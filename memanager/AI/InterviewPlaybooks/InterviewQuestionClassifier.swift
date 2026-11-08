import Foundation

/// The classifier's verdict: which playbook drives the answer, how sure the
/// cues are, and the breadcrumbs that explain the decision in the manifest.
struct InterviewFamilyResolution: Equatable {
    let playbook: InterviewAnswerPlaybook
    let confidence: Double
    let signals: [String]
    /// Second family detected in a compound question, if any.
    let secondaryFamilyID: String?
    /// True when this turn probes the previous answer rather than opening a
    /// new question. Probes inherit context instead of fresh skeletons.
    let isProbe: Bool
}

/// Pure keyword classifier over the playbook catalog. Runs before the model
/// call so the family chip and the prompt contract never wait on the LLM.
/// Cue stems are common words automatic transcription rarely mangles, so
/// classification stays robust even when rare content words arrive garbled.
final class InterviewQuestionClassifier {

    struct Input {
        let question: String
        let transcript: String
        let extraContext: String
        let questionSource: QuickAssistQuestionSource
        let previousFamilyID: String?
        /// When set, only these families may win (behavioural picker).
        let allowedFamilyIDs: Set<String>?
        /// Fallback family when a restriction is active and nothing matches.
        let defaultFamilyID: String?
    }

    private struct ScoredPlaybook {
        let playbook: InterviewAnswerPlaybook
        let score: Int
        let matched: String
    }

    private let anaphoraTerms = [
        "that", "it", "this", "you mentioned", "your answer", "earlier", "you said"
    ]

    func classify(_ input: Input) -> InterviewFamilyResolution? {
        let primary = normalize(primaryText(question: input.question, transcript: input.transcript))
        let supporting = normalize([input.transcript, input.extraContext].joined(separator: " "))
        guard !primary.isEmpty || !supporting.isEmpty else {
            return restrictedDefault(input: input, signals: ["family_no_text"])
        }

        if let probe = probeResolution(primary: primary, input: input) {
            return probe
        }

        var scored: [ScoredPlaybook] = []
        for playbook in InterviewPlaybookCatalog.playbooks where playbook.id != InterviewPlaybookCatalog.followUpProbe.id {
            if let allowed = input.allowedFamilyIDs, !allowed.contains(playbook.id) { continue }
            let result = score(playbook: playbook, primary: primary, supporting: supporting)
            if result.score > 0 {
                scored.append(ScoredPlaybook(playbook: playbook, score: result.score, matched: result.matched))
            }
        }

        // Catalog order breaks ties because strict comparison keeps the
        // earliest candidate, so concrete families beat generic ones.
        var bestCandidate: ScoredPlaybook?
        for candidate in scored {
            if let current = bestCandidate {
                if candidate.score > current.score { bestCandidate = candidate }
            } else {
                bestCandidate = candidate
            }
        }
        guard let best = bestCandidate else {
            return restrictedDefault(input: input, signals: ["family_no_match"])
        }

        var signals = [
            "family=\(best.playbook.id)",
            "family_score=\(best.score)",
            "family_cue=\(best.matched)"
        ]

        var secondary: ScoredPlaybook?
        for candidate in scored where candidate.playbook.id != best.playbook.id && candidate.score >= 3 {
            if let current = secondary {
                if candidate.score > current.score { secondary = candidate }
            } else {
                secondary = candidate
            }
        }
        if let secondary {
            signals.append("family_secondary=\(secondary.playbook.id)")
        }

        let confidence = min(0.95, 0.6 + 0.08 * Double(min(best.score, 5)))
        return InterviewFamilyResolution(
            playbook: best.playbook,
            confidence: confidence,
            signals: signals,
            secondaryFamilyID: secondary?.playbook.id,
            isProbe: false
        )
    }

    // MARK: - Probe detection

    private func probeResolution(primary: String, input: Input) -> InterviewFamilyResolution? {
        guard let previousFamilyID = input.previousFamilyID, !primary.isEmpty else { return nil }

        let probe = InterviewPlaybookCatalog.followUpProbe
        let strongProbeHit = firstMatch(of: probe.strongCues, in: primary)
        let anyStrongFamilyHit = InterviewPlaybookCatalog.playbooks.contains { playbook in
            playbook.id != probe.id && firstMatch(of: playbook.strongCues, in: primary) != nil
        }

        let wordCount = primary.split(separator: " ").count
        let anaphoric = firstMatch(of: anaphoraTerms, in: primary) != nil
        let shortAnaphoricNudge = wordCount <= 9 && anaphoric && !anyStrongFamilyHit

        guard strongProbeHit != nil || shortAnaphoricNudge else { return nil }

        var signals = ["family=\(probe.id)", "probe_inherits=\(previousFamilyID)"]
        if let strongProbeHit {
            signals.append("probe_cue=\(strongProbeHit)")
        } else {
            signals.append("probe_cue=short_anaphoric")
        }
        return InterviewFamilyResolution(
            playbook: probe,
            confidence: strongProbeHit != nil ? 0.86 : 0.72,
            signals: signals,
            secondaryFamilyID: previousFamilyID,
            isProbe: true
        )
    }

    // MARK: - Scoring

    private func score(
        playbook: InterviewAnswerPlaybook,
        primary: String,
        supporting: String
    ) -> (score: Int, matched: String) {
        var total = 0
        var matched = ""
        if let hit = firstMatch(of: playbook.strongCues, in: primary) {
            total += 3
            matched = hit
        } else if let hit = firstMatch(of: playbook.strongCues, in: supporting) {
            total += 2
            matched = hit
        }
        if let hit = firstMatch(of: playbook.cues, in: primary) {
            total += 1
            if matched.isEmpty { matched = hit }
        } else if let hit = firstMatch(of: playbook.cues, in: supporting) {
            total += 1
            if matched.isEmpty { matched = hit }
        }
        return (total, matched)
    }

    private func restrictedDefault(input: Input, signals: [String]) -> InterviewFamilyResolution? {
        guard
            let defaultID = input.defaultFamilyID,
            let playbook = InterviewPlaybookCatalog.playbook(id: defaultID)
        else { return nil }
        return InterviewFamilyResolution(
            playbook: playbook,
            confidence: 0.6,
            signals: signals + ["family_default=\(defaultID)"],
            secondaryFamilyID: nil,
            isProbe: false
        )
    }

    // MARK: - Text handling

    private func primaryText(question: String, transcript: String) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        for line in transcript.components(separatedBy: .newlines).reversed() {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { continue }
            return stripSpeakerPrefix(from: candidate)
        }
        return ""
    }

    private func stripSpeakerPrefix(from line: String) -> String {
        let pattern = #"^(?i)(me|speaker\s+\d+)\s*:\s*"#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return line }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercase, strip punctuation to spaces, collapse runs. Cues pass
    /// through the same pipe so "a/b test" matches "a b test" from ASR.
    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func firstMatch(of cues: [String], in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let padded = " \(text) "
        for cue in cues {
            let normalizedCue = normalize(cue)
            guard !normalizedCue.isEmpty else { continue }
            if padded.contains(" \(normalizedCue) ") {
                return cue
            }
        }
        return nil
    }
}
