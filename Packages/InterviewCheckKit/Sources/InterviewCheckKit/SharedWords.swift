import Foundation

/// Runs of words the candidate's answer shares, in the same order, with an
/// AI answer: what a plagiarism checker would highlight. Indexes count
/// display words (the text split on whitespace, see `wordRanges`), so the
/// same words can be highlighted in both texts.
public struct SharedWords: Equatable {
    /// Display words of the answer inside a shared run.
    public let answer: Set<Int>
    /// Display words of the AI answer inside a shared run.
    public let reference: Set<Int>
    /// Answer words inside a shared run (fillers not counted).
    public let sharedCount: Int
    /// Answer words, fillers not counted.
    public let answerCount: Int

    public init(answer: Set<Int>, reference: Set<Int>, sharedCount: Int, answerCount: Int) {
        self.answer = answer
        self.reference = reference
        self.sharedCount = sharedCount
        self.answerCount = answerCount
    }

    public static let none = SharedWords(answer: [], reference: [], sharedCount: 0, answerCount: 0)
    /// The shortest run that counts: four words, two of them not small words.
    public static let minimumRun = 4

    public var coverage: Double { answerCount > 0 ? Double(sharedCount) / Double(answerCount) : 0 }

    /// "41 of 63 words appear word for word in an AI answer", or nil when
    /// nothing is shared.
    public var summary: String? {
        guard sharedCount > 0 else { return nil }
        return "\(sharedCount) of \(answerCount) words appear word for word in an AI answer"
    }

    /// The words shared with one AI answer.
    public static func find(answer: String, reference: String, question: String = "") -> SharedWords {
        let answerTokens = tokens(answer)
        let referenceTokens = tokens(reference)
        let tiles = tiles(answerTokens.map(\.text), referenceTokens.map(\.text), question: question)
        let answerCovered = Set(tiles.flatMap { $0.answer..<($0.answer + $0.length) })
        let referenceCovered = Set(tiles.flatMap { $0.reference..<($0.reference + $0.length) })
        return SharedWords(answer: Set(answerCovered.map { answerTokens[$0].word }),
                           reference: Set(referenceCovered.map { referenceTokens[$0].word }),
                           sharedCount: answerCovered.count, answerCount: answerTokens.count)
    }

    /// The answer's words shared with any of the AI answers.
    public static func anyReference(answer: String, references: [String], question: String = "") -> SharedWords {
        let answerTokens = tokens(answer)
        var covered = Set<Int>()
        for reference in references {
            let tiles = tiles(answerTokens.map(\.text), tokens(reference).map(\.text), question: question)
            tiles.forEach { covered.formUnion($0.answer..<($0.answer + $0.length)) }
        }
        return SharedWords(answer: Set(covered.map { answerTokens[$0].word }), reference: [],
                           sharedCount: covered.count, answerCount: answerTokens.count)
    }

    /// Where each display word sits in the text.
    public static func wordRanges(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let begin = start { ranges.append(begin..<index); start = nil }
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let begin = start { ranges.append(begin..<text.endIndex) }
        return ranges
    }

    /// The stretches of text to highlight: neighbouring shared words joined
    /// into one range (with the spaces between them), also across a filler
    /// such as "(um)" that sits inside a shared run.
    public static func highlightRanges(_ text: String, words: Set<Int>) -> [Range<String.Index>] {
        guard !words.isEmpty else { return [] }
        let ranges = wordRanges(text)
        var result: [Range<String.Index>] = []
        var index = 0
        while index < ranges.count {
            guard words.contains(index) else { index += 1; continue }
            var end = index
            var next = index + 1
            while next < ranges.count {
                if words.contains(next) {
                    end = next
                    next += 1
                } else if FillerLexicon.tokens(String(text[ranges[next]])).isEmpty, words.contains(next + 1) {
                    next += 1
                } else {
                    break
                }
            }
            result.append(ranges[index].lowerBound..<ranges[end].upperBound)
            index = end + 1
        }
        return result
    }

    // MARK: - Matching

    struct Token {
        let text: String
        /// The display word it came from.
        let word: Int
    }

    struct Tile: Equatable {
        let answer: Int
        let reference: Int
        let length: Int
    }

    /// Normalized words, fillers left out, each tied to its display word.
    static func tokens(_ text: String) -> [Token] {
        wordRanges(text).enumerated().flatMap { index, range in
            FillerLexicon.tokens(String(text[range])).map { Token(text: $0, word: index) }
        }
    }

    /// The longest common runs first, without overlap on either side (greedy
    /// string tiling). A run counts when it has two words that are not small
    /// words and is not just the question said back.
    static func tiles(_ answer: [String], _ reference: [String], question: String) -> [Tile] {
        let minimum = minimumRun
        guard answer.count >= minimum, reference.count >= minimum else { return [] }
        let questionGrams = Set(SimilaritySignal.ngrams(FillerLexicon.tokens(question), 3))

        var candidates: [Tile] = []
        var previous = [Int](repeating: 0, count: reference.count + 1)
        for i in 1...answer.count {
            var current = [Int](repeating: 0, count: reference.count + 1)
            for j in 1...reference.count where answer[i - 1] == reference[j - 1] {
                current[j] = previous[j - 1] + 1
                let length = current[j]
                let extends = i < answer.count && j < reference.count && answer[i] == reference[j]
                if !extends, length >= minimum {
                    candidates.append(Tile(answer: i - length, reference: j - length, length: length))
                }
            }
            previous = current
        }

        var usedAnswer = Set<Int>()
        var usedReference = Set<Int>()
        var accepted: [Tile] = []
        for tile in candidates.sorted(by: { ($0.length, -$0.answer) > ($1.length, -$1.answer) }) {
            let answerRange = tile.answer..<(tile.answer + tile.length)
            let referenceRange = tile.reference..<(tile.reference + tile.length)
            guard usedAnswer.isDisjoint(with: answerRange), usedReference.isDisjoint(with: referenceRange) else { continue }
            let run = Array(answer[answerRange])
            guard run.filter({ !FillerLexicon.stopwords.contains($0) }).count >= 2 else { continue }
            let grams = SimilaritySignal.ngrams(run, 3)
            if !questionGrams.isEmpty, grams.allSatisfy(questionGrams.contains) { continue }
            usedAnswer.formUnion(answerRange)
            usedReference.formUnion(referenceRange)
            accepted.append(tile)
        }
        return accepted.sorted { $0.answer < $1.answer }
    }
}
