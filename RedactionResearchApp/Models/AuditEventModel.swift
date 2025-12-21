import Foundation
import SwiftData

@Model
final class AuditEventModel {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var level: String
    var stage: String
    var message: String
    var filePath: String?
    var sha256: String?
    var derivedFolderPath: String?
    var artifactPath: String?
    var thumbnailPath: String?
    var durationMs: Double?
    var metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: String,
        stage: String,
        message: String,
        filePath: String? = nil,
        sha256: String? = nil,
        derivedFolderPath: String? = nil,
        artifactPath: String? = nil,
        thumbnailPath: String? = nil,
        durationMs: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.stage = stage
        self.message = message
        self.filePath = filePath
        self.sha256 = sha256
        self.derivedFolderPath = derivedFolderPath
        self.artifactPath = artifactPath
        self.thumbnailPath = thumbnailPath
        self.durationMs = durationMs
        self.metadata = metadata
    }
}
