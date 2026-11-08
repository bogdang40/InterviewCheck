import Foundation

/// Where the owner license bytes live. The bytes are a signed public
/// artifact bound to this Mac, so a plain file next to the deployed app is
/// enough; the signing tool writes straight to the default location.
protocol OwnerLicenseStoring {
    var location: String { get }
    func load() -> Data?
    func save(_ data: Data) throws
    func clear() throws
}

struct FileOwnerLicenseStore: OwnerLicenseStoring {
    static let defaultURL: URL = {
        if TestRuntime.isRunningUnitTests {
            return TestRuntime.temporaryDirectory.appendingPathComponent("owner.license")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".memanager", isDirectory: true)
            .appendingPathComponent("owner.license")
    }()

    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL = FileOwnerLicenseStore.defaultURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    var location: String { fileURL.path }

    func load() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    func save(_ data: Data) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}

/// In memory store for tests and previews.
final class MemoryOwnerLicenseStore: OwnerLicenseStoring {
    var data: Data?
    let location = "memory"

    init(data: Data? = nil) {
        self.data = data
    }

    func load() -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
    func clear() throws { data = nil }
}
