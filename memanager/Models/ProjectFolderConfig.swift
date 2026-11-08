import Foundation

/// Per Mode optional configuration that grants the model read only access to a user selected
/// directory for the duration of a Quick Assist turn. Strictly read only by design.
struct ProjectFolderConfig: Codable, Equatable {
    var isEnabled: Bool
    var bookmarkData: Data?
    var displayPath: String
    var rootName: String
    var excludePatterns: [String]
    var maxFileSizeBytes: Int
    var maxSearchResults: Int
    var maxToolIterations: Int
    var allowSensitiveReads: Bool

    init(
        isEnabled: Bool = false,
        bookmarkData: Data? = nil,
        displayPath: String = "",
        rootName: String = "",
        excludePatterns: [String] = ProjectFolderConfig.defaultExcludes,
        maxFileSizeBytes: Int = 2_000_000,
        maxSearchResults: Int = 200,
        maxToolIterations: Int = 10,
        allowSensitiveReads: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.bookmarkData = bookmarkData
        self.displayPath = displayPath
        self.rootName = rootName
        self.excludePatterns = excludePatterns
        self.maxFileSizeBytes = maxFileSizeBytes
        self.maxSearchResults = maxSearchResults
        self.maxToolIterations = maxToolIterations
        self.allowSensitiveReads = allowSensitiveReads
    }

    static let defaultExcludes: [String] = [
        ".git", ".hg", ".svn",
        "node_modules", ".build", "DerivedData", "Pods",
        ".next", "dist", "build", "target",
        "__pycache__", ".venv", "venv",
        ".DS_Store"
    ]

    /// Sensitive filename patterns that `ReadFileTool` refuses unless `allowSensitiveReads` is true.
    static let sensitivePatterns: [String] = [
        ".env", ".env.local", ".env.production",
        "id_rsa", "id_ed25519", "id_ecdsa",
        "credentials", "secrets.yml", "secrets.yaml"
    ]

    static let sensitiveExtensions: Set<String> = ["key", "pem", "p12", "pfx"]

    var isConfigured: Bool {
        isEnabled && bookmarkData != nil
    }
}
