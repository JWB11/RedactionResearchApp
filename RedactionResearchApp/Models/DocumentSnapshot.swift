import Foundation
import SwiftData

/// Sendable value snapshot of a SwiftData DocumentModel.
/// Use this for analysis work to avoid sending @Model reference types across concurrency domains.
struct DocumentSnapshot: Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let localPath: String
    let sha256: String?
    let dHash: String?
    let extractedTextPath: String?
    let ocrTextPath: String?
}
