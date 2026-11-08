import XCTest
@testable import memanager

/// Pure presentation rules behind the Knowledge screen: kind tones, row
/// subtitles, source lines, relation sentences, message tones, and the
/// detail model's link targets.
final class KnowledgePresentationTests: XCTestCase {
    func testKindTones() {
        XCTAssertEqual(KnowledgeNodePresentation.tone(for: .story), .info)
        XCTAssertEqual(KnowledgeNodePresentation.tone(for: .project), .info)
        XCTAssertEqual(KnowledgeNodePresentation.tone(for: .skill), .success)
        XCTAssertEqual(KnowledgeNodePresentation.tone(for: .problem), .warning)
        XCTAssertEqual(KnowledgeNodePresentation.tone(for: .person), .neutral)
        XCTAssertEqual(KnowledgeNodePresentation.tone(for: .document), .neutral)
    }

    func testSubtitleFallsBackToTheKind() {
        XCTAssertEqual(KnowledgeNodePresentation.subtitle(for: KnowledgeNode(kind: .skill, label: "Go")), "Skill")
        XCTAssertEqual(KnowledgeNodePresentation.subtitle(for: KnowledgeNode(kind: .skill, label: "Go", summary: "  ")), "Skill")
        XCTAssertEqual(KnowledgeNodePresentation.subtitle(for: KnowledgeNode(kind: .skill, label: "Go", summary: "Primary language")), "Primary language")
    }

    func testSourceAndMentionLines() {
        XCTAssertEqual(KnowledgeNodePresentation.sourceLine(for: KnowledgeNode(kind: .topic, label: "t", sourceKind: .manual)), "Added by hand")
        XCTAssertEqual(KnowledgeNodePresentation.sourceLine(for: KnowledgeNode(kind: .story, label: "t", sourceKind: .manual, sourceRef: "paste:123")), "Extracted from pasted text")
        XCTAssertEqual(KnowledgeNodePresentation.sourceLine(for: KnowledgeNode(kind: .topic, label: "t", sourceKind: .session)), "Learned from a session")
        XCTAssertEqual(KnowledgeNodePresentation.sourceLine(for: KnowledgeNode(kind: .topic, label: "t", sourceKind: .workspace)), "Extracted from a workspace")
        XCTAssertEqual(KnowledgeNodePresentation.mentionLine(count: 1), "Mentioned once")
        XCTAssertEqual(KnowledgeNodePresentation.mentionLine(count: 3), "Mentioned 3 times")
    }

    func testEdgeDescriberResolvesBothEndsAndTrimsEvidence() {
        let ana = KnowledgeNode(kind: .person, label: "Ana")
        let acme = KnowledgeNode(kind: .company, label: "Acme")
        let edge = KnowledgeEdge(fromNodeID: ana.id, toNodeID: acme.id, relation: .workedAt, evidence: "  resume  ")
        let graph = KnowledgeSubgraph(nodes: [ana, acme], edges: [edge])

        let description = KnowledgeEdgeDescriber.describe(edge, in: graph)
        XCTAssertEqual(description.text, "Ana worked at Acme")
        XCTAssertEqual(description.evidence, "resume")

        let orphan = KnowledgeEdge(fromNodeID: ana.id, toNodeID: UUID(), relation: .built, evidence: "   ")
        let orphanDescription = KnowledgeEdgeDescriber.describe(orphan, in: graph)
        XCTAssertEqual(orphanDescription.text, "Ana built \(KnowledgeEdgeDescriber.unknownLabel)")
        XCTAssertNil(orphanDescription.evidence)
    }

    func testMessageToneFollowsTheWording() {
        XCTAssertEqual(KnowledgeMessageTone.tone(for: "Could not save: disk full"), .critical)
        XCTAssertEqual(KnowledgeMessageTone.tone(for: "Extraction failed: offline"), .critical)
        XCTAssertEqual(KnowledgeMessageTone.tone(for: "A skill named Go already exists."), .warning)
        XCTAssertEqual(KnowledgeMessageTone.tone(for: "Added 3 new, updated 1, linked 4."), .info)
        XCTAssertEqual(KnowledgeMessageTone.tone(for: "Knowledge graph cleared."), .info)
    }

    func testDetailModelLinkTargetsExcludeTheNodeItself() {
        let center = KnowledgeNode(kind: .project, label: "Ledger")
        let other = KnowledgeNode(kind: .skill, label: "Go")
        let model = KnowledgeNodeDetailModel(node: center, neighborhood: .empty, linkCandidates: [center, other])
        XCTAssertEqual(model.linkTargets.map(\.id), [other.id])
    }

    func testKeyValuePairsAreSortedByKey() {
        let pairs = KeyValuePair.sorted(["year": "2024", "scale": "40k", "team": "Payments"])
        XCTAssertEqual(pairs.map(\.key), ["scale", "team", "year"])
        XCTAssertEqual(pairs.map(\.id), ["scale", "team", "year"])
    }

    @MainActor
    func testPropertyEditorRejectsDataThatWouldOtherwiseBeDropped() {
        XCTAssertNotNil(KnowledgeNodeEditorSheet.propertiesIssue("team Payments"))
        XCTAssertNotNil(KnowledgeNodeEditorSheet.propertiesIssue("team:"))
        XCTAssertNotNil(KnowledgeNodeEditorSheet.propertiesIssue("team: Payments\nteam: Platform"))
        XCTAssertNil(KnowledgeNodeEditorSheet.propertiesIssue("team: Payments\nurl: https://example.com/source"))
        XCTAssertEqual(KnowledgeNodeEditorSheet.parseProperties("url: https://example.com/source"), ["url": "https://example.com/source"])
    }
}
