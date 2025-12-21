import Foundation
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

enum ZipUtils {
    static func isZip(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip"
    }

    /// Extracts a ZIP file to the specified destination directory.
    /// - Parameters:
    ///   - zipURL: The URL of the ZIP file to extract
    ///   - destinationURL: The directory where files should be extracted
    ///   - overwrite: Whether to overwrite existing files (default: false)
    /// - Returns: Array of URLs of extracted files
    /// - Throws: Errors during extraction
    static func extractZip(at zipURL: URL, to destinationURL: URL, overwrite: Bool = false) throws -> [URL] {
        #if canImport(ZIPFoundation)
        let fileManager = FileManager.default

        // Ensure destination directory exists
        if !fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        }

        // Extract the archive
        try fileManager.unzipItem(at: zipURL, to: destinationURL)

        // Get all extracted files
        let extractedFiles = try fileManager.contentsOfDirectory(
            at: destinationURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return extractedFiles
        #else
        // Fallback: Use system unzip command
        return try extractZipUsingSystemCommand(at: zipURL, to: destinationURL)
        #endif
    }

    /// Fallback method using system unzip command
    private static func extractZipUsingSystemCommand(at zipURL: URL, to destinationURL: URL) throws -> [URL] {
        let fileManager = FileManager.default

        // Ensure destination directory exists
        if !fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        }

        // Use system unzip command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", zipURL.path, "-d", destinationURL.path]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw ZipExtractionError.extractionFailed(errorMessage)
        }

        // Get all extracted files
        let extractedFiles = try fileManager.contentsOfDirectory(
            at: destinationURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return extractedFiles
    }

    enum ZipExtractionError: Error {
        case extractionFailed(String)
        case destinationNotDirectory
    }
}
