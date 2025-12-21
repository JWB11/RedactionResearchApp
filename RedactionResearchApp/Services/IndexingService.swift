import Foundation
import CryptoKit
import UniformTypeIdentifiers

#if canImport(PDFKit)
import PDFKit
#endif

#if canImport(AppKit)
import AppKit
#endif

#if canImport(Vision)
import Vision
#endif

actor IndexingService {
    struct ProgressEvent: Sendable {
        enum Kind: String, Sendable {
            case update
            case finished
            case failed
        }

        var kind: Kind
        var completed: Int
        var total: Int
        var message: String
        /// Full path to the file currently being processed (if applicable).
        var currentPath: String?

        // MARK: Live preview payload
        /// SHA-256 for the current file (available after hashing).
        var sha256: String?
        /// Full path to the generated thumbnail (available after thumbnail generation).
        var thumbnailPath: String?
        /// Full path to the derived artifact folder for this file (sha-based).
        var derivedFolderPath: String?
        /// Full path to extracted text artifact, if written.
        var extractedTextPath: String?
        /// Full path to OCR text artifact, if written.
        var ocrTextPath: String?
        /// Perceptual hash of the preview thumbnail (hex), if computed.
        var dHash: String?
        /// Character count of extracted text (when applicable).
        var extractedTextChars: Int?
        /// Character count of OCR text (when applicable).
        var ocrTextChars: Int?

        init(
            kind: Kind = .update,
            completed: Int,
            total: Int,
            message: String,
            currentPath: String? = nil,
            sha256: String? = nil,
            thumbnailPath: String? = nil,
            derivedFolderPath: String? = nil,
            extractedTextPath: String? = nil,
            ocrTextPath: String? = nil,
            dHash: String? = nil,
            extractedTextChars: Int? = nil,
            ocrTextChars: Int? = nil
        ) {
            self.kind = kind
            self.completed = completed
            self.total = total
            self.message = message
            self.currentPath = currentPath
            self.sha256 = sha256
            self.thumbnailPath = thumbnailPath
            self.derivedFolderPath = derivedFolderPath
            self.extractedTextPath = extractedTextPath
            self.ocrTextPath = ocrTextPath
            self.dHash = dHash
            self.extractedTextChars = extractedTextChars
            self.ocrTextChars = ocrTextChars
        }
    }

    struct IndexSummary: Sendable {
        var totalFiles: Int
        var hashed: Int
        var ocrAttempted: Int
        var textExtracted: Int
        var thumbnailsGenerated: Int
        var zippedExpanded: Int
        var errors: Int
    }

    /// Indexes the provided URLs (files, folders, and ZIPs), writing derived artifacts into
    /// Application Support/RedactionResearchApp/Derived.
    ///
    /// Emits progress updates suitable for a progress bar + scratchpad.
    func index(
        urls: [URL],
        enableAI: Bool = false,
        forceReindex: Bool = false,
        trace: (@Sendable (TraceEvent) -> Void)? = nil
    ) -> AsyncStream<ProgressEvent> {
        AsyncStream { continuation in
            Task.detached(priority: .utility) {
                let continuation = continuation

                // MARK: - Concurrency helpers

                actor YieldSink {
                    private let continuation: AsyncStream<ProgressEvent>.Continuation
                    init(_ continuation: AsyncStream<ProgressEvent>.Continuation) {
                        self.continuation = continuation
                    }
                    func yield(_ ev: ProgressEvent) {
                        continuation.yield(ev)
                    }
                    func finish() {
                        continuation.finish()
                    }
                }

                actor Stats {
                    private(set) var summary: IndexSummary
                    init(summary: IndexSummary) { self.summary = summary }
                    func incHashed() { summary.hashed += 1 }
                    func incTextExtracted() { summary.textExtracted += 1 }
                    func incThumb() { summary.thumbnailsGenerated += 1 }
                    func incOCR() { summary.ocrAttempted += 1 }
                    func incZip() { summary.zippedExpanded += 1 }
                    func incErrors() { summary.errors += 1 }
                    func setTotal(_ n: Int) { summary.totalFiles = n }
                    func snapshot() -> IndexSummary { summary }
                }

                actor InflightSHA {
                    private var set: Set<String> = []
                    func claim(_ sha: String) -> Bool {
                        if set.contains(sha) { return false }
                        set.insert(sha)
                        return true
                    }
                    func release(_ sha: String) { set.remove(sha) }
                }

                actor AsyncSemaphore {
                    private var permits: Int
                    init(_ permits: Int) { self.permits = max(1, permits) }
                    func acquire() async {
                        while permits == 0 {
                            await Task.yield()
                        }
                        permits -= 1
                    }
                    func release() {
                        permits += 1
                    }
                }

                actor CompletedCounter {
                    private var done: Int = 0
                    func snapshot() -> Int { done }
                    func increment() -> Int {
                        done += 1
                        return done
                    }
                }

                struct ArtifactFlags {
                    var hasThumb: Bool
                    var hasText: Bool
                    var hasOCR: Bool
                    var any: Bool { hasThumb || hasText || hasOCR }
                }

                func loadDerivedCache(root: URL) -> [String: ArtifactFlags] {
                    // Build a RAM cache keyed by sha folder name.
                    // This avoids repeated per-file fileExists() calls on large corpora.
                    var cache: [String: ArtifactFlags] = [:]
                    let fm = FileManager.default
                    guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                        return cache
                    }
                    for dir in items {
                        let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        guard isDir else { continue }
                        let sha = dir.lastPathComponent
                        let thumb = dir.appendingPathComponent("thumb.png").path
                        let text = dir.appendingPathComponent("text.txt").path
                        let ocr = dir.appendingPathComponent("ocr.txt").path
                        let flags = ArtifactFlags(
                            hasThumb: fm.fileExists(atPath: thumb),
                            hasText: fm.fileExists(atPath: text),
                            hasOCR: fm.fileExists(atPath: ocr)
                        )
                        if flags.any {
                            cache[sha] = flags
                        }
                    }
                    return cache
                }

                func tlog(
                    _ level: TraceEvent.Level = .info,
                    _ stage: String,
                    _ message: String,
                    filePath: String? = nil,
                    sha256: String? = nil,
                    derivedFolderPath: String? = nil,
                    artifactPath: String? = nil,
                    thumbnailPath: String? = nil,
                    durationMs: Double? = nil,
                    metadata: [String: String] = [:]
                ) {
                    trace?(TraceEvent(
                        level: level,
                        stage: stage,
                        message: message,
                        filePath: filePath,
                        sha256: sha256,
                        derivedFolderPath: derivedFolderPath,
                        artifactPath: artifactPath,
                        thumbnailPath: thumbnailPath,
                        durationMs: durationMs,
                        metadata: metadata
                    ))
                }

                let sink = YieldSink(continuation)

                // Bounded parallelism. Hashing can run higher, OCR should stay moderate.
                // Start conservative to keep UI responsive and avoid thrashing.
                let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
                let maxConcurrency = min(12, max(2, cores))
                let semaphore = AsyncSemaphore(maxConcurrency)
                let inflight = InflightSHA()

                // OCR is much heavier than hashing/text extraction; keep it more bounded.
                let ocrConcurrency = min(4, max(2, cores / 2))
                let ocrSemaphore = AsyncSemaphore(ocrConcurrency)

                let completed = CompletedCounter()

                // If extracted text is tiny (common for scanned PDFs), attempt OCR.
                let ocrTextThresholdChars = 200

                let stats = Stats(summary: IndexSummary(
                    totalFiles: 0,
                    hashed: 0,
                    ocrAttempted: 0,
                    textExtracted: 0,
                    thumbnailsGenerated: 0,
                    zippedExpanded: 0,
                    errors: 0
                ))

                let indexStart = Date()

                // Use sink for progress events
                tlog(.info, "Index", "Indexing started", metadata: ["inputCount": "\(urls.count)", "forceReindex": "\(forceReindex)"])
                await sink.yield(.init(completed: 0, total: 1, message: "Preparing inputs…"))

                func runAIIfEnabled(extractedText: String?, ocrText: String?, fileURL: URL, sha256: String, artifactDir: URL, thumbPath: String?) async {
                    guard enableAI else { return }

                    let aiStart = Date()

                    let extracted = extractedText ?? ""
                    let ocr = ocrText
                    // If we have essentially no text, skip.
                    if extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (ocr?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                        tlog(.debug, "AI", "Skipped (no text)", filePath: fileURL.path)
                        return
                    }

                    // Progress + trace
                    await sink.yield(.init(
                        completed: 0,
                        total: 1,
                        message: "AI redaction inference…",
                        currentPath: fileURL.path,
                        sha256: sha256,
                        thumbnailPath: thumbPath
                    ))
                    tlog(.info, "AI", "Starting redaction inference", filePath: fileURL.path)

                    do {
                        let resp = try await AIService.shared.inferRedactions(
                            .init(
                                extractedText: extracted,
                                ocrText: ocr,
                                contextHints: [
                                    "fileName": fileURL.lastPathComponent,
                                    "sha256": sha256,
                                    "uti": Self.contentType(for: fileURL)?.identifier ?? "",
                                    "byteSize": (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]).map { "\($0)" } ?? ""
                                ]
                            )
                        )

                        let outURL = artifactDir.appendingPathComponent("ai_redaction_suggestions.json")
                        try resp.text.write(to: outURL, atomically: true, encoding: .utf8)

                        tlog(
                            .info,
                            "AI",
                            "Wrote suggestions",
                            filePath: fileURL.path,
                            sha256: sha256,
                            derivedFolderPath: artifactDir.path,
                            artifactPath: outURL.path,
                            thumbnailPath: thumbPath,
                            durationMs: Date().timeIntervalSince(aiStart) * 1000,
                            metadata: ["path": outURL.path, "provenance": resp.provenance.rawValue]
                        )
                        await sink.yield(.init(
                            completed: 0,
                            total: 1,
                            message: "AI inference complete",
                            currentPath: fileURL.path,
                            sha256: sha256,
                            thumbnailPath: thumbPath
                        ))
                    } catch {
                        tlog(
                            .error,
                            "AI",
                            "Inference failed",
                            filePath: fileURL.path,
                            sha256: sha256,
                            derivedFolderPath: artifactDir.path,
                            thumbnailPath: thumbPath,
                            durationMs: Date().timeIntervalSince(aiStart) * 1000,
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }

                do {
                    let expanded = try await Self.expandInputURLs(urls)
                    await stats.setTotal(expanded.count)
                    tlog(.info, "Index", "Expanded inputs", metadata: ["expandedFiles": "\(expanded.count)"])

                    if expanded.isEmpty {
                        await sink.yield(.init(completed: 1, total: 1, message: "Nothing to index."))
                        await sink.finish()
                        return
                    }

                    await sink.yield(.init(completed: 0, total: expanded.count, message: "Indexing \(expanded.count) file(s)…"))

                    let derivedRoot = try Self.derivedRootDirectory()
                    let derivedCache = loadDerivedCache(root: derivedRoot)

                    await withTaskGroup(of: Void.self) { group in
                        for (i, url) in expanded.enumerated() {
                            group.addTask(priority: .utility) {
                                await semaphore.acquire()
                                defer { Task { await semaphore.release() } }

                                let displayName = url.lastPathComponent
                                let fileStart = Date()

                                var currentSha: String? = nil
                                var currentDerivedPath: String? = nil
                                var currentThumbPath: String? = nil

                                tlog(.debug, "File", "Begin", filePath: url.path, metadata: ["name": displayName, "index": "\(i)", "total": "\(expanded.count)"])
                                let c0 = await completed.snapshot()
                                await sink.yield(.init(completed: c0, total: expanded.count, message: "Hashing \(displayName)…", currentPath: url.path))

                                do {
                                    let (sha, size) = try Self.sha256Streaming(for: url)
                                    currentSha = sha
                                    await stats.incHashed()
                                    tlog(.info, "Hash", "SHA-256 computed", filePath: url.path, sha256: sha, metadata: ["sha256": sha, "bytes": "\(size)"])
                                    let c1 = await completed.snapshot()
                                    await sink.yield(.init(completed: c1, total: expanded.count, message: "Hashed \(displayName)", currentPath: url.path, sha256: sha))

                                    // If another task is already generating artifacts for this sha, skip heavy work.
                                    guard await inflight.claim(sha) else {
                                        tlog(.debug, "Dedup", "SHA already processing in this batch; skipping", filePath: url.path, metadata: ["sha256": sha])
                                        await sink.yield(.init(completed: i, total: expanded.count, message: "Duplicate SHA in batch; skipping \(displayName)", currentPath: url.path, sha256: sha))
                                        return
                                    }
                                    defer { Task { await inflight.release(sha) } }

                                    let type = Self.contentType(for: url)
                                    tlog(.debug, "Detect", "Content type resolved", filePath: url.path, metadata: ["uti": type?.identifier ?? "", "ext": url.pathExtension.lowercased()])

                                    let artifactDir = derivedRoot.appendingPathComponent(sha, isDirectory: true)
                                    try FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)
                                    currentDerivedPath = artifactDir.path

                                    // Cache check: consult the prebuilt derived cache (fast) and only fall back to disk if needed.
                                    let cachedThumb = artifactDir.appendingPathComponent("thumb.png")
                                    let cachedText = artifactDir.appendingPathComponent("text.txt")
                                    let cachedOCR = artifactDir.appendingPathComponent("ocr.txt")

                                    let cachedFlags = derivedCache[sha]
                                    let hasCache = (!forceReindex) && (cachedFlags?.any ?? false)

                                    if forceReindex, (cachedFlags?.any ?? false) {
                                        tlog(.info, "Cache", "Force re-index enabled; rebuilding artifacts", filePath: url.path, metadata: ["sha256": sha])
                                    }

                                    // Always (re)write cheap metadata for audit.
                                    let meta: [String: Any] = [
                                        "fileName": displayName,
                                        "originalPath": url.path,
                                        "sha256": sha,
                                        "byteSize": size,
                                        "uti": type?.identifier ?? "",
                                        "indexedAt": ISO8601DateFormatter().string(from: Date())
                                    ]
                                    try Self.writeJSON(meta, to: artifactDir.appendingPathComponent("meta.json"))

                                    if hasCache {
                                        tlog(.debug, "Cache", "Artifacts exist; skipping heavy extraction", filePath: url.path, metadata: ["sha256": sha])
                                        await sink.yield(.init(completed: i, total: expanded.count, message: "Cached; skipped \(displayName)", currentPath: url.path, sha256: sha, thumbnailPath: (cachedFlags?.hasThumb == true) ? cachedThumb.path : nil, derivedFolderPath: artifactDir.path))
                                        return
                                    }

                                    // Stage: Extract text where possible
                                    if Self.isTextLike(type: type, url: url) {
                                        await sink.yield(.init(completed: i, total: expanded.count, message: "Extracting text \(displayName)…", currentPath: url.path))
                                        if let text = try Self.extractText(from: url, type: type) {
                                            await stats.incTextExtracted()
                                            try text.write(to: cachedText, atomically: true, encoding: .utf8)
                                            tlog(.info, "Text", "Extracted text", filePath: url.path, metadata: ["chars": "\(text.count)"])
                                            await sink.yield(.init(completed: i, total: expanded.count, message: "Text extracted \(displayName)", currentPath: url.path, sha256: sha, derivedFolderPath: artifactDir.path, extractedTextPath: cachedText.path, extractedTextChars: text.count))

                                            // Optional AI inference (off by default)
                                            await runAIIfEnabled(extractedText: text, ocrText: nil, fileURL: url, sha256: sha, artifactDir: artifactDir, thumbPath: nil)
                                        }
                                    } else if Self.isPDF(type: type, url: url) {
                                        await sink.yield(.init(completed: i, total: expanded.count, message: "Extracting PDF text \(displayName)…", currentPath: url.path))
                                        let extractedText: String? = Self.extractPDFText(url: url)
                                        let extractedCountForOCR = extractedText?.count ?? 0
                                        if let text = extractedText {
                                            await stats.incTextExtracted()
                                            try text.write(to: cachedText, atomically: true, encoding: .utf8)
                                            tlog(.info, "PDF", "Extracted PDF text", filePath: url.path, metadata: ["chars": "\(text.count)"])
                                            await sink.yield(.init(completed: i, total: expanded.count, message: "PDF text extracted \(displayName)", currentPath: url.path, sha256: sha, derivedFolderPath: artifactDir.path, extractedTextPath: cachedText.path, extractedTextChars: text.count))
                                        }

                                        // Stage: thumbnail from first page
                                        #if canImport(PDFKit) && canImport(AppKit)
                                        await sink.yield(.init(completed: i, total: expanded.count, message: "Rendering thumbnail \(displayName)…", currentPath: url.path))
                                        let thumb: NSImage? = await MainActor.run { Self.pdfThumbnail(url: url, maxPixel: 768) }
                                        if let thumb {
                                            await stats.incThumb()
                                            try await MainActor.run { try Self.writePNG(thumb, to: cachedThumb) }
                                            tlog(
                                                .info,
                                                "Thumb",
                                                "Wrote thumbnail",
                                                filePath: url.path,
                                                sha256: sha,
                                                derivedFolderPath: artifactDir.path,
                                                artifactPath: cachedThumb.path,
                                                thumbnailPath: cachedThumb.path,
                                                metadata: ["path": cachedThumb.path]
                                            )

                                            let thumbPath = cachedThumb.path
                                            currentThumbPath = thumbPath
                                            await sink.yield(.init(completed: i, total: expanded.count, message: "Preview ready \(displayName)", currentPath: url.path, sha256: sha, thumbnailPath: thumbPath, derivedFolderPath: artifactDir.path))

                                            // If OCR is skipped, we can still run AI on extracted PDF text.
                                            if extractedCountForOCR >= ocrTextThresholdChars {
                                                await runAIIfEnabled(extractedText: extractedText, ocrText: nil, fileURL: url, sha256: sha, artifactDir: artifactDir, thumbPath: thumbPath)
                                            }

                                            // Optional: perceptual hash of thumbnail
                                            if let dh = Self.dHash(from: thumb) {
                                                try dh.write(to: artifactDir.appendingPathComponent("dhash.txt"), atomically: true, encoding: .utf8)
                                                tlog(.debug, "dHash", "Computed dHash", filePath: url.path, metadata: ["dhash": dh])
                                                await sink.yield(.init(completed: i, total: expanded.count, message: "Computed dHash \(displayName)", currentPath: url.path, sha256: sha, thumbnailPath: thumbPath, derivedFolderPath: artifactDir.path, dHash: dh))
                                            }

                                            #if canImport(Vision)
                                            if extractedCountForOCR < ocrTextThresholdChars {
                                                await sink.yield(.init(completed: i, total: expanded.count, message: "OCR \(displayName)…", currentPath: url.path, sha256: sha, thumbnailPath: thumbPath, extractedTextChars: extractedCountForOCR))
                                                await stats.incOCR()
                                                await ocrSemaphore.acquire()
                                                defer { Task { await ocrSemaphore.release() } }
                                                if let ocr = try await Self.ocrText(from: thumb) {
                                                    await stats.incTextExtracted()
                                                    try ocr.write(to: cachedOCR, atomically: true, encoding: .utf8)
                                                    tlog(
                                                        .info,
                                                        "OCR",
                                                        "Recognized text",
                                                        filePath: url.path,
                                                        sha256: sha,
                                                        derivedFolderPath: artifactDir.path,
                                                        thumbnailPath: thumbPath,
                                                        metadata: ["chars": "\(ocr.count)"]
                                                    )
                                                    await sink.yield(.init(completed: i, total: expanded.count, message: "OCR complete \(displayName)", currentPath: url.path, sha256: sha, thumbnailPath: thumbPath, derivedFolderPath: artifactDir.path, ocrTextPath: cachedOCR.path, extractedTextChars: extractedCountForOCR, ocrTextChars: ocr.count))

                                                    // Optional AI inference (use both extracted + OCR)
                                                    await runAIIfEnabled(extractedText: extractedText, ocrText: ocr, fileURL: url, sha256: sha, artifactDir: artifactDir, thumbPath: thumbPath)
                                                }
                                            }
                                            #endif
                                        }
                                        #endif
                                    } else if Self.isImage(type: type, url: url) {
                                        #if canImport(AppKit)
                                        await sink.yield(.init(completed: i, total: expanded.count, message: "Generating thumbnail \(displayName)…", currentPath: url.path))
                                        let img: NSImage? = await MainActor.run { NSImage(contentsOf: url) }
                                        let thumb: NSImage? = await MainActor.run {
                                            guard let img else { return nil }
                                            return Self.thumbnail(from: img, maxPixel: 768)
                                        }
                                        if let thumb {
                                            await stats.incThumb()
                                            try await MainActor.run { try Self.writePNG(thumb, to: cachedThumb) }
                                            tlog(
                                                .info,
                                                "Thumb",
                                                "Wrote thumbnail",
                                                filePath: url.path,
                                                sha256: sha,
                                                derivedFolderPath: artifactDir.path,
                                                artifactPath: cachedThumb.path,
                                                thumbnailPath: cachedThumb.path,
                                                metadata: ["path": cachedThumb.path]
                                            )

                                            let thumbPath = cachedThumb.path
                                            currentThumbPath = thumbPath
                                            await sink.yield(.init(completed: i, total: expanded.count, message: "Preview ready \(displayName)", currentPath: url.path, sha256: sha, thumbnailPath: thumbPath, derivedFolderPath: artifactDir.path))

                                            // Perceptual hash
                                            if let dh = Self.dHash(from: thumb) {
                                                try dh.write(to: artifactDir.appendingPathComponent("dhash.txt"), atomically: true, encoding: .utf8)
                                                tlog(.debug, "dHash", "Computed dHash", filePath: url.path, metadata: ["dhash": dh])
                                                await sink.yield(.init(completed: i, total: expanded.count, message: "Computed dHash \(displayName)", currentPath: url.path, sha256: sha, thumbnailPath: thumbPath, derivedFolderPath: artifactDir.path, dHash: dh))
                                            }

                                            // OCR (Vision)
                                            #if canImport(Vision)
                                            await sink.yield(.init(completed: i, total: expanded.count, message: "OCR \(displayName)…", currentPath: url.path, sha256: sha, thumbnailPath: thumbPath))
                                            await stats.incOCR()
                                            await ocrSemaphore.acquire()
                                            defer { Task { await ocrSemaphore.release() } }
                                            if let ocr = try await Self.ocrText(from: thumb) {
                                                await stats.incTextExtracted()
                                                try ocr.write(to: cachedOCR, atomically: true, encoding: .utf8)
                                                tlog(
                                                    .info,
                                                    "OCR",
                                                    "Recognized text",
                                                    filePath: url.path,
                                                    sha256: sha,
                                                    derivedFolderPath: artifactDir.path,
                                                    thumbnailPath: thumbPath,
                                                    metadata: ["chars": "\(ocr.count)"]
                                                )
                                                await sink.yield(.init(completed: i, total: expanded.count, message: "OCR complete \(displayName)", currentPath: url.path, sha256: sha, thumbnailPath: thumbPath, derivedFolderPath: artifactDir.path, ocrTextPath: cachedOCR.path, extractedTextChars: 0, ocrTextChars: ocr.count))

                                                await runAIIfEnabled(extractedText: nil, ocrText: ocr, fileURL: url, sha256: sha, artifactDir: artifactDir, thumbPath: thumbPath)
                                            }
                                            #endif
                                        }
                                        #endif
                                    }
                                } catch {
                                    await stats.incErrors()
                                    await sink.yield(.init(completed: i, total: expanded.count, message: "Error indexing \(displayName): \(error.localizedDescription)", currentPath: url.path))
                                    tlog(.error, "File", "Error", filePath: url.path, metadata: ["error": error.localizedDescription])
                                }

                                _ = await completed.increment()
                                let ms = Int(Date().timeIntervalSince(fileStart) * 1000)
                                tlog(
                                    .debug,
                                    "File",
                                    "End",
                                    filePath: url.path,
                                    sha256: currentSha,
                                    derivedFolderPath: currentDerivedPath,
                                    thumbnailPath: currentThumbPath,
                                    durationMs: Double(ms),
                                    metadata: ["elapsedMs": "\(ms)"]
                                )
                            }
                        }
                        await group.waitForAll()
                    }

                    // Final summary
                    let summary = await stats.snapshot()
                    let summaryMsg = "Done. Files: \(summary.totalFiles), hashed: \(summary.hashed), text: \(summary.textExtracted), thumbs: \(summary.thumbnailsGenerated), OCR tried: \(summary.ocrAttempted), errors: \(summary.errors)."
                    await sink.yield(.init(kind: .finished, completed: summary.totalFiles, total: summary.totalFiles, message: summaryMsg))
                    tlog(
                        .info,
                        "Index",
                        "Indexing finished",
                        durationMs: Date().timeIntervalSince(indexStart) * 1000,
                        metadata: [
                        "files": "\(summary.totalFiles)",
                        "hashed": "\(summary.hashed)",
                        "text": "\(summary.textExtracted)",
                        "thumbs": "\(summary.thumbnailsGenerated)",
                        "ocrTried": "\(summary.ocrAttempted)",
                        "errors": "\(summary.errors)"
                    ])
                    await sink.finish()

                } catch {
                    await sink.yield(.init(kind: .failed, completed: 0, total: 1, message: "Indexing failed: \(error.localizedDescription)"))
                    tlog(.error, "Index", "Indexing failed", metadata: ["error": error.localizedDescription])
                    await sink.finish()
                }
            }
        }
    }
}

// MARK: - Helpers

private extension IndexingService {
    static func contentType(for url: URL) -> UTType? {
        if let rv = try? url.resourceValues(forKeys: [.contentTypeKey]), let t = rv.contentType {
            return t
        }
        return UTType(filenameExtension: url.pathExtension)
    }

    static func isPDF(type: UTType?, url: URL) -> Bool {
        if let type { return type.conforms(to: .pdf) }
        return url.pathExtension.lowercased() == "pdf"
    }

    static func isImage(type: UTType?, url: URL) -> Bool {
        if let type { return type.conforms(to: .image) }
        let ext = url.pathExtension.lowercased()
        return ["png","jpg","jpeg","tif","tiff","heic","gif","bmp"].contains(ext)
    }

    static func isTextLike(type: UTType?, url: URL) -> Bool {
        if let type {
            if type.conforms(to: .plainText) { return true }
            if type.conforms(to: .xml) { return true }
            if type.identifier == "public.json" { return true }
            if type.conforms(to: .text) { return true }
        }
        let ext = url.pathExtension.lowercased()
        return ["txt","md","rtf","json","xml","csv","log"].contains(ext)
    }

    static func derivedRootDirectory() throws -> URL {
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

    /// Recursively expands directories and ZIPs into a flat list of file URLs.
    /// ZIP extraction uses `/usr/bin/unzip` for now (simple, reliable on macOS).
    static func expandInputURLs(_ urls: [URL]) async throws -> [URL] {
        var out: [URL] = []

        func addFile(_ file: URL) {
            // Skip hidden files and package internals.
            if file.lastPathComponent.hasPrefix(".") { return }
            out.append(file)
        }

        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let fm = FileManager.default
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    while let item = enumerator.nextObject() as? URL {
                        let isItemDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        if !isItemDir {
                            // ZIP handling
                            if item.pathExtension.lowercased() == "zip" {
                                let extracted = try await unzipToTempAndListFiles(zipURL: item)
                                out.append(contentsOf: extracted)
                            } else {
                                addFile(item)
                            }
                        }
                    }
                }
            } else {
                if url.pathExtension.lowercased() == "zip" {
                    let extracted = try await unzipToTempAndListFiles(zipURL: url)
                    out.append(contentsOf: extracted)
                } else {
                    addFile(url)
                }
            }
        }

        // De-dupe identical paths.
        let unique = Array(Set(out.map { $0.standardizedFileURL.path })).sorted()
        return unique.map { URL(fileURLWithPath: $0) }
    }

    static func unzipToTempAndListFiles(zipURL: URL) async throws -> [URL] {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("RedactionResearchApp-Unzipped", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        // /usr/bin/unzip -qq <zip> -d <dest>
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-qq", zipURL.path, "-d", tempRoot.path]
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume(returning: ())
                } else {
                    cont.resume(throwing: NSError(domain: "IndexingService", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "unzip failed (status \(proc.terminationStatus)) for \(zipURL.lastPathComponent)"]))
                }
            }
            do {
                try p.run()
            } catch {
                cont.resume(throwing: error)
            }
        }

        var extracted: [URL] = []
        if let enumerator = fm.enumerator(at: tempRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            while let item = enumerator.nextObject() as? URL {
                let isItemDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !isItemDir {
                    extracted.append(item)
                }
            }
        }
        return extracted
    }

    /// SHA-256 without loading the whole file into memory.
    static func sha256Streaming(for url: URL, chunkSize: Int = 1024 * 1024) throws -> (hex: String, byteCount: UInt64) {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        var hasher = SHA256()
        var total: UInt64 = 0

        while true {
            autoreleasepool {
                // noop; keep memory tidy when hashing huge files
            }
            let data = try fh.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            total += UInt64(data.count)
            hasher.update(data: data)
        }

        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (hex, total)
    }

    static func extractText(from url: URL, type: UTType?) throws -> String? {
        // Safety: cap read to avoid huge memory use.
        let maxBytes = 2_000_000
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let slice = data.prefix(maxBytes)
        // Try UTF-8 first; fall back to ISO Latin 1.
        if let s = String(data: slice, encoding: .utf8) { return s }
        if let s = String(data: slice, encoding: .isoLatin1) { return s }
        return nil
    }

    #if canImport(PDFKit)
    static func extractPDFText(url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        return doc.string
    }

    #if canImport(AppKit)
    static func pdfThumbnail(url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = maxPixel / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let img = page.thumbnail(of: size, for: .mediaBox)
        return img
    }
    #endif
    #endif

    #if canImport(AppKit)
    static func thumbnail(from img: NSImage, maxPixel: CGFloat) -> NSImage? {
        let size = img.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = maxPixel / max(size.width, size.height)
        let target = CGSize(width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))

        let out = NSImage(size: target)
        out.lockFocus()
        defer { out.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: CGRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1.0)
        return out
    }

    static func writePNG(_ img: NSImage, to url: URL) throws {
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "IndexingService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
        }
        try data.write(to: url, options: [.atomic])
    }

    /// A simple 64-bit dHash (difference hash) over an 9x8 luminance grid.
    /// Returns a hex string.
    static func dHash(from img: NSImage) -> String? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let w = 9
        let h = 8
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: w * h)

        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var bits: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                let left = pixels[y * w + x]
                let right = pixels[y * w + x + 1]
                let bitIndex = y * (w - 1) + x
                if left > right {
                    bits |= (1 << UInt64(63 - bitIndex))
                }
            }
        }
        return String(format: "%016llx", bits)
    }
    #endif

    #if canImport(Vision) && canImport(AppKit)
    static func ocrText(from image: NSImage) async throws -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        return try await withCheckedThrowingContinuation { cont in
            let request = VNRecognizeTextRequest { req, err in
                if let err {
                    cont.resume(throwing: err)
                    return
                }
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let strings = observations.compactMap { $0.topCandidates(1).first?.string }
                let text = strings.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: text.isEmpty ? nil : text)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
    #endif

    static func writeJSON(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
    }
}
