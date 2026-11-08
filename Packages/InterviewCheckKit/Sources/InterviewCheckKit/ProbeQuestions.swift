import Foundation
import NaturalLanguage

/// Follow-up questions made from the answer itself, with no AI key. A
/// candidate reading from a tool can repeat a claim; explaining it, saying
/// what would break, or why not something else is where reading breaks
/// down. Terms an AI answer also used come first: they are the likeliest
/// to have been read.
public enum ProbeQuestions {
    public static func make(answerText: String, questionText: String, aiAnswers: [String] = [], limit: Int = 2) -> [String] {
        let templates: [(String) -> String] = isAboutMotives(questionText) ? [
            { "You said \u{201C}\($0)\u{201D}. What have you actually done with it so far?" },
            { "What part of \u{201C}\($0)\u{201D} would you enjoy least?" },
        ] : isAboutThem(questionText) ? [
            { "You mentioned \u{201C}\($0)\u{201D}. What exactly was your part in that?" },
            { "Looking back at \u{201C}\($0)\u{201D}, what would you do differently now?" },
            { "Who disagreed with you about \u{201C}\($0)\u{201D}, and what did they say?" },
        ] : [
            { "You mentioned \u{201C}\($0)\u{201D}. Walk me through how that works, step by step." },
            { "What would go wrong with \u{201C}\($0)\u{201D} here, and how would you find out?" },
            { "Why \u{201C}\($0)\u{201D} and not something else? What did you rule out?" },
        ]
        let terms = keyTerms(in: answerText, questionText: questionText, aiAnswers: aiAnswers)
        return zip(terms.prefix(min(limit, templates.count)), templates).map { term, template in template(term) }
    }

    /// Noun phrases from the answer, best to ask about first: terms an AI
    /// answer also used, longer terms, and not the question's own words.
    public static func keyTerms(in text: String, questionText: String, aiAnswers: [String] = []) -> [String] {
        let questionWords = Set(FillerLexicon.tokens(questionText)).subtracting(FillerLexicon.stopwords)
        let aiText = " " + aiAnswers.map { FillerLexicon.tokens($0).joined(separator: " ") }.joined(separator: " | ") + " "
        var ranked: [(score: Int, order: Int, phrase: String)] = []
        var seen = Set<String>()
        for (order, raw) in nounPhrases(text).enumerated() {
            // "many servers" asks about servers; "great question" about nothing.
            var shown = raw.split(separator: " ").map(String.init)
            while let first = shown.first, vague.contains(FillerLexicon.normalize(first)) { shown.removeFirst() }
            let words = FillerLexicon.tokens(shown.joined(separator: " "))
            let key = words.joined(separator: " ")
            guard !words.isEmpty, words.count <= 4, !words.contains(where: { $0 == "question" || $0 == "questions" }),
                  seen.insert(key).inserted else { continue }
            let content = words.filter { !FillerLexicon.stopwords.contains($0) && !generic.contains($0) }
            guard !content.isEmpty, !content.allSatisfy(questionWords.contains),
                  // "2019" alone is not something to explain.
                  !content.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { continue }
            if words.count == 1, words[0].count < 4 { continue }
            var score = 0
            if aiText.contains(" \(key) ") { score += 3 }
            if words.count >= 2 { score += 1 }
            if words.count >= 3 { score += 1 }
            if content.contains(where: questionWords.contains) { score -= 2 }
            ranked.append((score, order, shown.joined(separator: " ")))
        }
        return ranked.sorted { ($0.score, -$0.order) > ($1.score, -$1.order) }.map(\.phrase)
    }

    /// Questions about the candidate's own past or motives ("Tell me about a
    /// time…", "Why do you want…") get probes about their part, not mechanics.
    static func isAboutThem(_ question: String) -> Bool {
        let text = " " + FillerLexicon.tokens(question).joined(separator: " ") + " "
        return [" tell me about ", " describe a ", " describe the ", " why do you ", " why did you ", " a time ",
                " what did you ", " give me an example ", " have you ever ", " your biggest ", " you owned "]
            .contains { text.contains($0) }
    }

    /// "Why do you want…", "What interests you…": probes about what they did, not mechanics.
    static func isAboutMotives(_ question: String) -> Bool {
        let text = " " + FillerLexicon.tokens(question).joined(separator: " ") + " "
        return [" why do you want ", " why are you interested ", " what interests you ", " what attracts you ",
                " why this ", " why us ", " what excites you ", " what motivates you "].contains { text.contains($0) }
    }

    /// Nouns that are everywhere, so not worth a question on their own.
    static let generic: Set<String> = [
        "thing", "things", "way", "ways", "lot", "time", "times", "problem", "problems", "answer",
        "people", "something", "anything", "everything", "nothing", "bit", "case", "cases", "example", "part",
        "parts", "point", "end", "fact", "idea", "stuff", "approach", "solution", "issue", "issues", "work", "job",
        "role", "place", "number", "kind", "sort", "minute", "minutes", "hour", "hours", "day", "days", "week",
        "weeks", "month", "months", "year", "years", "spring", "summer", "fall", "autumn", "winter", "morning",
        "night", "today", "yesterday", "tomorrow", "team", "teams", "company", "companies", "people", "person",
        "version", "versions", "customer", "customers", "user", "users",
    ]

    /// Leading words that make a phrase vaguer, not more specific.
    static let vague: Set<String> = [
        "many", "few", "last", "next", "same", "other", "different", "great", "good", "big", "small", "whole",
        "real", "several", "certain", "various", "such", "own", "new", "old", "first", "second", "main", "much",
    ]

    /// "teams", "scales"; not "Redis", "class", "status", "stateless".
    static func looksPlural(_ word: String) -> Bool {
        let lower = word.lowercased()
        return lower.hasSuffix("s") && !["ss", "us", "is", "less"].contains { lower.hasSuffix($0) }
    }

    /// Runs of adjectives and nouns ending in a noun ("token bucket",
    /// "public API", "HTTP 429"), in the order they appear.
    static func nounPhrases(_ text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var phrases: [String] = []
        var run: [(word: String, isNoun: Bool)] = []
        func flush(before tag: NLTag? = nil, word next: String = "") {
            // "node shares the state": a verb taken for a plural noun.
            if [.determiner, .pronoun].contains(tag), run.count >= 2, run.last?.word.hasSuffix("s") == true {
                run.removeLast()
            }
            // "teams ship safely", "cache scales horizontally": subject and verb, the verb
            // taken for a noun. ("token bucket heavily", "payments service then" keep their nouns.)
            if tag == .adverb, run.count >= 2, next.lowercased().hasSuffix("ly"),
               looksPlural(run[run.count - 2].word) != looksPlural(run[run.count - 1].word) {
                run.removeLast()
            }
            while let last = run.last, !last.isNoun { run.removeLast() }
            if !run.isEmpty { phrases.append(run.map(\.word).joined(separator: " ")) }
            run = []
        }
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let word = String(text[range])
            switch tag {
            case .noun?, .number?:
                run.append((word, true))
            case .otherWord? where word.first?.isUppercase == true:
                run.append((word, true))
            case .adjective?:
                run.append((word, false))
            default:
                flush(before: tag, word: word)
            }
            return true
        }
        flush()
        return phrases
    }
}
