import Foundation

extension ProjectSemanticQueryService {
    func findSymbol(named name: String, kind: String?, path: String?) throws -> ([ProjectSymbolMatch], String?) {
        var matches: [ProjectSymbolMatch] = []
        var sawSemanticLanguage = false
        try enumerateFiles(in: path) { file in
            guard let scan = try scanFile(file) else { return true }
            sawSemanticLanguage = true
            for declaration in scan.declarations where declaration.name == name && matchesKind(declaration.kind, requested: kind) {
                matches.append(ProjectSymbolMatch(
                    kind: declaration.kind.rawValue,
                    name: declaration.name,
                    path: file.relativePath,
                    line: declaration.line,
                    signature: declaration.signature
                ))
                if matches.count >= maxResults {
                    return false
                }
            }
            return true
        }

        matches.sort { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            return symbolSort(lhs, rhs)
        }
        return (matches, sawSemanticLanguage ? nil : Self.supportedLanguageNote)
    }

    func findReferences(symbol: String, path: String?) throws -> ([ProjectReferenceMatch], String?) {
        let regex = try tokenRegex(for: symbol)
        var matches: [ProjectReferenceMatch] = []
        var sawSemanticLanguage = false

        try enumerateFiles(in: path) { file in
            guard let textFile = softLoadTextFile(file) else { return true }
            let declarationLines = (try? declarationLines(for: symbol, file: file)) ?? []
            sawSemanticLanguage = sawSemanticLanguage || scannerRegistry.supports(file.fileExtension)
            for (index, line) in textFile.lines.enumerated() where lineHasMatch(line, regex: regex) {
                let matchKind: ProjectReferenceKind
                if declarationLines.contains(index + 1) {
                    matchKind = .declaration
                } else {
                    matchKind = scannerRegistry.supports(file.fileExtension) ? .usage : .possibleUsage
                }
                matches.append(ProjectReferenceMatch(
                    kind: matchKind,
                    path: file.relativePath,
                    line: index + 1,
                    snippet: line.trimmingCharacters(in: .whitespaces)
                ))
                if matches.count >= maxResults {
                    return false
                }
            }
            return true
        }

        return (matches, sawSemanticLanguage ? nil : Self.supportedLanguageNote)
    }

    private func declarationLines(for symbol: String, file: ProjectEligibleFile) throws -> Set<Int> {
        guard let scan = try scanFile(file) else { return [] }
        return Set(scan.declarations.filter { $0.name == symbol }.map(\.line))
    }

    private func matchesKind(_ kind: ProjectDeclarationKind, requested: String?) -> Bool {
        guard let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !requested.isEmpty else {
            return true
        }
        return kind.rawValue == requested
    }

    private func tokenRegex(for symbol: String) throws -> NSRegularExpression {
        let escaped = NSRegularExpression.escapedPattern(for: symbol)
        return try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])\#(escaped)(?![A-Za-z0-9_])"#)
    }

    private func lineHasMatch(_ line: String, regex: NSRegularExpression) -> Bool {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
}
