import Foundation
import SwiftData

enum RedactionResearchSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] = [CaseModel.self, DocumentModel.self]

    @Model
    final class CaseModel {
        @Attribute(.unique) var id: UUID
        var name: String
        var createdAt: Date
        var caseFolderPath: String

        init(id: UUID = UUID(), name: String, createdAt: Date = Date(), caseFolderPath: String) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.caseFolderPath = caseFolderPath
        }
    }

    @Model
    final class DocumentModel {
        @Attribute(.unique) var id: UUID

        // Case ownership
        var caseID: UUID

        var fileName: String
        var localPath: String
        var uti: String?

        // Exact-duplicate identity
        var sha256: String?

        // Derived artifacts written by IndexingService
        var derivedFolderPath: String?
        var extractedTextPath: String?
        var ocrTextPath: String?
        var thumbnailPath: String?
        var dHash: String?

        // Bookkeeping
        var createdAt: Date
        var lastIndexedAt: Date?

        init(
            id: UUID = UUID(),
            fileName: String,
            localPath: String,
            uti: String? = nil,
            caseID: UUID,
            sha256: String? = nil,
            derivedFolderPath: String? = nil,
            extractedTextPath: String? = nil,
            ocrTextPath: String? = nil,
            thumbnailPath: String? = nil,
            dHash: String? = nil,
            createdAt: Date = Date(),
            lastIndexedAt: Date? = nil
        ) {
            self.id = id
            self.caseID = caseID
            self.fileName = fileName
            self.localPath = localPath
            self.uti = uti
            self.sha256 = sha256
            self.derivedFolderPath = derivedFolderPath
            self.extractedTextPath = extractedTextPath
            self.ocrTextPath = ocrTextPath
            self.thumbnailPath = thumbnailPath
            self.dHash = dHash
            self.createdAt = createdAt
            self.lastIndexedAt = lastIndexedAt
        }
    }
}

enum RedactionResearchSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] = [
        CaseModel.self,
        DocumentModel.self,
        ClusterModel.self,
        ClusterMemberModel.self,
        ReconstructionSuggestionModel.self,
        AuditEventModel.self
    ]
}

enum RedactionResearchMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = [
        RedactionResearchSchemaV1.self,
        RedactionResearchSchemaV2.self
    ]

    static var migrations: [any Migration.Type] = [IndexingMigration.self]

    static var stages: [MigrationStage] { migrations.map { .heavyweight($0) } }
}

struct IndexingMigration: Migration {
    static func migrate(
        _ context: MigrationContext,
        from oldSchema: RedactionResearchSchemaV1.Type,
        to newSchema: RedactionResearchSchemaV2.Type
    ) throws {
        let oldCases = try context.fetch(FetchDescriptor<oldSchema.CaseModel>())
        for oldCase in oldCases {
            _ = newSchema.CaseModel(
                id: oldCase.id,
                name: oldCase.name,
                createdAt: oldCase.createdAt,
                caseFolderPath: oldCase.caseFolderPath
            )
        }

        let oldDocs = try context.fetch(FetchDescriptor<oldSchema.DocumentModel>())
        for oldDoc in oldDocs {
            _ = newSchema.DocumentModel(
                id: oldDoc.id,
                fileName: oldDoc.fileName,
                localPath: oldDoc.localPath,
                uti: oldDoc.uti,
                caseID: oldDoc.caseID,
                sha256: oldDoc.sha256,
                derivedFolderPath: oldDoc.derivedFolderPath,
                extractedTextPath: oldDoc.extractedTextPath,
                ocrTextPath: oldDoc.ocrTextPath,
                thumbnailPath: oldDoc.thumbnailPath,
                dHash: oldDoc.dHash,
                indexingVersion: DocumentModel.currentIndexingVersion,
                createdAt: oldDoc.createdAt,
                lastIndexedAt: oldDoc.lastIndexedAt
            )
        }
    }
}
