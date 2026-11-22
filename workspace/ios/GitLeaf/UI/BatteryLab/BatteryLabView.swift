import SwiftUI
import Charts

struct BatteryLabView: View {
    @EnvironmentObject var vm: GitLeafViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Cell Spread Summary Header
                    HStack(spacing: 12) {
                        MetricCard(title: "CELL DELTA", value: "\(vm.cells.deltaMv) mV", sub: vm.cells.deltaMv > 30 ? "Inspect weak cell" : "Pack well balanced", accent: vm.cells.deltaMv > 30 ? .orange : .green)
                        MetricCard(title: "MIN / AVG / MAX", value: "\(vm.cells.minMv) mV", sub: String(format: "Avg %.0f • Max %d mV", vm.cells.avgMv, vm.cells.maxMv), accent: .cyan)
                    }

                    // 96-Cell Interactive Voltage Bar Chart
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("96-Cell Pair Voltages (mV)")
                                .font(.headline)
                            Spacer()
                            if !vm.cells.weakCellIndices.isEmpty {
                                Text("Weak: #\(vm.cells.weakCellIndices.map(String.init).joined(separator: ", #"))")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.orange)
                            }
                        }

                        Chart(Array(vm.cells.voltagesMv.enumerated()), id: \.offset) { index, mv in
                            let isWeak = vm.cells.weakCellIndices.contains(index + 1)
                            let isBalancing = index < vm.cells.shuntActive.count && vm.cells.shuntActive[index]
                            BarMark(
                                x: .value("Cell", index + 1),
                                yStart: .value("Floor", max(3000, vm.cells.minMv - 25)),
                                yEnd: .value("mV", mv)
                            )
                            .foregroundStyle(isWeak ? Color.red : (isBalancing ? Color.yellow : Color.mint))
                        }
                        .chartYScale(domain: max(3000, vm.cells.minMv - 25)...(vm.cells.maxMv + 15))
                        .frame(height: 220)

                        HStack(spacing: 14) {
                            Label("Normal", systemImage: "circle.fill").foregroundStyle(.mint)
                            Label("Shunt Balancing", systemImage: "circle.fill").foregroundStyle(.yellow)
                            Label("Weak Cell", systemImage: "circle.fill").foregroundStyle(.red)
                        }
                        .font(.caption2)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))

                    // Charge Counters & Thermistors
                    HStack(spacing: 12) {
                        MetricCard(title: "QUICK CHARGES", value: "\(vm.battery.qcCount)", sub: "CHAdeMO DC Fast", accent: .yellow)
                        MetricCard(title: "L1 / L2 CHARGES", value: "\(vm.battery.l1L2Count)", sub: "AC Home / Public", accent: .green)
                    }

                    // Historical SOH & Hx Degradation Trend
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("SOH & Hx Health Trend")
                                .font(.headline)
                            Spacer()
                            Button("Log Snapshot") {
                                vm.logSOHSnapshot()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }

                        Chart(vm.sohHistory) { snap in
                            LineMark(
                                x: .value("Date", snap.date),
                                y: .value("SOH %", snap.sohPct)
                            )
                            .foregroundStyle(.mint)
                            .symbol(.circle)

                            LineMark(
                                x: .value("Date", snap.date),
                                y: .value("Hx %", snap.hxPct)
                            )
                            .foregroundStyle(.cyan)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        }
                        .chartYScale(domain: 60...100)
                        .frame(height: 150)

                        HStack(spacing: 14) {
                            Label("SOH %", systemImage: "line.diagonal").foregroundStyle(.mint)
                            Label("Hx %", systemImage: "line.diagonal").foregroundStyle(.cyan)
                            Spacer()
                            Text("\(vm.sohHistory.count) logs").foregroundStyle(.secondary)
                        }
                        .font(.caption2)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                }
                .padding()
            }
            .navigationTitle("Battery Lab")
        }
    }
}
