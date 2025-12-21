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
    @Environment(\.openWindow) private var openWindow
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
    @State private var showingEnableLocalPrompt: Bool = false
    @State private var showingRoutePicker: Bool = false
    @State private var pendingRouteChoice: AIRouteChoice? = nil
    @State private var pendingAIRun: (() async -> Void)? = nil
    @State private var aiStatus: String = ""

    @StateObject private var processing = ProcessingStatus()
    @State private var processingTask: Task<Void, Never>? = nil

    // Indexing options
    @AppStorage("indexing.skipCached") private var skipCachedOnRun: Bool = true
    @AppStorage("indexing.forceReindex") private var forceReindexOnRun: Bool = false

    @State private var showingNoChangesPrompt: Bool = false
    @State private var pendingRunURLs: [URL] = []

    @State private var indexedUpdateCount: Int = 0
    @State private var processingStartedAt: Date? = nil

    @State private var similarityClusters: [ClusterAnalysisService.SimilarityCluster] = []
    @State private var isAnalyzingClusters: Bool = false
    @State private var clustersStatus: String = ""

    // Cluster-level AI explanation state
    @State private var clusterAIText: [UUID: String] = [:]
    @State private var clusterAILoading: Set<UUID> = []
    @State private var expandedClusters: Set<UUID> = []
    @State private var showFullClusterDetail: Set<UUID> = []

    private let indexer = IndexingService()
    private let clusterAnalyzer = ClusterAnalysisService()

    private enum AIRouteChoice {
        case local
        case cloud
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            VStack(spacing: 12) {
                ProgressScratchpadView(processing: processing)
                ActionBar(
                    isProcessing: processing.isProcessing,
                    hasDocuments: !caseDocuments.isEmpty,
                    isAnalyzingClusters: isAnalyzingClusters,
                    onRun: { startProcessing() },
                    onCancel: { cancelProcessing() },
                    onReset: { processing.reset() },
                    onAnalyze: { analyzeClusters() },
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
                ClusterDetailView(
                    clusters: similarityClusters,
                    isAnalyzing: isAnalyzingClusters,
                    status: clustersStatus,
                    clusterAIText: clusterAIText,
                    clusterAILoading: clusterAILoading,
                    expandedClusters: expandedClusters,
                    showFullClusterDetail: showFullClusterDetail,
                    onAnalyze: { analyzeClusters() },
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
                    ai.markConsent(forLocal: false)
                    ai.setCloudAIEnabled(true)
                    aiStatus = "Cloud AI enabled"
                    runPendingAIRun()
                }
                Button("Cancel", role: .cancel) {
                    clearPendingAIRun()
                }
            } message: {
                Text("Cloud AI sends text and prompts to a configured provider. Only enable if you are comfortable sending derived text off-device.")
            }
            .alert("Enable Local AI?", isPresented: $showingEnableLocalPrompt) {
                Button("Enable", role: .destructive) {
                    ai.markConsent(forLocal: true)
                    ai.setLocalAIEnabled(true)
                    aiStatus = "Local AI enabled"
                    runPendingAIRun()
                }
                Button("Cancel", role: .cancel) {
                    clearPendingAIRun()
                }
            } message: {
                Text("Local AI runs on-device. Inputs stay on this Mac and are not sent to cloud providers.")
            }
            .confirmationDialog("Choose how to route AI tasks", isPresented: $showingRoutePicker, titleVisibility: .visible) {
                Button("Enable Local AI (on-device)") { handleRouteChoice(.local) }
                Button("Enable Cloud AI (off-device)") { handleRouteChoice(.cloud) }
                Button("Cancel", role: .cancel) { clearPendingAIRun() }
            } message: {
                Text("Select whether to keep AI processing local or allow cloud routing before running this task.")
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
                    analyzeClusters()
                } label: {
                    Label("Analyze Clusters", systemImage: "square.stack.3d.up")
                        .labelStyle(.iconOnly)
                }
                .disabled(processing.isProcessing || caseDocuments.isEmpty || isAnalyzingClusters)

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
                    handleRouteChoice(.local)
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
                    if ai.isCloudEnabled {
                        ai.setCloudAIEnabled(false)
                        aiStatus = "Cloud AI disabled"
                    } else {
                        handleRouteChoice(.cloud)
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

                Button {
                    openWindow(id: "execution-trace")
                } label: {
                    Label("Execution Trace", systemImage: "waveform.path.ecg")
                        .labelStyle(.iconOnly)
                }
            }
        }
        .onDisappear {
            processingTask?.cancel()
        }
    }

    private func startProcessing() {
        startProcessing(urlsOverride: nil, forceOverride: nil)
    }

    @MainActor
    private func requireAIRouteThenRun(_ action: @escaping () async -> Void) {
        if ai.isLocalEnabled || ai.isCloudEnabled {
            Task { await action() }
            return
        }
        pendingAIRun = action
        showingRoutePicker = true
    }

    private func handleRouteChoice(_ route: AIRouteChoice) {
        pendingRouteChoice = route
        switch route {
        case .local:
            if ai.hasLocalConsent {
                ai.setLocalAIEnabled(true)
                aiStatus = "Local AI enabled"
                runPendingAIRun()
            } else {
                showingEnableLocalPrompt = true
            }
        case .cloud:
            if ai.hasCloudConsent {
                ai.setCloudAIEnabled(true)
                aiStatus = "Cloud AI enabled"
                runPendingAIRun()
            } else {
                showingEnableCloudPrompt = true
            }
        }
    }

    private func runPendingAIRun() {
        let action = pendingAIRun
        pendingAIRun = nil
        pendingRouteChoice = nil
        Task { await action?() }
    }

    private func clearPendingAIRun() {
        pendingAIRun = nil
        pendingRouteChoice = nil
        showingRoutePicker = false
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
        if skipCachedOnRun {
            workDocs = allDocs.filter { IndexingService.needsIndexing(for: $0, force: force) }
        } else {
            workDocs = allDocs
        }

        // Option D: prompt when there is no work to do.
        if !force, skipCachedOnRun, workDocs.isEmpty {
            pendingRunURLs = allURLs
            processing.status = "No changes detected."
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
        processingStartedAt = Date()
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
                caseID: selectedCaseID,
                trace: { event in
                    Task { @MainActor in
                        traceStore.log(event)
                    }
                }
            ) {
                guard ev.caseID == nil || ev.caseID == selectedCaseID else { continue }
                if Task.isCancelled { break }

                let total = max(ev.total, 1)
                let completed = min(max(ev.completed, 0), total)
                await MainActor.run {
                    let normalizedPath = ev.currentPath ?? caseDocuments.first(where: { $0.sha256 == ev.sha256 })?.localPath
                    processing.status = ev.message
                    processing.progress = Double(completed) / Double(total)
                    processing.currentFilePath = normalizedPath

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
                let duration = processingStartedAt.map { Date().timeIntervalSince($0) * 1000 }
                await MainActor.run {
                    processing.status = "Cancelled."
                    processing.isProcessing = false
                    processing.currentFilePath = nil
                    processing.currentThumbnailPath = nil
                    processing.currentExtractedTextChars = nil
                    processing.currentOCRTextChars = nil
                }
                traceStore.log(TraceEvent(level: .warning, stage: "UI", message: "Indexing cancelled by user", durationMs: duration))
                processingStartedAt = nil
                return
            }

            // Sync derived artifacts (meta/text/ocr/thumb/dhash) back into SwiftData.
            await syncDerivedArtifactsIntoSwiftData()

            // Optional: refresh similarity clusters after indexing.
            await analyzeClusters(refreshOnly: true)

            await MainActor.run {
                try? modelContext.save()
            }

            await MainActor.run {
                processing.status = "Done."
                processing.progress = 1
                processing.isProcessing = false
                processing.currentFilePath = nil
                processing.currentThumbnailPath = nil
                processing.currentExtractedTextChars = nil
                processing.currentOCRTextChars = nil
            }
            let duration = processingStartedAt.map { Date().timeIntervalSince($0) * 1000 }
            traceStore.log(TraceEvent(stage: "UI", message: "Indexing completed", durationMs: duration))
            processingStartedAt = nil
        }
    }

    private func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
    }

    @MainActor
    private func updateDocumentFromProgress(_ ev: IndexingService.ProgressEvent) {
        if let evCase = ev.caseID, let activeCaseID = selectedCaseID, evCase != activeCaseID {
            return
        }

        let resolved: DocumentModel?
        if let path = ev.currentPath, let match = caseDocuments.first(where: { $0.localPath == path }) {
            resolved = match
        } else if let sha = ev.sha256, let match = caseDocuments.first(where: { $0.sha256 == sha }) {
            resolved = match
        } else {
            resolved = nil
        }
        guard let resolved else { return }

        let normalizedPath = ev.currentPath ?? resolved.localPath
        if let normalizedPath, resolved.localPath != normalizedPath {
            resolved.localPath = normalizedPath
        }

        if let sha = ev.sha256, !sha.isEmpty { resolved.sha256 = sha }
        if let p = ev.derivedFolderPath, !p.isEmpty { resolved.derivedFolderPath = p }
        if let p = ev.thumbnailPath, !p.isEmpty { resolved.thumbnailPath = p }
        if let p = ev.extractedTextPath, !p.isEmpty { resolved.extractedTextPath = p }
        if let p = ev.ocrTextPath, !p.isEmpty { resolved.ocrTextPath = p }
        if let dh = ev.dHash, !dh.isEmpty { resolved.dHash = dh }

        // Consider any derived output as proof the doc is indexed.
        if ev.derivedFolderPath != nil || ev.thumbnailPath != nil || ev.extractedTextPath != nil || ev.ocrTextPath != nil || ev.dHash != nil {
            resolved.lastIndexedAt = Date()
            resolved.indexingVersion = IndexingService.currentIndexingVersion
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
                doc.lastIndexedAt = Date()
                doc.indexingVersion = IndexingService.currentIndexingVersion

                let textURL = folder.appendingPathComponent("text.txt")
                if FileManager.default.fileExists(atPath: textURL.path) {
                    doc.extractedTextPath = textURL.path
                }

                let ocrURL = folder.appendingPathComponent("ocr.txt")
                if FileManager.default.fileExists(atPath: ocrURL.path) {
                    doc.ocrTextPath = ocrURL.path
                }

                let thumbURL = folder.appendingPathComponent("thumb.png")
                if FileManager.default.fileExists(atPath: thumbURL.path) {
                    doc.thumbnailPath = thumbURL.path
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

    private func analyzeClusters() {
        processingTask?.cancel() // don't cancel indexing; just ensure we don't reuse this task slot
        Task { await analyzeClusters(refreshOnly: false) }
    }

    private func analyzeClusters(refreshOnly: Bool) async {
        if !refreshOnly {
            await MainActor.run {
                isAnalyzingClusters = true
                clustersStatus = "Analyzing clusters…"
            }
        } else {
            await MainActor.run {
                clustersStatus = "Refreshing clusters…"
            }
        }

        guard selectedCaseID != nil else {
            await MainActor.run {
                isAnalyzingClusters = false
                clustersStatus = "Select a case first."
                similarityClusters = []
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
        let clusters = await clusterAnalyzer.analyze(documents: docs, nearThreshold: 10)

        await MainActor.run {
            similarityClusters = clusters
            isAnalyzingClusters = false
            if clusters.isEmpty {
                clustersStatus = "No clusters found."
            } else {
                clustersStatus = "Found \(clusters.count) cluster(s)."
            }
        }
    }

    private func runAIRedactionInferenceForCurrentFile() async {
        if !(ai.isLocalEnabled || ai.isCloudEnabled) {
            await MainActor.run {
                requireAIRouteThenRun { await runAIRedactionInferenceForCurrentFile() }
            }
            return
        }

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

    private func explainCluster(_ cluster: ClusterAnalysisService.SimilarityCluster) async {
        if clusterAILoading.contains(cluster.id) { return }
        clusterAILoading.insert(cluster.id)
        defer { clusterAILoading.remove(cluster.id) }

        let members = cluster.exactDuplicates + cluster.variants
        let evidence = members.map {
            """
            file=\($0.fileName)
            sha=\($0.sha256 ?? "")
            score=\($0.completenessScore)
            extracted=\($0.extractedTextChars)
            ocr=\($0.ocrTextChars)
            best=\($0.isBestCandidate)
            """
        }.joined(separator: "\n\n")

        let reasons = cluster.reasons.map { "\($0.label): \($0.detail) (\(Int($0.confidence * 100))%)" }
            .joined(separator: "; ")

        let prompt = """
        Cluster: \(cluster.title)
        Confidence: \(Int(cluster.confidence * 100))%
        Reasons: \(reasons)

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
    let isAnalyzingClusters: Bool
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
                .disabled(isProcessing || !hasDocuments || isAnalyzingClusters)

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

