import XCTest
@testable import memanager

final class MermaidDiagramChunkerTests: XCTestCase {
    func testChunkerSplitsLargeFlowchartIntoMultipleChunks() {
        var lines: [String] = ["flowchart TD"]
        for index in 1...34 {
            lines.append("N\(index)[Node \(index)] --> N\(index + 1)[Node \(index + 1)]")
        }

        let diagram = lines.joined(separator: "\n")
        let result = MermaidDiagramChunker.split(diagram: diagram)

        XCTAssertTrue(result.didSplit)
        XCTAssertGreaterThan(result.chunks.count, 1)
        XCTAssertEqual(result.reason, "split_flowchart_edges")
        XCTAssertTrue(result.chunks.allSatisfy { $0.diagram.contains("flowchart TD") })
    }

    func testChunkerKeepsSmallFlowchartAsSingleChunk() {
        let diagram = """
        flowchart TD
            A[Start] --> B[Validate]
            B --> C[Finish]
        """

        let result = MermaidDiagramChunker.split(diagram: diagram)
        XCTAssertFalse(result.didSplit)
        XCTAssertEqual(result.chunks.count, 1)
    }

    func testChunkerFallsBackToSingleChunkForUnsupportedStructure() {
        var lines: [String] = [
            "flowchart TD",
            "subgraph API",
            "A[Gateway] --> B[Service]",
            "end"
        ]
        for index in 1...26 {
            lines.append("B --> C\(index)[Database \(index)]")
        }
        let diagram = lines.joined(separator: "\n")

        let result = MermaidDiagramChunker.split(diagram: diagram)
        XCTAssertFalse(result.didSplit)
        XCTAssertEqual(result.reason, "uncertain_or_unsupported_structure")
    }

    func testQuickAssistAggressiveProfileSplitsEarlierThanStandard() {
        var lines: [String] = ["flowchart TD"]
        for index in 1...14 {
            lines.append("N\(index)[Node \(index)] --> N\(index + 1)[Node \(index + 1)]")
        }
        let diagram = lines.joined(separator: "\n")

        let standard = MermaidDiagramChunker.split(diagram: diagram, profile: .standard)
        let aggressive = MermaidDiagramChunker.split(diagram: diagram, profile: .quickAssistAggressive)

        XCTAssertFalse(standard.didSplit)
        XCTAssertTrue(aggressive.didSplit)
    }

    func testQuickAssistAggressiveProfileCanSplitSubgraphBlocks() {
        let diagram = """
        flowchart LR
        subgraph EdgeA
            A1[Agent A1] --> A2[Queue A2]
            A2 --> A3[Store A3]
            A3 --> A4[Metrics A4]
            A4 --> A5[Worker A5]
            A5 --> A6[Sink A6]
            A6 --> A7[Cache A7]
            A7 --> A8[Fanout A8]
            A8 --> A9[Reporter A9]
        end
        subgraph EdgeB
            B1[Agent B1] --> B2[Queue B2]
            B2 --> B3[Store B3]
            B3 --> B4[Metrics B4]
            B4 --> B5[Worker B5]
            B5 --> B6[Sink B6]
            B6 --> B7[Cache B7]
            B7 --> B8[Fanout B8]
            B8 --> B9[Reporter B9]
        end
        """

        let result = MermaidDiagramChunker.split(diagram: diagram, profile: .quickAssistAggressive)

        XCTAssertTrue(result.didSplit)
        XCTAssertEqual(result.reason, "split_flowchart_edges")
        XCTAssertTrue(result.chunks.allSatisfy { $0.diagram.contains("flowchart LR") })
    }

    func testQuickAssistChunksInjectMissingLabelDeclarationsForReferencedIds() throws {
        let diagram = """
        flowchart LR
        SRC["Source Service"] --> AGW["Agent Ingress (Pull API / Long Poll)"]
        SRC --> DEV["Device Registry Service"]
        SRC --> Q["Queue / Stream"]
        Q --> DB["SQL Metadata Store"]
        Q --> T1["Task 1"]
        Q --> T2["Task 2"]
        Q --> T3["Task 3"]
        Q --> T4["Task 4"]
        AGW --> DEV
        AGW --> Q
        DEV --> DB
        T4 --> DB
        """

        let result = MermaidDiagramChunker.split(diagram: diagram, profile: .quickAssistAggressive)
        XCTAssertTrue(result.didSplit)

        let chunk = try XCTUnwrap(result.chunks.first(where: { $0.diagram.contains("AGW --> DEV") }))
        XCTAssertTrue(chunk.diagram.contains(#"AGW["Agent Ingress (Pull API / Long Poll)"]"#))
        XCTAssertTrue(chunk.diagram.contains(#"DEV["Device Registry Service"]"#))
    }

    func testQuickAssistChunkTitlesPreferResolvedLabelsWhenAvailable() throws {
        let diagram = """
        flowchart LR
        SRC["Source Service"] --> AGW["Agent Ingress (Pull API / Long Poll)"]
        SRC --> DEV["Device Registry Service"]
        SRC --> Q["Queue / Stream"]
        Q --> DB["SQL Metadata Store"]
        Q --> T1["Task 1"]
        Q --> T2["Task 2"]
        Q --> T3["Task 3"]
        Q --> T4["Task 4"]
        AGW --> DEV
        AGW --> Q
        DEV --> DB
        T4 --> DB
        """

        let result = MermaidDiagramChunker.split(diagram: diagram, profile: .quickAssistAggressive)
        XCTAssertTrue(result.didSplit)

        let chunk = try XCTUnwrap(result.chunks.first(where: { $0.diagram.contains("AGW --> DEV") }))
        XCTAssertTrue(chunk.title.contains("Agent Ingress (Pull API / Long Poll)"))
        XCTAssertTrue(chunk.title.contains("Device Registry Service"))
        XCTAssertFalse(chunk.title.contains("AGW -> DEV"))
    }

    func testChunkTitlesFallbackToRawIdsWhenNoLabelsAreAvailable() {
        var lines: [String] = ["flowchart LR"]
        for index in 1...12 {
            lines.append("A\(index) --> A\(index + 1)")
        }
        let diagram = lines.joined(separator: "\n")

        let result = MermaidDiagramChunker.split(diagram: diagram, profile: .quickAssistAggressive)
        XCTAssertTrue(result.didSplit)
        XCTAssertEqual(result.chunks.first?.title, "Step 1: A1 -> A2")
    }
}
