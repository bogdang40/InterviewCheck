import Foundation

/// Context passed to every tool call. Carries the resolved sandbox root and the configuration
/// used to enforce per tool caps.
struct ProjectToolContext {
    let rootURL: URL
    let config: ProjectFolderConfig
    let access: ProjectFolderAccess
    let fileTime: FileTimeRegistry?
    let fsIndex: FSIndexActor?

    init(
        rootURL: URL,
        config: ProjectFolderConfig,
        access: ProjectFolderAccess,
        fileTime: FileTimeRegistry? = nil,
        fsIndex: FSIndexActor? = nil
    ) {
        self.rootURL = rootURL
        self.config = config
        self.access = access
        self.fileTime = fileTime
        self.fsIndex = fsIndex
    }
}

/// All project folder tools conform to this protocol. They take a JSON argument dictionary and
/// return a `ToolResult`. They must be strictly read only.
protocol ProjectTool {
    var name: String { get }
    var description: String { get }
    var inputSchema: JSONObject { get }
    func execute(callID: String, arguments: [String: Any], context: ProjectToolContext) async -> ToolResult
}

/// Small helpers that every tool uses.
enum ProjectToolHelpers {
    static func stringArgument(_ arguments: [String: Any], _ key: String) -> String? {
        arguments[key] as? String
    }

    static func intArgument(_ arguments: [String: Any], _ key: String) -> Int? {
        arguments[key] as? Int
    }

    static func boolArgument(_ arguments: [String: Any], _ key: String, default defaultValue: Bool = false) -> Bool {
        (arguments[key] as? Bool) ?? defaultValue
    }

    static func dictionaryArrayArgument(_ arguments: [String: Any], _ key: String) -> [[String: Any]]? {
        arguments[key] as? [[String: Any]]
    }

    static func truncate(_ content: String, maxCharacters: Int) -> (String, Bool) {
        if content.count <= maxCharacters { return (content, false) }
        return (String(content.prefix(maxCharacters)), true)
    }

    static func isSensitivePath(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        if ProjectFolderConfig.sensitivePatterns.contains(where: {
            let pattern = $0.lowercased()
            return filename.hasPrefix(pattern) || filename == pattern
        }) {
            return true
        }
        let ext = (filename as NSString).pathExtension
        return ProjectFolderConfig.sensitiveExtensions.contains(ext)
    }
}
