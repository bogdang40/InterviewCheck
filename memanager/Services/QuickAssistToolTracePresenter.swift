import Foundation

final class QuickAssistToolTracePresenter {
    func present(records: [SessionToolCallRecord], turnID: UUID?) -> QuickAssistToolTrace {
        present(inputs: records.map(Self.input(from:)), turnID: turnID)
    }

    func present(events: [ProjectToolCallEvent], turnID: UUID? = nil) -> QuickAssistToolTrace {
        present(inputs: events.map(Self.input(from:)), turnID: turnID)
    }

    func present(inputs: [QuickAssistToolTraceInput], turnID: UUID?) -> QuickAssistToolTrace {
        let steps = inputs.map(makeStep).sorted {
            if $0.iteration == $1.iteration {
                return $0.startedAt < $1.startedAt
            }
            return $0.iteration < $1.iteration
        }
        return QuickAssistToolTrace(turnID: turnID, steps: steps)
    }

    private func makeStep(from input: QuickAssistToolTraceInput) -> QuickAssistToolTraceStep {
        let arguments = decodeArguments(input.rawArgumentsJSON)
        let parsed = parseEvidence(toolName: input.toolName, arguments: arguments, resultContent: input.resultContent)
        return QuickAssistToolTraceStep(
            id: input.id,
            toolName: input.toolName,
            state: input.state,
            iteration: input.iteration,
            displayInput: input.displayInput,
            rawArgumentsJSON: input.rawArgumentsJSON,
            resultContent: input.resultContent,
            contentTruncated: input.contentTruncated,
            overflowPath: input.overflowPath,
            startedAt: input.startedAt,
            durationMs: input.durationMs,
            evidenceKind: parsed.kind,
            referencedFiles: parsed.references
        )
    }

    private func parseEvidence(
        toolName: String,
        arguments: [String: Any],
        resultContent: String?
    ) -> (kind: QuickAssistToolEvidenceKind, references: [QuickAssistToolFileReference]) {
        switch toolName {
        case "search_files":
            return parseSearch(arguments: arguments, resultContent: resultContent)
        case "read_file":
            return parseRead(arguments: arguments, resultContent: resultContent)
        case "list_directory", "glob", "get_structure":
            return parseDirectory(arguments: arguments, resultContent: resultContent)
        default:
            return parseGeneric(resultContent: resultContent)
        }
    }

    private func parseSearch(arguments: [String: Any], resultContent: String?) -> (QuickAssistToolEvidenceKind, [QuickAssistToolFileReference]) {
        let groups = groupedMatches(from: resultContent)
        if groups.isEmpty {
            return parseGeneric(resultContent: resultContent)
        }
        let references = groups.map { group in
            QuickAssistToolFileReference(path: group.path, lines: group.lines.map(\.lineNumber))
        }
        return (
            .search(
                pattern: arguments["pattern"] as? String,
                scopePath: arguments["path"] as? String,
                groups: groups
            ),
            references
        )
    }

    private func parseRead(arguments: [String: Any], resultContent: String?) -> (QuickAssistToolEvidenceKind, [QuickAssistToolFileReference]) {
        guard let path = arguments["path"] as? String,
              let resultContent,
              let excerpt = readExcerpt(path: path, resultContent: resultContent) else {
            return parseGeneric(resultContent: resultContent)
        }
        let references = [QuickAssistToolFileReference(path: path, lines: Array(excerpt.startLine...excerpt.endLine))]
        return (.read(excerpt), references)
    }

    private func parseDirectory(arguments: [String: Any], resultContent: String?) -> (QuickAssistToolEvidenceKind, [QuickAssistToolFileReference]) {
        let rawPath = (arguments["path"] as? String) ?? ""
        let entries = (resultContent ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("(truncated") }
        return (.directory(.init(path: rawPath.isEmpty ? "." : rawPath, entries: Array(entries.prefix(12)))), [])
    }

    private func parseGeneric(resultContent: String?) -> (QuickAssistToolEvidenceKind, [QuickAssistToolFileReference]) {
        let preview = (resultContent ?? "")
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(8)
            .joined(separator: "\n")
        let references = groupedMatches(from: resultContent).map { group in
            QuickAssistToolFileReference(path: group.path, lines: group.lines.map(\.lineNumber))
        }
        return (.generic(preview: preview), references)
    }

    private func groupedMatches(from resultContent: String?) -> [QuickAssistToolSearchGroup] {
        let lines = (resultContent ?? "").components(separatedBy: .newlines)
        var grouped: [String: [QuickAssistToolSearchMatchLine]] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let pieces = trimmed.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard pieces.count == 3, let lineNumber = Int(pieces[1]) else { continue }
            let path = String(pieces[0])
            let text = String(pieces[2]).trimmingCharacters(in: .whitespaces)
            let isContext = line != trimmed
            grouped[path, default: []].append(
                QuickAssistToolSearchMatchLine(lineNumber: lineNumber, text: text, isContext: isContext)
            )
        }
        return grouped
            .map { QuickAssistToolSearchGroup(path: $0.key, lines: $0.value) }
            .sorted { $0.path < $1.path }
    }

    private func readExcerpt(path: String, resultContent: String) -> QuickAssistToolReadExcerpt? {
        let regex = try? NSRegularExpression(pattern: #"^\s*(\d+)\s{2}(.*)$"#, options: [])
        let parsedLines = resultContent
            .components(separatedBy: .newlines)
            .compactMap { line -> (Int, String)? in
                guard let regex else { return nil }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard let match = regex.firstMatch(in: line, options: [], range: range),
                      let numberRange = Range(match.range(at: 1), in: line),
                      let textRange = Range(match.range(at: 2), in: line),
                      let number = Int(line[numberRange]) else { return nil }
                let text = String(line[textRange])
                return (number, text)
            }
        guard let startLine = parsedLines.first?.0, let endLine = parsedLines.last?.0 else { return nil }
        let snippet = parsedLines
            .map { "\($0.0): \($0.1)" }
            .joined(separator: "\n")
        return QuickAssistToolReadExcerpt(path: path, startLine: startLine, endLine: endLine, snippet: snippet)
    }

    private func decodeArguments(_ rawArgumentsJSON: String) -> [String: Any] {
        guard let data = rawArgumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = object as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    private static func input(from record: SessionToolCallRecord) -> QuickAssistToolTraceInput {
        QuickAssistToolTraceInput(
            id: [
                record.turnID ?? "no-turn",
                record.toolName,
                String(record.iteration),
                String(Int(record.startedAt.timeIntervalSince1970 * 1000))
            ].joined(separator: "|"),
            toolName: record.toolName,
            state: record.isError ? .failed : .completed,
            iteration: record.iteration,
            displayInput: record.displayInput ?? record.argumentsJSON,
            rawArgumentsJSON: record.argumentsJSON,
            resultContent: record.resultContent ?? record.resultPreview,
            contentTruncated: record.contentTruncated,
            overflowPath: record.overflowPath,
            startedAt: record.startedAt,
            durationMs: record.durationMs
        )
    }

    private static func input(from event: ProjectToolCallEvent) -> QuickAssistToolTraceInput {
        QuickAssistToolTraceInput(
            id: event.callID,
            toolName: event.toolName,
            state: {
                switch event.phase {
                case .started: return .running
                case .completed: return .completed
                case .failed: return .failed
                }
            }(),
            iteration: 0,
            displayInput: event.displayInput,
            rawArgumentsJSON: event.rawArgumentsJSON,
            resultContent: event.resultContent,
            contentTruncated: event.contentTruncated,
            overflowPath: event.overflowPath,
            startedAt: event.startedAt,
            durationMs: event.durationMs
        )
    }
}
