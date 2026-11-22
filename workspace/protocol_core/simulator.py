"""Virtual ELM327/STN + Nissan Leaf ECU Simulator for Offline Testing & Demo Mode."""

from __future__ import annotations

from dataclasses import dataclass, field

from .isotp import encode_isotp_frames
from .leaf_protocol import LeafGeneration, PACK_PROFILES
from .obd_adapter import AdapterTier


@dataclass
class VirtualLeafOBDAdapter:
    """Simulates a physical OBD2 adapter plugged into a Nissan Leaf EV-CAN bus."""

    generation: LeafGeneration = LeafGeneration.ZE1_40
    adapter_tier: AdapterTier = AdapterTier.STN_PRO
    real_soc_pct: float = 76.5
    soh_pct: float = 89.4
    hx_pct: float = 84.2
    pack_voltage_v: float = 368.4
    pack_current_a: float = 12.5
    temps_c: list[int] = field(default_factory=lambda: [18, 19, 18, 17])
    tpms_psi: tuple[float, float, float, float] = (36.0, 36.25, 35.5, 31.0)
    weak_cell_index: int | None = 42  # 1-based weak cell for Battery Lab testing
    active_dtcs: list[bytes] = field(
        default_factory=lambda: [
            bytes([0x31, 0x73, 0x00, 0x09]),  # P3173
            bytes([0xC1, 0x00, 0x00, 0x08]),  # U0100 (or U1000 via 0xD0 0x00)
        ]
    )
    speed_kmh: float = 0.0
    gear: str = "P"
    ambient_temp_c: float = 14.5
    odometer_km: int = 64_210
    active_tx_header: int = 0x79B

    def send_command(self, cmd: str) -> str:
        """Process an ELM327 AT/ST command or Nissan Leaf UDS hex request."""
        norm = cmd.strip().upper()

        if norm == "ATZ":
            return "ELM327 v1.5\r\n>" if self.adapter_tier != AdapterTier.ELM327_CLONE_V21 else "ELM327 v2.1\r\n>"
        if norm == "ATI":
            return "ELM327 v1.5\r\n>" if self.adapter_tier != AdapterTier.ELM327_CLONE_V21 else "ELM327 v2.1\r\n>"
        if norm == "STI":
            return "STN2255 v5.6.5\r\n>" if self.adapter_tier == AdapterTier.STN_PRO else "?\r\n>"
        if norm in ("ATCFC1", "ATFCSM1"):
            return "?\r\n>" if self.adapter_tier == AdapterTier.ELM327_CLONE_V21 else "OK\r\n>"
        if norm.startswith("ATSH"):
            hdr = norm.replace("ATSH", "").strip()
            if hdr:
                self.active_tx_header = int(hdr, 16)
            return "OK\r\n>"
        if norm.startswith("AT") or norm.startswith("ST"):
            return "OK\r\n>"

        # Strip spaces for UDS hex commands
        hex_cmd = norm.replace(" ", "")
        if self.active_tx_header == 0x79B:
            if hex_cmd == "2101":
                return self._format_response(0x7BB, self._build_lbc_group1())
            if hex_cmd == "2102":
                return self._format_response(0x7BB, self._build_lbc_group2())
            if hex_cmd == "2104":
                return self._format_response(0x7BB, self._build_lbc_group4())
            if hex_cmd == "2106":
                return self._format_response(0x7BB, self._build_lbc_group6())
            if hex_cmd == "2161":
                return self._format_response(0x7BB, self._build_lbc_group61())
            if hex_cmd == "1902FF":
                return self._format_response(0x7BB, self._build_uds_dtcs())
            if hex_cmd == "14FFFFFF":
                self.active_dtcs.clear()
                return self._format_response(0x7BB, bytes([0x54]))
        elif self.active_tx_header == 0x745:
            if hex_cmd == "210E":
                return self._format_response(0x765, self._build_tpms())
        elif self.active_tx_header == 0x797:
            if hex_cmd == "221156":
                return self._format_response(0x79A, self._build_vcm_gear())
            if hex_cmd == "22121A":
                return self._format_response(0x79A, self._build_vcm_speed())
            if hex_cmd == "22115D":
                return self._format_response(0x79A, self._build_vcm_ambient())
        elif self.active_tx_header == 0x743:
            if hex_cmd == "220E01":
                return self._format_response(0x763, self._build_odometer())

        return "NO DATA\r\n>"

    def _format_response(self, rx_id: int, payload: bytes) -> str:
        lines = encode_isotp_frames(payload, arb_id=rx_id)
        return "\r\n".join(lines) + "\r\n>"

    def _build_lbc_group1(self) -> bytes:
        profile = PACK_PROFILES[self.generation]
        buf = bytearray(40)
        buf[0] = 0x61
        buf[1] = 0x01

        # Signed 32-bit pack current in 1/1024 A
        cur_raw = int(round(self.pack_current_a * 1024))
        if cur_raw < 0:
            cur_raw += 0x100000000
        buf[2:6] = cur_raw.to_bytes(4, "big")

        # Pack voltage in 0.01 V
        volt_raw = int(round(self.pack_voltage_v * 100))
        buf[18:20] = volt_raw.to_bytes(2, "big")

        # Hx (0.01 %), Real SoC (0.0001 %), Ahr (0.0001 Ah)
        buf[24:26] = int(round(self.hx_pct * 100)).to_bytes(2, "big")
        soc_raw = int(round(self.real_soc_pct * 10000))
        buf[26:29] = soc_raw.to_bytes(3, "big")

        nominal_ahr = (profile.nominal_kwh * 1000.0) / 360.0
        ahr_raw = int(round(nominal_ahr * (self.soh_pct / 100.0) * 10000))
        buf[29:32] = ahr_raw.to_bytes(3, "big")

        buf[32:34] = int(round(self.soh_pct * 100)).to_bytes(2, "big")
        gids = int(round(profile.max_gids * (self.real_soc_pct / 100.0) * (self.soh_pct / 100.0)))
        buf[34:36] = gids.to_bytes(2, "big")
        buf[36:38] = (47).to_bytes(2, "big")    # QC count
        buf[38:40] = (812).to_bytes(2, "big")   # L1/L2 count
        return bytes(buf)

    def _build_lbc_group2(self) -> bytes:
        buf = bytearray([0x61, 0x02])
        base_mv = int(round((self.pack_voltage_v / 96.0) * 1000))
        for i in range(96):
            jitter = (i % 7) - 3
            mv = base_mv + jitter
            if self.weak_cell_index is not None and (i + 1) == self.weak_cell_index:
                mv = base_mv - 42
            buf.extend(mv.to_bytes(2, "big"))
        return bytes(buf)

    def _build_lbc_group4(self) -> bytes:
        buf = bytearray([0x61, 0x04])
        for t in self.temps_c[:4]:
            buf.extend([0x02, 0x10])
            buf.append(t & 0xFF)
        buf.append(0x00)  # heater off
        return bytes(buf)

    def _build_lbc_group6(self) -> bytes:
        buf = bytearray([0x61, 0x06])
        for mod in range(24):
            # Mark a few high cells as actively balancing via shunts
            buf.append(0x05 if mod in (2, 10, 18) else 0x00)
        return bytes(buf)

    def _build_lbc_group61(self) -> bytes:
        profile = PACK_PROFILES[self.generation]
        buf = bytearray([0x61, 0x61])
        buf.extend(int(round(self.soh_pct * 100)).to_bytes(2, "big"))
        gids = int(round(profile.max_gids * (self.real_soc_pct / 100.0) * (self.soh_pct / 100.0)))
        buf.extend(gids.to_bytes(2, "big"))
        usable_kwh = (gids * profile.wh_per_gid) / 1000.0
        buf.extend(int(round(usable_kwh * 100)).to_bytes(2, "big"))
        return bytes(buf)

    def _build_vcm_gear(self) -> bytes:
        code = {"P": 1, "R": 2, "N": 3, "D": 4, "E": 7, "B": 7}.get(self.gear.upper(), 0)
        return bytes([0x62, 0x11, 0x56, code])

    def _build_vcm_speed(self) -> bytes:
        raw = max(0, min(0xFFFF, int(round(self.speed_kmh * 10))))
        return bytes([0x62, 0x12, 0x1A, (raw >> 8) & 0xFF, raw & 0xFF])

    def _build_vcm_ambient(self) -> bytes:
        fahrenheit = self.ambient_temp_c * 9.0 / 5.0 + 32.0
        temp_byte = int(round(fahrenheit + 41)) & 0xFF
        return bytes([0x62, 0x11, 0x5D, 0x7F, temp_byte, 0x7F, 0x00])

    def _build_odometer(self) -> bytes:
        odo = int(self.odometer_km) & 0xFFFFFF
        return bytes([0x62, 0x0E, 0x01, (odo >> 16) & 0xFF, (odo >> 8) & 0xFF, odo & 0xFF])

    def _build_tpms(self) -> bytes:
        buf = bytearray([0x61, 0x0E])
        for psi in self.tpms_psi:
            buf.append(int(round(psi / 0.25)) & 0xFF)
        return bytes(buf)

    def _build_uds_dtcs(self) -> bytes:
        buf = bytearray([0x59, 0x02, 0xFF])
        for entry in self.active_dtcs:
            buf.extend(entry)
        return bytes(buf)
