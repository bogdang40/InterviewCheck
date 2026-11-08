import XCTest
@testable import memanager

final class ProjectToolPathNormalizerTests: XCTestCase {
    private var fixture: ProjectToolTestFixture!
    private var rootDescriptor: ProjectToolRootDescriptor!
    private let normalizer = ProjectToolPathNormalizer.shared

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try ProjectToolTestFixture()
        rootDescriptor = ProjectToolRootDescriptor(config: fixture.config)
    }

    override func tearDown() {
        rootDescriptor = nil
        fixture = nil
        super.tearDown()
    }

    func testRelativePathPassesThrough() {
        let call = ToolCall(id: "1", name: "read_file", arguments: JSONObject(["path": "Sources/Conversation.swift"]))
        let result = normalizer.normalize(call: call, rootURL: fixture.rootURL, rootDescriptor: rootDescriptor)

        switch result {
        case .success(let normalized):
            XCTAssertEqual(normalized.arguments.raw["path"] as? String, "Sources/Conversation.swift")
        case .failure(let failure):
            XCTFail("unexpected failure: \(failure.content)")
        }
    }

    func testAbsolutePathInsideRootRewritesToRelative() {
        let absolute = fixture.rootURL.appendingPathComponent("Docs/Guide.md").path
        let call = ToolCall(id: "1", name: "read_file", arguments: JSONObject(["path": absolute]))
        let result = normalizer.normalize(call: call, rootURL: fixture.rootURL, rootDescriptor: rootDescriptor)

        switch result {
        case .success(let normalized):
            XCTAssertEqual(normalized.arguments.raw["path"] as? String, "Docs/Guide.md")
        case .failure(let failure):
            XCTFail("unexpected failure: \(failure.content)")
        }
    }

    func testAbsoluteRootRewritesToEmptyForRootAwareTool() {
        let call = ToolCall(id: "1", name: "list_directory", arguments: JSONObject(["path": fixture.rootURL.path]))
        let result = normalizer.normalize(call: call, rootURL: fixture.rootURL, rootDescriptor: rootDescriptor)

        switch result {
        case .success(let normalized):
            XCTAssertEqual(normalized.arguments.raw["path"] as? String, "")
        case .failure(let failure):
            XCTFail("unexpected failure: \(failure.content)")
        }
    }

    func testAbsolutePathOutsideRootIsRefused() {
        let call = ToolCall(id: "1", name: "read_file", arguments: JSONObject(["path": "/dev/null"]))
        let result = normalizer.normalize(call: call, rootURL: fixture.rootURL, rootDescriptor: rootDescriptor)

        switch result {
        case .success:
            XCTFail("expected outside root failure")
        case .failure(let failure):
            XCTAssertTrue(failure.isError)
            XCTAssertTrue(failure.content.contains("selected_root:"))
            XCTAssertTrue(failure.content.contains("provided_path: /dev/null"))
            XCTAssertTrue(failure.content.contains(#"list_directory(path: "")"#))
        }
    }

    func testParentTraversalStillFails() {
        let call = ToolCall(id: "1", name: "read_file", arguments: JSONObject(["path": "../Secrets.txt"]))
        let result = normalizer.normalize(call: call, rootURL: fixture.rootURL, rootDescriptor: rootDescriptor)

        switch result {
        case .success:
            XCTFail("expected parent traversal failure")
        case .failure(let failure):
            XCTAssertTrue(failure.content.contains("Parent traversal is not allowed"))
        }
    }
}
