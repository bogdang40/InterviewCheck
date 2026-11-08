import Foundation

struct ProjectTextFile {
    let relativePath: String
    let url: URL
    let text: String
    let lines: [String]
    let size: Int
}

struct ProjectLineSlice {
    let relativePath: String
    let offset: Int
    let lines: [String]
    let totalLineCount: Int

    var formattedText: String {
        let numbered = lines.enumerated().map { index, line in
            let lineNumber = offset + index + 1
            return "\(String(format: "%6d", lineNumber))  \(line)"
        }
        var output = numbered.joined(separator: "\n")
        if isTruncated {
            let remaining = totalLineCount - (offset + lines.count)
            output.append("\n(truncated, \(remaining) more lines)")
        }
        return output
    }

    var isTruncated: Bool {
        (offset + lines.count) < totalLineCount
    }
}

struct ProjectEligibleFile {
    let relativePath: String
    let url: URL
    let size: Int
    let modifiedAt: Date
    let fileExtension: String
}

enum ProjectDeclarationKind: String {
    case `class`
    case `struct`
    case `enum`
    case actor
    case `protocol`
    case `extension`
    case `typealias`
    case function
    case trait
    case impl
}

typealias SwiftDeclarationKind = ProjectDeclarationKind

struct ProjectImportStatement {
    let module: String
    let line: Int
}

typealias SwiftImportStatement = ProjectImportStatement

struct ProjectOutlineMarker {
    let title: String
    let line: Int
}

typealias SwiftOutlineMarker = ProjectOutlineMarker

struct ProjectDeclaration {
    let kind: ProjectDeclarationKind
    let name: String
    let line: Int
    let signature: String
    let inheritedTypes: [String]
}

typealias SwiftDeclaration = ProjectDeclaration

struct ProjectSemanticFileScan {
    let imports: [ProjectImportStatement]
    let markers: [ProjectOutlineMarker]
    let declarations: [ProjectDeclaration]
}

typealias SwiftFileScan = ProjectSemanticFileScan

struct ProjectSymbolMatch {
    let kind: String
    let name: String
    let path: String
    let line: Int
    let signature: String
}

enum ProjectReferenceKind: String {
    case declaration = "declaration"
    case usage = "usage"
    case possibleUsage = "possible usage"
}

struct ProjectReferenceMatch {
    let kind: ProjectReferenceKind
    let path: String
    let line: Int
    let snippet: String
}

struct ProjectOutlineRow {
    let line: Int
    let kind: String
    let summary: String
}

struct ProjectFileOutline {
    let rows: [ProjectOutlineRow]
    let note: String?
    let isTruncated: Bool
}

struct ProjectRelatedFile {
    let path: String
    let reason: String
    let score: Int
}

struct ProjectRelationshipConformer {
    let relation: String
    let kind: String
    let name: String
    let path: String
    let line: Int
}

struct ProjectTypeRelationships {
    let declarations: [ProjectSymbolMatch]
    let extensions: [ProjectSymbolMatch]
    let inheritsFrom: [String]
    let conformsTo: [String]
    let conformers: [ProjectRelationshipConformer]
    let note: String?
}
