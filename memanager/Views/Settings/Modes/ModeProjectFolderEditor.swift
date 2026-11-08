import Foundation

/// Reads and writes a mode's project folder configuration through the
/// store. Every mutation copies the current config, changes one field, and
/// hands it back, so the view never holds a stale copy. Main actor bound
/// because the store is.
@MainActor
struct ModeProjectFolderEditor {
    let store: ModeStore
    let mode: Mode

    var config: ProjectFolderConfig {
        store.mode(with: mode.id)?.projectFolder ?? ProjectFolderConfig()
    }

    func setEnabled(_ isEnabled: Bool) {
        commit(\.isEnabled, isEnabled)
    }

    func commit<Value>(_ keyPath: WritableKeyPath<ProjectFolderConfig, Value>, _ value: Value) {
        var updated = config
        updated[keyPath: keyPath] = value
        store.setProjectFolder(updated, modeID: mode.id)
    }

    func clearFolder() {
        var updated = config
        updated.bookmarkData = nil
        updated.displayPath = ""
        updated.rootName = ""
        store.setProjectFolder(updated, modeID: mode.id)
    }

    /// Stores a security scoped bookmark for the chosen folder.
    func select(folder url: URL) throws {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var updated = config
        updated.bookmarkData = bookmark
        updated.displayPath = url.path
        updated.rootName = url.lastPathComponent
        store.setProjectFolder(updated, modeID: mode.id)
    }
}

/// Pure copy for the folder row.
enum ProjectFolderPresentation {
    static func folderTitle(for config: ProjectFolderConfig) -> String {
        if config.displayPath.isEmpty { return "No folder selected" }
        return config.rootName.isEmpty ? config.displayPath : config.rootName
    }

    static func folderHelper(for config: ProjectFolderConfig) -> String {
        config.displayPath.isEmpty ? "Choose the folder Quick Assist may read." : config.displayPath
    }

    static func fileSizeCaption(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
