import Foundation

final class PythonDeclarationScanner: ProjectSemanticScanner {
    private let importRegex = try! NSRegularExpression(pattern: #"^\s*(?:from\s+([A-Za-z_][A-Za-z0-9_\.]*)\s+import|import\s+([A-Za-z_][A-Za-z0-9_\.]*))"#)
    private let markerRegex = try! NSRegularExpression(pattern: #"^\s*#\s*(?:MARK:|region)\s*(.+)$"#, options: [.caseInsensitive])
    private let classRegex = try! NSRegularExpression(pattern: #"^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(([^)]*)\))?\s*:"#)
    private let functionRegex = try! NSRegularExpression(pattern: #"^\s*def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#)

    let supportedExtensions: Set<String> = ["py"]

    func scan(file: ProjectTextFile) -> ProjectSemanticFileScan {
        var imports: [ProjectImportStatement] = []
        var markers: [ProjectOutlineMarker] = []
        var declarations: [ProjectDeclaration] = []

        for (index, line) in file.lines.enumerated() {
            let lineNumber = index + 1
            if let statement = importStatement(from: line, line: lineNumber) {
                imports.append(statement)
            }
            if let marker = marker(from: line, line: lineNumber) {
                markers.append(marker)
            }
            guard lineHasTopLevelIndentation(line) else { continue }
            if let declaration = classDeclaration(from: line, line: lineNumber) {
                declarations.append(declaration)
                continue
            }
            if let declaration = functionDeclaration(from: line, line: lineNumber) {
                declarations.append(declaration)
            }
        }

        return ProjectSemanticFileScan(imports: imports, markers: markers, declarations: declarations)
    }

    private func importStatement(from line: String, line lineNumber: Int) -> ProjectImportStatement? {
        guard let match = importRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }
        for index in 1...2 {
            guard let range = Range(match.range(at: index), in: line) else { continue }
            return ProjectImportStatement(module: String(line[range]), line: lineNumber)
        }
        return nil
    }

    private func marker(from line: String, line lineNumber: Int) -> ProjectOutlineMarker? {
        guard let match = markerRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return ProjectOutlineMarker(title: String(line[range]).trimmingCharacters(in: .whitespaces), line: lineNumber)
    }

    private func classDeclaration(from line: String, line lineNumber: Int) -> ProjectDeclaration? {
        guard let match = classRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let nameRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        let basesRange = Range(match.range(at: 2), in: line)
        let bases = basesRange.map { inheritedTypes(from: String(line[$0])) } ?? []
        return ProjectDeclaration(
            kind: .class,
            name: String(line[nameRange]),
            line: lineNumber,
            signature: line.trimmingCharacters(in: .whitespaces),
            inheritedTypes: bases
        )
    }

    private func functionDeclaration(from line: String, line lineNumber: Int) -> ProjectDeclaration? {
        guard let match = functionRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let nameRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return ProjectDeclaration(
            kind: .function,
            name: String(line[nameRange]),
            line: lineNumber,
            signature: line.trimmingCharacters(in: .whitespaces),
            inheritedTypes: []
        )
    }

    private func lineHasTopLevelIndentation(_ line: String) -> Bool {
        let leadingWhitespace = line.prefix { $0 == " " || $0 == "\t" }
        return leadingWhitespace.isEmpty
    }

    private func inheritedTypes(from raw: String) -> [String] {
        raw.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
