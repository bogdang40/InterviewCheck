import XCTest
@testable import memanager

final class SectionParserSystemDesignMergeTests: XCTestCase {
    func testMergesRepeatedSectionBlocksInDocumentOrder() {
        let text = """
        ## System Design

        **High-Level Architecture:**
        ### Step 1: Baseline
        Start with direct request routing through one service.
        Decision: Keep one synchronous path
        Trade-off: Limited isolation
        ```mermaid
        flowchart LR
            CLIENT[Client] --> GATEWAY[Gateway] --> CORE[CoreService]
        ```
        ### Step 2: Cache hot reads
        Extend baseline with a cache in front of core reads.
        Decision: Add cache for hot endpoints
        Trade-off: Eventual consistency on invalidation
        ```mermaid
        flowchart LR
            CLIENT[Client] --> GATEWAY[Gateway]
            GATEWAY --> CACHE[Cache]
            GATEWAY --> CORE[CoreService]
        ```

        **Components:**
        ### Step 1: Core boundaries
        Split API and worker ownership.
        Decision: Separate read and write workers
        Trade-off: More services to operate
        ```mermaid
        flowchart LR
            API[API] --> QUEUE[Queue] --> WORKER[Worker]
        ```

        **High-Level Architecture:**
        ### Step 3: Async write path
        Keep Gateway and CoreService, then add Queue before worker execution.
        Builds-on: Gateway and CoreService from step 2
        Diagram delta: Add Queue and Worker branch from Gateway
        Why now: absorb write spikes before scale-out
        Decision: Route writes through queue
        Trade-off: Increased end-to-end write latency
        ```mermaid
        flowchart LR
            CLIENT[Client] --> GATEWAY[Gateway]
            GATEWAY --> CACHE[Cache]
            GATEWAY --> CORE[CoreService]
            GATEWAY --> QUEUE[Queue] --> WORKER[Worker]
        ```
        ### Step 4: Failure isolation
        Keep queue path and add retry DLQ handling.
        Builds-on: Queue and Worker branch from step 3
        Diagram delta: Add DLQ branch off Queue
        Why now: isolate poison messages without blocking normal flow
        Decision: Add dead-letter queue
        Trade-off: More operational complexity
        ```mermaid
        flowchart LR
            CLIENT[Client] --> GATEWAY[Gateway]
            GATEWAY --> CACHE[Cache]
            GATEWAY --> CORE[CoreService]
            GATEWAY --> QUEUE[Queue] --> WORKER[Worker]
            QUEUE --> DLQ[DLQ]
        ```
        """

        let parsed = SectionParser.parseSystemDesign(text)
        let steps = parsed.architecture?.steps ?? []

        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(steps.map(\.title), ["Baseline", "Cache hot reads", "Async write path", "Failure isolation"])
    }

    func testDuplicateStepNumberUsesLastDefinitionAndFlagsOverride() {
        let text = """
        ## System Design

        **High-Level Architecture:**
        ### Step 1: Baseline
        Initial path.
        Decision: Baseline decision
        Trade-off: Baseline trade-off
        ```mermaid
        flowchart LR
            CLIENT[Client] --> API[API]
        ```
        ### Step 2: Old draft
        Original draft for step 2.
        Decision: Old step 2 decision
        Trade-off: Old step 2 trade-off
        ```mermaid
        flowchart LR
            CLIENT[Client] --> API[API] --> DB[Database]
        ```

        **High-Level Architecture:**
        ### Step 2: Revised draft
        Revised step 2 replaces the old draft and keeps API.
        Builds-on: API from step 1
        Diagram delta: Replace DB path with Queue path
        Why now: Need buffered writes before worker fanout
        Decision: Revised step 2 decision
        Trade-off: Added queue latency
        ```mermaid
        flowchart LR
            CLIENT[Client] --> API[API] --> QUEUE[Queue]
        ```
        ### Step 3: Worker fanout
        Extend revised step with workers.
        Decision: Add worker fanout
        Trade-off: More coordination
        ```mermaid
        flowchart LR
            CLIENT[Client] --> API[API] --> QUEUE[Queue] --> WORKER[Worker]
        ```
        """

        let parsed = SectionParser.parseSystemDesign(text)
        let steps = parsed.architecture?.steps ?? []

        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[1].title, "Revised draft")
        XCTAssertEqual(steps[1].decision, "Revised step 2 decision")
        XCTAssertTrue(steps[1].wasOverriddenDuringMerge)
    }

    func testRepeatedMergedScalabilityAndAPISectionsRemainStableAcrossParses() {
        let text = """
        ## System Design

        **API Design:**
        ### Step 1: Baseline APIs
        Define baseline read and write endpoints.
        Decision: Start with REST resources
        Trade-off: More endpoint surface area
        ```mermaid
        flowchart LR
            Client --> GET[/GET /v1/items/]
            Client --> POST[/POST /v1/items/]
        ```
        ### Step 2: Add auth
        Add token verification at gateway.
        Decision: Verify JWT at API gateway
        Trade-off: Extra auth latency
        ```mermaid
        flowchart LR
            Client --> Gateway --> API
        ```
        ### Step 3: Draft missing diagram
        This draft intentionally omits Mermaid and should be skipped.
        Decision: Keep partial step
        Trade-off: incomplete visualization

        **Scalability:**
        ### Step 1: Horizontal app scale
        Add stateless app replicas behind load balancing.
        Decision: Scale app layer first
        Trade-off: requires external session/cache state
        ```mermaid
        flowchart LR
            LB --> App1
            LB --> App2
        ```
        ### Step 2: Add caching tier
        Keep app replicas and introduce cache for hot reads.
        Decision: Add distributed cache
        Trade-off: cache invalidation complexity
        ```mermaid
        flowchart LR
            LB --> App1
            LB --> App2
            App1 --> Cache
            App2 --> Cache
        ```
        ### Step 3: Draft missing diagram
        This draft intentionally omits Mermaid and should be skipped.
        Decision: Keep partial scale step
        Trade-off: incomplete visualization

        **API Design:**
        ### Step 2: Revised auth path
        Replace old step 2 with a clearer auth boundary.
        Decision: Centralize auth in edge gateway
        Trade-off: tighter coupling to gateway
        ```mermaid
        flowchart LR
            Client --> EdgeGateway --> API
        ```
        ### Step 3: Finalized contracts
        Add explicit contract validation and versioning.
        Decision: Enforce schema validation
        Trade-off: stricter compatibility management
        ```mermaid
        flowchart LR
            Client --> EdgeGateway --> ContractValidator --> API
        ```

        **Scalability:**
        ### Step 3: Second draft still missing diagram
        Still no Mermaid by design, should continue to be skipped.
        Decision: Keep invalid draft
        Trade-off: not renderable
        """

        var firstParsed: SystemDesignContent?
        for _ in 0..<20 {
            let parsed = SectionParser.parseSystemDesign(text)
            if firstParsed == nil {
                firstParsed = parsed
            }

            XCTAssertEqual(parsed.apiDesign?.steps.count, 3)
            XCTAssertEqual(parsed.scalability?.steps.count, 2)
            XCTAssertEqual(parsed.apiDesign?.steps[1].title, "Revised auth path")
            XCTAssertEqual(parsed.apiDesign?.steps[2].title, "Finalized contracts")
        }

        guard let firstParsed else {
            return XCTFail("Expected at least one parsed result")
        }

        XCTAssertEqual(firstParsed.apiDesign?.steps.count, 3)
        XCTAssertEqual(firstParsed.scalability?.steps.count, 2)
    }
}
