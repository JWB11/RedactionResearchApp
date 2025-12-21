import Foundation
import SwiftData

struct TraceEvent: Identifiable, Sendable, Hashable {
    enum Level: String, CaseIterable, Codable, Sendable {
        case debug
        case info
        case warning
        case error
    }

    let id: UUID
    let timestamp: Date
    let level: Level
    let stage: String
    let message: String
    let filePath: String?
    let sha256: String?
    let derivedPath: String?
    let thumbnailPath: String?
    let metadata: [String: String]
    let aiMetadata: [String: String]

    init(
        level: Level = .info,
        stage: String,
        message: String,
        filePath: String? = nil,
        sha256: String? = nil,
        derivedPath: String? = nil,
        thumbnailPath: String? = nil,
        metadata: [String: String] = [:],
        aiMetadata: [String: String] = [:],
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.stage = stage
        self.message = message
        self.filePath = filePath
        self.sha256 = sha256
        self.derivedPath = derivedPath
        self.thumbnailPath = thumbnailPath
        self.metadata = metadata
        self.aiMetadata = aiMetadata
    }
}

@Model
final class AuditEventModel {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var levelRaw: String
    var stage: String
    var message: String
    var filePath: String?
    var sha256: String?
    var derivedPath: String?
    var thumbnailPath: String?
    var metadata: [String: String]
    var aiMetadata: [String: String]

    init(_ event: TraceEvent) {
        self.id = event.id
        self.createdAt = event.timestamp
        self.levelRaw = event.level.rawValue
        self.stage = event.stage
        self.message = event.message
        self.filePath = event.filePath
        self.sha256 = event.sha256
        self.derivedPath = event.derivedPath
        self.thumbnailPath = event.thumbnailPath
        self.metadata = event.metadata
        self.aiMetadata = event.aiMetadata
    }
}

extension AuditEventModel {
    var level: TraceEvent.Level { TraceEvent.Level(rawValue: levelRaw) ?? .info }

    var asTraceEvent: TraceEvent {
        TraceEvent(
            level: level,
            stage: stage,
            message: message,
            filePath: filePath,
            sha256: sha256,
            derivedPath: derivedPath,
            thumbnailPath: thumbnailPath,
            metadata: metadata,
            aiMetadata: aiMetadata,
            id: id,
            timestamp: createdAt
        )
    }
}
