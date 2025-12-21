import Foundation
import SwiftData

@Model
final class ClusterModel {
    @Attribute(.unique) var clusterID: UUID
    var caseID: UUID
    var clusterKind: String
    var title: String
    var bestCandidateDocumentID: UUID?
    var memberDocumentIDs: [UUID]
    var suggestionsData: Data?
    var updatedAt: Date

    init(clusterID: UUID, caseID: UUID, clusterKind: String, title: String, bestCandidateDocumentID: UUID?, memberDocumentIDs: [UUID]) {
        self.clusterID = clusterID
        self.caseID = caseID
        self.clusterKind = clusterKind
        self.title = title
        self.bestCandidateDocumentID = bestCandidateDocumentID
        self.memberDocumentIDs = memberDocumentIDs
        self.suggestionsData = nil
        self.updatedAt = Date()
    }
}

extension ClusterModel {
    var suggestions: [ClusterSuggestion] {
        get {
            guard let data = suggestionsData else { return [] }
            return (try? JSONDecoder().decode([ClusterSuggestion].self, from: data)) ?? []
        }
        set {
            suggestionsData = try? JSONEncoder().encode(newValue)
            updatedAt = Date()
        }
    }
}
