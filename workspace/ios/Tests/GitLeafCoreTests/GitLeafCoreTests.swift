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

    func testELMPromptAccumulationKeepsLaterISOFrames() throws {
        var accumulator = ELMResponseAccumulator()
        let first = "7BB 10 08 61 01 00 00 00 00\r\n"
        let rest = "7BB 21 11 22 00 00 00 00 00\r\n>"
        XCTAssertNil(accumulator.append(first))
        XCTAssertFalse(first.contains(">"))
        let complete = try XCTUnwrap(accumulator.append(rest))
        XCTAssertTrue(complete.hasSuffix(">"))
        XCTAssertTrue(complete.contains("7BB 21"))

        let assembler = ISOTPAssembler()
        XCTAssertThrowsError(try assembler.assemble(rawELMResponse: first, expectedRxID: 0x7BB))
        let payload = try assembler.assemble(rawELMResponse: complete, expectedRxID: 0x7BB)
        XCTAssertEqual(payload.count, 8)
        XCTAssertEqual(payload[6], 0x11)
        XCTAssertEqual(payload[7], 0x22)
    }

    func testELMCommandExchangeTimesOutWithoutPrompt() {
        let start = Date(timeIntervalSince1970: 1_000)
        var pending = ELMCommandExchange(timeoutSeconds: OBDTiming.commandTimeoutSeconds, startedAt: start)
        XCTAssertEqual(pending.ingest("7BB 10 08", now: start.addingTimeInterval(1)), .pending)
        XCTAssertEqual(pending.ingest("7BB 21", now: start.addingTimeInterval(OBDTiming.commandTimeoutSeconds)), .timedOut)

        var finished = ELMCommandExchange(timeoutSeconds: OBDTiming.commandTimeoutSeconds, startedAt: start)
        let result = finished.ingest("OK\r\n>", now: start.addingTimeInterval(OBDTiming.commandTimeoutSeconds))
        guard case .complete(let text) = result else {
            return XCTFail("Prompt at the deadline should complete the exchange")
        }
        XCTAssertTrue(text.contains(">"))
        XCTAssertEqual(OBDTiming.commandTimeoutSeconds, 8)
    }

    func testWiFiLinkIsConnectedOnlyAfterReady() {
        XCTAssertEqual(OBDConnectionWatch.decide(OBDConnectionWatch.phase(for: .setup)), .keepWaiting)
        XCTAssertEqual(OBDConnectionWatch.decide(OBDConnectionWatch.phase(for: .preparing)), .keepWaiting)
        XCTAssertEqual(OBDConnectionWatch.decide(OBDConnectionWatch.phase(for: .waiting("unreachable"))), .keepWaiting)
        XCTAssertEqual(OBDConnectionWatch.decide(OBDConnectionWatch.phase(for: .ready)), .connected)
        XCTAssertEqual(
            OBDConnectionWatch.decide(OBDConnectionWatch.phase(for: .failed("Connection refused"))),
            .failed("Connection refused")
        )
        XCTAssertEqual(OBDTiming.connectTimeoutSeconds, 10)
    }

    func testVCMGearSpeedAmbientAndOdometerParsing() throws {
        let assembler = ISOTPAssembler()
        let gear = try assembler.assemble(rawELMResponse: "79A 04 62 11 56 04 00 00 00\r\n>", expectedRxID: 0x79A)
        XCTAssertEqual(LeafCANParser.decodeVCMGear(gear), Optional("D"))
        XCTAssertNil(LeafCANParser.decodeVCMGear([0x62, 0x11, 0x56, 0x00]))
        XCTAssertEqual(LeafCANParser.decodeVCMGear([0x62, 0x11, 0x56, 0x01]), Optional("P"))

        let speed = try assembler.assemble(rawELMResponse: "79A 05 62 12 1A 01 6D 00 00\r\n>", expectedRxID: 0x79A)
        XCTAssertEqual(try XCTUnwrap(LeafCANParser.decodeVCMSpeedKmh(speed)), 36.5)

        let ambient = try assembler.assemble(rawELMResponse: "79A 07 62 11 5D 7F 6D 7F 00\r\n>", expectedRxID: 0x79A)
        XCTAssertEqual(try XCTUnwrap(LeafCANParser.decodeVCMAmbientC(ambient)), 20.0)

        let odometer = try assembler.assemble(rawELMResponse: "763 06 62 0E 01 00 FA D2 00\r\n>", expectedRxID: 0x763)
        XCTAssertEqual(try XCTUnwrap(LeafCANParser.decodeOdometerKm(odometer)), 64_210)
        XCTAssertNil(LeafCANParser.decodeOdometerKm([0x62, 0x0E, 0x02, 0x00, 0x00, 0x01]))
    }

    func testNoFakeSOHSeedOnFirstLaunch() throws {
        XCTAssertTrue(SOHHistoryLoader.initial(persisted: nil).isEmpty)
        XCTAssertTrue(SOHHistoryLoader.initial(persisted: []).isEmpty)

        let saved = SOHSnapshot(odometerKm: 12_000, sohPct: 95.0, hxPct: 90.0, ahr: 110.0, packTempC: 21.0)
        XCTAssertEqual(SOHHistoryLoader.initial(persisted: [saved]).count, 1)

        let legacy = """
        [{"id":"00000000-0000-0000-0000-000000000001","date":0,"odometerKm":12000,"sohPct":95,"hxPct":90,"ahr":110,"packTempC":21}]
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([SOHSnapshot].self, from: legacy)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertTrue(decoded[0].fromLiveAdapter)
        XCTAssertFalse(decoded.contains { $0.odometerKm == 58_400 && $0.sohPct == 91.2 })
    }

    func testSimulatorSamplesAreNotPersistedWhileAdapterIsActive() {
        XCTAssertFalse(TelemetryPersistencePolicy.shouldPersistToHistory(sourceIsLiveAdapter: false, realAdapterActive: true))
        XCTAssertFalse(TelemetryPersistencePolicy.shouldPersistToHistory(sourceIsLiveAdapter: false, realAdapterActive: false))
        XCTAssertTrue(TelemetryPersistencePolicy.shouldPersistToHistory(sourceIsLiveAdapter: true, realAdapterActive: true))
        XCTAssertFalse(TelemetryPersistencePolicy.shouldPersistToHistory(sourceIsLiveAdapter: true, realAdapterActive: false))
    }

    func testTripDistancePrefersOdometerAndDoesNotInventDemoEnergy() {
        let used = TripMetrics.energyUsedKwh(startRemaining: 20.0, endRemaining: 20.0)
        XCTAssertEqual(used, 0.0)
        XCTAssertEqual(TripMetrics.energyUsedKwh(startRemaining: 20.0, endRemaining: 17.6), 2.4)
        XCTAssertEqual(TripMetrics.regenKwh(startRemaining: 17.0, endRemaining: 17.4), 0.4)

        let measured = TripMetrics.distanceKm(
            startOdometerKm: 64_210,
            endOdometerKm: 64_222,
            energyUsedKwh: 2.4,
            odometerAvailable: true
        )
        XCTAssertEqual(measured.distanceKm, 12.0)
        XCTAssertFalse(measured.isEstimated)

        let estimated = TripMetrics.distanceKm(
            startOdometerKm: nil,
            endOdometerKm: nil,
            energyUsedKwh: 3.1,
            odometerAvailable: false
        )
        XCTAssertEqual(estimated.distanceKm, 20.0)
        XCTAssertTrue(estimated.isEstimated)
    }

    func testCloneWarningMatchesActualPollInterval() {
        XCTAssertEqual(AdapterPollSchedule.intervalSeconds(for: .stnPro), 1.5)
        XCTAssertEqual(AdapterPollSchedule.intervalSeconds(for: .elm327v15), 2.5)
        XCTAssertEqual(AdapterPollSchedule.intervalSeconds(for: .elm327CloneV21), 2.5)
        XCTAssertEqual(
            AdapterPollSchedule.cloneWarning(for: .elm327CloneV21),
            "Clone ELM327 v2.1 detected — using software-paced ISO-TP polling (every 2.5 s)."
        )
        XCTAssertNil(AdapterPollSchedule.cloneWarning(for: .stnPro))
        XCTAssertNil(AdapterPollSchedule.cloneWarning(for: .elm327v15))
    }
}
