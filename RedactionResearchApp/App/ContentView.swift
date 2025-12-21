import SwiftUI
import SwiftData

#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class ProcessingStatus: ObservableObject {
    @Published var progress: Double = 0
    @Published var status: String = "Idle"
    @Published var isProcessing: Bool = false
    @Published var currentFilePath: String? = nil
    @Published var currentThumbnailPath: String? = nil
    @Published var currentExtractedTextChars: Int? = nil
    @Published var currentOCRTextChars: Int? = nil

    func reset() {
        progress = 0
        status = "Idle"
        isProcessing = false
        currentFilePath = nil
        currentThumbnailPath = nil
        currentExtractedTextChars = nil
        currentOCRTextChars = nil
    }

}



struct ContentView: View {
    @EnvironmentObject private var traceStore: TraceStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DocumentModel.createdAt, order: .reverse) private var documents: [DocumentModel]

    @ObservedObject private var ai = AIService.shared

    // Active case (set by SidebarView). Empty means none selected.
    @AppStorage("workspace.selectedCaseID") private var selectedCaseIDString: String = ""
    private var selectedCaseID: UUID? { UUID(uuidString: selectedCaseIDString) }

    private var caseDocuments: [DocumentModel] {
        guard let cid = selectedCaseID else { return [] }
        return documents.filter { $0.caseID == cid }
    }

    @State private var showingEnableCloudPrompt: Bool = false
    @State private var pendingEnableCloud: Bool = false
    @State private var aiStatus: String = ""

    @StateObject private var processing = ProcessingStatus()
    @State private var processingTask: Task<Void, Never>? = nil

    // Indexing options
    @AppStorage("indexing.skipCached") private var skipCachedOnRun: Bool = true
    @AppStorage("indexing.forceReindex") private var forceReindexOnRun: Bool = false

    @State private var showingNoChangesPrompt: Bool = false
    @State private var pendingRunURLs: [URL] = []

    @State private var indexedUpdateCount: Int = 0

    @State private var duplicateClusters: [DuplicateAnalysisService.DuplicateCluster] = []
    @State private var isAnalyzingDuplicates: Bool = false
    @State private var duplicatesStatus: String = ""

    // Cluster-level AI explanation state
    @State private var clusterAIText: [UUID: String] = [:]
    @State private var clusterAILoading: Set<UUID> = []
    @State private var expandedClusters: Set<UUID> = []
    @State private var showFullClusterDetail: Set<UUID> = []

    private let indexer = IndexingService()
    private let duplicateAnalyzer = DuplicateAnalysisService()

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            VStack(spacing: 12) {
                ProgressScratchpadView(processing: processing)
                ActionBar(
                    isProcessing: processing.isProcessing,
                    hasDocuments: !caseDocuments.isEmpty,
                    isAnalyzingDuplicates: isAnalyzingDuplicates,
                    onRun: { startProcessing() },
                    onCancel: { cancelProcessing() },
                    onReset: { processing.reset() },
                    onAnalyze: { analyzeDuplicates() },
                    onIndexOptions: {
                        // No-op; options live in toolbar menu for now.
                    }
                )
                if !aiStatus.isEmpty {
                    Text(aiStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                DashboardView()
                DocumentListView()
                DuplicatesPanel(
                    clusters: duplicateClusters,
                    isAnalyzing: isAnalyzingDuplicates,
                    status: duplicatesStatus,
                    clusterAIText: clusterAIText,
                    clusterAILoading: clusterAILoading,
                    expandedClusters: expandedClusters,
                    showFullClusterDetail: showFullClusterDetail,
                    onAnalyze: { analyzeDuplicates() },
                    onExplainCluster: { cluster in
                        Task { await explainCluster(cluster) }
                    },
                    onToggleExpand: { id in toggleClusterExpand(id) },
                    onToggleFull: { id in toggleClusterFull(id) },
                    onOpenOriginal: { openURL(URL(fileURLWithPath: $0)) },
                    onOpenDerived: { openURL(URL(fileURLWithPath: $0)) }
                )
            }
            .padding()
            .appBackground()
            .onAppear {
                // Wire AI service to the Execution Trace window.
                AIService.shared.trace = { ev in
                    traceStore.log(ev)
                }
            }
            .alert("Enable Cloud AI?", isPresented: $showingEnableCloudPrompt) {
                Button("Enable", role: .destructive) {
                    ai.setCloudAIEnabled(true)
                }
                Button("Cancel", role: .cancel) {
                    // Leave disabled
                }
            } message: {
                Text("Cloud AI sends text off-device. For legal research, enable only when you intend to use a cloud model. You can disable it any time in Settings.")
            }
            .alert("No changes detected", isPresented: $showingNoChangesPrompt) {
                Button("Re-index anyway", role: .destructive) {
                    startProcessing(urlsOverride: pendingRunURLs, forceOverride: true)
                }
                Button("Cancel", role: .cancel) {
                    pendingRunURLs = []
                }
            } message: {
                Text("All files in this case appear up to date. You can re-index anyway to rebuild derived artifacts.")
            }
        }
        .navigationTitle("Redaction Research")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    startProcessing()
                } label: {
                    Label("Begin Processing", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                }
                .disabled(processing.isProcessing || caseDocuments.isEmpty)

                Button {
                    cancelProcessing()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                }
                .disabled(!processing.isProcessing)

                Button {
                    processing.reset()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .labelStyle(.iconOnly)
                }
                .disabled(processing.isProcessing)

                Button {
                    analyzeDuplicates()
                } label: {
                    Label("Analyze Duplicates", systemImage: "square.stack.3d.up")
                        .labelStyle(.iconOnly)
                }
                .disabled(processing.isProcessing || caseDocuments.isEmpty || isAnalyzingDuplicates)

                Menu {
                    Toggle("Skip cached files", isOn: $skipCachedOnRun)
                    Toggle("Force re-index", isOn: $forceReindexOnRun)
                        .help("Rebuild thumbnails/OCR/text even if cached artifacts exist.")
                } label: {
                    Label("Index Options", systemImage: "slider.horizontal.3")
                        .labelStyle(.iconOnly)
                }
                .disabled(processing.isProcessing)

                Divider()

                Button {
                    // Local is safe by default; allow toggling.
                    ai.setLocalAIEnabled(true)
                    aiStatus = "Local AI enabled"
                } label: {
                    Label("Enable Local AI", systemImage: "bolt.horizontal.circle")
                        .labelStyle(.iconOnly)
                }

                Button {
                    ai.setLocalAIEnabled(false)
                    aiStatus = "Local AI disabled"
                } label: {
                    Label("Disable Local AI", systemImage: "bolt.slash")
                        .labelStyle(.iconOnly)
                }

                Button {
                    if ai.shouldPromptToEnableCloudAI() {
                        showingEnableCloudPrompt = true
                    } else {
                        ai.setCloudAIEnabled(false)
                        aiStatus = "Cloud AI disabled"
                    }
                } label: {
                    Label("Cloud AI…", systemImage: "icloud")
                        .labelStyle(.iconOnly)
                }

                Button {
                    Task { await runAIRedactionInferenceForCurrentFile() }
                } label: {
                    Label("Run AI Inference", systemImage: "sparkles")
                        .labelStyle(.iconOnly)
                }
                .disabled(processing.isProcessing)
            }
        }
        .onDisappear {
            processingTask?.cancel()
        }
    }

    private func startProcessing() {
        startProcessing(urlsOverride: nil, forceOverride: nil)
    }

    private func startProcessing(urlsOverride: [URL]?, forceOverride: Bool?) {
        guard !processing.isProcessing else { return }
        guard selectedCaseID != nil else {
            processing.status = "Select a case first."
            return
        }

        let force = forceOverride ?? forceReindexOnRun

        let allDocs = caseDocuments
        let allURLs: [URL] = urlsOverride ?? allDocs.map { URL(fileURLWithPath: $0.localPath) }
        guard !allURLs.isEmpty else { return }

        let workDocs: [DocumentModel]
        if force {
            workDocs = allDocs
        } else if skipCachedOnRun {
            workDocs = allDocs.filter { needsIndexing($0) }
        } else {
            workDocs = allDocs
        }

        // Option D: prompt when there is no work to do.
        if !force, skipCachedOnRun, workDocs.isEmpty {
            pendingRunURLs = allURLs
            showingNoChangesPrompt = true
            return
        }

        let urlsToIndex: [URL]
        if urlsOverride != nil {
            // Caller explicitly provided URLs.
            urlsToIndex = allURLs
        } else {
            urlsToIndex = workDocs.map { URL(fileURLWithPath: $0.localPath) }
        }

        processing.isProcessing = true
        indexedUpdateCount = 0
        processing.status = force ? "Starting (force re-index)…" : "Starting indexing…"
        processing.progress = 0
        traceStore.log(TraceEvent(stage: "UI", message: "User started indexing", metadata: [
            "documents": "\(urlsToIndex.count)",
            "skipCached": "\(skipCachedOnRun)",
            "force": "\(force)"
        ]))

        processingTask?.cancel()
        processingTask = Task {
            // Stream progress from the indexing actor.
            for await ev in await indexer.index(
                urls: urlsToIndex,
                enableAI: (ai.isLocalEnabled || ai.isCloudEnabled),
                forceReindex: force,
                trace: { event in
                    Task { @MainActor in
                        traceStore.log(event)
                    }
                }
            ) {
                if Task.isCancelled { break }

                let total = max(ev.total, 1)
                let completed = min(max(ev.completed, 0), total)
                await MainActor.run {
                    processing.status = ev.message
                    processing.progress = Double(completed) / Double(total)
                    processing.currentFilePath = ev.currentPath

                    // Live preview updates
                    if let thumb = ev.thumbnailPath {
                        processing.currentThumbnailPath = thumb
                    }
                    if let ex = ev.extractedTextChars {
                        processing.currentExtractedTextChars = ex
                    }
                    if let ocr = ev.ocrTextChars {
                        processing.currentOCRTextChars = ocr
                    }
                }

                await MainActor.run {
                    updateDocumentFromProgress(ev)
                }
            }

            if Task.isCancelled {
                await MainActor.run {
                    processing.status = "Cancelled."
                    processing.isProcessing = false
                    processing.currentFilePath = nil
                    processing.currentThumbnailPath = nil
                    processing.currentExtractedTextChars = nil
                    processing.currentOCRTextChars = nil
                }
                traceStore.log(TraceEvent(level: .warning, stage: "UI", message: "Indexing cancelled by user"))
                return
            }

            // Sync derived artifacts (meta/text/ocr/thumb/dhash) back into SwiftData.
            await syncDerivedArtifactsIntoSwiftData()

            // Optional: refresh duplicate clusters after indexing.
            await analyzeDuplicates(refreshOnly: true)

            await MainActor.run {
                processing.status = "Done."
                processing.progress = 1
                processing.isProcessing = false
                processing.currentFilePath = nil
                processing.currentThumbnailPath = nil
                processing.currentExtractedTextChars = nil
                processing.currentOCRTextChars = nil
            }
            traceStore.log(TraceEvent(stage: "UI", message: "Indexing completed"))
        }
    }

    private func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
    }

    private func needsIndexing(_ doc: DocumentModel) -> Bool {
        // Consider a document indexed if it has a derived folder and at least one derived artifact.
        let hasDerived = (doc.derivedFolderPath?.isEmpty == false)
        let hasAnyArtifact = (doc.thumbnailPath?.isEmpty == false)
            || (doc.extractedTextPath?.isEmpty == false)
            || (doc.ocrTextPath?.isEmpty == false)
            || (doc.dHash?.isEmpty == false)

        if doc.indexingVersion < DocumentModel.currentIndexingVersion { return true }
        if !hasDerived { return true }
        if !hasAnyArtifact { return true }
        if doc.lastIndexedAt == nil { return true }
        return false
    }

    @MainActor
    private func updateDocumentFromProgress(_ ev: IndexingService.ProgressEvent) {
        // Try to match by exact path first, then fall back to sha256.
        let doc: DocumentModel?
        if let p = ev.currentPath {
            doc = caseDocuments.first(where: { $0.localPath == p })
        } else {
            doc = nil
        }

        let resolved = doc ?? (ev.sha256.flatMap { sha in caseDocuments.first(where: { $0.sha256 == sha }) })
        guard let resolved else { return }

        if let sha = ev.sha256, !sha.isEmpty { resolved.sha256 = sha }
        if let p = ev.derivedFolderPath, !p.isEmpty {
            resolved.derivedFolderPath = p
            resolved.normalizedDerivedFolderPath = DocumentModel.normalizePath(p)
        }
        if let p = ev.thumbnailPath, !p.isEmpty {
            resolved.thumbnailPath = p
            resolved.normalizedThumbnailPath = DocumentModel.normalizePath(p)
        }
        if let p = ev.extractedTextPath, !p.isEmpty {
            resolved.extractedTextPath = p
            resolved.normalizedExtractedTextPath = DocumentModel.normalizePath(p)
        }
        if let p = ev.ocrTextPath, !p.isEmpty {
            resolved.ocrTextPath = p
            resolved.normalizedOCRTextPath = DocumentModel.normalizePath(p)
        }
        if let dh = ev.dHash, !dh.isEmpty { resolved.dHash = dh }

        // Consider any derived output as proof the doc is indexed.
        if ev.derivedFolderPath != nil || ev.thumbnailPath != nil || ev.extractedTextPath != nil || ev.ocrTextPath != nil || ev.dHash != nil {
            resolved.lastIndexedAt = Date()
            resolved.indexingVersion = DocumentModel.currentIndexingVersion
        }

        indexedUpdateCount += 1
        if indexedUpdateCount % 10 == 0 {
            try? modelContext.save()
        }
    }

    @MainActor
    private func syncDerivedArtifactsIntoSwiftData() async {
        do {
            let derivedRoot = try derivedRootDirectory()

            for doc in caseDocuments {
                let fileURL = URL(fileURLWithPath: doc.localPath)
                doc.normalizedLocalPath = DocumentModel.normalizePath(doc.localPath)

                // Ensure sha256 is present (IndexingService already computed it, but we don't currently
                // return the value through the stream, so we recompute here if needed).
                if doc.sha256 == nil || doc.sha256?.isEmpty == true {
                    doc.sha256 = try? HashUtils.sha256(for: fileURL)
                }

                guard let sha = doc.sha256, !sha.isEmpty else { continue }

                let folder = derivedRoot.appendingPathComponent(sha, isDirectory: true)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }

                doc.derivedFolderPath = folder.path
                doc.normalizedDerivedFolderPath = DocumentModel.normalizePath(folder.path)
                doc.lastIndexedAt = Date()
                doc.indexingVersion = DocumentModel.currentIndexingVersion

                let textURL = folder.appendingPathComponent("text.txt")
                if FileManager.default.fileExists(atPath: textURL.path) {
                    doc.extractedTextPath = textURL.path
                    doc.normalizedExtractedTextPath = DocumentModel.normalizePath(textURL.path)
                }

                let ocrURL = folder.appendingPathComponent("ocr.txt")
                if FileManager.default.fileExists(atPath: ocrURL.path) {
                    doc.ocrTextPath = ocrURL.path
                    doc.normalizedOCRTextPath = DocumentModel.normalizePath(ocrURL.path)
                }

                let thumbURL = folder.appendingPathComponent("thumb.png")
                if FileManager.default.fileExists(atPath: thumbURL.path) {
                    doc.thumbnailPath = thumbURL.path
                    doc.normalizedThumbnailPath = DocumentModel.normalizePath(thumbURL.path)
                }

                let dhURL = folder.appendingPathComponent("dhash.txt")
                if FileManager.default.fileExists(atPath: dhURL.path),
                   let dh = try? String(contentsOf: dhURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                   !dh.isEmpty {
                    doc.dHash = dh
                }
            }

            try modelContext.save()
        } catch {
            // If this fails, keep it non-fatal; user still has derived artifacts on disk.
            await MainActor.run {
                processing.status = "Indexed, but failed to sync derived artifacts: \(error.localizedDescription)"
            }
        }
    }

    private func derivedRootDirectory() throws -> URL {
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

    private func analyzeDuplicates() {
        processingTask?.cancel() // don't cancel indexing; just ensure we don't reuse this task slot
        Task { await analyzeDuplicates(refreshOnly: false) }
    }

    private func analyzeDuplicates(refreshOnly: Bool) async {
        if !refreshOnly {
            await MainActor.run {
                isAnalyzingDuplicates = true
                duplicatesStatus = "Analyzing duplicates…"
            }
        } else {
            await MainActor.run {
                duplicatesStatus = "Refreshing duplicate clusters…"
            }
        }

        guard selectedCaseID != nil else {
            await MainActor.run {
                isAnalyzingDuplicates = false
                duplicatesStatus = "Select a case first."
                duplicateClusters = []
            }
            return
        }

        let docs: [DocumentSnapshot] = caseDocuments.map { d in
            DocumentSnapshot(
                id: d.id,
                fileName: d.fileName,
                localPath: d.localPath,
                sha256: d.sha256,
                dHash: d.dHash,
                extractedTextPath: d.extractedTextPath,
                ocrTextPath: d.ocrTextPath
            )
        }
        let clusters = await duplicateAnalyzer.analyze(documents: docs, nearThreshold: 10)

        await MainActor.run {
            duplicateClusters = clusters
            isAnalyzingDuplicates = false
            if clusters.isEmpty {
                duplicatesStatus = "No duplicate clusters found."
            } else {
                duplicatesStatus = "Found \(clusters.count) cluster(s)."
            }
        }
    }

    private func runAIRedactionInferenceForCurrentFile() async {
        // Prefer the currently analyzed file; otherwise fall back to the newest document.
        let currentPath = processing.currentFilePath
        let doc: DocumentModel?
        if let currentPath {
            doc = caseDocuments.first(where: { $0.localPath == currentPath })
        } else {
            doc = caseDocuments.first
        }

        guard let doc else {
            await MainActor.run { aiStatus = "No document available for AI inference." }
            return
        }

        // Load extracted/OCR text if present.
        let extracted = readTextIfExists(doc.extractedTextPath)
        let ocr = readTextIfExists(doc.ocrTextPath)

        guard let extracted, !extracted.isEmpty || (ocr?.isEmpty == false) else {
            await MainActor.run { aiStatus = "No extracted/OCR text available yet. Run indexing/OCR first." }
            return
        }

        await MainActor.run { aiStatus = "AI: running redaction inference…" }
        traceStore.log(TraceEvent(stage: "AI", message: "UI started redaction inference", filePath: doc.localPath))

        do {
            let resp = try await ai.inferRedactions(
                .init(
                    extractedText: extracted,
                    ocrText: ocr,
                    contextHints: [
                        "fileName": doc.fileName,
                        "sha256": doc.sha256 ?? "",
                        "kind": "document"
                    ]
                )
            )

            // Write a derived artifact next to text/ocr/thumb.
            if let derivedFolder = doc.derivedFolderPath, !derivedFolder.isEmpty {
                let outURL = URL(fileURLWithPath: derivedFolder).appendingPathComponent("ai_redaction_suggestions.txt")
                let header = "Provenance: \(resp.provenance.rawValue)\nWarnings: \(resp.warnings.joined(separator: "; "))\n\n"
                try (header + resp.text).write(to: outURL, atomically: true, encoding: .utf8)
                traceStore.log(TraceEvent(stage: "AI", message: "Wrote AI suggestions", filePath: doc.localPath, metadata: ["path": outURL.path]))
            }

            await MainActor.run {
                aiStatus = "AI: inference complete (\(resp.provenance.rawValue))."
            }
        } catch {
            traceStore.log(TraceEvent(level: .error, stage: "AI", message: "AI inference failed", filePath: doc.localPath, metadata: ["error": error.localizedDescription]))
            await MainActor.run { aiStatus = "AI: failed — \(error.localizedDescription)" }
        }
    }

    private func readTextIfExists(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (try? String(contentsOf: url, encoding: .utf8))
    }

    private func toggleClusterExpand(_ id: UUID) {
        if expandedClusters.contains(id) { expandedClusters.remove(id) }
        else { expandedClusters.insert(id) }
    }

    private func toggleClusterFull(_ id: UUID) {
        if showFullClusterDetail.contains(id) { showFullClusterDetail.remove(id) }
        else { showFullClusterDetail.insert(id) }
    }

    private func explainCluster(_ cluster: DuplicateAnalysisService.DuplicateCluster) async {
        if clusterAILoading.contains(cluster.id) { return }
        clusterAILoading.insert(cluster.id)
        defer { clusterAILoading.remove(cluster.id) }

        let evidence = cluster.members.map {
            """
            file=\($0.fileName)
            sha=\($0.sha256 ?? "")
            score=\($0.completenessScore)
            extracted=\($0.extractedTextChars)
            ocr=\($0.ocrTextChars)
            best=\($0.isBestCandidate)
            """
        }.joined(separator: "\n\n")

        let prompt = """
        Cluster: \(cluster.title)
        Kind: \(cluster.kind.rawValue)

        Evidence:
        \(evidence)

        Explain why the best candidate was selected and what a human should verify next.
        """

        do {
            let resp = try await ai.explainCluster(text: prompt)
            clusterAIText[cluster.id] = resp.text
            expandedClusters.insert(cluster.id)
        } catch {
            clusterAIText[cluster.id] = "AI explanation failed: \(error.localizedDescription)"
            expandedClusters.insert(cluster.id)
        }
    }

    private func openURL(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

private extension View {
    /// Applies the macOS 26 "Liquid Glass" look when available, otherwise falls back to a Material card.
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .padding(12)
            .background {
                if #available(macOS 26.0, *) {
                    Color.clear
                        .glassEffect(in: shape)
                } else {
                    // Fallback for older macOS: translucent material.
                    shape
                        .fill(.ultraThinMaterial)
                }
            }
            .overlay {
                shape
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
    }

    /// Subtle app background that works well with glass layers.
    func appBackground() -> some View {
        self
            .background {
                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.03),
                        Color.primary.opacity(0.01),
                        Color.primary.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
    }
}

private struct ActionBar: View {
    let isProcessing: Bool
    let hasDocuments: Bool
    let isAnalyzingDuplicates: Bool
    let onRun: () -> Void
    let onCancel: () -> Void
    let onReset: () -> Void
    let onAnalyze: () -> Void
    let onIndexOptions: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ActionButton(title: "Run", systemImage: "play.fill") { onRun() }
                .disabled(isProcessing || !hasDocuments)

            ActionButton(title: "Cancel", systemImage: "stop.fill") { onCancel() }
                .disabled(!isProcessing)

            ActionButton(title: "Reset", systemImage: "arrow.counterclockwise") { onReset() }
                .disabled(isProcessing)

            ActionButton(title: "Analyze", systemImage: "square.stack.3d.up") { onAnalyze() }
                .disabled(isProcessing || !hasDocuments || isAnalyzingDuplicates)

            Spacer()
        }
        .glassCard(cornerRadius: 16)
    }
}

private struct ActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.caption)
            }
            .frame(minWidth: 64)
        }
        .buttonStyle(.borderedProminent)
    }
}

private struct DuplicatesPanel: View {
    let clusters: [DuplicateAnalysisService.DuplicateCluster]
    let isAnalyzing: Bool
    let status: String
    let clusterAIText: [UUID: String]
    let clusterAILoading: Set<UUID>
    let expandedClusters: Set<UUID>
    let showFullClusterDetail: Set<UUID>
    let onAnalyze: () -> Void
    let onExplainCluster: (DuplicateAnalysisService.DuplicateCluster) -> Void
    let onToggleExpand: (UUID) -> Void
    let onToggleFull: (UUID) -> Void
    let onOpenOriginal: (String) -> Void
    let onOpenDerived: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Duplicates", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Spacer()
                Button {
                    onAnalyze()
                } label: {
                    Text(isAnalyzing ? "Analyzing…" : "Analyze")
                }
                .disabled(isAnalyzing)
            }

            if clusters.isEmpty {
                ContentUnavailableView(
                    "No clusters",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Run Analyze after indexing to group exact and near-duplicate documents."))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(clusters) { cluster in
                            ClusterCard(
                                cluster: cluster,
                                aiText: clusterAIText[cluster.id],
                                isLoadingAI: clusterAILoading.contains(cluster.id),
                                isExpanded: expandedClusters.contains(cluster.id),
                                showFullDetail: showFullClusterDetail.contains(cluster.id),
                                onExplain: { onExplainCluster(cluster) },
                                onToggleExpand: { onToggleExpand(cluster.id) },
                                onToggleFull: { onToggleFull(cluster.id) },
                                onOpenOriginal: onOpenOriginal,
                                onOpenDerived: onOpenDerived
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18)
    }
}

private struct ClusterCard: View {
    let cluster: DuplicateAnalysisService.DuplicateCluster
    let aiText: String?
    let isLoadingAI: Bool
    let isExpanded: Bool
    let showFullDetail: Bool
    let onExplain: () -> Void
    let onToggleExpand: () -> Void
    let onToggleFull: () -> Void
    let onOpenOriginal: (String) -> Void
    let onOpenDerived: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(cluster.title)
                    .font(.headline)
                Spacer()
                Button(isLoadingAI ? "Explaining…" : "Explain") { onExplain() }
                    .disabled(isLoadingAI)
                Button {
                    onToggleExpand()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .padding(6)
                }
                .buttonStyle(.plain)
            }

            if !cluster.rationale.isEmpty {
                Text(cluster.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(cluster.members) { m in
                HStack(spacing: 10) {
                    if m.isBestCandidate {
                        Text("Best")
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.green.opacity(0.18))
                            .clipShape(Capsule())
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.fileName)
                            .font(.callout)
                        Text("score \(m.completenessScore) • text \(m.extractedTextChars) • ocr \(m.ocrTextChars)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Spacer()

                    Button("Open") { onOpenOriginal(m.localPath) }
                        .buttonStyle(.link)
                    if let derived = derivedFolderPath(from: m) {
                        Button("Derived") { onOpenDerived(derived) }
                            .buttonStyle(.link)
                    }
                }
                .padding(.vertical, 2)
            }

            if isExpanded {
                let text = aiText ?? "No AI explanation yet."
                let short = String(text.prefix(500))

                VStack(alignment: .leading, spacing: 6) {
                    Text(showFullDetail ? text : short)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Button(showFullDetail ? "Show less" : "More detail") {
                        onToggleFull()
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .glassCard(cornerRadius: 18)
    }

    private func derivedFolderPath(from m: DuplicateAnalysisService.ClusterMember) -> String? {
        guard let sha = m.sha256, !sha.isEmpty else { return nil }
        do {
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            return appSupport
                .appendingPathComponent("RedactionResearchApp", isDirectory: true)
                .appendingPathComponent("Derived", isDirectory: true)
                .appendingPathComponent(sha, isDirectory: true)
                .path
        } catch {
            return nil
        }
    }
}
