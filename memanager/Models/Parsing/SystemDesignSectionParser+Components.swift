import Foundation

extension SystemDesignSectionParser {
    // MARK: - Components Parser
    
    static func parseComponents(from text: String) -> [ComponentBlock] {
        let componentsRaw = MarkdownSectionGrammar.extractMergedSystemDesignContent(after: SystemDesignBlueprint.aliases(forSectionID: "components"), in: text)
        guard let raw = componentsRaw, !raw.isEmpty else { return [] }
        
        var components: [ComponentBlock] = []
        
        // Try to match ### Component Name or **Component Name:** patterns
        let componentPattern = "(?:###\\s*|\\*\\*)([^\\n*]+?)(?:\\*\\*)?:?\\s*\\n([\\s\\S]*?)(?=(?:###|\\*\\*[^*]+\\*\\*:|$))"
        guard let regex = try? NSRegularExpression(pattern: componentPattern, options: []) else {
            return components
        }
        
        let nsString = raw as NSString
        let range = NSRange(location: 0, length: nsString.length)
        
        for match in regex.matches(in: raw, range: range) {
            guard match.range(at: 1).location != NSNotFound else { continue }
            
            let name = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if name.lowercased().hasPrefix("step ") {
                continue
            }
            let content = match.range(at: 2).location != NSNotFound
                ? nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            
            // Extract responsibilities from bullet points
            let responsibilities = parseBulletList(content)
            
            // Extract any diagram
            let diagram = SystemDesignProgressiveStepParser.extractMermaidDiagram(from: content)
            
            // Get description (first non-bullet paragraph)
            let descriptionPattern = "^([^\\-\\*\\n][^\\n]*)"
            var description = ""
            if let descRegex = try? NSRegularExpression(pattern: descriptionPattern),
               let descMatch = descRegex.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)) {
                description = (content as NSString).substring(with: descMatch.range).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            components.append(ComponentBlock(
                name: name,
                description: description,
                responsibilities: responsibilities,
                technologies: [],
                mermaidDiagram: diagram
            ))
        }
        
        // If pattern didn't match, try simple bullet list approach
        if components.isEmpty {
            let items = parseBulletList(raw)
            for (index, item) in items.enumerated() {
                // Split on colon if present
                if let colonIndex = item.firstIndex(of: ":") {
                    let name = String(item[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    if name.lowercased().hasPrefix("step ") {
                        continue
                    }
                    let desc = String(item[item.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                    components.append(ComponentBlock(
                        name: name,
                        description: desc,
                        responsibilities: [],
                        technologies: [],
                        mermaidDiagram: nil
                    ))
                } else {
                    components.append(ComponentBlock(
                        name: "Component \(index + 1)",
                        description: item,
                        responsibilities: [],
                        technologies: [],
                        mermaidDiagram: nil
                    ))
                }
            }
        }
        
        return components
    }

    // MARK: - Scalability Parser
    
    static func parseScalability(from text: String) -> ScalabilityBlock? {
        let scaleRaw = MarkdownSectionGrammar.extractMergedSystemDesignContent(after: SystemDesignBlueprint.aliases(forSectionID: "scalability"), in: text)
        guard let raw = scaleRaw, !raw.isEmpty else { return nil }

        let steps = SystemDesignProgressiveStepParser.parseProgressiveSteps(from: raw, legacyTitle: "Scalability")
        guard !steps.isEmpty else { return nil }
        
        var strategies: [ScalabilityStrategy] = []
        let bottlenecks: [String] = []
        
        // First, try sub-header pattern matching (like parseComponents)
        // Matches ### Strategy Name or **Strategy Name:** patterns
        let strategyPattern = "(?:###\\s*|\\*\\*)([^\\n*]+?)(?:\\*\\*)?:?\\s*\\n([\\s\\S]*?)(?=(?:###|\\*\\*[^*]+\\*\\*:|$))"
        if let regex = try? NSRegularExpression(pattern: strategyPattern, options: []) {
            let nsString = raw as NSString
            let range = NSRange(location: 0, length: nsString.length)
            
            for match in regex.matches(in: raw, range: range) {
                guard match.range(at: 1).location != NSNotFound else { continue }

                let name = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                // Progressive step headers are not strategies: without this
                // guard (which Components and Trade-offs already had) every
                // "### Step N:" became a strategy whose description was the
                // whole step body INCLUDING raw mermaid source, rendered a
                // second time below the stepper.
                if name.lowercased().hasPrefix("step ") {
                    continue
                }
                let content = match.range(at: 2).location != NSNotFound
                    ? nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""

                // Skip empty or placeholder content (like "--" or "---")
                guard !content.isEmpty && !content.allSatisfy({ $0 == "-" }) else { continue }
                
                // Extract trade-offs if mentioned in the content
                var tradeOff: String?
                let tradeOffPattern = "(?:Trade-off|Tradeoff):\\s*(.+)"
                if let toRegex = try? NSRegularExpression(pattern: tradeOffPattern, options: [.caseInsensitive]),
                   let toMatch = toRegex.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)),
                   toMatch.range(at: 1).location != NSNotFound {
                    tradeOff = (content as NSString).substring(with: toMatch.range(at: 1)).trimmingCharacters(in: .whitespaces)
                }
                
                strategies.append(ScalabilityStrategy(name: name, description: content, tradeOffs: tradeOff))
            }
        }
        
        // Fallback: Parse strategies from bullet points if sub-headers didn't work
        if strategies.isEmpty {
            let items = parseBulletList(raw)
            for item in items {
                // Skip malformed items (too short, just dashes, etc.)
                guard item.count > 2 && !item.allSatisfy({ $0 == "-" }) else { continue }
                
                // Try to split on colon for name: description format
                if let colonIndex = item.firstIndex(of: ":") {
                    let name = String(item[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    let desc = String(item[item.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                    // Skip if description is empty or just dashes
                    guard !desc.isEmpty && !desc.allSatisfy({ $0 == "-" }) else { continue }
                    strategies.append(ScalabilityStrategy(name: name, description: desc, tradeOffs: nil))
                } else {
                    strategies.append(ScalabilityStrategy(name: "Strategy", description: item, tradeOffs: nil))
                }
            }
        }
        
        // Get general description (text before bullet points or sub-headers)
        var description = raw
        // Find first bullet or sub-header marker
        if let firstMarker = raw.firstIndex(where: { $0 == "-" || $0 == "*" || $0 == "#" }) {
            description = String(raw[..<firstMarker]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Also check for ** sub-header start
        if let boldStart = raw.range(of: "**") {
            let beforeBold = String(raw[..<boldStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !beforeBold.isEmpty && beforeBold.count < description.count {
                description = beforeBold
            }
        }
        
        return ScalabilityBlock(
            description: description,
            mermaidDiagram: steps.first?.mermaidDiagram,
            strategies: strategies,
            bottlenecks: bottlenecks,
            estimations: nil,
            steps: steps
        )
    }
    
    // MARK: - Trade-offs Parser

    static func parseTradeOffSteps(from text: String) -> [ProgressiveDesignStep] {
        let tradeOffsRaw = MarkdownSectionGrammar.extractMergedSystemDesignContent(
            after: SystemDesignBlueprint.aliases(forSectionID: "tradeoffs"),
            in: text
        )
        guard let raw = tradeOffsRaw, !raw.isEmpty else { return [] }
        return SystemDesignProgressiveStepParser.parseProgressiveSteps(from: raw, legacyTitle: "Trade-offs")
    }
    
    static func parseTradeOffs(from text: String) -> [TradeOff] {
        let tradeOffsRaw = MarkdownSectionGrammar.extractMergedSystemDesignContent(
            after: SystemDesignBlueprint.aliases(forSectionID: "tradeoffs"),
            in: text
        )
        guard let raw = tradeOffsRaw, !raw.isEmpty else { return [] }
        
        var tradeOffs: [TradeOff] = []
        
        // First try sub-header pattern matching (like Components/Scalability)
        // Matches ### Trade-off Name or **Trade-off Name:** patterns
        let tradeOffPattern = "(?:###\\s*|\\*\\*)([^\\n*]+?)(?:\\*\\*)?:?\\s*\\n([\\s\\S]*?)(?=(?:###|\\*\\*[^*]+\\*\\*:|$))"
        if let regex = try? NSRegularExpression(pattern: tradeOffPattern, options: []) {
            let nsString = raw as NSString
            let range = NSRange(location: 0, length: nsString.length)
            
            for match in regex.matches(in: raw, range: range) {
                guard match.range(at: 1).location != NSNotFound else { continue }
                
                let decision = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if decision.lowercased().hasPrefix("step ") {
                    continue
                }
                let content = match.range(at: 2).location != NSNotFound
                    ? nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                
                // Skip empty or placeholder content
                guard !decision.isEmpty && !decision.allSatisfy({ $0 == "-" }) else { continue }
                guard decision.count > 2 else { continue }
                
                tradeOffs.append(TradeOff(decision: decision, alternative: "", reasoning: content))
            }
        }
        
        // Fallback to bullet list parsing if sub-headers didn't work
        if tradeOffs.isEmpty {
            let items = parseBulletList(raw)
            
            for item in items {
                // Skip items that are just dashes or too short
                guard !item.allSatisfy({ $0 == "-" }) && item.count > 2 else { continue }
                
                // Try to parse "X vs Y: reasoning" or "Chose X over Y because..."
                let vsPattern = "([^:]+?)\\s+(?:vs\\.?|over|instead of)\\s+([^:]+?):\\s*(.+)"
                if let regex = try? NSRegularExpression(pattern: vsPattern, options: [.caseInsensitive]),
                   let match = regex.firstMatch(in: item, range: NSRange(location: 0, length: (item as NSString).length)) {
                    let decision = (item as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                    let alternative = (item as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    let reasoning = (item as NSString).substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
                    
                    // Skip if decision is empty or just dashes
                    guard !decision.isEmpty && !decision.allSatisfy({ $0 == "-" }) else { continue }
                    
                    tradeOffs.append(TradeOff(decision: decision, alternative: alternative, reasoning: reasoning))
                } else {
                    // Simple format - just use the item as the decision
                    tradeOffs.append(TradeOff(decision: item, alternative: "", reasoning: ""))
                }
            }
        }
        
        return tradeOffs
    }
    
}
