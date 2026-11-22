import Foundation

public struct SOHSnapshot: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let odometerKm: Int
    public let sohPct: Double
    public let hxPct: Double
    public let ahr: Double
    public let packTempC: Double

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        odometerKm: Int,
        sohPct: Double,
        hxPct: Double,
        ahr: Double,
        packTempC: Double
    ) {
        self.id = id
        self.date = date
        self.odometerKm = odometerKm
        self.sohPct = sohPct
        self.hxPct = hxPct
        self.ahr = ahr
        self.packTempC = packTempC
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
        ambientTempC: Double
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
