import Foundation
import InterviewCheckKit

/// A short scripted interview for Help › Demo Interview: one honest answer,
/// one read from an AI tool, one in between. Times are seconds from start.
enum DemoScript {
    struct Exchange {
        let question: String
        let questionStart: TimeInterval
        /// Pause after the question before the candidate's first word.
        let pause: TimeInterval
        /// The candidate's words; "...N" inserts N seconds of silence.
        let answer: String
        let wordSeconds: TimeInterval
        /// What the AI tools say (the reading answer follows the first one).
        let aiAnswers: [String]
    }

    static let exchanges: [Exchange] = [
        Exchange(
            question: "Tell me about a production incident you owned.",
            questionStart: 1, pause: 0.8,
            answer: """
            Um, so last spring our checkout started timing out ...1.2 and I was on call. I, I first thought it was the \
            database, uh, but the graphs looked fine ...1.5 so I pulled traces and saw the payment client retrying \
            without backoff. Um, we hot-fixed the retry and then, honestly, spent a week adding a circuit breaker.
            """,
            wordSeconds: 0.33,
            aiAnswers: [
                "At my previous company I owned a Sev-1 incident where checkout latency spiked. I coordinated the response, identified a misconfigured retry policy through distributed tracing, implemented exponential backoff with jitter, and led a blameless postmortem that introduced circuit breakers across services.",
                "Say first: \"I owned a checkout outage caused by aggressive retries.\" - Traced it with distributed tracing - Added backoff with jitter - Ran a blameless postmortem - Added circuit breakers",
            ]),
        Exchange(
            question: "How would you design a rate limiter for a public API?",
            questionStart: 30, pause: 2.1,
            answer: """
            That's a great question so ...3.9 I would implement a token bucket algorithm for each API key, stored in \
            Redis so that every gateway node shares the same state. Each bucket refills at a fixed rate and allows \
            short bursts up to its capacity. When a request arrives, the gateway atomically decrements the bucket \
            using a Lua script, and if the bucket is empty we return HTTP 429 with a Retry-After header.
            """,
            wordSeconds: 0.27,
            aiAnswers: [
                "I would implement a token bucket algorithm for each API key, stored in Redis so that every gateway node shares the same state. Each bucket refills at a fixed rate and allows short bursts up to its capacity. When a request arrives, the gateway atomically decrements the bucket using a Lua script; if the bucket is empty, we return HTTP 429 with a Retry-After header.",
                "Say first: \"A token bucket per API key, shared in Redis.\" - Refill at a fixed rate, allow bursts - Atomic decrement with a Lua script - 429 with Retry-After when empty",
            ]),
        Exchange(
            question: "Why do you want to work on payments infrastructure?",
            questionStart: 70, pause: 1.6,
            answer: """
            I like problems where correctness really matters ...1.0 and payments is, you know, the purest version of \
            that. I want to keep growing toward reliability work and help teams ship safely at scale.
            """,
            wordSeconds: 0.3,
            aiAnswers: [
                "I'm drawn to payments infrastructure because correctness and reliability matter enormously. I want to grow toward reliability engineering and help teams ship safely at scale while working on systems that directly affect customers' trust.",
            ]),
    ]

    /// Every word of the script on the demo clock.
    static func words(origin: TimeInterval) -> [(word: TimedWord, markAfter: Bool)] {
        var result: [(TimedWord, Bool)] = []
        for exchange in exchanges {
            let questionWords = timed(exchange.question, side: .interviewer, start: origin + exchange.questionStart, seconds: 0.32)
            result += questionWords.enumerated().map { ($1, $0 == questionWords.count - 1) }
            let answerStart = (questionWords.last?.end ?? origin) + exchange.pause
            result += timed(exchange.answer, side: .candidate, start: answerStart, seconds: exchange.wordSeconds).map { ($0, false) }
        }
        return result
    }

    static func timed(_ text: String, side: InterviewSide, start: TimeInterval, seconds: TimeInterval) -> [TimedWord] {
        var clock = start
        var words: [TimedWord] = []
        for token in text.split(separator: " ").map(String.init) {
            if token.hasPrefix("..."), let pause = Double(token.dropFirst(3)) {
                clock += pause
                continue
            }
            words.append(TimedWord(side: side, speakerIndex: side == .candidate ? 0 : nil, text: token, start: clock,
                                   end: clock + seconds * 0.85, confidence: 0.95, isFiller: FillerLexicon.isFiller(token)))
            clock += seconds
        }
        return words
    }

    /// The canned AI answer for a question and a run.
    static func aiAnswer(question: String, runIndex: Int) -> String {
        guard let exchange = exchanges.first(where: { question.contains($0.question.prefix(20)) }) else {
            return "A strong answer would explain the approach, the trade-offs and the result."
        }
        return exchange.aiAnswers[runIndex % exchange.aiAnswers.count]
    }
}
