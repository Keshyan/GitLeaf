# GitLeaf — Modern iOS Nissan Leaf Telemetry & Diagnostics App

**GitLeaf** brings full **LeafSpy Pro** capability to a modern, glanceable **SwiftUI (iOS 17+)** interface with broad market OBD2 adapter compatibility (BLE 4.0/5.0, Wi-Fi TCP, and MFi Bluetooth) and a built-in **Virtual Leaf Demo Mode**.

---

## Features
- **Cockpit**: Live real BMS SoC vs Dash SoC ring, GIDs & usable kWh, live kW power draw/regen, SOH/Hx/Ahr, pack temperature, estimated range, and TPMS alert strip.
- **Battery Lab**: Interactive 96-cell voltage chart (`Swift Charts`), ΔmV balance spread, automatic weak-cell flagging, active shunt balancing indicators, and QC / L1-L2 charge counters.
- **Trip & Energy**: Elevation-aware Eco / Normal / Highway range estimator, odometer, ambient temp, and climate load.
- **Diagnostics & Service**: 4-wheel TPMS pressure monitor, multi-ECU UDS DTC scanner & clearer, and LeafSpy Pro service toggles (VSP pedestrian sound, auto door lock, headlight delay, TPMS registration) gated by a **Park-Only Safety Interlock**.
- **Adapter & Garage**: Multi-generation Leaf support (`ZE0 24`, `AZE0 24/30`, `ZE1 40/62 kWh`) and zero-config discovery for:
  - **BLE 4.0/5.0**: OBDLink CX, Veepeak OBDCheck BLE/BLE+, Vgate iCar Pro BLE 4.0 / vLinker MC+/FD+, LELink / LELink², Carista EVO/BLE, and generic `FFE0`/`FFF0`/`18F0`/Nordic UART adapters.
  - **Wi-Fi TCP**: ELM327 Wi-Fi, Vgate Wi-Fi, KONNWEI KW902/903 (`192.168.0.10:35000`).
  - **MFi Bluetooth**: OBDLink MX+ / LX (`com.obdlink.protocol`).

---

## Building the iOS App (macOS / GitHub Actions)
1. **Local macOS + Xcode 15.4+**:
   ```bash
   cd workspace/ios
   brew install xcodegen
   xcodegen generate
   open GitLeaf.xcodeproj
   ```
2. **Run Swift Core Unit Tests**:
   ```bash
   cd workspace/ios
   swift test
   ```
3. **Automated CI**: Push to GitHub to trigger [ios-ci.yml](ios/.github/workflows/ios-ci.yml) on `macos-14`.

---

## Local Verification (Windows / Python Protocol Core)
Run the `dev-squad` verification gate against the reference Nissan Leaf CAN/ISO-TP/ELM327 engine and Virtual Leaf simulator:
```bash
python ../../.agent/skills/dev-squad/scripts/verify.py .
```
