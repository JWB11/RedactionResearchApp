import SwiftUI

struct CompareView: View {
    let leftDocument: DocumentModel?
    let rightDocument: DocumentModel?

    @State private var comparisonMode: ComparisonMode = .sideBySide
    @State private var leftText: String = ""
    @State private var rightText: String = ""
    @State private var differences: [TextDifference] = []

    enum ComparisonMode: String, CaseIterable {
        case sideBySide = "Side by Side"
        case overlay = "Overlay"
        case unified = "Unified Diff"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with mode selector
            HStack {
                Text("Compare Documents")
                    .font(.headline)

                Spacer()

                Picker("Mode", selection: $comparisonMode) {
                    ForEach(ComparisonMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
            }
            .padding()

            Divider()

            // Content area
            if leftDocument == nil && rightDocument == nil {
                ContentUnavailableView(
                    "No Documents Selected",
                    systemImage: "doc.on.doc",
                    description: Text("Select two documents to compare")
                )
            } else {
                switch comparisonMode {
                case .sideBySide:
                    sideBySideView
                case .overlay:
                    overlayView
                case .unified:
                    unifiedDiffView
                }
            }
        }
        .onAppear {
            loadDocumentTexts()
            computeDifferences()
        }
        .onChange(of: leftDocument) { _ in
            loadDocumentTexts()
            computeDifferences()
        }
        .onChange(of: rightDocument) { _ in
            loadDocumentTexts()
            computeDifferences()
        }
    }

    // MARK: - Side by Side View

    private var sideBySideView: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(leftDocument?.fileName ?? "No Document")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                ScrollView {
                    Text(leftText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(rightDocument?.fileName ?? "No Document")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                ScrollView {
                    Text(rightText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    // MARK: - Overlay View

    private var overlayView: some View {
        VStack {
            Text("Overlay Comparison")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(zip(leftText.split(separator: "\n"), rightText.split(separator: "\n")).enumerated()), id: \.offset) { index, pair in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)

                            if pair.0 == pair.1 {
                                Text(String(pair.0))
                                    .font(.system(.body, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(pair.0))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.red)
                                        .background(Color.red.opacity(0.1))
                                    Text(String(pair.1))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.green)
                                        .background(Color.green.opacity(0.1))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - Unified Diff View

    private var unifiedDiffView: some View {
        VStack {
            HStack {
                Image(systemName: "info.circle")
                Text("\(differences.count) differences found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(differences) { diff in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Line \(diff.lineNumber)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let removed = diff.removedText {
                                HStack(spacing: 4) {
                                    Text("-")
                                        .foregroundColor(.red)
                                        .font(.system(.body, design: .monospaced))
                                    Text(removed)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.red)
                                }
                                .padding(4)
                                .background(Color.red.opacity(0.1))
                            }

                            if let added = diff.addedText {
                                HStack(spacing: 4) {
                                    Text("+")
                                        .foregroundColor(.green)
                                        .font(.system(.body, design: .monospaced))
                                    Text(added)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.green)
                                }
                                .padding(4)
                                .background(Color.green.opacity(0.1))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - Helper Methods

    private func loadDocumentTexts() {
        // In a real implementation, this would load the actual document content
        // For now, we'll use placeholder text based on document metadata
        if let left = leftDocument {
            let extractedText = loadExtractedText(from: left)
            leftText = "Document: \(left.fileName)\nPath: \(left.localPath)\nSHA256: \(left.sha256 ?? "N/A")\n\nExtracted Text: \(extractedText ?? "(No text extracted)")"
        } else {
            leftText = ""
        }

        if let right = rightDocument {
            let extractedText = loadExtractedText(from: right)
            rightText = "Document: \(right.fileName)\nPath: \(right.localPath)\nSHA256: \(right.sha256 ?? "N/A")\n\nExtracted Text: \(extractedText ?? "(No text extracted)")"
        } else {
            rightText = ""
        }
    }
    
    private func loadExtractedText(from document: DocumentModel) -> String? {
        guard let path = document.extractedTextPath else { return nil }
        let url = URL(fileURLWithPath: path)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func computeDifferences() {
        guard !leftText.isEmpty && !rightText.isEmpty else {
            differences = []
            return
        }

        let leftLines = leftText.split(separator: "\n")
        let rightLines = rightText.split(separator: "\n")
        var diffs: [TextDifference] = []

        let maxLines = max(leftLines.count, rightLines.count)
        for i in 0..<maxLines {
            let leftLine = i < leftLines.count ? String(leftLines[i]) : nil
            let rightLine = i < rightLines.count ? String(rightLines[i]) : nil

            if leftLine != rightLine {
                diffs.append(TextDifference(
                    lineNumber: i + 1,
                    removedText: leftLine,
                    addedText: rightLine
                ))
            }
        }

        differences = diffs
    }
}

// MARK: - Supporting Types

struct TextDifference: Identifiable {
    let id = UUID()
    let lineNumber: Int
    let removedText: String?
    let addedText: String?
}

// MARK: - Preview

#Preview {
    CompareView(leftDocument: nil, rightDocument: nil)
}
