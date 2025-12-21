import Foundation
import SwiftData

@Model
final class AuditEventModel {
    @Attribute(.unique) var id: UUID
    var createdAt: Date  // Renamed from timestamp for consistency
    var level: String
    var stage: String
    var message: String
    var filePath: String?
    var sha256: String?
    var derivedPath: String?  // Renamed from derivedFolderPath for consistency
    var artifactPath: String?
    var thumbnailPath: String?
    var durationMs: Double?
    var metadata: [String: String]
    var aiMetadata: [String: String]  // Added missing property

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: String,
        stage: String,
        message: String,
        filePath: String? = nil,
        sha256: String? = nil,
        derivedPath: String? = nil,
        artifactPath: String? = nil,
        thumbnailPath: String? = nil,
        durationMs: Double? = nil,
        metadata: [String: String] = [:],
        aiMetadata: [String: String] = [:]
    ) {
        self.id = id
        self.createdAt = timestamp
        self.level = level
        self.stage = stage
        self.message = message
        self.filePath = filePath
        self.sha256 = sha256
        self.derivedPath = derivedPath
        self.artifactPath = artifactPath
        self.thumbnailPath = thumbnailPath
        self.durationMs = durationMs
        self.metadata = metadata
        self.aiMetadata = aiMetadata
    }

    /// Convenience initializer from TraceEvent
    convenience init(_ event: TraceEvent) {
        self.init(
            id: event.id,
            timestamp: event.timestamp,
            level: event.level.rawValue,
            stage: event.stage,
            message: event.message,
            filePath: event.filePath,
            sha256: event.sha256,
            derivedPath: event.derivedFolderPath,
            artifactPath: event.artifactPath,
            thumbnailPath: event.thumbnailPath,
            durationMs: event.durationMs,
            metadata: event.metadata,
            aiMetadata: event.aiMetadata
        )
    }
}
