import Foundation
import SwiftData

@Model
final class ReconstructionSuggestionModel {
    @Attribute(.unique) var id: UUID
    var caseID: UUID
    var createdAt: Date
    var summary: String?

    @Relationship(inverse: \DocumentModel.reconstructionSuggestions)
    var document: DocumentModel?

    @Relationship(inverse: \ClusterModel.reconstructionSuggestions)
    var cluster: ClusterModel?

    init(id: UUID = UUID(), caseID: UUID, createdAt: Date = Date(), summary: String? = nil, document: DocumentModel? = nil, cluster: ClusterModel? = nil) {
        self.id = id
        self.caseID = caseID
        self.createdAt = createdAt
        self.summary = summary
        self.document = document
        self.cluster = cluster
    }
}
