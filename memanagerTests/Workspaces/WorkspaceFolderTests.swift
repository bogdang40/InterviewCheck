import XCTest
@testable import memanager

final class WorkspaceFolderTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ws-root-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testProvisionCreatesSkeletonManifestAndReadme() throws {
        let provisioner = WorkspaceFolderProvisioner(rootDirectory: root)
        let workspace = JobWorkspace(name: "", company: "Stripe", role: "Staff / Payments", folderPath: "")

        let folder = try provisioner.provision(workspace)

        XCTAssertEqual(folder.lastPathComponent, "Stripe Staff Payments")
        for category in WorkspaceFolderLayout.provisionedCategories {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(category.folderName).path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(WorkspaceFolderLayout.readmeFileName).path))
        let manifest = try XCTUnwrap(WorkspaceManifest.read(from: folder))
        XCTAssertEqual(manifest.id, workspace.id)
        XCTAssertEqual(manifest.company, "Stripe")
    }

    func testProvisionAvoidsNameCollisions() throws {
        let provisioner = WorkspaceFolderProvisioner(rootDirectory: root)
        let first = try provisioner.provision(JobWorkspace(name: "Acme", folderPath: ""))
        let second = try provisioner.provision(JobWorkspace(name: "Acme", folderPath: ""))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.lastPathComponent, "Acme 2")
    }

    func testManifestRoundTripRebuildsWorkspace() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var workspace = JobWorkspace(name: "Acme", company: "Acme", role: "SWE", status: .offer, folderPath: root.path, tags: ["x"])
        workspace.jobDescriptionSummary = "Summary"
        try WorkspaceManifest(workspace: workspace).write(to: root)

        let rebuilt = try XCTUnwrap(WorkspaceManifest.read(from: root)).makeWorkspace(folderURL: root)
        XCTAssertEqual(rebuilt.id, workspace.id)
        XCTAssertEqual(rebuilt.status, .offer)
        XCTAssertEqual(rebuilt.tags, ["x"])
        XCTAssertEqual(rebuilt.jobDescriptionSummary, "Summary")
        XCTAssertEqual(rebuilt.folderPath, root.path)
    }

    func testCategoryDerivesFromTopLevelFolder() {
        XCTAssertEqual(WorkspaceFolderLayout.category(forRelativePath: "Job Description/jd.pdf"), .jobDescription)
        XCTAssertEqual(WorkspaceFolderLayout.category(forRelativePath: "Journal/2026-09-02.md"), .journal)
        XCTAssertEqual(WorkspaceFolderLayout.category(forRelativePath: "random.txt"), .other)
        XCTAssertEqual(WorkspaceFolderLayout.category(forRelativePath: "Projects/deep/nested/file.md"), .projects)
    }

    func testImportGuardRefusesBroadFoldersAndProtectsIdentities() throws {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        XCTAssertThrowsError(try WorkspaceImportGuard.validate(home, rootDirectory: root))
        XCTAssertThrowsError(try WorkspaceImportGuard.validate(root, rootDirectory: root))
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            XCTAssertThrowsError(try WorkspaceImportGuard.validate(documents, rootDirectory: root))
        }
        XCTAssertNoThrow(try WorkspaceImportGuard.validate(root.appendingPathComponent("Acme"), rootDirectory: root))

        try fileManager.createDirectory(at: root.appendingPathComponent("old"), withIntermediateDirectories: true)
        let oldPath = root.appendingPathComponent("old").path
        XCTAssertFalse(WorkspaceImportGuard.shouldAdoptExistingIdentity(existingFolderPath: oldPath, importedFolderPath: root.appendingPathComponent("copy").path), "a copied manifest must not hijack a live workspace")
        XCTAssertTrue(WorkspaceImportGuard.shouldAdoptExistingIdentity(existingFolderPath: oldPath, importedFolderPath: oldPath))
        XCTAssertTrue(WorkspaceImportGuard.shouldAdoptExistingIdentity(existingFolderPath: root.appendingPathComponent("gone").path, importedFolderPath: root.appendingPathComponent("moved").path))
    }

    func testAdoptRejectsFilesAndMissingFolders() {
        let provisioner = WorkspaceFolderProvisioner(rootDirectory: root)
        XCTAssertThrowsError(try provisioner.adopt(existingFolder: root.appendingPathComponent("missing"), for: JobWorkspace(name: "x", folderPath: "")))
    }
}
