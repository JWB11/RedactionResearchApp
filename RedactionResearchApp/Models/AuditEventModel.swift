import Foundation
import SwiftData

@Model
final class AuditEventModel {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var levelRaw: String
    var stage: String
    var message: String
    var filePath: String?
    var sha256: String?
    var derivedFolderPath: String?
    var artifactPath: String?
    var thumbnailPath: String?
    var durationMs: Double?
    var metadata: [String: String]
    var aiMetadata: [String: String]

    var derivedPath: String? {
        get { derivedFolderPath }
        set { derivedFolderPath = newValue }
    }

    var level: TraceEvent.Level {
        get { TraceEvent.Level(rawValue: levelRaw) ?? .info }
        set { levelRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        level: TraceEvent.Level,
        stage: String,
        message: String,
        filePath: String? = nil,
        sha256: String? = nil,
        derivedFolderPath: String? = nil,
        artifactPath: String? = nil,
        thumbnailPath: String? = nil,
        durationMs: Double? = nil,
        metadata: [String: String] = [:],
        aiMetadata: [String: String] = [:]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.levelRaw = level.rawValue
        self.stage = stage
        self.message = message
        self.filePath = filePath
        self.sha256 = sha256
        self.derivedFolderPath = derivedFolderPath
        self.artifactPath = artifactPath
        self.thumbnailPath = thumbnailPath
        self.durationMs = durationMs
        self.metadata = metadata
        self.aiMetadata = aiMetadata
    }

    convenience init(event: TraceEvent) {
        self.init(
            id: event.id,
            createdAt: event.timestamp,
            level: event.level,
            stage: event.stage,
            message: event.message,
            filePath: event.filePath,
            sha256: event.sha256,
            derivedFolderPath: event.derivedFolderPath,
            artifactPath: event.artifactPath,
            thumbnailPath: event.thumbnailPath,
            durationMs: event.durationMs,
            metadata: event.metadata,
            aiMetadata: event.aiMetadata
        )
    }
}
