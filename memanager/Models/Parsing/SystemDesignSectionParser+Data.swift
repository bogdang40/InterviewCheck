import Foundation

extension SystemDesignSectionParser {
    // MARK: - Data Flow Parser
    
    static func parseDataFlow(from text: String) -> DataFlowBlock? {
        let flowRaw = MarkdownSectionGrammar.extractMergedSystemDesignContent(after: SystemDesignBlueprint.aliases(forSectionID: "dataFlow"), in: text)
        guard let raw = flowRaw, !raw.isEmpty else { return nil }

        let steps = SystemDesignProgressiveStepParser.parseProgressiveSteps(from: raw, legacyTitle: "Data Flow")
        guard !steps.isEmpty else { return nil }
        
        let diagram = steps.first?.mermaidDiagram ?? SystemDesignProgressiveStepParser.extractMermaidDiagram(from: raw)
        
        // Parse flow steps
        var flows: [DataFlowStep] = []
        let stepPattern = "(\\d+)\\.\\s*([^:]+?)\\s*(?:->|→|sends to|calls)\\s*([^:]+?):\\s*(.+)"
        if let regex = try? NSRegularExpression(pattern: stepPattern, options: [.caseInsensitive]) {
            let nsString = raw as NSString
            for match in regex.matches(in: raw, range: NSRange(location: 0, length: nsString.length)) {
                guard match.range(at: 1).location != NSNotFound else { continue }
                
                let number = Int(nsString.substring(with: match.range(at: 1))) ?? 0
                let from = nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let to = nsString.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
                let desc = match.range(at: 4).location != NSNotFound
                    ? nsString.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
                    : ""
                
                flows.append(DataFlowStep(number: number, from: from, to: to, description: desc))
            }
        }
        
        // Get description
        let description = SystemDesignProgressiveStepParser.extractSectionDescription(from: raw)

        return DataFlowBlock(
            description: description,
            mermaidDiagram: diagram,
            flows: flows,
            steps: steps
        )
    }
    
    // MARK: - Database Parser
    
    static func parseDatabase(from text: String) -> DatabaseBlock? {
        let dbRaw = MarkdownSectionGrammar.extractMergedSystemDesignContent(
            after: SystemDesignBlueprint.aliases(forSectionID: "database"),
            in: text
        )
        guard let raw = dbRaw, !raw.isEmpty else { return nil }

        let steps = SystemDesignProgressiveStepParser.parseProgressiveSteps(from: raw, legacyTitle: "Database Design")
        guard !steps.isEmpty else { return nil }
        
        let diagram = steps.first?.mermaidDiagram ?? SystemDesignProgressiveStepParser.extractMermaidDiagram(from: raw)
        var tables: [DatabaseTable] = []
        
        // Try to parse table definitions like "**TableName:** columns..."
        let tablePattern = "\\*\\*([A-Za-z_]+)\\*\\*:\\s*([^\\n]+)"
        if let regex = try? NSRegularExpression(pattern: tablePattern) {
            let nsString = raw as NSString
            for match in regex.matches(in: raw, range: NSRange(location: 0, length: nsString.length)) {
                guard match.range(at: 1).location != NSNotFound else { continue }
                
                let tableName = nsString.substring(with: match.range(at: 1))
                tables.append(DatabaseTable(name: tableName, columns: [], indexes: []))
            }
        }
        
        // Get description
        let description = SystemDesignProgressiveStepParser.extractSectionDescription(from: raw)

        return DatabaseBlock(
            description: description,
            tables: tables,
            mermaidDiagram: diagram,
            steps: steps
        )
    }
    
    // MARK: - API Design Parser
    
    static func parseAPIDesign(from text: String) -> APIDesignBlock? {
        let apiRaw = MarkdownSectionGrammar.extractMergedSystemDesignContent(
            after: SystemDesignBlueprint.aliases(forSectionID: "apiDesign"),
            in: text
        )
        guard let raw = apiRaw, !raw.isEmpty else { return nil }

        let steps = SystemDesignProgressiveStepParser.parseProgressiveSteps(from: raw, legacyTitle: "API Design")
        guard !steps.isEmpty else { return nil }
        
        var endpoints: [APIEndpoint] = []
        
        // Match patterns like: GET /api/users - Description or **GET** `/api/users` - Description
        let endpointPattern = "(?:\\*\\*)?\\s*(GET|POST|PUT|DELETE|PATCH)\\s*(?:\\*\\*)?\\s*[`]?(/[^`\\s]+)[`]?\\s*[-:]?\\s*(.+)"
        if let regex = try? NSRegularExpression(pattern: endpointPattern, options: [.caseInsensitive]) {
            let nsString = raw as NSString
            for match in regex.matches(in: raw, range: NSRange(location: 0, length: nsString.length)) {
                guard match.range(at: 1).location != NSNotFound,
                      match.range(at: 2).location != NSNotFound else { continue }
                
                let method = nsString.substring(with: match.range(at: 1)).uppercased()
                let path = nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let desc = match.range(at: 3).location != NSNotFound
                    ? nsString.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
                    : ""
                
                endpoints.append(APIEndpoint(
                    method: method,
                    path: path,
                    description: desc,
                    requestBody: nil,
                    responseBody: nil
                ))
            }
        }
        
        // Get general description
        let stripped = SystemDesignProgressiveStepParser.extractSectionDescription(from: raw)
        let firstLineEnd = stripped.firstIndex(of: "\n") ?? stripped.endIndex
        let description = String(stripped[..<firstLineEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

        return APIDesignBlock(
            description: description,
            mermaidDiagram: steps.first?.mermaidDiagram,
            endpoints: endpoints,
            steps: steps
        )
    }
    
}
