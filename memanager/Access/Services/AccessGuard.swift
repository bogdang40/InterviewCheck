import Foundation

/// Tiny guard used by hot paths that spend model calls.
@MainActor
enum AccessGuard {
    static let deniedMessage = "Sign in with an active subscription to use \(AppBrand.name)."

    static func allows(controller: AccessController? = nil) -> Bool {
        #if DEBUG
        if TestRuntime.isRunningUnitTests { return true }
        #endif
        return (controller ?? .shared).isAllowed
    }
}
