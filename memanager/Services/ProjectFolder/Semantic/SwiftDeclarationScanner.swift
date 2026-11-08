import Foundation

final class SwiftDeclarationScanner: ProjectSemanticScanner {
    private struct PendingHeader {
        let line: Int
        var text: String
        var remainingLines: Int
    }

    private let importRegex = try! NSRegularExpression(pattern: #"^\s*import\s+([A-Za-z_][A-Za-z0-9_\.]*)"#)
    private let markerRegex = try! NSRegularExpression(pattern: #"MARK:\s*-?\s*(.+)$"#)
    private let declarationRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+|(?:public|private|internal|fileprivate|open|final|indirect|nonisolated|convenience|required|override|lazy|weak|unowned|static|class|distributed|consuming|borrowing|mutating|nonmutating)\s+)*(class|struct|enum|actor|protocol|extension|typealias)\s+([A-Za-z_][A-Za-z0-9_\.<>`]*)"#,
        options: []
    )

    let supportedExtensions: Set<String> = ["swift"]

    func scan(file: ProjectTextFile) -> ProjectSemanticFileScan {
        scan(relativePath: file.relativePath, text: file.text)
    }

    func scan(relativePath: String, text: String) -> ProjectSemanticFileScan {
        let lines = text.components(separatedBy: "\n")
        var sanitizer = SwiftSourceSanitizer()
        var state = SwiftSourceSanitizer.State()
        var braceDepth = 0
        var imports: [SwiftImportStatement] = []
        var markers: [SwiftOutlineMarker] = []
        var declarations: [SwiftDeclaration] = []
        var pending: PendingHeader?

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let sanitized = sanitizer.sanitize(rawLine, state: &state)
            let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)

            if let marker = parseMarker(in: rawLine, line: lineNumber) {
                markers.append(marker)
            }

            if var pendingHeader = pending {
                if !trimmed.isEmpty {
                    pendingHeader.text += " " + trimmed
                }
                pendingHeader.remainingLines -= 1
                if sanitized.contains("{") || pendingHeader.remainingLines == 0 {
                    if let declaration = parseDeclaration(header: pendingHeader.text, line: pendingHeader.line) {
                        declarations.append(declaration)
                    }
                    pending = nil
                } else {
                    pending = pendingHeader
                }
            } else if braceDepth == 0 {
                if let statement = parseImport(in: trimmed, line: lineNumber) {
                    imports.append(statement)
                }
                if isDeclarationStart(trimmed) {
                    let header = PendingHeader(line: lineNumber, text: trimmed, remainingLines: 4)
                    if sanitized.contains("{") {
                        if let declaration = parseDeclaration(header: header.text, line: header.line) {
                            declarations.append(declaration)
                        }
                    } else {
                        pending = header
                    }
                }
            }

            braceDepth += sanitizer.braceDelta(in: sanitized)
            braceDepth = max(braceDepth, 0)
        }

        if let pending, let declaration = parseDeclaration(header: pending.text, line: pending.line) {
            declarations.append(declaration)
        }

        return ProjectSemanticFileScan(imports: imports, markers: markers, declarations: declarations)
    }

    private func parseImport(in line: String, line lineNumber: Int) -> SwiftImportStatement? {
        guard let match = importRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return SwiftImportStatement(module: String(line[range]), line: lineNumber)
    }

    private func parseMarker(in line: String, line lineNumber: Int) -> SwiftOutlineMarker? {
        guard let match = markerRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return SwiftOutlineMarker(title: String(line[range]).trimmingCharacters(in: .whitespaces), line: lineNumber)
    }

    private func isDeclarationStart(_ line: String) -> Bool {
        declarationRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private func parseDeclaration(header: String, line lineNumber: Int) -> SwiftDeclaration? {
        guard let match = declarationRegex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let kindRange = Range(match.range(at: 1), in: header),
              let nameRange = Range(match.range(at: 2), in: header),
              let kind = SwiftDeclarationKind(rawValue: String(header[kindRange])) else {
            return nil
        }

        let rawName = String(header[nameRange])
        let name = normalizeTypeName(rawName)
        let inheritedTypes = parseInheritedTypes(header: header, name: rawName)
        let signature = header
            .replacingOccurrences(of: "{", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return SwiftDeclaration(
            kind: kind,
            name: name,
            line: lineNumber,
            signature: signature,
            inheritedTypes: inheritedTypes
        )
    }

    private func parseInheritedTypes(header: String, name: String) -> [String] {
        guard let nameRange = header.range(of: name) else { return [] }
        let suffix = header[nameRange.upperBound...]
        guard let colonIndex = suffix.firstIndex(of: ":") else { return [] }

        let trailing = suffix[suffix.index(after: colonIndex)...]
        let terminators = [" where ", "{", "="]
        let inheritedPortion = terminators.reduce(String(trailing)) { partial, terminator in
            guard let range = partial.range(of: terminator) else { return partial }
            return String(partial[..<range.lowerBound])
        }
        return inheritedPortion
            .split(separator: ",")
            .map { normalizeTypeName(String($0)) }
            .filter { !$0.isEmpty }
    }

    private func normalizeTypeName(_ rawName: String) -> String {
        let noGenerics = rawName.split(separator: "<", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawName
        let noBackticks = noGenerics.replacingOccurrences(of: "`", with: "")
        let trimmed = noBackticks.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.split(separator: ".").last {
            return String(last)
        }
        return trimmed
    }
}
