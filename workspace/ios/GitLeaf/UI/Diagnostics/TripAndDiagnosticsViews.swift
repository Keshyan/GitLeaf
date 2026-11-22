import SwiftUI

struct TripEnergyView: View {
    @EnvironmentObject var vm: GitLeafViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Elevation-Aware Range Estimator") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Planned Elevation Change")
                            Spacer()
                            Text(String(format: "%+.0f m", vm.elevationGainM))
                                .font(.headline.monospacedDigit())
                        }
                        Slider(value: $vm.elevationGainM, in: -800...1200, step: 25)
                    }

                    RangeRow(label: "Eco (130 Wh/km)", km: LeafCANParser.estimateRangeKm(remainingKwh: vm.battery.remainingKwh, whPerKm: 130, elevationGainM: vm.elevationGainM), color: .green)
                    RangeRow(label: "Normal (155 Wh/km)", km: LeafCANParser.estimateRangeKm(remainingKwh: vm.battery.remainingKwh, whPerKm: 155, elevationGainM: vm.elevationGainM), color: .cyan)
                    RangeRow(label: "Highway (195 Wh/km)", km: LeafCANParser.estimateRangeKm(remainingKwh: vm.battery.remainingKwh, whPerKm: 195, elevationGainM: vm.elevationGainM), color: .orange)
                }

                Section("Vehicle Telemetry") {
                    LabeledContent("Odometer", value: "\(vm.vcm.odometerKm) km")
                    LabeledContent("Ambient Temp", value: String(format: "%.1f °C", vm.vcm.ambientTempC))
                    LabeledContent("Climate Draw", value: String(format: "%.2f kW", vm.vcm.climateKw))
                }
            }
            .navigationTitle("Trip & Energy")
        }
    }
}

private struct RangeRow: View {
    let label: String
    let km: Double
    let color: Color

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(String(format: "%.1f km", km))
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
        }
    }
}

struct DiagnosticsServiceView: View {
    @EnvironmentObject var vm: GitLeafViewModel
    @State private var pendingCommand: ServiceCommandType?
    @State private var feedbackMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("TPMS 4-Wheel Tire Pressure (PSI)") {
                    HStack {
                        TPMSBadge(wheel: "FL", psi: vm.tpms.flPsi)
                        TPMSBadge(wheel: "FR", psi: vm.tpms.frPsi)
                        TPMSBadge(wheel: "RL", psi: vm.tpms.rlPsi)
                        TPMSBadge(wheel: "RR", psi: vm.tpms.rrPsi)
                    }
                }

                Section("Diagnostic Trouble Codes (\(vm.dtcs.count))") {
                    if vm.dtcs.isEmpty {
                        Label("All ECUs Clean — 0 Active DTCs", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        ForEach(vm.dtcs) { dtc in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(dtc.ecu) • \(dtc.code)")
                                        .font(.headline.monospaced())
                                    Spacer()
                                    Text(dtc.severity)
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(dtc.severity == "CRITICAL" ? Color.red.opacity(0.25) : Color.orange.opacity(0.25), in: Capsule())
                                }
                                Text(dtc.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("LeafSpy Pro Service Controls (Park-Only Interlock)") {
                    Toggle("Safe Read-Only Mode", isOn: $vm.readOnlySafeMode)
                    ForEach(ServiceCommandType.allCases) { cmd in
                        Button(cmd.rawValue) {
                            pendingCommand = cmd
                        }
                        .disabled(vm.readOnlySafeMode)
                    }
                    if let msg = feedbackMessage {
                        Text(msg).font(.caption).foregroundStyle(.mint)
                    }
                }
            }
            .navigationTitle("Diagnostics & Service")
            .confirmationDialog(
                "Confirm ECU Service Command",
                isPresented: Binding(get: { pendingCommand != nil }, set: { if !$0 { pendingCommand = nil } }),
                titleVisibility: .visible
            ) {
                if let cmd = pendingCommand {
                    Button("Execute \(cmd.rawValue)", role: .destructive) {
                        Task {
                            let res = await vm.executeServiceCommand(cmd, confirmed: true)
                            switch res {
                            case .success(let ok): feedbackMessage = ok
                            case .failure(let err): feedbackMessage = err.localizedDescription
                            }
                        }
                    }
                }
            } message: {
                Text("Requires Park (P), 0 km/h, and Safe Read-Only Mode disabled.")
            }
        }
    }
}

private struct TPMSBadge: View {
    let wheel: String
    let psi: Double

    var body: some View {
        VStack(spacing: 4) {
            Text(wheel).font(.caption2.bold()).foregroundStyle(.secondary)
            Text(String(format: "%.1f", psi))
                .font(.headline.monospacedDigit())
                .foregroundStyle(psi < 32.0 ? .orange : .mint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
