import Foundation

/// The six phase shape used by the system design answer,
/// with the minutes each usually gets in a forty five minute round, and
/// the blueprint sections that belong to each phase.
struct DesignPhase: Identifiable, Equatable {
    let id: Int
    let title: String
    let minutes: Int
    let sectionIDs: [String]
}

enum DesignPhaseCatalog {
    static let phases: [DesignPhase] = [
        DesignPhase(id: 0, title: "Requirements", minutes: 5, sectionIDs: ["requirements"]),
        DesignPhase(id: 1, title: "Estimation", minutes: 4, sectionIDs: ["estimation"]),
        DesignPhase(id: 2, title: "Architecture", minutes: 12, sectionIDs: ["architecture", "components", "dataFlow"]),
        DesignPhase(id: 3, title: "Data and API", minutes: 8, sectionIDs: ["database", "apiDesign"]),
        DesignPhase(id: 4, title: "Deep dive", minutes: 12, sectionIDs: ["scalability", "tradeoffs"]),
        DesignPhase(id: 5, title: "Wrap up", minutes: 3, sectionIDs: ["wrapUp"])
    ]

    static func phaseIndex(forSectionID sectionID: String) -> Int? {
        phases.first { $0.sectionIDs.contains(sectionID) }?.id
    }

    /// Rail items for the sections that exist in the current design. A
    /// phase is complete when every available section before the current
    /// one belongs to an earlier phase.
    static func railItems(availableSectionIDs: [String], currentSectionIndex: Int) -> (items: [PhaseRailItem], currentPhase: Int) {
        let currentSectionID = availableSectionIDs.indices.contains(currentSectionIndex) ? availableSectionIDs[currentSectionIndex] : nil
        let currentPhase = currentSectionID.flatMap(phaseIndex(forSectionID:)) ?? 0
        let items = phases.map { phase in
            PhaseRailItem(
                id: phase.id,
                title: phase.title,
                minutes: phase.minutes,
                isComplete: phase.id < currentPhase
            )
        }
        return (items, currentPhase)
    }

    /// Index into `availableSectionIDs` of the first section in a phase.
    static func firstSectionIndex(inPhase phaseID: Int, availableSectionIDs: [String]) -> Int? {
        guard let phase = phases.first(where: { $0.id == phaseID }) else { return nil }
        return availableSectionIDs.firstIndex { phase.sectionIDs.contains($0) }
    }

    /// Blueprint sections, in order, that hold at least one progressive step.
    static func availableSectionIDs(in content: SystemDesignContent) -> [String] {
        SystemDesignBlueprint.sections.compactMap { section in
            content.progressiveSteps(for: section.id).isEmpty ? nil : section.id
        }
    }
}
