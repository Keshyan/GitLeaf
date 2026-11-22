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
