import Foundation
import UniformTypeIdentifiers

actor FileImportService {
    enum ImportError: Error {
        case caseDirectoryUnavailable
    }

    func importItems(urls: [URL], intoCaseFolder caseFolder: URL) async throws -> [URL] {
        var copied: [URL] = []
        for url in urls {
            let type: UTType? = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                ?? UTType(filenameExtension: url.pathExtension)

            let dst: URL
            if let type {
                dst = caseFolder.appendingPathComponent(url.lastPathComponent, conformingTo: type)
            } else {
                dst = caseFolder.appendingPathComponent(url.lastPathComponent)
            }
            try FileManager.default.copyItem(at: url, to: dst)
            copied.append(dst)
        }
        return copied
    }
}
