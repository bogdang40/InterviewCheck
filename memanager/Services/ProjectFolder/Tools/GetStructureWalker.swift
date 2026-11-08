import Foundation

/// Legacy walker used by `GetStructureTool` when the `FSIndexActor` has not
/// warmed yet. Kept in its own file so the tool's primary async path stays
/// concise.
enum GetStructureWalker {
    static func append(
        url: URL,
        depth: Int,
        maxDepth: Int,
        indent: Int,
        output: inout [String],
        config: ProjectFolderConfig
    ) {
        if depth > 0 {
            let prefix = String(repeating: "  ", count: indent)
            output.append(prefix + url.lastPathComponent + (isDirectory(url) ? "/" : ""))
        }
        guard depth < maxDepth, isDirectory(url) else { return }
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let contents = try? manager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }
        let sorted = contents
            .filter { !config.excludePatterns.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in sorted {
            append(
                url: child,
                depth: depth + 1,
                maxDepth: maxDepth,
                indent: indent + 1,
                output: &output,
                config: config
            )
            if output.count > 1000 { return }
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
