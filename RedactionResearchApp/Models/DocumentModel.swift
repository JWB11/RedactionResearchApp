import Foundation
import SwiftData

@Model
final class DocumentModel {
    static let currentIndexingVersion = 1

    @Attribute(.unique) var id: UUID

    // Case ownership
    var caseID: UUID

    var fileName: String
    var localPath: String
    var normalizedLocalPath: String?
    var uti: String?

    // Exact-duplicate identity
    var sha256: String?

    // Derived artifacts written by IndexingService
    var derivedFolderPath: String?
    var normalizedDerivedFolderPath: String?
    var extractedTextPath: String?
    var normalizedExtractedTextPath: String?
    var ocrTextPath: String?
    var normalizedOCRTextPath: String?
    var thumbnailPath: String?
    var normalizedThumbnailPath: String?
    var dHash: String?

    // Bookkeeping
    var indexingVersion: Int
    var createdAt: Date
    var lastIndexedAt: Date?

    // Relationships
    @Relationship(deleteRule: .cascade, inverse: \ClusterMemberModel.document)
    var clusterMemberships: [ClusterMemberModel] = []

    @Relationship(deleteRule: .cascade, inverse: \ReconstructionSuggestionModel.document)
    var reconstructionSuggestions: [ReconstructionSuggestionModel] = []

    @Relationship(deleteRule: .nullify, inverse: \AuditEventModel.document)
    var auditEvents: [AuditEventModel] = []

    init(
        id: UUID = UUID(),
        fileName: String,
        localPath: String,
        normalizedLocalPath: String? = nil,
        uti: String? = nil,
        caseID: UUID,
        sha256: String? = nil,
        derivedFolderPath: String? = nil,
        normalizedDerivedFolderPath: String? = nil,
        extractedTextPath: String? = nil,
        normalizedExtractedTextPath: String? = nil,
        ocrTextPath: String? = nil,
        normalizedOCRTextPath: String? = nil,
        thumbnailPath: String? = nil,
        normalizedThumbnailPath: String? = nil,
        dHash: String? = nil,
        indexingVersion: Int = DocumentModel.currentIndexingVersion,
        createdAt: Date = Date(),
        lastIndexedAt: Date? = nil
    ) {
        self.id = id
        self.caseID = caseID
        self.fileName = fileName
        self.localPath = localPath
        self.normalizedLocalPath = normalizedLocalPath ?? DocumentModel.normalizePath(localPath)
        self.uti = uti

        self.sha256 = sha256
        self.derivedFolderPath = derivedFolderPath
        self.normalizedDerivedFolderPath = normalizedDerivedFolderPath ?? DocumentModel.normalizePath(derivedFolderPath)
        self.extractedTextPath = extractedTextPath
        self.normalizedExtractedTextPath = normalizedExtractedTextPath ?? DocumentModel.normalizePath(extractedTextPath)
        self.ocrTextPath = ocrTextPath
        self.normalizedOCRTextPath = normalizedOCRTextPath ?? DocumentModel.normalizePath(ocrTextPath)
        self.thumbnailPath = thumbnailPath
        self.normalizedThumbnailPath = normalizedThumbnailPath ?? DocumentModel.normalizePath(thumbnailPath)
        self.dHash = dHash

        self.indexingVersion = indexingVersion
        self.createdAt = createdAt
        self.lastIndexedAt = lastIndexedAt
    }
}

extension DocumentModel {
    static func normalizePath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
