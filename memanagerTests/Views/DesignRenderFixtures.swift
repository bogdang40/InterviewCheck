import Foundation
@testable import memanager

/// A system design answer in the exact prompt contract shape: every
/// blueprint section, progressive steps carrying the builds on, diagram
/// delta, why now, decision, and trade off lines, one mermaid diagram per
/// step, estimation metric rows, and the closing checklist line.
enum DesignRenderFixtures {
    static var content: SystemDesignContent {
        SystemDesignSectionParser.parseSystemDesign(designAnswer)
    }

    static var response: MentorResponse {
        MentorResponse.parse(from: designAnswer)
    }

    static let designAnswer = """
    ## System Design

    **Requirements:**
    - Users can upload and share clips up to 60 seconds
    - Users can follow other users and see a personalized feed
    - Support 100M daily active users with 99.9% availability

    ### Step 1: Scope the product
    Okay, so let me start by understanding the scope here. Users upload short clips and watch a personalized feed, and that is the whole v1.
    Builds-on: Baseline
    Diagram delta: Client and API only
    Why now: Scope decides every later trade-off
    Decision: Ship upload and feed first, nothing else in v1
    Trade-off: Smaller launch scope
    ```mermaid
    flowchart LR
        User --> App[Mobile App]
        App --> API[API Gateway]
    ```
    ### Step 2: Scale targets
    Keeping the App and API from step 1, I add the targets: 100M daily actives and playback that starts in under 200 milliseconds.
    Builds-on: App and API from step 1
    Diagram delta: Adds a CDN in front of the API
    Why now: The latency target shapes the storage choice
    Decision: Define explicit latency and availability targets
    Trade-off: Tighter targets increase infrastructure cost
    ```mermaid
    flowchart LR
        User --> App[Mobile App]
        App --> CDN[CDN]
        CDN --> API[API Gateway]
    ```

    **Estimation:**
    - DAU: 100M
    - Read to write ratio: 100:1
    - Average QPS: 12,000 (100M x 10 / 86,400)
    - Peak QPS: 24,000 (2x average)
    - Storage per day: 50 TB (1M uploads x 50 MB)
    - Cache size: 10 TB (20% of daily reads)

    ### Step 1: Traffic math
    The first thing I am thinking about is scale. With 100M daily actives and ten views each, the API from the requirements sees about 12,000 requests a second.
    Builds-on: API from requirements
    Diagram delta: Adds the read and write split at the API
    Why now: Peak traffic sizes every tier below
    Decision: Size for peak at 24,000 requests a second
    Trade-off: Idle capacity off peak
    ```mermaid
    flowchart TD
        API[API Gateway] --> Read[Read path]
        API --> Write[Write path]
    ```
    ### Step 2: Storage math
    Keeping the Write path from step 1, a million uploads a day at 50 MB each is 50 TB a day, so object storage is the only sane home for video.
    Builds-on: Write path from step 1
    Diagram delta: Adds object storage behind the write path
    Why now: Daily volume rules out a relational store for blobs
    Decision: Store video in object storage with a CDN in front
    Trade-off: Eventual consistency on newly uploaded clips
    ```mermaid
    flowchart TD
        API[API Gateway] --> Write[Write path]
        Write --> S3[(Object Storage)]
    ```

    **High-Level Architecture:**
    ### Step 1: Core request path
    Start with a direct request path from the Client through a Gateway to one service.
    Builds-on: Baseline
    Diagram delta: Client, Gateway, and Service
    Why now: Everything else hangs off this spine
    Decision: Route all traffic through the API gateway
    Trade-off: One more hop per request
    ```mermaid
    flowchart LR
        C[Client] --> G[Gateway]
        G --> S[Feed Service]
    ```
    ### Step 2: Add a cache
    Keeping the Gateway and Feed Service, I put a cache beside the service to absorb the hot reads.
    Builds-on: Gateway and Feed Service from step 1
    Diagram delta: Adds a cache next to the feed service
    Why now: Reads outnumber writes one hundred to one
    Decision: Cache read heavy feed results
    Trade-off: Stale feeds during cache invalidation
    ```mermaid
    flowchart LR
        C[Client] --> G[Gateway]
        G --> Cache[(Redis Cache)]
        G --> S[Feed Service]
    ```

    **Components:**
    ### Step 1: Component boundaries
    Split the ingestion and read paths so the Gateway fans out to a write service and a read service.
    Builds-on: Gateway from the architecture
    Diagram delta: Adds Write Service and Read Service
    Why now: Separate scaling for uploads and feeds
    Decision: Separate write and read services
    Trade-off: More services to operate
    ```mermaid
    flowchart LR
        G[Gateway] --> W[Write Service] --> Q[Queue]
        G --> R[Read Service] --> DB[(Feed DB)]
    ```

    **Data Flow:**
    ### Step 1: Upload sequence
    The Client uploads through the Gateway, the Write Service stores the clip, and the Queue kicks off transcoding.
    Builds-on: Write Service and Queue from components
    Diagram delta: Adds the upload sequence
    Why now: Upload is the first user visible flow
    Decision: Validate the upload at the gateway
    Trade-off: Slight latency per request
    ```mermaid
    sequenceDiagram
        participant C as Client
        participant G as Gateway
        participant W as Write Service
        C->>G: upload clip
        G->>W: validated upload
        W-->>C: clip id
    ```

    **Database Design:**
    ### Step 1: Core entities
    Model users, clips, and follows as the three core entities behind the Read Service.
    **Users**: id UUID PK, handle TEXT, created_at TIMESTAMP; indexes: handle
    **Clips**: id UUID PK, owner_id UUID FK, url TEXT; indexes: owner_id
    Builds-on: Read Service from components
    Diagram delta: Adds USER, CLIP, and FOLLOW entities
    Why now: The feed query needs the follow graph
    Decision: Keep normalized core entities
    Trade-off: More joins on the read path
    ```mermaid
    erDiagram
        USER ||--o{ CLIP : owns
        USER ||--o{ FOLLOW : follows
    ```

    **API Design:**
    ### Step 1: Resource model
    Expose the feed and clips as resources through the Gateway.
    - **GET** `/v1/feed` - Personalized feed, paginated by cursor
    - **POST** `/v1/clips` - Upload a clip, idempotent by client token
    Builds-on: Gateway from the architecture
    Diagram delta: Adds the two public endpoints
    Why now: Clients need a stable contract before scaling work
    Decision: Resource oriented REST endpoints
    Trade-off: More endpoints to maintain over time
    ```mermaid
    flowchart LR
        Client --> GET[/GET /v1/feed/]
        Client --> POST[/POST /v1/clips/]
    ```

    **Scalability:**
    - CDN: cache clips at edge locations worldwide
    - Sharding: shard the feed database by user id

    ### Step 1: Horizontal scale
    Keeping the Gateway, add stateless nodes behind a load balancer.
    Bottleneck: the single feed database under write load
    Builds-on: Gateway from the architecture
    Diagram delta: Adds a load balancer and two nodes
    Why now: Stateless tiers scale first and cheapest
    Decision: Stateless app nodes behind a load balancer
    Trade-off: Session state must live outside the nodes
    ```mermaid
    flowchart LR
        LB[Load Balancer] --> N1[Node 1]
        LB --> N2[Node 2]
        N1 --> G[Gateway]
    ```

    **Trade-offs:**
    ### Step 1: Consistency choice
    Pick availability for the feed path, keeping the Queue from the components.
    Builds-on: Queue from components
    Diagram delta: Adds the fan out read model
    Why now: Peak load would stall synchronous fan out
    Decision: Eventual consistency on feed fan out
    Trade-off: Stale reads under propagation lag
    ```mermaid
    flowchart LR
        Write --> Queue --> ReadModel
    ```
    ### Step 2: Storage choice
    Keeping the ReadModel, choose a wide column store over a relational one for the feed timeline.
    Builds-on: ReadModel from step 1
    Diagram delta: Replaces the read model store with Cassandra
    Why now: Timeline writes dominate at fan out time
    Decision: Wide column store for the timeline
    Trade-off: Weaker ad hoc query support
    ```mermaid
    flowchart LR
        Queue --> ReadModel[(Cassandra)]
    ```

    **Wrap-Up:**
    ### Step 1: Final architecture
    Here is the complete picture with the Gateway, cache, services, queue, and storage, plus monitoring on every hop.
    Builds-on: Every previous section
    Diagram delta: Adds monitoring and the full path end to end
    Why now: The closing walkthrough covers failure and growth
    Decision: Ship this shape and scale the read tier first
    Trade-off: None
    ```mermaid
    flowchart LR
        C[Client] --> CDN --> G[Gateway]
        G --> Cache[(Redis)]
        G --> R[Read Service] --> DB[(Cassandra)]
        G --> W[Write Service] --> Q[Queue] --> S3[(Object Storage)]
        M[Monitoring] -.-> G
    ```

    COMPLETION_CHECKLIST: Requirements=2, Estimation=2, High-Level Architecture=2, Components=1, Data Flow=1, Database Design=1, API Design=1, Scalability=1, Trade-offs=2, Wrap-Up=1
    """
}
