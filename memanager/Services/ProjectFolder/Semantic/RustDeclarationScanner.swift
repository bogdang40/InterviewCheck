import Foundation

final class RustDeclarationScanner: ProjectSemanticScanner {
    private let useRegex = try! NSRegularExpression(pattern: #"^\s*use\s+([^;]+);"#)
    private let traitRegex = try! NSRegularExpression(pattern: #"^\s*(?:pub\s+)?trait\s+([A-Za-z_][A-Za-z0-9_]*)"#)
    private let structRegex = try! NSRegularExpression(pattern: #"^\s*(?:pub\s+)?struct\s+([A-Za-z_][A-Za-z0-9_]*)"#)
    private let enumRegex = try! NSRegularExpression(pattern: #"^\s*(?:pub\s+)?enum\s+([A-Za-z_][A-Za-z0-9_]*)"#)
    private let typeRegex = try! NSRegularExpression(pattern: #"^\s*(?:pub\s+)?type\s+([A-Za-z_][A-Za-z0-9_]*)"#)
    private let functionRegex = try! NSRegularExpression(pattern: #"^\s*(?:pub\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#)
    private let implForRegex = try! NSRegularExpression(pattern: #"^\s*impl(?:<[^>]+>)?\s+([A-Za-z_][A-Za-z0-9_:<>]*)\s+for\s+([A-Za-z_][A-Za-z0-9_:<>]*)"#)
    private let implRegex = try! NSRegularExpression(pattern: #"^\s*impl(?:<[^>]+>)?\s+([A-Za-z_][A-Za-z0-9_:<>]*)"#)

    let supportedExtensions: Set<String> = ["rs"]

    func scan(file: ProjectTextFile) -> ProjectSemanticFileScan {
        var imports: [ProjectImportStatement] = []
        var declarations: [ProjectDeclaration] = []
        var braceDepth = 0

        for (index, rawLine) in file.lines.enumerated() {
            let lineNumber = index + 1
            let line = stripComment(from: rawLine)
            if let statement = parse(regex: useRegex, in: line, line: lineNumber) {
                imports.append(statement)
            }
            if braceDepth == 0, let declaration = declaration(from: line, line: lineNumber) {
                declarations.append(declaration)
            }
            braceDepth += line.reduce(into: 0) { delta, character in
                if character == "{" { delta += 1 }
                if character == "}" { delta -= 1 }
            }
            braceDepth = max(braceDepth, 0)
        }

        return ProjectSemanticFileScan(imports: imports, markers: [], declarations: declarations)
    }

    private func declaration(from line: String, line lineNumber: Int) -> ProjectDeclaration? {
        if let declaration = typeDeclaration(from: line, regex: traitRegex, kind: .trait, line: lineNumber) { return declaration }
        if let declaration = typeDeclaration(from: line, regex: structRegex, kind: .struct, line: lineNumber) { return declaration }
        if let declaration = typeDeclaration(from: line, regex: enumRegex, kind: .enum, line: lineNumber) { return declaration }
        if let declaration = typeDeclaration(from: line, regex: typeRegex, kind: .typealias, line: lineNumber) { return declaration }
        if let declaration = implDeclaration(from: line, line: lineNumber) { return declaration }
        return typeDeclaration(from: line, regex: functionRegex, kind: .function, line: lineNumber)
    }

    private func typeDeclaration(
        from line: String,
        regex: NSRegularExpression,
        kind: ProjectDeclarationKind,
        line lineNumber: Int
    ) -> ProjectDeclaration? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let nameRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return ProjectDeclaration(
            kind: kind,
            name: normalizeTypeName(String(line[nameRange])),
            line: lineNumber,
            signature: line.trimmingCharacters(in: .whitespaces),
            inheritedTypes: []
        )
    }

    private func implDeclaration(from line: String, line lineNumber: Int) -> ProjectDeclaration? {
        if let match = implForRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let traitRange = Range(match.range(at: 1), in: line),
           let typeRange = Range(match.range(at: 2), in: line) {
            return ProjectDeclaration(
                kind: .impl,
                name: normalizeTypeName(String(line[typeRange])),
                line: lineNumber,
                signature: line.trimmingCharacters(in: .whitespaces),
                inheritedTypes: [normalizeTypeName(String(line[traitRange]))]
            )
        }
        guard let match = implRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let typeRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return ProjectDeclaration(
            kind: .impl,
            name: normalizeTypeName(String(line[typeRange])),
            line: lineNumber,
            signature: line.trimmingCharacters(in: .whitespaces),
            inheritedTypes: []
        )
    }

    private func parse(regex: NSRegularExpression, in line: String, line lineNumber: Int) -> ProjectImportStatement? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return ProjectImportStatement(module: String(line[range]).trimmingCharacters(in: .whitespaces), line: lineNumber)
    }

    private func stripComment(from line: String) -> String {
        guard let range = line.range(of: "//") else { return line }
        return String(line[..<range.lowerBound])
    }

    private func normalizeTypeName(_ raw: String) -> String {
        let noGenerics = raw.split(separator: "<", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        return noGenerics.split(separator: "::").last.map(String.init) ?? noGenerics
    }
}
