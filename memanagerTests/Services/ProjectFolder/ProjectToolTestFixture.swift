import Foundation
@testable import memanager

final class ProjectToolTestFixture {
    let rootURL: URL
    var config: ProjectFolderConfig

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectToolFixture-\(UUID().uuidString)", isDirectory: true)
        config = ProjectFolderConfig(
            isEnabled: true,
            bookmarkData: nil,
            displayPath: rootURL.path,
            rootName: rootURL.lastPathComponent,
            maxFileSizeBytes: 4_000,
            maxSearchResults: 200,
            maxToolIterations: 10,
            allowSensitiveReads: false
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try seedFixture()
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func context() -> ProjectToolContext {
        ProjectToolContext(rootURL: rootURL, config: config, access: .shared)
    }

    func execute(_ tool: ProjectTool, arguments: [String: Any]) async -> ToolResult {
        await tool.execute(callID: "test-call", arguments: arguments, context: context())
    }

    private func seedFixture() throws {
        try writeText("""
        import Foundation

        // MARK: - Conversation
        protocol Renderable {
            func render() -> String
        }

        final class Conversation: NSObject, Renderable {
            let title: String

            init(title: String) {
                self.title = title
            }

            func render() -> String {
                title
            }
        }
        """, to: "Sources/Conversation.swift")

        try writeText("""
        import Foundation

        extension Conversation: CustomStringConvertible {
            var description: String { render() }
        }
        """, to: "Sources/Conversation+Display.swift")

        try writeText("""
        import Foundation

        struct ConversationStore {
            let current: Conversation

            func lines() -> [String] {
                [current.render(), current.description]
            }
        }
        """, to: "Sources/ConversationStore.swift")

        try writeText("""
        struct Mode {}
        """, to: "Sources/Mode.swift")

        try writeText("""
        struct ModeStore {
            let mode: Mode
        }
        """, to: "Sources/ModeStore.swift")

        try writeText("""
        import XCTest
        @testable import memanager

        final class ConversationTests: XCTestCase {
            func testConversationRendersTitle() {
                let conversation = Conversation(title: "Hi")
                XCTAssertEqual(conversation.render(), "Hi")
            }
        }
        """, to: "Tests/ConversationTests.swift")

        try writeText("""
        # Guide

        ## Conversation
        Use Conversation when rendering summaries.
        """, to: "Docs/Guide.md")

        try writeText("""
        import pathlib

        class BaseGreeter:
            pass

        class Greeter(BaseGreeter):
            def greet(self):
                return "hi"

        def build_greeter():
            return Greeter()
        """, to: "Python/greeter.py")

        try writeText("""
        from greeter import Greeter

        def run():
            return Greeter()
        """, to: "Python/greeter_usage.py")

        try writeText("""
        use std::fmt::Display;

        trait Renderable {}
        struct RustGreeter;

        impl Renderable for RustGreeter {}

        impl RustGreeter {
            fn render(&self) {}
        }

        fn build_greeter() -> RustGreeter {
            RustGreeter
        }
        """, to: "Rust/render.rs")

        try writeText("""
        #include <string>

        class BaseWidget {};

        class Widget : public BaseWidget {
        public:
            std::string title() const;
        };
        """, to: "Cpp/widget.hpp")

        try writeText("""
        #include "widget.hpp"

        std::string Widget::title() const {
            return "widget";
        }
        """, to: "Cpp/widget.cpp")

        try writeText("""
        #include <stddef.h>

        typedef struct Buffer Buffer;
        size_t buffer_length(const Buffer *buffer);
        """, to: "C/buffer.h")

        try writeText("API_KEY=secret-value\n", to: ".env")
        try writeText("struct IgnoredThing {}\n", to: "node_modules/IgnoredThing.swift")

        let largePayload = Array(repeating: "// filler line for size testing\n", count: 250).joined()
        try writeText("import Foundation\n\nstruct HugeSymbol {}\n\(largePayload)", to: "Sources/LargeSymbol.swift")
    }

    private func writeText(_ text: String, to relativePath: String) throws {
        let destination = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try text.write(to: destination, atomically: true, encoding: .utf8)
    }
}
