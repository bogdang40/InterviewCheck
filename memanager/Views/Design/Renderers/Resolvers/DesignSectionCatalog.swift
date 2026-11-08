import Foundation

/// One blueprint section as the renderers see it: the stable id shared with
/// `SystemDesignContent.progressiveSteps(for:)`, the title and symbol from
/// the blueprint, the position in blueprint order, and the step budget the
/// prompt demanded.
struct DesignSection: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let blueprintIndex: Int
    let expectedStepCount: Int
}

/// Resolves which sections a design answer can show. Titles, symbols, and
/// order all derive from `SystemDesignBlueprint`, so the renderers can never
/// drift from the taxonomy the prompt demands.
enum DesignSectionCatalog {
    static let all: [DesignSection] = SystemDesignBlueprint.sections.enumerated().map { index, section in
        DesignSection(
            id: section.id,
            title: section.title,
            symbol: section.icon,
            blueprintIndex: index,
            expectedStepCount: section.expectedStepCount
        )
    }

    static func section(id: String) -> DesignSection? {
        all.first { $0.id == id }
    }

    /// Sections holding at least one progressive step, in blueprint order.
    static func availableSections(in content: SystemDesignContent) -> [DesignSection] {
        all.filter { !content.progressiveSteps(for: $0.id).isEmpty }
    }
}
