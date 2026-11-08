import XCTest
@testable import memanager

/// Locks down the streaming behavior of the Live Reasoning Canvas parser.
/// The parser is the only thing standing between the LLM stream and what the
/// user reads, so its three guarantees must not regress: prose passes through
/// unchanged, well-formed fences become commands, and partial fences buffer
/// until they close (rather than leaking the YAML body into the prose).
final class StreamingCanvasParserTests: XCTestCase {

    // MARK: - Prose passthrough

    func testPlainProseFeedsThroughUnchanged() {
        let parser = StreamingCanvasParser()
        let result = parser.feed("Walking through the approach line by line.\n")
        XCTAssertEqual(result.prose, "Walking through the approach line by line.\n")
        XCTAssertTrue(result.commands.isEmpty)
    }

    func testEmptyChunkProducesEmptyResult() {
        let parser = StreamingCanvasParser()
        let result = parser.feed("")
        XCTAssertTrue(result.prose.isEmpty)
        XCTAssertTrue(result.commands.isEmpty)
    }

    // MARK: - Whole-fence in one chunk

    func testCompleteArrayFenceProducesArrayCommandAndStripsItFromProse() {
        let parser = StreamingCanvasParser()
        let stream = """
        Sliding window walk:
        ```canvas:array
        id: main
        values: [2, 4, 1, 7, 3, 5]
        label: "Input"
        ```
        Now we shrink from the left.
        """

        let result = parser.feed(stream)

        XCTAssertEqual(result.commands.count, 1)
        guard case let .array(payload) = result.commands[0] else {
            return XCTFail("Expected an array command")
        }
        XCTAssertEqual(payload.id, "main")
        XCTAssertEqual(payload.values, ["2", "4", "1", "7", "3", "5"])
        XCTAssertEqual(payload.label, "Input")

        XCTAssertFalse(result.prose.contains("```"), "Prose must not leak the fence markers")
        XCTAssertFalse(result.prose.contains("values:"), "Prose must not leak the fence body")
        XCTAssertTrue(result.prose.contains("Sliding window walk:"))
        XCTAssertTrue(result.prose.contains("Now we shrink from the left."))
    }

    func testMultipleFencesInOneChunkProduceMultipleCommands() {
        let parser = StreamingCanvasParser()
        let stream = """
        Setup:
        ```canvas:array
        id: a
        values: [1, 2, 3]
        ```
        And then highlight cell 1:
        ```canvas:highlight
        target: a
        kind: cell
        value: 1
        ttl_ms: 800
        ```
        Done.
        """

        let result = parser.feed(stream)

        XCTAssertEqual(result.commands.count, 2)
        if case let .array(payload) = result.commands[0] {
            XCTAssertEqual(payload.id, "a")
        } else {
            XCTFail("First command must be an array")
        }
        if case let .highlight(payload) = result.commands[1] {
            XCTAssertEqual(payload.targetID, "a")
            XCTAssertEqual(payload.kind, .cell)
            XCTAssertEqual(payload.value, "1")
            XCTAssertEqual(payload.ttlMs, 800)
        } else {
            XCTFail("Second command must be a highlight")
        }
    }

    // MARK: - Cross-chunk fence buffering (the critical case)

    func testFenceSplitAcrossTwoChunksBuffersUntilClose() {
        let parser = StreamingCanvasParser()
        let firstHalf = """
        Working through it:
        ```canvas:array
        id: main
        values: [1, 2
        """
        let secondHalf = """
        , 3, 4]
        ```
        Wrap-up sentence.
        """

        let firstResult = parser.feed(firstHalf)
        XCTAssertTrue(firstResult.commands.isEmpty, "No command may be emitted until the closing fence arrives")
        XCTAssertEqual(firstResult.prose, "Working through it:\n", "Only the prose preceding the opener should flush")

        let secondResult = parser.feed(secondHalf)
        XCTAssertEqual(secondResult.commands.count, 1, "Closing fence in the second chunk must finalize the command")
        if case let .array(payload) = secondResult.commands[0] {
            XCTAssertEqual(payload.values, ["1", "2", "3", "4"], "Values from both chunks must concatenate correctly")
        } else {
            XCTFail("Buffered fence must decode as an array command")
        }
        XCTAssertTrue(secondResult.prose.contains("Wrap-up sentence."))
        XCTAssertFalse(secondResult.prose.contains("```"), "Closing fence must not leak into prose")
    }

    func testFenceSplitImmediatelyAfterOpenerStillBuffersUntilClose() {
        let parser = StreamingCanvasParser()

        let openerOnly = parser.feed("```canvas:array\n")
        XCTAssertTrue(openerOnly.commands.isEmpty, "Opener alone must not produce a command")

        let bodyOnly = parser.feed("id: x\nvalues: [9]\n")
        XCTAssertTrue(bodyOnly.commands.isEmpty, "Body without closing fence must keep buffering")

        let closer = parser.feed("```\n")
        XCTAssertEqual(closer.commands.count, 1, "Closing fence in a third chunk must finalize the command")
        if case let .array(payload) = closer.commands[0] {
            XCTAssertEqual(payload.values, ["9"])
        } else {
            XCTFail("Decoded command must be an array")
        }
    }

    // MARK: - Unclosed and malformed fences

    func testUnclosedFenceEmitsNoCommandAndDoesNotLeakBodyIntoProse() {
        let parser = StreamingCanvasParser()
        let result = parser.feed("""
        Intro line.
        ```canvas:array
        id: stuck
        values: [1, 2, 3
        """)

        XCTAssertTrue(result.commands.isEmpty)
        XCTAssertEqual(result.prose, "Intro line.\n", "Only the pre-fence prose may flush; the open body must stay buffered")
    }

    func testMalformedArrayBodyDropsSilentlyWithoutAffectingProse() {
        let parser = StreamingCanvasParser()
        let result = parser.feed("""
        Before.
        ```canvas:array
        label: "missing required fields"
        ```
        After.
        """)

        XCTAssertTrue(result.commands.isEmpty, "Missing required `id` and `values` must drop the command")
        XCTAssertTrue(result.prose.contains("Before."))
        XCTAssertTrue(result.prose.contains("After."))
        XCTAssertFalse(result.prose.contains("missing required fields"), "Body must be consumed even when decoding fails")
    }

    func testUnknownSubtypeDropsTheCommandButPreservesProse() {
        let parser = StreamingCanvasParser()
        let result = parser.feed("""
        Before.
        ```canvas:tree
        id: t
        ```
        After.
        """)

        XCTAssertTrue(result.commands.isEmpty)
        XCTAssertTrue(result.prose.contains("Before."))
        XCTAssertTrue(result.prose.contains("After."))
    }

    // MARK: - Reset

    func testResetDiscardsPendingFenceState() {
        let parser = StreamingCanvasParser()
        _ = parser.feed("""
        ```canvas:array
        id: stale
        values: [
        """)

        parser.reset()

        let afterReset = parser.feed("New session begins.\n")
        XCTAssertTrue(afterReset.commands.isEmpty)
        XCTAssertEqual(afterReset.prose, "New session begins.\n", "After reset the parser must behave like a fresh instance")
    }

    // MARK: - Subtype coverage

    func testWindowFenceDecodes() {
        let parser = StreamingCanvasParser()
        let result = parser.feed("""
        ```canvas:window
        target: main
        op: set
        left: 0
        right: 2
        ```
        """)
        XCTAssertEqual(result.commands.count, 1)
        guard case let .window(payload) = result.commands[0] else {
            return XCTFail("Expected a window command")
        }
        XCTAssertEqual(payload.targetID, "main")
        XCTAssertEqual(payload.op, .set)
        XCTAssertEqual(payload.left, 0)
        XCTAssertEqual(payload.right, 2)
    }

    func testPointerFenceDecodes() {
        let parser = StreamingCanvasParser()
        let result = parser.feed("""
        ```canvas:pointer
        id: ptr
        target: main
        op: advance
        name: i
        index: 3
        ```
        """)
        XCTAssertEqual(result.commands.count, 1)
        guard case let .pointer(payload) = result.commands[0] else {
            return XCTFail("Expected a pointer command")
        }
        XCTAssertEqual(payload.id, "ptr")
        XCTAssertEqual(payload.targetID, "main")
        XCTAssertEqual(payload.op, .advance)
        XCTAssertEqual(payload.name, "i")
        XCTAssertEqual(payload.index, 3)
    }

    func testClearFenceDecodes() {
        let parser = StreamingCanvasParser()
        let result = parser.feed("""
        ```canvas:clear
        id: main
        ```
        """)
        XCTAssertEqual(result.commands.count, 1)
        if case let .clear(sceneID) = result.commands[0] {
            XCTAssertEqual(sceneID, "main")
        } else {
            XCTFail("Expected a clear command")
        }
    }

    func testHighlightFenceUsesDefaultTtlWhenAbsent() {
        let parser = StreamingCanvasParser()
        let result = parser.feed("""
        ```canvas:highlight
        target: a
        kind: indices
        value: 0,2,4
        ```
        """)
        XCTAssertEqual(result.commands.count, 1)
        guard case let .highlight(payload) = result.commands[0] else {
            return XCTFail("Expected a highlight command")
        }
        XCTAssertEqual(payload.ttlMs, 1500, "Default TTL must remain 1500ms when the field is omitted")
    }
}
