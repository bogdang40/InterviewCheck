import Foundation

struct ProactiveFailureCoachInput {
    let sessionId: String
    let activeThreadId: String?
    let isCaptureActive: Bool
    let lastTranscriptAt: Date?
    let now: Date
}

protocol ProactiveFailureCoachEvaluating {
    func evaluate(input: ProactiveFailureCoachInput) -> [CoachFindingRecord]
}

final class ProactiveFailureCoachEngine: ProactiveFailureCoachEvaluating {
    private let logger: SessionLogger

    init(logger: SessionLogger = .shared) {
        self.logger = logger
    }

    func evaluate(input: ProactiveFailureCoachInput) -> [CoachFindingRecord] {
        let recentQuickAssist = logger.getRecentQuickAssistCalls(limit: 120)
            .filter { $0.sessionId == input.sessionId }
        let recentDebug = logger.getRecentDebugEvents(limit: 400)
            .filter { $0.sessionId == input.sessionId }

        var findings: [CoachFindingRecord] = []
        findings.append(contentsOf: detectQuickAssistFailureBurst(input: input, calls: recentQuickAssist))
        findings.append(contentsOf: detectQuickAssistHighLatency(input: input, calls: recentQuickAssist))
        findings.append(contentsOf: detectMermaidRecoveryLoop(input: input, events: recentDebug))
        findings.append(contentsOf: detectProgressiveParseInstability(input: input, events: recentDebug))
        findings.append(contentsOf: detectTranscriptStall(input: input))
        return findings
    }

    private func detectQuickAssistFailureBurst(
        input: ProactiveFailureCoachInput,
        calls: [QuickAssistCallRecord]
    ) -> [CoachFindingRecord] {
        let cutoff = input.now.addingTimeInterval(-5 * 60)
        let failures = calls.filter { $0.status == "error" && $0.startedAt >= cutoff }
        guard failures.count >= 2 else { return [] }

        let latest = failures.first
        let evidence: [CoachEvidenceItem] = [
            CoachEvidenceItem(label: "failure_count_5m", value: "\(failures.count)"),
            CoachEvidenceItem(label: "latest_provider", value: latest?.provider ?? "unknown"),
            CoachEvidenceItem(label: "latest_model", value: latest?.model ?? "unknown")
        ]
        let context = buildCoachContext(
            title: "Recent Quick Assist requests failed repeatedly.",
            evidence: evidence,
            extraLines: failures.compactMap { $0.errorMessage }.prefix(2).map { "error=\($0)" }
        )

        return [
            CoachFindingRecord(
                sessionId: input.sessionId,
                threadId: latest?.threadId ?? input.activeThreadId,
                issueType: .quickAssistFailureBurst,
                severity: .critical,
                title: "Quick Assist failure burst",
                message: "I detected \(failures.count) Quick Assist failures in the last 5 minutes.",
                suggestedQuestion: "Diagnose why my recent Quick Assist calls are failing and give the fastest recovery path.",
                suggestedContext: context,
                evidence: evidence,
                dedupeKey: "\(CoachIssueType.quickAssistFailureBurst.rawValue):\(input.sessionId)"
            )
        ]
    }

    private func detectQuickAssistHighLatency(
        input: ProactiveFailureCoachInput,
        calls: [QuickAssistCallRecord]
    ) -> [CoachFindingRecord] {
        let cutoff = input.now.addingTimeInterval(-20 * 60)
        let durations = calls
            .filter { $0.status == "success" && $0.startedAt >= cutoff }
            .compactMap(\.durationMs)
            .sorted()
        guard durations.count >= 5 else { return [] }

        let median = durations[durations.count / 2]
        guard median >= 20_000 else { return [] }

        let evidence = [
            CoachEvidenceItem(label: "median_duration_ms_20m", value: "\(median)"),
            CoachEvidenceItem(label: "sample_size", value: "\(durations.count)")
        ]
        let context = buildCoachContext(
            title: "Quick Assist latency is above target.",
            evidence: evidence,
            extraLines: []
        )
        return [
            CoachFindingRecord(
                sessionId: input.sessionId,
                threadId: input.activeThreadId,
                issueType: .quickAssistHighLatency,
                severity: .warning,
                title: "Quick Assist latency drift",
                message: "Median Quick Assist latency is \(median)ms over the latest sample.",
                suggestedQuestion: "Help me reduce Quick Assist latency while keeping answer quality high.",
                suggestedContext: context,
                evidence: evidence,
                dedupeKey: "\(CoachIssueType.quickAssistHighLatency.rawValue):\(input.sessionId)"
            )
        ]
    }

    private func detectMermaidRecoveryLoop(
        input: ProactiveFailureCoachInput,
        events: [DebugEventRecord]
    ) -> [CoachFindingRecord] {
        let cutoff = input.now.addingTimeInterval(-3 * 60)
        let loopEvents = events.filter {
            $0.timestamp >= cutoff &&
            $0.eventCategory == "mermaid" &&
            [
                "render_timeout_kept_last_good",
                "render_failure_kept_last_good",
                "web_content_process_terminated",
                "render_eval_failed"
            ].contains($0.eventName)
        }
        guard loopEvents.count >= 3 else { return [] }

        let evidence = [
            CoachEvidenceItem(label: "mermaid_recovery_events_3m", value: "\(loopEvents.count)")
        ]
        let context = buildCoachContext(
            title: "Mermaid rendering entered repeated recovery.",
            evidence: evidence,
            extraLines: loopEvents.prefix(3).map { "\($0.eventName): \($0.details ?? "n/a")" }
        )
        return [
            CoachFindingRecord(
                sessionId: input.sessionId,
                threadId: input.activeThreadId,
                issueType: .mermaidRecoveryLoop,
                severity: .warning,
                title: "Mermaid recovery loop",
                message: "Mermaid rendering has repeatedly entered fallback or recovery in the last 3 minutes.",
                suggestedQuestion: "Analyze my Mermaid render instability and propose targeted fixes.",
                suggestedContext: context,
                evidence: evidence,
                dedupeKey: "\(CoachIssueType.mermaidRecoveryLoop.rawValue):\(input.sessionId)"
            )
        ]
    }

    private func detectProgressiveParseInstability(
        input: ProactiveFailureCoachInput,
        events: [DebugEventRecord]
    ) -> [CoachFindingRecord] {
        let cutoff = input.now.addingTimeInterval(-3 * 60)
        let skipped = events.filter {
            $0.timestamp >= cutoff &&
            $0.eventName == "progressive_step_skipped_invalid"
        }
        guard skipped.count >= 3 else { return [] }

        let evidence = [
            CoachEvidenceItem(label: "progressive_step_skipped_invalid_3m", value: "\(skipped.count)")
        ]
        let context = buildCoachContext(
            title: "Progressive system design parsing is unstable.",
            evidence: evidence,
            extraLines: skipped.prefix(3).compactMap(\.details)
        )
        return [
            CoachFindingRecord(
                sessionId: input.sessionId,
                threadId: input.activeThreadId,
                issueType: .progressiveParseInstability,
                severity: .warning,
                title: "Progressive parse instability",
                message: "I observed repeated invalid progressive steps during parsing.",
                suggestedQuestion: "Help me stabilize progressive system design parsing and reduce invalid step drops.",
                suggestedContext: context,
                evidence: evidence,
                dedupeKey: "\(CoachIssueType.progressiveParseInstability.rawValue):\(input.sessionId)"
            )
        ]
    }

    private func detectTranscriptStall(
        input: ProactiveFailureCoachInput
    ) -> [CoachFindingRecord] {
        guard input.isCaptureActive,
              let lastTranscriptAt = input.lastTranscriptAt else { return [] }
        let silenceSeconds = Int(input.now.timeIntervalSince(lastTranscriptAt))
        guard silenceSeconds >= 35 else { return [] }

        let evidence = [
            CoachEvidenceItem(label: "silence_seconds", value: "\(silenceSeconds)")
        ]
        let context = buildCoachContext(
            title: "Transcript appears stalled while capture is active.",
            evidence: evidence,
            extraLines: []
        )
        return [
            CoachFindingRecord(
                sessionId: input.sessionId,
                threadId: input.activeThreadId,
                issueType: .transcriptStall,
                severity: .warning,
                title: "Transcript stall detected",
                message: "No new transcript has arrived for \(silenceSeconds) seconds while capture is active.",
                suggestedQuestion: "Diagnose why transcription appears stalled and give immediate recovery steps.",
                suggestedContext: context,
                evidence: evidence,
                dedupeKey: "\(CoachIssueType.transcriptStall.rawValue):\(input.sessionId)"
            )
        ]
    }

    private func buildCoachContext(
        title: String,
        evidence: [CoachEvidenceItem],
        extraLines: [String]
    ) -> String {
        var lines: [String] = [title, "", "Evidence:"]
        lines.append(contentsOf: evidence.map { "\($0.label)=\($0.value)" })
        if !extraLines.isEmpty {
            lines.append("")
            lines.append("Recent details:")
            lines.append(contentsOf: extraLines.map { String($0.prefix(220)) })
        }
        return lines.joined(separator: "\n")
    }
}
