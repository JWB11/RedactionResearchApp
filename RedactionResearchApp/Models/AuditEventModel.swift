import Foundation
import SwiftData

@Model
final class AuditEventModel {
    @Attribute(.unique) var id: UUID
    var caseID: UUID
    var createdAt: Date
    var eventType: String
    var message: String?
    var indexingVersion: Int

    @Relationship(inverse: \DocumentModel.auditEvents)
    var document: DocumentModel?

    @Relationship(inverse: \ClusterModel.auditEvents)
    var cluster: ClusterModel?

    init(
        id: UUID = UUID(),
        caseID: UUID,
        createdAt: Date = Date(),
        eventType: String,
        message: String? = nil,
        indexingVersion: Int = DocumentModel.currentIndexingVersion,
        document: DocumentModel? = nil,
        cluster: ClusterModel? = nil
    ) {
        self.id = id
        self.caseID = caseID
        self.createdAt = createdAt
        self.eventType = eventType
        self.message = message
        self.indexingVersion = indexingVersion
        self.document = document
        self.cluster = cluster
    }
}
