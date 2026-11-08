import Foundation

extension SessionController {
    func buildConversationHistoryThroughTurn(index: Int, maxTurns: Int = 3) -> [(role: String, content: String)] {
        guard !quickAssistTurns.isEmpty,
              index >= 0,
              index < quickAssistTurns.count else {
            return []
        }

        let lowerBound = max(0, index - maxTurns + 1)
        let range = lowerBound...index
        var history: [(role: String, content: String)] = []

        for turn in quickAssistTurns[range] {
            var userContent = ""
            if !turn.transcriptDelta.isEmpty {
                userContent += "Transcript: \(turn.transcriptDelta)\n"
            }
            if !turn.question.isEmpty {
                userContent += "Question: \(turn.question)"
            }
            if !userContent.isEmpty {
                history.append((role: "user", content: userContent.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            if !turn.response.isEmpty {
                history.append((role: "assistant", content: turn.response))
            }
        }

        return history
    }
    func buildQuickAssistSectionContext(for mode: QuickAssistContextMode) -> String {
        switch mode {
        case .conversation:
            return ""
        case .implementationContext:
            return buildImplementationContextBlock()
        case .systemDesignContext:
            return buildSystemDesignContextBlock()
        case .allSectionsContext:
            return buildAllSectionsContextBlock()
        }
    }
    func sectionContextWarning(for mode: QuickAssistContextMode, sectionContext: String) -> String? {
        switch mode {
        case .conversation:
            return nil
        case .implementationContext:
            if sectionContext.isEmpty {
                return "Implementation context unavailable. Trigger this mode after a previous implementation solve."
            }
            return nil
        case .systemDesignContext:
            if sectionContext.isEmpty {
                return "System-design context unavailable. Trigger this mode after a previous system-design solve."
            }
            return nil
        case .allSectionsContext:
            if sectionContext.isEmpty {
                return "All-sections context unavailable. Trigger this mode after a previous solve."
            }
            return nil
        }
    }
    private func buildImplementationContextBlock() -> String {
        guard let response = session.response else { return "" }
        var sections: [String] = ["IMPLEMENTATION CONTEXT FROM PREVIOUS SOLVE"]

        appendContextSection(title: "Problem", content: response.problem, into: &sections)
        appendContextSection(title: "Implementation", content: response.implementation, into: &sections)
        appendContextSection(title: "Tests", content: response.tests, into: &sections)
        appendContextSection(title: "Complexity", content: response.complexity, into: &sections)

        guard sections.count > 1 else { return "" }
        return sections.joined(separator: "\n\n")
    }
    private func buildSystemDesignContextBlock() -> String {
        var sections: [String] = ["SYSTEM DESIGN CONTEXT FROM PREVIOUS SOLVE"]

        if let structured = parsedSystemDesignContent, structured.hasContent {
            appendContextSection(
                title: "Structured Design Context",
                content: structured.rawContent,
                into: &sections
            )
        }

        if let systemDesign = session.response?.systemDesign {
            appendContextSection(
                title: "System Design",
                content: systemDesign,
                into: &sections
            )
        }

        guard sections.count > 1 else { return "" }
        return sections.joined(separator: "\n\n")
    }
    private func buildAllSectionsContextBlock() -> String {
        guard let response = session.response else { return "" }
        var sections: [String] = ["ALL SECTIONS CONTEXT FROM PREVIOUS SOLVE"]

        appendContextSection(title: "Problem", content: response.problem, into: &sections)
        appendContextSection(title: "Clarifying Questions", content: response.clarifyingQuestions, into: &sections)
        appendContextSection(title: "Implementation", content: response.implementation, into: &sections)
        appendContextSection(title: "Tests", content: response.tests, into: &sections)
        appendContextSection(title: "Complexity", content: response.complexity, into: &sections)

        if let structured = parsedSystemDesignContent, structured.hasContent {
            appendContextSection(
                title: "Structured Design Context",
                content: structured.rawContent,
                into: &sections
            )
        }

        appendContextSection(title: "System Design", content: response.systemDesign, into: &sections)
        guard sections.count > 1 else { return "" }
        return sections.joined(separator: "\n\n")
    }
    private func appendContextSection(title: String, content: String, into sections: inout [String]) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sections.append("\(title):\n\(trimmed)")
    }
    func quickAssistOutputContractStatus(
        mode: QuickAssistContextMode,
        contract: QuickAssistOutputContract
    ) -> String {
        let required = contract.requiredElements.isEmpty
            ? "none"
            : contract.requiredElements.joined(separator: ",")
        return "Quick Assist: mode=\(mode.rawValue), detail=\(contract.detailLevel.rawValue), shape=\(contract.responseShape.rawValue), required=\(required)."
    }
}
