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
}
