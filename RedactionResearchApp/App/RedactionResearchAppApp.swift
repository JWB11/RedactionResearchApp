import SwiftUI
import SwiftData

@main
struct RedactionResearchAppApp: App {
    @Environment(\.openWindow) private var openWindow

    @StateObject private var traceStore = TraceStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(traceStore)
        }
        .modelContainer(for: RedactionResearchSchemaV2.self, migrationPlan: RedactionResearchMigrationPlan.self)

        // Secondary window: live execution trace
        WindowGroup("Execution Trace", id: "execution-trace") {
            TraceWindowView()
                .environmentObject(traceStore)
        }

        Settings {
            SettingsView()
                .environmentObject(traceStore)
        }

        .commands {
            CommandGroup(after: .windowArrangement) {
                Divider()
                Button("Show Execution Trace") {
                    openWindow(id: "execution-trace")
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }
}

// MARK: - Execution Trace

/// A structured, copy/paste-friendly trace of what the app is doing (not model chain-of-thought).
struct TraceEvent: Identifiable, Sendable, Hashable {
    enum Level: String, CaseIterable, Sendable {
        case debug
        case info
        case warning
        case error
    }

    let id: UUID
    let timestamp: Date
    let level: Level
    let stage: String
    let message: String
    let filePath: String?
    let metadata: [String: String]

    init(level: Level = .info, stage: String, message: String, filePath: String? = nil, metadata: [String: String] = [:]) {
        self.id = UUID()
        self.timestamp = Date()
        self.level = level
        self.stage = stage
        self.message = message
        self.filePath = filePath
        self.metadata = metadata
    }
}

@MainActor
final class TraceStore: ObservableObject {
    @Published private(set) var events: [TraceEvent] = []

    func log(_ event: TraceEvent) {
        events.append(event)
        // Keep memory bounded for v1
        if events.count > 10_000 {
            events.removeFirst(events.count - 10_000)
        }
    }

    func clear() {
        events.removeAll()
    }

    func exportText() -> String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .medium

        return events.map { ev in
            let ts = df.string(from: ev.timestamp)
            let fp = ev.filePath.map { "\n  file: \($0)" } ?? ""
            let meta: String
            if ev.metadata.isEmpty {
                meta = ""
            } else {
                meta = "\n  meta: " + ev.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            }
            return "[\(ts)] \(ev.level.rawValue.uppercased()) \(ev.stage): \(ev.message)\(fp)\(meta)"
        }.joined(separator: "\n")
    }
}

struct TraceWindowView: View {
    @EnvironmentObject private var trace: TraceStore

    @State private var searchText: String = ""
    @State private var selectedLevel: TraceEvent.Level? = nil

    private var filtered: [TraceEvent] {
        var out = trace.events

        if let lvl = selectedLevel {
            out = out.filter { $0.level == lvl }
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            out = out.filter {
                $0.stage.localizedCaseInsensitiveContains(q) ||
                $0.message.localizedCaseInsensitiveContains(q) ||
                ($0.filePath?.localizedCaseInsensitiveContains(q) ?? false) ||
                $0.metadata.values.contains(where: { $0.localizedCaseInsensitiveContains(q) })
            }
        }

        return out
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Level", selection: $selectedLevel) {
                    Text("All").tag(TraceEvent.Level?.none)
                    ForEach(TraceEvent.Level.allCases, id: \.self) { lvl in
                        Text(lvl.rawValue.uppercased()).tag(Optional(lvl))
                    }
                }
                .pickerStyle(.menu)

                Spacer()

                Button("Copy All") {
                    #if canImport(AppKit)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(trace.exportText(), forType: .string)
                    #endif
                }

                Button("Clear") {
                    trace.clear()
                }
            }

            List(filtered) { ev in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(ev.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text(ev.level.rawValue.uppercased())
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.gray.opacity(0.12))
                            .clipShape(Capsule())

                        Text(ev.stage)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()
                    }

                    Text(ev.message)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)

                    if let fp = ev.filePath {
                        Text(fp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }

                    if !ev.metadata.isEmpty {
                        Text(ev.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " • "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .frame(minWidth: 820, minHeight: 520)
        .navigationTitle("Execution Trace")
    }
}
