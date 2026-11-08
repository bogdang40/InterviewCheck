import Foundation

enum VoiceGuardSurface: String {
    case quickAssist = "quick_assist"
    case solve = "solve"
    case systemDesign = "system_design"
    case mlGuide = "ml_guide"
}

struct VoiceNormalizationReport: Equatable {
    let coachingDetected: Bool
    let firstPersonBefore: Bool
    let firstPersonAfter: Bool
    let rewriteCount: Int
    let bannedOpenerRewrites: Int
    let leadInjected: Bool
}

struct VoiceNormalizationResult {
    let text: String
    let report: VoiceNormalizationReport
}

protocol ResponseVoiceGuarding {
    func normalizeText(_ text: String, surface: VoiceGuardSurface) -> VoiceNormalizationResult
}

final class ResponseVoiceGuard: ResponseVoiceGuarding {
    func normalizeText(_ text: String, surface: VoiceGuardSurface) -> VoiceNormalizationResult {
        let coachingDetected = Self.containsCoachingLanguage(in: text)
        let firstPersonBefore = Self.hasFirstPerson(in: text)
        let bannedOpenerRewrites = Self.countClicheOpeners(in: text)

        var rewriteCount = 0
        let normalized = Self.splitByFencedBlocks(text).map { segment in
            switch segment {
            case .fenced(let block):
                return block
            case .prose(let prose):
                let rewrite = rewriteMutableLines(in: prose, surface: surface)
                rewriteCount += rewrite.replacementCount
                return rewrite.text
            }
        }
        var output = Self.normalizeWhitespace(normalized.joined())

        var leadInjected = false
        var firstPersonAfter = Self.hasFirstPerson(in: output)
        if !firstPersonAfter {
            let injected = injectFirstPersonLead(in: output, surface: surface)
            if injected != output {
                output = injected
                rewriteCount += 1
                leadInjected = true
                firstPersonAfter = Self.hasFirstPerson(in: output)
            }
        }

        return VoiceNormalizationResult(
            text: output,
            report: VoiceNormalizationReport(
                coachingDetected: coachingDetected,
                firstPersonBefore: firstPersonBefore,
                firstPersonAfter: firstPersonAfter,
                rewriteCount: rewriteCount,
                bannedOpenerRewrites: bannedOpenerRewrites,
                leadInjected: leadInjected
            )
        )
    }

    /// Accumulator for per-section reports. Extracted from the old inout
    /// soup so adding new report fields is a one-place change.
    struct ReportAccumulator {
        var rewriteCount: Int = 0
        var coachingDetected: Bool = false
        var firstPersonBefore: Bool = false
        var firstPersonAfter: Bool = true
        var bannedOpenerRewrites: Int = 0
        var leadInjected: Bool = false

        mutating func merge(_ report: VoiceNormalizationReport) {
            rewriteCount += report.rewriteCount
            coachingDetected = coachingDetected || report.coachingDetected
            firstPersonBefore = firstPersonBefore || report.firstPersonBefore
            firstPersonAfter = firstPersonAfter && report.firstPersonAfter
            bannedOpenerRewrites += report.bannedOpenerRewrites
            leadInjected = leadInjected || report.leadInjected
        }

        func snapshot() -> VoiceNormalizationReport {
            VoiceNormalizationReport(
                coachingDetected: coachingDetected,
                firstPersonBefore: firstPersonBefore,
                firstPersonAfter: firstPersonAfter,
                rewriteCount: rewriteCount,
                bannedOpenerRewrites: bannedOpenerRewrites,
                leadInjected: leadInjected
            )
        }
    }

    func normalizedSection(
        _ text: String,
        surface: VoiceGuardSurface,
        accumulator: inout ReportAccumulator
    ) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }
        let result = normalizeText(text, surface: surface)
        accumulator.merge(result.report)
        return result.text
    }

    func rewriteMutableLines(in text: String, surface: VoiceGuardSurface) -> MutableLineRewrite {
        let lines = text.components(separatedBy: "\n")
        var rewritten: [String] = []
        rewritten.reserveCapacity(lines.count)
        var replacementCount = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if isImmutableLine(trimmed, surface: surface) {
                rewritten.append(line)
                continue
            }

            var mutable = line
            for rule in Self.rewriteRules {
                let range = NSRange(location: 0, length: (mutable as NSString).length)
                let matchCount = rule.regex.numberOfMatches(in: mutable, options: [], range: range)
                if matchCount > 0 {
                    mutable = rule.regex.stringByReplacingMatches(
                        in: mutable,
                        options: [],
                        range: range,
                        withTemplate: rule.replacement
                    )
                    replacementCount += matchCount
                }
            }
            rewritten.append(mutable)
        }

        return MutableLineRewrite(
            text: rewritten.joined(separator: "\n"),
            replacementCount: replacementCount
        )
    }

    func isImmutableLine(_ normalizedTrimmedLine: String, surface: VoiceGuardSurface) -> Bool {
        guard !normalizedTrimmedLine.isEmpty else { return false }
        if normalizedTrimmedLine.hasPrefix("```") || normalizedTrimmedLine.hasPrefix("~~~") {
            return true
        }

        switch surface {
        case .systemDesign, .mlGuide:
            return Self.immutableLinePrefixes.contains { normalizedTrimmedLine.hasPrefix($0) }
        case .quickAssist, .solve:
            if normalizedTrimmedLine.hasPrefix("inferred side question:") {
                return true
            }
            // The playbook opener line is a verbatim deliverable the
            // candidate speaks while the rest streams in. Never rewrite it.
            if normalizedTrimmedLine.hasPrefix("**say first:**") {
                return true
            }
            return false
        }
    }

    func injectFirstPersonLead(in text: String, surface: VoiceGuardSurface) -> String {
        let segments = Self.splitByFencedBlocks(text)
        var updated = segments

        for (segmentIndex, segment) in segments.enumerated() {
            guard case .prose(let prose) = segment else { continue }
            var lines = prose.components(separatedBy: "\n")
            for lineIndex in lines.indices {
                let originalLine = lines[lineIndex]
                let trimmed = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if isImmutableLine(trimmed.lowercased(), surface: surface) {
                    continue
                }
                let lead = VoiceCore.contextualLead(for: surface, existing: trimmed)
                guard !lead.isEmpty else {
                    // The existing line already opens with a permitted hedge;
                    // no lead is needed.
                    updated[segmentIndex] = .prose(lines.joined(separator: "\n"))
                    return updated.map(Self.renderSegment).joined()
                }
                let bridged = VoiceCore.lowercaseBridge(originalLine)
                lines[lineIndex] = lead + bridged
                updated[segmentIndex] = .prose(lines.joined(separator: "\n"))
                return updated.map(Self.renderSegment).joined()
            }
        }

        let trimmedAll = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAll.isEmpty else { return text }
        let lead = VoiceCore.contextualLead(for: surface, existing: trimmedAll)
        guard !lead.isEmpty else { return text }
        return lead + VoiceCore.lowercaseBridge(text)
    }

}
