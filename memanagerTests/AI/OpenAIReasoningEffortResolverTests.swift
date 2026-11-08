import XCTest
@testable import memanager

final class OpenAIReasoningEffortResolverTests: XCTestCase {
    func testGPT54SupportsExtendedReasoningEfforts() {
        XCTAssertEqual(
            OpenAIReasoningEffortResolver.supportedEfforts(for: "gpt-5.4"),
            [.none, .low, .medium, .high, .xhigh]
        )
        XCTAssertEqual(
            OpenAIReasoningEffortResolver.defaultEffort(for: "gpt-5.4"),
            OpenAIReasoningEffort.none
        )
    }

    func testGPT52CodexSupportsExtendedReasoningEfforts() {
        XCTAssertEqual(
            OpenAIReasoningEffortResolver.supportedEfforts(for: "gpt-5.2-codex"),
            [.none, .low, .medium, .high, .xhigh]
        )
        XCTAssertEqual(
            OpenAIReasoningEffortResolver.defaultEffort(for: "gpt-5.2-codex"),
            OpenAIReasoningEffort.none
        )
    }

    func testGPT5NormalizesUnsupportedEffortToOfficialDefault() {
        let resolved = OpenAIReasoningEffortResolver.resolve(
            storedEffort: .xhigh,
            for: "gpt-5",
            logContext: "test"
        )

        XCTAssertEqual(resolved, .medium)
    }
}
