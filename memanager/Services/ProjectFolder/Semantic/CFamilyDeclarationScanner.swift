import Foundation

final class CFamilyDeclarationScanner: ProjectSemanticScanner {
    private let includeRegex = try! NSRegularExpression(pattern: #"^\s*#include\s+[<"]([^>"]+)[>"]"#)
    private let classRegex = try! NSRegularExpression(pattern: #"^\s*(?:template\s*<[^>]+>\s*)?(class|struct)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*([^/{]+))?"#)
    private let enumRegex = try! NSRegularExpression(pattern: #"^\s*enum(?:\s+class)?\s+([A-Za-z_][A-Za-z0-9_]*)"#)
    private let typedefRegex = try! NSRegularExpression(pattern: #"^\s*typedef\s+.*?\s+([A-Za-z_][A-Za-z0-9_]*)\s*;"#)
    private let functionRegex = try! NSRegularExpression(pattern: #"^\s*[A-Za-z_][A-Za-z0-9_\s\*&:<>]*\s+([A-Za-z_][A-Za-z0-9_:]*)\s*\([^;{]*\)\s*(?:\{|;)"#)

    let supportedExtensions: Set<String> = ["c", "h", "hpp", "hh", "hxx", "cpp", "cc", "cxx"]

    func scan(file: ProjectTextFile) -> ProjectSemanticFileScan {
        var imports: [ProjectImportStatement] = []
        var declarations: [ProjectDeclaration] = []
        var braceDepth = 0

        for (index, rawLine) in file.lines.enumerated() {
            let lineNumber = index + 1
            let line = stripComment(from: rawLine)
            if let statement = importStatement(from: line, line: lineNumber) {
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

    private func importStatement(from line: String, line lineNumber: Int) -> ProjectImportStatement? {
        guard let match = includeRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return ProjectImportStatement(module: String(line[range]), line: lineNumber)
    }

    private func declaration(from line: String, line lineNumber: Int) -> ProjectDeclaration? {
        if let match = classRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let nameRange = Range(match.range(at: 2), in: line) {
            let baseRange = Range(match.range(at: 3), in: line)
            let inherited = baseRange.map { parseBases(String(line[$0])) } ?? []
            return ProjectDeclaration(
                kind: line.contains("class ") ? .class : .struct,
                name: String(line[nameRange]),
                line: lineNumber,
                signature: line.trimmingCharacters(in: .whitespaces),
                inheritedTypes: inherited
            )
        }
        if let match = enumRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let nameRange = Range(match.range(at: 1), in: line) {
            return ProjectDeclaration(
                kind: .enum,
                name: String(line[nameRange]),
                line: lineNumber,
                signature: line.trimmingCharacters(in: .whitespaces),
                inheritedTypes: []
            )
        }
        if let match = typedefRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let nameRange = Range(match.range(at: 1), in: line) {
            return ProjectDeclaration(
                kind: .typealias,
                name: String(line[nameRange]),
                line: lineNumber,
                signature: line.trimmingCharacters(in: .whitespaces),
                inheritedTypes: []
            )
        }
        guard let match = functionRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let nameRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        let rawName = String(line[nameRange])
        return ProjectDeclaration(
            kind: .function,
            name: rawName.split(separator: "::").last.map(String.init) ?? rawName,
            line: lineNumber,
            signature: line.trimmingCharacters(in: .whitespaces),
            inheritedTypes: []
        )
    }

    private func parseBases(_ raw: String) -> [String] {
        raw.split(separator: ",").map {
            $0
                .replacingOccurrences(of: "public ", with: "")
                .replacingOccurrences(of: "protected ", with: "")
                .replacingOccurrences(of: "private ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private func stripComment(from line: String) -> String {
        guard let range = line.range(of: "//") else { return line }
        return String(line[..<range.lowerBound])
    }
}
