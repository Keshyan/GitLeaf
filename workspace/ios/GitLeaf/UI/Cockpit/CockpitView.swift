import SwiftUI

struct CockpitView: View {
    @EnvironmentObject var vm: GitLeafViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Connection Status Pill
                    HStack {
                        Circle()
                            .fill(vm.isConnected ? Color.green : Color.orange)
                            .frame(width: 9, height: 9)
                        Text(vm.isConnected ? "\(vm.selectedAdapter.displayName) • \(vm.latencyMs) ms" : vm.statusBanner)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !vm.isConnected {
                            Button("Demo") {
                                Task { await vm.connectDemo() }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                    // Hero Real BMS SoC vs Dash SoC Gauge
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.1), lineWidth: 18)
                        Circle()
                            .trim(from: 0, to: CGFloat(vm.battery.realSocPct / 100.0))
                            .stroke(
                                AngularGradient(
                                    colors: [.mint, .cyan, .green],
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 18, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .animation(.spring(response: 0.6), value: vm.battery.realSocPct)

                        VStack(spacing: 4) {
                            Text(String(format: "%.1f%%", vm.battery.realSocPct))
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                            Text(String(format: "Dash %.1f%% • %d GIDs", vm.battery.dashSocPct, vm.battery.gids))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.2f kWh usable", vm.battery.remainingKwh))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.mint)
                        }
                    }
                    .frame(width: 220, height: 220)
                    .padding(.vertical, 8)

                    // 4-Tile Live Electrical & Health Grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        MetricCard(title: "LIVE POWER", value: String(format: "%+.2f kW", vm.battery.powerKw), sub: String(format: "%.1f V • %.1f A", vm.battery.packVoltageV, vm.battery.packCurrentA), accent: vm.battery.powerKw < 0 ? .green : .cyan)
                        MetricCard(title: "BATTERY SOH", value: String(format: "%.1f%%", vm.battery.sohPct), sub: String(format: "Hx %.1f%% • %.1f Ah", vm.battery.hxPct, vm.battery.ahr), accent: .mint)
                        MetricCard(title: "PACK TEMP", value: String(format: "%.1f °C", vm.temps.avgC), sub: String(format: "Min %.0f° / Max %.0f°", vm.temps.minC, vm.temps.maxC), accent: .orange)
                        MetricCard(title: "EST. RANGE", value: String(format: "%.0f km", LeafCANParser.estimateRangeKm(remainingKwh: vm.battery.remainingKwh)), sub: "Normal (155 Wh/km)", accent: .blue)
                    }

                    // Quick TPMS Alert Strip
                    let lowWheels = vm.tpms.lowPressureWheels()
                    HStack {
                        Image(systemName: lowWheels.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(lowWheels.isEmpty ? .green : .yellow)
                        Text(lowWheels.isEmpty
                             ? "All 4 Tires Healthy (FL \(String(format: "%.1f", vm.tpms.flPsi)) • FR \(String(format: "%.1f", vm.tpms.frPsi)) PSI)"
                             : "Low Tire Pressure Alert: \(lowWheels.joined(separator: ", "))")
                            .font(.footnote.weight(.medium))
                        Spacer()
                    }
                    .padding(14)
                    .background(lowWheels.isEmpty ? Color.green.opacity(0.12) : Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                }
                .padding()
            }
            .navigationTitle("GitLeaf Cockpit")
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let sub: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(accent)
            Text(sub)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}
