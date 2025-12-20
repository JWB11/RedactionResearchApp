import Foundation
import PDFKit

enum PDFTextExtractor {
    static func extractText(from url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        return doc.string ?? ""
    }
}
