import Foundation

/// One labelled line of a step's progression context.
struct DesignContextRow: Identifiable, Equatable {
    let label: String
    let value: String

    var id: String { label }
}

/// The lines that make a step a progression instead of an island: what it
/// builds on, what changed in the diagram, why now, and whether recovery
/// output replaced it. Explicit model fields win; otherwise the lines are
/// derived from the previous step, and a first step with nothing explicit
/// has no rows at all.
struct DesignStepContext: Equatable {
    var buildsOn: String?
    var diagramDelta: String?
    var whyNow: String?
    var recoveryNote: String?

    var rows: [DesignContextRow] {
        [
            buildsOn.map { DesignContextRow(label: "Builds on", value: $0) },
            diagramDelta.map { DesignContextRow(label: "Diagram delta", value: $0) },
            whyNow.map { DesignContextRow(label: "Why now", value: $0) },
            recoveryNote.map { DesignContextRow(label: "Recovery", value: $0) }
        ].compactMap { $0 }
    }
}

enum DesignStepContextResolver {
    static func context(for step: ProgressiveDesignStep, previous: ProgressiveDesignStep?) -> DesignStepContext {
        DesignStepContext(
            buildsOn: cleaned(step.buildsOn) ?? derivedBuildsOn(previous: previous),
            diagramDelta: cleaned(step.diagramDelta) ?? derivedDiagramDelta(step: step, previous: previous),
            whyNow: cleaned(step.whyNow) ?? derivedWhyNow(step: step),
            recoveryNote: step.wasOverriddenDuringMerge
                ? "Replaced an earlier step \(step.number) with appended recovery output."
                : nil
        )
    }

    /// A trade off worth showing: present, not blank, and not the literal "None".
    static func meaningfulTradeOff(_ value: String?) -> String? {
        guard let value = cleaned(value), value.lowercased() != "none" else { return nil }
        return value
    }

    static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func derivedBuildsOn(previous: ProgressiveDesignStep?) -> String? {
        guard let previous else { return nil }
        return "Step \(previous.number), \(previous.title), which decided: \(previous.decision)"
    }

    private static func derivedDiagramDelta(step: ProgressiveDesignStep, previous: ProgressiveDesignStep?) -> String? {
        guard let previous else { return nil }
        let delta = DesignDiagramTokenizer.delta(from: previous.mermaidDiagram, to: step.mermaidDiagram)
        let kept = delta.kept.joined(separator: ", ")
        let added = delta.added.joined(separator: ", ")
        if !kept.isEmpty, !added.isEmpty { return "Keeps \(kept) and adds \(added)" }
        if !added.isEmpty { return "Introduces \(added) to extend the previous diagram" }
        if !kept.isEmpty { return "Refines the relationships around \(kept)" }
        return "Refines the previous diagram with more detail"
    }

    private static func derivedWhyNow(step: ProgressiveDesignStep) -> String? {
        guard let tradeOff = meaningfulTradeOff(step.tradeOff) else { return nil }
        return "Needed now to manage the trade off: \(tradeOff)"
    }
}
