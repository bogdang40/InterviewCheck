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
    /// Words of the answer, as shown, inside a shared run (fillers not counted).
    public let sharedCount: Int
    /// Words of the answer as shown, fillers not counted.
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
        // Screens redraw often with the same texts (the clock ticks during a live answer).
        cache.value(for: [answer, reference, question]) { compute(answer: answer, reference: reference, question: question) }
    }

    static func compute(answer: String, reference: String, question: String) -> SharedWords {
        let answerTokens = tokens(answer)
        let referenceTokens = tokens(reference)
        let tiles = tiles(answerTokens.map(\.text), referenceTokens.map(\.text), question: question)
        let answerCovered = Set(tiles.flatMap { $0.answer..<($0.answer + $0.length) })
        let referenceCovered = Set(tiles.flatMap { $0.reference..<($0.reference + $0.length) })
        let words = Set(answerCovered.map { answerTokens[$0].word })
        return SharedWords(answer: words, reference: Set(referenceCovered.map { referenceTokens[$0].word }),
                           sharedCount: words.count, answerCount: Set(answerTokens.map(\.word)).count)
    }

    /// The answer's words shared with any of the AI answers.
    public static func anyReference(answer: String, references: [String], question: String = "") -> SharedWords {
        cache.value(for: [answer, question, "\u{1}"] + references) {
            computeAny(answer: answer, references: references, question: question)
        }
    }

    static func computeAny(answer: String, references: [String], question: String) -> SharedWords {
        let answerTokens = tokens(answer)
        var covered = Set<Int>()
        for reference in references {
            let tiles = tiles(answerTokens.map(\.text), tokens(reference).map(\.text), question: question)
            tiles.forEach { covered.formUnion($0.answer..<($0.answer + $0.length)) }
        }
        let words = Set(covered.map { answerTokens[$0].word })
        return SharedWords(answer: words, reference: [], sharedCount: words.count,
                           answerCount: Set(answerTokens.map(\.word)).count)
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

    struct Tile: Hashable {
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

    /// The longest common runs first, without overlap on either side, repeated
    /// over the words still unmatched until no run is left (greedy string
    /// tiling): a run that overlaps a longer one keeps its own part. A run
    /// counts when it has two words that are not small words and is not just
    /// the question said back.
    static func tiles(_ answer: [String], _ reference: [String], question: String) -> [Tile] {
        let minimum = minimumRun
        guard answer.count >= minimum, reference.count >= minimum else { return [] }
        let questionGrams = Set(SimilaritySignal.ngrams(FillerLexicon.tokens(question), 3))
        // Words as numbers: the comparison below runs answer × reference times.
        var ids: [String: Int] = [:]
        let a = answer.map { word in ids[word] ?? { ids[word] = ids.count; return ids.count - 1 }() }
        let b = reference.map { word in ids[word] ?? { ids[word] = ids.count; return ids.count - 1 }() }
        var usedA = [Bool](repeating: false, count: a.count)
        var usedB = [Bool](repeating: false, count: b.count)
        var accepted: [Tile] = []
        var rejected = Set<Tile>()

        while true {
            var candidates: [Tile] = []
            var previous = [Int](repeating: 0, count: b.count + 1)
            var current = previous
            for i in 1...a.count {
                for j in 0...b.count { current[j] = 0 }
                if !usedA[i - 1] {
                    for j in 1...b.count where !usedB[j - 1] && a[i - 1] == b[j - 1] {
                        current[j] = previous[j - 1] + 1
                        let length = current[j]
                        let extends = i < a.count && j < b.count && !usedA[i] && !usedB[j] && a[i] == b[j]
                        if !extends, length >= minimum {
                            candidates.append(Tile(answer: i - length, reference: j - length, length: length))
                        }
                    }
                }
                swap(&previous, &current)
            }

            // Only the longest runs this pass: a shorter one must not take words
            // that a trimmed longer run needs in the next pass.
            var progress = false
            var passLength: Int?
            for tile in candidates.sorted(by: { ($0.length, -$0.answer) > ($1.length, -$1.answer) })
            where !rejected.contains(tile) {
                if let length = passLength, tile.length < length { break }
                let answerRange = tile.answer..<(tile.answer + tile.length)
                let referenceRange = tile.reference..<(tile.reference + tile.length)
                guard !answerRange.contains(where: { usedA[$0] }), !referenceRange.contains(where: { usedB[$0] }) else { continue }
                let run = Array(answer[answerRange])
                let grams = SimilaritySignal.ngrams(run, 3)
                guard run.filter({ !FillerLexicon.stopwords.contains($0) }).count >= 2,
                      questionGrams.isEmpty || !grams.allSatisfy(questionGrams.contains) else {
                    rejected.insert(tile)
                    continue
                }
                answerRange.forEach { usedA[$0] = true }
                referenceRange.forEach { usedB[$0] = true }
                accepted.append(tile)
                progress = true
                passLength = tile.length
            }
            if !progress { break }
        }
        return accepted.sorted { $0.answer < $1.answer }
    }
}

/// Remembers recent results by their input texts; safe from any thread.
final class SharedWordsCache: @unchecked Sendable {
    private var entries: [[String]: SharedWords] = [:]
    private let lock = NSLock()
    private let limit: Int

    init(limit: Int = 128) { self.limit = limit }

    func value(for key: [String], compute: () -> SharedWords) -> SharedWords {
        lock.lock()
        if let hit = entries[key] { lock.unlock(); return hit }
        lock.unlock()
        let result = compute()
        lock.lock()
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[key] = result
        lock.unlock()
        return result
    }
}

extension SharedWords {
    static let cache = SharedWordsCache()
}

