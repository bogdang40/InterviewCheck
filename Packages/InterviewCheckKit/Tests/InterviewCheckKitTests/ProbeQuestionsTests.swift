import XCTest
@testable import InterviewCheckKit

final class ProbeQuestionsTests: XCTestCase {
    private let question = "How would you design a rate limiter for a public API?"
    private let read = """
    That's a great question so I would implement a token bucket algorithm for each API key, stored in Redis so that \
    every gateway node shares the same state. When a request arrives, the gateway atomically decrements the bucket \
    using a Lua script, and if the bucket is empty we return HTTP 429 with a Retry-After header.
    """
    private let ai = """
    I would implement a token bucket algorithm for each API key, stored in Redis so that every gateway node shares the \
    same state. When a request arrives, the gateway atomically decrements the bucket using a Lua script; if the bucket \
    is empty, we return HTTP 429 with a Retry-After header.
    """

    func testProbesAskAboutWhatTheAnswerClaimed() {
        let probes = ProbeQuestions.make(answerText: read, questionText: question, aiAnswers: [ai])
        XCTAssertEqual(probes.count, 2)
        XCTAssertTrue(probes[0].hasPrefix("You mentioned \u{201C}"), probes[0])
        XCTAssertTrue(probes[1].hasPrefix("What would go wrong with \u{201C}"), probes[1])
        let terms = ProbeQuestions.keyTerms(in: read, questionText: question, aiAnswers: [ai])
        let first = terms.first?.lowercased() ?? ""
        XCTAssertTrue(["token bucket algorithm", "api key", "gateway node", "lua script", "redis"].contains { first.contains($0) },
                      "a shared, specific term comes first: \(terms)")
    }

    func testTermsFromTheQuestionAreSkipped() {
        let terms = ProbeQuestions.keyTerms(in: "A rate limiter for a public API needs a sliding window in Redis.",
                                            questionText: question)
        XCTAssertFalse(terms.contains { $0.lowercased() == "rate limiter" || $0.lowercased() == "public api" }, "\(terms)")
        XCTAssertTrue(terms.contains { $0.lowercased().contains("sliding window") || $0 == "Redis" }, "\(terms)")
    }

    func testQuestionsAboutThemGetProbesAboutTheirPart() {
        let incident = ProbeQuestions.make(
            answerText: "Last spring our checkout started timing out and I pulled traces and saw the payment client retrying without backoff.",
            questionText: "Tell me about a production incident you owned.")
        XCTAssertTrue(incident.first?.hasSuffix("What exactly was your part in that?") == true, "\(incident)")
        let motive = ProbeQuestions.make(
            answerText: "I like problems where correctness matters and I want to keep growing toward reliability work at scale.",
            questionText: "Why do you want to work on payments infrastructure?")
        XCTAssertTrue(motive.first?.hasSuffix("What have you actually done with it so far?") == true, "\(motive)")
    }

    func testVerbsBeforeAdverbsAreNotTerms() {
        let terms = ProbeQuestions.keyTerms(
            in: "I want to keep growing toward reliability work and help teams ship safely at scale.",
            questionText: "Why do you want to work on payments infrastructure?")
        XCTAssertFalse(terms.contains { $0.lowercased().contains("ship") }, "\(terms)")
        XCTAssertTrue(terms.contains { $0.lowercased() == "reliability work" }, "\(terms)")
    }

    func testNothingToAskAboutGivesNoProbes() {
        XCTAssertTrue(ProbeQuestions.make(answerText: "Um, yes, I think so, honestly.", questionText: question).isEmpty)
        XCTAssertTrue(ProbeQuestions.make(answerText: "", questionText: question).isEmpty)
    }
}
