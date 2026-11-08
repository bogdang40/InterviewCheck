import Foundation

/// Turns the current step of a section into the spoken script for the talk
/// through. Every paragraph is short enough to say in one breath, and the
/// paragraphs double as teleprompter chunks.
enum DesignScriptComposer {
    static func script(section: DesignSection, steps: [ProgressiveDesignStep], stepIndex: Int) -> String {
        guard !steps.isEmpty else { return "" }
        let index = max(0, min(stepIndex, steps.count - 1))
        let step = steps[index]
        // Spoken content comes from the answer itself. Step numbers,
        // diagram deltas, merge recovery and parser bookkeeping stay in
        // the reference view; they are not interview speech.
        var parts: [String] = []
        for value in [step.reasoning, step.decision, DesignStepContextResolver.meaningfulTradeOff(step.tradeOff)] {
            guard let value = DesignStepContextResolver.cleaned(value),
                  DesignTextValidator.isMeaningful(value) else { continue }
            let paragraph = sentence(value)
            if !parts.contains(paragraph) { parts.append(paragraph) }
        }
        return parts.joined(separator: "\n\n")
    }

    /// One sentence relating this step to the previous one. The diagram
    /// delta carries the comparison when it exists; otherwise a changed
    /// decision does, and a plain step just adds detail.
    static func comparison(previous: ProgressiveDesignStep, current: ProgressiveDesignStep, context: DesignStepContext) -> String {
        if let delta = context.diagramDelta {
            return "What changed since step \(previous.number): \(sentence(leadLowercased(delta)))"
        }
        if previous.decision != current.decision {
            return "Compared with step \(previous.number), the decision shifts from \(previous.decision) to \(current.decision)."
        }
        return "Compared with step \(previous.number), this step adds more detail around \(current.title)."
    }

    /// Ends the fragment with a period unless it already ends a sentence.
    static func sentence(_ fragment: String) -> String {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    /// Lowercases the first letter unless the first word is an acronym.
    static func leadLowercased(_ text: String) -> String {
        guard let first = text.first else { return text }
        let firstWord = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? text
        let isAcronym = firstWord.count > 1 && firstWord.allSatisfy { $0.isUppercase || $0.isNumber }
        guard first.isUppercase, !isAcronym else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
