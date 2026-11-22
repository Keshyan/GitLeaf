import Foundation

public enum LeafGeneration: String, CaseIterable, Codable, Identifiable, Sendable {
    case ze0_24 = "ZE0_24"
    case aze0_24 = "AZE0_24"
    case aze0_30 = "AZE0_30"
    case ze1_40 = "ZE1_40"
    case ze1_62 = "ZE1_62"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ze0_24: return "Leaf ZE0 (24 kWh)"
        case .aze0_24: return "Leaf AZE0 (24 kWh)"
        case .aze0_30: return "Leaf AZE0 (30 kWh)"
        case .ze1_40: return "Leaf ZE1 (40 kWh)"
        case .ze1_62: return "Leaf ZE1 e+ (62 kWh)"
        }
    }

    public var nominalKwh: Double {
        switch self {
        case .ze0_24, .aze0_24: return 24.0
        case .aze0_30: return 30.0
        case .ze1_40: return 40.0
        case .ze1_62: return 62.0
        }
    }

    public var maxGids: Int {
        switch self {
        case .ze0_24, .aze0_24: return 281
        case .aze0_30: return 363
        case .ze1_40: return 502
        case .ze1_62: return 775
        }
    }

    public var whPerGid: Double { 77.5 }
}

public enum AdapterTransportKind: String, Codable, Sendable {
    case ble = "BLE 4.0/5.0"
    case wifiTCP = "Wi-Fi TCP"
    case mfiEA = "MFi Bluetooth"
    case virtual = "Virtual Demo"
}

public enum AdapterTier: String, Codable, Sendable {
    case stnPro = "STN Pro"
    case elm327v15 = "ELM327 v1.5"
    case elm327CloneV21 = "ELM327 Clone v2.1"
}

public struct AdapterSpec: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let transport: AdapterTransportKind
    public let expectedTier: AdapterTier
    public let bleNamePrefixes: [String]
    public let bleServiceUUIDs: [String]
    public let wifiHost: String?
    public let wifiPort: UInt16?
    public let mfiProtocol: String?
    public let notes: String

    public init(
        id: String,
        displayName: String,
        transport: AdapterTransportKind,
        expectedTier: AdapterTier,
        bleNamePrefixes: [String] = [],
        bleServiceUUIDs: [String] = [],
        wifiHost: String? = nil,
        wifiPort: UInt16? = nil,
        mfiProtocol: String? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.expectedTier = expectedTier
        self.bleNamePrefixes = bleNamePrefixes
        self.bleServiceUUIDs = bleServiceUUIDs
        self.wifiHost = wifiHost
        self.wifiPort = wifiPort
        self.mfiProtocol = mfiProtocol
        self.notes = notes
    }
}

public enum AdapterCatalog {
    public static let all: [AdapterSpec] = [
        AdapterSpec(
            id: "obdlink_cx",
            displayName: "OBDLink CX (BLE 5.1)",
            transport: .ble,
            expectedTier: .stnPro,
            bleNamePrefixes: ["OBDLink CX", "OBDLINK"],
            bleServiceUUIDs: ["FFF0"],
            notes: "STN2255 chip • Fast hardware CAN filters"
        ),
        AdapterSpec(
            id: "veepeak_ble",
            displayName: "Veepeak OBDCheck BLE / BLE+",
            transport: .ble,
            expectedTier: .elm327v15,
            bleNamePrefixes: ["VEEPEAK", "OBDCHECK"],
            bleServiceUUIDs: ["FFF0"],
            notes: "Popular iOS BLE adapter for Nissan Leaf"
        ),
        AdapterSpec(
            id: "vgate_icar_vlinker",
            displayName: "Vgate iCar Pro BLE 4.0 / vLinker MC+",
            transport: .ble,
            expectedTier: .stnPro,
            bleNamePrefixes: ["IOS-VLINK", "V-LINK", "VLINKER", "VGATE", "ICAR"],
            bleServiceUUIDs: ["18F0", "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2", "FFE0"],
            notes: "Supports 18F0 & ISSC/vLinker GATT profiles"
        ),
        AdapterSpec(
            id: "lelink2",
            displayName: "LELink / LELink² BLE",
            transport: .ble,
            expectedTier: .elm327v15,
            bleNamePrefixes: ["LELINK", "OBD BLE"],
            bleServiceUUIDs: ["FFE0"],
            notes: "Auto-sleep Leaf-friendly BLE adapter"
        ),
        AdapterSpec(
            id: "carista_ble",
            displayName: "Carista EVO / BLE",
            transport: .ble,
            expectedTier: .elm327v15,
            bleNamePrefixes: ["CARISTA"],
            bleServiceUUIDs: ["FFE0", "FFF0"],
            notes: "Standard BLE GATT adapter"
        ),
        AdapterSpec(
            id: "generic_ble",
            displayName: "Generic ELM327 BLE 4.0",
            transport: .ble,
            expectedTier: .elm327CloneV21,
            bleNamePrefixes: ["OBDII", "OBD2", "ELM327", "KONNWEI", "VPEAK"],
            bleServiceUUIDs: ["FFE0", "FFF0", "18F0", "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"],
            notes: "Auto-detects FFE0, FFF0, 18F0 & Nordic UART"
        ),
        AdapterSpec(
            id: "obdlink_mx_mfi",
            displayName: "OBDLink MX+ / LX (MFi)",
            transport: .mfiEA,
            expectedTier: .stnPro,
            mfiProtocol: "com.obdlink.protocol",
            notes: "Apple MFi STN2120 via ExternalAccessory"
        ),
        AdapterSpec(
            id: "wifi_elm327",
            displayName: "Wi-Fi ELM327 / Vgate / KONNWEI",
            transport: .wifiTCP,
            expectedTier: .elm327v15,
            wifiHost: "192.168.0.10",
            wifiPort: 35000,
            notes: "Standard TCP OBD2 socket"
        ),
        AdapterSpec(
            id: "virtual_leaf",
            displayName: "Virtual Leaf Demo Simulator",
            transport: .virtual,
            expectedTier: .stnPro,
            notes: "Explore all GitLeaf screens without a car"
        )
    ]

    public static func matchBLE(name: String?, serviceUUIDs: [String]) -> AdapterSpec? {
        let upperName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let uuidSet = Set(serviceUUIDs.map { $0.uppercased() })

        if !upperName.isEmpty {
            if let matched = all.first(where: { spec in
                spec.transport == .ble && spec.bleNamePrefixes.contains { prefix in
                    upperName.contains(prefix.uppercased())
                }
            }) {
                return matched
            }
        }
        return all.first(where: { spec in
            spec.transport == .ble && !uuidSet.isDisjoint(with: Set(spec.bleServiceUUIDs.map { $0.uppercased() }))
        })
    }
}

public struct LeafBatterySummary: Sendable {
    public let packVoltageV: Double
    public let packCurrentA: Double
    public let powerKw: Double
    public let hxPct: Double
    public let realSocPct: Double
    public let dashSocPct: Double
    public let ahr: Double
    public let sohPct: Double
    public let gids: Int
    public let remainingKwh: Double
    public let qcCount: Int
    public let l1L2Count: Int
}

public struct LeafCellPack: Sendable {
    public let voltagesMv: [Int]
    public let minMv: Int
    public let maxMv: Int
    public let avgMv: Double
    public let deltaMv: Int
    public let weakCellIndices: [Int]
    public let shuntActive: [Bool]
}

public struct LeafThermistors: Sendable {
    public let tempsC: [Double]
    public let minC: Double
    public let maxC: Double
    public let avgC: Double
    public let heaterActive: Bool
}

public struct LeafTPMS: Sendable {
    public let flPsi: Double
    public let frPsi: Double
    public let rlPsi: Double
    public let rrPsi: Double

    public func lowPressureWheels(thresholdPsi: Double = 32.0) -> [String] {
        [("FL", flPsi), ("FR", frPsi), ("RL", rlPsi), ("RR", rrPsi)]
            .filter { $0.1 < thresholdPsi }
            .map { $0.0 }
    }
}

public struct LeafVCMState: Sendable {
    public let speedKmh: Double
    public let gear: String
    public let ambientTempC: Double
    public let odometerKm: Int
    public let climateKw: Double
}

public struct DTCEntry: Identifiable, Sendable {
    public var id: String { "\(ecu)-\(code)" }
    public let ecu: String
    public let code: String
    public let statusByte: UInt8
    public let description: String
    public let severity: String
}

public enum ServiceCommandType: String, CaseIterable, Identifiable, Sendable {
    case clearDTCs = "Clear All DTCs"
    case toggleVSP = "Toggle VSP Pedestrian Sound"
    case setAutoDoorLock = "Configure Auto Door Lock"
    case setHeadlightDelay = "Set Headlight Off Delay"
    case registerTPMS = "Start TPMS Sensor Registration"

    public var id: String { rawValue }
}
