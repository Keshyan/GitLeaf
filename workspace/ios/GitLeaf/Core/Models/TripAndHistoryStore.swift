import Foundation

public struct SOHSnapshot: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let odometerKm: Int
    public let sohPct: Double
    public let hxPct: Double
    public let ahr: Double
    public let packTempC: Double
    /// False for session-only demo rows. Those rows are not written to the shared store.
    public let fromLiveAdapter: Bool

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        odometerKm: Int,
        sohPct: Double,
        hxPct: Double,
        ahr: Double,
        packTempC: Double,
        fromLiveAdapter: Bool = true
    ) {
        self.id = id
        self.date = date
        self.odometerKm = odometerKm
        self.sohPct = sohPct
        self.hxPct = hxPct
        self.ahr = ahr
        self.packTempC = packTempC
        self.fromLiveAdapter = fromLiveAdapter
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, odometerKm, sohPct, hxPct, ahr, packTempC, fromLiveAdapter
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        odometerKm = try container.decode(Int.self, forKey: .odometerKm)
        sohPct = try container.decode(Double.self, forKey: .sohPct)
        hxPct = try container.decode(Double.self, forKey: .hxPct)
        ahr = try container.decode(Double.self, forKey: .ahr)
        packTempC = try container.decode(Double.self, forKey: .packTempC)
        fromLiveAdapter = try container.decodeIfPresent(Bool.self, forKey: .fromLiveAdapter) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(odometerKm, forKey: .odometerKm)
        try container.encode(sohPct, forKey: .sohPct)
        try container.encode(hxPct, forKey: .hxPct)
        try container.encode(ahr, forKey: .ahr)
        try container.encode(packTempC, forKey: .packTempC)
        try container.encode(fromLiveAdapter, forKey: .fromLiveAdapter)
    }
}

public struct TripRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let distanceKm: Double
    public let startSocPct: Double
    public let endSocPct: Double
    public let energyUsedKwh: Double
    public let regenKwh: Double
    public let ambientTempC: Double
    /// True when distance came from the kWh fallback rather than an odometer delta.
    public let distanceIsEstimated: Bool
    /// False for demo trips. Those trips stay in memory and are not written to the shared store.
    public let fromLiveAdapter: Bool

    public var whPerKm: Double {
        guard distanceKm > 0.05 else { return 0 }
        return ((energyUsedKwh * 1000.0) / distanceKm).rounded()
    }

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        distanceKm: Double,
        startSocPct: Double,
        endSocPct: Double,
        energyUsedKwh: Double,
        regenKwh: Double,
        ambientTempC: Double,
        distanceIsEstimated: Bool = false,
        fromLiveAdapter: Bool = true
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceKm = distanceKm
        self.startSocPct = startSocPct
        self.endSocPct = endSocPct
        self.energyUsedKwh = energyUsedKwh
        self.regenKwh = regenKwh
        self.ambientTempC = ambientTempC
        self.distanceIsEstimated = distanceIsEstimated
        self.fromLiveAdapter = fromLiveAdapter
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, distanceKm, startSocPct, endSocPct
        case energyUsedKwh, regenKwh, ambientTempC, distanceIsEstimated, fromLiveAdapter
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        distanceKm = try container.decode(Double.self, forKey: .distanceKm)
        startSocPct = try container.decode(Double.self, forKey: .startSocPct)
        endSocPct = try container.decode(Double.self, forKey: .endSocPct)
        energyUsedKwh = try container.decode(Double.self, forKey: .energyUsedKwh)
        regenKwh = try container.decode(Double.self, forKey: .regenKwh)
        ambientTempC = try container.decode(Double.self, forKey: .ambientTempC)
        distanceIsEstimated = try container.decodeIfPresent(Bool.self, forKey: .distanceIsEstimated) ?? false
        fromLiveAdapter = try container.decodeIfPresent(Bool.self, forKey: .fromLiveAdapter) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(distanceKm, forKey: .distanceKm)
        try container.encode(startSocPct, forKey: .startSocPct)
        try container.encode(endSocPct, forKey: .endSocPct)
        try container.encode(energyUsedKwh, forKey: .energyUsedKwh)
        try container.encode(regenKwh, forKey: .regenKwh)
        try container.encode(ambientTempC, forKey: .ambientTempC)
        try container.encode(distanceIsEstimated, forKey: .distanceIsEstimated)
        try container.encode(fromLiveAdapter, forKey: .fromLiveAdapter)
    }
}

/// First launch has no SOH history. Missing or empty storage stays empty.
public enum SOHHistoryLoader {
    public static func initial(persisted: [SOHSnapshot]?) -> [SOHSnapshot] {
        guard let persisted, !persisted.isEmpty else { return [] }
        return persisted
    }
}

public enum TelemetryPersistencePolicy {
    /// Simulator and demo samples are never written into the shared history,
    /// including while a real adapter is the active connection.
    public static func shouldPersistToHistory(sourceIsLiveAdapter: Bool, realAdapterActive: Bool) -> Bool {
        sourceIsLiveAdapter && realAdapterActive
    }
}

public struct TripDistanceResult: Equatable, Sendable {
    public let distanceKm: Double
    public let isEstimated: Bool

    public init(distanceKm: Double, isEstimated: Bool) {
        self.distanceKm = distanceKm
        self.isEstimated = isEstimated
    }
}

public enum TripMetrics {
    /// Metered pack-energy drop. Does not add a synthetic demo kWh bonus.
    public static func energyUsedKwh(startRemaining: Double, endRemaining: Double) -> Double {
        let used = max(0, startRemaining - endRemaining)
        return (used * 100).rounded() / 100
    }

    public static func regenKwh(startRemaining: Double, endRemaining: Double) -> Double {
        let regen = max(0, endRemaining - startRemaining)
        return (regen * 100).rounded() / 100
    }

    /// Prefer an odometer delta when a live reading exists. Otherwise estimate
    /// kilometres from consumed kWh at 155 Wh/km and mark the result estimated.
    public static func distanceKm(
        startOdometerKm: Int?,
        endOdometerKm: Int?,
        energyUsedKwh: Double,
        odometerAvailable: Bool
    ) -> TripDistanceResult {
        if odometerAvailable,
           let start = startOdometerKm,
           let end = endOdometerKm,
           end >= start {
            let km = Double(end - start)
            return TripDistanceResult(distanceKm: (km * 10).rounded() / 10, isEstimated: false)
        }
        let estimated = max(0, (max(0, energyUsedKwh) * 1000.0) / 155.0)
        return TripDistanceResult(distanceKm: (estimated * 10).rounded() / 10, isEstimated: true)
    }
}

public enum TelemetryExporter {
    public static func tripsToCSV(_ trips: [TripRecord]) -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["started_at,ended_at,distance_km,start_soc_pct,end_soc_pct,energy_used_kwh,regen_kwh,wh_per_km,ambient_temp_c"]
        for t in trips {
            lines.append(
                "\(iso.string(from: t.startedAt)),\(iso.string(from: t.endedAt)),\(String(format: "%.2f", t.distanceKm)),\(String(format: "%.1f", t.startSocPct)),\(String(format: "%.1f", t.endSocPct)),\(String(format: "%.3f", t.energyUsedKwh)),\(String(format: "%.3f", t.regenKwh)),\(String(format: "%.0f", t.whPerKm)),\(String(format: "%.1f", t.ambientTempC))"
            )
        }
        return lines.joined(separator: "\n")
    }

    public static func abrpJSON(battery: LeafBatterySummary, temps: LeafThermistors, vcm: LeafVCMState) -> String {
        let payload: [String: Any] = [
            "utc": Int(Date().timeIntervalSince1970),
            "soc": battery.realSocPct,
            "soh": battery.sohPct,
            "power": battery.powerKw,
            "speed": vcm.speedKmh,
            "is_charging": battery.powerKw < -1.0 && vcm.gear.uppercased() == "P",
            "batt_temp": temps.avgC,
            "ext_temp": vcm.ambientTempC,
            "odometer": vcm.odometerKm
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
