import XCTest
@testable import memanager

final class QuickAssistToolAvailabilityTests: XCTestCase {
    func testAvailableHelpTextIncludesRootLabelAndPath() {
        let availability = QuickAssistToolAvailability.available(
            root: ProjectToolRootDescriptor(rootName: "Mariana", displayPath: "/Users/abekhadra/Desktop/Mariana")
        )

        XCTAssertTrue(availability.helpText.contains("Mariana"))
        XCTAssertTrue(availability.helpText.contains("/Users/abekhadra/Desktop/Mariana"))
    }

    func testRootMismatchHelpTextIncludesBoundAndLiveRoots() {
        let availability = QuickAssistToolAvailability.rootMismatch(
            boundRoot: ProjectToolRootDescriptor(rootName: "Mariana", displayPath: "/Users/abekhadra/Desktop/Mariana"),
            liveRootPath: "/Users/abekhadra/Desktop/Container 3"
        )

        XCTAssertTrue(availability.helpText.contains("/Users/abekhadra/Desktop/Mariana"))
        XCTAssertTrue(availability.helpText.contains("/Users/abekhadra/Desktop/Container 3"))
        XCTAssertEqual(availability.disabledLabel, "Root mismatch")
    }

    func testUnsupportedProviderHelpTextMentionsProviderAndBoundRoot() {
        let availability = QuickAssistToolAvailability.unsupportedProvider(
            providerDisplayName: "Azure OpenAI",
            root: ProjectToolRootDescriptor(rootName: "Mariana", displayPath: "/Users/abekhadra/Desktop/Mariana")
        )

        XCTAssertTrue(availability.helpText.contains("Azure OpenAI"))
        XCTAssertTrue(availability.helpText.contains("/Users/abekhadra/Desktop/Mariana"))
        XCTAssertEqual(availability.disabledLabel, "Provider unsupported")
    }
}
