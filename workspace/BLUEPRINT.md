# GitLeaf — Product & Technical Blueprint (v2.0)

## 1. Vision & Product Positioning
**GitLeaf** is a next-generation iOS application for Nissan Leaf owners (ZE0 2011–2012, AZE0 2013–2017, ZE1 2018–2025) delivering **full LeafSpy Pro feature parity** wrapped in a clean, modern, Apple HIG-compliant SwiftUI interface. Unlike legacy diagnostic tools cluttered with dense hex tables and manual adapter setup, GitLeaf provides:
- **Zero-friction OBD2 onboarding**: Auto-detects BLE, Wi-Fi, and MFi adapters, probes chip capabilities (STN2120/STN1110, genuine ELM327 v1.5, or clone v2.1), and negotiates optimal Leaf CAN polling automatically.
- **Glanceable, modern EV UI**: High-contrast dark/light OLED cockpit, interactive 96-cell battery health visuals, elevation-aware range & energy analytics, and guided one-tap diagnostics.
- **Built-in Demo / Virtual Leaf Mode**: Explore every screen and test UI flows without being plugged into a car.

---

## 2. Full LeafSpy Feature Parity Map & Modern 5-Tab UX

| Tab | LeafSpy Equivalent | Modern GitLeaf UX |
|---|---|---|
| **1. Cockpit** | Screen 4 (Summary / Driving) | Glanceable live SoC ring (Real BMS SoC vs Dash SoC), GIDs & remaining kWh, live kW power bar (draw vs regen), motor/inverter/battery temps, real-time range rings (Eco / Normal / Highway), quick-glance TPMS status pill. |
| **2. Battery Lab** | Screen 1 (Cell Voltages) & Screen 2 (Temps/SOH) | Interactive **96-cell bar & heatmap** (min/avg/max mV, ΔmV spread alert, live balancing shunt indicators), SOH%, Hx%, Ahr, 4 battery pack thermistors, QC & L1/L2 charge counters, historical SOH/Hx degradation chart (Swift Charts). |
| **3. Trip & Energy** | Trip Log / Elevation / Wh/km | Live trip recorder (Wh/km, kWh used, regen recovered, ambient temp, elevation delta), route efficiency chart, CSV / JSON / ABRP-compatible telemetry export. |
| **4. Diagnostics & Service** | DTC Read/Clear, Service Screen, TPMS | Multi-ECU DTC scanner (LBC, VCM, Charger/OBC, Inverter, BCM, ABS, HVAC) with human-readable fault descriptions & severity badges; 4-wheel TPMS PSI/Bar/kPa cards + registration workflow; Service controls (VSP pedestrian sound toggles, auto door lock/unlock, headlight delay) protected by a **Park-Only Safety Interlock**. |
| **5. Adapter & Garage** | Settings & Connection | One-tap Auto-Connect scanner, adapter health & latency badge (ms/frame), chip capability profile (ELM327/STN), multi-vehicle Leaf garage (24/30/40/62 kWh auto-detected from VIN/LBC), units (km/mi, °C/°F, PSI/Bar/kPa), Safe Read-Only Mode toggle, Demo Simulator toggle. |

---

## 3. Broad Market OBD2 Adapter Compatibility Matrix (iOS)

Because iOS restricts classic Bluetooth SPP (BR/EDR) to MFi-certified accessories, GitLeaf implements a **unified `OBDTransport` protocol** supporting all three iOS-legal physical transports:

1. **Bluetooth Low Energy (CoreBluetooth BLE 4.0 / 5.0)** — *Covers ~85% of modern iOS OBD2 adapters*:
   - **Veepeak OBDCheck BLE / BLE+** (`FFF0` / `FFF1` / `FFF2`)
   - **Vgate iCar Pro BLE 4.0 / vLinker MC+ / FD+ / BM+** (`18F0` / `2AF0` / `2AF1` & `FFE0`)
   - **OBDLink CX** (`FFF0` / STN2255 chip — high-speed `ST` commands)
   - **LELink / LELink²** (`FFE0` / `FFE1`)
   - **Carista EVO / BLE** (`FFE0` / `FFF0`)
   - **Generic ELM327 BLE 4.0 adapters** (dynamic GATT service/characteristic discovery for `FFE0`, `FFF0`, `18F0`, `E7810A71-...`, Nordic UART `6E400001-...`).
2. **Wi-Fi TCP Socket (`NWConnection` via Network.framework)** — *Covers legacy & budget ELM327 Wi-Fi*:
   - Default `192.168.0.10:35000` (plus configurable IP/port for Vgate iCar Wi-Fi, KONNWEI KW902/903 Wi-Fi, generic ELM327 Wi-Fi).
3. **MFi Classic Bluetooth (`ExternalAccessory` framework)** — *Covers pro-grade MFi adapters*:
   - **OBDLink MX+ / LX** (`com.obdlink.protocol` / STN2120 — ultra-fast CAN streaming).
4. **Virtual Leaf Simulator Transport**:
   - In-app deterministic mock ELM327/CAN responder for offline UI testing, demos, and automated unit tests.

### Adapter Auto-Probing & Quirk Mitigation State Machine
1. `ATZ` (reset) → `ATE0` (echo off) → `ATI` (identify ELM version) → `STI` (probe STN chip).
2. Classify adapter tier:
   - **Tier 1 (STN11xx / STN21xx / STN22xx)**: Enable `STFAP` hardware CAN filtering, high baud/flow-control, 5–10 Hz telemetry.
   - **Tier 2 (Genuine ELM327 v1.4b/v1.5)**: Standard `ATSP6` (ISO 15765-4 CAN 11-bit 500 kbps), `ATCAF0`, `ATCFC1`, `ATSH`, `ATCRA`, `ATFCSD`/`ATFCSM1` ISO-TP multi-frame flow control.
   - **Tier 3 (Budget Clone v2.1)**: Detect rejected `ATFCSM1`/`ATCFC1` commands cleanly, fall back to software-paced single-frame / flow-control `30 00 00` frames, and show a clear non-blocking compatibility badge in the Adapter tab if a clone lacks required ISO-TP commands.

---

## 4. Nissan Leaf CAN / UDS Protocol Specification

- **Bus**: EV-CAN / CAR-CAN (500 kbps, 11-bit standard IDs, `ATSP6`).
- **ISO-TP (ISO 15765-2) Multi-Frame Reassembly**:
  - Single Frame (`0x0N`), First Frame (`0x1N NN`), Consecutive Frames (`0x21..0x2F` with wraparound), Flow Control (`30 00 00`).
- **Primary ECUs & Request/Response IDs**:
  - **LBC (Lithium Battery Controller)**: TX `0x79B` / RX `0x7BB`
    - `21 01` (Group 1): Pack Voltage, Pack Current (signed 32-bit), Hx, Real SoC, Ahr (capacity), SOH%, GIDs, Quick Charge count, L1/L2 count.
    - `21 02` (Group 2): All **96 cell pair voltages** (2 bytes/cell in mV, 192 bytes payload).
    - `21 04` (Group 4): 4 battery pack thermistors (raw ADC → °C lookup / linear conversion for ZE0/AZE0/ZE1) + heater status.
    - `21 06` (Group 6): 96-cell shunt balancing bitmask.
    - `21 61` (ZE1 / 40 & 62 kWh extended): Extended capacity, SOH, and high-res GIDs.
  - **VCM (Vehicle Control Module)**: TX `0x797` / RX `0x79A` — VIN, odometer, ambient temp, gear/speed interlock check, climate kW.
  - **OBC / Charger**: TX `0x792` / RX `0x793` — AC pilot amps, charger power, voltage.
  - **BCM / TPMS**: TX `0x745` / RX `0x765` — 4-wheel tire pressures (raw × 0.25 PSI) + service settings (auto-lock, headlight delay).
  - **VSP (Vehicle Sound for Pedestrians)**: TX `0x74B` / RX `0x76B` — VSP sound configuration.
  - **DTC Reading & Clearing**: Standard UDS Service `0x19 02 FF` (Read DTCs by status mask) and `0x14 FF FF FF` (Clear DTCs) per ECU.
- **Model Capacity Profiles**:
  - `ZE0_24`: 24 kWh (281 max GIDs, ~77.5 Wh/GID)
  - `AZE0_24`: 24 kWh (281 max GIDs)
  - `AZE0_30`: 30 kWh (363 max GIDs)
  - `ZE1_40`: 40 kWh (502 max GIDs)
  - `ZE1_62`: 62 kWh (775 max GIDs)

---

## 5. Safety & Security Architecture
- **Park-Only Safety Interlock**: Any write/service command (DTC clear, BCM settings, VSP toggles, TPMS register) is hard-blocked unless:
  1. `Safe Read-Only Mode` is explicitly turned OFF,
  2. Live vehicle speed == `0 km/h` AND gear == `P` (verified via VCM frame),
  3. User confirms an explicit destructive/write action modal.
- **Zero Cloud Lock-in**: All telemetry and trip logs stay local on-device (`SwiftData`), with user-initiated export only.

---

## 6. Repository Architecture & Dual-Track Verification Strategy

Because the development workstation is Windows (no local Xcode compiler), `GitLeaf` is structured in two cleanly synchronized tracks inside `GitLeaf/workspace/`:

```text
GitLeaf/
└── workspace/
    ├── BLUEPRINT.md                     # This approved architecture document
    ├── agent_comms.md                   # Dev-Squad inter-agent communication log
    ├── protocol_core/                   # Verified Python Reference & Virtual Leaf Simulator
    │   ├── __init__.py
    │   ├── isotp.py                     # ISO-TP multi-frame assembler & parser
    │   ├── obd_adapter.py               # Adapter catalog, GATT/Wi-Fi/MFi profiles & AT/STN probe state machine
    │   ├── leaf_protocol.py             # LBC/VCM/TPMS/DTC decoders (ZE0/AZE0/ZE1) + safety interlock
    │   └── simulator.py                 # Virtual ELM327 + Nissan Leaf ECU responder
    ├── test_main.py                     # Comprehensive Pytest suite verified by dev-squad verify.py
    └── ios/                             # Native iOS SwiftUI App (iOS 17+, XcodeGen + GitHub Actions CI)
        ├── project.yml                  # XcodeGen spec (generates GitLeaf.xcodeproj on macOS)
        ├── Package.swift                # Swift Package for GitLeafCore (swift test on macOS/Linux)
        ├── .github/workflows/ios-ci.yml # Automated macOS CI build & unit test workflow
        └── GitLeaf/
            ├── App/GitLeafApp.swift
            ├── Core/
            │   ├── Models/              # LeafModels.swift, AdapterProfile.swift, DTCModels.swift
            │   ├── Transport/           # OBDTransport.swift, BLETransport.swift, WiFiTransport.swift, MFiTransport.swift, MockTransport.swift
            │   └── Protocol/            # ISOTPAssembler.swift, ELM327Session.swift, LeafCANParser.swift, SafetyInterlock.swift
            └── UI/
                ├── Theme/GitLeafTheme.swift
                ├── Cockpit/CockpitView.swift
                ├── BatteryLab/BatteryLabView.swift
                ├── Trip/TripView.swift
                ├── Diagnostics/DiagnosticsView.swift
                └── Settings/AdapterGarageView.swift
```

### Verification Plan
1. **Local Windows Verification (`dev-squad` Gate)**: `python .agent/skills/dev-squad/scripts/verify.py GitLeaf/workspace` runs `ruff` static analysis and `pytest` against `test_main.py` covering ISO-TP reassembly, all Leaf generation decoders (96 cells, thermistors, SOH/Hx/GIDs, TPMS, DTCs), adapter probing & v2.1 clone fallback, and the Park-Only safety interlock.
2. **iOS Verification**: `Package.swift` + XcodeGen `project.yml` + GitHub Actions `macos-latest` workflow compiles and runs `XCTest` for the SwiftUI & CoreBluetooth/Network codebase.
