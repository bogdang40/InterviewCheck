import XCTest
@testable import memanager

final class ProjectToolRegistryTests: XCTestCase {
    func testRegistryIncludesAllTwelveToolsInStableOrder() {
        XCTAssertEqual(ProjectToolRegistry.shared.allTools.map(\.name), [
            "list_directory",
            "read_file",
            "search_files",
            "glob",
            "file_info",
            "get_structure",
            "find_symbol",
            "find_references",
            "get_file_outline",
            "read_files_batch",
            "find_related_files",
            "find_type_relationships"
        ])
    }

    func testToolDefinitionsReturnExpandedReadOnlySet() {
        let config = ProjectFolderConfig(isEnabled: true, bookmarkData: Data([1]), displayPath: "/tmp", rootName: "tmp")
        let mode = Mode(title: "Project", prompt: "Prompt", projectFolder: config)

        let definitions = ProjectToolRegistry.shared.toolDefinitions(
            for: mode,
            rootDescriptor: ProjectToolRootDescriptor(config: config)
        )

        XCTAssertEqual(definitions.count, ProjectFolderCapabilities.toolCount)
        XCTAssertTrue(definitions.allSatisfy { $0.isReadOnly })
        XCTAssertTrue(definitions.contains { $0.name == "find_symbol" })
        XCTAssertTrue(definitions.contains { $0.name == "find_type_relationships" })
        XCTAssertTrue(definitions.contains { $0.description.contains("Selected project root: tmp at /tmp") })
        XCTAssertTrue(definitions.contains { $0.description.contains(#"list_directory(path: "")"#) })
    }

    func testProjectFolderHelpTextMentionsSemanticReadOnlyCapabilities() {
        let helpText = ProjectFolderCapabilities.helpText

        XCTAssertTrue(helpText.contains("find symbols"))
        XCTAssertTrue(helpText.contains("trace references"))
        XCTAssertTrue(helpText.contains("outline files"))
        XCTAssertTrue(helpText.contains("batch read files"))
        XCTAssertTrue(helpText.contains("locate related files"))
        XCTAssertTrue(helpText.contains("map type relationships"))
        XCTAssertTrue(helpText.contains("Swift, Python, Rust, C, and C++"))
        XCTAssertTrue(helpText.contains("Nothing is ever written or executed."))
    }
}
