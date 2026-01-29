import SwiftUI
import AppKit

struct ProgressScratchpadView: View {
    @ObservedObject var processing: ProcessingStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Analysis")
                    .font(.headline)
                Spacer()
                Text("\(Int(processing.progress * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: processing.progress)

            // Live preview of the current file being processed.
            // Prefer the generated thumbnail (if available) so the preview updates as soon as the pipeline writes it.
            if let path = processing.currentFilePath {
                FilePreview(
                    path: path,
                    thumbnailPath: processing.currentThumbnailPath,
                    extractedChars: processing.currentExtractedTextChars,
                    ocrChars: processing.currentOCRTextChars
                )
            }

            GroupBox("Scratchpad") {
                Text(processing.status)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - File Preview

private struct FilePreview: View {
    let path: String
    let thumbnailPath: String?
    let extractedChars: Int?
    let ocrChars: Int?

    var body: some View {
        GroupBox("Currently Analyzing") {
            VStack(alignment: .leading, spacing: 8) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    if let extractedChars {
                        Text("Extracted: \(extractedChars)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let ocrChars {
                        Text("OCR: \(ocrChars)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let thumbPath = thumbnailPath, let thumb = loadImage(path: thumbPath) {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if let image = loadImage(path: path) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if let snippet = loadTextSnippet(path: path) {
                    Text(snippet)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                        Text("Preview unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadImage(path: String) -> NSImage? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "tiff", "heic", "gif", "bmp"].contains(ext) else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private func loadTextSnippet(path: String) -> String? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard ["txt", "json", "xml", "csv", "md"].contains(ext) else { return nil }
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: 2048)) ?? Data()
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
