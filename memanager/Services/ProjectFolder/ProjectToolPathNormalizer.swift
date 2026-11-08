import Foundation

final class ProjectToolPathNormalizer {
    static let shared = ProjectToolPathNormalizer()

    enum CallOutcome {
        case success(ToolCall)
        case failure(ToolResult)
    }

    private enum Outcome {
        case success(String)
        case failure(ToolResult)
    }

    private init() {}

    func normalize(
        call: ToolCall,
        rootURL: URL,
        rootDescriptor: ProjectToolRootDescriptor
    ) -> CallOutcome {
        guard let rule = ProjectToolPathContractCatalog.rule(for: call.name) else {
            return .success(call)
        }

        var raw = call.arguments.raw
        for directRule in rule.directArguments {
            if let failure = normalizeDirectArgument(
                key: directRule.key,
                allowsRootSentinel: directRule.allowsRootSentinel,
                arguments: &raw,
                rootURL: rootURL,
                rootDescriptor: rootDescriptor,
                toolName: call.name,
                toolCallID: call.id
            ) {
                return .failure(failure)
            }
        }

        for nestedRule in rule.nestedArrayArguments {
            if let failure = normalizeNestedArrayArgument(
                arrayKey: nestedRule.arrayKey,
                fieldKey: nestedRule.fieldKey,
                allowsRootSentinel: nestedRule.allowsRootSentinel,
                arguments: &raw,
                rootURL: rootURL,
                rootDescriptor: rootDescriptor,
                toolName: call.name,
                toolCallID: call.id
            ) {
                return .failure(failure)
            }
        }

        return .success(ToolCall(id: call.id, name: call.name, arguments: JSONObject(raw)))
    }

    private func normalizeDirectArgument(
        key: String,
        allowsRootSentinel: Bool,
        arguments: inout [String: Any],
        rootURL: URL,
        rootDescriptor: ProjectToolRootDescriptor,
        toolName: String,
        toolCallID: String
    ) -> ToolResult? {
        guard let rawValue = arguments[key] as? String else { return nil }
        switch normalizePathValue(
            rawValue,
            allowsRootSentinel: allowsRootSentinel,
            rootURL: rootURL,
            rootDescriptor: rootDescriptor,
            toolName: toolName,
            toolCallID: toolCallID
        ) {
        case .success(let normalized):
            arguments[key] = normalized
            return nil
        case .failure(let result):
            return result
        }
    }

    private func normalizeNestedArrayArgument(
        arrayKey: String,
        fieldKey: String,
        allowsRootSentinel: Bool,
        arguments: inout [String: Any],
        rootURL: URL,
        rootDescriptor: ProjectToolRootDescriptor,
        toolName: String,
        toolCallID: String
    ) -> ToolResult? {
        guard var entries = arguments[arrayKey] as? [[String: Any]] else { return nil }
        for index in entries.indices {
            guard let rawValue = entries[index][fieldKey] as? String else { continue }
            switch normalizePathValue(
                rawValue,
                allowsRootSentinel: allowsRootSentinel,
                rootURL: rootURL,
                rootDescriptor: rootDescriptor,
                toolName: toolName,
                toolCallID: toolCallID
            ) {
            case .success(let normalized):
                entries[index][fieldKey] = normalized
            case .failure(let result):
                return result
            }
        }
        arguments[arrayKey] = entries
        return nil
    }

    private func normalizePathValue(
        _ rawValue: String,
        allowsRootSentinel: Bool,
        rootURL: URL,
        rootDescriptor: ProjectToolRootDescriptor,
        toolName: String,
        toolCallID: String
    ) -> Outcome {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if allowsRootSentinel {
                return .success("")
            }
            return .failure(invalidPathResult(
                toolCallID: toolCallID,
                toolName: toolName,
                providedPath: rawValue,
                reason: "This tool needs a file or subpath relative to the selected root and cannot use the root sentinel.",
                rootDescriptor: rootDescriptor
            ))
        }
        if trimmed.split(separator: "/").contains("..") {
            return .failure(invalidPathResult(
                toolCallID: toolCallID,
                toolName: toolName,
                providedPath: rawValue,
                reason: "Parent traversal is not allowed inside the project root.",
                rootDescriptor: rootDescriptor
            ))
        }
        guard trimmed.hasPrefix("/") else {
            return .success(trimmed.hasPrefix("./") ? String(trimmed.dropFirst(2)) : trimmed)
        }

        let absoluteURL = URL(fileURLWithPath: trimmed).standardizedFileURL
        let resolvedRoot = rootURL.resolvingSymlinksInPath()
        let resolvedAbsolute = absoluteURL.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path
        let candidatePath = resolvedAbsolute.path
        if candidatePath == rootPath {
            if allowsRootSentinel {
                return .success("")
            }
            return .failure(invalidPathResult(
                toolCallID: toolCallID,
                toolName: toolName,
                providedPath: rawValue,
                reason: "This tool needs a file or subpath relative to the selected root and cannot use the root itself.",
                rootDescriptor: rootDescriptor
            ))
        }
        guard candidatePath.hasPrefix(rootPath + "/") else {
            return .failure(invalidPathResult(
                toolCallID: toolCallID,
                toolName: toolName,
                providedPath: rawValue,
                reason: "The path is outside the selected project root.",
                rootDescriptor: rootDescriptor
            ))
        }

        let relativePath = String(candidatePath.dropFirst(rootPath.count + 1))
        return .success(relativePath)
    }

    private func invalidPathResult(
        toolCallID: String,
        toolName: String,
        providedPath: String,
        reason: String,
        rootDescriptor: ProjectToolRootDescriptor
    ) -> ToolResult {
        let hint = ProjectToolPathContractCatalog.isDiscoveryTool(toolName)
            ? #"If the exact location is unknown, use list_directory(path: ""), glob, search_files, or get_structure first."#
            : #"If the exact file is unknown, discover it first with list_directory(path: ""), glob, search_files, or get_structure."#
        let content = """
        Invalid path for \(toolName).
        provided_path: \(providedPath)
        reason: \(reason)
        selected_root: \(rootDescriptor.displayPath)
        required_format: use a path relative to the selected root, for example \(rootDescriptor.relativePathExample)
        root_discovery: use list_directory(path: "") for the root folder
        next_step: \(hint)
        """
        return .error(toolCallID: toolCallID, message: content)
    }
}
