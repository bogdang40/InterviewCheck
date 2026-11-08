import Foundation

extension SessionController {
    func persistQuickAssistMemory(
        sessionID: UUID,
        threadID: String,
        turnID: String,
        question: String,
        response: String,
        intent: QuickAssistIntent,
        mode: QuickAssistContextMode,
        tier: QuickAssistModelTier,
        questionSource: QuickAssistQuestionSource,
        isFollowUp: Bool,
        routeReason: String
    ) {
        guard settings.hubMemoryEnabled else { return }

        let nodeID = UUID().uuidString
        let createdAt = Date()
        let summary = summarizeMemoryText(response, maxChars: 240)
        let tags = memoryTags(from: [
            intent.rawValue,
            mode.rawValue,
            tier.rawValue,
            questionSource.rawValue,
            question,
            routeReason
        ])

        let node = MemoryNodeRecord(
            id: nodeID,
            sessionId: sessionID.uuidString,
            sourceType: .quickAssist,
            sourceRef: "\(threadID):\(turnID)",
            threadId: threadID,
            turnId: turnID,
            questionSource: questionSource,
            intent: intent.rawValue,
            contextMode: mode.rawValue,
            content: response,
            summary: summary,
            tags: tags,
            importance: tier == .deep ? 3 : 2,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        self.logger.upsertMemoryNode(node)

        if isFollowUp, let lastQuickAssistMemoryNodeID {
            self.logger.linkMemoryNodes(
                MemoryRelationshipRecord(
                    fromNodeId: lastQuickAssistMemoryNodeID,
                    toNodeId: nodeID,
                    relationType: .followUp,
                    strength: 2,
                    createdAt: createdAt
                )
            )
        }

        if let lastSolveMemoryNodeID {
            self.logger.linkMemoryNodes(
                MemoryRelationshipRecord(
                    fromNodeId: lastSolveMemoryNodeID,
                    toNodeId: nodeID,
                    relationType: .supportsAnswer,
                    strength: 1,
                    createdAt: createdAt
                )
            )
        }

        self.lastQuickAssistMemoryNodeID = nodeID
    }
    func persistSolveMemory(
        sessionID: UUID,
        response: MentorResponse,
        solveMode: SolveMode
    ) {
        guard settings.hubMemoryEnabled else { return }

        let sections = [
            response.problem,
            response.clarifyingQuestions,
            response.implementation,
            response.tests,
            response.complexity,
            response.systemDesign
        ]
        let content = sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !content.isEmpty else { return }

        let nodeID = UUID().uuidString
        let createdAt = Date()
        let source: MemoryNodeSource = solveMode == .systemDesign ? .systemDesign : .solve
        let summary = summarizeMemoryText(content, maxChars: 260)
        let tags = memoryTags(from: [
            source.rawValue,
            response.problem,
            response.systemDesign
        ])
        let node = MemoryNodeRecord(
            id: nodeID,
            sessionId: sessionID.uuidString,
            sourceType: source,
            sourceRef: nil,
            content: content,
            summary: summary,
            tags: tags,
            importance: 3,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        self.logger.upsertMemoryNode(node)

        if let lastQuickAssistMemoryNodeID {
            self.logger.linkMemoryNodes(
                MemoryRelationshipRecord(
                    fromNodeId: lastQuickAssistMemoryNodeID,
                    toNodeId: nodeID,
                    relationType: .supportsAnswer,
                    strength: 1,
                    createdAt: createdAt
                )
            )
        }

        self.lastSolveMemoryNodeID = nodeID
    }
    private func summarizeMemoryText(_ text: String, maxChars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        return String(trimmed.prefix(maxChars))
    }
    private func memoryTags(from candidates: [String]) -> [String] {
        let rawTokens = candidates
            .joined(separator: " ")
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 }
        var seen = Set<String>()
        var tags: [String] = []
        for token in rawTokens where !seen.contains(token) {
            seen.insert(token)
            tags.append(token)
            if tags.count == 8 { break }
        }
        return tags
    }
}
