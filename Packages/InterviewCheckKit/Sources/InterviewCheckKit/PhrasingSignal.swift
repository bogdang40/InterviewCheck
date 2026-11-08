import Foundation

/// What wording says about an answer: phrases language models write and
/// people rarely say out loud ("furthermore", "it's worth noting"), STAR
/// labels read out ("situation … task … action … result"), and announced
/// lists ("there are three key …", "first … second … finally").
///
/// Works without any AI key. It only speaks up when it finds something:
/// an answer without these words is not evidence of anything.
public struct PhrasingResult: Equatable {
    /// 0 ... 1.
    public let score: Double
    /// What was found, as it would be said, strongest first.
    public let tells: [String]
    public let wordCount: Int

    public init(score: Double, tells: [String], wordCount: Int) {
        self.score = score
        self.tells = tells
        self.wordCount = wordCount
    }

    public static let none = PhrasingResult(score: 0, tells: [], wordCount: 0)
}

public enum PhrasingSignal {
    /// Answers shorter than this are not judged on wording.
    public static let minimumWords = 25
    /// Below this the wording is not mentioned and does not count.
    public static let countsFrom = 0.3

    /// Rare in speech, common in model output: (normalized words, as said).
    static let strong: [(String, String)] = [
        ("delve", "delve"), ("delving", "delving"), ("furthermore", "furthermore"), ("moreover", "moreover"),
        ("additionally", "additionally"), ("in conclusion", "in conclusion"), ("in summary", "in summary"),
        ("to summarize", "to summarize"), ("its worth noting", "it's worth noting"),
        ("it is worth noting", "it is worth noting"), ("its important to note", "it's important to note"),
        ("it is important to note", "it is important to note"), ("plays a crucial role", "plays a crucial role"),
        ("plays a pivotal role", "plays a pivotal role"), ("a testament to", "a testament to"),
        ("tapestry", "tapestry"), ("multifaceted", "multifaceted"), ("paramount", "paramount"),
        ("pivotal", "pivotal"), ("holistic", "holistic"), ("seamlessly", "seamlessly"), ("fostering", "fostering"),
        ("the realm of", "the realm of"), ("underscores", "underscores"), ("ever evolving", "ever-evolving"),
        ("fast paced environment", "fast-paced environment"), ("proven track record", "proven track record"),
        ("im passionate about", "I'm passionate about"), ("i am passionate about", "I am passionate about"),
        ("aligns with my", "aligns with my"), ("aligns perfectly", "aligns perfectly"),
    ]

    /// Common in tech talk too, so they count for a third.
    static let mild: [(String, String)] = [
        ("leverage", "leverage"), ("leveraging", "leveraging"), ("leveraged", "leveraged"),
        ("utilize", "utilize"), ("utilizing", "utilizing"), ("utilized", "utilized"),
        ("facilitate", "facilitate"), ("robust", "robust"), ("comprehensive", "comprehensive"),
        ("streamline", "streamline"), ("streamlined", "streamlined"), ("showcase", "showcase"),
        ("nuanced", "nuanced"), ("landscape", "landscape"), ("crucial", "crucial"), ("ensuring", "ensuring"),
    ]

    static let strongWeight = 1.0
    static let mildWeight = 0.35
    static let listWeight = 0.45

    public static func evaluate(answerText: String) -> PhrasingResult {
        let tokens = FillerLexicon.tokens(answerText)
        guard tokens.count >= minimumWords else { return PhrasingResult(score: 0, tells: [], wordCount: tokens.count) }

        var weight = 0.0
        var found: [(Double, String)] = []
        // Longest phrases first; a word inside a matched phrase is not counted again
        // ("plays a pivotal role" is one tell, not two with "pivotal").
        let phrases = (strong.map { ($0, strongWeight) } + mild.map { ($0, mildWeight) })
            .map { (words: $0.0.0.split(separator: " ").map(String.init), said: $0.0.1, weight: $0.1) }
            .sorted { $0.words.count > $1.words.count }
        var used = Set<Int>()
        for phrase in phrases {
            let count = claim(phrase.words, in: tokens, used: &used)
            guard count > 0 else { continue }
            weight += phrase.weight * Double(count)
            found.append((phrase.weight, count > 1 ? "\(phrase.said) (\(count)\u{00D7})" : phrase.said))
        }
        if let list = announcedList(tokens) {
            weight += listWeight
            found.append((listWeight, list))
        }
        if let order = ordinalList(tokens) {
            weight += listWeight
            found.append((listWeight, order))
        }

        // Coaches teach STAR too, so labels said aloud are one clue, not proof.
        if let star = starLabels(tokens) {
            weight += strongWeight
            found.append((strongWeight + 0.1, star))
        }
        // Per 100 words, never fewer: one tell in a short answer is one tell, not a density.
        let perHundred = weight / Double(max(tokens.count, 100)) * 100
        let score = min(max((perHundred - 0.6) / 2.4, 0), 1)
        let tells = found.sorted { $0.0 > $1.0 }.map(\.1)
        return PhrasingResult(score: score, tells: score > 0 ? tells : [], wordCount: tokens.count)
    }

    /// Counts the phrase where none of its words is already part of another tell.
    static func claim(_ phrase: [String], in tokens: [String], used: inout Set<Int>) -> Int {
        guard !phrase.isEmpty, tokens.count >= phrase.count else { return 0 }
        var count = 0
        var index = 0
        while index + phrase.count <= tokens.count {
            let range = index..<(index + phrase.count)
            if used.isDisjoint(with: range), Array(tokens[range]) == phrase {
                used.formUnion(range)
                count += 1
                index += phrase.count
            } else {
                index += 1
            }
        }
        return count
    }

    /// "situation … task … action … result" said in that order.
    static func starLabels(_ tokens: [String]) -> String? {
        let labels: [Set<String>] = [["situation"], ["task"], ["action", "actions"], ["result", "results"]]
        var position = 0
        for label in labels {
            guard position < tokens.count, let found = tokens[position...].firstIndex(where: label.contains) else { return nil }
            position = found + 1
        }
        return "situation \u{2026} task \u{2026} action \u{2026} result"
    }

    /// "there are three key …": a count announced before the points.
    static func announcedList(_ tokens: [String]) -> String? {
        let counts: Set<String> = ["two", "three", "four", "five", "several"]
        let kinds: Set<String> = ["key", "main", "primary", "important", "core", "critical"]
        for index in tokens.indices.dropLast(3) where tokens[index] == "there" && ["are", "were"].contains(tokens[index + 1]) {
            if counts.contains(tokens[index + 2]), kinds.contains(tokens[index + 3]) {
                return "there are \(tokens[index + 2]) \(tokens[index + 3]) \u{2026}"
            }
        }
        return nil
    }

    /// "first … second … finally" (or "firstly … secondly … lastly").
    static func ordinalList(_ tokens: [String]) -> String? {
        let steps: [Set<String>] = [["first", "firstly"], ["second", "secondly"], ["third", "thirdly", "finally", "lastly"]]
        var position = 0
        var said: [String] = []
        for step in steps {
            guard position < tokens.count, let found = tokens[position...].firstIndex(where: step.contains) else { return nil }
            said.append(tokens[found])
            position = found + 1
        }
        return said.joined(separator: " \u{2026} ")
    }
}
