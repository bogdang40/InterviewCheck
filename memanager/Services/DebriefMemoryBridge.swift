import Foundation

// MARK: - Protocol

protocol DebriefMemoryBridging {
    func extractAndStore(debrief: SessionDebrief, sessionId: String)
}

// MARK: - Implementation

/// Extracts key learnings from a debrief into `MemoryNodeRecord` entries
/// for the hub memory system, enabling cross-session recall.
final class DebriefMemoryBridge: DebriefMemoryBridging {

    private let logger: SessionLogger

    init(logger: SessionLogger = .shared) {
        self.logger = logger
    }

    func extractAndStore(debrief: SessionDebrief, sessionId: String) {
        let now = Date()
        let focusNode = buildFocusNode(debrief: debrief, sessionId: sessionId, now: now)
        let drillNodes = buildDrillNodes(debrief: debrief, sessionId: sessionId, now: now)

        logger.upsertMemoryNode(focusNode)
        for node in drillNodes {
            logger.upsertMemoryNode(node)
        }

        linkFocusToDrills(focusNodeId: focusNode.id, drillNodes: drillNodes, now: now)
    }

    // MARK: - Focus Node

    private func buildFocusNode(
        debrief: SessionDebrief,
        sessionId: String,
        now: Date
    ) -> MemoryNodeRecord {
        let focusContent = (debrief.nextSessionFocus + debrief.missedOpportunities)
            .joined(separator: " | ")

        let tags = ["debrief", "focus", "next_session"]

        return MemoryNodeRecord(
            id: "debrief_focus_\(debrief.id)",
            sessionId: sessionId,
            sourceType: .debrief,
            sourceRef: debrief.id,
            content: focusContent,
            summary: debrief.nextSessionFocus.first,
            tags: tags,
            importance: 4,
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: - Drill Nodes

    private func buildDrillNodes(
        debrief: SessionDebrief,
        sessionId: String,
        now: Date
    ) -> [MemoryNodeRecord] {
        debrief.drills.map { drill in
            let content = "\(drill.kind.displayLabel): \(drill.prompt)"
                + (drill.transcriptSpan.isEmpty ? "" : " | context: \(drill.transcriptSpan)")

            return MemoryNodeRecord(
                id: "debrief_drill_\(drill.id)",
                sessionId: sessionId,
                sourceType: .debrief,
                sourceRef: debrief.id,
                threadId: drill.relatedThreadId,
                turnId: drill.relatedTurnId,
                content: content,
                summary: drill.title,
                tags: ["debrief", "drill", drill.kind.rawValue],
                importance: 3,
                createdAt: now,
                updatedAt: now
            )
        }
    }

    // MARK: - Relationships

    private func linkFocusToDrills(
        focusNodeId: String,
        drillNodes: [MemoryNodeRecord],
        now: Date
    ) {
        for node in drillNodes {
            let relationship = MemoryRelationshipRecord(
                fromNodeId: focusNodeId,
                toNodeId: node.id,
                relationType: .supportsAnswer,
                strength: 3,
                createdAt: now
            )
            logger.linkMemoryNodes(relationship)
        }
    }
}
