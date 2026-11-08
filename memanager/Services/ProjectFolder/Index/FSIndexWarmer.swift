import Foundation

/// Warms the index by calling `rg --files` once and stat ing each hit. Gitignore
/// membership is computed in a second pass (ripgrep honors .gitignore by
/// default; a file is marked ignored when it shows up in `--no-ignore` but not
/// in the normal pass).
struct FSIndexWarmer {
    let ripgrep: RipgrepService

    init(ripgrep: RipgrepService = .shared) {
        self.ripgrep = ripgrep
    }

    func warm(root: URL) async throws -> [FileRecord] {
        var visible = RipgrepService.FileListOptions(scope: root)
        visible.includeHidden = true
        visible.respectGitignore = true
        var all = RipgrepService.FileListOptions(scope: root)
        all.includeHidden = true
        all.respectGitignore = false
        async let visibleHits = ripgrep.files(visible)
        async let allHits = ripgrep.files(all)
        let visibleSet = try Set((await visibleHits).map { $0.relativePath })
        let allList = try await allHits
        var records: [FileRecord] = []
        records.reserveCapacity(allList.count)
        for hit in allList {
            let absolute = root.appendingPathComponent(hit.relativePath)
            let stamp = FileTimeRegistry.Stamp.of(url: absolute)
            records.append(FileRecord(
                relativePath: hit.relativePath,
                mtime: stamp?.mtime ?? .distantPast,
                size: stamp?.size ?? 0,
                languageKind: FileLanguageKind.from(path: hit.relativePath),
                isHidden: isHiddenPath(hit.relativePath),
                isIgnored: !visibleSet.contains(hit.relativePath)
            ))
        }
        return records
    }

    private func isHiddenPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}
