import XCTest
@testable import InterviewCheckKit

final class SharedWordsTests: XCTestCase {
    private let ai = "I would implement a token bucket algorithm for each API key, stored in Redis so that every gateway node shares the same state. When the bucket is empty we return HTTP 429 with a Retry-After header."

    func testReadAnswerIsAlmostAllShared() throws {
        let answer = "That's a great question so I would implement a token bucket algorithm for each API key stored in Redis, so that every gateway node shares the same state. When the bucket is empty we return HTTP 429 with a Retry After header."
        let shared = SharedWords.find(answer: answer, reference: ai, question: "How would you design a rate limiter for a public API?")
        XCTAssertGreaterThan(shared.coverage, 0.8)
        let words = answer.split(whereSeparator: \.isWhitespace).map(String.init)
        // The stall at the start is not shared; the answer itself is.
        XCTAssertFalse(shared.answer.contains(0), "\"That's\" is not in the AI answer")
        XCTAssertTrue(shared.answer.contains(try XCTUnwrap(words.firstIndex(of: "token"))))
        XCTAssertTrue(shared.answer.contains(try XCTUnwrap(words.firstIndex(of: "header."))))
        let referenceWords = ai.split(whereSeparator: \.isWhitespace).count
        XCTAssertGreaterThan(Double(shared.reference.count) / Double(referenceWords), 0.8)
        XCTAssertEqual(shared.summary, "\(shared.sharedCount) of \(shared.answerCount) words appear word for word in an AI answer")
    }

    func testOwnWordsShareNothing() {
        let answer = "Um, so I'd probably put a counter per customer in Redis and, uh, reject them once they go over, maybe with a sliding window."
        let shared = SharedWords.find(answer: answer, reference: ai)
        XCTAssertEqual(shared, SharedWords(answer: [], reference: [], sharedCount: 0, answerCount: shared.answerCount))
        XCTAssertNil(shared.summary)
    }

    func testSmallWordRunsDoNotCount() {
        // "and then I would" is four words in a row in both, but only small words.
        let shared = SharedWords.find(answer: "and then I would rewrite everything myself", reference: "First we measure, and then I would profile it")
        XCTAssertEqual(shared.sharedCount, 0)
    }

    func testQuestionSaidBackDoesNotCount() {
        let question = "How would you design a rate limiter for a public API?"
        let shared = SharedWords.find(answer: "So how would you design a rate limiter, okay, let me think",
                                      reference: "To design a rate limiter for a public API, start with the clients.",
                                      question: question)
        XCTAssertEqual(shared.sharedCount, 0)
    }

    func testFillersDoNotBreakARun() {
        let shared = SharedWords.find(answer: "we keep a token (um) bucket per API key in Redis",
                                      reference: "Keep a token bucket per API key in Redis.")
        XCTAssertEqual(shared.answerCount, 10)
        XCTAssertEqual(shared.sharedCount, 9)
        XCTAssertFalse(shared.answer.contains(4), "the filler itself is not highlighted")
    }

    func testAnyReferenceUnitesTheMatches() {
        let answer = "a token bucket for each API key and a blameless postmortem with circuit breakers everywhere"
        let union = SharedWords.anyReference(answer: answer, references: [
            "Use a token bucket for each API key.",
            "Run a blameless postmortem with circuit breakers.",
        ])
        let first = SharedWords.find(answer: answer, reference: "Use a token bucket for each API key.")
        XCTAssertGreaterThan(union.sharedCount, first.sharedCount)
        XCTAssertTrue(union.answer.isSuperset(of: first.answer))
        XCTAssertTrue(union.reference.isEmpty)
    }

    func testWordRangesSplitOnAnyWhitespace() {
        let text = "  one two\n\nthree\tfour "
        XCTAssertEqual(SharedWords.wordRanges(text).map { String(text[$0]) }, ["one", "two", "three", "four"])
        XCTAssertTrue(SharedWords.wordRanges("").isEmpty)
    }

    func testRepeatedPhraseIsMatchedOnce() {
        let shared = SharedWords.find(answer: "circuit breakers across all services and circuit breakers across all services",
                                      reference: "We added circuit breakers across all services.")
        XCTAssertEqual(shared.sharedCount, 5)
        XCTAssertEqual(shared.reference.count, 5)
    }
}

final class SharedWordsHighlightTests: XCTestCase {
    func testNeighbouringWordsBecomeOneRange() {
        let text = "we keep a token (um) bucket per key, then panic"
        let ranges = SharedWords.highlightRanges(text, words: [2, 3, 5, 6, 7, 9])
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["a token (um) bucket per key,", "panic"])
    }

    func testNothingSharedHighlightsNothing() {
        XCTAssertTrue(SharedWords.highlightRanges("one two three", words: []).isEmpty)
        XCTAssertEqual(SharedWords.highlightRanges("one two three", words: [2]).map { "one two three"[$0] }, ["three"])
    }
}
