import Foundation

/// Lightweight value type for logging and displaying execution trace entries.
struct TraceEvent: Identifiable, Hashable, Codable {
    enum Level: String, CaseIterable, Codable {
        case info
        case warning
        case error
    }

    var id: UUID = UUID()
    var timestamp: Date = Date()
    var level: Level = .info
    var stage: String
    var message: String
    var filePath: String? = nil
    var sha256: String? = nil
    var derivedFolderPath: String? = nil
    var artifactPath: String? = nil
    var thumbnailPath: String? = nil
    var durationMs: Double? = nil
    var metadata: [String: String] = [:]
    var aiMetadata: [String: String] = [:]

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

    init(model: AuditEventModel) {
        self.id = model.id
        self.timestamp = model.createdAt
        self.level = model.level
        self.stage = model.stage
        self.message = model.message
        self.filePath = model.filePath
        self.sha256 = model.sha256
        self.derivedFolderPath = model.derivedFolderPath
        self.artifactPath = model.artifactPath
        self.thumbnailPath = model.thumbnailPath
        self.durationMs = model.durationMs
        self.metadata = model.metadata
        self.aiMetadata = model.aiMetadata
    }

    func asModel() -> AuditEventModel {
        AuditEventModel(event: self)
    }
}
