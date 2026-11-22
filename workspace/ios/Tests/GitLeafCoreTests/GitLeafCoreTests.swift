import XCTest
@testable import GitLeafCore

final class GitLeafCoreTests: XCTestCase {
    func testAdapterCatalogMatchesPopularBLEAdapters() {
        XCTAssertEqual(AdapterCatalog.matchBLE(name: "VEEPEAK", serviceUUIDs: [])?.id, "veepeak_ble")
        XCTAssertEqual(AdapterCatalog.matchBLE(name: "OBDLink CX", serviceUUIDs: [])?.id, "obdlink_cx")
        XCTAssertEqual(AdapterCatalog.matchBLE(name: "IOS-Vlink", serviceUUIDs: [])?.id, "vgate_icar_vlinker")
        XCTAssertEqual(AdapterCatalog.matchBLE(name: "LELink2", serviceUUIDs: [])?.id, "lelink2")
        XCTAssertEqual(AdapterCatalog.matchBLE(name: nil, serviceUUIDs: ["6E400001-B5A3-F393-E0A9-E50E24DCCA9E"])?.id, "generic_ble")
    }

    func testISOTPSingleFrameAssembly() throws {
        let assembler = ISOTPAssembler()
        let payload = try assembler.assemble(rawELMResponse: "765 06 61 0E 90 91 8E 7C 00\r\n>", expectedRxID: 0x765)
        let tpms = LeafCANParser.decodeTPMS(payload)
        XCTAssertEqual(tpms?.flPsi, 36.0)
        XCTAssertEqual(tpms?.rrPsi, 31.0)
    }

    func testSafetyInterlockBlocksWhileDriving() {
        let interlock = SafetyInterlock()
        let driving = LeafVCMState(speedKmh: 45.0, gear: "D", ambientTempC: 12.0, odometerKm: 50_000, climateKw: 0.5)
        XCTAssertThrowsError(try interlock.authorize(command: .clearDTCs, vcm: driving, readOnlyMode: false, userConfirmed: true))
    }

    func testWinterThermistorsAndShuntDecoding() {
        // 4 thermistors: -4, -2, -3, -5 C (signed two's complement) + heater active
        let tempPayload: [UInt8] = [
            0x61, 0x04,
            0x02, 0x10, 0xFC,
            0x02, 0x10, 0xFE,
            0x02, 0x10, 0xFD,
            0x02, 0x10, 0xFB,
            0x01
        ]
        let temps = LeafCANParser.decodeLBCGroup4Temps(tempPayload)
        XCTAssertEqual(temps?.minC, -5.0)
        XCTAssertEqual(temps?.maxC, -2.0)
        XCTAssertEqual(temps?.heaterActive, true)

        var shuntPayload: [UInt8] = [0x61, 0x06] + Array(repeating: 0x00, count: 24)
        shuntPayload[2] = 0x05 // cells 1 & 3 balancing
        let shunts = LeafCANParser.decodeLBCGroup6Shunts(shuntPayload)
        XCTAssertEqual(shunts.count, 96)
        XCTAssertEqual(shunts.filter { $0 }.count, 2)
    }

    func testCSVExportFormatsTripHeaderAndRows() {
        let now = Date()
        let trip = TripRecord(
            startedAt: now.addingTimeInterval(-1800),
            endedAt: now,
            distanceKm: 24.5,
            startSocPct: 80.0,
            endSocPct: 68.5,
            energyUsedKwh: 3.8,
            regenKwh: 0.65,
            ambientTempC: 14.0
        )
        let csv = TelemetryExporter.tripsToCSV([trip])
        XCTAssertTrue(csv.contains("started_at,ended_at,distance_km"))
        XCTAssertTrue(csv.contains("24.50,80.0,68.5"))
    }
}
