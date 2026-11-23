import Foundation

/// Timeouts shared by BLE, Wi-Fi, and MFi command exchanges.
/// `commandTimeoutSeconds` matches `protocol_core` `OBD_COMMAND_TIMEOUT_S`.
public enum OBDTiming {
    public static let connectTimeoutSeconds: TimeInterval = 10
    public static let commandTimeoutSeconds: TimeInterval = 8
    public static let scanTimeoutSeconds: TimeInterval = 20
}

/// Poll periods actually used by `GitLeafViewModel.startLivePolling`.
/// Clone warning copy is derived from this so it cannot drift from the sleep.
public enum AdapterPollSchedule {
    public static func intervalSeconds(for tier: AdapterTier) -> TimeInterval {
        switch tier {
        case .stnPro:
            return 1.5
        case .elm327v15, .elm327CloneV21:
            return 2.5
        }
    }

    public static func cloneWarning(for tier: AdapterTier) -> String? {
        guard tier == .elm327CloneV21 else { return nil }
        let seconds = intervalSeconds(for: tier)
        return String(format: "Clone ELM327 v2.1 detected — using software-paced ISO-TP polling (every %.1f s).", seconds)
    }
}

/// Accumulates ELM327/STN chunks until the `>` prompt.
/// A 96-cell ISO-TP reply spans many BLE notifications or TCP reads; returning
/// on the first chunk truncates the pack.
public struct ELMResponseAccumulator: Sendable, Equatable {
    public private(set) var buffer: String

    public init(buffer: String = "") {
        self.buffer = buffer
    }

    public mutating func reset() {
        buffer = ""
    }

    /// Returns the text through the first `>` when the prompt has arrived.
    public mutating func append(_ chunk: String) -> String? {
        guard !chunk.isEmpty else { return nil }
        buffer += chunk
        guard let prompt = buffer.firstIndex(of: ">") else { return nil }
        let end = buffer.index(after: prompt)
        let complete = String(buffer[..<end])
        buffer = String(buffer[end...])
        return complete
    }
}

public enum ELMExchangeResult: Equatable, Sendable {
    case pending
    case complete(String)
    case timedOut
}

/// Pure command state machine: a prompt completes the exchange even if the
/// timeout has just elapsed; otherwise a deadline with no prompt times out.
public struct ELMCommandExchange: Sendable {
    public let timeoutSeconds: TimeInterval
    public let startedAt: Date
    public private(set) var accumulator: ELMResponseAccumulator

    public init(
        timeoutSeconds: TimeInterval = OBDTiming.commandTimeoutSeconds,
        startedAt: Date,
        accumulator: ELMResponseAccumulator = ELMResponseAccumulator()
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.startedAt = startedAt
        self.accumulator = accumulator
    }

    public mutating func ingest(_ chunk: String, now: Date) -> ELMExchangeResult {
        if let complete = accumulator.append(chunk) {
            return .complete(complete)
        }
        if now.timeIntervalSince(startedAt) >= timeoutSeconds {
            return .timedOut
        }
        return .pending
    }
}

public enum OBDConnectionEvent: Equatable, Sendable {
    case setup
    case preparing
    case waiting(String)
    case ready
    case failed(String)
    case cancelled
}

public enum OBDConnectionPhase: Equatable, Sendable {
    case pending
    case ready
    case failed(String)
}

public enum OBDConnectDecision: Equatable, Sendable {
    case keepWaiting
    case connected
    case failed(String)
}

/// Maps a link event to "not connected yet", "ready", or "failed".
/// Callers must not report the adapter connected until the decision is `.connected`.
public enum OBDConnectionWatch {
    public static func phase(for event: OBDConnectionEvent) -> OBDConnectionPhase {
        switch event {
        case .setup, .preparing, .waiting:
            return .pending
        case .ready:
            return .ready
        case .failed(let message):
            return .failed(message)
        case .cancelled:
            return .failed("Connection cancelled.")
        }
    }

    public static func decide(_ phase: OBDConnectionPhase) -> OBDConnectDecision {
        switch phase {
        case .pending:
            return .keepWaiting
        case .ready:
            return .connected
        case .failed(let message):
            return .failed(message)
        }
    }
}

/// Fixed demo-snapshot figures. The 1.1.0 car screenshot matched these, including the sine-wave power and latency.
public enum DemoLeafSnapshot {
    public static let realSocPct = 76.5
    public static let dashSocPct = 77.7
    public static let sohPct = 89.4
    public static let hxPct = 84.2
    public static let packVoltageV = 368.4
    public static let ahr = 99.3
    public static let rrPsi = 31.0

    public static func gids(maxGids: Int) -> Int {
        Int(Double(maxGids) * 0.765 * 0.894)
    }

    public static func remainingKwh(gids: Int, whPerGid: Double) -> Double {
        ((Double(gids) * whPerGid) / 1000.0 * 100).rounded() / 100
    }

    public static func powerKw(tick: Int) -> Double {
        (sin(Double(tick) * 0.6) * 2.4 * 100).rounded() / 100
    }

    public static func currentAmps(powerKw: Double, packVoltageV: Double) -> Double {
        guard packVoltageV != 0 else { return 0 }
        return ((powerKw * 1000.0 / packVoltageV) * 100).rounded() / 100
    }

    public static func latencyMs(tick: Int) -> Int {
        12 + (tick % 6)
    }
}

public enum TelemetryPhase: String, Sendable {
    case demo
    case waiting
    case live
}

public enum LiveDisplayPolicy {
    /// A real adapter shows waiting placeholders until a battery frame decodes. Demo numbers stay on the demo transport only.
    public static func phase(realAdapterConnected: Bool, hasDecodedLiveBattery: Bool, demoTransportActive: Bool) -> TelemetryPhase {
        if realAdapterConnected && !hasDecodedLiveBattery {
            return .waiting
        }
        if realAdapterConnected && hasDecodedLiveBattery {
            return .live
        }
        if demoTransportActive {
            return .demo
        }
        return .demo
    }
}

/// `ATCAF0` requests must include the ISO-TP length byte. Clones that reject hardware flow control need a `30 00 00` frame after a first frame.
public enum LeafELMFraming {
    public static let flowControl = "30 00 00"

    public static func pciPrefixed(_ dataHex: String) -> String {
        let bytes = dataHex.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !bytes.isEmpty, bytes.count <= 7, bytes.allSatisfy({ $0.count == 2 }) else {
            return dataHex.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(format: "%02X ", bytes.count) + bytes.joined(separator: " ")
    }

    public static func needsSoftwareFlowControl(_ raw: String) -> Bool {
        let frames = ISOTPAssembler().parseELMLines(raw)
        guard let first = frames.first, first.count >= 2 else { return false }
        let pciType = (first[0] & 0xF0) >> 4
        guard pciType == 0x1 else { return false }
        let total = (Int(first[0] & 0x0F) << 8) | Int(first[1])
        var got = max(0, first.count - 2)
        var expectedSeq: UInt8 = 1
        for frame in frames.dropFirst() {
            guard let pci = frame.first else { continue }
            let type = (pci & 0xF0) >> 4
            if type == 0x3 { continue }
            guard type == 0x2, (pci & 0x0F) == expectedSeq else { continue }
            got += max(0, frame.count - 1)
            expectedSeq = (expectedSeq + 1) & 0x0F
        }
        return got < total
    }
}

public enum ELMResponseRecovery {
    public static func containsCANFrames(_ raw: String) -> Bool {
        !ISOTPAssembler().parseELMLines(raw).isEmpty
    }
}

public enum OBDTrace {
    public static let capacity = 200

    public static func appending(_ lines: [String], stamp: String, direction: String, text: String) -> [String] {
        let flattened = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var next = lines
        next.append("\(stamp) \(direction) \(flattened)")
        if next.count > capacity {
            next.removeFirst(next.count - capacity)
        }
        return next
    }
}
