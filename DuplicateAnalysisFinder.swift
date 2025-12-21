import Foundation
import SwiftData

/// Sendable value snapshot of a SwiftData DocumentModel.
/// Use this for analysis work to avoid sending @Model reference types across concurrency domains.
struct DocumentSnapshot: Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let localPath: String
    let sha256: String?
    let dHash: String?
    let extractedTextPath: String?
    let ocrTextPath: String?
}

/// Computes exact-duplicate (SHA-256) clusters and near-duplicate (dHash) clusters.
///
/// Notes:
/// - Exact duplicates are grouped by `DocumentSnapshot.sha256`.
/// - Near duplicates are grouped by 64-bit dHash Hamming distance (hex-encoded in `DocumentSnapshot.dHash`).
/// - "Best candidate" is a simple heuristic: prefer higher extracted/OCR text length, then larger byte size.
actor DuplicateAnalysisService {

    enum ClusterKind: String, Sendable {
        case exactSHA256
        case nearDHash
    }

    struct ClusterMember: Identifiable, Sendable {
        let id: UUID
        let fileName: String
        let localPath: String
        let sha256: String?
        let dHashHex: String?

        let extractedTextChars: Int
        let ocrTextChars: Int
        let byteSize: Int64

        /// Higher is "more complete".
        let completenessScore: Int

        /// Marked true for the top-ranked member within a cluster.
        let isBestCandidate: Bool
    }

    struct DuplicateCluster: Identifiable, Sendable {
        let id: UUID
        let kind: ClusterKind
        let title: String
        let members: [ClusterMember]

        /// A short human explanation for UI.
        let rationale: String
    }

    /// Main entrypoint.
    /// - Parameters:
    ///   - documents: Sendable document snapshots.
    ///   - nearThreshold: Max Hamming distance between 64-bit dHashes to be considered "near".
    func analyze(documents: [DocumentSnapshot], nearThreshold: Int = 10) async -> [DuplicateCluster] {
        let exactClusters = await exactDuplicateClusters(documents: documents)
        let nearClusters = await nearDuplicateClusters(documents: documents, threshold: nearThreshold)
        return exactClusters + nearClusters
    }

    // MARK: - Exact duplicates (SHA-256)

    private func exactDuplicateClusters(documents: [DocumentSnapshot]) async -> [DuplicateCluster] {
        var buckets: [String: [DocumentSnapshot]] = [:]
        for d in documents {
            guard let sha = d.sha256, !sha.isEmpty else { continue }
            buckets[sha, default: []].append(d)
        }

        var clusters: [DuplicateCluster] = []
        for (_, docs) in buckets {
            guard docs.count > 1 else { continue }

            let members = await buildMembers(for: docs)
            let bestName = members.first(where: { $0.isBestCandidate })?.fileName ?? ""

            clusters.append(
                DuplicateCluster(
                    id: UUID(),
                    kind: .exactSHA256,
                    title: "Exact duplicates (SHA) — \(docs.count) files",
                    members: members,
                    rationale: bestName.isEmpty
                        ? "All files have identical SHA-256 content."
                        : "All files have identical SHA-256 content. Best candidate: \(bestName)"
                )
            )
        }

        clusters.sort { $0.members.count > $1.members.count }
        return clusters
    }

    // MARK: - Near duplicates (dHash)

    private func nearDuplicateClusters(documents: [DocumentSnapshot], threshold: Int) async -> [DuplicateCluster] {
        var items: [(doc: DocumentSnapshot, bits: UInt64)] = []
        items.reserveCapacity(documents.count)

        for d in documents {
            guard let hex = d.dHash?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else { continue }
            if let bits = UInt64(hex, radix: 16) {
                items.append((d, bits))
            }
        }

        guard items.count >= 2 else { return [] }

        var parent = Array(0..<items.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        // Bucketing to avoid O(n^2): group by multiple 16-bit slices.
        // Using several buckets greatly improves recall vs a single prefix bucket.
        // We still compare only within buckets (approximate), but with far fewer misses.
        let sliceBits: UInt64 = 16
        let mask: UInt64 = (1 << sliceBits) - 1

        // key = (sliceIndex<<16) | sliceValue
        var buckets: [UInt64: [Int]] = [:]
        buckets.reserveCapacity(min(items.count * 3, 8192))

        @inline(__always)
        func bucketKey(_ sliceIndex: UInt64, _ value: UInt64) -> UInt64 {
            (sliceIndex << sliceBits) | (value & mask)
        }

        for idx in 0..<items.count {
            let bits = items[idx].bits
            let top = (bits >> 48) & mask
            let mid = (bits >> 24) & mask
            let low = bits & mask

            buckets[bucketKey(0, top), default: []].append(idx)
            buckets[bucketKey(1, mid), default: []].append(idx)
            buckets[bucketKey(2, low), default: []].append(idx)
        }

        // Compare within each bucket; avoid repeated work by tracking visited pairs.
        // For corpora of typical size, this is fast and dramatically increases recall.
        var seenPairs = Set<UInt64>()
        seenPairs.reserveCapacity(min(1_000_000, items.count * 64))

        @inline(__always)
        func pairKey(_ a: Int, _ b: Int) -> UInt64 {
            let x = UInt64(min(a, b))
            let y = UInt64(max(a, b))
            return (x << 32) ^ y
        }

        for (_, indices) in buckets {
            guard indices.count >= 2 else { continue }
            for a in 0..<indices.count {
                let i = indices[a]
                for b in (a + 1)..<indices.count {
                    let j = indices[b]
                    let pk = pairKey(i, j)
                    if seenPairs.contains(pk) { continue }
                    seenPairs.insert(pk)

                    let dist = Self.hammingDistance64(items[i].bits, items[j].bits)
                    if dist <= threshold {
                        union(i, j)
                    }
                }
            }
        }

        var groups: [Int: [DocumentSnapshot]] = [:]
        for i in 0..<items.count {
            let root = find(i)
            groups[root, default: []].append(items[i].doc)
        }

        var clusters: [DuplicateCluster] = []
        for (_, docs) in groups {
            guard docs.count > 1 else { continue }

            let members = await buildMembers(for: docs)
            let bestName = members.first(where: { $0.isBestCandidate })?.fileName ?? ""

            clusters.append(
                DuplicateCluster(
                    id: UUID(),
                    kind: .nearDHash,
                    title: "Near duplicates (dHash ≤ \(threshold)) — \(docs.count) files",
                    members: members,
                    rationale: bestName.isEmpty
                        ? "Files appear visually similar (thumbnail hash)."
                        : "Files appear visually similar (thumbnail hash). Best candidate: \(bestName)"
                )
            )
        }

        clusters.sort { $0.members.count > $1.members.count }
        return clusters
    }

    // MARK: - Member building + scoring

    func buildMembers(for docs: [DocumentSnapshot]) async -> [ClusterMember] {
        // Cache text counts per path to avoid rereading the same derived artifacts.
        actor TextCountCache {
            private var map: [String: Int] = [:]
            func count(for path: String?) -> Int {
                guard let path, !path.isEmpty else { return 0 }
                if let v = map[path] { return v }
                let v = DuplicateAnalysisService.countTextChars(path: path)
                map[path] = v
                return v
            }
        }
        let textCountCache = TextCountCache()

        // Precompute (exChars, ocrChars, byteSize) concurrently.
        struct Pre: Sendable {
            let id: UUID
            let fileName: String
            let localPath: String
            let sha256: String?
            let dHash: String?
            let exChars: Int
            let ocrChars: Int
            let byteSize: Int64
        }

        var pres: [Pre] = []
        pres.reserveCapacity(docs.count)

        // Bounded parallelism for file I/O: process in chunks.
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let maxConcurrency = min(12, max(2, cores))
        let chunkSize = max(1, (docs.count + maxConcurrency - 1) / maxConcurrency)

        let chunks: [[DocumentSnapshot]] = stride(from: 0, to: docs.count, by: chunkSize).map {
            Array(docs[$0..<min($0 + chunkSize, docs.count)])
        }

        await withTaskGroup(of: [Pre].self) { group in
            for chunk in chunks {
                group.addTask {
                    var local: [Pre] = []
                    local.reserveCapacity(chunk.count)

                    for d in chunk {
                        let ex = await textCountCache.count(for: d.extractedTextPath)
                        let ocr = await textCountCache.count(for: d.ocrTextPath)
                        let size = Self.fileByteSize(path: d.localPath)

                        local.append(
                            Pre(
                                id: d.id,
                                fileName: d.fileName,
                                localPath: d.localPath,
                                sha256: d.sha256,
                                dHash: d.dHash,
                                exChars: ex,
                                ocrChars: ocr,
                                byteSize: size
                            )
                        )
                    }

                    return local
                }
            }

            for await arr in group {
                pres.append(contentsOf: arr)
            }
        }

        var raw: [ClusterMember] = []
        raw.reserveCapacity(pres.count)

        for p in pres {
            // Prefer extracted text (usually higher quality), then OCR, then file size as a tiebreaker.
            let textScore = (p.exChars * 2) + p.ocrChars
            let sizeScore = Int(min(max(p.byteSize / 1024, 0), 50_000))
            let score = textScore + sizeScore

            raw.append(
                ClusterMember(
                    id: p.id,
                    fileName: p.fileName,
                    localPath: p.localPath,
                    sha256: p.sha256,
                    dHashHex: p.dHash,
                    extractedTextChars: p.exChars,
                    ocrTextChars: p.ocrChars,
                    byteSize: p.byteSize,
                    completenessScore: score,
                    isBestCandidate: false
                )
            )
        }

        raw.sort {
            if $0.completenessScore != $1.completenessScore { return $0.completenessScore > $1.completenessScore }
            if $0.byteSize != $1.byteSize { return $0.byteSize > $1.byteSize }
            return $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending
        }

        if let first = raw.first {
            raw[0] = ClusterMember(
                id: first.id,
                fileName: first.fileName,
                localPath: first.localPath,
                sha256: first.sha256,
                dHashHex: first.dHashHex,
                extractedTextChars: first.extractedTextChars,
                ocrTextChars: first.ocrTextChars,
                byteSize: first.byteSize,
                completenessScore: first.completenessScore,
                isBestCandidate: true
            )
        }

        return raw
    }

    // MARK: - Utilities

    static func hammingDistance64(_ a: UInt64, _ b: UInt64) -> Int {
        Int((a ^ b).nonzeroBitCount)
    }

    static func fileByteSize(path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize { return Int64(size) }
        return 0
    }

    static func countTextChars(path: String) -> Int {
        let url = URL(fileURLWithPath: path)
        guard let fh = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? fh.close() }

        let maxBytes = 1_000_000
        let data = (try? fh.read(upToCount: maxBytes)) ?? Data()
        if data.isEmpty { return 0 }
        if let s = String(data: data, encoding: .utf8) { return s.count }
        if let s = String(data: data, encoding: .isoLatin1) { return s.count }
        return 0
    }

    static func textCharCounts(extractedPath: String?, ocrPath: String?) async -> (Int, Int) {
        return (extractedPath.map { countTextChars(path: $0) } ?? 0,
                ocrPath.map { countTextChars(path: $0) } ?? 0)
    }
}

// MARK: - Convenience for UI

extension DuplicateAnalysisService {
    static func summaryLine(for cluster: DuplicateCluster) -> String {
        let best = cluster.members.first(where: { $0.isBestCandidate })?.fileName
        if let best, !best.isEmpty {
            return "\(cluster.title) • best: \(best)"
        }
        return cluster.title
    }
}
