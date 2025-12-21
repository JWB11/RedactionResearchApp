import Foundation
import SwiftUI

// MARK: - AI Service

@MainActor
final class AIService: ObservableObject {
    static let shared = AIService()
    private init() {}

    // User consent (off by default)
    @AppStorage("cloudAIEnabled") private var cloudAIEnabled: Bool = false
    @AppStorage("localAIEnabled") private var localAIEnabled: Bool = false
    @AppStorage("cloudAIConsented") private var cloudAIConsented: Bool = false
    @AppStorage("localAIConsented") private var localAIConsented: Bool = false

    // Read-only accessors for UI / services (do not mutate storage directly)
    var isCloudEnabled: Bool { cloudAIEnabled }
    var isLocalEnabled: Bool { localAIEnabled }
    var hasCloudConsent: Bool { cloudAIConsented }
    var hasLocalConsent: Bool { localAIConsented }

    // Optional trace hook (Execution Trace window)
    // Inject from ContentView or App entry if desired
    var trace: ((TraceEvent) -> Void)?

    // MARK: Capabilities

    enum Capability: String, CaseIterable, Sendable {
        case summarize
        case redactInference
        case clusterExplain
    }

    struct CapabilityStatus: Sendable {
        let localAvailable: Bool
        let cloudAvailable: Bool
    }

    func capabilityStatus(_ cap: Capability) -> CapabilityStatus {
        // v1: local is assumed available for summarize/clusterExplain;
        // redactInference may require OCR text and model availability.
        switch cap {
        case .summarize, .clusterExplain:
            return .init(localAvailable: true, cloudAvailable: true)
        case .redactInference:
            return .init(localAvailable: true, cloudAvailable: true)
        }
    }

    // MARK: Requests / Responses (structured)

    struct SummarizeRequest: Sendable {
        let text: String
        let maxTokens: Int
        let audience: String? // e.g., "legal analyst"
    }

    struct RedactionInferenceRequest: Sendable {
        let extractedText: String
        let ocrText: String?
        let contextHints: [String: String]
    }

    struct AIResponse: Sendable {
        let text: String
        let provenance: Provenance
        let warnings: [String]
    }

    enum Provenance: String, Sendable {
        case localOnDevice
        case cloud
    }

    // MARK: Future model hooks (optional)

    /// Optional local model runner hook (CoreML / Apple Intelligence on-device).
    /// Keep this protocol very small to avoid SDK-specific dependencies.
    protocol LocalModelRunner: Sendable {
        func generate(system: String, user: String, maxTokens: Int) async throws -> String
    }

    /// Optional cloud model runner hook (only when explicitly enabled).
    protocol CloudModelRunner: Sendable {
        func generate(system: String, user: String, maxTokens: Int) async throws -> String
    }

    /// Inject these from the app (later). For now, we use deterministic heuristics.
    var localRunner: LocalModelRunner? = nil
    var cloudRunner: CloudModelRunner? = nil

    struct RedactionFinding: Codable, Sendable, Hashable {
        var kind: String
        var confidence: Double
        var snippet: String
        var rationale: String
    }

    struct RedactionInferenceResult: Codable, Sendable, Hashable {
        var summary: String
        var findings: [RedactionFinding]
        var suggestedNextSteps: [String]
        var notes: [String]
    }

    // MARK: Public APIs

    /// Summarize text using on-device first. Cloud is used only if explicitly enabled.
    func summarize(_ req: SummarizeRequest) async throws -> AIResponse {
        let start = Date()
        trace?(TraceEvent(stage: "AI", message: "Summarize requested", metadata: ["len": "\(req.text.count)"]))

        if localAIEnabled {
            let text = try await summarizeLocal(req)
            trace?(TraceEvent(stage: "AI", message: "Summarize completed (local)", durationMs: Date().timeIntervalSince(start) * 1000, metadata: ["chars": "\(text.count)", "provenance": Provenance.localOnDevice.rawValue]))
            return AIResponse(text: text, provenance: .localOnDevice, warnings: [])
        }

        if cloudAIEnabled {
            let text = try await summarizeCloud(req)
            trace?(TraceEvent(stage: "AI", message: "Summarize completed (cloud)", durationMs: Date().timeIntervalSince(start) * 1000, metadata: ["chars": "\(text.count)", "provenance": Provenance.cloud.rawValue]))
            return AIResponse(text: text, provenance: .cloud, warnings: ["Cloud output—verify before use."])
        }

        throw AIError.consentRequired
    }

    /// Infer likely redacted content (suggestions only).
    func inferRedactions(_ req: RedactionInferenceRequest) async throws -> AIResponse {
        let start = Date()
        trace?(TraceEvent(stage: "AI", message: "Redaction inference requested", metadata: ["extracted": "\(req.extractedText.count)", "ocr": "\(req.ocrText?.count ?? 0)"]))

        if localAIEnabled {
            let text = try await redactLocal(req)
            trace?(TraceEvent(stage: "AI", message: "Redaction inference completed (local)", durationMs: Date().timeIntervalSince(start) * 1000, metadata: ["chars": "\(text.count)", "provenance": Provenance.localOnDevice.rawValue]))
            return AIResponse(text: text, provenance: .localOnDevice, warnings: ["Suggestions only."])
        }

        if cloudAIEnabled {
            let text = try await redactCloud(req)
            trace?(TraceEvent(stage: "AI", message: "Redaction inference completed (cloud)", durationMs: Date().timeIntervalSince(start) * 1000, metadata: ["chars": "\(text.count)", "provenance": Provenance.cloud.rawValue]))
            return AIResponse(text: text, provenance: .cloud, warnings: ["Cloud output—verify before use."])
        }

        throw AIError.consentRequired
    }

    /// Explain why a duplicate cluster picked a "best" candidate.
    func explainCluster(text: String) async throws -> AIResponse {
        let start = Date()
        trace?(TraceEvent(stage: "AI", message: "Cluster explanation requested", metadata: ["len": "\(text.count)"]))
        if localAIEnabled {
            let out = try await explainLocal(text)
            trace?(TraceEvent(stage: "AI", message: "Cluster explanation completed (local)", durationMs: Date().timeIntervalSince(start) * 1000, metadata: ["len": "\(text.count)", "provenance": Provenance.localOnDevice.rawValue]))
            return AIResponse(text: out, provenance: .localOnDevice, warnings: [])
        }
        if cloudAIEnabled {
            let out = try await explainCloud(text)
            trace?(TraceEvent(stage: "AI", message: "Cluster explanation completed (cloud)", durationMs: Date().timeIntervalSince(start) * 1000, metadata: ["len": "\(text.count)", "provenance": Provenance.cloud.rawValue]))
            return AIResponse(text: out, provenance: .cloud, warnings: ["Cloud output—verify before use."])
        }
        throw AIError.consentRequired
    }

    // MARK: Consent helpers

    func shouldPromptToEnableCloudAI() -> Bool { !cloudAIEnabled }

    func markConsent(forLocal: Bool) {
        objectWillChange.send()
        if forLocal {
            localAIConsented = true
        } else {
            cloudAIConsented = true
        }
    }

    func setCloudAIEnabled(_ enabled: Bool) {
        objectWillChange.send()
        cloudAIEnabled = enabled
        trace?(TraceEvent(stage: "AI", message: enabled ? "Cloud AI enabled" : "Cloud AI disabled", aiMetadata: ["capability": "settings", "cloud": enabled ? "on" : "off"]))
    }

    func setLocalAIEnabled(_ enabled: Bool) {
        objectWillChange.send()
        localAIEnabled = enabled
        trace?(TraceEvent(stage: "AI", message: enabled ? "Local AI enabled" : "Local AI disabled", aiMetadata: ["capability": "settings", "local": enabled ? "on" : "off"]))
    }

    // MARK: - Local / Cloud implementations

    private func summarizeLocal(_ req: SummarizeRequest) async throws -> String {
        // Prefer an injected local model if available.
        if let localRunner {
            trace?(TraceEvent(stage: "AI", message: "Summarize using local runner", metadata: ["maxTokens": "\(req.maxTokens)"], aiMetadata: ["capability": Capability.summarize.rawValue, "provenance": Provenance.localOnDevice.rawValue]))
            let system = "You are a careful legal research assistant. Summarize concisely and preserve key dates, parties, and docket identifiers."
            let user = "Audience: \(req.audience ?? "legal analyst")\n\nText:\n\(req.text)"
            let prompt = system + "\n" + user
            let out = try await localRunner.generate(system: system, user: user, maxTokens: req.maxTokens)
            audit(capability: .summarize, modelID: "local-runner", prompt: prompt, input: req.text, output: out, provenance: .localOnDevice)
            return out
        }

        // Deterministic fallback: extract top lines and simple key fields.
        let clean = Self.normalizeText(req.text)
        let lines = clean.split(separator: "\n", omittingEmptySubsequences: true)
        let head = lines.prefix(12).joined(separator: "\n")

        // Pull a few "signals" that help legal work.
        let signals = Self.extractSignals(from: clean)
        var out: [String] = []
        out.append("Summary (local heuristic)")
        if !signals.isEmpty {
            out.append("Key signals: " + signals.joined(separator: " • "))
        }
        out.append(String(head))
        let rendered = out.joined(separator: "\n")
        audit(capability: .summarize, modelID: "local-heuristic-v1", prompt: "local_heuristic_summarize", input: req.text, output: rendered, provenance: .localOnDevice)
        return rendered
    }

    private func summarizeCloud(_ req: SummarizeRequest) async throws -> String {
        // Only called when cloud is enabled and local is disabled.
        if let cloudRunner {
            trace?(TraceEvent(stage: "AI", message: "Summarize using cloud runner", metadata: ["maxTokens": "\(req.maxTokens)"], aiMetadata: ["capability": Capability.summarize.rawValue, "provenance": Provenance.cloud.rawValue]))
            let system = "You are a careful legal research assistant. Summarize concisely and preserve key dates, parties, and docket identifiers."
            let user = "Audience: \(req.audience ?? "legal analyst")\n\nText:\n\(req.text)"
            let prompt = system + "\n" + user
            let out = try await cloudRunner.generate(system: system, user: user, maxTokens: req.maxTokens)
            audit(capability: .summarize, modelID: "cloud-runner", prompt: prompt, input: req.text, output: out, provenance: .cloud)
            return out
        }

        // If no cloud runner is installed, fail clearly.
        throw AIError.cloudNotConfigured
    }

    private func redactLocal(_ req: RedactionInferenceRequest) async throws -> String {
        // Prefer an injected local model if available.
        if let localRunner {
            trace?(TraceEvent(stage: "AI", message: "Redaction inference using local runner", aiMetadata: ["capability": Capability.redactInference.rawValue, "provenance": Provenance.localOnDevice.rawValue]))
            let system = "You analyze legal documents. You do NOT guess private info. You identify likely redactions and propose safe next steps. Output valid JSON only."
            let user = Self.buildRedactionPrompt(extracted: req.extractedText, ocr: req.ocrText, hints: req.contextHints)
            let prompt = system + "\n" + user
            let out = try await localRunner.generate(system: system, user: user, maxTokens: 900)
            audit(capability: .redactInference, modelID: "local-runner", prompt: prompt, input: req.extractedText + (req.ocrText ?? ""), output: out, provenance: .localOnDevice)
            return out
        }

        // Deterministic heuristic inference: look for redaction markers and missing-field patterns.
        let extracted = Self.normalizeText(req.extractedText)
        let ocr = Self.normalizeText(req.ocrText ?? "")

        let markers = Self.findRedactionMarkers(in: extracted + "\n" + ocr)
        let holes = Self.findLikelyHoles(in: extracted, ocr: ocr)

        var findings: [RedactionFinding] = []
        findings.append(contentsOf: markers)
        findings.append(contentsOf: holes)

        findings.sort { $0.confidence > $1.confidence }
        if findings.count > 20 { findings = Array(findings.prefix(20)) }

        let result = RedactionInferenceResult(
            summary: findings.isEmpty
                ? "No obvious redaction markers were detected in extracted/OCR text."
                : "Detected \(findings.count) potential redaction markers/patterns (heuristic).",
            findings: findings,
            suggestedNextSteps: [
                "Compare with near-duplicates (dHash) to locate less-redacted variants.",
                "Run OCR at higher quality (300–400 DPI) if scans are low-resolution.",
                "Search across corpus for repeated partially-visible identifiers (case number, dates, party names)."
            ],
            notes: [
                "This output is generated locally with deterministic heuristics (no cloud).",
                "Suggestions are not de-redaction and do not recover hidden text." 
            ]
        )

        let output = try Self.prettyJSON(result)
        audit(capability: .redactInference, modelID: "local-heuristic-v1", prompt: "local_heuristic_redact_inference", input: req.extractedText + (req.ocrText ?? ""), output: output, provenance: .localOnDevice)
        return output
    }

    private func redactCloud(_ req: RedactionInferenceRequest) async throws -> String {
        if let cloudRunner {
            trace?(TraceEvent(stage: "AI", message: "Redaction inference using cloud runner", aiMetadata: ["capability": Capability.redactInference.rawValue, "provenance": Provenance.cloud.rawValue]))
            let system = "You analyze legal documents. You do NOT guess private info. You identify likely redactions and propose safe next steps. Output valid JSON only."
            let user = Self.buildRedactionPrompt(extracted: req.extractedText, ocr: req.ocrText, hints: req.contextHints)
            let prompt = system + "\n" + user
            let out = try await cloudRunner.generate(system: system, user: user, maxTokens: 900)
            audit(capability: .redactInference, modelID: "cloud-runner", prompt: prompt, input: req.extractedText + (req.ocrText ?? ""), output: out, provenance: .cloud)
            return out
        }
        throw AIError.cloudNotConfigured
    }

    private func explainLocal(_ text: String) async throws -> String {
        if let localRunner {
            trace?(TraceEvent(stage: "AI", message: "Cluster explanation using local runner", aiMetadata: ["capability": Capability.clusterExplain.rawValue, "provenance": Provenance.localOnDevice.rawValue]))
            let system = "You explain duplicate clustering decisions for legal research. Be precise and cite the provided evidence."
            let user = "Explain why the best candidate was selected. Evidence:\n\(text)"
            let prompt = system + "\n" + user
            let out = try await localRunner.generate(system: system, user: user, maxTokens: 450)
            audit(capability: .clusterExplain, modelID: "local-runner", prompt: prompt, input: text, output: out, provenance: .localOnDevice)
            return out
        }

        // Deterministic fallback: template explanation.
        let clean = Self.normalizeText(text)
        let signals = Self.extractSignals(from: clean)
        let sigLine = signals.isEmpty ? "" : "Signals: " + signals.joined(separator: " • ")
        let rendered = ([
            "Cluster explanation (local heuristic)",
            sigLine,
            "The best candidate is selected by maximizing completeness signals (text chars + OCR chars + file size) and preferring higher coverage.",
            "Verify by opening the derived artifacts (text.txt, ocr.txt, thumb.png) for the top-ranked file."
        ].filter { !$0.isEmpty }).joined(separator: "\n")
        audit(capability: .clusterExplain, modelID: "local-heuristic-v1", prompt: "local_heuristic_cluster_explain", input: text, output: rendered, provenance: .localOnDevice)
        return rendered
    }

    private func explainCloud(_ text: String) async throws -> String {
        if let cloudRunner {
            trace?(TraceEvent(stage: "AI", message: "Cluster explanation using cloud runner", aiMetadata: ["capability": Capability.clusterExplain.rawValue, "provenance": Provenance.cloud.rawValue]))
            let system = "You explain duplicate clustering decisions for legal research. Be precise and cite the provided evidence."
            let user = "Explain why the best candidate was selected. Evidence:\n\(text)"
            let prompt = system + "\n" + user
            let out = try await cloudRunner.generate(system: system, user: user, maxTokens: 450)
            audit(capability: .clusterExplain, modelID: "cloud-runner", prompt: prompt, input: text, output: out, provenance: .cloud)
            return out
        }
        throw AIError.cloudNotConfigured
    }

    // MARK: - Helpers (deterministic)

    private static func normalizeText(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractSignals(from s: String) -> [String] {
        var out: [String] = []
        // Very small, safe signal extraction.
        let patterns: [(String, String)] = [
            ("case no", "Case No"),
            ("docket", "Docket"),
            ("plaintiff", "Plaintiff"),
            ("defendant", "Defendant"),
            ("v.", "v."),
            ("court", "Court")
        ]
        let lower = s.lowercased()
        for (needle, label) in patterns {
            if lower.contains(needle) { out.append(label) }
        }
        // Date-like signals
        if lower.range(of: "\\b(19|20)\\d{2}\\b", options: .regularExpression) != nil {
            out.append("Has year")
        }
        return out
    }

    private static func buildRedactionPrompt(extracted: String, ocr: String?, hints: [String: String]) -> String {
        let hintBlock = hints.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        let ocrBlock = (ocr ?? "")
        return "Context:\n\(hintBlock)\n\nExtracted Text:\n\(extracted)\n\nOCR Text:\n\(ocrBlock)\n\nTask: Identify redaction markers and likely missing fields. Output JSON with: summary, findings[{kind,confidence,snippet,rationale}], suggestedNextSteps[], notes[]."
    }

    private static func findRedactionMarkers(in s: String) -> [RedactionFinding] {
        let candidates: [(String, String, Double)] = [
            ("[REDACTED]", "explicit_marker", 0.98),
            ("(REDACTED)", "explicit_marker", 0.96),
            ("REDACTED", "explicit_marker", 0.90),
            ("████", "block_marker", 0.92),
            ("▮▮▮", "block_marker", 0.85),
            ("____", "underscore_marker", 0.70)
        ]
        var out: [RedactionFinding] = []
        for (needle, kind, conf) in candidates {
            if let range = s.range(of: needle) {
                let snippet = Self.snippet(around: s, range: range, radius: 80)
                out.append(.init(kind: kind, confidence: conf, snippet: snippet, rationale: "Found marker \(needle)."))
            }
        }
        return out
    }

    private static func findLikelyHoles(in extracted: String, ocr: String) -> [RedactionFinding] {
        // Heuristic: lines that end with colon but have no value; or repeated spaces suggesting blank fields.
        let lines = extracted.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [RedactionFinding] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":") {
                out.append(.init(kind: "missing_field", confidence: 0.55, snippet: String(trimmed), rationale: "Field label with no value."))
            }
            if trimmed.contains("      ") && trimmed.count < 140 {
                out.append(.init(kind: "possible_blank", confidence: 0.45, snippet: String(trimmed), rationale: "Multiple spaces may indicate blanked content."))
            }
        }

        // Cross-signal: if OCR has substantially more content, flag that extracted layer is likely incomplete.
        if ocr.count > extracted.count * 3 && ocr.count > 500 {
            out.append(.init(kind: "scanned_pdf", confidence: 0.80, snippet: "OCR chars \(ocr.count) vs extracted \(extracted.count)", rationale: "OCR contains much more text than extracted PDF layer."))
        }
        return out
    }

    private static func snippet(around s: String, range: Range<String.Index>, radius: Int) -> String {
        let start = s.index(range.lowerBound, offsetBy: -radius, limitedBy: s.startIndex) ?? s.startIndex
        let end = s.index(range.upperBound, offsetBy: radius, limitedBy: s.endIndex) ?? s.endIndex
        return String(s[start..<end]).replacingOccurrences(of: "\n", with: " ")
    }

    private static func prettyJSON<T: Encodable>(_ value: T) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Audit helpers

    private func audit(capability: Capability, modelID: String, prompt: String, input: String, output: String, provenance: Provenance) {
        let promptHash = HashUtils.sha256(for: prompt)
        let inputHash = HashUtils.sha256(for: input)
        let outputHash = HashUtils.sha256(for: output)
        trace?(TraceEvent(stage: "AI", message: "Audit \(capability.rawValue)", metadata: [
            "modelID": modelID,
            "promptHash": promptHash,
            "inputHash": inputHash,
            "outputHash": outputHash,
            "provenance": provenance.rawValue
        ]))
    }
}

// MARK: - Errors

enum AIError: Error, LocalizedError {
    case consentRequired
    case cloudNotConfigured

    var errorDescription: String? {
        switch self {
        case .consentRequired:
            return "AI feature requires user consent. Enable local or cloud AI in Settings."
        case .cloudNotConfigured:
            return "Cloud AI is enabled but no cloud runner is configured."
        }
    }
}
