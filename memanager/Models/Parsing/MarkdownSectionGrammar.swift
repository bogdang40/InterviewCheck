import Foundation

// MARK: - Markdown Section Grammar

/// Shared markdown header matching, normalization, and section extraction helpers
/// used by the individual section parsers.
enum MarkdownSectionGrammar {
    private struct MermaidLogThrottleState {
        var count: Int
        var lastLoggedAt: Date
    }

    private static let mermaidLogThrottleQueue = DispatchQueue(label: "com.memanager.SectionParser.mermaidLogThrottle")
    private static var mermaidLogThrottleByKey: [String: MermaidLogThrottleState] = [:]

    // MARK: - Header Pattern Matching

    /// Matches bold header lines like **Header** or **Header:** (with optional trailing content)
    private static let boldHeaderRegex = try? NSRegularExpression(
        pattern: #"^\*\*([^*]+?)\*\*\s*:?\s*$"#,
        options: []
    )
    
    /// Matches bold header at start of line with content after: **Header:** content here
    private static let boldHeaderWithContentRegex = try? NSRegularExpression(
        pattern: #"^\*\*([^*]+?)\*\*\s*:?\s*(.+)$"#,
        options: []
    )

    static func logMermaidEventThrottled(
        name: String,
        details: String,
        key: String,
        sampleEvery: Int = 25,
        minIntervalSeconds: TimeInterval = 1.5
    ) {
        let safeSampleEvery = max(1, sampleEvery)
        let now = Date()
        var shouldLog = false
        var seenCount = 0

        mermaidLogThrottleQueue.sync {
            var state = mermaidLogThrottleByKey[key] ?? MermaidLogThrottleState(
                count: 0,
                lastLoggedAt: .distantPast
            )
            state.count += 1
            seenCount = state.count

            let isFirstOccurrence = state.count == 1
            let intervalElapsed = now.timeIntervalSince(state.lastLoggedAt) >= minIntervalSeconds
            let sampledOccurrence = state.count % safeSampleEvery == 0

            if isFirstOccurrence || intervalElapsed || sampledOccurrence {
                shouldLog = true
                state.lastLoggedAt = now
            }

            mermaidLogThrottleByKey[key] = state
            if mermaidLogThrottleByKey.count > 4096 {
                mermaidLogThrottleByKey.removeAll(keepingCapacity: true)
            }
        }

        guard shouldLog else { return }
        let decoratedDetails = seenCount > 1 ? "\(details), seen=\(seenCount)" : details
        SessionLogger.shared.logMermaidEvent(name: name, details: decoratedDetails)
    }

    /// Extracts content after a specific header line until the next header line or end
    /// Also handles cases where content is on the same line as the header: **Header:** content here
    static func extractContent(after header: String, in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        let targetHeader = normalizeHeader(header)
        let allowsNestedHeaders = systemDesignTopLevelHeaders.contains(targetHeader)

        var isCollecting = false
        var collected: [String] = []

        for line in lines {
            // First check if this line is a header (with or without inline content)
            if let (title, inlineContent) = headerTitleAndContent(from: line) {
                let normalizedTitle = normalizeHeader(title)
                if !isCollecting {
                    if normalizedTitle == targetHeader || normalizedTitle.hasPrefix(targetHeader + " ") {
                        isCollecting = true
                        // If there's content on the same line as the header, add it
                        if let inline = inlineContent, !inline.isEmpty {
                            collected.append(inline)
                        }
                    }
                } else {
                    if !allowsNestedHeaders {
                        break
                    }

                    if systemDesignTopLevelHeaders.contains(normalizedTitle),
                       normalizedTitle != targetHeader {
                        break
                    }

                    // Preserve nested headers (e.g. "### Step 1", "### Functional")
                    // so downstream progressive parsers can reason about structure.
                    collected.append(line)
                    if let inline = inlineContent, !inline.isEmpty {
                        collected.append(inline)
                    }
                }
                continue
            }

            if isCollecting {
                collected.append(line)
            }
        }

        let content = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    /// Extracts and merges all matching top-level system-design sections in document order.
    /// Used for recovery append flows where the same section header can reappear later.
    static func extractMergedSystemDesignContent(after headers: [String], in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        let targetHeaders = Set(headers.map(normalizeHeader))

        var isCollecting = false
        var currentBlock: [String] = []
        var blocks: [String] = []

        func flushCurrentBlock() {
            let block = currentBlock.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty {
                blocks.append(block)
            }
            currentBlock = []
        }

        for line in lines {
            if let (title, inlineContent) = headerTitleAndContent(from: line) {
                let normalizedTitle = normalizeHeader(title)
                let isSystemDesignTopLevel = systemDesignTopLevelHeaders.contains(normalizedTitle)

                if isCollecting && isSystemDesignTopLevel {
                    flushCurrentBlock()
                    isCollecting = false
                }

                let isTargetSection = targetHeaders.contains { target in
                    normalizedTitle == target || normalizedTitle.hasPrefix(target + " ")
                }

                if isSystemDesignTopLevel && isTargetSection {
                    isCollecting = true
                    if let inline = inlineContent, !inline.isEmpty {
                        currentBlock.append(inline)
                    }
                    continue
                }

                if isCollecting {
                    currentBlock.append(line)
                    if let inline = inlineContent, !inline.isEmpty {
                        currentBlock.append(inline)
                    }
                }
                continue
            }

            if isCollecting {
                currentBlock.append(line)
            }
        }

        if isCollecting {
            flushCurrentBlock()
        }

        if blocks.count > 1 {
            logMermaidEventThrottled(
                name: "progressive_section_blocks_merged",
                details: "headers=\(headers.joined(separator: "|")), blocks=\(blocks.count)",
                key: "progressive_section_blocks_merged|\(headers.joined(separator: "|"))",
                sampleEvery: 20
            )
        }

        let merged = blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return merged.isEmpty ? nil : merged
    }
    
    /// Extracts header title and optional inline content from a line
    /// Returns (title, inlineContent) where inlineContent is content after the header on the same line
    private static func headerTitleAndContent(from line: String) -> (String, String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Handle markdown headers: # Header or ## Header
        if trimmed.hasPrefix("#") {
            let withoutHashes = trimmed.drop(while: { $0 == "#" })
            let title = String(withoutHashes).trimmingCharacters(in: .whitespacesAndNewlines)
            return (title.trimmingCharacters(in: CharacterSet(charactersIn: ":")), nil)
        }

        // First try bold header with content on same line: **Header:** content
        if let regex = boldHeaderWithContentRegex {
            let nsString = trimmed as NSString
            let range = NSRange(location: 0, length: nsString.length)
            if let match = regex.firstMatch(in: trimmed, range: range),
               match.range(at: 1).location != NSNotFound {
                var title = nsString.substring(with: match.range(at: 1))
                title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                title = title.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                
                var inlineContent: String? = nil
                if match.range(at: 2).location != NSNotFound {
                    inlineContent = nsString.substring(with: match.range(at: 2))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                return (title.trimmingCharacters(in: .whitespacesAndNewlines), inlineContent)
            }
        }
        
        // Then try bold header alone: **Header** or **Header:**
        if let regex = boldHeaderRegex {
            let nsString = trimmed as NSString
            let range = NSRange(location: 0, length: nsString.length)
            if let match = regex.firstMatch(in: trimmed, range: range),
               match.range(at: 1).location != NSNotFound {
                var title = nsString.substring(with: match.range(at: 1))
                title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                title = title.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                return (title.trimmingCharacters(in: .whitespacesAndNewlines), nil)
            }
        }

        return nil
    }

    private static func headerTitle(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("#") {
            let withoutHashes = trimmed.drop(while: { $0 == "#" })
            let title = String(withoutHashes).trimmingCharacters(in: .whitespacesAndNewlines)
            return title.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        }

        if let regex = boldHeaderRegex {
            let nsString = trimmed as NSString
            let range = NSRange(location: 0, length: nsString.length)
            if let match = regex.firstMatch(in: trimmed, range: range),
               match.range(at: 1).location != NSNotFound {
                var title = nsString.substring(with: match.range(at: 1))
                title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                title = title.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                return title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    private static func normalizeHeader(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .lowercased()
    }

    /// Derived from the blueprint: every accepted alias of every section
    /// (prompt active or not) acts as a top level block boundary. The
    /// legacy hand maintained list drifted from the parser's query aliases;
    /// deriving both from one table makes drift impossible.
    private static let systemDesignTopLevelHeaders: Set<String> = Set(
        SystemDesignBlueprint.sections.flatMap { section in
            section.aliases.map { alias in
                alias.lowercased()
            }
        }
    )
}
