import Foundation

enum ZipUtils {
    // TODO: Implement ZIP extraction.
    // Suggestion: use Apple's Compression framework or a small Swift ZIP library,
    // then extract into a temp folder before importing into the case folder.
    static func isZip(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip"
    }
}
