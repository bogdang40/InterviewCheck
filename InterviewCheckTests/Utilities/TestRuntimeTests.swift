import XCTest
@testable import InterviewCheck

final class TestRuntimeTests: XCTestCase {
    func testDetectsXCTestEnvironmentBeforeTestClassesLoad() {
        XCTAssertTrue(TestRuntime.detectsUnitTests(environment: ["INTERVIEWCHECK_TEST_PROCESS": "1"],
                                                  hasXCTestClass: false))
        XCTAssertFalse(TestRuntime.detectsUnitTests(environment: ["INTERVIEWCHECK_TEST_PROCESS": "0"],
                                                   hasXCTestClass: false))
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
            XCTAssertTrue(TestRuntime.detectsUnitTests(environment: [key: "test-run"], hasXCTestClass: false))
        }
    }

    func testLoadedXCTestClassIsAFallbackWithoutEnvironmentMarkers() {
        XCTAssertTrue(TestRuntime.detectsUnitTests(environment: [:], hasXCTestClass: true))
        XCTAssertFalse(TestRuntime.detectsUnitTests(environment: [:], hasXCTestClass: false))
        XCTAssertFalse(TestRuntime.detectsUnitTests(environment: ["INTERVIEWCHECK_RENDER_DIR": "/tmp/render"],
                                                    hasXCTestClass: false))
    }

    func testCurrentTestHostHasAStableTemporaryNamespace() {
        XCTAssertTrue(TestRuntime.isRunningUnitTests)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = TestRuntime.temporaryDirectory.resolvingSymlinksInPath()
        XCTAssertEqual(directory.deletingLastPathComponent(), root)
        XCTAssertEqual(directory.lastPathComponent, "interviewcheck-tests-\(TestRuntime.runIdentifier)")
        XCTAssertTrue(TestRuntime.runIdentifier.hasPrefix("\(ProcessInfo.processInfo.processIdentifier)-"))
    }
}
