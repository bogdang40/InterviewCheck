import Foundation

enum ProjectFolderCapabilities {
    static let toolCount = 12

    static let helpText = """
    When enabled and a folder is selected, Quick Assist can list, read, search, glob, inspect, describe structure, find symbols, trace references, outline files, batch read files, locate related files, and map type relationships in that folder during a turn. Content search and glob run through ripgrep so they respect .gitignore, support context lines, file type filters, and multiline patterns, and return results ranked newest first. A live in memory index warmed by FSEvents makes repeated enumeration near instantaneous. File reads stream on demand with offset, limit, and a byte budget; images and PDFs return as base64 attachments. Up to four tool calls run in parallel each turn. Language aware semantic parsing covers Swift, Python, Rust, C, and C++. Nothing is ever written or executed.
    """
}
