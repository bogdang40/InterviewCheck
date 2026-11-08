import Foundation

/// Parses the Implementation section of a mentor response,
/// including step parsing and code-link helpers.
enum ImplementationSectionParser {
    // MARK: - Implementation Section Parser (Unified Approach + Code)

    static func parseImplementation(_ text: String) -> ImplementationContent {
        var steps: [ImplementationStep] = []
        var detectedLanguage = "python"
        let lines = text.components(separatedBy: "\n")
        let stepHeaders = extractStepHeaders(from: lines)

        // If no step headers found, try fallback parsing
        guard !stepHeaders.isEmpty else {
            return parseImplementationFallback(text)
        }

        // Track cumulative code as we parse each step
        var cumulativeLines: [String] = []

        for (index, header) in stepHeaders.enumerated() {
            let startLine = min(header.lineIndex + 1, lines.count)
            let endLine = index + 1 < stepHeaders.count ? stepHeaders[index + 1].lineIndex : lines.count
            guard startLine <= endLine else { continue }

            let bodyLines = lines[startLine..<endLine]
            let stepBody = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            let codeBlocks = extractCodeBlocks(from: stepBody)
            let lastCodeBlock = codeBlocks.last

            let reasoning = stripCodeBlocks(from: stepBody)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let updatedLanguage = normalizeLanguage(lastCodeBlock?.language) {
                detectedLanguage = updatedLanguage
            }
            let stepLanguage = normalizeLanguage(lastCodeBlock?.language) ?? detectedLanguage

            let codeBlock = lastCodeBlock?.code ?? ""
            let cleanedCode = stripNewLineMarker(from: codeBlock)

            let codeLines = cleanedCode.isEmpty ? [] : cleanedCode.components(separatedBy: "\n")

            var addedLineRange: ClosedRange<Int>?
            if let explicitRange = parseNewLineRange(from: codeBlock),
               explicitRange.lowerBound <= codeLines.count {
                addedLineRange = explicitRange.lowerBound...min(explicitRange.upperBound, codeLines.count)
            } else if !codeLines.isEmpty {
                if cumulativeLines.isEmpty {
                    addedLineRange = 1...max(1, codeLines.count)
                } else if codeLines.count > cumulativeLines.count {
                    addedLineRange = (cumulativeLines.count + 1)...codeLines.count
                }
            }

            if !codeLines.isEmpty {
                cumulativeLines = codeLines
            }

            var snippet = cleanedCode
            if let range = addedLineRange, !codeLines.isEmpty {
                snippet = codeLines[(range.lowerBound - 1)..<range.upperBound].joined(separator: "\n")
            }

            if reasoning.isEmpty && cleanedCode.isEmpty {
                continue
            }

            steps.append(ImplementationStep(
                number: header.number,
                title: header.title,
                reasoning: reasoning,
                codeSnippet: snippet,
                cumulativeCode: cleanedCode,
                language: stepLanguage,
                addedLineRange: addedLineRange
            ))
        }

        // Sort by step number
        steps.sort { $0.number < $1.number }

        return ImplementationContent(
            steps: steps,
            language: detectedLanguage,
            rawContent: text
        )
    }
    
    /// Fallback parser for when no explicit step headers are found
    /// Attempts to create pseudo-steps by splitting on code blocks
    private static func parseImplementationFallback(_ text: String) -> ImplementationContent {
        var detectedLanguage = "python"
        let codeBlocks = extractCodeBlocks(from: text)
        
        // If no code blocks, return raw content only
        guard !codeBlocks.isEmpty else {
            return ImplementationContent(steps: [], language: detectedLanguage, rawContent: text)
        }
        
        var steps: [ImplementationStep] = []
        var lastEndIndex = text.startIndex
        var cumulativeCode = ""
        
        for (index, block) in codeBlocks.enumerated() {
            let stepNumber = index + 1
            
            // Get the reasoning text between previous code block and this one
            let reasoningRange = lastEndIndex..<block.range.lowerBound
            let reasoning = String(text[reasoningRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Update cumulative code
            let blockCode = stripNewLineMarker(from: block.code)
            if !blockCode.isEmpty {
                cumulativeCode = blockCode
            }
            
            // Detect language
            if let lang = normalizeLanguage(block.language) {
                detectedLanguage = lang
            }
            
            // Generate a title from the first line of reasoning (if meaningful)
            var title = "Step \(stepNumber)"
            let reasoningLines = reasoning.components(separatedBy: "\n")
            if let firstLine = reasoningLines.first {
                let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "##", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= 5 && trimmed.count <= 60 {
                    title = trimmed
                }
            }
            
            let codeLines = blockCode.components(separatedBy: "\n")
            let addedLineRange = codeLines.isEmpty ? nil : 1...codeLines.count
            
            if !reasoning.isEmpty || !blockCode.isEmpty {
                steps.append(ImplementationStep(
                    number: stepNumber,
                    title: title,
                    reasoning: reasoning,
                    codeSnippet: blockCode,
                    cumulativeCode: cumulativeCode,
                    language: detectedLanguage,
                    addedLineRange: addedLineRange
                ))
            }
            
            lastEndIndex = block.range.upperBound
        }
        
        // Capture any trailing reasoning after the last code block
        if lastEndIndex < text.endIndex {
            let trailingText = String(text[lastEndIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            // If there's significant trailing content, add it to the last step's reasoning
            if !trailingText.isEmpty && !steps.isEmpty {
                let lastStep = steps.removeLast()
                let combinedReasoning = lastStep.reasoning.isEmpty 
                    ? trailingText 
                    : lastStep.reasoning + "\n\n" + trailingText
                steps.append(ImplementationStep(
                    number: lastStep.number,
                    title: lastStep.title,
                    reasoning: combinedReasoning,
                    codeSnippet: lastStep.codeSnippet,
                    cumulativeCode: lastStep.cumulativeCode,
                    language: lastStep.language,
                    addedLineRange: lastStep.addedLineRange
                ))
            }
        }
        
        return ImplementationContent(
            steps: steps,
            language: detectedLanguage,
            rawContent: text
        )
    }
    static func parseCodeLink(from text: String) -> String? {
        let pattern = #"\[->\s*code:\s*([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let nsString = text as NSString
        let range = NSRange(location: 0, length: nsString.length)

        guard let match = regex.firstMatch(in: text, range: range),
              match.range(at: 1).location != NSNotFound else {
            return nil
        }

        return nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
    }

}
