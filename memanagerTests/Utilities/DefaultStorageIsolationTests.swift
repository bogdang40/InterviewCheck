import XCTest
@testable import memanager

final class DefaultStorageIsolationTests: XCTestCase {
    func testDefaultWritableFileLocationsStayInsideTestDirectory() throws {
        _ = try XCTUnwrap(TestRuntime.isRunningUnitTests ? true : nil,
                          "Refusing storage operations outside an isolated test host")
        let root = TestRuntime.temporaryDirectory.standardizedFileURL.path + "/"
        let locations = [
            FileSystemModeAttachmentStorage.shared.rootDirectory,
            SessionModeSnapshotAssetStorage.shared.rootDirectory,
            FileOwnerLicenseStore.defaultURL,
            ToolOutputCacheDir.shared.baseURL,
            WorkspaceFolderProvisioner.defaultRootDirectory()
        ]
        for location in locations {
            _ = try XCTUnwrap(location.standardizedFileURL.path.hasPrefix(root) ? location : nil,
                              "Refusing a storage path outside the test directory: \(location.path)")
        }
        let modeID = UUID()
        let directory = try FileSystemModeAttachmentStorage.shared.attachmentsDirectory(for: modeID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(directory.standardizedFileURL.path.hasPrefix(root))
        try FileSystemModeAttachmentStorage.shared.removeDirectory(modeID: modeID)
    }

    func testDefaultKeychainOperationsUseProcessMemory() throws {
        _ = try XCTUnwrap(TestRuntime.isRunningUnitTests ? true : nil,
                          "Refusing credential operations outside an isolated test host")
        let key = "test-isolation-\(UUID().uuidString)"
        defer { KeychainManager.delete(key: key) }
        let value = Data([0, 7, 255])
        XCTAssertTrue(KeychainManager.saveBinary(key: key, data: value))
        XCTAssertEqual(TestCredentialStore.shared.data(for: key), value)
        XCTAssertEqual(try KeychainManager.readBinaryWithoutInteraction(key: key), value)
        XCTAssertTrue(KeychainManager.exists(key: key))
        XCTAssertTrue(KeychainManager.delete(key: key))
        XCTAssertNil(TestCredentialStore.shared.data(for: key))
        XCTAssertNil(try KeychainManager.readBinaryWithoutInteraction(key: key))
        XCTAssertFalse(KeychainManager.exists(key: key))
    }
}
