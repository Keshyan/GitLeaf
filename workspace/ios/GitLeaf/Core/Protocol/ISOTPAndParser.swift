import Foundation

public enum ISOTPError: Error, LocalizedError {
    case emptyFrames
    case invalidPCI(UInt8)
    case sequenceMismatch(expected: UInt8, got: UInt8)
    case incompleteMessage(received: Int, expected: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyFrames: return "No CAN frames received."
        case .invalidPCI(let byte): return String(format: "Unsupported ISO-TP PCI byte 0x%02X", byte)
        case .sequenceMismatch(let exp, let got): return "ISO-TP sequence mismatch (expected \(exp), got \(got))"
        case .incompleteMessage(let r, let e): return "Incomplete ISO-TP payload (\(r)/\(e) bytes)"
        }
    }
}

public struct ISOTPAssembler: Sendable {
    public init() {}

    public func assemble(rawELMResponse: String, expectedRxID: UInt16? = nil) throws -> [UInt8] {
        let frames = parseELMLines(rawELMResponse, expectedRxID: expectedRxID)
        return try assemble(frames: frames)
    }

    public func parseELMLines(_ raw: String, expectedRxID: UInt16? = nil) -> [[UInt8]] {
        let cleaned = raw.replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: ">", with: "")
        var result: [[UInt8]] = []

        for rawLine in cleaned.split(separator: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let upper = line.uppercased()
            if ["NO DATA", "STOPPED", "OK", "?"].contains(upper) || upper.hasPrefix("SEARCHING") { continue }

            if line.count >= 2 && line[line.index(line.startIndex, offsetBy: 1)] == ":" {
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }

            let tokens = line.split(separator: " ").map(String.init)
            var arbID: UInt16?
            var hexPayload = ""

            if tokens.count >= 2, tokens[0].count == 3, let parsedID = UInt16(tokens[0], radix: 16) {
                arbID = parsedID
                hexPayload = tokens.dropFirst().joined()
            } else {
                hexPayload = tokens.joined()
            }

            if let expected = expectedRxID, let actual = arbID, actual != expected {
                continue
            }

            if let bytes = hexToBytes(hexPayload), !bytes.isEmpty {
                result.append(bytes)
            }
        }
        return result
    }

    public func assemble(frames: [[UInt8]]) throws -> [UInt8] {
        guard let first = frames.first, !first.isEmpty else { throw ISOTPError.emptyFrames }
        let pciType = (first[0] & 0xF0) >> 4

        if pciType == 0x0 {
            let length = Int(first[0] & 0x0F)
            guard length > 0 && length <= first.count - 1 else { throw ISOTPError.invalidPCI(first[0]) }
            return Array(first[1..<(1 + length)])
        }

        if pciType == 0x1 {
            guard first.count >= 3 else { throw ISOTPError.invalidPCI(first[0]) }
            let totalLen = (Int(first[0] & 0x0F) << 8) | Int(first[1])
            var buffer = Array(first.dropFirst(2))
            var expectedSeq: UInt8 = 1

            for frame in frames.dropFirst() {
                if buffer.count >= totalLen { break }
                guard let pci = frame.first else { continue }
                let type = (pci & 0xF0) >> 4
                if type == 0x3 { continue }
                guard type == 0x2 else { throw ISOTPError.invalidPCI(pci) }
                let seq = pci & 0x0F
                guard seq == expectedSeq else {
                    throw ISOTPError.sequenceMismatch(expected: expectedSeq, got: seq)
                }
                buffer.append(contentsOf: frame.dropFirst())
                expectedSeq = (expectedSeq + 1) & 0x0F
            }

            guard buffer.count >= totalLen else {
                throw ISOTPError.incompleteMessage(received: buffer.count, expected: totalLen)
            }
            return Array(buffer.prefix(totalLen))
        }

        throw ISOTPError.invalidPCI(first[0])
    }

    private func hexToBytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return bytes
    }
}

/// Active Leaf queries for speed, gear, ambient temperature, and odometer.
/// Speed, gear, and ambient are VCM `0x797` / `0x79A`.
/// Odometer is the meter cluster `0x743` / `0x763` (`22 0E 01`); VCM does not serve it.
public enum LeafVehicleQuery {
    public static let vcmTxHeader = "ATSH 797"
    public static let meterTxHeader = "ATSH 743"
    public static let vcmRxID: UInt16 = 0x79A
    public static let meterRxID: UInt16 = 0x763
    public static let gear = "22 11 56"
    public static let speed = "22 12 1A"
    public static let ambient = "22 11 5D"
    public static let odometer = "22 0E 01"
}

public enum LeafCANParser {
    private static let knownDTCs: [String: (String, String)] = [
        "P3173": ("LBC Battery Cell Voltage Sensor Fault", "CRITICAL"),
        "P31E7": ("LBC HV Battery Insulation / Contactor Check", "CRITICAL"),
        "P312F": ("VCM Quick Charge Communication Error", "WARNING"),
        "C118C": ("ABS / Regenerative Braking Pressure Sensor", "WARNING"),
        "B26F2": ("BCM Keyless Antenna Warning", "INFO"),
        "U1000": ("CAN Communication Bus Timeout", "WARNING")
    ]

    public static func decodeLBCGroup1(_ payload: [UInt8], generation: LeafGeneration = .ze1_40) -> LeafBatterySummary? {
        guard payload.count >= 40, payload[0] == 0x61, payload[1] == 0x01 else { return nil }

        let currentRaw = Int32(bitPattern:
            (UInt32(payload[2]) << 24) |
            (UInt32(payload[3]) << 16) |
            (UInt32(payload[4]) << 8) |
            UInt32(payload[5])
        )
        let currentA = Double(currentRaw) / 1024.0
        let voltageV = Double((UInt16(payload[18]) << 8) | UInt16(payload[19])) / 100.0
        let powerKw = (voltageV * currentA) / 1000.0
        let hxPct = Double((UInt16(payload[24]) << 8) | UInt16(payload[25])) / 100.0

        let realSocRaw = (UInt32(payload[26]) << 16) | (UInt32(payload[27]) << 8) | UInt32(payload[28])
        let realSocPct = min(100.0, max(0.0, Double(realSocRaw) / 10000.0))

        let ahrRaw = (UInt32(payload[29]) << 16) | (UInt32(payload[30]) << 8) | UInt32(payload[31])
        let ahr = Double(ahrRaw) / 10000.0

        let sohPct = min(100.0, max(0.0, Double((UInt16(payload[32]) << 8) | UInt16(payload[33])) / 100.0))
        let gids = Int((UInt16(payload[34]) << 8) | UInt16(payload[35]))
        let qcCount = Int((UInt16(payload[36]) << 8) | UInt16(payload[37]))
        let l1L2Count = Int((UInt16(payload[38]) << 8) | UInt16(payload[39]))

        let dashSocPct = min(100.0, max(0.0, (realSocPct - 5.0) / 0.92))
        let remainingKwh = (Double(gids) * generation.whPerGid) / 1000.0

        return LeafBatterySummary(
            packVoltageV: (voltageV * 100).rounded() / 100,
            packCurrentA: (currentA * 100).rounded() / 100,
            powerKw: (powerKw * 100).rounded() / 100,
            hxPct: (hxPct * 100).rounded() / 100,
            realSocPct: (realSocPct * 100).rounded() / 100,
            dashSocPct: (dashSocPct * 10).rounded() / 10,
            ahr: (ahr * 100).rounded() / 100,
            sohPct: (sohPct * 100).rounded() / 100,
            gids: gids,
            remainingKwh: (remainingKwh * 100).rounded() / 100,
            qcCount: qcCount,
            l1L2Count: l1L2Count
        )
    }

    public static func decodeLBCGroup2Cells(_ payload: [UInt8], shunts: [Bool] = [], weakThresholdMv: Int = 30) -> LeafCellPack? {
        guard payload.count >= 2 + 96 * 2, payload[0] == 0x61, payload[1] == 0x02 else { return nil }
        var voltages: [Int] = []
        voltages.reserveCapacity(96)
        for i in 0..<96 {
            let mv = (Int(payload[2 + i * 2]) << 8) | Int(payload[3 + i * 2])
            voltages.append(mv)
        }
        let minMv = voltages.min() ?? 0
        let maxMv = voltages.max() ?? 0
        let avgMv = Double(voltages.reduce(0, +)) / Double(voltages.count)
        let weak = voltages.enumerated().compactMap { (idx, mv) in
            (avgMv - Double(mv)) >= Double(weakThresholdMv) ? idx + 1 : nil
        }
        let normalizedShunts = shunts.count == 96 ? shunts : Array(repeating: false, count: 96)
        return LeafCellPack(
            voltagesMv: voltages,
            minMv: minMv,
            maxMv: maxMv,
            avgMv: (avgMv * 10).rounded() / 10,
            deltaMv: maxMv - minMv,
            weakCellIndices: weak,
            shuntActive: normalizedShunts
        )
    }

    public static func decodeLBCGroup4Temps(_ payload: [UInt8]) -> LeafThermistors? {
        guard payload.count >= 14, payload[0] == 0x61, payload[1] == 0x04 else { return nil }
        var temps: [Double] = []
        for i in 0..<4 {
            let base = 2 + i * 3
            if payload[base] == 0xFF && payload[base + 1] == 0xFF { continue }
            let rawByte = payload[base + 2]
            let signedTemp = Int8(bitPattern: rawByte)
            temps.append(Double(signedTemp))
        }
        guard let minC = temps.min(), let maxC = temps.max() else { return nil }
        let avgC = ((temps.reduce(0, +) / Double(temps.count)) * 10).rounded() / 10
        let heater = payload.count > 14 ? (payload[14] & 0x01) != 0 : false
        return LeafThermistors(tempsC: temps, minC: minC, maxC: maxC, avgC: avgC, heaterActive: heater)
    }

    public static func decodeLBCGroup6Shunts(_ payload: [UInt8]) -> [Bool] {
        guard payload.count >= 26, payload[0] == 0x61, payload[1] == 0x06 else {
            return Array(repeating: false, count: 96)
        }
        var shunts: [Bool] = []
        shunts.reserveCapacity(96)
        for mod in 0..<24 {
            let nibble = payload[2 + mod] & 0x0F
            for bit in 0..<4 {
                shunts.append((nibble & (1 << bit)) != 0)
            }
        }
        return shunts
    }

    public static func decodeTPMS(_ payload: [UInt8]) -> LeafTPMS? {
        guard payload.count >= 6 else { return nil }
        return LeafTPMS(
            flPsi: Double(payload[2]) * 0.25,
            frPsi: Double(payload[3]) * 0.25,
            rlPsi: Double(payload[4]) * 0.25,
            rrPsi: Double(payload[5]) * 0.25
        )
    }

    /// VCM `22 11 56` gear byte: 1=P, 2=R, 3=N, 4=D, 7=Eco.
    /// Unknown codes return nil so a failed decode is never treated as Park.
    public static func decodeVCMGear(_ payload: [UInt8]) -> String? {
        guard payload.count >= 4, payload[0] == 0x62, payload[1] == 0x11, payload[2] == 0x56 else { return nil }
        switch payload[3] {
        case 1: return "P"
        case 2: return "R"
        case 3: return "N"
        case 4: return "D"
        case 7: return "E"
        default: return nil
        }
    }

    /// VCM `22 12 1A`: unsigned speed in 0.1 km/h.
    public static func decodeVCMSpeedKmh(_ payload: [UInt8]) -> Double? {
        guard payload.count >= 5, payload[0] == 0x62, payload[1] == 0x12, payload[2] == 0x1A else { return nil }
        let raw = (Int(payload[3]) << 8) | Int(payload[4])
        return Double(raw) / 10.0
    }

    /// VCM `22 11 5D`: the byte after the status byte is °F + 41 (Turbo3 / LeafSpy).
    /// Returned in °C.
    public static func decodeVCMAmbientC(_ payload: [UInt8]) -> Double? {
        guard payload.count >= 5, payload[0] == 0x62, payload[1] == 0x11, payload[2] == 0x5D else { return nil }
        let fahrenheit = Int(payload[4]) - 41
        let celsius = (Double(fahrenheit) - 32.0) * 5.0 / 9.0
        return (celsius * 10).rounded() / 10
    }

    /// Meter `22 0E 01` (TX `0x743` / RX `0x763`): 24-bit odometer in dash units.
    /// ZE1 cluster replies are kilometres on metric cars and miles on US/UK cars.
    public static func decodeOdometerKm(_ payload: [UInt8]) -> Int? {
        guard payload.count >= 6, payload[0] == 0x62, payload[1] == 0x0E, payload[2] == 0x01 else { return nil }
        return (Int(payload[3]) << 16) | (Int(payload[4]) << 8) | Int(payload[5])
    }

    public static func decodeUDSDTCs(_ payload: [UInt8], ecu: String = "LBC") -> [DTCEntry] {
        guard payload.count >= 3, payload[0] == 0x59, payload[1] == 0x02 else { return [] }
        let prefixes = ["P", "C", "B", "U"]
        var results: [DTCEntry] = []
        var idx = 3
        while idx + 3 < payload.count {
            let b0 = payload[idx], b1 = payload[idx + 1], status = payload[idx + 3]
            idx += 4
            if b0 == 0 && b1 == 0 { continue }
            let letter = prefixes[Int((b0 >> 6) & 0x03)]
            let code = String(format: "%@%d%X%X%X", letter, (b0 >> 4) & 0x03, b0 & 0x0F, (b1 >> 4) & 0x0F, b1 & 0x0F)
            let info = knownDTCs[code] ?? ("\(ecu) Diagnostic Trouble Code \(code)", "WARNING")
            results.append(DTCEntry(ecu: ecu, code: code, statusByte: status, description: info.0, severity: info.1))
        }
        return results
    }

    public static func estimateRangeKm(
        remainingKwh: Double,
        whPerKm: Double = 155.0,
        elevationGainM: Double = 0.0,
        reserveKwh: Double = 1.5
    ) -> Double {
        guard whPerKm > 0 else { return 0 }
        let usable = max(0.0, remainingKwh - reserveKwh)
        let potKwh = (1650.0 * 9.81 * elevationGainM) / 3_600_000.0
        let adjusted = potKwh > 0 ? max(0.0, usable - potKwh / 0.85) : (usable + abs(potKwh) * 0.70)
        return ((adjusted * 1000.0 / whPerKm) * 10).rounded() / 10
    }
}

public enum SafetyInterlockError: Error, LocalizedError {
    case readOnlyEnabled
    case confirmationRequired
    case vehicleNotInPark(gear: String, speedKmh: Double)

    public var errorDescription: String? {
        switch self {
        case .readOnlyEnabled: return "Blocked: Safe Read-Only Mode is active."
        case .confirmationRequired: return "Blocked: Explicit user confirmation required."
        case .vehicleNotInPark(let g, let s):
            return String(format: "Blocked: Shift to Park (P) at 0 km/h (currently %@, %.1f km/h).", g, s)
        }
    }
}

public struct SafetyInterlock: Sendable {
    public init() {}

    public func authorize(
        command: ServiceCommandType,
        vcm: LeafVCMState,
        readOnlyMode: Bool,
        userConfirmed: Bool
    ) throws -> (txArbID: UInt16, payload: [UInt8]) {
        if readOnlyMode { throw SafetyInterlockError.readOnlyEnabled }
        if !userConfirmed { throw SafetyInterlockError.confirmationRequired }
        if vcm.gear.uppercased() != "P" || abs(vcm.speedKmh) > 0.1 {
            throw SafetyInterlockError.vehicleNotInPark(gear: vcm.gear, speedKmh: vcm.speedKmh)
        }
        switch command {
        case .clearDTCs: return (0x79B, [0x14, 0xFF, 0xFF, 0xFF])
        case .toggleVSP: return (0x74B, [0x3B, 0x01, 0x00])
        case .setAutoDoorLock: return (0x745, [0x3B, 0x10, 0x01])
        case .setHeadlightDelay: return (0x745, [0x3B, 0x12, 0x03])
        case .registerTPMS: return (0x745, [0x31, 0x01, 0x02, 0x00])
        }
    }
}
