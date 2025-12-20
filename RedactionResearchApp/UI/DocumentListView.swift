import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct DocumentListView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \CaseModel.createdAt, order: .forward) private var cases: [CaseModel]
    @Query(sort: \DocumentModel.createdAt, order: .reverse) private var documents: [DocumentModel]

    @State private var searchText: String = ""

    @State private var selection = Set<DocumentModel.ID>()

    @AppStorage("workspace.selectedCaseID") private var selectedCaseIDString: String = ""

    @AppStorage("autoIndexAfterImport") private var autoIndexAfterImport: Bool = false

    @State private var isIndexing: Bool = false
    @State private var indexingProgress: Double = 0
    @State private var indexingScratchpad: String = ""
    @State private var indexingCurrentThumbPath: String? = nil

    private let indexer = IndexingService()

    @State private var showingNewCaseSheet: Bool = false
    @State private var newCaseName: String = ""
    @State private var confirmingClearCase: Bool = false

    @State private var showingError: Bool = false
    @State private var errorMessage: String = ""

    @State private var showingTextPreview: Bool = false
    @State private var textPreviewTitle: String = ""
    @State private var textPreviewBody: String = ""

    private let importService = FileImportService()

    var body: some View {
        GroupBox("Documents") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    Text("Case:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Case", selection: Binding(
                        get: { activeCase?.id ?? UUID() },
                        set: { setActiveCase(id: $0) }
                    )) {
                        ForEach(cases) { c in
                            Text(c.name).tag(c.id)
                        }
                    }
                    .frame(minWidth: 220)

                    Button("New Case…") {
                        newCaseName = ""
                        showingNewCaseSheet = true
                    }

                    Button("Clear Case") {
                        confirmingClearCase = true
                    }
                    .disabled(activeCase == nil)

                    Button("Import…") {
                        importWithOpenPanel()
                    }

                    Toggle("Auto-index", isOn: $autoIndexAfterImport)
                        .toggleStyle(.switch)
                        .help("When enabled, indexing starts automatically after import.")

                    Button("Remove Selected") {
                        removeSelectedDocuments()
                    }
                    .disabled(selection.isEmpty)
                }
                .frame(maxWidth: .infinity)

                if isIndexing {
                    HStack(spacing: 10) {
                        ProgressView(value: indexingProgress)
                            .frame(width: 220)
                        Text(indexingScratchpad.isEmpty ? "Indexing…" : indexingScratchpad)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let p = indexingCurrentThumbPath, let img = NSImage(contentsOfFile: p) {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 26, height: 26)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }

                if filteredDocuments.isEmpty {
                    ContentUnavailableView(
                        "No documents yet",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Import files/folders/ZIPs to begin indexing."))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    List(selection: $selection) {
                        ForEach(filteredDocuments) { doc in
                            DocumentRow(
                                doc: doc,
                                onOpenOriginal: { openURL(URL(fileURLWithPath: doc.localPath)) },
                                onOpenDerived: { openDerived(doc) },
                                onPreviewText: { previewText(doc) },
                                onPreviewOCR: { previewOCR(doc) },
                                onRemove: { removeDocuments([doc]) }
                            )
                            .tag(doc.id)
                        }
                        .onDelete(perform: deleteDocuments)
                    }
                    .listStyle(.inset)
                    .onDeleteCommand {
                        removeSelectedDocuments()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            ensureDefaultCaseExistsIfNeeded()
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showingTextPreview) {
            VStack(spacing: 12) {
                HStack {
                    Text(textPreviewTitle).font(.headline)
                    Spacer()
                    Button("Close") { showingTextPreview = false }
                }
                .padding(.horizontal)

                TextEditor(text: .constant(textPreviewBody))
                    .font(.system(.body, design: .monospaced))
                    .padding()
            }
            .frame(minWidth: 700, minHeight: 500)
        }
        .confirmationDialog(
            "Start over and clear this case?",
            isPresented: $confirmingClearCase,
            titleVisibility: .visible
        ) {
            Button("Clear Case", role: .destructive) {
                clearActiveCase()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes imported documents from the case and deletes derived artifacts (thumbnails/OCR/text/AI suggestions) generated for those documents. It does not delete your original source files outside the case folder.")
        }
        .sheet(isPresented: $showingNewCaseSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("New Case")
                    .font(.headline)

                TextField("Case name", text: $newCaseName)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Spacer()
                    Button("Cancel") { showingNewCaseSheet = false }
                    Button("Create") {
                        createNewCase()
                        showingNewCaseSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newCaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .frame(width: 440)
        }
    }

    private var filteredDocuments: [DocumentModel] {
        let caseFiltered: [DocumentModel]
        if let active = activeCase {
            caseFiltered = documents.filter { $0.caseID == active.id }
        } else {
            caseFiltered = []
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return caseFiltered }
        return caseFiltered.filter {
            $0.fileName.localizedCaseInsensitiveContains(q) ||
            $0.localPath.localizedCaseInsensitiveContains(q) ||
            ($0.sha256?.localizedCaseInsensitiveContains(q) ?? false) ||
            ($0.dHash?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private func ensureDefaultCaseExistsIfNeeded() {
        guard cases.isEmpty else {
            if selectedCaseIDString.isEmpty, let first = cases.first {
                selectedCaseIDString = first.id.uuidString
            }
            return
        }

        do {
            let folder = try defaultCaseFolderURL()
            let model = CaseModel(name: "Default Case", caseFolderPath: folder.path)
            modelContext.insert(model)
            try modelContext.save()
            selectedCaseIDString = model.id.uuidString
        } catch {
            showingError = true
            errorMessage = "Failed to create default case folder: \(error.localizedDescription)"
        }
    }

    private func importWithOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.title = "Import Files, Folders, or ZIPs"
        panel.message = "Selected items will be copied into the Case folder for indexing."

        panel.allowedContentTypes = [
            .pdf,
            .image,
            .plainText,
            .xml,
            UTType(filenameExtension: "doc") ?? .data,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "xls") ?? .data,
            UTType(filenameExtension: "xlsx") ?? .data,
            UTType(filenameExtension: "ppt") ?? .data,
            UTType(filenameExtension: "pptx") ?? .data,
            UTType(filenameExtension: "zip") ?? .data,
            .data
        ]

        guard panel.runModal() == .OK else { return }

        Task {
            do {
                if cases.isEmpty {
                    await MainActor.run { ensureDefaultCaseExistsIfNeeded() }
                }
                guard let activeCase = activeCase ?? cases.first else {
                    throw FileImportService.ImportError.caseDirectoryUnavailable
                }

                let caseFolder = URL(fileURLWithPath: activeCase.caseFolderPath)
                let copied = try await importService.importItems(urls: panel.urls, intoCaseFolder: caseFolder)

                for url in copied {
                    let doc = DocumentModel(
                        fileName: url.lastPathComponent,
                        localPath: url.path,
                        caseID: activeCase.id
                    )
                    doc.sha256 = try? HashUtils.sha256(for: url)
                    modelContext.insert(doc)
                }

                try modelContext.save()

                if autoIndexAfterImport {
                    let urlsToIndex = copied
                    await MainActor.run {
                        beginBackgroundIndexing(urls: urlsToIndex)
                    }
                }
            } catch {
                await MainActor.run {
                    showingError = true
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func beginBackgroundIndexing(urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !isIndexing else { return }

        isIndexing = true
        indexingProgress = 0
        indexingScratchpad = "Preparing…"
        indexingCurrentThumbPath = nil

        // Keep a quick lookup from local path to DocumentModel for updating fields (case-scoped).
        let caseDocs: [DocumentModel] = {
            guard let c = activeCase else { return [] }
            return documents.filter { $0.caseID == c.id }
        }()

        let localToDocID: [String: DocumentModel.ID] = Dictionary(
            uniqueKeysWithValues: caseDocs.map { ($0.localPath, $0.id) }
        )

        Task(priority: .utility) {
            let stream = await indexer.index(urls: urls, enableAI: false, trace: nil)

            for await ev in stream {
                await MainActor.run {
                    if ev.total > 0 {
                        indexingProgress = Double(ev.completed) / Double(ev.total)
                    }
                    indexingScratchpad = ev.message
                    if let thumb = ev.thumbnailPath {
                        indexingCurrentThumbPath = thumb
                    }

                    // Update the corresponding DocumentModel (best-effort; case-only)
                    if let path = ev.currentPath, let id = localToDocID[path],
                       let doc = documents.first(where: { $0.id == id }) {
                        if let sha = ev.sha256, !sha.isEmpty { doc.sha256 = sha }
                        if let dh = ev.dHash, !dh.isEmpty { doc.dHash = dh }
                        if let derived = ev.derivedFolderPath, !derived.isEmpty { doc.derivedFolderPath = derived }
                        if let p = ev.extractedTextPath, !p.isEmpty { doc.extractedTextPath = p }
                        if let p = ev.ocrTextPath, !p.isEmpty { doc.ocrTextPath = p }
                        if let p = ev.thumbnailPath, !p.isEmpty { doc.thumbnailPath = p }

                        // Mark indexed once we start receiving derived outputs for this file.
                        if ev.derivedFolderPath != nil || ev.thumbnailPath != nil || ev.extractedTextPath != nil || ev.ocrTextPath != nil || ev.dHash != nil {
                            doc.lastIndexedAt = Date()
                        }
                    }

                    // Save occasionally to persist progress (keep it cheap)
                    if ev.total > 0 && ev.completed % 25 == 0 {
                        try? modelContext.save()
                    }

                    if ev.kind == .finished {
                        isIndexing = false
                        indexingProgress = 1
                        indexingScratchpad = "Indexing complete"
                        try? modelContext.save()
                    } else if ev.kind == .failed {
                        isIndexing = false
                        showingError = true
                        errorMessage = ev.message
                    }
                }
            }

            await MainActor.run {
                if isIndexing {
                    isIndexing = false
                    indexingScratchpad = "Indexing stopped"
                }
            }
        }
    }

    private func deleteDocuments(at offsets: IndexSet) {
        for i in offsets {
            let doc = filteredDocuments[i]
            modelContext.delete(doc)
        }
        do {
            try modelContext.save()
        } catch {
            showingError = true
            errorMessage = "Failed to delete: \(error.localizedDescription)"
        }
    }

    private func removeSelectedDocuments() {
        let selectedDocs = filteredDocuments.filter { selection.contains($0.id) }
        guard !selectedDocs.isEmpty else { return }
        removeDocuments(selectedDocs)
    }

    private func removeDocuments(_ docs: [DocumentModel]) {
        for doc in docs {
            modelContext.delete(doc)
        }
        do {
            try modelContext.save()
            // Clear selection of any deleted IDs
            for doc in docs {
                selection.remove(doc.id)
            }
        } catch {
            showingError = true
            errorMessage = "Failed to remove: \(error.localizedDescription)"
        }
    }

    private func openDerived(_ doc: DocumentModel) {
        guard let path = doc.derivedFolderPath else {
            showingError = true
            errorMessage = "No derived folder found yet. Run Begin Processing first."
            return
        }
        openURL(URL(fileURLWithPath: path))
    }

    private func previewText(_ doc: DocumentModel) {
        guard let path = doc.extractedTextPath else {
            showingError = true
            errorMessage = "No extracted text found yet."
            return
        }
        do {
            textPreviewBody = try String(contentsOfFile: path, encoding: .utf8)
            textPreviewTitle = "Extracted Text — \(doc.fileName)"
            showingTextPreview = true
        } catch {
            showingError = true
            errorMessage = "Failed to load text: \(error.localizedDescription)"
        }
    }

    private func previewOCR(_ doc: DocumentModel) {
        guard let path = doc.ocrTextPath else {
            showingError = true
            errorMessage = "No OCR text found yet."
            return
        }
        do {
            textPreviewBody = try String(contentsOfFile: path, encoding: .utf8)
            textPreviewTitle = "OCR — \(doc.fileName)"
            showingTextPreview = true
        } catch {
            showingError = true
            errorMessage = "Failed to load OCR: \(error.localizedDescription)"
        }
    }

    private func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func defaultCaseFolderURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let root = appSupport
            .appendingPathComponent("RedactionResearchApp", isDirectory: true)
            .appendingPathComponent("Cases", isDirectory: true)
            .appendingPathComponent("Default Case", isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private var activeCase: CaseModel? {
        if let id = UUID(uuidString: selectedCaseIDString), let match = cases.first(where: { $0.id == id }) {
            return match
        }
        return cases.first
    }

    private func setActiveCase(id: UUID) {
        selectedCaseIDString = id.uuidString
    }

    private func createNewCase() {
        let name = newCaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        do {
            let folder = try caseFolderURL(caseName: name)
            let model = CaseModel(name: name, caseFolderPath: folder.path)
            modelContext.insert(model)
            try modelContext.save()
            selectedCaseIDString = model.id.uuidString
        } catch {
            showingError = true
            errorMessage = "Failed to create new case: \(error.localizedDescription)"
        }
    }

    private func clearActiveCase() {
        guard let c = activeCase else { return }

        // Documents are case-scoped; only clear documents belonging to the active case.
        let docsToRemove = documents.filter { $0.caseID == c.id }

        // Delete SwiftData records first
        for doc in docsToRemove {
            modelContext.delete(doc)
        }

        do {
            try modelContext.save()
            selection.removeAll()

            let fm = FileManager.default

            // Remove per-document derived artifacts (only those referenced)
            let derivedRoot = try derivedRootURL()
            for doc in docsToRemove {
                if let sha = doc.sha256, !sha.isEmpty {
                    let dir = derivedRoot.appendingPathComponent(sha, isDirectory: true)
                    if fm.fileExists(atPath: dir.path) {
                        try? fm.removeItem(at: dir)
                    }
                }
            }

            // Remove copied files within the active case folder (but keep the folder)
            let caseURL = URL(fileURLWithPath: c.caseFolderPath)
            if let items = try? fm.contentsOfDirectory(at: caseURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for u in items {
                    try? fm.removeItem(at: u)
                }
            }
        } catch {
            showingError = true
            errorMessage = "Failed to clear case: \(error.localizedDescription)"
        }
    }

    private func derivedRootURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = appSupport
            .appendingPathComponent("RedactionResearchApp", isDirectory: true)
            .appendingPathComponent("Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func caseFolderURL(caseName: String) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let casesRoot = appSupport
            .appendingPathComponent("RedactionResearchApp", isDirectory: true)
            .appendingPathComponent("Cases", isDirectory: true)
        try FileManager.default.createDirectory(at: casesRoot, withIntermediateDirectories: true)

        let sanitized = sanitizeFolderName(caseName)
        let url = casesRoot.appendingPathComponent(sanitized, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sanitizeFolderName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Untitled Case" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.replacingOccurrences(of: "--", with: "-")
    }
}

private struct DocumentRow: View {
    let doc: DocumentModel
    let onOpenOriginal: () -> Void
    let onOpenDerived: () -> Void
    let onPreviewText: () -> Void
    let onPreviewOCR: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailView(path: doc.thumbnailPath)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(doc.fileName)
                        .font(.headline)
                    Spacer()
                    StatusBadge(indexedAt: doc.lastIndexedAt)
                }

                Text(doc.localPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 12) {
                    if let sha = doc.sha256, !sha.isEmpty {
                        Label(String(sha.prefix(12)), systemImage: "number")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospaced()
                    }
                    if let dh = doc.dHash, !dh.isEmpty {
                        Label(String(dh.prefix(12)), systemImage: "waveform.path.ecg")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospaced()
                    }
                }

                HStack(spacing: 8) {
                    Button("Open") { onOpenOriginal() }
                    Button("Derived") { onOpenDerived() }
                    Button("Text") { onPreviewText() }
                        .disabled(doc.extractedTextPath == nil)
                    Button("OCR") { onPreviewOCR() }
                        .disabled(doc.ocrTextPath == nil)
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Open Original") { onOpenOriginal() }
            Button("Open Derived Folder") { onOpenDerived() }
            Divider()
            Button("Remove from Case") { onRemove() }
        }
    }
}

private struct StatusBadge: View {
    let indexedAt: Date?

    var body: some View {
        if let indexedAt {
            Text("Indexed")
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.green.opacity(0.18))
                .clipShape(Capsule())
                .help("Last indexed at \(indexedAt.formatted())")
        } else {
            Text("Not indexed")
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.orange.opacity(0.18))
                .clipShape(Capsule())
                .help("Run Begin Processing")
        }
    }
}

private struct ThumbnailView: View {
    let path: String?

    var body: some View {
        Group {
            if let path, let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 56, height: 56)
        .background(.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.gray.opacity(0.18), lineWidth: 1)
        )
    }
}
