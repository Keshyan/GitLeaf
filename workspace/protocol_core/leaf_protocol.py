"""Nissan Leaf EV-CAN / UDS Protocol Decoders (ZE0 / AZE0 / ZE1) & Safety Interlock."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
import math


class LeafGeneration(str, Enum):
    ZE0_24 = "ZE0_24"    # 2011-2012 (24 kWh)
    AZE0_24 = "AZE0_24"  # 2013-2017 (24 kWh)
    AZE0_30 = "AZE0_30"  # 2016-2017 (30 kWh)
    ZE1_40 = "ZE1_40"    # 2018-2025 (40 kWh)
    ZE1_62 = "ZE1_62"    # 2019-2025 (62 kWh e+)


@dataclass(frozen=True)
class LeafPackProfile:
    generation: LeafGeneration
    label: str
    nominal_kwh: float
    max_gids: int
    wh_per_gid: float = 77.5
    cell_count: int = 96


PACK_PROFILES: dict[LeafGeneration, LeafPackProfile] = {
    LeafGeneration.ZE0_24: LeafPackProfile(LeafGeneration.ZE0_24, "Leaf ZE0 (24 kWh)", 24.0, 281),
    LeafGeneration.AZE0_24: LeafPackProfile(LeafGeneration.AZE0_24, "Leaf AZE0 (24 kWh)", 24.0, 281),
    LeafGeneration.AZE0_30: LeafPackProfile(LeafGeneration.AZE0_30, "Leaf AZE0 (30 kWh)", 30.0, 363),
    LeafGeneration.ZE1_40: LeafPackProfile(LeafGeneration.ZE1_40, "Leaf ZE1 (40 kWh)", 40.0, 502),
    LeafGeneration.ZE1_62: LeafPackProfile(LeafGeneration.ZE1_62, "Leaf ZE1 e+ (62 kWh)", 62.0, 775),
}


@dataclass(frozen=True)
class LeafBatterySummary:
    pack_voltage_v: float
    pack_current_a: float
    power_kw: float
    hx_pct: float
    real_soc_pct: float
    dash_soc_pct: float
    ahr: float
    soh_pct: float
    gids: int
    remaining_kwh: float
    qc_count: int
    l1_l2_count: int


@dataclass(frozen=True)
class LeafCellPack:
    voltages_mv: list[int]
    min_mv: int
    max_mv: int
    avg_mv: float
    delta_mv: int
    weak_cell_indices: list[int] = field(default_factory=list)


@dataclass(frozen=True)
class LeafThermistors:
    temps_c: list[float]
    min_c: float
    max_c: float
    avg_c: float
    heater_active: bool


@dataclass(frozen=True)
class LeafTPMS:
    fl_psi: float
    fr_psi: float
    rl_psi: float
    rr_psi: float

    def as_bar(self) -> dict[str, float]:
        factor = 0.0689476
        return {
            "FL": round(self.fl_psi * factor, 2),
            "FR": round(self.fr_psi * factor, 2),
            "RL": round(self.rl_psi * factor, 2),
            "RR": round(self.rr_psi * factor, 2),
        }

    def low_pressure_wheels(self, threshold_psi: float = 32.0) -> list[str]:
        mapping = {"FL": self.fl_psi, "FR": self.fr_psi, "RL": self.rl_psi, "RR": self.rr_psi}
        return [wheel for wheel, psi in mapping.items() if psi < threshold_psi]


@dataclass(frozen=True)
class LeafVCMState:
    speed_kmh: float
    gear: str  # "P", "R", "N", "D", "B"
    ambient_temp_c: float
    odometer_km: int
    climate_kw: float


@dataclass(frozen=True)
class DTCEntry:
    ecu: str
    code: str
    status_byte: int
    description: str
    severity: str  # "INFO", "WARNING", "CRITICAL"


KNOWN_LEAF_DTCS: dict[str, tuple[str, str]] = {
    "P3173": ("LBC Battery Cell Voltage Sensor Fault", "CRITICAL"),
    "P31E7": ("LBC HV Battery Insulation / Contactor Check", "CRITICAL"),
    "P312F": ("VCM Quick Charge Communication Error", "WARNING"),
    "P3176": ("Inverter Capacitor Discharge Fault", "CRITICAL"),
    "C118C": ("ABS / Regenerative Braking Pressure Sensor", "WARNING"),
    "B26F2": ("BCM Keyless / Intelligent Key Antenna Warning", "INFO"),
    "U1000": ("CAN Communication Bus Timeout", "WARNING"),
}


def _u16(payload: bytes, offset: int) -> int:
    return (payload[offset] << 8) | payload[offset + 1]


def _i32(payload: bytes, offset: int) -> int:
    val = (
        (payload[offset] << 24)
        | (payload[offset + 1] << 16)
        | (payload[offset + 2] << 8)
        | payload[offset + 3]
    )
    return val - 0x100000000 if val >= 0x80000000 else val


def decode_lbc_group1(payload: bytes, generation: LeafGeneration = LeafGeneration.ZE1_40) -> LeafBatterySummary:
    """Decode LBC Group 1 (`21 01` -> `61 01 ...`) canonical Leaf telemetry payload."""
    if len(payload) < 39 or payload[0] != 0x61 or payload[1] != 0x01:
        raise ValueError("Invalid LBC Group 1 payload (expected header 61 01, >=39 bytes)")

    profile = PACK_PROFILES[generation]
    # Signed 32-bit pack current in 1/1024 A units (positive = discharge, negative = regen/charge)
    pack_current_a = _i32(payload, 2) / 1024.0
    # Pack voltage at offset 18 in 0.01 V units
    pack_voltage_v = _u16(payload, 18) / 100.0
    power_kw = (pack_voltage_v * pack_current_a) / 1000.0

    # Hx (0.01 %), Real BMS SoC (0.0001 % -> 3 bytes), Ahr (0.0001 Ah -> 3 bytes)
    hx_pct = _u16(payload, 24) / 100.0
    real_soc_raw = (payload[26] << 16) | (payload[27] << 8) | payload[28]
    real_soc_pct = min(100.0, max(0.0, real_soc_raw / 10000.0))

    ahr_raw = (payload[29] << 16) | (payload[30] << 8) | payload[31]
    ahr = ahr_raw / 10000.0

    soh_pct = min(100.0, max(0.0, _u16(payload, 32) / 100.0))
    gids = _u16(payload, 34)
    qc_count = _u16(payload, 35 + 1) if len(payload) >= 40 else _u16(payload, 36)
    l1_l2_count = _u16(payload, 38) if len(payload) >= 40 else 0

    # LeafSpy Dash SoC maps usable ~5%..97% BMS SoC onto 0..100% dashboard display
    dash_soc_pct = min(100.0, max(0.0, (real_soc_pct - 5.0) / 0.92))
    remaining_kwh = (gids * profile.wh_per_gid) / 1000.0

    return LeafBatterySummary(
        pack_voltage_v=round(pack_voltage_v, 2),
        pack_current_a=round(pack_current_a, 2),
        power_kw=round(power_kw, 2),
        hx_pct=round(hx_pct, 2),
        real_soc_pct=round(real_soc_pct, 2),
        dash_soc_pct=round(dash_soc_pct, 1),
        ahr=round(ahr, 2),
        soh_pct=round(soh_pct, 2),
        gids=gids,
        remaining_kwh=round(remaining_kwh, 2),
        qc_count=qc_count,
        l1_l2_count=l1_l2_count,
    )


def decode_lbc_group2_cells(payload: bytes, weak_threshold_mv: int = 30) -> LeafCellPack:
    """Decode LBC Group 2 (`21 02` -> `61 02`) 96-cell voltage array (2 bytes/cell in mV)."""
    if len(payload) < 2 + 96 * 2 or payload[0] != 0x61 or payload[1] != 0x02:
        raise ValueError("Invalid LBC Group 2 payload (expected header 61 02 and 96 cells)")

    voltages: list[int] = []
    for i in range(96):
        mv = _u16(payload, 2 + i * 2)
        voltages.append(mv)

    min_mv = min(voltages)
    max_mv = max(voltages)
    avg_mv = sum(voltages) / len(voltages)
    delta_mv = max_mv - min_mv
    weak_cells = [idx + 1 for idx, mv in enumerate(voltages) if (avg_mv - mv) >= weak_threshold_mv]

    return LeafCellPack(
        voltages_mv=voltages,
        min_mv=min_mv,
        max_mv=max_mv,
        avg_mv=round(avg_mv, 1),
        delta_mv=delta_mv,
        weak_cell_indices=weak_cells,
    )


def decode_lbc_group4_temps(payload: bytes) -> LeafThermistors:
    """Decode LBC Group 4 (`21 04` -> `61 04`) 4 battery pack thermistors."""
    if len(payload) < 14 or payload[0] != 0x61 or payload[1] != 0x04:
        raise ValueError("Invalid LBC Group 4 payload (expected header 61 04, >=14 bytes)")

    # Each sensor occupies 3 bytes: 2-byte raw ADC + 1-byte signed temp °C
    temps: list[float] = []
    for i in range(4):
        raw_temp_byte = payload[2 + i * 3 + 2]
        temp_c = raw_temp_byte - 256 if raw_temp_byte >= 128 else raw_temp_byte
        # Some ZE0/AZE0 packs omit sensor #3 (0xFF / -1 or 0x7F sentinel)
        if payload[2 + i * 3] == 0xFF and payload[2 + i * 3 + 1] == 0xFF:
            continue
        temps.append(float(temp_c))

    if not temps:
        raise ValueError("No valid battery thermistor readings present")

    heater_active = bool(payload[14] & 0x01) if len(payload) > 14 else False
    return LeafThermistors(
        temps_c=temps,
        min_c=min(temps),
        max_c=max(temps),
        avg_c=round(sum(temps) / len(temps), 1),
        heater_active=heater_active,
    )


def decode_lbc_group6_shunts(payload: bytes) -> list[bool]:
    """Decode LBC Group 6 (`21 06` -> `61 06`) 96-cell balancing shunt bitmask."""
    if len(payload) < 26 or payload[0] != 0x61 or payload[1] != 0x06:
        raise ValueError("Invalid LBC Group 6 payload (expected header 61 06, >=26 bytes)")

    # 24 bytes (4 bits per 4-cell module -> 96 cells)
    shunts: list[bool] = []
    for byte_idx in range(24):
        nibble = payload[2 + byte_idx] & 0x0F
        for bit in range(4):
            shunts.append(bool(nibble & (1 << bit)))
    return shunts


def decode_lbc_group61_ze1(payload: bytes) -> dict[str, float]:
    """Decode ZE1 extended LBC Group 61 (`21 61` -> `61 61`) high-res SOH/GIDs."""
    if len(payload) < 8 or payload[0] != 0x61 or payload[1] != 0x61:
        raise ValueError("Invalid LBC Group 61 payload (expected header 61 61, >=8 bytes)")

    soh_pct = _u16(payload, 2) / 100.0
    gids = _u16(payload, 4)
    usable_kwh = _u16(payload, 6) / 100.0
    return {
        "soh_pct": round(soh_pct, 2),
        "gids": float(gids),
        "usable_kwh": round(usable_kwh, 2),
    }


def decode_tpms_pressures(payload: bytes) -> LeafTPMS:
    """Decode BCM/TPMS response (`61 0E` or `62 ...`) 4-wheel tire pressures (0.25 PSI/bit)."""
    if len(payload) < 6:
        raise ValueError("Invalid TPMS payload (expected >=6 bytes)")
    return LeafTPMS(
        fl_psi=round(payload[2] * 0.25, 2),
        fr_psi=round(payload[3] * 0.25, 2),
        rl_psi=round(payload[4] * 0.25, 2),
        rr_psi=round(payload[5] * 0.25, 2),
    )


def decode_uds_dtcs(payload: bytes, ecu: str = "LBC") -> list[DTCEntry]:
    """Decode UDS Service 0x19 02 FF response (`59 02 <availMask> [DTC_HI DTC_LO DTC_FTB STATUS]...`)."""
    if len(payload) < 3 or payload[0] != 0x59 or payload[1] != 0x02:
        raise ValueError("Invalid UDS ReadDTCInformation response (expected 59 02)")

    prefix_map = {0: "P", 1: "C", 2: "B", 3: "U"}
    entries: list[DTCEntry] = []
    idx = 3
    while idx + 3 < len(payload):
        b0, b1, _ftb, status = payload[idx], payload[idx + 1], payload[idx + 2], payload[idx + 3]
        idx += 4
        if b0 == 0 and b1 == 0:
            continue
        letter = prefix_map[(b0 >> 6) & 0x03]
        d1 = (b0 >> 4) & 0x03
        d2 = b0 & 0x0F
        d3 = (b1 >> 4) & 0x0F
        d4 = b1 & 0x0F
        code = f"{letter}{d1}{d2:X}{d3:X}{d4:X}"
        desc, severity = KNOWN_LEAF_DTCS.get(code, (f"{ecu} Diagnostic Trouble Code {code}", "WARNING"))
        entries.append(DTCEntry(ecu=ecu, code=code, status_byte=status, description=desc, severity=severity))

    return entries


def estimate_range_km(
    remaining_kwh: float,
    wh_per_km: float = 155.0,
    elevation_gain_m: float = 0.0,
    vehicle_mass_kg: float = 1650.0,
    reserve_kwh: float = 1.5,
) -> float:
    """Estimate remaining drivable range in km with elevation energy penalty/recovery."""
    usable_kwh = max(0.0, remaining_kwh - reserve_kwh)
    # Potential energy delta: m * g * dh / 3.6e6 (converted to kWh with 0.85 drive / 0.70 regen efficiency)
    potential_kwh = (vehicle_mass_kg * 9.81 * elevation_gain_m) / 3_600_000.0
    if potential_kwh > 0:
        adjusted_kwh = max(0.0, usable_kwh - potential_kwh / 0.85)
    else:
        adjusted_kwh = usable_kwh + abs(potential_kwh) * 0.70

    if wh_per_km <= 0:
        raise ValueError("wh_per_km must be positive")
    return round((adjusted_kwh * 1000.0) / wh_per_km, 1)


class ServiceCommandType(str, Enum):
    CLEAR_DTCS = "CLEAR_DTCS"
    TOGGLE_VSP_SOUND = "TOGGLE_VSP_SOUND"
    SET_AUTO_DOOR_LOCK = "SET_AUTO_DOOR_LOCK"
    SET_HEADLIGHT_DELAY = "SET_HEADLIGHT_DELAY"
    REGISTER_TPMS = "REGISTER_TPMS"


class SafetyInterlockError(PermissionError):
    """Raised when a write/service command violates Park-Only Safety Interlock."""


class SafetyInterlock:
    """Hard safety gate for all write/clear ECU commands (LeafSpy Pro service parity)."""

    def authorize_and_build(
        self,
        command: ServiceCommandType,
        vcm_state: LeafVCMState,
        read_only_mode: bool,
        user_confirmed: bool,
        param: int = 0,
    ) -> tuple[int, bytes]:
        """Validate safety interlock conditions and return (tx_arb_id, uds_payload)."""
        if read_only_mode:
            raise SafetyInterlockError("Blocked: Safe Read-Only Mode is enabled.")
        if not user_confirmed:
            raise SafetyInterlockError("Blocked: Explicit user confirmation is required.")
        if not math.isclose(vcm_state.speed_kmh, 0.0, abs_tol=0.1) or vcm_state.gear.upper() != "P":
            raise SafetyInterlockError(
                f"Blocked: Vehicle must be in Park (P) at 0 km/h (current: gear={vcm_state.gear}, speed={vcm_state.speed_kmh} km/h)."
            )

        if command == ServiceCommandType.CLEAR_DTCS:
            return (0x79B, bytes([0x14, 0xFF, 0xFF, 0xFF]))
        if command == ServiceCommandType.TOGGLE_VSP_SOUND:
            return (0x74B, bytes([0x3B, 0x01, 0x01 if param else 0x00]))
        if command == ServiceCommandType.SET_AUTO_DOOR_LOCK:
            return (0x745, bytes([0x3B, 0x10, param & 0x03]))
        if command == ServiceCommandType.SET_HEADLIGHT_DELAY:
            return (0x745, bytes([0x3B, 0x12, param & 0x0F]))
        if command == ServiceCommandType.REGISTER_TPMS:
            return (0x745, bytes([0x31, 0x01, 0x02, 0x00]))

        raise ValueError(f"Unsupported service command: {command}")


def format_abrp_telemetry(
    summary: LeafBatterySummary,
    temps: LeafThermistors,
    vcm: LeafVCMState,
    utc_timestamp: int,
) -> dict[str, object]:
    """Build an ABRP (A Better Routeplanner) Live Telemetry JSON payload."""
    return {
        "utc": utc_timestamp,
        "soc": summary.real_soc_pct,
        "soh": summary.soh_pct,
        "power": summary.power_kw,
        "speed": vcm.speed_kmh,
        "is_charging": summary.power_kw < -1.0 and vcm.gear.upper() == "P",
        "batt_temp": temps.avg_c,
        "ext_temp": vcm.ambient_temp_c,
        "odometer": vcm.odometer_km,
    }


def export_trips_csv(trips: list[dict[str, object]]) -> str:
    """Export recorded Leaf trips to CSV format."""
    header = "started_at,ended_at,distance_km,start_soc_pct,end_soc_pct,energy_used_kwh,regen_kwh,wh_per_km,ambient_temp_c"
    rows = [header]
    for t in trips:
        dist = float(t.get("distance_km", 0.0))
        kwh = float(t.get("energy_used_kwh", 0.0))
        wh_per_km = round((kwh * 1000.0) / dist) if dist > 0.05 else 0
        rows.append(
            f"{t.get('started_at', '')},{t.get('ended_at', '')},{dist:.2f},"
            f"{float(t.get('start_soc_pct', 0.0)):.1f},{float(t.get('end_soc_pct', 0.0)):.1f},"
            f"{kwh:.3f},{float(t.get('regen_kwh', 0.0)):.3f},{wh_per_km},"
            f"{float(t.get('ambient_temp_c', 0.0)):.1f}"
        )
    return "\n".join(rows)
