import XCTest
@testable import memanager

final class SectionParserSystemDesignProgressiveTests: XCTestCase {
    func testParsesProgressiveSectionsWithDiagrams() {
        let text = """
        ## System Design

        **Requirements:**
        ### Step 1: Scope baseline
        Start with the smallest scope and core user journey.
        Decision: Keep v1 to one primary workflow
        Trade-off: Lower feature breadth for better reliability
        ```mermaid
        flowchart LR
            U[User] --> API[API]
        ```
        ### Step 2: Scale targets
        Add scale and SLO constraints.
        Decision: Define explicit latency and availability targets
        Trade-off: Tighter targets increase infra cost
        ```mermaid
        flowchart LR
            U[User] --> CDN[CDN]
            CDN --> API[API]
        ```

        **High-Level Architecture:**
        ### Step 1: Core request path
        Start with a direct request path.
        Decision: Route traffic through API gateway
        Trade-off: Added hop for stronger control plane
        ```mermaid
        flowchart LR
            C[Client] --> G[Gateway]
            G --> S[Service]
        ```
        ### Step 2: Add cache
        Introduce cache to absorb hot reads.
        Decision: Cache read-heavy results
        Trade-off: Eventual consistency on cache invalidation
        ```mermaid
        flowchart LR
            C[Client] --> G[Gateway]
            G --> Cache[(Cache)]
            G --> S[Service]
        ```

        **Components:**
        ### Step 1: Component boundaries
        Split ingestion and read paths.
        Decision: Separate write and read services
        Trade-off: More services to operate
        ```mermaid
        flowchart LR
            W[Write Service] --> Q[Queue]
            R[Read Service] --> DB[(DB)]
        ```

        **Data Flow:**
        ### Step 1: Request sequence
        Define synchronous request handling.
        Decision: Validate request at gateway
        Trade-off: Slight latency increase per request
        ```mermaid
        sequenceDiagram
            participant C as Client
            participant G as Gateway
            participant S as Service
            C->>G: request
            G->>S: validated request
            S-->>G: response
            G-->>C: response
        ```

        **Database Design:**
        ### Step 1: Core entities
        Define base entities and relationships.
        Decision: Keep normalized core entities
        Trade-off: More joins on read path
        ```mermaid
        erDiagram
            USER ||--o{ ORDER : places
        ```

        **API Design:**
        ### Step 1: Resource model
        Define resources and endpoint semantics.
        Decision: Resource-oriented REST endpoints
        Trade-off: More endpoints to maintain
        ```mermaid
        flowchart LR
            Client --> GET[/GET /v1/orders/]
            Client --> POST[/POST /v1/orders/]
        ```
        - **GET** `/v1/orders` - List orders
        - **POST** `/v1/orders` - Create order

        **Scalability:**
        ### Step 1: Horizontal scale
        Add horizontal app scaling first.
        Decision: Stateless app nodes behind LB
        Trade-off: Requires externalized session state
        ```mermaid
        flowchart LR
            LB[Load Balancer] --> N1[Node 1]
            LB --> N2[Node 2]
        ```

        **Trade-offs:**
        ### Step 1: Consistency choice
        Pick availability for the feed path.
        Decision: Eventual consistency on feed fanout
        Trade-off: Stale reads under propagation lag
        ```mermaid
        flowchart LR
            Write --> Queue --> ReadModel
        ```
        """

        let parsed = SectionParser.parseSystemDesign(text)

        XCTAssertEqual(parsed.requirements?.steps.count, 2)
        XCTAssertEqual(parsed.architecture?.steps.count, 2)
        XCTAssertEqual(parsed.componentSteps.count, 1)
        XCTAssertEqual(parsed.dataFlow?.steps.count, 1)
        XCTAssertEqual(parsed.database?.steps.count, 1)
        XCTAssertEqual(parsed.apiDesign?.steps.count, 1)
        XCTAssertEqual(parsed.scalability?.steps.count, 1)
        XCTAssertEqual(parsed.tradeOffSteps.count, 1)
    }

    func testSkipsInvalidStepsAndRenumbersSequentially() {
        let text = """
        ## System Design

        **High-Level Architecture:**
        ### Step 9: Initial path
        Baseline request flow.
        Decision: Start with direct service path
        Trade-off: No async buffering
        ```mermaid
        flowchart LR
            C[Client] --> S[Service]
        ```
        ### Step 12: Invalid step
        This step has no mermaid and must be skipped.
        Decision: Keep step anyway
        Trade-off: Invalid output
        ### Step 42: Add queue
        Introduce async buffering.
        Decision: Buffer writes through queue
        Trade-off: Higher end-to-end latency
        ```mermaid
        flowchart LR
            C[Client] --> Q[Queue] --> S[Service]
        ```
        """

        let parsed = SectionParser.parseSystemDesign(text)
        let steps = parsed.architecture?.steps ?? []

        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps.map(\.number), [1, 2])
        XCTAssertEqual(steps[0].title, "Initial path")
        XCTAssertEqual(steps[1].title, "Add queue")
    }

    func testSynthesizesLegacySingleDiagramStep() {
        let text = """
        ## System Design

        **High-Level Architecture:**
        We use a gateway and core service with cache.
        ```mermaid
        flowchart LR
            Client --> Gateway --> Service
            Service --> Cache
        ```
        """

        let parsed = SectionParser.parseSystemDesign(text)
        let steps = parsed.architecture?.steps ?? []

        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.number, 1)
        XCTAssertTrue(steps.first?.title.contains("Baseline") == true)
    }

    func testOmitsSectionWhenNoValidStepDiagramsExist() {
        let text = """
        ## System Design

        **Data Flow:**
        ### Step 1: Happy path
        Describe call sequence without diagram.
        Decision: Keep it simple
        Trade-off: No visual explanation
        """

        let parsed = SectionParser.parseSystemDesign(text)
        XCTAssertNil(parsed.dataFlow)
    }

    func testSupportsStepHeaderVariantsLevel2AndBold() {
        let text = """
        ## System Design

        **High-Level Architecture:**
        ## Step 1: Foundation path
        Build the minimal routing baseline.
        Decision: Start with single service path
        Trade-off: Less fault isolation initially
        ```mermaid
        flowchart LR
            C[Client] --> G[Gateway] --> S[Service]
        ```
        **Step 2: Add isolation**
        Introduce async buffering and worker isolation.
        Decision: Insert queue between gateway and workers
        Trade-off: Added eventual consistency
        ```mermaid
        flowchart LR
            C[Client] --> G[Gateway] --> Q[Queue] --> W[Worker]
        ```
        """

        let parsed = SectionParser.parseSystemDesign(text)
        let steps = parsed.architecture?.steps ?? []

        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].title, "Foundation path")
        XCTAssertEqual(steps[1].title, "Add isolation")
        XCTAssertEqual(steps.map(\.number), [1, 2])
    }

    func testBoldStepHeaderDoesNotFallbackToLegacyTitle() {
        let text = """
        ## System Design

        **High-Level Architecture:**
        **Step 1: Scope baseline**
        Keep v1 intentionally narrow.
        Decision: Prioritize one request path
        Trade-off: Fewer launch features
        ```mermaid
        flowchart LR
            U[User] --> API[API]
        ```
        """

        let parsed = SectionParser.parseSystemDesign(text)
        let step = parsed.architecture?.steps.first

        XCTAssertEqual(parsed.architecture?.steps.count, 1)
        XCTAssertEqual(step?.title, "Scope baseline")
        XCTAssertEqual(step?.number, 1)
    }

    func testParsesProgressiveContextLabels() {
        let text = """
        ## System Design

        **High-Level Architecture:**
        ### Step 1: Baseline path
        Start with a direct synchronous request path.
        Builds-on: Baseline
        Diagram delta: Initial client-to-service path
        Why now: We need a working baseline before adding resilience.
        Decision: Use a single gateway and service
        Trade-off: Fewer moving parts but limited fault isolation
        ```mermaid
        flowchart LR
            Client --> Gateway --> Service
        ```
        ### Step 2: Add queue isolation
        Extend the same path with asynchronous buffering.
        Builds-on: Keep gateway and service from Step 1
        Diagram delta: Insert Queue between Gateway and Service
        Why now: Absorb spikes before scaling workers.
        Decision: Queue writes before workers
        Trade-off: Eventual consistency for better stability
        ```mermaid
        flowchart LR
            Client --> Gateway --> Queue --> Service
        ```
        """

        let parsed = SectionParser.parseSystemDesign(text)
        let steps = parsed.architecture?.steps ?? []

        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].buildsOn, "Baseline")
        XCTAssertEqual(steps[1].buildsOn, "Keep gateway and service from Step 1")
        XCTAssertEqual(steps[1].diagramDelta, "Insert Queue between Gateway and Service")
        XCTAssertEqual(steps[1].whyNow, "Absorb spikes before scaling workers.")
    }

}
