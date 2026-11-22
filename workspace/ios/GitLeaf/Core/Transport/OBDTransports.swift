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

public enum OBDTransportError: Error, LocalizedError, Sendable {
    case bluetoothUnavailable
    case adapterNotFound
    case notConnected
    case timeout
    case invalidEndpoint
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: return "Bluetooth is powered off or unauthorized."
        case .adapterNotFound: return "No compatible OBD2 adapter found nearby."
        case .notConnected: return "OBD2 adapter is not connected."
        case .timeout: return "OBD2 adapter response timed out."
        case .invalidEndpoint: return "Wi-Fi OBD2 port is invalid."
        case .connectionFailed(let message): return message
        }
    }
}

/// Resumes a continuation at most once. Transport callbacks and timeouts race.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var finished = false
    var onResume: (@Sendable () -> Void)?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: T) -> Bool {
        finish { $0.resume(returning: value) }
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        finish { $0.resume(throwing: error) }
    }

    private func finish(_ body: (CheckedContinuation<T, Error>) -> Void) -> Bool {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return false
        }
        finished = true
        self.continuation = nil
        let callback = onResume
        onResume = nil
        lock.unlock()
        body(continuation)
        callback?()
        return true
    }
}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    timeoutError: OBDTransportError = .timeout,
    _ start: @escaping (@escaping (Result<T, Error>) -> Void) -> Void
) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let gate = ResumeOnce(cont)
        let sleeper = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            gate.resume(throwing: timeoutError)
        }
        gate.onResume = { sleeper.cancel() }
        start { result in
            switch result {
            case .success(let value):
                gate.resume(returning: value)
            case .failure(let error):
                gate.resume(throwing: error)
            }
        }
    }
}

private func withVoidTimeout(
    seconds: TimeInterval,
    timeoutError: OBDTransportError = .timeout,
    _ start: @escaping (@escaping (Result<Void, Error>) -> Void) -> Void
) async throws {
    try await withTimeout(seconds: seconds, timeoutError: timeoutError, start)
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
    private var connectFinish: ((Result<Void, Error>) -> Void)?
    private var responseFinish: ((Result<String, Error>) -> Void)?
    private var commandExchange = ELMCommandExchange(startedAt: .distantPast)
    private var acceptingResponse = false
    private var connectOpen = false
    private let ioLock = NSLock()
    private let bleQueue = DispatchQueue(label: "gitleaf.ble")

    public func connect() async throws {
        connectOpen = true
        do {
            try await withTimeout(seconds: OBDTiming.scanTimeoutSeconds, timeoutError: .adapterNotFound) { finish in
                self.connectFinish = finish
                self.central = CBCentralManager(delegate: self, queue: self.bleQueue)
            }
            connectOpen = false
        } catch {
            connectOpen = false
            connectFinish = nil
            central?.stopScan()
            disconnect()
            throw error
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
        do {
            return try await withTimeout(seconds: OBDTiming.commandTimeoutSeconds) { finish in
                self.ioLock.lock()
                self.commandExchange = ELMCommandExchange(startedAt: Date())
                self.acceptingResponse = true
                self.responseFinish = { result in
                    self.ioLock.lock()
                    self.acceptingResponse = false
                    self.responseFinish = nil
                    self.ioLock.unlock()
                    finish(result)
                }
                self.ioLock.unlock()
                let writeType: CBCharacteristicWriteType = tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                p.writeValue(payload, for: tx, type: writeType)
            }
        } catch {
            clearPendingResponse()
            throw error
        }
    }

    private func clearPendingResponse() {
        ioLock.lock()
        acceptingResponse = false
        responseFinish = nil
        ioLock.unlock()
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard connectOpen else { return }
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: Self.knownServiceUUIDs, options: nil)
        } else if central.state == .poweredOff || central.state == .unauthorized || central.state == .unsupported {
            finishConnect(.failure(OBDTransportError.bluetoothUnavailable))
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard connectOpen else { return }
        let advUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString } ?? []
        guard AdapterCatalog.matchBLE(name: peripheral.name, serviceUUIDs: advUUIDs) != nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        self.name = peripheral.name ?? "BLE OBD2 Adapter"
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard connectOpen else { return }
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
        if connectOpen && txChar != nil && rxChar != nil && !isConnected {
            isConnected = true
            finishConnect(.success(()))
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            deliverResponse(.failure(error))
            return
        }
        guard let data = characteristic.value else { return }
        let chunk = String(decoding: data, as: UTF8.self)
        ioLock.lock()
        guard acceptingResponse else {
            ioLock.unlock()
            return
        }
        let exchanged = commandExchange.ingest(chunk, now: Date())
        ioLock.unlock()
        switch exchanged {
        case .pending:
            break
        case .complete(let text):
            deliverResponse(.success(text))
        case .timedOut:
            deliverResponse(.failure(OBDTransportError.timeout))
        }
    }

    private func finishConnect(_ result: Result<Void, Error>) {
        let finish = connectFinish
        connectFinish = nil
        finish?(result)
    }

    private func deliverResponse(_ result: Result<String, Error>) {
        ioLock.lock()
        let finish = responseFinish
        acceptingResponse = false
        responseFinish = nil
        ioLock.unlock()
        finish?(result)
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
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw OBDTransportError.invalidEndpoint
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.connection = conn
        do {
            try await withVoidTimeout(
                seconds: OBDTiming.connectTimeoutSeconds,
                timeoutError: .connectionFailed("Timed out waiting for the Wi-Fi adapter to become ready.")
            ) { finish in
                conn.stateUpdateHandler = { state in
                    let decision = OBDConnectionWatch.decide(OBDConnectionWatch.phase(for: Self.event(for: state)))
                    switch decision {
                    case .keepWaiting:
                        return
                    case .connected:
                        finish(.success(()))
                    case .failed(let message):
                        finish(.failure(OBDTransportError.connectionFailed(message)))
                    }
                }
                conn.start(queue: .global(qos: .userInitiated))
            }
            conn.stateUpdateHandler = nil
            isConnected = true
        } catch {
            conn.stateUpdateHandler = nil
            conn.cancel()
            connection = nil
            isConnected = false
            throw error
        }
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    public func sendCommand(_ command: String) async throws -> String {
        guard let conn = connection, isConnected else {
            throw OBDTransportError.notConnected
        }
        let started = Date()
        let payload = Data((command + "\r").utf8)
        let budget = OBDTiming.commandTimeoutSeconds
        try await transmit(conn, payload, timeoutSeconds: budget)
        var exchange = ELMCommandExchange(timeoutSeconds: budget, startedAt: started)
        while true {
            let remaining = budget - Date().timeIntervalSince(started)
            if remaining <= 0 {
                throw OBDTransportError.timeout
            }
            let chunk = try await receiveChunk(conn, timeoutSeconds: remaining)
            switch exchange.ingest(chunk, now: Date()) {
            case .complete(let text):
                return text
            case .timedOut:
                throw OBDTransportError.timeout
            case .pending:
                continue
            }
        }
    }

    private func transmit(_ conn: NWConnection, _ data: Data, timeoutSeconds: TimeInterval) async throws {
        try await withVoidTimeout(seconds: timeoutSeconds) { finish in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success(()))
                }
            })
        }
    }

    private func receiveChunk(_ conn: NWConnection, timeoutSeconds: TimeInterval) async throws -> String {
        try await withTimeout(seconds: timeoutSeconds) { finish in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error {
                    finish(.failure(error))
                    return
                }
                let text = String(decoding: data ?? Data(), as: UTF8.self)
                if text.isEmpty && isComplete {
                    finish(.failure(OBDTransportError.notConnected))
                    return
                }
                finish(.success(text))
            }
        }
    }

    private static func event(for state: NWConnection.State) -> OBDConnectionEvent {
        switch state {
        case .setup:
            return .setup
        case .waiting(let error):
            return .waiting(error.localizedDescription)
        case .preparing:
            return .preparing
        case .ready:
            return .ready
        case .failed(let error):
            return .failed(error.localizedDescription)
        case .cancelled:
            return .cancelled
        @unknown default:
            return .setup
        }
    }
}
#endif

#if canImport(ExternalAccessory) && os(iOS)
/// Serial thread that owns the ExternalAccessory streams and their run loop.
private final class MFiIOThread: Thread {
    private let lock = NSLock()
    private var jobs: [() -> Void] = []

    func enqueue(_ job: @escaping () -> Void) {
        lock.lock()
        jobs.append(job)
        lock.unlock()
    }

    override func main() {
        RunLoop.current.add(Port(), forMode: .default)
        while !isCancelled {
            lock.lock()
            let batch = jobs
            jobs.removeAll()
            lock.unlock()
            for job in batch {
                job()
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}

/// Apple MFi Classic Bluetooth Transport for OBDLink MX+ / LX (`com.obdlink.protocol`).
public final class MFiOBDTransport: OBDTransport {
    public let name = "OBDLink MX+ (MFi)"
    public private(set) var isConnected = false
    private var session: EASession?
    private let protocolString = "com.obdlink.protocol"
    private let ioThread = MFiIOThread()

    public init() {
        ioThread.start()
    }

    deinit {
        session?.inputStream?.close()
        session?.outputStream?.close()
        session = nil
        ioThread.cancel()
    }

    public func connect() async throws {
        let accessories = EAAccessoryManager.shared().connectedAccessories
        guard let acc = accessories.first(where: { $0.protocolStrings.contains(protocolString) }) else {
            throw OBDTransportError.adapterNotFound
        }
        try await withVoidTimeout(
            seconds: OBDTiming.connectTimeoutSeconds,
            timeoutError: .adapterNotFound
        ) { finish in
            self.ioThread.enqueue {
                guard let eaSession = EASession(accessory: acc, forProtocol: self.protocolString),
                      let input = eaSession.inputStream,
                      let output = eaSession.outputStream else {
                    finish(.failure(OBDTransportError.adapterNotFound))
                    return
                }
                input.schedule(in: .current, forMode: .default)
                output.schedule(in: .current, forMode: .default)
                input.open()
                output.open()
                self.session = eaSession
                self.isConnected = true
                finish(.success(()))
            }
        }
    }

    public func disconnect() {
        isConnected = false
        ioThread.enqueue { [weak self] in
            self?.session?.inputStream?.close()
            self?.session?.outputStream?.close()
            self?.session = nil
        }
    }

    public func sendCommand(_ command: String) async throws -> String {
        guard isConnected else { throw OBDTransportError.notConnected }
        let bytes = Array((command + "\r").utf8)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.ioThread.enqueue {
                guard let out = self.session?.outputStream, let inp = self.session?.inputStream else {
                    cont.resume(throwing: OBDTransportError.notConnected)
                    return
                }
                let deadline = Date().addingTimeInterval(OBDTiming.commandTimeoutSeconds)
                var offset = 0
                while offset < bytes.count {
                    if Date() >= deadline {
                        cont.resume(throwing: OBDTransportError.timeout)
                        return
                    }
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                    guard out.hasSpaceAvailable else { continue }
                    let remaining = bytes[offset...]
                    let written = remaining.withUnsafeBytes { raw -> Int in
                        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                        return out.write(base, maxLength: bytes.count - offset)
                    }
                    if written <= 0 {
                        cont.resume(throwing: OBDTransportError.connectionFailed("MFi write failed."))
                        return
                    }
                    offset += written
                }

                var exchange = ELMCommandExchange(startedAt: Date())
                var scratch = [UInt8](repeating: 0, count: 1024)
                while true {
                    if Date() >= deadline {
                        cont.resume(throwing: OBDTransportError.timeout)
                        return
                    }
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                    guard inp.hasBytesAvailable else { continue }
                    let readCount = inp.read(&scratch, maxLength: scratch.count)
                    if readCount < 0 {
                        cont.resume(throwing: OBDTransportError.connectionFailed("MFi read failed."))
                        return
                    }
                    guard readCount > 0 else { continue }
                    let chunk = String(bytes: scratch.prefix(readCount), encoding: .utf8) ?? ""
                    switch exchange.ingest(chunk, now: Date()) {
                    case .complete(let text):
                        cont.resume(returning: text)
                        return
                    case .timedOut:
                        cont.resume(throwing: OBDTransportError.timeout)
                        return
                    case .pending:
                        continue
                    }
                }
            }
        }
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
    private var activeTripStartOdometer: Int?
    private var activeTripStartedLive = false
    private var hasLiveBattery = false
    private var hasLiveOdometer = false
    private var pollTail: Task<Void, Never>?

    private let simulator = VirtualLeafTransport()
    private var activeTransport: OBDTransport?
    private var pollingTask: Task<Void, Never>?
    private let interlock = SafetyInterlock()
    private let assembler = ISOTPAssembler()
    private var demoTick: Int = 0

    private var isRealAdapterConnected: Bool {
        activeTransport != nil && !(activeTransport is VirtualLeafTransport)
    }

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
        let persistedSOH: [SOHSnapshot]?
        if let data = UserDefaults.standard.data(forKey: sohStoreKey) {
            persistedSOH = try? JSONDecoder().decode([SOHSnapshot].self, from: data)
        } else {
            persistedSOH = nil
        }
        self.sohHistory = SOHHistoryLoader.initial(persisted: persistedSOH)
        if let data = UserDefaults.standard.data(forKey: tripStoreKey),
           let decoded = try? JSONDecoder().decode([TripRecord].self, from: data) {
            self.trips = decoded
        }
    }

    private func persistHistory() {
        let durableSOH = sohHistory.filter(\.fromLiveAdapter)
        let durableTrips = trips.filter(\.fromLiveAdapter)
        if let data = try? JSONEncoder().encode(durableSOH) {
            UserDefaults.standard.set(data, forKey: sohStoreKey)
        }
        if let data = try? JSONEncoder().encode(durableTrips) {
            UserDefaults.standard.set(data, forKey: tripStoreKey)
        }
    }

    public func logSOHSnapshot() {
        let liveSample = hasLiveBattery && isRealAdapterConnected
        guard TelemetryPersistencePolicy.shouldPersistToHistory(
            sourceIsLiveAdapter: liveSample,
            realAdapterActive: isRealAdapterConnected
        ) else {
            statusBanner = "SOH history is recorded from a live adapter, not demo data."
            return
        }
        let snap = SOHSnapshot(
            odometerKm: hasLiveOdometer ? vcm.odometerKm : 0,
            sohPct: battery.sohPct,
            hxPct: battery.hxPct,
            ahr: battery.ahr,
            packTempC: temps.avgC,
            fromLiveAdapter: true
        )
        sohHistory.append(snap)
        persistHistory()
        statusBanner = "SOH snapshot saved."
    }

    public func toggleTripRecording() {
        if isRecordingTrip {
            finishActiveTrip()
        } else {
            activeTripStartDate = Date()
            activeTripStartSoc = battery.realSocPct
            activeTripStartKwh = battery.remainingKwh
            activeTripStartedLive = isRealAdapterConnected && hasLiveBattery
            activeTripStartOdometer = (activeTripStartedLive && hasLiveOdometer) ? vcm.odometerKm : nil
            isRecordingTrip = true
        }
    }

    private func finishActiveTrip() {
        let endedAt = Date()
        let startedAt = activeTripStartDate ?? endedAt
        let startedLive = activeTripStartedLive
        let stillLive = isRealAdapterConnected && hasLiveBattery
        if startedLive != stillLive {
            isRecordingTrip = false
            activeTripStartedLive = false
            statusBanner = "Trip discarded so demo data is not mixed into live history."
            return
        }
        let used = TripMetrics.energyUsedKwh(startRemaining: activeTripStartKwh, endRemaining: battery.remainingKwh)
        let regen = TripMetrics.regenKwh(startRemaining: activeTripStartKwh, endRemaining: battery.remainingKwh)
        let distance = TripMetrics.distanceKm(
            startOdometerKm: activeTripStartOdometer,
            endOdometerKm: vcm.odometerKm,
            energyUsedKwh: used,
            odometerAvailable: startedLive && hasLiveOdometer && activeTripStartOdometer != nil
        )
        let record = TripRecord(
            startedAt: startedAt,
            endedAt: endedAt,
            distanceKm: distance.distanceKm,
            startSocPct: activeTripStartSoc,
            endSocPct: battery.realSocPct,
            energyUsedKwh: used,
            regenKwh: regen,
            ambientTempC: vcm.ambientTempC,
            distanceIsEstimated: distance.isEstimated,
            fromLiveAdapter: startedLive
        )
        trips.insert(record, at: 0)
        isRecordingTrip = false
        activeTripStartedLive = false
        if TelemetryPersistencePolicy.shouldPersistToHistory(
            sourceIsLiveAdapter: startedLive,
            realAdapterActive: stillLive
        ) {
            persistHistory()
        }
    }

    public func disconnect() {
        if isRecordingTrip {
            finishActiveTrip()
        }
        pollingTask?.cancel()
        pollingTask = nil
        activeTransport?.disconnect()
        activeTransport = nil
        isConnected = false
        isPolling = false
        hasLiveBattery = false
        hasLiveOdometer = false
        adapterWarning = nil
        statusBanner = "Disconnected — Ready"
    }

    private func invalidateSimulatedVehicleState() {
        hasLiveBattery = false
        hasLiveOdometer = false
        vcm = LeafVCMState(speedKmh: 0, gear: "?", ambientTempC: 0, odometerKm: 0, climateKw: 0)
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
                invalidateSimulatedVehicleState()
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
                invalidateSimulatedVehicleState()
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
                invalidateSimulatedVehicleState()
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
        } else if !cfc.contains("?") && !fcsm.contains("?") && !elm.uppercased().contains("V2.1") {
            adapterTier = .elm327v15
        } else {
            adapterTier = .elm327CloneV21
        }
        adapterWarning = AdapterPollSchedule.cloneWarning(for: adapterTier)
    }

    public func startLivePolling() {
        pollingTask?.cancel()
        isPolling = true
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isConnected else { break }
                await self.pollOnce()
                let interval = AdapterPollSchedule.intervalSeconds(for: self.adapterTier)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func pollOnce() async {
        let previous = pollTail
        let next = Task { @MainActor [weak self] in
            _ = await previous?.value
            await self?.performPoll()
        }
        pollTail = next
        await next.value
    }

    private func performPoll() async {
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
            self.hasLiveBattery = false
            self.hasLiveOdometer = false
            return
        }

        let start = Date()
        lastPollFailed = false
        var sawLive = false

        if await query(transport, "ATSH 79B") != nil {
            if let rawG1 = await query(transport, "21 01"),
               let g1Bytes = try? assembler.assemble(rawELMResponse: rawG1, expectedRxID: 0x7BB),
               let summary = LeafCANParser.decodeLBCGroup1(g1Bytes, generation: selectedGeneration) {
                self.battery = summary
                self.hasLiveBattery = true
                sawLive = true
            }

            let shunts: [Bool]
            if let rawG6 = await query(transport, "21 06"),
               let g6Bytes = try? assembler.assemble(rawELMResponse: rawG6, expectedRxID: 0x7BB) {
                shunts = LeafCANParser.decodeLBCGroup6Shunts(g6Bytes)
            } else {
                shunts = []
            }

            if let rawG2 = await query(transport, "21 02"),
               let g2Bytes = try? assembler.assemble(rawELMResponse: rawG2, expectedRxID: 0x7BB),
               let cellPack = LeafCANParser.decodeLBCGroup2Cells(g2Bytes, shunts: shunts) {
                self.cells = cellPack
                sawLive = true
            }

            if let rawG4 = await query(transport, "21 04"),
               let g4Bytes = try? assembler.assemble(rawELMResponse: rawG4, expectedRxID: 0x7BB),
               let therm = LeafCANParser.decodeLBCGroup4Temps(g4Bytes) {
                self.temps = therm
                sawLive = true
            }

            if let rawDTC = await query(transport, "19 02 FF"),
               let dtcBytes = try? assembler.assemble(rawELMResponse: rawDTC, expectedRxID: 0x7BB) {
                self.dtcs = LeafCANParser.decodeUDSDTCs(dtcBytes, ecu: "LBC")
                sawLive = true
            }
        }

        if await query(transport, "ATSH 745") != nil,
           let rawTPMS = await query(transport, "21 0E"),
           let tpmsBytes = try? assembler.assemble(rawELMResponse: rawTPMS, expectedRxID: 0x765),
           let parsedTpms = LeafCANParser.decodeTPMS(tpmsBytes) {
            self.tpms = parsedTpms
            sawLive = true
        }

        if await pollVehicleState(on: transport) {
            sawLive = true
        }

        if sawLive {
            self.latencyMs = max(1, Int(Date().timeIntervalSince(start) * 1000))
        }
        if !lastPollFailed && sawLive && statusBanner.hasPrefix("Poll error:") {
            statusBanner = "Connected to \(transport.name)"
        }
    }

    private var lastPollFailed = false

    private func query(_ transport: OBDTransport, _ command: String) async -> String? {
        do {
            return try await transport.sendCommand(command)
        } catch {
            lastPollFailed = true
            statusBanner = "Poll error: \(error.localizedDescription)"
            return nil
        }
    }

    /// VCM speed, gear, and ambient (`0x797`), plus cluster odometer (`0x743`).
    private func pollVehicleState(on transport: OBDTransport) async -> Bool {
        var gear = vcm.gear
        var speed = vcm.speedKmh
        var ambient = vcm.ambientTempC
        var odometer = vcm.odometerKm
        let climate = vcm.climateKw
        var updated = false

        if await query(transport, LeafVehicleQuery.vcmTxHeader) != nil {
            if let raw = await query(transport, LeafVehicleQuery.gear),
               let bytes = try? assembler.assemble(rawELMResponse: raw, expectedRxID: LeafVehicleQuery.vcmRxID),
               let decoded = LeafCANParser.decodeVCMGear(bytes) {
                gear = decoded
                updated = true
            }
            if let raw = await query(transport, LeafVehicleQuery.speed),
               let bytes = try? assembler.assemble(rawELMResponse: raw, expectedRxID: LeafVehicleQuery.vcmRxID),
               let decoded = LeafCANParser.decodeVCMSpeedKmh(bytes) {
                speed = decoded
                updated = true
            }
            if let raw = await query(transport, LeafVehicleQuery.ambient),
               let bytes = try? assembler.assemble(rawELMResponse: raw, expectedRxID: LeafVehicleQuery.vcmRxID),
               let decoded = LeafCANParser.decodeVCMAmbientC(bytes) {
                ambient = decoded
                updated = true
            }
        }

        if await query(transport, LeafVehicleQuery.meterTxHeader) != nil,
           let raw = await query(transport, LeafVehicleQuery.odometer),
           let bytes = try? assembler.assemble(rawELMResponse: raw, expectedRxID: LeafVehicleQuery.meterRxID),
           let decoded = LeafCANParser.decodeOdometerKm(bytes) {
            odometer = decoded
            hasLiveOdometer = true
            updated = true
        }

        if updated {
            vcm = LeafVCMState(
                speedKmh: speed,
                gear: gear,
                ambientTempC: ambient,
                odometerKm: odometer,
                climateKw: climate
            )
        }
        return updated
    }

    public func refreshTelemetry() {
        if isRealAdapterConnected {
            Task { await self.pollOnce() }
        } else {
            applySimulatorSnapshot()
        }
    }

    private func applySimulatorSnapshot() {
        let snap = simulator.sampleSnapshot(generation: selectedGeneration)
        self.battery = snap.0
        self.cells = snap.1
        self.temps = snap.2
        self.tpms = snap.3
        self.vcm = snap.4
        self.dtcs = snap.5
        self.hasLiveBattery = false
        self.hasLiveOdometer = false
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
                await pollOnce()
            } else {
                if command == .clearDTCs {
                    _ = try await simulator.sendCommand("14 FF FF FF")
                }
                applySimulatorSnapshot()
            }
            return .success("\(command.rawValue) completed safely.")
        } catch {
            return .failure(error)
        }
    }
}
