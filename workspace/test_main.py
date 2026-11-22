"""QA Automation Test Suite for GitLeaf Protocol Core, OBD2 Adapters, and Safety Interlock."""

from __future__ import annotations

import pytest

from protocol_core import (
    ADAPTER_CATALOG,
    AdapterTier,
    AdapterTransportType,
    ELM327ProbeSession,
    ISOTPAssembler,
    ISOTPError,
    LeafGeneration,
    LeafVCMState,
    PACK_PROFILES,
    SafetyInterlock,
    SafetyInterlockError,
    ServiceCommandType,
    VirtualLeafOBDAdapter,
    decode_lbc_group1,
    decode_lbc_group2_cells,
    decode_lbc_group4_temps,
    decode_lbc_group61_ze1,
    decode_lbc_group6_shunts,
    decode_tpms_pressures,
    decode_uds_dtcs,
    estimate_range_km,
    match_ble_advertisement,
)
from protocol_core.isotp import encode_isotp_frames


def test_01_market_obd2_adapter_catalog_and_ble_discovery():
    """Verify broad iOS market OBD2 adapter coverage across BLE, Wi-Fi, and MFi."""
    transports = {spec.transport for spec in ADAPTER_CATALOG}
    assert AdapterTransportType.BLE in transports
    assert AdapterTransportType.WIFI_TCP in transports
    assert AdapterTransportType.MFI_EA in transports
    assert AdapterTransportType.VIRTUAL in transports

    assert match_ble_advertisement("VEEPEAK").id == "veepeak_ble"
    assert match_ble_advertisement("OBDLink CX").id == "obdlink_cx"
    assert match_ble_advertisement("IOS-Vlink").id == "vgate_icar_vlinker"
    assert match_ble_advertisement("LELink2").id == "lelink2"
    assert match_ble_advertisement("CARISTA").id == "carista_ble"
    # Fallback match by Nordic UART service UUID when name is blank
    assert match_ble_advertisement("", ["6E400001-B5A3-F393-E0A9-E50E24DCCA9E"]).id == "generic_ble_nordic"


def test_02_three_tier_adapter_probe_and_v21_clone_fallback():
    """Verify STN Pro, Genuine ELM327 v1.5, and Clone v2.1 fallback classification."""
    prober = ELM327ProbeSession()

    stn_sim = VirtualLeafOBDAdapter(adapter_tier=AdapterTier.STN_PRO)
    stn_profile = prober.probe(stn_sim.send_command)
    assert stn_profile.tier == AdapterTier.STN_PRO
    assert stn_profile.supports_stn_filters is True
    assert stn_profile.supports_hardware_flow_control is True
    assert stn_profile.warnings == []

    elm15_sim = VirtualLeafOBDAdapter(adapter_tier=AdapterTier.ELM327_V15)
    elm15_profile = prober.probe(elm15_sim.send_command)
    assert elm15_profile.tier == AdapterTier.ELM327_V15
    assert elm15_profile.supports_stn_filters is False
    assert elm15_profile.supports_hardware_flow_control is True

    clone_sim = VirtualLeafOBDAdapter(adapter_tier=AdapterTier.ELM327_CLONE_V21)
    clone_profile = prober.probe(clone_sim.send_command)
    assert clone_profile.tier == AdapterTier.ELM327_CLONE_V21
    assert clone_profile.supports_hardware_flow_control is False
    assert any("v2.1" in w for w in clone_profile.warnings)


def test_03_isotp_multiframe_wraparound_96_cells():
    """Verify 28-frame ISO-TP reassembly with 0x2F -> 0x20 sequence wraparound."""
    sim = VirtualLeafOBDAdapter(generation=LeafGeneration.ZE1_40, weak_cell_index=42)
    sim.send_command("ATSH 79B")
    raw = sim.send_command("21 02")

    assembler = ISOTPAssembler()
    payload = assembler.assemble_raw(raw, expected_rx_id=0x7BB)
    assert len(payload) == 2 + 96 * 2

    pack = decode_lbc_group2_cells(payload)
    assert len(pack.voltages_mv) == 96
    assert 42 in pack.weak_cell_indices
    assert pack.delta_mv >= 39


def test_04_isotp_detects_sequence_error_and_truncation():
    """Verify malformed or truncated ISO-TP multi-frame sequences raise ISOTPError."""
    assembler = ISOTPAssembler()
    bad_seq = "7BB 10 14 61 01 00 00 00 00\r\n7BB 22 01 02 03 04 05 06 07\r\n>"
    with pytest.raises(ISOTPError, match="sequence mismatch"):
        assembler.assemble_raw(bad_seq, expected_rx_id=0x7BB)

    truncated = "7BB 10 20 61 01 00 00 00 00\r\n7BB 21 01 02 03 04 05 06 07\r\n>"
    with pytest.raises(ISOTPError, match="Incomplete"):
        assembler.assemble_raw(truncated, expected_rx_id=0x7BB)


@pytest.mark.parametrize("generation", list(LeafGeneration))
def test_05_all_leaf_generations_lbc_group1_decoding(generation: LeafGeneration):
    """Verify LBC Group 1 decoding & GID scaling across ZE0 24, AZE0 24/30, ZE1 40/62."""
    sim = VirtualLeafOBDAdapter(
        generation=generation,
        real_soc_pct=80.0,
        soh_pct=92.0,
        pack_voltage_v=380.0,
        pack_current_a=-15.0,  # Regen / charging negative current
    )
    sim.send_command("ATSH 79B")
    payload = ISOTPAssembler().assemble_raw(sim.send_command("21 01"), expected_rx_id=0x7BB)
    summary = decode_lbc_group1(payload, generation=generation)

    profile = PACK_PROFILES[generation]
    expected_gids = int(round(profile.max_gids * 0.80 * 0.92))
    assert summary.gids == expected_gids
    assert summary.real_soc_pct == pytest.approx(80.0, abs=0.05)
    assert summary.soh_pct == pytest.approx(92.0, abs=0.05)
    assert summary.pack_current_a == pytest.approx(-15.0, abs=0.05)
    assert summary.power_kw == pytest.approx(-5.7, abs=0.05)
    assert summary.qc_count == 47
    assert summary.l1_l2_count == 812


def test_06_lbc_thermistors_shunts_and_ze1_group61():
    """Verify battery thermistor, shunt balance bitmask, and ZE1 Group 61 decoders."""
    sim = VirtualLeafOBDAdapter(generation=LeafGeneration.ZE1_62, temps_c=[-4, -2, -3, -5])
    sim.send_command("ATSH 79B")
    asm = ISOTPAssembler()

    temps = decode_lbc_group4_temps(asm.assemble_raw(sim.send_command("21 04"), expected_rx_id=0x7BB))
    assert temps.min_c == -5.0
    assert temps.max_c == -2.0
    assert temps.avg_c == pytest.approx(-3.5, abs=0.1)

    shunts = decode_lbc_group6_shunts(asm.assemble_raw(sim.send_command("21 06"), expected_rx_id=0x7BB))
    assert len(shunts) == 96
    assert sum(shunts) == 6  # 3 modules * 2 bits (0x05)

    g61 = decode_lbc_group61_ze1(asm.assemble_raw(sim.send_command("21 61"), expected_rx_id=0x7BB))
    assert g61["soh_pct"] == pytest.approx(89.4, abs=0.05)
    assert g61["gids"] > 450


def test_07_tpms_and_uds_dtc_scan_and_clear_workflow():
    """Verify TPMS 4-wheel pressure decoding and UDS DTC read + authorized clear."""
    sim = VirtualLeafOBDAdapter(tpms_psi=(36.0, 36.25, 35.5, 30.5))
    asm = ISOTPAssembler()

    sim.send_command("ATSH 745")
    tpms = decode_tpms_pressures(asm.assemble_raw(sim.send_command("21 0E"), expected_rx_id=0x765))
    assert tpms.fl_psi == 36.0
    assert tpms.low_pressure_wheels(threshold_psi=32.0) == ["RR"]
    assert tpms.as_bar()["FL"] == pytest.approx(2.48, abs=0.02)

    sim.send_command("ATSH 79B")
    dtcs = decode_uds_dtcs(asm.assemble_raw(sim.send_command("19 02 FF"), expected_rx_id=0x7BB), ecu="LBC")
    assert any(d.code == "P3173" and d.severity == "CRITICAL" for d in dtcs)

    # Clear DTCs via Park-Only Safety Interlock
    interlock = SafetyInterlock()
    parked = LeafVCMState(
        speed_kmh=0.0, gear="P", ambient_temp_c=12.0, odometer_km=50_000, climate_kw=0.2
    )
    tx_id, clear_bytes = interlock.authorize_and_build(
        ServiceCommandType.CLEAR_DTCS, vcm_state=parked, read_only_mode=False, user_confirmed=True
    )
    assert tx_id == 0x79B
    sim.send_command(f"ATSH {tx_id:03X}")
    sim.send_command(clear_bytes.hex().upper())

    dtcs_after = decode_uds_dtcs(asm.assemble_raw(sim.send_command("19 02 FF"), expected_rx_id=0x7BB), ecu="LBC")
    assert dtcs_after == []


def test_08_park_only_safety_interlock_enforces_all_guardrails():
    """Verify SafetyInterlock blocks writes in Read-Only mode, unconfirmed, or non-Park."""
    interlock = SafetyInterlock()
    parked = LeafVCMState(speed_kmh=0.0, gear="P", ambient_temp_c=10.0, odometer_km=42_000, climate_kw=0.0)
    driving = LeafVCMState(speed_kmh=32.0, gear="D", ambient_temp_c=10.0, odometer_km=42_000, climate_kw=0.5)

    with pytest.raises(SafetyInterlockError, match="Read-Only"):
        interlock.authorize_and_build(ServiceCommandType.CLEAR_DTCS, parked, read_only_mode=True, user_confirmed=True)

    with pytest.raises(SafetyInterlockError, match="confirmation"):
        interlock.authorize_and_build(ServiceCommandType.TOGGLE_VSP_SOUND, parked, read_only_mode=False, user_confirmed=False)

    with pytest.raises(SafetyInterlockError, match="Park"):
        interlock.authorize_and_build(ServiceCommandType.SET_AUTO_DOOR_LOCK, driving, read_only_mode=False, user_confirmed=True)

    tx_id, payload = interlock.authorize_and_build(
        ServiceCommandType.TOGGLE_VSP_SOUND, parked, read_only_mode=False, user_confirmed=True, param=0
    )
    assert tx_id == 0x74B
    assert payload == bytes([0x3B, 0x01, 0x00])


def test_09_elevation_aware_range_estimator():
    """Verify uphill elevation reduces estimated range and downhill recovers energy."""
    flat = estimate_range_km(remaining_kwh=30.0, wh_per_km=155.0, elevation_gain_m=0.0)
    uphill = estimate_range_km(remaining_kwh=30.0, wh_per_km=155.0, elevation_gain_m=600.0)
    downhill = estimate_range_km(remaining_kwh=30.0, wh_per_km=155.0, elevation_gain_m=-600.0)
    assert uphill < flat < downhill
    assert len(encode_isotp_frames(b"\x61\x01\x02")) == 1


def test_10_trip_csv_and_abrp_telemetry_export():
    """Verify CSV trip export and ABRP live telemetry JSON formatting."""
    from protocol_core.leaf_protocol import export_trips_csv, format_abrp_telemetry

    sim = VirtualLeafOBDAdapter(generation=LeafGeneration.ZE1_40, pack_current_a=-18.0)
    sim.send_command("ATSH 79B")
    asm = ISOTPAssembler()
    summary = decode_lbc_group1(asm.assemble_raw(sim.send_command("21 01"), expected_rx_id=0x7BB))
    temps = decode_lbc_group4_temps(asm.assemble_raw(sim.send_command("21 04"), expected_rx_id=0x7BB))
    vcm = LeafVCMState(speed_kmh=0.0, gear="P", ambient_temp_c=11.0, odometer_km=64_210, climate_kw=0.3)

    abrp = format_abrp_telemetry(summary, temps, vcm, utc_timestamp=1700000000)
    assert abrp["is_charging"] is True
    assert abrp["soc"] == summary.real_soc_pct
    assert abrp["odometer"] == 64_210

    csv_text = export_trips_csv([
        {
            "started_at": "2026-11-22T08:00:00Z",
            "ended_at": "2026-11-22T08:30:00Z",
            "distance_km": 20.0,
            "start_soc_pct": 80.0,
            "end_soc_pct": 70.0,
            "energy_used_kwh": 3.1,
            "regen_kwh": 0.5,
            "ambient_temp_c": 12.0,
        }
    ])
    assert "started_at,ended_at,distance_km" in csv_text
    assert "20.00,80.0,70.0,3.100,0.500,155,12.0" in csv_text
