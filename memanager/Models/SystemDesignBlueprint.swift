import Foundation

/// The single source of truth for the system design section taxonomy.
///
/// Section identity, canonical prompt titles, parser aliases, icons, order,
/// and per section step budgets were previously duplicated across four
/// places (PromptBuilder's hardcoded contract, SystemDesignSectionExpectation,
/// the recovery request's checklist line, and the view's SectionType) with
/// stringly typed ids and no compiler enforced link. The prompt contract and
/// the completion checklist line are now GENERATED from this table; adding
/// or changing a section is a one place edit.
struct SystemDesignBlueprint {
    struct Section {
        /// Stable string id shared with SystemDesignContent.progressiveSteps(for:)
        /// and the view layer's SectionType raw values.
        let id: String
        /// Canonical header exactly as the prompt demands it.
        let title: String
        /// Header aliases the parser accepts for this section.
        let aliases: [String]
        /// SF Symbol for the section.
        let icon: String
        /// Progressive steps the prompt demands for this section.
        let expectedStepCount: Int
        /// Whether the prompt currently demands this section. Inactive
        /// sections still parse and render when a model emits them, but are
        /// excluded from the generated contract, the checklist line, and the
        /// completeness expectations. Activating a section is one flag flip.
        var isPromptActive: Bool = true
    }

    static let sections: [Section] = [
        Section(
            id: "requirements",
            title: "Requirements",
            aliases: ["Requirements"],
            icon: "checklist",
            expectedStepCount: 2
        ),
        Section(
            id: "estimation",
            title: "Estimation",
            aliases: ["Estimation", "Estimations", "Back-of-the-Envelope Estimation", "Capacity Estimation", "Capacity Planning"],
            icon: "number.square",
            expectedStepCount: 2
        ),
        Section(
            id: "architecture",
            title: "High-Level Architecture",
            aliases: ["High-Level Architecture", "Architecture"],
            icon: "building.2",
            expectedStepCount: 4
        ),
        Section(
            id: "components",
            title: "Components",
            aliases: ["Components", "Services"],
            icon: "cube",
            expectedStepCount: 3
        ),
        Section(
            id: "dataFlow",
            title: "Data Flow",
            aliases: ["Data Flow"],
            icon: "arrow.triangle.swap",
            expectedStepCount: 3
        ),
        Section(
            id: "database",
            title: "Database Design",
            aliases: ["Database Design", "Database", "Data Model"],
            icon: "cylinder",
            expectedStepCount: 3
        ),
        Section(
            id: "apiDesign",
            title: "API Design",
            aliases: ["API Design", "API Endpoints", "APIs"],
            icon: "arrow.left.arrow.right",
            expectedStepCount: 3
        ),
        Section(
            id: "scalability",
            title: "Scalability",
            aliases: ["Scalability", "Scaling"],
            icon: "arrow.up.right",
            expectedStepCount: 3
        ),
        Section(
            id: "tradeoffs",
            title: "Trade-offs",
            aliases: ["Trade-offs", "Trade-Offs", "Tradeoffs", "Trade-off", "Trade-Off"],
            icon: "scale.3d",
            expectedStepCount: 2
        ),
        Section(
            id: "wrapUp",
            title: "Wrap-Up",
            aliases: ["Wrap-Up", "Wrap Up", "Wrapup", "Summary and Next Steps"],
            icon: "flag.checkered",
            expectedStepCount: 1
        )
    ]

    /// Sections the prompt currently demands, in order.
    static var promptActiveSections: [Section] {
        sections.filter(\.isPromptActive)
    }

    static func section(id: String) -> Section? {
        sections.first { $0.id == id }
    }

    static func aliases(forSectionID id: String) -> [String] {
        section(id: id)?.aliases ?? []
    }

    /// The per section prompt contract, byte identical to the previously
    /// hardcoded block.
    static var promptSectionContract: String {
        promptActiveSections
            .map { "**\($0.title):**\nUse exactly \($0.expectedStepCount) progressive steps." }
            .joined(separator: "\n\n")
    }

    /// The checklist line the prompt (and every recovery request) demands as
    /// the final response line.
    static var completionChecklistLine: String {
        "COMPLETION_CHECKLIST: " + promptActiveSections
            .map { "\($0.title)=\($0.expectedStepCount)" }
            .joined(separator: ", ")
    }
}
