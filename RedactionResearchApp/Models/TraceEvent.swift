import Foundation
import SwiftData

/// A lightweight, in-memory representation of a trace/audit event.
/// Used for passing event data before persistence and for UI display.
struct TraceEvent: Identifiable {
    enum Level: String, CaseIterable, Codable {
        case debug
        case info
        case warning
        case error
    }

    var id: UUID
    var timestamp: Date
    var level: Level
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

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: Level = .info,
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
        self.aiMetadata = aiMetadata
    }

    /// Initialize from a persisted AuditEventModel
    init(model: AuditEventModel) {
        self.id = model.id
        self.timestamp = model.createdAt
        self.level = Level(rawValue: model.level) ?? .info
        self.stage = model.stage
        self.message = model.message
        self.filePath = model.filePath
        self.sha256 = model.sha256
        self.derivedFolderPath = model.derivedPath
        self.artifactPath = model.artifactPath
        self.thumbnailPath = model.thumbnailPath
        self.durationMs = model.durationMs
        self.metadata = model.metadata
        self.aiMetadata = model.aiMetadata
    }

    /// Convert to a persisted model for SwiftData storage
    func asModel() -> AuditEventModel {
        return AuditEventModel(
            id: id,
            timestamp: timestamp,
            level: level.rawValue,
            stage: stage,
            message: message,
            filePath: filePath,
            sha256: sha256,
            derivedPath: derivedFolderPath,
            artifactPath: artifactPath,
            thumbnailPath: thumbnailPath,
            durationMs: durationMs,
            metadata: metadata,
            aiMetadata: aiMetadata
        )
    }
}
