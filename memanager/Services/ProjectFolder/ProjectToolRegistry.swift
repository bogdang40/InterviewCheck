import Foundation

/// Read only registry of project folder tools. Immutable and safe to share. Registration is
/// not dynamic: adding a new tool means adding it to `allTools` here and making it conform to
/// `ProjectTool`.
final class ProjectToolRegistry {
    static let shared = ProjectToolRegistry()

    let allTools: [ProjectTool]
    private let formatter = ProjectToolDefinitionFormatter()

    private init() {
        allTools = [
            ListDirectoryTool(),
            ReadFileTool(),
            SearchFilesTool(),
            GlobTool(),
            FileInfoTool(),
            GetStructureTool(),
            FindSymbolTool(),
            FindReferencesTool(),
            GetFileOutlineTool(),
            ReadFilesBatchTool(),
            FindRelatedFilesTool(),
            FindTypeRelationshipsTool()
        ]
    }

    func tool(named name: String) -> ProjectTool? {
        allTools.first(where: { $0.name == name })
    }

    /// Produce the provider neutral tool descriptors for a given Mode. Returns an empty array
    /// when the Mode has no enabled project folder or when the tool harness is disabled.
    func toolDefinitions(for mode: Mode, rootDescriptor: ProjectToolRootDescriptor? = nil) -> [ToolDefinition] {
        guard let config = mode.projectFolder, config.isEnabled, config.bookmarkData != nil else {
            return []
        }
        let resolvedRoot = rootDescriptor ?? ProjectToolRootDescriptor(config: config)
        return allTools.map { formatter.format(tool: $0, rootDescriptor: resolvedRoot) }
    }
}
