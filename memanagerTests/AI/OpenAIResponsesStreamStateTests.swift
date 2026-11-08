import XCTest
@testable import memanager

final class OpenAIResponsesStreamStateTests: XCTestCase {
    func testDoneIsSuppressedForItemThatEmittedDeltas() {
        var state = OpenAIResponsesStreamState()
        state.registerDeltaEmitted(itemKey: "msg_1#0")

        XCTAssertTrue(state.shouldSuppressDoneText(itemKey: "msg_1#0"))
    }

    func testDoneIsEmittedForItemWithoutDeltas() {
        var state = OpenAIResponsesStreamState()
        state.registerDeltaEmitted(itemKey: "msg_1#0")

        XCTAssertFalse(state.shouldSuppressDoneText(itemKey: "msg_2#0"))
    }

    func testDoneWithoutKeyIsSuppressedAfterAnyDelta() {
        var state = OpenAIResponsesStreamState()
        state.registerDeltaEmitted(itemKey: "msg_1#0")

        XCTAssertTrue(state.shouldSuppressDoneText(itemKey: nil))
    }

    func testKeyedDoneIsSuppressedAfterKeylessDeltas() {
        var state = OpenAIResponsesStreamState()
        state.registerDeltaEmitted(itemKey: nil)

        XCTAssertTrue(state.shouldSuppressDoneText(itemKey: "msg_1#0"))
    }

    func testDoneIsEmittedWhenNoDeltasWereSeen() {
        let state = OpenAIResponsesStreamState()

        XCTAssertFalse(state.shouldSuppressDoneText(itemKey: "msg_1#0"))
        XCTAssertFalse(state.shouldSuppressDoneText(itemKey: nil))
    }

    func testRegisteringDeltaMarksVisibleText() {
        var state = OpenAIResponsesStreamState()
        XCTAssertFalse(state.hasVisibleText)

        state.registerDeltaEmitted(itemKey: "msg_1#0")

        XCTAssertTrue(state.hasVisibleText)
    }
}
