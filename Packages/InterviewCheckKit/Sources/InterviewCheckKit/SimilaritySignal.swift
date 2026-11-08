import Foundation

/// How closely the spoken answer follows one AI reference answer.
public struct ReferenceMatch: Equatable {
    public let referenceID: UUID
    public let label: String
    /// Share of the candidate's three-word phrases that appear in the reference.
    public let phraseContainment: Double
    /// Overlap of distinctive content words (Jaccard).
    public let contentOverlap: Double
    /// Cosine similarity of the two embeddings, when available.
    public let semantic: Double?
    /// The longest phrases both share, for the evidence line.
    public let sharedPhrases: [String]
    public let score: Double
}

public struct SimilarityResult: Equatable {
    public let best: ReferenceMatch?
    /// Words the answer shares in order with the best match, for the evidence line.
    public var bestShared: SharedWords?
    /// How much the AI answers agree with each other (0...1). When every
    /// model says the same thing, any correct answer matches them.
    public let referenceAgreement: Double
    public let score: Double
}

/// One AI answer to compare against.
public struct ReferenceText: Equatable {
    public let id: UUID
    public let label: String
    public let text: String
    public let embedding: [Double]?

    public init(id: UUID, label: String, text: String, embedding: [Double]?) {
        self.id = id
        self.label = label
        self.text = text
        self.embedding = embedding
    }
}

/// Compares the candidate's words with each AI answer. Exact shared
/// phrasing is the strongest sign of reading; meaning similarity alone is
/// weak, because a correct answer covers the same ground as the AI.
public enum SimilaritySignal {
    public static let phraseLength = 3

    public static func evaluate(
        answerText: String,
        answerEmbedding: [Double]?,
        questionText: String,
        references: [ReferenceText]
    ) -> SimilarityResult {
        let answerTokens = FillerLexicon.tokens(answerText)
        let questionGrams = Set(ngrams(FillerLexicon.tokens(questionText), phraseLength))
        let usable = references.filter { !FillerLexicon.tokens($0.text).isEmpty }
        guard answerTokens.count >= 8, !usable.isEmpty else {
            return SimilarityResult(best: nil, referenceAgreement: 0, score: 0)
        }

        let matches = usable.map { reference in
            match(answerTokens: answerTokens, answerEmbedding: answerEmbedding,
                  questionGrams: questionGrams, reference: reference)
        }
        let best = matches.max { $0.score < $1.score }
        let agreement = referenceAgreement(usable, questionGrams: questionGrams)
        // Discount up to half when the references agree closely.
        let discount = 1 - 0.5 * clamp((agreement - 0.15) / 0.35)
        var result = SimilarityResult(best: best, referenceAgreement: agreement, score: (best?.score ?? 0) * discount)
        if let best, let reference = usable.first(where: { $0.id == best.referenceID }) {
            result.bestShared = SharedWords.find(answer: answerText, reference: reference.text, question: questionText)
        }
        return result
    }

    public static func match(
        answerTokens: [String],
        answerEmbedding: [Double]?,
        questionGrams: Set<[String]>,
        reference: ReferenceText
    ) -> ReferenceMatch {
        let referenceTokens = FillerLexicon.tokens(reference.text)
        let answerGrams = distinctiveGrams(answerTokens, excluding: questionGrams)
        let referenceGrams = distinctiveGrams(referenceTokens, excluding: questionGrams)
        let containment = answerGrams.isEmpty ? 0
            : Double(answerGrams.intersection(referenceGrams).count) / Double(answerGrams.count)

        let answerContent = contentWords(answerTokens)
        let referenceContent = contentWords(referenceTokens)
        let union = answerContent.union(referenceContent)
        let overlap = union.isEmpty ? 0 : Double(answerContent.intersection(referenceContent).count) / Double(union.count)

        let semantic = zip2(answerEmbedding, reference.embedding).map { cosine($0.0, $0.1) }
        let phraseNorm = clamp(containment / 0.25)
        let overlapNorm = clamp((overlap - 0.1) / 0.3)
        let score: Double
        if let semantic {
            score = 0.45 * clamp((semantic - 0.55) / 0.35) + 0.35 * phraseNorm + 0.2 * overlapNorm
        } else {
            score = 0.65 * phraseNorm + 0.35 * overlapNorm
        }

        return ReferenceMatch(
            referenceID: reference.id, label: reference.label, phraseContainment: containment,
            contentOverlap: overlap, semantic: semantic,
            sharedPhrases: sharedPhrases(answerTokens, referenceTokens, excluding: questionGrams),
            score: score
        )
    }

    /// Mean pairwise phrase containment between the references.
    public static func referenceAgreement(_ references: [ReferenceText], questionGrams: Set<[String]>) -> Double {
        let grams = references.map { distinctiveGrams(FillerLexicon.tokens($0.text), excluding: questionGrams) }
        var total = 0.0
        var pairs = 0
        for i in grams.indices {
            for j in grams.indices where j > i {
                let smaller = min(grams[i].count, grams[j].count)
                guard smaller > 0 else { continue }
                total += Double(grams[i].intersection(grams[j]).count) / Double(smaller)
                pairs += 1
            }
        }
        return pairs > 0 ? total / Double(pairs) : 0
    }

    /// Three-word phrases that are not all small words and not in the question.
    public static func distinctiveGrams(_ tokens: [String], excluding: Set<[String]>) -> Set<[String]> {
        Set(ngrams(tokens, phraseLength).filter { gram in
            !excluding.contains(gram) && gram.contains { !FillerLexicon.stopwords.contains($0) }
        })
    }

    public static func contentWords(_ tokens: [String]) -> Set<String> {
        Set(tokens.filter { $0.count >= 4 && !FillerLexicon.stopwords.contains($0) })
    }

    /// Longest shared runs (up to 8 words, at least 4), longest first, max 3.
    public static func sharedPhrases(_ answer: [String], _ reference: [String], excluding: Set<[String]>) -> [String] {
        var found: [[String]] = []
        let referenceGrams = Set(ngrams(reference, 4))
        var index = 0
        while index + 4 <= answer.count {
            var length = 4
            guard referenceGrams.contains(Array(answer[index..<(index + 4)])) else { index += 1; continue }
            let referenceText = " " + reference.joined(separator: " ") + " "
            while index + length < answer.count, length < 8,
                  referenceText.contains(" " + answer[index...(index + length)].joined(separator: " ") + " ") {
                length += 1
            }
            let run = Array(answer[index..<(index + length)])
            if run.contains(where: { !FillerLexicon.stopwords.contains($0) }) { found.append(run) }
            index += length
        }
        return found.sorted { $0.count > $1.count }.prefix(3).map { $0.joined(separator: " ") }
    }

    public static func ngrams(_ tokens: [String], _ n: Int) -> [[String]] {
        guard tokens.count >= n else { return [] }
        return (0...(tokens.count - n)).map { Array(tokens[$0..<($0 + n)]) }
    }

    public static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for (x, y) in zip(a, b) {
            dot += x * y
            normA += x * x
            normB += y * y
        }
        let denominator = normA.squareRoot() * normB.squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }

    private static func zip2(_ a: [Double]?, _ b: [Double]?) -> ([Double], [Double])? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    public static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}
