import Foundation
import Combine
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
#if canImport(Network)
import Network
#endif
#if canImport(ExternalAccessory)
import ExternalAccessory
#endif

public protocol OBDTransport: AnyObject {
    var name: String { get }
    var isConnected: Bool { get }
    func connect() async throws
    func disconnect()
    func sendCommand(_ command: String) async throws -> String
}

public enum OBDTransportError: Error, LocalizedError {
    case bluetoothUnavailable
    case adapterNotFound
    case notConnected
    case timeout

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: return "Bluetooth is powered off or unauthorized."
        case .adapterNotFound: return "No compatible OBD2 adapter found nearby."
        case .notConnected: return "OBD2 adapter is not connected."
        case .timeout: return "OBD2 adapter response timed out."
        }
    }
}

/// Built-in deterministic Virtual Nissan Leaf simulator so users can explore GitLeaf offline.
public final class VirtualLeafTransport: OBDTransport {
    public let name = "Virtual Leaf ZE1 (40 kWh)"
    public private(set) var isConnected = false
    private var txHeader: String = "79B"
    private var clearedDTCs = false

    public init() {}

    public func connect() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
        isConnected = true
    }

    public func disconnect() {
        isConnected = false
    }

    public func sendCommand(_ command: String) async throws -> String {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cmd == "ATZ" || cmd == "ATI" { return "ELM327 v1.5\r\n>" }
        if cmd == "STI" { return "STN2255 v5.6.5\r\n>" }
        if cmd.hasPrefix("ATSH") {
            txHeader = cmd.replacingOccurrences(of: "ATSH", with: "").trimmingCharacters(in: .whitespaces)
            return "OK\r\n>"
        }
        if cmd.hasPrefix("AT") || cmd.hasPrefix("ST") { return "OK\r\n>" }
        if cmd == "14 FF FF FF" || cmd == "14FFFFFF" {
            clearedDTCs = true
            return "7BB 01 54 00 00 00 00 00 00\r\n>"
        }
        return "OK\r\n>"
    }

    public func sampleSnapshot(generation: LeafGeneration) -> (LeafBatterySummary, LeafCellPack, LeafThermistors, LeafTPMS, LeafVCMState, [DTCEntry]) {
        let gids = Int(Double(generation.maxGids) * 0.765 * 0.894)
        let remKwh = ((Double(gids) * generation.whPerGid) / 1000.0 * 100).rounded() / 100
        let summary = LeafBatterySummary(
            packVoltageV: 368.4,
            packCurrentA: 12.5,
            powerKw: 4.61,
            hxPct: 84.2,
            realSocPct: 76.5,
            dashSocPct: 77.7,
            ahr: 99.3,
            sohPct: 89.4,
            gids: gids,
            remainingKwh: remKwh,
            qcCount: 47,
            l1L2Count: 812
        )
        var voltages: [Int] = []
        var shunts: [Bool] = []
        for i in 0..<96 {
            let base = 3838 + (i % 7) - 3
            voltages.append(i == 41 ? 3796 : base)
            shunts.append(i == 8 || i == 40 || i == 72)
        }
        let minMv = voltages.min() ?? 3796
        let maxMv = voltages.max() ?? 3841
        let avgMv = Double(voltages.reduce(0, +)) / 96.0
        let cells = LeafCellPack(
            voltagesMv: voltages,
            minMv: minMv,
            maxMv: maxMv,
            avgMv: (avgMv * 10).rounded() / 10,
            deltaMv: maxMv - minMv,
            weakCellIndices: [42],
            shuntActive: shunts
        )
        let temps = LeafThermistors(tempsC: [18.0, 19.0, 18.0, 17.0], minC: 17.0, maxC: 19.0, avgC: 18.0, heaterActive: false)
        let tpms = LeafTPMS(flPsi: 36.0, frPsi: 36.25, rlPsi: 35.5, rrPsi: 31.0)
        let vcm = LeafVCMState(speedKmh: 0.0, gear: "P", ambientTempC: 14.5, odometerKm: 64_210, climateKw: 0.4)
        let dtcs: [DTCEntry] = clearedDTCs ? [] : [
            DTCEntry(ecu: "LBC", code: "P3173", statusByte: 0x09, description: "LBC Battery Cell Voltage Sensor Fault", severity: "CRITICAL"),
            DTCEntry(ecu: "BCM", code: "B26F2", statusByte: 0x08, description: "BCM Keyless Antenna Warning", severity: "INFO")
        ]
        return (summary, cells, temps, tpms, vcm, dtcs)
    }
}

#if canImport(CoreBluetooth)
/// CoreBluetooth BLE 4.0/5.0 Transport covering Veepeak, OBDLink CX, Vgate iCar Pro, vLinker, LELink², Carista & Generic ELM327 BLE.
public final class BLEOBDTransport: NSObject, OBDTransport, CBCentralManagerDelegate, CBPeripheralDelegate {
    public private(set) var name: String = "BLE OBD2 Adapter"
    public private(set) var isConnected: Bool = false

    private static let knownServiceUUIDs: [CBUUID] = [
        CBUUID(string: "FFF0"),
        CBUUID(string: "FFE0"),
        CBUUID(string: "18F0"),
        CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"),
        CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    ]

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var rxChar: CBCharacteristic?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var responseContinuation: CheckedContinuation<String, Error>?
    private var rxBuffer = ""

    public func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.connectContinuation = cont
            self.central = CBCentralManager(delegate: self, queue: .global(qos: .userInitiated))
        }
    }

    public func disconnect() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        txChar = nil
        rxChar = nil
        isConnected = false
    }

    public func sendCommand(_ command: String) async throws -> String {
        guard isConnected, let p = peripheral, let tx = txChar else {
            throw OBDTransportError.notConnected
        }
        let payload = Data((command + "\r").utf8)
        rxBuffer = ""
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.responseContinuation = cont
            let writeType: CBCharacteristicWriteType = tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            p.writeValue(payload, for: tx, type: writeType)
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: Self.knownServiceUUIDs, options: nil)
        } else if central.state == .poweredOff || central.state == .unauthorized || central.state == .unsupported {
            connectContinuation?.resume(throwing: OBDTransportError.bluetoothUnavailable)
            connectContinuation = nil
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString } ?? []
        guard AdapterCatalog.matchBLE(name: peripheral.name, serviceUUIDs: advUUIDs) != nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        self.name = peripheral.name ?? "BLE OBD2 Adapter"
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(Self.knownServiceUUIDs)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics else { return }
        for char in chars {
            if char.properties.contains(.notify) || char.properties.contains(.indicate) {
                rxChar = char
                peripheral.setNotifyValue(true, for: char)
            }
            if char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse) {
                txChar = char
            }
        }
        if txChar != nil && rxChar != nil && !isConnected {
            isConnected = true
            connectContinuation?.resume()
            connectContinuation = nil
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, let chunk = String(data: data, encoding: .utf8) else { return }
        rxBuffer += chunk
        if rxBuffer.contains(">") {
            let complete = rxBuffer
            rxBuffer = ""
            responseContinuation?.resume(returning: complete)
            responseContinuation = nil
        }
    }
}
#endif

#if canImport(Network)
/// Wi-Fi TCP OBD2 Transport (ELM327 Wi-Fi, Vgate Wi-Fi, KONNWEI KW902/903 at 192.168.0.10:35000).
public final class WiFiOBDTransport: OBDTransport {
    public let name: String
    public let host: String
    public let port: UInt16
    public private(set) var isConnected = false
    private var connection: NWConnection?

    public init(host: String = "192.168.0.10", port: UInt16 = 35000) {
        self.host = host
        self.port = port
        self.name = "Wi-Fi OBD2 (\(host):\(port))"
    }

    public func connect() async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.connection = conn
        conn.start(queue: .global(qos: .userInitiated))
        isConnected = true
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    public func sendCommand(_ command: String) async throws -> String {
        guard let conn = connection, isConnected else { return "NO DATA\r\n>" }
        let data = Data((command + "\r").utf8)
        return try await withCheckedThrowingContinuation { cont in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err); return }
                conn.receive(minimumIncompleteLength: 1, maximumLength: 2048) { rx, _, _, rxErr in
                    if let rxErr { cont.resume(throwing: rxErr); return }
                    cont.resume(returning: String(data: rx ?? Data(), encoding: .utf8) ?? "")
                }
            })
        }
    }
}
#endif

#if canImport(ExternalAccessory) && os(iOS)
/// Apple MFi Classic Bluetooth Transport for OBDLink MX+ / LX (`com.obdlink.protocol`).
public final class MFiOBDTransport: OBDTransport {
    public let name = "OBDLink MX+ (MFi)"
    public private(set) var isConnected = false
    private var session: EASession?
    private let protocolString = "com.obdlink.protocol"

    public init() {}

    public func connect() async throws {
        let accessories = EAAccessoryManager.shared().connectedAccessories
        guard let acc = accessories.first(where: { $0.protocolStrings.contains(protocolString) }),
              let eaSession = EASession(accessory: acc, forProtocol: protocolString) else {
            throw OBDTransportError.adapterNotFound
        }
        eaSession.inputStream?.open()
        eaSession.outputStream?.open()
        self.session = eaSession
        self.isConnected = true
    }

    public func disconnect() {
        session?.inputStream?.close()
        session?.outputStream?.close()
        session = nil
        isConnected = false
    }

    public func sendCommand(_ command: String) async throws -> String {
        guard isConnected, let out = session?.outputStream, let inp = session?.inputStream else {
            throw OBDTransportError.notConnected
        }
        let bytes = Array((command + "\r").utf8)
        _ = out.write(bytes, maxLength: bytes.count)
        var buffer = [UInt8](repeating: 0, count: 1024)
        let readCount = inp.read(&buffer, maxLength: buffer.count)
        guard readCount > 0 else { return "NO DATA\r\n>" }
        return String(bytes: buffer.prefix(readCount), encoding: .utf8) ?? ""
    }
}
#endif

@MainActor
public final class GitLeafViewModel: ObservableObject {
    @Published public var selectedGeneration: LeafGeneration = .ze1_40
    @Published public var selectedAdapter: AdapterSpec = AdapterCatalog.all.last!
    @Published public var isConnected: Bool = false
    @Published public var isPolling: Bool = false
    @Published public var adapterTier: AdapterTier = .stnPro
    @Published public var adapterWarning: String? = nil
    @Published public var latencyMs: Int = 18
    @Published public var readOnlySafeMode: Bool = true
    @Published public var elevationGainM: Double = 0.0
    @Published public var wifiHost: String = "192.168.0.10"
    @Published public var wifiPort: String = "35000"
    @Published public var statusBanner: String = "Ready — Tap Connect or Demo Mode"

    @Published public var battery: LeafBatterySummary
    @Published public var cells: LeafCellPack
    @Published public var temps: LeafThermistors
    @Published public var tpms: LeafTPMS
    @Published public var vcm: LeafVCMState
    @Published public var dtcs: [DTCEntry]

    @Published public var sohHistory: [SOHSnapshot] = []
    @Published public var trips: [TripRecord] = []
    @Published public var isRecordingTrip: Bool = false
    private var activeTripStartDate: Date?
    private var activeTripStartSoc: Double = 0
    private var activeTripStartKwh: Double = 0

    private let simulator = VirtualLeafTransport()
    private var activeTransport: OBDTransport?
    private var pollingTask: Task<Void, Never>?
    private let interlock = SafetyInterlock()
    private let assembler = ISOTPAssembler()
    private var demoTick: Int = 0

    private let sohStoreKey = "gitleaf_soh_history_v1"
    private let tripStoreKey = "gitleaf_trip_history_v1"

    public init() {
        let initial = simulator.sampleSnapshot(generation: .ze1_40)
        self.battery = initial.0
        self.cells = initial.1
        self.temps = initial.2
        self.tpms = initial.3
        self.vcm = initial.4
        self.dtcs = initial.5
        loadPersistedHistory()
    }

    private func loadPersistedHistory() {
        if let data = UserDefaults.standard.data(forKey: sohStoreKey),
           let decoded = try? JSONDecoder().decode([SOHSnapshot].self, from: data),
           !decoded.isEmpty {
            self.sohHistory = decoded
        } else {
            let now = Date()
            self.sohHistory = [
                SOHSnapshot(date: now.addingTimeInterval(-86400 * 120), odometerKm: 58_400, sohPct: 91.2, hxPct: 86.8, ahr: 101.4, packTempC: 16.0),
                SOHSnapshot(date: now.addingTimeInterval(-86400 * 60), odometerKm: 61_300, sohPct: 90.3, hxPct: 85.4, ahr: 100.2, packTempC: 19.0),
                SOHSnapshot(date: now, odometerKm: 64_210, sohPct: 89.4, hxPct: 84.2, ahr: 99.3, packTempC: 18.0)
            ]
        }
        if let data = UserDefaults.standard.data(forKey: tripStoreKey),
           let decoded = try? JSONDecoder().decode([TripRecord].self, from: data) {
            self.trips = decoded
        }
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(sohHistory) {
            UserDefaults.standard.set(data, forKey: sohStoreKey)
        }
        if let data = try? JSONEncoder().encode(trips) {
            UserDefaults.standard.set(data, forKey: tripStoreKey)
        }
    }

    public func logSOHSnapshot() {
        let snap = SOHSnapshot(
            odometerKm: vcm.odometerKm,
            sohPct: battery.sohPct,
            hxPct: battery.hxPct,
            ahr: battery.ahr,
            packTempC: temps.avgC
        )
        sohHistory.append(snap)
        persistHistory()
    }

    public func toggleTripRecording() {
        if isRecordingTrip {
            let endedAt = Date()
            let startedAt = activeTripStartDate ?? endedAt.addingTimeInterval(-600)
            let usedKwh = max(0.2, abs(activeTripStartKwh - battery.remainingKwh) + (activeTransport is VirtualLeafTransport ? 2.4 : 0.0))
            let distKm = max(1.2, (usedKwh * 1000.0) / 155.0)
            let record = TripRecord(
                startedAt: startedAt,
                endedAt: endedAt,
                distanceKm: (distKm * 10).rounded() / 10,
                startSocPct: activeTripStartSoc,
                endSocPct: battery.realSocPct,
                energyUsedKwh: (usedKwh * 100).rounded() / 100,
                regenKwh: (usedKwh * 0.18 * 100).rounded() / 100,
                ambientTempC: vcm.ambientTempC
            )
            trips.insert(record, at: 0)
            isRecordingTrip = false
            persistHistory()
        } else {
            activeTripStartDate = Date()
            activeTripStartSoc = battery.realSocPct
            activeTripStartKwh = battery.remainingKwh
            isRecordingTrip = true
        }
    }

    public func disconnect() {
        pollingTask?.cancel()
        pollingTask = nil
        activeTransport?.disconnect()
        activeTransport = nil
        isConnected = false
        isPolling = false
        adapterWarning = nil
        statusBanner = "Disconnected — Ready"
    }

    public func connectDemo() async {
        disconnect()
        try? await simulator.connect()
        activeTransport = simulator
        isConnected = true
        adapterTier = .stnPro
        adapterWarning = nil
        latencyMs = 14
        statusBanner = "Connected to Virtual Leaf (\(selectedGeneration.displayName))"
        refreshTelemetry()
        startLivePolling()
    }

    public func connectSelectedAdapter() async {
        disconnect()
        switch selectedAdapter.transport {
        case .virtual:
            await connectDemo()
        case .ble:
            #if canImport(CoreBluetooth)
            let ble = BLEOBDTransport()
            do {
                statusBanner = "Scanning BLE for \(selectedAdapter.displayName)..."
                try await ble.connect()
                activeTransport = ble
                isConnected = true
                try await initializeELM327(on: ble)
                statusBanner = "Connected to \(ble.name) (\(adapterTier.rawValue))"
                startLivePolling()
            } catch {
                statusBanner = error.localizedDescription
            }
            #endif
        case .wifiTCP:
            #if canImport(Network)
            let parsedPort = UInt16(wifiPort) ?? (selectedAdapter.wifiPort ?? 35000)
            let wifi = WiFiOBDTransport(
                host: wifiHost.isEmpty ? (selectedAdapter.wifiHost ?? "192.168.0.10") : wifiHost,
                port: parsedPort
            )
            do {
                try await wifi.connect()
                activeTransport = wifi
                isConnected = true
                try await initializeELM327(on: wifi)
                statusBanner = "Connected to \(wifi.name)"
                startLivePolling()
            } catch {
                statusBanner = error.localizedDescription
            }
            #endif
        case .mfiEA:
            #if canImport(ExternalAccessory) && os(iOS)
            let mfi = MFiOBDTransport()
            do {
                try await mfi.connect()
                activeTransport = mfi
                isConnected = true
                try await initializeELM327(on: mfi)
                statusBanner = "Connected to \(mfi.name)"
                startLivePolling()
            } catch {
                statusBanner = error.localizedDescription
            }
            #else
            statusBanner = "MFi ExternalAccessory is supported on physical iOS devices."
            #endif
        }
    }

    private func initializeELM327(on transport: OBDTransport) async throws {
        for cmd in ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP6", "ATCAF0"] {
            _ = try await transport.sendCommand(cmd)
        }
        let elm = try await transport.sendCommand("ATI")
        let stn = try await transport.sendCommand("STI")
        let cfc = try await transport.sendCommand("ATCFC1")
        let fcsm = try await transport.sendCommand("ATFCSM1")
        if stn.uppercased().contains("STN") && !stn.contains("?") {
            adapterTier = .stnPro
            adapterWarning = nil
        } else if !cfc.contains("?") && !fcsm.contains("?") && !elm.uppercased().contains("V2.1") {
            adapterTier = .elm327v15
            adapterWarning = nil
        } else {
            adapterTier = .elm327CloneV21
            adapterWarning = "Clone ELM327 v2.1 detected — using software-paced ISO-TP polling (1 Hz)."
        }
    }

    public func startLivePolling() {
        pollingTask?.cancel()
        isPolling = true
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isConnected else { break }
                await self.pollOnce()
                let intervalNs: UInt64 = (self.adapterTier == .stnPro) ? 1_500_000_000 : 2_500_000_000
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    private func pollOnce() async {
        guard let transport = activeTransport else { return }
        if transport is VirtualLeafTransport {
            demoTick += 1
            let snap = simulator.sampleSnapshot(generation: selectedGeneration)
            let waveKw = (sin(Double(demoTick) * 0.6) * 2.4 * 100).rounded() / 100
            let base = snap.0
            self.battery = LeafBatterySummary(
                packVoltageV: base.packVoltageV,
                packCurrentA: ((waveKw * 1000.0 / base.packVoltageV) * 100).rounded() / 100,
                powerKw: waveKw,
                hxPct: base.hxPct,
                realSocPct: base.realSocPct,
                dashSocPct: base.dashSocPct,
                ahr: base.ahr,
                sohPct: base.sohPct,
                gids: base.gids,
                remainingKwh: base.remainingKwh,
                qcCount: base.qcCount,
                l1L2Count: base.l1L2Count
            )
            self.cells = snap.1
            self.temps = snap.2
            self.tpms = snap.3
            self.vcm = snap.4
            self.dtcs = snap.5
            self.latencyMs = 12 + (demoTick % 6)
            return
        }

        let start = Date()
        do {
            _ = try await transport.sendCommand("ATSH 79B")
            let rawG1 = try await transport.sendCommand("21 01")
            if let g1Bytes = try? assembler.assemble(rawELMResponse: rawG1, expectedRxID: 0x7BB),
               let summary = LeafCANParser.decodeLBCGroup1(g1Bytes, generation: selectedGeneration) {
                self.battery = summary
            }

            let rawG6 = try await transport.sendCommand("21 06")
            let shunts = (try? assembler.assemble(rawELMResponse: rawG6, expectedRxID: 0x7BB))
                .map { LeafCANParser.decodeLBCGroup6Shunts($0) } ?? []

            let rawG2 = try await transport.sendCommand("21 02")
            if let g2Bytes = try? assembler.assemble(rawELMResponse: rawG2, expectedRxID: 0x7BB),
               let cellPack = LeafCANParser.decodeLBCGroup2Cells(g2Bytes, shunts: shunts) {
                self.cells = cellPack
            }

            let rawG4 = try await transport.sendCommand("21 04")
            if let g4Bytes = try? assembler.assemble(rawELMResponse: rawG4, expectedRxID: 0x7BB),
               let therm = LeafCANParser.decodeLBCGroup4Temps(g4Bytes) {
                self.temps = therm
            }

            let rawDTC = try await transport.sendCommand("19 02 FF")
            if let dtcBytes = try? assembler.assemble(rawELMResponse: rawDTC, expectedRxID: 0x7BB) {
                self.dtcs = LeafCANParser.decodeUDSDTCs(dtcBytes, ecu: "LBC")
            }

            _ = try await transport.sendCommand("ATSH 745")
            let rawTPMS = try await transport.sendCommand("21 0E")
            if let tpmsBytes = try? assembler.assemble(rawELMResponse: rawTPMS, expectedRxID: 0x765),
               let parsedTpms = LeafCANParser.decodeTPMS(tpmsBytes) {
                self.tpms = parsedTpms
            }

            self.latencyMs = max(1, Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            self.statusBanner = "Poll error: \(error.localizedDescription)"
        }
    }

    public func refreshTelemetry() {
        let snap = simulator.sampleSnapshot(generation: selectedGeneration)
        self.battery = snap.0
        self.cells = snap.1
        self.temps = snap.2
        self.tpms = snap.3
        self.vcm = snap.4
        self.dtcs = snap.5
    }

    public func executeServiceCommand(_ command: ServiceCommandType, confirmed: Bool) async -> Result<String, Error> {
        do {
            let (txID, bytes) = try interlock.authorize(
                command: command,
                vcm: vcm,
                readOnlyMode: readOnlySafeMode,
                userConfirmed: confirmed
            )
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            if let transport = activeTransport {
                _ = try await transport.sendCommand(String(format: "ATSH %03X", txID))
                _ = try await transport.sendCommand(hex)
            } else if command == .clearDTCs {
                _ = try await simulator.sendCommand("14 FF FF FF")
            }
            refreshTelemetry()
            return .success("\(command.rawValue) completed safely.")
        } catch {
            return .failure(error)
        }
    }
}
