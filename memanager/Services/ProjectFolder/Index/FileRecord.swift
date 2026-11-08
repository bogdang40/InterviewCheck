import Foundation

/// A single row in the in memory file index. Paths are always stored relative
/// to the warmed root so queries never leak absolute paths.
struct FileRecord: Equatable, Sendable {
    let relativePath: String
    let mtime: Date
    let size: Int
    let languageKind: FileLanguageKind
    let isHidden: Bool
    let isIgnored: Bool
}

/// Coarse grained language bucket. Used by callers (outline, search) to route
/// work to the right scanner without re reading the file's extension each time.
enum FileLanguageKind: String, Equatable, Sendable {
    case swift
    case python
    case rust
    case c
    case cpp
    case objectiveC
    case javascript
    case typescript
    case go
    case markdown
    case json
    case yaml
    case shell
    case other

    static func from(path: String) -> FileLanguageKind {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .swift
        case "py": return .python
        case "rs": return .rust
        case "c", "h": return .c
        case "cpp", "cc", "cxx", "hpp", "hxx": return .cpp
        case "m", "mm": return .objectiveC
        case "js", "mjs", "cjs", "jsx": return .javascript
        case "ts", "tsx": return .typescript
        case "go": return .go
        case "md", "markdown": return .markdown
        case "json": return .json
        case "yaml", "yml": return .yaml
        case "sh", "bash", "zsh": return .shell
        default: return .other
        }
    }
}
