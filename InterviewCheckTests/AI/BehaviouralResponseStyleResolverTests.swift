import XCTest
@testable import InterviewCheck

final class BehaviouralResponseStyleResolverTests: XCTestCase {
    private let resolver = BehaviouralResponseStyleResolver()

    func testDefaultsToStarPlusWhenNoExceptionSignals() {
        let decision = resolver.resolve(
            question: "Tell me about a time you disagreed with a teammate and what you did.",
            transcript: "",
            questionSource: .manual
        )

        XCTAssertEqual(decision, .starPlus)
    }

    func testAutoQuestionSourceAlwaysUsesConversationalException() {
        let decision = resolver.resolve(
            question: "ignored",
            transcript: "Me: ignored",
            questionSource: .auto
        )

        XCTAssertEqual(
            decision,
            .conversational(.autoSideQuestion)
        )
    }

    func testProbeCueUsesConversationalException() {
        let decision = resolver.resolve(
            question: "Can you elaborate on what your exact role was there?",
            transcript: "",
            questionSource: .manual
        )

        XCTAssertEqual(
            decision,
            .conversational(.probeQuestion)
        )
    }

    func testSimpleIntroCueUsesConversationalException() {
        let decision = resolver.resolve(
            question: "Tell me about yourself.",
            transcript: "",
            questionSource: .manual
        )

        XCTAssertEqual(
            decision,
            .conversational(.simpleIntroQuestion)
        )
    }

    func testTranscriptFallbackUsesLatestUtteranceWhenQuestionIsEmpty() {
        let decision = resolver.resolve(
            question: "",
            transcript: """
            Me: I improved API latency by 20%.
            Speaker 2: Can you elaborate on the tradeoffs you made?
            """,
            questionSource: .none
        )

        XCTAssertEqual(
            decision,
            .conversational(.probeQuestion)
        )
    }

    func testWordBoundaryAvoidsFalsePositiveForStrengthsPrefix() {
        let decision = resolver.resolve(
            question: "I used a strengthsfinders workshop with my team.",
            transcript: "",
            questionSource: .manual
        )

        XCTAssertEqual(decision, .starPlus)
    }
}
