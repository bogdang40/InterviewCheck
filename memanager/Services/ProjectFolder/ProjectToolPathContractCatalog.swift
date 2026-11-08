import Foundation

enum ProjectToolPathContractCatalog {
    struct DirectArgumentRule: Equatable {
        let key: String
        let allowsRootSentinel: Bool
    }

    struct NestedArrayArgumentRule: Equatable {
        let arrayKey: String
        let fieldKey: String
        let allowsRootSentinel: Bool
    }

    struct Rule: Equatable {
        let toolName: String
        let directArguments: [DirectArgumentRule]
        let nestedArrayArguments: [NestedArrayArgumentRule]
    }

    static func rule(for toolName: String) -> Rule? {
        switch toolName {
        case "list_directory":
            return Rule(
                toolName: toolName,
                directArguments: [DirectArgumentRule(key: "path", allowsRootSentinel: true)],
                nestedArrayArguments: []
            )
        case "read_file":
            return Rule(
                toolName: toolName,
                directArguments: [DirectArgumentRule(key: "path", allowsRootSentinel: false)],
                nestedArrayArguments: []
            )
        case "search_files":
            return Rule(
                toolName: toolName,
                directArguments: [DirectArgumentRule(key: "path", allowsRootSentinel: true)],
                nestedArrayArguments: []
            )
        case "glob":
            return Rule(
                toolName: toolName,
                directArguments: [DirectArgumentRule(key: "path", allowsRootSentinel: true)],
                nestedArrayArguments: []
            )
        case "file_info":
            return Rule(
                toolName: toolName,
                directArguments: [DirectArgumentRule(key: "path", allowsRootSentinel: false)],
                nestedArrayArguments: []
            )
        case "get_structure":
            return Rule(
                toolName: toolName,
                directArguments: [DirectArgumentRule(key: "path", allowsRootSentinel: true)],
                nestedArrayArguments: []
            )
        case "find_symbol":
            return Rule(
                toolName: toolName,
                directArguments: [DirectArgumentRule(key: "path", allowsRootSentinel: true)],
                nestedArrayArguments: []
            )
        case "find_references":
            return Rule(
                toolName: toolName,
                directArguments: [DirectArgumentRule(key: "path", allowsRootSentinel: true)],
                nestedArrayArguments: []
            )
        case "get_file_outline":
            return Rule(
                toolName: toolName,
                directArguments: [DirectArgumentRule(key: "path", allowsRootSentinel: false)],
                nestedArrayArguments: []
            )
        case "read_files_batch":
            return Rule(
                toolName: toolName,
                directArguments: [],
                nestedArrayArguments: [NestedArrayArgumentRule(arrayKey: "files", fieldKey: "path", allowsRootSentinel: false)]
            )
        case "find_related_files":
            return Rule(
                toolName: toolName,
                directArguments: [DirectArgumentRule(key: "path", allowsRootSentinel: false)],
                nestedArrayArguments: []
            )
        case "find_type_relationships":
            return Rule(
                toolName: toolName,
                directArguments: [DirectArgumentRule(key: "path", allowsRootSentinel: true)],
                nestedArrayArguments: []
            )
        default:
            return nil
        }
    }

    static func isDiscoveryTool(_ toolName: String) -> Bool {
        discoveryToolNames.contains(toolName)
    }

    private static let discoveryToolNames: Set<String> = [
        "list_directory",
        "search_files",
        "glob",
        "get_structure",
        "find_symbol",
        "find_references",
        "find_type_relationships"
    ]
}
