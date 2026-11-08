import SwiftUI

/// Functional and non functional requirements plus assumptions, the phase
/// interviewers most often see skipped. Renders nothing when every list is
/// empty so the stepper stands alone.
struct DesignRequirementsBlock: View {
    let requirements: RequirementsBlock
    let fontSize: CGFloat

    private var isEmpty: Bool {
        requirements.functional.isEmpty
            && requirements.nonFunctional.isEmpty
            && requirements.assumptions.isEmpty
    }

    var body: some View {
        if !isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                DesignBulletList(
                    title: "Functional",
                    systemImage: "checkmark.circle",
                    items: requirements.functional,
                    fontSize: fontSize
                )
                DesignBulletList(
                    title: "Non functional",
                    systemImage: "gauge",
                    items: requirements.nonFunctional,
                    fontSize: fontSize
                )
                DesignBulletList(
                    title: "Assumptions",
                    systemImage: "lightbulb",
                    items: requirements.assumptions,
                    fontSize: fontSize
                )
            }
        }
    }
}
