"""ISO 15765-2 (ISO-TP) Multi-Frame CAN Reassembler for ELM327 / STN Responses."""

from __future__ import annotations

import re
from dataclasses import dataclass

_NOISE_TOKENS = {
    "SEARCHING...",
    "NO DATA",
    "STOPPED",
    "BUS INIT",
    "OK",
    "?",
    "",
}

_HEX_BYTE_RE = re.compile(r"^[0-9A-Fa-f]+$")


class ISOTPError(ValueError):
    """Raised when ISO-TP frames are malformed, incomplete, or out of sequence."""


@dataclass(frozen=True)
class CANFrame:
    """Single 8-byte CAN frame parsed from an ELM327 response line."""

    arb_id: int | None
    data: bytes


def parse_elm_hex_lines(raw_response: str, expected_rx_id: int | None = None) -> list[CANFrame]:
    """Parse raw ELM327/STN text output into CANFrame records.

    Supports both header-on (`ATH1`, e.g. `7BB 10 C2 61 02 ...`) and header-off
    (`ATH0`, e.g. `10 C2 61 02 ...` or ELM line-numbered `0: 61 02 ...`).
    """
    frames: list[CANFrame] = []
    cleaned = raw_response.replace("\r", "\n").replace(">", "")

    for raw_line in cleaned.splitlines():
        line = raw_line.strip()
        if not line or line.upper() in _NOISE_TOKENS:
            continue
        if line.upper().startswith("SEARCHING") or line.upper().startswith("BUS INIT"):
            continue

        # Strip optional ELM327 CAF1 line index prefix like "0:" or "1:"
        if len(line) >= 2 and line[1] == ":" and line[0] in "0123456789ABCDEFabcdef":
            line = line[2:].strip()

        tokens = line.split()
        arb_id: int | None = None
        hex_payload = ""

        if len(tokens) >= 2 and len(tokens[0]) == 3 and _HEX_BYTE_RE.match(tokens[0]):
            arb_id = int(tokens[0], 16)
            hex_payload = "".join(tokens[1:])
        elif len(tokens) == 1 and len(tokens[0]) > 3 and len(tokens[0]) % 2 == 1 and _HEX_BYTE_RE.match(tokens[0]):
            # Compact header-on format without spaces: e.g. 7BB10C26102...
            arb_id = int(tokens[0][:3], 16)
            hex_payload = tokens[0][3:]
        else:
            hex_payload = "".join(tokens)

        if not hex_payload or len(hex_payload) % 2 != 0 or not _HEX_BYTE_RE.match(hex_payload):
            continue

        if expected_rx_id is not None and arb_id is not None and arb_id != expected_rx_id:
            continue

        frames.append(CANFrame(arb_id=arb_id, data=bytes.fromhex(hex_payload)))

    return frames


def encode_single_frame(payload: bytes) -> bytes:
    """Encode a <=7-byte UDS/OBD payload into an ISO-TP Single Frame."""
    if not (1 <= len(payload) <= 7):
        raise ISOTPError(f"Single frame payload must be 1..7 bytes, got {len(payload)}")
    return bytes([len(payload)]) + payload


def encode_isotp_frames(payload: bytes, arb_id: int | None = None) -> list[str]:
    """Encode an arbitrary payload into ELM327-formatted ISO-TP hex frame lines.

    Used by the Virtual Leaf Simulator and protocol tests to generate authentic
    multi-frame CAN traffic (including 28-frame 96-cell LBC Group 2 responses).
    """
    prefix = f"{arb_id:03X} " if arb_id is not None else ""
    total_len = len(payload)
    if total_len <= 7:
        frame = bytes([total_len]) + payload
        frame = frame.ljust(8, b"\x00")
        return [prefix + " ".join(f"{b:02X}" for b in frame)]

    if total_len > 4095:
        raise ISOTPError("ISO-TP payload exceeds 4095-byte 12-bit length limit")

    lines: list[str] = []
    # First Frame (0x1000 | total_len) + first 6 bytes
    ff_pci_hi = 0x10 | ((total_len >> 8) & 0x0F)
    ff_pci_lo = total_len & 0xFF
    ff = bytes([ff_pci_hi, ff_pci_lo]) + payload[:6]
    lines.append(prefix + " ".join(f"{b:02X}" for b in ff))

    # Consecutive Frames (0x21..0x2F, wrapping to 0x20, 0x21, ...)
    offset = 6
    seq = 1
    while offset < total_len:
        chunk = payload[offset : offset + 7].ljust(7, b"\x00")
        cf = bytes([0x20 | (seq & 0x0F)]) + chunk
        lines.append(prefix + " ".join(f"{b:02X}" for b in cf))
        offset += 7
        seq = (seq + 1) & 0x0F

    return lines


class ISOTPAssembler:
    """Reassembles ISO 15765-2 Single Frame and First/Consecutive Frame sequences."""

    def assemble(self, frames: list[CANFrame]) -> bytes:
        """Reassemble CAN frames into the complete UDS application payload."""
        if not frames:
            raise ISOTPError("No CAN frames available for ISO-TP assembly")

        first_data = frames[0].data
        if not first_data:
            raise ISOTPError("Empty CAN frame")

        pci_type = (first_data[0] & 0xF0) >> 4

        # Single Frame (0x0N)
        if pci_type == 0x0:
            length = first_data[0] & 0x0F
            if length == 0 or length > len(first_data) - 1:
                raise ISOTPError(f"Invalid Single Frame length {length}")
            return first_data[1 : 1 + length]

        # First Frame (0x1N NN)
        if pci_type == 0x1:
            if len(first_data) < 3:
                raise ISOTPError("Truncated ISO-TP First Frame")
            total_length = ((first_data[0] & 0x0F) << 8) | first_data[1]
            if total_length <= 7:
                raise ISOTPError(f"Invalid First Frame total length {total_length}")

            buffer = bytearray(first_data[2:])
            expected_seq = 1

            for frame in frames[1:]:
                if len(buffer) >= total_length:
                    break
                data = frame.data
                if not data:
                    continue
                frame_type = (data[0] & 0xF0) >> 4
                if frame_type == 0x3:
                    # Flow Control frame echoed on bus; ignore safely
                    continue
                if frame_type != 0x2:
                    raise ISOTPError(f"Expected Consecutive Frame (0x2X), got 0x{data[0]:02X}")

                seq = data[0] & 0x0F
                if seq != expected_seq:
                    raise ISOTPError(
                        f"ISO-TP sequence mismatch: expected 0x2{expected_seq:X}, got 0x2{seq:X}"
                    )
                buffer.extend(data[1:])
                expected_seq = (expected_seq + 1) & 0x0F

            if len(buffer) < total_length:
                raise ISOTPError(
                    f"Incomplete ISO-TP message: received {len(buffer)} of {total_length} bytes"
                )
            return bytes(buffer[:total_length])

        raise ISOTPError(f"Unsupported ISO-TP PCI byte 0x{first_data[0]:02X}")

    def assemble_raw(self, raw_response: str, expected_rx_id: int | None = None) -> bytes:
        """Convenience helper: parse ELM327 text and reassemble ISO-TP payload."""
        frames = parse_elm_hex_lines(raw_response, expected_rx_id=expected_rx_id)
        return self.assemble(frames)
