import Foundation

enum QuickAssistToolTraceStepState: String, Equatable {
    case running
    case completed
    case failed
}

struct QuickAssistToolTraceInput: Equatable {
    let id: String
    let toolName: String
    let state: QuickAssistToolTraceStepState
    let iteration: Int
    let displayInput: String
    let rawArgumentsJSON: String
    let resultContent: String?
    let contentTruncated: Bool
    let overflowPath: String?
    let startedAt: Date
    let durationMs: Int?
}

struct QuickAssistToolFileReference: Identifiable, Equatable, Hashable {
    let path: String
    let lines: [Int]

    var id: String {
        "\(path)#\(lines.map(String.init).joined(separator: ","))"
    }

    var lineSummary: String? {
        guard !lines.isEmpty else { return nil }
        let rendered = lines.sorted().prefix(6).map(String.init).joined(separator: ", ")
        let suffix = lines.count > 6 ? " +" : ""
        return "Lines \(rendered)\(suffix)"
    }
}

struct QuickAssistToolSearchMatchLine: Identifiable, Equatable {
    let lineNumber: Int
    let text: String
    let isContext: Bool

    var id: String {
        "\(lineNumber):\(isContext ? "ctx" : "match"):\(text)"
    }
}

struct QuickAssistToolSearchGroup: Identifiable, Equatable {
    let path: String
    let lines: [QuickAssistToolSearchMatchLine]

    var id: String { path }
}

struct QuickAssistToolReadExcerpt: Equatable {
    let path: String
    let startLine: Int
    let endLine: Int
    let snippet: String
}

struct QuickAssistToolDirectoryEvidence: Equatable {
    let path: String
    let entries: [String]
}

enum QuickAssistToolEvidenceKind: Equatable {
    case search(pattern: String?, scopePath: String?, groups: [QuickAssistToolSearchGroup])
    case read(QuickAssistToolReadExcerpt)
    case directory(QuickAssistToolDirectoryEvidence)
    case generic(preview: String)
}

struct QuickAssistToolTraceStep: Identifiable, Equatable {
    let id: String
    let toolName: String
    let state: QuickAssistToolTraceStepState
    let iteration: Int
    let displayInput: String
    let rawArgumentsJSON: String
    let resultContent: String?
    let contentTruncated: Bool
    let overflowPath: String?
    let startedAt: Date
    let durationMs: Int?
    let evidenceKind: QuickAssistToolEvidenceKind
    let referencedFiles: [QuickAssistToolFileReference]

    var previewText: String {
        switch evidenceKind {
        case .search(_, _, let groups):
            return groups
                .prefix(2)
                .flatMap(\.lines)
                .prefix(3)
                .map { "\($0.lineNumber): \($0.text)" }
                .joined(separator: "\n")
        case .read(let excerpt):
            return excerpt.snippet
        case .directory(let evidence):
            return evidence.entries.prefix(6).joined(separator: "\n")
        case .generic(let preview):
            return preview
        }
    }

    var usesCodeBlockStyling: Bool {
        switch evidenceKind {
        case .search, .read:
            return true
        case .directory:
            return false
        case .generic:
            return (resultContent ?? "").contains("\n")
        }
    }
}

struct QuickAssistToolTrace: Equatable {
    let turnID: UUID?
    let steps: [QuickAssistToolTraceStep]

    var isEmpty: Bool {
        steps.isEmpty
    }

    var statusSummary: String {
        let running = steps.filter { $0.state == .running }.count
        let completed = steps.filter { $0.state == .completed }.count
        let failed = steps.filter { $0.state == .failed }.count
        return [
            running > 0 ? "\(running) running" : nil,
            completed > 0 ? "\(completed) ok" : nil,
            failed > 0 ? "\(failed) failed" : nil
        ]
        .compactMap { $0 }
        .joined(separator: "  ")
    }

    var referencedFiles: [QuickAssistToolFileReference] {
        var merged: [String: Set<Int>] = [:]
        for step in steps {
            for reference in step.referencedFiles {
                var lines = merged[reference.path, default: []]
                lines.formUnion(reference.lines)
                merged[reference.path] = lines
            }
        }
        return merged
            .map { path, lines in
                QuickAssistToolFileReference(path: path, lines: lines.sorted())
            }
            .sorted { lhs, rhs in
                if lhs.path == rhs.path {
                    return lhs.lines.lexicographicallyPrecedes(rhs.lines)
                }
                return lhs.path < rhs.path
            }
    }
}
