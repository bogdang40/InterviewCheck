import XCTest
@testable import memanager

final class KnowledgeGraphScorerTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    private func edge(_ from: UUID, _ to: UUID, _ relation: KnowledgeRelation = .relatedTo, weight: Double = 1) -> KnowledgeEdge {
        KnowledgeEdge(fromNodeID: from, toNodeID: to, relation: relation, weight: weight)
    }

    func testSeedsOutrankNeighborsAndDecayPerHop() {
        let ranked = KnowledgeGraphScorer.expand(
            seeds: [.init(nodeID: a, score: 1.0)],
            edges: [edge(a, b, .built), edge(b, c, .built), edge(c, d, .built)],
            policy: .init(maxHops: 2, hopDecay: 0.5)
        )
        let byID = Dictionary(uniqueKeysWithValues: ranked.map { ($0.nodeID, $0) })
        XCTAssertEqual(byID[a]?.score, 1.0)
        XCTAssertEqual(byID[b]?.score ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(byID[c]?.score ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertNil(byID[d], "third hop must not be reached with maxHops 2")
        XCTAssertEqual(byID[b]?.hops, 1)
        XCTAssertEqual(byID[c]?.via, b)
    }

    func testSeedsAreNeverInflatedByTheirOwnNeighbors() {
        let ranked = KnowledgeGraphScorer.expand(
            seeds: [.init(nodeID: a, score: 0.9), .init(nodeID: b, score: 0.3)],
            edges: [edge(a, b, .built), edge(b, a, .relatedTo)],
            policy: .init(maxHops: 2, hopDecay: 0.9)
        )
        let byID = Dictionary(uniqueKeysWithValues: ranked.map { ($0.nodeID, $0) })
        XCTAssertEqual(byID[a]?.score, 0.9)
        XCTAssertEqual(byID[b]?.score, 0.3)
        XCTAssertEqual(ranked.first?.nodeID, a)
    }

    func testWeakRelationsPropagateLessThanStructuralOnes() {
        let strong = KnowledgeGraphScorer.expand(seeds: [.init(nodeID: a, score: 1)], edges: [edge(a, b, .solved)])
        let weak = KnowledgeGraphScorer.expand(seeds: [.init(nodeID: a, score: 1)], edges: [edge(a, b, .mentionedIn)])
        let strongB = strong.first { $0.nodeID == b }!.score
        let weakB = weak.first { $0.nodeID == b }!.score
        XCTAssertGreaterThan(strongB, weakB)
    }

    func testNodeReachedFromTwoSeedsAccumulates() {
        let single = KnowledgeGraphScorer.expand(seeds: [.init(nodeID: a, score: 1)], edges: [edge(a, c)])
        let double = KnowledgeGraphScorer.expand(seeds: [.init(nodeID: a, score: 1), .init(nodeID: b, score: 1)], edges: [edge(a, c), edge(b, c)])
        XCTAssertGreaterThan(double.first { $0.nodeID == c }!.score, single.first { $0.nodeID == c }!.score)
    }

    func testAdjustBoostsWorkspaceMatchAndTrustsManualMore() {
        let now = Date()
        let workspace = UUID()
        let ranked = KnowledgeGraphScorer.Ranked(nodeID: a, score: 1, hops: 0, via: nil)
        let manualInWorkspace = KnowledgeNode(id: a, kind: .story, label: "x", sourceKind: .manual, workspaceID: workspace, updatedAt: now)
        let sessionElsewhere = KnowledgeNode(id: a, kind: .story, label: "x", sourceKind: .session, workspaceID: nil, updatedAt: now)
        let boosted = KnowledgeGraphScorer.adjust(ranked, node: manualInWorkspace, workspaceID: workspace, now: now)
        let plain = KnowledgeGraphScorer.adjust(ranked, node: sessionElsewhere, workspaceID: workspace, now: now)
        XCTAssertGreaterThan(boosted, plain)
        let stale = KnowledgeNode(id: a, kind: .story, label: "x", sourceKind: .manual, workspaceID: workspace, updatedAt: now.addingTimeInterval(-86_400 * 400))
        XCTAssertLessThan(KnowledgeGraphScorer.adjust(ranked, node: stale, workspaceID: workspace, now: now), boosted)
    }

    func testParallelPathsCorroborateIndependentlyOfEdgeOrder() {
        let edges = [edge(a, b, .built, weight: 1.0), edge(a, b, .relatedTo, weight: 0.6)]
        let forward = KnowledgeGraphScorer.expand(seeds: [.init(nodeID: a, score: 1)], edges: edges)
        let backward = KnowledgeGraphScorer.expand(seeds: [.init(nodeID: a, score: 1)], edges: edges.reversed())
        let forwardB = forward.first { $0.nodeID == b }!.score
        let backwardB = backward.first { $0.nodeID == b }!.score
        XCTAssertEqual(forwardB, backwardB, accuracy: 1e-9)
        // strongest path (0.55) plus half of the weaker one (0.55 * 0.6 * 0.6 = 0.198)
        XCTAssertEqual(forwardB, 0.55 + 0.099, accuracy: 1e-9)
    }

    func testOutputIsDeterministicallyOrdered() {
        let edges = [edge(a, b), edge(a, c), edge(a, d)]
        let first = KnowledgeGraphScorer.expand(seeds: [.init(nodeID: a, score: 1)], edges: edges)
        let second = KnowledgeGraphScorer.expand(seeds: [.init(nodeID: a, score: 1)], edges: edges.reversed())
        XCTAssertEqual(first.map(\.nodeID), second.map(\.nodeID))
    }

    func testLayoutKeepsEveryNodeInsideTheUnitSquareAndIsStable() {
        let nodes = [a, b, c, d].map { KnowledgeNode(id: $0, kind: .topic, label: $0.uuidString) }
        let graph = KnowledgeSubgraph(nodes: nodes, edges: [edge(a, b), edge(b, c), edge(c, d), edge(d, a)])
        let first = KnowledgeGraphLayout.positions(for: graph, pinned: a)
        let second = KnowledgeGraphLayout.positions(for: graph, pinned: a)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 4)
        for point in first.values {
            XCTAssertTrue((0...1).contains(point.x) && (0...1).contains(point.y))
        }
        XCTAssertEqual(first[a], CGPoint(x: 0.5, y: 0.5), "pinned node stays centered")
    }
}
