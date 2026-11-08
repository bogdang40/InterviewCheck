import XCTest
@testable import memanager

final class ProjectSemanticCrossLanguageToolTests: XCTestCase {
    func testFindSymbolAndReferencesSupportPythonAndCpp() async throws {
        let fixture = try ProjectToolTestFixture()

        let pythonSymbol = await fixture.execute(FindSymbolTool(), arguments: [
            "name": "Greeter",
            "path": "Python"
        ])
        XCTAssertFalse(pythonSymbol.isError, pythonSymbol.content)
        XCTAssertTrue(pythonSymbol.content.contains("kind: class"), pythonSymbol.content)
        XCTAssertTrue(pythonSymbol.content.contains("path: Python/greeter.py"), pythonSymbol.content)

        let pythonReferences = await fixture.execute(FindReferencesTool(), arguments: [
            "symbol": "Greeter",
            "path": "Python"
        ])
        XCTAssertFalse(pythonReferences.isError, pythonReferences.content)
        XCTAssertTrue(pythonReferences.content.contains("declarations:"), pythonReferences.content)
        XCTAssertTrue(pythonReferences.content.contains("path: Python/greeter.py"), pythonReferences.content)
        XCTAssertTrue(pythonReferences.content.contains("usages:"), pythonReferences.content)
        XCTAssertTrue(pythonReferences.content.contains("path: Python/greeter_usage.py"), pythonReferences.content)
        XCTAssertFalse(pythonReferences.content.contains("snippet: class BaseGreeter:"), pythonReferences.content)

        let cppSymbol = await fixture.execute(FindSymbolTool(), arguments: [
            "name": "Widget",
            "path": "Cpp"
        ])
        XCTAssertFalse(cppSymbol.isError, cppSymbol.content)
        XCTAssertTrue(cppSymbol.content.contains("kind: class"), cppSymbol.content)
        XCTAssertTrue(cppSymbol.content.contains("path: Cpp/widget.hpp"), cppSymbol.content)
    }

    func testOutlineAndRelationshipsSupportRustCppAndC() async throws {
        let fixture = try ProjectToolTestFixture()

        let rustOutline = await fixture.execute(GetFileOutlineTool(), arguments: ["path": "Rust/render.rs"])
        XCTAssertFalse(rustOutline.isError, rustOutline.content)
        XCTAssertTrue(rustOutline.content.contains("kind: import"), rustOutline.content)
        XCTAssertTrue(rustOutline.content.contains("summary: std::fmt::Display"), rustOutline.content)
        XCTAssertTrue(rustOutline.content.contains("kind: trait"), rustOutline.content)
        XCTAssertTrue(rustOutline.content.contains("kind: struct"), rustOutline.content)
        XCTAssertTrue(rustOutline.content.contains("kind: impl"), rustOutline.content)

        let cppRelationships = await fixture.execute(FindTypeRelationshipsTool(), arguments: [
            "name": "Widget",
            "path": "Cpp"
        ])
        XCTAssertFalse(cppRelationships.isError, cppRelationships.content)
        XCTAssertTrue(cppRelationships.content.contains("inherits from:\nBaseWidget"), cppRelationships.content)

        let rustRelationships = await fixture.execute(FindTypeRelationshipsTool(), arguments: [
            "name": "Renderable",
            "path": "Rust"
        ])
        XCTAssertFalse(rustRelationships.isError, rustRelationships.content)
        XCTAssertTrue(rustRelationships.content.contains("relation: implements"), rustRelationships.content)
        XCTAssertTrue(rustRelationships.content.contains("name: RustGreeter"), rustRelationships.content)

        let cOutline = await fixture.execute(GetFileOutlineTool(), arguments: ["path": "C/buffer.h"])
        XCTAssertFalse(cOutline.isError, cOutline.content)
        XCTAssertTrue(cOutline.content.contains("summary: stddef.h"), cOutline.content)
        XCTAssertTrue(cOutline.content.contains("kind: typealias"), cOutline.content)
        XCTAssertTrue(cOutline.content.contains("kind: function"), cOutline.content)
    }
}
