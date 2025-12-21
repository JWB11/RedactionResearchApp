import Foundation
import SwiftData

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
    var indexingVersion: Int

    // Bookkeeping
    var createdAt: Date
    var lastIndexedAt: Date?

    init(fileName: String, localPath: String, uti: String? = nil, caseID: UUID) {
        self.id = UUID()
        self.caseID = caseID
        self.fileName = fileName
        self.localPath = localPath
        self.uti = uti

        self.sha256 = nil
        self.derivedFolderPath = nil
        self.extractedTextPath = nil
        self.ocrTextPath = nil
        self.thumbnailPath = nil
        self.dHash = nil
        self.indexingVersion = 0

        self.createdAt = Date()
        self.lastIndexedAt = nil
    }
}
