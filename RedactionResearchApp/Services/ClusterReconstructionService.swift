import Foundation
import SwiftData

final class ClusterReconstructionService {

    func reconstruct(
        clusters: [DuplicateAnalysisService.DuplicateCluster],
        documents: [DocumentSnapshot],
        caseID: UUID,
        modelContext: ModelContext
    ) async -> [UUID: [ClusterSuggestion]] {
        let docMap = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        var result: [UUID: [ClusterSuggestion]] = [:]

        for cluster in clusters {
            let membersWithText: [(DuplicateAnalysisService.ClusterMember, String)] = cluster.members.compactMap { member in
                guard let snap = docMap[member.id], let text = readCombinedText(for: snap) else { return nil }
                return (member, text)
            }

            guard !membersWithText.isEmpty else { continue }

            let suggestion = alignText(cluster: cluster, members: membersWithText)
            result[cluster.id] = [suggestion]

            await persist(cluster: cluster, caseID: caseID, members: membersWithText, suggestions: [suggestion], modelContext: modelContext)
        }

        return result
    }

    private func readCombinedText(for snapshot: DocumentSnapshot) -> String? {
        let extracted = snapshot.extractedTextPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let ocr = snapshot.ocrTextPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let combined = (extracted + "\n" + ocr).trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? nil : combined
    }

    private func alignText(
        cluster: DuplicateAnalysisService.DuplicateCluster,
        members: [(DuplicateAnalysisService.ClusterMember, String)]
    ) -> ClusterSuggestion {
        let splitMembers: [(DuplicateAnalysisService.ClusterMember, [String])] = members.map { ($0.0, $0.1.components(separatedBy: "\n")) }
        let maxLines = splitMembers.map { $0.1.count }.max() ?? 0
        var merged: [String] = []
        var evidence: [SuggestionEvidence] = []

        for lineIndex in 0..<maxLines {
            let lineCandidates = splitMembers.compactMap { (member, lines) -> (DuplicateAnalysisService.ClusterMember, String)? in
                guard lineIndex < lines.count else { return nil }
                return (member, lines[lineIndex])
            }

            guard !lineCandidates.isEmpty else { continue }
            let bestLine = lineCandidates.max { lhs, rhs in
                lhs.1.count < rhs.1.count
            }

            if let bestLine {
                let trimmed = bestLine.1.trimmingCharacters(in: .whitespaces)
                merged.append(trimmed)
                let ev = SuggestionEvidence(
                    sourceFile: bestLine.0.fileName,
                    line: lineIndex + 1,
                    rangeStart: 0,
                    rangeLength: trimmed.count
                )
                evidence.append(ev)
            }
        }

        let mergedText = merged.joined(separator: "\n")
        let basisFile = members.first(where: { $0.0.isBestCandidate })?.0.fileName ?? cluster.members.first?.fileName ?? ""

        return ClusterSuggestion(
            mergedText: mergedText,
            basisFile: basisFile,
            evidence: evidence
        )
    }

    @MainActor
    private func persist(
        cluster: DuplicateAnalysisService.DuplicateCluster,
        caseID: UUID,
        members: [(DuplicateAnalysisService.ClusterMember, String)],
        suggestions: [ClusterSuggestion],
        modelContext: ModelContext
    ) {
        let fetch = FetchDescriptor<ClusterModel>(predicate: #Predicate { $0.clusterID == cluster.id })
        let existing = (try? modelContext.fetch(fetch))?.first

        let memberIDs = members.map { $0.0.id }
        let bestID = cluster.members.first(where: { $0.isBestCandidate })?.id

        let model: ClusterModel
        if let existing {
            model = existing
        } else {
            model = ClusterModel(
                clusterID: cluster.id,
                caseID: caseID,
                clusterKind: cluster.kind.rawValue,
                title: cluster.title,
                bestCandidateDocumentID: bestID,
                memberDocumentIDs: memberIDs
            )
            modelContext.insert(model)
        }

        model.title = cluster.title
        model.clusterKind = cluster.kind.rawValue
        model.bestCandidateDocumentID = bestID
        model.memberDocumentIDs = memberIDs
        model.suggestions = suggestions
    }
}
