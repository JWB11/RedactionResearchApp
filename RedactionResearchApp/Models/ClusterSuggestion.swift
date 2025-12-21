import Foundation

struct ClusterSuggestion: Identifiable, Codable, Hashable {
    let id: UUID
    let mergedText: String
    let basisFile: String
    let evidence: [SuggestionEvidence]
    let createdAt: Date

    init(id: UUID = UUID(), mergedText: String, basisFile: String, evidence: [SuggestionEvidence], createdAt: Date = Date()) {
        self.id = id
        self.mergedText = mergedText
        self.basisFile = basisFile
        self.evidence = evidence
        self.createdAt = createdAt
    }
}

struct SuggestionEvidence: Identifiable, Codable, Hashable {
    let id: UUID
    let sourceFile: String
    let page: Int?
    let line: Int?
    let rangeStart: Int?
    let rangeLength: Int?

    init(id: UUID = UUID(), sourceFile: String, page: Int? = nil, line: Int? = nil, rangeStart: Int? = nil, rangeLength: Int? = nil) {
        self.id = id
        self.sourceFile = sourceFile
        self.page = page
        self.line = line
        self.rangeStart = rangeStart
        self.rangeLength = rangeLength
    }
}
