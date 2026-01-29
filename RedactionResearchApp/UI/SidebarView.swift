import SwiftUI
import SwiftData

/// Sidebar for selecting the active Case.
///
/// We persist selection using AppStorage so other views (e.g., ContentView) can filter to "case only"
/// without requiring a separate shared app-state file.
struct SidebarView: View {
    @Query(sort: \CaseModel.createdAt, order: .reverse) private var cases: [CaseModel]

    @AppStorage("workspace.selectedCaseID") private var selectedCaseIDString: String = ""

    private var selectedCaseID: UUID? {
        UUID(uuidString: selectedCaseIDString)
    }

    private var selectionBinding: Binding<UUID?> {
        Binding<UUID?>(
            get: { UUID(uuidString: selectedCaseIDString) },
            set: { newValue in
                selectedCaseIDString = newValue?.uuidString ?? ""
            }
        )
    }

    var body: some View {
        List(selection: selectionBinding) {
            Section("Cases") {
                if cases.isEmpty {
                    Text("No cases yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(cases) { c in
                        HStack(spacing: 8) {
                            Image(systemName: (c.id == selectedCaseID) ? "folder.fill" : "folder")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name)
                                    .lineLimit(1)
                                if let created = c.createdAt as Date? {
                                    Text(created.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .tag(c.id)
                    }
                }
            }

            Section("Clusters") {
                // These are navigational placeholders; cluster computation is case-scoped elsewhere.
                Label("Duplicates", systemImage: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                Label("Variants", systemImage: "rectangle.stack.badge.plus")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Workspace")
        .onAppear {
            // If nothing selected yet, default to the most recent case.
            if selectedCaseID == nil, let first = cases.first {
                selectedCaseIDString = first.id.uuidString
            }
        }
    }
}
