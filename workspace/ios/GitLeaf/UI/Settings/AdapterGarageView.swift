import SwiftUI

struct AdapterGarageView: View {
    @EnvironmentObject var vm: GitLeafViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Connection Status") {
                    HStack {
                        Label(vm.isConnected ? "Connected (\(vm.adapterTier.rawValue))" : "Disconnected",
                              systemImage: vm.isConnected ? "checkmark.circle.fill" : "bolt.slash")
                            .foregroundStyle(vm.isConnected ? .mint : .secondary)
                        Spacer()
                        if vm.isConnected {
                            Button("Disconnect", role: .destructive) {
                                vm.disconnect()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                    if let warning = vm.adapterWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Wi-Fi OBD2 Endpoint") {
                    HStack {
                        Text("Host IP")
                        Spacer()
                        TextField("192.168.0.10", text: $vm.wifiHost)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    HStack {
                        Text("TCP Port")
                        Spacer()
                        TextField("35000", text: $vm.wifiPort)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                }

                Section("My Nissan Leaf Garage") {
                    Picker("Leaf Model / Battery", selection: $vm.selectedGeneration) {
                        ForEach(LeafGeneration.allCases) { gen in
                            Text(gen.displayName).tag(gen)
                        }
                    }
                    .onChange(of: vm.selectedGeneration) { _, _ in
                        vm.refreshTelemetry()
                    }
                }

                Section("Supported Market OBD2 Adapters") {
                    ForEach(AdapterCatalog.all) { adapter in
                        Button {
                            vm.selectedAdapter = adapter
                            Task { await vm.connectSelectedAdapter() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(adapter.displayName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("\(adapter.transport.rawValue) • \(adapter.expectedTier.rawValue)")
                                        .font(.caption2)
                                        .foregroundStyle(.mint)
                                    if !adapter.notes.isEmpty {
                                        Text(adapter.notes)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if vm.selectedAdapter.id == adapter.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.mint)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Adapter & Garage")
        }
    }
}
