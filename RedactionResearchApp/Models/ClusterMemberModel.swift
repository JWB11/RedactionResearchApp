import Foundation
import SwiftData

@Model
final class ClusterMemberModel {
    @Attribute(.unique) var id: UUID
    var caseID: UUID
    var similarityScore: Double?
    var isCanonical: Bool
    var createdAt: Date

    @Relationship(inverse: \ClusterModel.members)
    var cluster: ClusterModel?

    @Relationship(inverse: \DocumentModel.clusterMemberships)
    var document: DocumentModel?

    init(
        id: UUID = UUID(),
        caseID: UUID,
        similarityScore: Double? = nil,
        isCanonical: Bool = false,
        createdAt: Date = Date(),
        cluster: ClusterModel? = nil,
        document: DocumentModel? = nil
    ) {
        self.id = id
        self.caseID = caseID
        self.similarityScore = similarityScore
        self.isCanonical = isCanonical
        self.createdAt = createdAt
        self.cluster = cluster
        self.document = document
    }
}
