import Foundation

extension SessionController {
    struct SystemDesignProgressSnapshot: Equatable {
        let sectionCount: Int
        let totalProgressiveStepCount: Int
        let hasStructuredContent: Bool
        let rawCharacterCount: Int
    }
    struct SystemDesignPartialCommitDecision: Equatable {
        let shouldCommit: Bool
        let reason: String
        let isRegression: Bool
    }
    static func makeSystemDesignProgressSnapshot(
        parsed: SystemDesignContent,
        rawText: String
    ) -> SystemDesignProgressSnapshot {
        let sectionCount = SystemDesignSectionExpectation.all.reduce(0) { count, expectation in
            count + (parsed.progressiveStepCount(for: expectation.id) > 0 ? 1 : 0)
        }
        let totalProgressiveStepCount = SystemDesignSectionExpectation.all.reduce(0) { count, expectation in
            count + parsed.progressiveStepCount(for: expectation.id)
        }

        return SystemDesignProgressSnapshot(
            sectionCount: sectionCount,
            totalProgressiveStepCount: totalProgressiveStepCount,
            hasStructuredContent: parsed.hasStructuredContent,
            rawCharacterCount: rawText.trimmingCharacters(in: .whitespacesAndNewlines).count
        )
    }
    static func evaluateSystemDesignPartialCommit(
        previous: SystemDesignProgressSnapshot?,
        candidate: SystemDesignProgressSnapshot,
        elapsedMs: Int,
        charDelta: Int
    ) -> SystemDesignPartialCommitDecision {
        let boundedElapsed = max(0, elapsedMs)
        let boundedCharDelta = max(0, charDelta)

        if let previous {
            if candidate.sectionCount < previous.sectionCount ||
                candidate.totalProgressiveStepCount < previous.totalProgressiveStepCount ||
                candidate.rawCharacterCount < previous.rawCharacterCount {
                return SystemDesignPartialCommitDecision(
                    shouldCommit: false,
                    reason: "regression_detected",
                    isRegression: true
                )
            }

            if !previous.hasStructuredContent && candidate.hasStructuredContent {
                return SystemDesignPartialCommitDecision(
                    shouldCommit: true,
                    reason: "first_structured_content",
                    isRegression: false
                )
            }

            if candidate.sectionCount > previous.sectionCount {
                return SystemDesignPartialCommitDecision(
                    shouldCommit: true,
                    reason: "section_count_growth",
                    isRegression: false
                )
            }

            if candidate.totalProgressiveStepCount > previous.totalProgressiveStepCount {
                return SystemDesignPartialCommitDecision(
                    shouldCommit: true,
                    reason: "step_count_growth",
                    isRegression: false
                )
            }
        } else if candidate.hasStructuredContent {
            return SystemDesignPartialCommitDecision(
                shouldCommit: true,
                reason: "first_structured_content",
                isRegression: false
            )
        }

        if !candidate.hasStructuredContent && boundedElapsed >= 1200 && boundedCharDelta >= 600 {
            return SystemDesignPartialCommitDecision(
                shouldCommit: true,
                reason: "raw_threshold_met",
                isRegression: false
            )
        }

        return SystemDesignPartialCommitDecision(
            shouldCommit: false,
            reason: "low_signal_no_progress",
            isRegression: false
        )
    }
    static func buildSystemDesignCompletenessReport(
        for response: MentorResponse,
        recoveryAttempted: Bool
    ) -> SystemDesignCompletenessReport {
        SystemDesignCompletenessReport.from(
            content: response.parsedSystemDesign,
            recoveryAttempted: recoveryAttempted
        )
    }
    static func mergeSystemDesignRecovery(
        base: MentorResponse,
        recovery: MentorResponse
    ) -> MentorResponse {
        let trimmedRecovery = recovery.systemDesign.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRecovery.isEmpty else {
            return base
        }

        var merged = base
        let trimmedBase = base.systemDesign.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBase.isEmpty {
            merged.systemDesign = trimmedRecovery
        } else {
            merged.systemDesign = trimmedBase + "\n\n" + trimmedRecovery
        }
        return merged
    }
    func attemptSystemDesignRecovery(
        provider: AIProvider,
        context: SessionContext,
        baseResponse: MentorResponse,
        report: SystemDesignCompletenessReport
    ) async -> MentorResponse? {
        guard !report.isComplete else { return baseResponse }

        let recoveryRequest = buildSystemDesignRecoveryRequest(report: report)
        self.logger.logSystemDesignEvent(
            name: "recovery_request_start",
            details: report.missingSummary
        )

        var recoveryContext = context
        let transcriptPrefix = context.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorDesign = baseResponse.systemDesign.trimmingCharacters(in: .whitespacesAndNewlines)
        let recoveryTranscript = [
            transcriptPrefix,
            "Existing system design output (incomplete):",
            priorDesign,
            "Recovery request:",
            recoveryRequest
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")

        recoveryContext = SessionContext(
            transcript: recoveryTranscript,
            screenshots: context.screenshots,
            previousResponse: baseResponse,
            contextEnvelope: context.contextEnvelope
        )

        do {
            let recoveryResponse = try await provider.completeSystemDesign(context: recoveryContext)
            self.logger.logSystemDesignEvent(
                name: "recovery_request_complete",
                details: "responseLen=\(recoveryResponse.systemDesign.count)"
            )
            return SessionController.mergeSystemDesignRecovery(base: baseResponse, recovery: recoveryResponse)
        } catch {
            self.logger.logError(
                category: "system_design",
                name: "recovery_request_failed",
                error: error
            )
            return baseResponse
        }
    }
    private func buildSystemDesignRecoveryRequest(report: SystemDesignCompletenessReport) -> String {
        var lines: [String] = [
            "Return ONLY the missing or low-coherence system-design sections/steps listed below.",
            "Do not repeat unaffected sections.",
            "Keep exact section headers and this step format:",
            "### Step N: <title>",
            "Builds-on: ...",
            "Diagram delta: ...",
            "Why now: ...",
            "Decision: ...",
            "Trade-off: ...",
            "```mermaid",
            "...",
            "```",
            "For Step N>1, keep at least one node/actor identifier from Step N-1 and mention it by the exact same name in reasoning.",
            "When replacing a step, return the entire step block for that step number."
        ]

        for section in report.incompleteSections {
            if section.missingStepCount > 0 {
                let nextStep = section.actualStepCount + 1
                lines.append(
                    "- \(section.title): add steps \(nextStep) through \(section.expectedStepCount) (\(section.missingStepCount) missing)."
                )
            }

            if !section.coherenceIssues.isEmpty {
                let affectedStepNumbers = extractStepNumbers(from: section.coherenceIssues)
                if affectedStepNumbers.isEmpty {
                    lines.append("- \(section.title): rewrite affected low-coherence steps with explicit Builds-on/Diagram delta/Why now continuity.")
                } else {
                    let list = affectedStepNumbers.map(String.init).joined(separator: ", ")
                    lines.append("- \(section.title): replace steps \(list) in full with explicit Builds-on/Diagram delta/Why now continuity.")
                }
                for issue in section.coherenceIssues {
                    lines.append("  - \(issue)")
                }
            }
        }

        lines.append(
            "End with: \(SystemDesignBlueprint.completionChecklistLine)"
        )

        return lines.joined(separator: "\n")
    }
    private func extractStepNumbers(from issues: [String]) -> [Int] {
        var numbers: Set<Int> = []
        guard let regex = try? NSRegularExpression(pattern: #"Step\s+(\d+)"#, options: [.caseInsensitive]) else {
            return []
        }

        for issue in issues {
            let nsIssue = issue as NSString
            let range = NSRange(location: 0, length: nsIssue.length)
            for match in regex.matches(in: issue, range: range) {
                guard match.range(at: 1).location != NSNotFound else { continue }
                if let value = Int(nsIssue.substring(with: match.range(at: 1))) {
                    numbers.insert(value)
                }
            }
        }

        return numbers.sorted()
    }
}
