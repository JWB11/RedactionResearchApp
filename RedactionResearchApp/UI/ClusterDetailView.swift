import SwiftUI

struct ClusterDetailView: View {
    let clusters: [ClusterAnalysisService.SimilarityCluster]
    let isAnalyzing: Bool
    let status: String
    let clusterAIText: [UUID: String]
    let clusterAILoading: Set<UUID>
    let expandedClusters: Set<UUID>
    let showFullClusterDetail: Set<UUID>
    let clusterSuggestions: [UUID: [ClusterSuggestion]]
    let onAnalyze: () -> Void
    let onExplainCluster: (ClusterAnalysisService.SimilarityCluster) -> Void
    let onToggleExpand: (UUID) -> Void
    let onToggleFull: (UUID) -> Void
    let onOpenOriginal: (String) -> Void
    let onOpenDerived: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Clusters")
                    .font(.title3)
                    .bold()
                Spacer()
                Button(isAnalyzing ? "Analyzing…" : "Refresh clusters") {
                    onAnalyze()
                }
                .disabled(isAnalyzing)
            }

            if clusters.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No clusters yet")
                        .bold()
                    Text("Run indexing and clustering for the active case to populate similarity groups.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 18)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(clusters) { cluster in
                            ClusterCard(
                                cluster: cluster,
                                suggestions: clusterSuggestions[cluster.id] ?? [],
                                aiText: clusterAIText[cluster.id],
                                isLoadingAI: clusterAILoading.contains(cluster.id),
                                isExpanded: expandedClusters.contains(cluster.id),
                                showFullDetail: showFullClusterDetail.contains(cluster.id),
                                onExplain: { onExplainCluster(cluster) },
                                onToggleExpand: { onToggleExpand(cluster.id) },
                                onToggleFull: { onToggleFull(cluster.id) },
                                onOpenOriginal: onOpenOriginal,
                                onOpenDerived: onOpenDerived
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }

            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18)
    }
}

private struct ClusterCard: View {
    let cluster: ClusterAnalysisService.SimilarityCluster
    let suggestions: [ClusterSuggestion]
    let aiText: String?
    let isLoadingAI: Bool
    let isExpanded: Bool
    let showFullDetail: Bool
    let onExplain: () -> Void
    let onToggleExpand: () -> Void
    let onToggleFull: () -> Void
    let onOpenOriginal: (String) -> Void
    let onOpenDerived: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cluster.title)
                        .font(.headline)
                    Text(cluster.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isLoadingAI ? "Explaining…" : "Explain") { onExplain() }
                    .disabled(isLoadingAI)
                Button { onToggleExpand() } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .padding(6)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                ForEach(cluster.reasons) { reason in
                    HStack(spacing: 6) {
                        Text(reason.label)
                            .bold()
                        Text(String(format: "%.0f%%", reason.confidence * 100))
                            .monospacedDigit()
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.blue.opacity(0.12))
                    .clipShape(Capsule())
                    .help(reason.detail)
                }
            }

            memberSection(title: "Exact duplicates", members: cluster.exactDuplicates)
            memberSection(title: "Variants", members: cluster.variants)

            if isExpanded && !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cluster suggestions")
                        .font(.subheadline.weight(.semibold))

                    ForEach(suggestions) { suggestion in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Merged text from best candidates")
                                        .font(.caption)
                                    Text("Basis: \(suggestion.basisFile)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    copyToClipboard(suggestion.mergedText)
                                } label: {
                                    Label("Copy suggestion", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                            }

                            Text(suggestion.mergedText)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .background(.gray.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                            if !suggestion.evidence.isEmpty {
                                let citations = suggestion.evidence.map { ev -> String in
                                    var parts: [String] = [ev.sourceFile]
                                    if let page = ev.page { parts.append("p. \(page)") }
                                    if let line = ev.line { parts.append("line \(line)") }
                                    return parts.joined(separator: ", ")
                                }
                                Text("Citations: " + citations.joined(separator: " • "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(.blue.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            if isExpanded {
                let text = aiText ?? "No AI explanation yet."
                let short = String(text.prefix(500))

                VStack(alignment: .leading, spacing: 6) {
                    Text(showFullDetail ? text : short)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Button(showFullDetail ? "Show less" : "More detail") {
                        onToggleFull()
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .glassCard(cornerRadius: 18)
    }

    private func memberSection(title: String, members: [DuplicateAnalysisService.ClusterMember]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !members.isEmpty {
                Text(title)
                    .font(.callout)
                    .bold()
            }
            ForEach(members) { m in
                HStack(spacing: 10) {
                    if m.isBestCandidate {
                        Text("Best")
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.green.opacity(0.18))
                            .clipShape(Capsule())
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.fileName)
                            .font(.callout)
                        Text("score \(m.completenessScore) • text \(m.extractedTextChars) • ocr \(m.ocrTextChars)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Spacer()

                    Button("Open") { onOpenOriginal(m.localPath) }
                        .buttonStyle(.link)
                    if let derived = derivedFolderPath(from: m) {
                        Button("Derived") { onOpenDerived(derived) }
                            .buttonStyle(.link)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func derivedFolderPath(from m: DuplicateAnalysisService.ClusterMember) -> String? {
        guard let sha = m.sha256, !sha.isEmpty else { return nil }
        do {
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            return appSupport
                .appendingPathComponent("RedactionResearchApp", isDirectory: true)
                .appendingPathComponent("Derived", isDirectory: true)
                .appendingPathComponent(sha, isDirectory: true)
                .path
        } catch {
            return nil
        }
    }

    private func copyToClipboard(_ text: String) {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #endif
    }
}
