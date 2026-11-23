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
                            .fill(statusColor)
                            .frame(width: 9, height: 9)
                        Text(statusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(badgeTitle)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(badgeColor.opacity(0.2), in: Capsule())
                            .foregroundStyle(badgeColor)
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
                            Text(waiting ? "—" : String(format: "%.1f%%", vm.battery.realSocPct))
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                            Text(waiting ? "Waiting for car data" : String(format: "Dash %.1f%% • %d GIDs", vm.battery.dashSocPct, vm.battery.gids))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(waiting ? "—" : String(format: "%.2f kWh usable", vm.battery.remainingKwh))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.mint)
                        }
                    }
                    .frame(width: 220, height: 220)
                    .padding(.vertical, 8)

                    // 4-Tile Live Electrical & Health Grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        MetricCard(title: "LIVE POWER", value: waiting ? "—" : String(format: "%+.2f kW", vm.battery.powerKw), sub: waiting ? "Waiting for car data" : String(format: "%.1f V • %.1f A", vm.battery.packVoltageV, vm.battery.packCurrentA), accent: vm.battery.powerKw < 0 ? .green : .cyan)
                        MetricCard(title: "BATTERY SOH", value: waiting ? "—" : String(format: "%.1f%%", vm.battery.sohPct), sub: waiting ? "—" : String(format: "Hx %.1f%% • %.1f Ah", vm.battery.hxPct, vm.battery.ahr), accent: .mint)
                        MetricCard(title: "PACK TEMP", value: waiting ? "—" : String(format: "%.1f °C", vm.temps.avgC), sub: waiting ? "—" : String(format: "Min %.0f° / Max %.0f°", vm.temps.minC, vm.temps.maxC), accent: .orange)
                        MetricCard(title: "EST. RANGE", value: waiting ? "—" : String(format: "%.0f km", LeafCANParser.estimateRangeKm(remainingKwh: vm.battery.remainingKwh)), sub: waiting ? "—" : "Normal (155 Wh/km)", accent: .blue)
                    }

                    if waiting {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.yellow)
                            Text(vm.statusBanner)
                                .font(.footnote.weight(.medium))
                            Spacer()
                        }
                        .padding(14)
                        .background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                    } else {
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
                }
                .padding()
            }
            .navigationTitle("GitLeaf Cockpit")
        }
    }

    private var waiting: Bool { vm.telemetryPhase == .waiting }

    private var statusColor: Color {
        switch vm.telemetryPhase {
        case .live: return .green
        case .waiting: return .yellow
        case .demo: return vm.isConnected ? .orange : .orange
        }
    }

    private var badgeTitle: String {
        switch vm.telemetryPhase {
        case .live: return "LIVE"
        case .waiting: return "WAITING"
        case .demo: return "DEMO"
        }
    }

    private var badgeColor: Color {
        switch vm.telemetryPhase {
        case .live: return .green
        case .waiting: return .yellow
        case .demo: return .orange
        }
    }

    private var statusText: String {
        switch vm.telemetryPhase {
        case .live:
            return "\(vm.selectedAdapter.displayName) • \(vm.latencyMs) ms"
        case .waiting:
            return "Waiting for car data"
        case .demo:
            return vm.isConnected ? "\(vm.selectedAdapter.displayName) • \(vm.latencyMs) ms" : vm.statusBanner
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
