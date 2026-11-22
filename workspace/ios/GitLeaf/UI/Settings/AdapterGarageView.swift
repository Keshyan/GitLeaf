import SwiftUI

struct AdapterGarageView: View {
    @EnvironmentObject var vm: GitLeafViewModel

    var body: some View {
        NavigationStack {
            List {
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
