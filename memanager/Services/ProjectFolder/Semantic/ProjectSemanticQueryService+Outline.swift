import Foundation

extension ProjectSemanticQueryService {
    func outline(path: String) throws -> ProjectFileOutline {
        let file = try enumerator.loadTextFile(relativePath: path)
        let rows: [ProjectOutlineRow]
        let note: String?
        if let scan = try scanTextFile(file) {
            rows = buildOutlineRows(scan: scan)
            note = nil
        } else {
            rows = fallbackScanner.outlineRows(for: file.text)
            note = Self.supportedLanguageNote
        }

        return ProjectFileOutline(
            rows: Array(rows.prefix(Self.maxOutlineRows)),
            note: note,
            isTruncated: rows.count > Self.maxOutlineRows
        )
    }

    func relatedFiles(for path: String) throws -> [ProjectRelatedFile] {
        let target = try enumerator.loadTextFile(relativePath: path)
        let targetScan = try scanTextFile(target)
        var candidates: [ProjectRelatedFile] = []

        try enumerateFiles { file in
            guard let candidate = softLoadTextFile(file) else { return true }
            let candidateScan = try? scanFile(file)
            if let ranked = relatedHeuristics.candidate(
                target: target,
                targetScan: targetScan,
                candidate: candidate,
                candidateScan: candidateScan
            ) {
                candidates.append(ranked)
            }
            return true
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.path < rhs.path
            }
            .prefix(Self.maxRelatedFiles)
            .map { $0 }
    }

    private func buildOutlineRows(scan: ProjectSemanticFileScan) -> [ProjectOutlineRow] {
        let importRows = scan.imports.map { ProjectOutlineRow(line: $0.line, kind: "import", summary: $0.module) }
        let markerRows = scan.markers.map { ProjectOutlineRow(line: $0.line, kind: "marker", summary: $0.title) }
        let declarationRows = scan.declarations.map {
            ProjectOutlineRow(line: $0.line, kind: $0.kind.rawValue, summary: $0.signature)
        }
        return (importRows + markerRows + declarationRows).sorted { lhs, rhs in lhs.line < rhs.line }
    }
}
