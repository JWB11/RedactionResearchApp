import Foundation
import CryptoKit

/// Computes textual similarity using SimHash and MinHash over extracted/OCR text artifacts.
actor TextSimilarityService {
    struct TextCluster: Identifiable, Sendable {
        let id: UUID
        let documents: [DocumentSnapshot]
        let minhashSimilarity: Double
        let simhashSpread: Int
        let summary: String
        let confidence: Double
    }

    /// Analyze the provided documents and group those with similar text content.
    /// SimHash focuses on global token distribution; MinHash approximates Jaccard similarity over shingles.
    func analyze(documents: [DocumentSnapshot]) async -> [TextCluster] {
        // Load normalized text payloads.
        var payloads: [(doc: DocumentSnapshot, text: String)] = []
        payloads.reserveCapacity(documents.count)

        for doc in documents {
            if let text = await loadCombinedText(for: doc), !text.isEmpty {
                payloads.append((doc, text))
            }
        }

        guard payloads.count >= 2 else { return [] }

        // Precompute signatures.
        let tokensAndSignatures: [(doc: DocumentSnapshot, simhash: UInt64, minhash: [UInt64])] = payloads.map { pair in
            let tokens = tokenize(pair.text)
            let simhash = simhash64(tokens: tokens)
            let shingles = makeShingles(tokens: tokens, size: 3)
            let minhash = minhashSignature(shingles: shingles, signatureCount: 32)
            return (pair.doc, simhash, minhash)
        }

        var parent = Array(0..<tokensAndSignatures.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        // Compare pairwise; corpus sizes here are typically moderate.
        for i in 0..<tokensAndSignatures.count {
            for j in (i + 1)..<tokensAndSignatures.count {
                let a = tokensAndSignatures[i]
                let b = tokensAndSignatures[j]

                let simhashDistance = Self.hammingDistance64(a.simhash, b.simhash)
                let jaccardEstimate = Self.minhashJaccardEstimate(a.minhash, b.minhash)

                // Combine heuristics: either close SimHash or strong MinHash similarity.
                if simhashDistance <= 10 || jaccardEstimate >= 0.6 {
                    union(i, j)
                }
            }
        }

        var grouped: [Int: [Int]] = [:]
        for i in 0..<tokensAndSignatures.count {
            let root = find(i)
            grouped[root, default: []].append(i)
        }

        var clusters: [TextCluster] = []
        for (_, indices) in grouped {
            guard indices.count > 1 else { continue }

            var docs: [DocumentSnapshot] = []
            docs.reserveCapacity(indices.count)
            var spread = 0
            var minhashScores: [Double] = []

            for i in 0..<indices.count {
                let idx = indices[i]
                docs.append(tokensAndSignatures[idx].doc)
                for j in (i + 1)..<indices.count {
                    let jdx = indices[j]
                    let dist = Self.hammingDistance64(tokensAndSignatures[idx].simhash, tokensAndSignatures[jdx].simhash)
                    spread = max(spread, dist)
                    let mh = Self.minhashJaccardEstimate(tokensAndSignatures[idx].minhash, tokensAndSignatures[jdx].minhash)
                    minhashScores.append(mh)
                }
            }

            let avgMinhash = minhashScores.isEmpty ? 0 : minhashScores.reduce(0, +) / Double(minhashScores.count)
            let confidence = max(0.35, min(0.95, (1.0 - Double(spread) / 64.0) * 0.6 + avgMinhash * 0.4))
            let summary = "Text similarity via SimHash/MinHash (spread ≤ \(spread), est. Jaccard ≈ \(String(format: "%.2f", avgMinhash)))"

            clusters.append(
                TextCluster(
                    id: UUID(),
                    documents: docs,
                    minhashSimilarity: avgMinhash,
                    simhashSpread: spread,
                    summary: summary,
                    confidence: confidence
                )
            )
        }

        clusters.sort { $0.documents.count > $1.documents.count }
        return clusters
    }

    // MARK: - Helpers

    private func loadCombinedText(for doc: DocumentSnapshot) async -> String? {
        if let extracted = await readText(path: doc.extractedTextPath), !extracted.isEmpty {
            if let ocr = await readText(path: doc.ocrTextPath), !ocr.isEmpty {
                return extracted + "\n\n" + ocr
            }
            return extracted
        }
        if let ocr = await readText(path: doc.ocrTextPath), !ocr.isEmpty {
            return ocr
        }
        return nil
    }

    private func readText(path: String?) async -> String? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func tokenize(_ text: String) -> [String] {
        let lowered = text.lowercased()
        let allowed = CharacterSet.alphanumerics.union(.whitespacesAndNewlines)
        let cleaned = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        return String(cleaned)
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0.prefix(48)) }
    }

    private func simhash64(tokens: [String]) -> UInt64 {
        guard !tokens.isEmpty else { return 0 }
        var weights = [Int](repeating: 0, count: 64)
        for token in tokens {
            let h = stable64(token)
            for bit in 0..<64 {
                let mask = UInt64(1) << bit
                if h & mask != 0 { weights[bit] += 1 } else { weights[bit] -= 1 }
            }
        }
        var result: UInt64 = 0
        for bit in 0..<64 {
            if weights[bit] >= 0 { result |= (UInt64(1) << bit) }
        }
        return result
    }

    private func makeShingles(tokens: [String], size: Int) -> [String] {
        guard tokens.count >= size else { return tokens }
        var shingles: [String] = []
        shingles.reserveCapacity(tokens.count - size + 1)
        for i in 0...(tokens.count - size) {
            shingles.append(tokens[i..<i+size].joined(separator: " "))
        }
        return shingles
    }

    private func minhashSignature(shingles: [String], signatureCount: Int) -> [UInt64] {
        let seeds: [UInt64] = (0..<signatureCount).map { UInt64(0x9e3779b97f4a7c15 &* (UInt64($0) + 1)) }
        var signature = Array(repeating: UInt64.max, count: signatureCount)
        for shingle in shingles {
            let h = stable64(shingle)
            for i in 0..<signatureCount {
                let mixed = h &+ seeds[i]
                if mixed < signature[i] { signature[i] = mixed }
            }
        }
        return signature
    }

    private func stable64(_ string: String) -> UInt64 {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest[..<8].reduce(UInt64(0)) { (acc, byte) in
            (acc << 8) | UInt64(byte)
        }
    }

    static func hammingDistance64(_ a: UInt64, _ b: UInt64) -> Int {
        Int((a ^ b).nonzeroBitCount)
    }

    static func minhashJaccardEstimate(_ a: [UInt64], _ b: [UInt64]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var matches = 0
        for i in 0..<a.count {
            if a[i] == b[i] { matches += 1 }
        }
        return Double(matches) / Double(a.count)
    }
}
