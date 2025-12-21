import Foundation
import SwiftData

@Model
final class ClusterModel {
    @Attribute(.unique) var id: UUID
    var caseID: UUID
    var representativeDocumentID: UUID?
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ClusterMemberModel.cluster)
    var members: [ClusterMemberModel] = []

    @Relationship(deleteRule: .cascade, inverse: \ReconstructionSuggestionModel.cluster)
    var reconstructionSuggestions: [ReconstructionSuggestionModel] = []

    @Relationship(deleteRule: .cascade, inverse: \AuditEventModel.cluster)
    var auditEvents: [AuditEventModel] = []

    init(id: UUID = UUID(), caseID: UUID, representativeDocumentID: UUID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.caseID = caseID
        self.representativeDocumentID = representativeDocumentID
        self.createdAt = createdAt
    }
}
