import XCTest
@testable import memanager

final class MemoizedParseTests: XCTestCase {
    func testSameInputComputesOnceAndReturnsCachedValue() {
        let cache = MemoizedParse<String>()
        var computeCount = 0

        let first = cache.value(for: "input") { _ in computeCount += 1; return "out" }
        let second = cache.value(for: "input") { _ in computeCount += 1; return "different" }

        XCTAssertEqual(first, "out")
        XCTAssertEqual(second, "out", "Cached value wins; compute must not rerun")
        XCTAssertEqual(computeCount, 1)
    }

    func testChangedInputRecomputes() {
        let cache = MemoizedParse<Int>()
        var computeCount = 0

        _ = cache.value(for: "a") { _ in computeCount += 1; return 1 }
        _ = cache.value(for: "b") { _ in computeCount += 1; return 2 }

        XCTAssertEqual(computeCount, 2)
    }

    func testEvictionDropsOldestBeyondCapacity() {
        let cache = MemoizedParse<Int>(capacity: 2)
        var computeCount = 0
        func fetch(_ key: String) -> Int {
            cache.value(for: key) { _ in computeCount += 1; return computeCount }
        }

        _ = fetch("a")
        _ = fetch("b")
        _ = fetch("c")   // evicts a
        _ = fetch("b")   // still cached
        XCTAssertEqual(computeCount, 3)

        _ = fetch("a")   // recomputes
        XCTAssertEqual(computeCount, 4)
    }

    func testConcurrentAccessIsSafeAndConverges() {
        let cache = MemoizedParse<String>()

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let key = "key-\(index % 3)"
            let value = cache.value(for: key) { "value-for-\($0)" }
            XCTAssertEqual(value, "value-for-\(key)")
        }
    }
}

final class SectionParseStoreTests: XCTestCase {
    func testUnchangedInputPreservesProductIdentity() {
        let response = MentorResponse(
            problem: "Test problem\n- Time: O(n)",
            clarifyingQuestions: "- What about empty input?",
            implementation: "",
            tests: "",
            complexity: "",
            systemDesign: ""
        )

        let firstIDs = response.parsedProblem.constraints.map(\.id)
        let secondIDs = response.parsedProblem.constraints.map(\.id)

        XCTAssertEqual(firstIDs, secondIDs, "Same input must return the same cached instance, keeping UUID identities stable")
        XCTAssertEqual(
            response.parsedQuestions.allQuestions.map(\.id),
            response.parsedQuestions.allQuestions.map(\.id)
        )
    }

    func testMemoizedOutputMatchesDirectParserFieldForField() {
        let text = "Sorted array lookup\n- Time: O(log n)\n- Input: sorted integers"
        let direct = SectionParser.parseProblem(text)
        let memoized = SectionParseStore.problem.value(for: text, compute: SectionParser.parseProblem)

        XCTAssertEqual(memoized.constraints.map(\.description), direct.constraints.map(\.description))
        XCTAssertEqual(memoized.rawContent, direct.rawContent)
    }

    func testProgressiveStepIDsAreDeterministicAcrossGrowingReparses() {
        let sectionV1 = """
        ### Step 1: Baseline
        Start with a client and a server talking directly.
        Decision: single service
        ```mermaid
        flowchart TD
            Client --> Server
        ```
        """
        let sectionV2 = sectionV1 + """

        ### Step 2: Add cache
        Keep the client and server, add a cache beside the server.
        Decision: cache-aside
        ```mermaid
        flowchart TD
            Client --> Server
            Server --> Cache
        ```
        """

        let stepsV1 = SystemDesignProgressiveStepParser.parseProgressiveSteps(from: sectionV1, legacyTitle: "Architecture")
        let stepsV2 = SystemDesignProgressiveStepParser.parseProgressiveSteps(from: sectionV2, legacyTitle: "Architecture")

        XCTAssertEqual(stepsV1.count, 1)
        XCTAssertEqual(stepsV2.count, 2)
        XCTAssertEqual(stepsV1[0].id, stepsV2[0].id,
                       "Step 1's identity must survive the streamed text growing")
        XCTAssertNotEqual(stepsV2[0].id, stepsV2[1].id)

        let otherSection = SystemDesignProgressiveStepParser.parseProgressiveSteps(from: sectionV1, legacyTitle: "Data Flow")
        XCTAssertNotEqual(stepsV1[0].id, otherSection[0].id, "Identity is scoped per section")
    }
}
