import SwiftUI
import SwiftData
import CoreGraphics

#if canImport(AppKit)
import AppKit
import CoreText
#endif

@main
struct RedactionResearchAppApp: App {
    @Environment(\.openWindow) private var openWindow

    @State private var modelContainer: ModelContainer
    @StateObject private var traceStore: TraceStore
    @State private var initializationError: String?

    init() {
        do {
            let container = try ModelContainer(for: CaseModel.self, DocumentModel.self, AuditEventModel.self)
            _modelContainer = State(initialValue: container)
            _traceStore = StateObject(wrappedValue: TraceStore(container: container))
            _initializationError = State(initialValue: nil)
        } catch {
            // Create a fallback in-memory container to prevent crash
            let schema = Schema([CaseModel.self, DocumentModel.self, AuditEventModel.self])
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try! ModelContainer(for: schema, configurations: config)
            _modelContainer = State(initialValue: container)
            _traceStore = StateObject(wrappedValue: TraceStore(container: container))
            _initializationError = State(initialValue: "Failed to initialize data store: \(error.localizedDescription). Running in memory-only mode. Data will not be persisted.")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(traceStore)
                .alert("Data Store Warning", isPresented: Binding(
                    get: { initializationError != nil },
                    set: { if !$0 { initializationError = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(initializationError ?? "")
                }
        }
        .modelContainer(modelContainer)

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

/// A SwiftData-backed store for audit/trace events so execution history survives app restarts.
@MainActor
final class TraceStore: ObservableObject {
    @Published private(set) var events: [AuditEventModel] = []

    private let context: ModelContext

    init(container: ModelContainer) {
        self.context = ModelContext(container)
        Task { await reload() }
    }

    func log(_ event: TraceEvent) {
        let model = AuditEventModel(event)
        context.insert(model)
        do {
            try context.save()
        } catch {
            print("Failed to persist audit event: \(error)")
        }
        events.append(model)
    }

    func reload() async {
        let descriptor = FetchDescriptor<AuditEventModel>(sortBy: [SortDescriptor(\.createdAt)])
        if let items = try? context.fetch(descriptor) {
            events = items
        }
    }

    func clear() {
        let descriptor = FetchDescriptor<AuditEventModel>()
        do {
            let items = try context.fetch(descriptor)
            for item in items {
                context.delete(item)
            }
            try context.save()
            // Only clear in-memory array if database operations succeeded
            events.removeAll()
        } catch {
            print("Failed to clear trace events: \(error)")
            // Keep in-memory events intact if database operation failed
        }
    }

    func exportText(events: [AuditEventModel]? = nil) -> String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .medium
        let payload = events ?? self.events

        return payload.map { ev in
            let ts = df.string(from: ev.createdAt)
            let fp = ev.filePath.map { "\n  file: \($0)" } ?? ""
            let sha = ev.sha256.map { "\n  sha256: \($0)" } ?? ""
            let derived = ev.derivedPath.map { "\n  derived: \($0)" } ?? ""
            let thumb = ev.thumbnailPath.map { "\n  thumb: \($0)" } ?? ""
            let meta: String
            if ev.metadata.isEmpty {
                meta = ""
            } else {
                meta = "\n  meta: " + ev.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            }
            let aiMeta: String
            if ev.aiMetadata.isEmpty {
                aiMeta = ""
            } else {
                aiMeta = "\n  ai: " + ev.aiMetadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            }
            return "[\(ts)] \(ev.level.rawValue.uppercased()) \(ev.stage): \(ev.message)\(fp)\(sha)\(derived)\(thumb)\(meta)\(aiMeta)"
        }.joined(separator: "\n")
    }
}

struct TraceWindowView: View {
    @EnvironmentObject private var trace: TraceStore

    @State private var searchText: String = ""
    @State private var selectedLevel: TraceEvent.Level? = nil
    @State private var selectedStage: String? = nil
    @State private var selectedEventID: UUID?

    private var filtered: [AuditEventModel] {
        var out = Array(trace.events.reversed())

        if let lvl = selectedLevel {
            out = out.filter { $0.level == lvl }
        }

        if let stage = selectedStage, !stage.isEmpty {
            out = out.filter { $0.stage == stage }
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            out = out.filter {
                $0.stage.localizedCaseInsensitiveContains(q) ||
                $0.message.localizedCaseInsensitiveContains(q) ||
                ($0.filePath?.localizedCaseInsensitiveContains(q) ?? false) ||
                ($0.sha256?.localizedCaseInsensitiveContains(q) ?? false) ||
                ($0.derivedPath?.localizedCaseInsensitiveContains(q) ?? false) ||
                $0.metadata.values.contains(where: { $0.localizedCaseInsensitiveContains(q) }) ||
                $0.aiMetadata.values.contains(where: { $0.localizedCaseInsensitiveContains(q) })
            }
        }

        return out
    }

    private var stages: [String] {
        Array(Set(trace.events.map { $0.stage })).sorted()
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
                    ForEach(stages, id: \.self) { stage in
                        Text(stage).tag(Optional(stage))
                    }
                }
                .pickerStyle(.menu)

                Spacer()

                Button("Export Text") {
                    #if canImport(AppKit)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(trace.exportText(events: filtered), forType: .string)
                    #endif
                }

                Button("Export PDF") {
                    #if canImport(AppKit)
                    exportPDF()
                    #endif
                }

                Button("Clear") {
                    trace.clear()
                }
            }

            HStack(spacing: 12) {
                List(filtered, selection: $selectedEventID) { ev in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(ev.createdAt.formatted(date: .omitted, time: .standard))
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

                        if let sha = ev.sha256 {
                            Text("SHA: \(sha)")
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
                }
                .onChange(of: filtered) { _ in
                    if let selectedEventID, !filtered.contains(where: { $0.id == selectedEventID }) {
                        self.selectedEventID = filtered.first?.id
                    }
                }
                .frame(minWidth: 420)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    if let selected = filtered.first(where: { $0.id == selectedEventID }) ?? filtered.first {
                        TraceDetailView(event: selected)
                    } else {
                        Text("Select an event to preview details")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding()
        .frame(minWidth: 820, minHeight: 520)
        .navigationTitle("Execution Trace")
    }
}

struct TraceDetailView: View {
    let event: AuditEventModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(event.message)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)

                detailRow(title: "Stage", value: event.stage)
                detailRow(title: "Level", value: event.level.rawValue.uppercased())
                detailRow(title: "Timestamp", value: event.createdAt.formatted(date: .abbreviated, time: .standard))

                if let filePath = event.filePath {
                    detailRow(title: "File", value: filePath)
                }

                if let sha = event.sha256 {
                    detailRow(title: "SHA-256", value: sha)
                }

                if let derived = event.derivedPath {
                    detailRow(title: "Derived", value: derived)
                }

                if let thumb = resolvedThumbnailPath {
                    detailRow(title: "Thumbnail", value: thumb)
                }

                if !event.metadata.isEmpty {
                    detailRow(title: "Metadata", value: event.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n"))
                }

                if !event.aiMetadata.isEmpty {
                    detailRow(title: "AI Metadata", value: event.aiMetadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n"))
                }

                thumbnailView
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var resolvedThumbnailPath: String? {
        if let thumb = event.thumbnailPath { return thumb }
        if let derived = event.derivedPath {
            let derivedThumb = URL(fileURLWithPath: derived).appendingPathComponent("thumb.png").path
            if FileManager.default.fileExists(atPath: derivedThumb) {
                return derivedThumb
            }
        }
        return nil
    }

    @ViewBuilder
    private var thumbnailView: some View {
        #if canImport(AppKit)
        if let path = resolvedThumbnailPath, let image = NSImage(contentsOfFile: path) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
            }
        }
        #else
        EmptyView()
        #endif
    }
}

#if canImport(AppKit)
private extension TraceWindowView {
    func exportPDF() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = "ExecutionTrace.pdf"
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            let text = trace.exportText(events: filtered)
            guard let data = TraceWindowView.makePDF(from: text) else { return }
            try? data.write(to: url)
        }
    }

    static func makePDF(from text: String) -> Data? {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let path = CGPath(rect: CGRect(x: 24, y: 24, width: mediaBox.width - 48, height: mediaBox.height - 48), transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attrString.length), path, nil)
        CTFrameDraw(frame, ctx)

        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}
#endif
