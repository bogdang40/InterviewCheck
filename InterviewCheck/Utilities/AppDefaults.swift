import Foundation

/// The app's preference boundary. Hosted XCTest runs use their own suite so
/// constructing live stores or rendering controls cannot change app settings.
enum AppDefaults {
    static let standard: UserDefaults = {
        guard TestRuntime.isRunningUnitTests else { return UserDefaults.standard }
        let suiteName = "com.interviewcheck.tests.\(TestRuntime.runIdentifier)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated test preferences")
        }
        return defaults
    }()
}
