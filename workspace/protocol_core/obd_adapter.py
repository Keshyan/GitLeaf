"""Broad Market iOS OBD2 Adapter Catalog & 3-Tier ELM327/STN Auto-Probe Engine."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Callable


class AdapterTransportType(str, Enum):
    BLE = "BLE"
    WIFI_TCP = "WIFI_TCP"
    MFI_EA = "MFI_EA"
    VIRTUAL = "VIRTUAL"


class AdapterTier(str, Enum):
    STN_PRO = "STN_PRO"
    ELM327_V15 = "ELM327_V15"
    ELM327_CLONE_V21 = "ELM327_CLONE_V21"


@dataclass(frozen=True)
class AdapterSpec:
    """Known market OBD2 adapter profile for zero-config iOS discovery."""

    id: str
    display_name: str
    transport: AdapterTransportType
    expected_tier: AdapterTier
    ble_name_prefixes: tuple[str, ...] = ()
    ble_service_uuids: tuple[str, ...] = ()
    ble_tx_char_uuids: tuple[str, ...] = ()
    ble_rx_char_uuids: tuple[str, ...] = ()
    wifi_host: str | None = None
    wifi_port: int | None = None
    mfi_protocol_string: str | None = None
    notes: str = ""


ADAPTER_CATALOG: tuple[AdapterSpec, ...] = (
    AdapterSpec(
        id="obdlink_cx",
        display_name="OBDLink CX (BLE 5.1)",
        transport=AdapterTransportType.BLE,
        expected_tier=AdapterTier.STN_PRO,
        ble_name_prefixes=("OBDLink CX", "OBDLINK"),
        ble_service_uuids=("FFF0",),
        ble_tx_char_uuids=("FFF2",),
        ble_rx_char_uuids=("FFF1",),
        notes="STN2255 chip; supports fast STFAP hardware CAN filters.",
    ),
    AdapterSpec(
        id="veepeak_ble",
        display_name="Veepeak OBDCheck BLE / BLE+",
        transport=AdapterTransportType.BLE,
        expected_tier=AdapterTier.ELM327_V15,
        ble_name_prefixes=("VEEPEAK", "OBDCHECK"),
        ble_service_uuids=("FFF0",),
        ble_tx_char_uuids=("FFF2",),
        ble_rx_char_uuids=("FFF1",),
        notes="Most popular budget iOS BLE adapter for Nissan Leaf.",
    ),
    AdapterSpec(
        id="vgate_icar_vlinker",
        display_name="Vgate iCar Pro BLE 4.0 / vLinker MC+ / FD+",
        transport=AdapterTransportType.BLE,
        expected_tier=AdapterTier.STN_PRO,
        ble_name_prefixes=("IOS-VLINK", "V-LINK", "VLINKER", "VGATE", "ICAR"),
        ble_service_uuids=("18F0", "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2", "FFE0"),
        ble_tx_char_uuids=("2AF1", "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F", "FFE1"),
        ble_rx_char_uuids=("2AF0", "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F", "FFE1"),
        notes="Supports both standard 18F0 and ISSC/vLinker custom GATT UUIDs.",
    ),
    AdapterSpec(
        id="lelink2",
        display_name="LELink / LELink² BLE",
        transport=AdapterTransportType.BLE,
        expected_tier=AdapterTier.ELM327_V15,
        ble_name_prefixes=("LELINK", "OBD BLE"),
        ble_service_uuids=("FFE0",),
        ble_tx_char_uuids=("FFE1",),
        ble_rx_char_uuids=("FFE1",),
        notes="Classic LeafSpy-recommended BLE adapter with auto-sleep.",
    ),
    AdapterSpec(
        id="carista_ble",
        display_name="Carista EVO / BLE",
        transport=AdapterTransportType.BLE,
        expected_tier=AdapterTier.ELM327_V15,
        ble_name_prefixes=("CARISTA",),
        ble_service_uuids=("FFE0", "FFF0"),
        ble_tx_char_uuids=("FFE1", "FFF2"),
        ble_rx_char_uuids=("FFE1", "FFF1"),
    ),
    AdapterSpec(
        id="generic_ble_nordic",
        display_name="Generic ELM327 BLE 4.0 (FFE0 / FFF0 / Nordic UART)",
        transport=AdapterTransportType.BLE,
        expected_tier=AdapterTier.ELM327_CLONE_V21,
        ble_name_prefixes=("OBDII", "OBD2", "ELM327", "KONNWEI", "VPEAK", "BLE-OBD"),
        ble_service_uuids=("FFE0", "FFF0", "18F0", "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),
        ble_tx_char_uuids=("FFE1", "FFF2", "2AF1", "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"),
        ble_rx_char_uuids=("FFE1", "FFF1", "2AF0", "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"),
    ),
    AdapterSpec(
        id="obdlink_mx_mfi",
        display_name="OBDLink MX+ / LX (MFi Bluetooth)",
        transport=AdapterTransportType.MFI_EA,
        expected_tier=AdapterTier.STN_PRO,
        mfi_protocol_string="com.obdlink.protocol",
        notes="Apple MFi certified STN2120 adapter via ExternalAccessory.",
    ),
    AdapterSpec(
        id="wifi_elm327",
        display_name="Wi-Fi ELM327 / Vgate / KONNWEI KW902",
        transport=AdapterTransportType.WIFI_TCP,
        expected_tier=AdapterTier.ELM327_V15,
        wifi_host="192.168.0.10",
        wifi_port=35000,
        notes="Standard TCP socket transport for Wi-Fi OBD2 dongles.",
    ),
    AdapterSpec(
        id="virtual_leaf",
        display_name="GitLeaf Virtual Leaf Simulator",
        transport=AdapterTransportType.VIRTUAL,
        expected_tier=AdapterTier.STN_PRO,
        notes="Offline built-in demo & automated test transport.",
    ),
)


def match_ble_advertisement(device_name: str | None, advertised_service_uuids: list[str] | None = None) -> AdapterSpec | None:
    """Match a CoreBluetooth peripheral name and/or service UUIDs to an AdapterSpec."""
    upper_name = (device_name or "").strip().upper()
    norm_uuids = {u.strip().upper() for u in (advertised_service_uuids or [])}

    # 1. Exact brand/name prefix match (most specific first)
    for spec in ADAPTER_CATALOG:
        if spec.transport != AdapterTransportType.BLE:
            continue
        if upper_name and any(upper_name.startswith(prefix.upper()) or prefix.upper() in upper_name for prefix in spec.ble_name_prefixes):
            return spec

    # 2. Fallback to known GATT service UUID match
    if norm_uuids:
        for spec in ADAPTER_CATALOG:
            if spec.transport != AdapterTransportType.BLE:
                continue
            if norm_uuids.intersection({u.upper() for u in spec.ble_service_uuids}):
                return spec

    return None


@dataclass
class AdapterCapabilityProfile:
    """Result of probing an OBD2 adapter at connection time."""

    elm_version: str
    stn_version: str | None
    tier: AdapterTier
    supports_hardware_flow_control: bool
    supports_stn_filters: bool
    recommended_poll_hz: float
    warnings: list[str] = field(default_factory=list)


class ELM327ProbeSession:
    """3-Tier ELM327/STN initialization and quirk detection state machine."""

    BASE_INIT_COMMANDS: tuple[str, ...] = (
        "ATZ",
        "ATE0",
        "ATL0",
        "ATS0",
        "ATH1",
        "ATSP6",   # ISO 15765-4 CAN 11-bit 500 kbps (Nissan Leaf EV-CAN)
        "ATCAF0",  # Raw ISO-TP frames for deterministic 96-cell reassembly
    )

    def probe(self, send_command: Callable[[str], str]) -> AdapterCapabilityProfile:
        """Run AT/STN probe sequence and classify adapter capabilities safely."""
        warnings: list[str] = []

        for cmd in self.BASE_INIT_COMMANDS:
            resp = send_command(cmd)
            if "?" in resp and cmd in ("ATSP6", "ATCAF0"):
                warnings.append(f"Adapter rejected core CAN command '{cmd}' ({resp.strip()}).")

        elm_ver = send_command("ATI").replace(">", "").strip()
        stn_raw = send_command("STI").replace(">", "").strip()
        is_stn = ("STN" in stn_raw.upper()) and ("?" not in stn_raw)
        stn_ver = stn_raw if is_stn else None

        # Probe ISO-TP hardware flow control support (fails on cheap ELM327 v2.1 clones)
        cfc_resp = send_command("ATCFC1").strip()
        fcsm_resp = send_command("ATFCSM1").strip()
        hw_fc_ok = ("?" not in cfc_resp) and ("?" not in fcsm_resp)

        if is_stn:
            tier = AdapterTier.STN_PRO
            poll_hz = 6.0
        elif hw_fc_ok and "V2.1" not in elm_ver.upper():
            tier = AdapterTier.ELM327_V15
            poll_hz = 2.5
        else:
            tier = AdapterTier.ELM327_CLONE_V21
            poll_hz = 1.0
            if not hw_fc_ok:
                warnings.append(
                    "Clone ELM327 v2.1 detected (ATFCSM1/ATCFC1 unsupported). "
                    "Falling back to software-paced ISO-TP flow control."
                )

        return AdapterCapabilityProfile(
            elm_version=elm_ver or "UNKNOWN",
            stn_version=stn_ver,
            tier=tier,
            supports_hardware_flow_control=hw_fc_ok,
            supports_stn_filters=is_stn,
            recommended_poll_hz=poll_hz,
            warnings=warnings,
        )
