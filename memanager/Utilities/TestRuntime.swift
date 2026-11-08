import Foundation

/// Single place production code may consult to detect an XCTest run, so the
/// environment sniff never spreads through feature code.
enum TestRuntime {
    // Environment markers exist before the test bundle initializes. The class
    // fallback covers hosts that load XCTest without a configuration-file key.
    static let isRunningUnitTests = detectsUnitTests(
        environment: ProcessInfo.processInfo.environment,
        hasXCTestClass: NSClassFromString("XCTestCase") != nil
    )

    static let runIdentifier = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
    static let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("memanager-tests-\(runIdentifier)", isDirectory: true)

    static func detectsUnitTests(environment: [String: String], hasXCTestClass: Bool) -> Bool {
        environment["MEMANAGER_TEST_PROCESS"] == "1" || hasXCTestClass
            || ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { environment[$0] != nil }
    }
}
