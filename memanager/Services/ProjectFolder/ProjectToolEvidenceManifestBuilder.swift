import Foundation

final class ProjectToolEvidenceManifestBuilder {
    private let presenter: QuickAssistToolTracePresenter

    init(presenter: QuickAssistToolTracePresenter = QuickAssistToolTracePresenter()) {
        self.presenter = presenter
    }

    func build(from inputs: [QuickAssistToolTraceInput]) -> String {
        let successful = inputs.filter { $0.state == .completed && !($0.resultContent ?? "").isEmpty }
        guard !successful.isEmpty else { return "" }
        let trace = presenter.present(inputs: successful, turnID: nil)
        let sections = trace.steps.prefix(4).map(renderStep)
        return sections.joined(separator: "\n\n")
    }

    private func renderStep(_ step: QuickAssistToolTraceStep) -> String {
        switch step.evidenceKind {
        case .read(let excerpt):
            return """
            Evidence from \(step.toolName):
            File: \(excerpt.path)
            Lines: \(excerpt.startLine)-\(excerpt.endLine)
            ```text
            \(excerpt.snippet)
            ```
            """
        case .search(let pattern, let scopePath, let groups):
            let renderedGroups = groups.prefix(2).map { group in
                let body = group.lines.prefix(4).map { line in
                    "\(line.lineNumber): \(line.text)"
                }.joined(separator: "\n")
                return """
                File: \(group.path)
                ```text
                \(body)
                ```
                """
            }.joined(separator: "\n")
            return """
            Evidence from \(step.toolName):
            Pattern: \(pattern ?? "(unknown)")
            Scope: \((scopePath?.isEmpty == false ? scopePath! : "."))
            \(renderedGroups)
            """
        case .directory(let evidence):
            let entries = evidence.entries.prefix(8).joined(separator: "\n")
            return """
            Evidence from \(step.toolName):
            Path: \(evidence.path)
            ```text
            \(entries)
            ```
            """
        case .generic(let preview):
            return """
            Evidence from \(step.toolName):
            ```text
            \(preview)
            ```
            """
        }
    }
}
