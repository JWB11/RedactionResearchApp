import SwiftUI
import SwiftData

#if canImport(AppKit)
import AppKit
#endif

@main
struct RedactionResearchAppApp: App {
    @Environment(\.openWindow) private var openWindow
    private let container: ModelContainer

    @StateObject private var traceStore: TraceStore

    init() {
        do {
            container = try ModelContainer(for: [CaseModel.self, DocumentModel.self, AuditEventModel.self])
        } catch {
            fatalError("Failed to set up model container: \(error)")
        }
        _traceStore = StateObject(wrappedValue: TraceStore(container: container))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(traceStore)
        }
        .modelContainer(container)

        // Secondary window: live execution trace
        WindowGroup("Execution Trace", id: "execution-trace") {
            TraceWindowView()
                .environmentObject(traceStore)
        }
        .modelContainer(container)

        Settings {
            SettingsView()
                .environmentObject(traceStore)
        }
        .modelContainer(container)

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
    let sha256: String?
    let derivedFolderPath: String?
    let artifactPath: String?
    let thumbnailPath: String?
    let durationMs: Double?
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: Level = .info,
        stage: String,
        message: String,
        filePath: String? = nil,
        sha256: String? = nil,
        derivedFolderPath: String? = nil,
        artifactPath: String? = nil,
        thumbnailPath: String? = nil,
        durationMs: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.stage = stage
        self.message = message
        self.filePath = filePath
        self.sha256 = sha256
        self.derivedFolderPath = derivedFolderPath
        self.artifactPath = artifactPath
        self.thumbnailPath = thumbnailPath
        self.durationMs = durationMs
        self.metadata = metadata
    }

    init(model: AuditEventModel) {
        self.init(
            id: model.id,
            timestamp: model.timestamp,
            level: Level(rawValue: model.level) ?? .info,
            stage: model.stage,
            message: model.message,
            filePath: model.filePath,
            sha256: model.sha256,
            derivedFolderPath: model.derivedFolderPath,
            artifactPath: model.artifactPath,
            thumbnailPath: model.thumbnailPath,
            durationMs: model.durationMs,
            metadata: model.metadata
        )
    }

    func asModel() -> AuditEventModel {
        AuditEventModel(
            id: id,
            timestamp: timestamp,
            level: level.rawValue,
            stage: stage,
            message: message,
            filePath: filePath,
            sha256: sha256,
            derivedFolderPath: derivedFolderPath,
            artifactPath: artifactPath,
            thumbnailPath: thumbnailPath,
            durationMs: durationMs,
            metadata: metadata
        )
    }
}

@MainActor
final class TraceStore: ObservableObject {
    private let container: ModelContainer
    private let context: ModelContext

    @Published private(set) var events: [TraceEvent] = []

    init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
        loadPersisted()
    }

    func loadPersisted(limit: Int = 5000) {
        let descriptor = FetchDescriptor<AuditEventModel>(
            predicate: nil,
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        if let fetched = try? context.fetch(descriptor) {
            let trimmed = fetched.suffix(limit)
            events = trimmed.map { TraceEvent(model: $0) }
        }
    }

    func log(_ event: TraceEvent) {
        events.append(event)
        // Keep memory bounded for v1
        if events.count > 10_000 {
            events.removeFirst(events.count - 10_000)
        }

        let model = event.asModel()
        context.insert(model)
        try? context.save()
    }

    func clear() {
        events.removeAll()

        let descriptor = FetchDescriptor<AuditEventModel>()
        if let models = try? context.fetch(descriptor) {
            for model in models {
                context.delete(model)
            }
            try? context.save()
        }
    }

    func exportText(events overrideEvents: [TraceEvent]? = nil) -> String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .medium
        let source = overrideEvents ?? events

        return source.map { ev in
            let ts = df.string(from: ev.timestamp)
            let fp = ev.filePath.map { "\n  file: \($0)" } ?? ""
            let sha = ev.sha256.map { "\n  sha: \($0)" } ?? ""
            let derived = ev.derivedFolderPath.map { "\n  derived: \($0)" } ?? ""
            let art = ev.artifactPath.map { "\n  artifact: \($0)" } ?? ""
            let duration = ev.durationMs.map { "\n  durationMs: \(Int($0))" } ?? ""
            let meta: String
            if ev.metadata.isEmpty {
                meta = ""
            } else {
                meta = "\n  meta: " + ev.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            }
            return "[\(ts)] \(ev.level.rawValue.uppercased()) \(ev.stage): \(ev.message)\(fp)\(sha)\(derived)\(art)\(duration)\(meta)"
        }.joined(separator: "\n")
    }
}

struct TraceWindowView: View {
    @EnvironmentObject private var trace: TraceStore

    @State private var searchText: String = ""
    @State private var selectedLevel: TraceEvent.Level? = nil
    @State private var selectedStage: String? = nil
    @State private var selectedEventID: UUID? = nil

    private var stageOptions: [String] {
        Array(Set(trace.events.map { $0.stage })).sorted()
    }

    private var filtered: [TraceEvent] {
        var out = trace.events

        if let lvl = selectedLevel {
            out = out.filter { $0.level == lvl }
        }

        if let stage = selectedStage {
            out = out.filter { $0.stage == stage }
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            out = out.filter {
                $0.stage.localizedCaseInsensitiveContains(q) ||
                $0.message.localizedCaseInsensitiveContains(q) ||
                ($0.filePath?.localizedCaseInsensitiveContains(q) ?? false) ||
                ($0.sha256?.localizedCaseInsensitiveContains(q) ?? false) ||
                ($0.derivedFolderPath?.localizedCaseInsensitiveContains(q) ?? false) ||
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

                Picker("Stage", selection: $selectedStage) {
                    Text("All Stages").tag(String?.none)
                    ForEach(stageOptions, id: \.self) { stage in
                        Text(stage).tag(Optional(stage))
                    }
                }
                .pickerStyle(.menu)

                Spacer()

                Button("Clear") {
                    trace.clear()
                }

                Menu("Export") {
                    Button("Copy All") {
                        copyAll()
                    }
                    Button("Export Text…") { exportText() }
                    Button("Export PDF…") { exportPDF() }
                }
            }

            List(filtered, selection: $selectedEventID) { ev in
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

                    if let dur = ev.durationMs {
                        Text("Duration: \(Int(dur)) ms")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let fp = ev.filePath {
                        Text(fp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }

                    if let sha = ev.sha256, !sha.isEmpty {
                        Text("SHA: \(sha)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    if let derived = ev.derivedFolderPath, !derived.isEmpty {
                        Text("Derived: \(derived)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    if let art = ev.artifactPath, !art.isEmpty {
                        Text("Artifact: \(art)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    if !ev.metadata.isEmpty {
                        Text(ev.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " • "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
                .tag(ev.id)
            }

            if let current = currentSelection {
                TracePreview(event: current)
            }
        }
        .padding()
        .frame(minWidth: 820, minHeight: 520)
        .navigationTitle("Execution Trace")
    }

    private var currentSelection: TraceEvent? {
        if let id = selectedEventID {
            return filtered.first(where: { $0.id == id })
        }
        return filtered.last
    }

    private func copyAll() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trace.exportText(events: filtered), forType: .string)
        #endif
    }

    private func exportText() {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["txt"]
        panel.nameFieldStringValue = "ExecutionTrace.txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? trace.exportText(events: filtered).write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
    }

    private func exportPDF() {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["pdf"]
        panel.nameFieldStringValue = "ExecutionTrace.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 0))
        textView.string = trace.exportText(events: filtered)
        textView.sizeToFit()
        let data = textView.dataWithPDF(inside: textView.bounds)
        try? data.write(to: url)
        #endif
    }
}

private struct TracePreview: View {
    let event: TraceEvent

    @State private var thumbnail: NSImage? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Selected Event")
                    .font(.headline)
                Spacer()
            }

            Text(event.message)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            if let thumb = thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
            } else if event.thumbnailPath != nil {
                Text("Thumbnail preview not available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.gray.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear { loadThumbnail() }
        .onChange(of: event.id) { _ in loadThumbnail() }
    }

    private func loadThumbnail() {
        #if canImport(AppKit)
        if let path = event.thumbnailPath ?? event.artifactPath, let image = NSImage(contentsOfFile: path) {
            thumbnail = image
        } else {
            thumbnail = nil
        }
        #endif
    }
}
