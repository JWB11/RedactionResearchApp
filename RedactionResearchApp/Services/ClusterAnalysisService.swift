import Foundation

/// Merges exact duplicate, visual similarity, and text similarity signals into unified clusters.
actor ClusterAnalysisService {
    struct ClusterReason: Identifiable, Sendable {
        let id: UUID
        let label: String
        let detail: String
        let confidence: Double
    }

    struct SimilarityCluster: Identifiable, Sendable {
        let id: UUID
        let title: String
        let summary: String
        let confidence: Double
        let reasons: [ClusterReason]
        let bestCandidateID: UUID?
        let exactDuplicates: [DuplicateAnalysisService.ClusterMember]
        let variants: [DuplicateAnalysisService.ClusterMember]
    }

    private let duplicateAnalyzer = DuplicateAnalysisService()
    private let textAnalyzer = TextSimilarityService()

    func analyze(documents: [DocumentSnapshot], nearThreshold: Int = 10) async -> [SimilarityCluster] {
        async let duplicateClusters = duplicateAnalyzer.analyze(documents: documents, nearThreshold: nearThreshold)
        async let textClusters = textAnalyzer.analyze(documents: documents)

        var results: [SimilarityCluster] = []
        var membershipIndex: [UUID: Int] = [:]

        func assignMembership(_ members: [DuplicateAnalysisService.ClusterMember], clusterIndex: Int) {
            for m in members { membershipIndex[m.id] = clusterIndex }
        }

        func rebuildBestFlags(for cluster: SimilarityCluster) -> SimilarityCluster {
            guard let bestID = bestCandidateID(in: cluster.exactDuplicates + cluster.variants) else { return cluster }

            func rewrite(_ members: [DuplicateAnalysisService.ClusterMember]) -> [DuplicateAnalysisService.ClusterMember] {
                members.map {
                    DuplicateAnalysisService.ClusterMember(
                        id: $0.id,
                        fileName: $0.fileName,
                        localPath: $0.localPath,
                        sha256: $0.sha256,
                        dHashHex: $0.dHashHex,
                        extractedTextChars: $0.extractedTextChars,
                        ocrTextChars: $0.ocrTextChars,
                        byteSize: $0.byteSize,
                        completenessScore: $0.completenessScore,
                        isBestCandidate: $0.id == bestID
                    )
                }
            }

            let rewritten = SimilarityCluster(
                id: cluster.id,
                title: cluster.title,
                summary: cluster.summary,
                confidence: cluster.confidence,
                reasons: cluster.reasons,
                bestCandidateID: bestID,
                exactDuplicates: rewrite(cluster.exactDuplicates),
                variants: rewrite(cluster.variants)
            )
            return rewritten
        }

        // Seed clusters from exact and near-duplicate image hashing results.
        let duplicateResults = await duplicateClusters
        for dc in duplicateResults {
            let reasonLabel = dc.kind == .exactSHA256 ? "Exact content" : "Visual similarity"
            let confidence = dc.kind == .exactSHA256 ? 1.0 : 0.75
            let reason = ClusterReason(
                id: UUID(),
                label: reasonLabel,
                detail: dc.rationale,
                confidence: confidence
            )

            let exactMembers = dc.kind == .exactSHA256 ? dc.members : []
            let variantMembers = dc.kind == .nearDHash ? dc.members : []

            var cluster = SimilarityCluster(
                id: UUID(),
                title: dc.title,
                summary: dc.rationale,
                confidence: confidence,
                reasons: [reason],
                bestCandidateID: dc.members.first(where: { $0.isBestCandidate })?.id,
                exactDuplicates: exactMembers,
                variants: variantMembers
            )
            cluster = rebuildBestFlags(for: cluster)
            results.append(cluster)
            assignMembership(cluster.exactDuplicates + cluster.variants, clusterIndex: results.count - 1)
        }

        // Merge in text similarity clusters.
        let textResults = await textClusters
        for tc in textResults {
            let reason = ClusterReason(
                id: UUID(),
                label: "Text similarity",
                detail: tc.summary,
                confidence: tc.confidence
            )

            let members = await duplicateAnalyzer.buildMembers(for: tc.documents)
            let title = "Text-similar set — \(members.count) files"
            let summary = "Best textual overlap candidate highlighted. \(tc.summary)"

            // Check for overlap with existing clusters to merge signals.
            if let overlapIndex = members.compactMap({ membershipIndex[$0.id] }).first {
                var cluster = results[overlapIndex]
                cluster.reasons.append(reason)
                cluster.confidence = max(cluster.confidence, tc.confidence)

                // Merge members, avoiding duplicates.
                let existingIDs = Set((cluster.exactDuplicates + cluster.variants).map { $0.id })
                let newMembers = members.filter { !existingIDs.contains($0.id) }
                cluster.variants.append(contentsOf: newMembers)
                cluster.summary = mergeSummary(cluster.summary, with: tc.summary)
                cluster = rebuildBestFlags(for: cluster)
                results[overlapIndex] = cluster
                assignMembership(newMembers, clusterIndex: overlapIndex)
            } else {
                var cluster = SimilarityCluster(
                    id: UUID(),
                    title: title,
                    summary: summary,
                    confidence: tc.confidence,
                    reasons: [reason],
                    bestCandidateID: members.first(where: { $0.isBestCandidate })?.id,
                    exactDuplicates: [],
                    variants: members
                )
                cluster = rebuildBestFlags(for: cluster)
                results.append(cluster)
                assignMembership(cluster.variants, clusterIndex: results.count - 1)
            }
        }

        return results.sorted { lhs, rhs in
            let lCount = lhs.exactDuplicates.count + lhs.variants.count
            let rCount = rhs.exactDuplicates.count + rhs.variants.count
            if lCount != rCount { return lCount > rCount }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func bestCandidateID(in members: [DuplicateAnalysisService.ClusterMember]) -> UUID? {
        guard !members.isEmpty else { return nil }
        let sorted = members.sorted { lhs, rhs in
            if lhs.completenessScore != rhs.completenessScore { return lhs.completenessScore > rhs.completenessScore }
            if lhs.byteSize != rhs.byteSize { return lhs.byteSize > rhs.byteSize }
            return lhs.fileName.localizedCaseInsensitiveCompare(rhs.fileName) == .orderedAscending
        }
        return sorted.first?.id
    }

    private func mergeSummary(_ a: String, with b: String) -> String {
        if a.contains(b) { return a }
        if b.contains(a) { return b }
        return a + "\n" + b
    }
}
