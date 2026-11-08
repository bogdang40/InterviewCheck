import Foundation

/// The seam AccessController uses to learn whether an owner license unlocks
/// this Mac, and to install or remove one from the UI.
@MainActor
protocol OwnerLicenseGating: AnyObject {
    var deviceID: String? { get }
    var location: String { get }
    func resolve(now: Date) -> OwnerLicenseResolution
    @discardableResult func install(from fileURL: URL, now: Date) throws -> OwnerLicense
    func remove() throws
}

/// Store plus verifier plus device identity. Reads the license fresh on
/// every resolve so a file dropped next to the app is picked up by the next
/// evaluation without a relaunch.
@MainActor
final class OwnerLicenseGate: OwnerLicenseGating {
    private let store: OwnerLicenseStoring
    private let verifier: OwnerLicenseVerifier
    private let deviceIdentity: DeviceIdentifying
    private var cachedDeviceID: String??

    /// Under XCTest the default store is empty and in memory, the same
    /// convention AccessGuard and AppDelegate follow, so the suite's outcome
    /// never depends on the license issued on the machine running it and
    /// no test can remove the owner's real file.
    nonisolated static func defaultStore() -> OwnerLicenseStoring {
        TestRuntime.isRunningUnitTests ? MemoryOwnerLicenseStore() : FileOwnerLicenseStore()
    }

    /// Nonisolated so it can serve as a default argument of
    /// AccessController's initializer; it only stores its collaborators.
    nonisolated init(
        store: OwnerLicenseStoring = OwnerLicenseGate.defaultStore(),
        verifier: OwnerLicenseVerifier = OwnerLicenseVerifier(),
        deviceIdentity: DeviceIdentifying = IOKitDeviceIdentity()
    ) {
        self.store = store
        self.verifier = verifier
        self.deviceIdentity = deviceIdentity
    }

    /// Read once per process; the hardware identifier does not change.
    var deviceID: String? {
        if let cachedDeviceID { return cachedDeviceID }
        let value = deviceIdentity.deviceID()
        cachedDeviceID = .some(value)
        return value
    }

    var location: String { store.location }

    func resolve(now: Date) -> OwnerLicenseResolution {
        guard let data = store.load() else { return .none }
        guard let deviceID else { return .invalid(.deviceUnavailable) }
        do {
            return .valid(try verifier.verify(data, deviceID: deviceID, now: now))
        } catch let error as OwnerLicenseError {
            return .invalid(error)
        } catch {
            return .invalid(.malformed)
        }
    }

    /// Verifies before storing, so a bad file never replaces a good one.
    @discardableResult
    func install(from fileURL: URL, now: Date) throws -> OwnerLicense {
        let data = try Data(contentsOf: fileURL)
        guard let deviceID else { throw OwnerLicenseError.deviceUnavailable }
        let license = try verifier.verify(data, deviceID: deviceID, now: now)
        try store.save(data)
        return license
    }

    func remove() throws {
        try store.clear()
    }
}
