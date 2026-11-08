import Foundation

/// Parses the System Design section of a mentor response.
enum SystemDesignSectionParser {
    // MARK: - System Design Section Parser
    
    static func parseSystemDesign(_ rawText: String) -> SystemDesignContent {
        let text = SystemDesignChecklistParser.removingMetadataLines(from: rawText)
        let requirements = parseRequirements(from: text)
        let architecture = parseArchitecture(from: text)
        let components = parseComponents(from: text)
        let componentSteps = parseComponentSteps(from: text)
        let dataFlow = parseDataFlow(from: text)
        let database = parseDatabase(from: text)
        let apiDesign = parseAPIDesign(from: text)
        let scalability = parseScalability(from: text)
        let tradeOffs = parseTradeOffs(from: text)
        let tradeOffSteps = parseTradeOffSteps(from: text)
        let estimation = EstimationSectionParser.parseEstimation(from: text)
        let wrapUp = parseWrapUp(from: text)

        return SystemDesignContent(
            requirements: requirements,
            architecture: architecture,
            components: components,
            componentSteps: componentSteps,
            dataFlow: dataFlow,
            database: database,
            apiDesign: apiDesign,
            scalability: scalability,
            tradeOffs: tradeOffs,
            tradeOffSteps: tradeOffSteps,
            rawContent: rawText,
            estimation: estimation,
            wrapUp: wrapUp
        )
    }

    // MARK: - Wrap-Up Parser

    private static func parseWrapUp(from text: String) -> WrapUpBlock? {
        let raw = MarkdownSectionGrammar.extractMergedSystemDesignContent(
            after: SystemDesignBlueprint.aliases(forSectionID: "wrapUp"),
            in: text
        )
        guard let raw, !raw.isEmpty else { return nil }

        let steps = SystemDesignProgressiveStepParser.parseProgressiveSteps(from: raw, legacyTitle: "Wrap-Up")
        guard !steps.isEmpty else { return nil }

        return WrapUpBlock(steps: steps)
    }

    // MARK: - Requirements Parser
    
    private static func parseRequirements(from text: String) -> RequirementsBlock? {
        let requirementsRaw = MarkdownSectionGrammar.extractMergedSystemDesignContent(after: SystemDesignBlueprint.aliases(forSectionID: "requirements"), in: text)
        guard let raw = requirementsRaw, !raw.isEmpty else { return nil }

        let steps = SystemDesignProgressiveStepParser.parseProgressiveSteps(from: raw, legacyTitle: "Requirements")
        guard !steps.isEmpty else { return nil }
        
        let functionalRaw = MarkdownSectionGrammar.extractContent(after: "Functional", in: raw)
        let nonFunctionalRaw = MarkdownSectionGrammar.extractContent(after: "Non-Functional", in: raw) ??
                               MarkdownSectionGrammar.extractContent(after: "Non-functional", in: raw)
        let assumptionsRaw = MarkdownSectionGrammar.extractContent(after: "Assumptions", in: raw)
        
        let functional = parseBulletList(functionalRaw)
        let nonFunctional = parseBulletList(nonFunctionalRaw)
        let assumptions = parseBulletList(assumptionsRaw)
        
        // If no sub-sections found, fall back to bullets from the prose
        // BEFORE the first step header only: promoting every bullet in the
        // section labeled step prose as "Functional" requirements.
        if functional.isEmpty && nonFunctional.isEmpty {
            let preStepProse = SystemDesignProgressiveStepParser.extractSectionDescription(from: raw)
            let allItems = parseBulletList(preStepProse)
            if !allItems.isEmpty {
                return RequirementsBlock(
                    functional: allItems,
                    nonFunctional: [],
                    assumptions: assumptions,
                    steps: steps
                )
            }
        }

        return RequirementsBlock(
            functional: functional,
            nonFunctional: nonFunctional,
            assumptions: assumptions,
            steps: steps
        )
    }
    
    // MARK: - Architecture Parser
    
    private static func parseArchitecture(from text: String) -> ArchitectureBlock? {
        let archRaw = MarkdownSectionGrammar.extractMergedSystemDesignContent(
            after: SystemDesignBlueprint.aliases(forSectionID: "architecture"),
            in: text
        )
        guard let raw = archRaw, !raw.isEmpty else { return nil }

        let steps = SystemDesignProgressiveStepParser.parseProgressiveSteps(from: raw, legacyTitle: "High-Level Architecture")
        guard !steps.isEmpty else { return nil }
        
        let diagram = steps.first?.mermaidDiagram ?? SystemDesignProgressiveStepParser.extractMermaidDiagram(from: raw)
        
        // Get description (text before the mermaid block or after removing it)
        let description = SystemDesignProgressiveStepParser.extractSectionDescription(from: raw)

        return ArchitectureBlock(
            description: description,
            mermaidDiagram: diagram,
            steps: steps
        )
    }
    
    private static func parseComponentSteps(from text: String) -> [ProgressiveDesignStep] {
        let componentsRaw = MarkdownSectionGrammar.extractMergedSystemDesignContent(after: SystemDesignBlueprint.aliases(forSectionID: "components"), in: text)
        guard let raw = componentsRaw, !raw.isEmpty else { return [] }
        return SystemDesignProgressiveStepParser.parseProgressiveSteps(from: raw, legacyTitle: "Components")
    }
    
    // MARK: - Helpers
    
    /// Parses bullet points from text
    /// Filters out malformed items like "--", "---", or items that are too short to be meaningful
    static func parseBulletList(_ text: String?) -> [String] {
        guard let text = text else { return [] }
        
        var items: [String] = []
        let lines = text.components(separatedBy: "\n")
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("•") else { continue }
            
            let content = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            
            // Skip empty content
            guard !content.isEmpty else { continue }
            
            // Skip items that are just dashes (e.g., "--", "---")
            // These often appear when AI outputs horizontal rules or placeholder content
            guard !content.allSatisfy({ $0 == "-" }) else { continue }
            
            // Skip items that are too short to be meaningful (single char like "-")
            // but allow short valid items like "1." or "OK"
            guard content.count >= 2 || content.first?.isLetter == true else { continue }
            
            items.append(content)
        }
        
        return items
    }
}
