import Foundation

struct ProjectToolDefinitionFormatter {
    func format(tool: ProjectTool, rootDescriptor: ProjectToolRootDescriptor) -> ToolDefinition {
        ToolDefinition(
            name: tool.name,
            description: formattedDescription(for: tool, rootDescriptor: rootDescriptor),
            inputSchema: formattedSchema(for: tool, rootDescriptor: rootDescriptor),
            isReadOnly: true
        )
    }

    private func formattedDescription(for tool: ProjectTool, rootDescriptor: ProjectToolRootDescriptor) -> String {
        guard let rule = ProjectToolPathContractCatalog.rule(for: tool.name) else {
            return tool.description
        }
        let rootUsage = rule.directArguments.contains { $0.allowsRootSentinel } || rule.nestedArrayArguments.contains { $0.allowsRootSentinel }
        let rootHint = rootUsage
            ? #"Use "" only where this tool accepts the root folder sentinel."#
            : #"Use only file or subpath values relative to the selected root."#
        return "\(tool.description) Selected project root: \(rootDescriptor.rootName) at \(rootDescriptor.displayPath). Use only project relative paths. \(rootHint) If the exact path is unknown, start with list_directory(path: \"\"), glob, or search_files."
    }

    private func formattedSchema(for tool: ProjectTool, rootDescriptor: ProjectToolRootDescriptor) -> JSONObject {
        guard let rule = ProjectToolPathContractCatalog.rule(for: tool.name) else {
            return tool.inputSchema
        }
        var raw = tool.inputSchema.raw
        if var properties = raw["properties"] as? [String: Any] {
            for directRule in rule.directArguments {
                properties[directRule.key] = appendPathContext(
                    to: properties[directRule.key],
                    rootDescriptor: rootDescriptor,
                    allowsRootSentinel: directRule.allowsRootSentinel
                )
            }
            for nestedRule in rule.nestedArrayArguments {
                if var arraySchema = properties[nestedRule.arrayKey] as? [String: Any],
                   var itemSchema = arraySchema["items"] as? [String: Any],
                   var itemProperties = itemSchema["properties"] as? [String: Any] {
                    itemProperties[nestedRule.fieldKey] = appendPathContext(
                        to: itemProperties[nestedRule.fieldKey],
                        rootDescriptor: rootDescriptor,
                        allowsRootSentinel: nestedRule.allowsRootSentinel
                    )
                    itemSchema["properties"] = itemProperties
                    arraySchema["items"] = itemSchema
                    properties[nestedRule.arrayKey] = arraySchema
                }
            }
            raw["properties"] = properties
        }
        return JSONObject(raw)
    }

    private func appendPathContext(
        to schemaValue: Any?,
        rootDescriptor: ProjectToolRootDescriptor,
        allowsRootSentinel: Bool
    ) -> Any? {
        guard var property = schemaValue as? [String: Any] else { return schemaValue }
        let suffix = allowsRootSentinel
            ? #" Selected root: \#(rootDescriptor.displayPath). Use a relative path inside this root. Use "" for the root when needed."#
            : #" Selected root: \#(rootDescriptor.displayPath). Use a relative path inside this root. Do not use absolute paths."#
        let existing = (property["description"] as? String) ?? ""
        property["description"] = existing + suffix
        return property
    }
}
