import Foundation
import SwiftData

@Model
final class CaseModel {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var caseFolderPath: String

    init(name: String, caseFolderPath: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.caseFolderPath = caseFolderPath
    }
}

extension CaseModel {
    static func appRootURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = appSupport.appendingPathComponent("RedactionResearchApp", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func derivedRootURL() throws -> URL {
        let root = try appRootURL()
        let derived = root.appendingPathComponent("Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        return derived
    }

    static func makeCaseFolderURL(caseName: String) throws -> URL {
        let casesRoot = try defaultCasesRootURL()
        let folderName = sanitizedFolderName(caseName)
        let url = casesRoot.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func defaultCasesRootURL() throws -> URL {
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = appSupport.appendingPathComponent("RedactionResearchApp", isDirectory: true)
        let cases = root.appendingPathComponent("Cases", isDirectory: true)
        try FileManager.default.createDirectory(at: cases, withIntermediateDirectories: true)
        return cases
    }

    static func sanitizedFolderName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Untitled Case" }
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: " -_"))
        let cleanedScalars = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleaned = String(cleanedScalars)
        // Collapse repeated underscores
        return cleaned.replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
    }
}
