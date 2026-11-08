import SwiftUI

/// One constraint as a chip: the kind as a tone badge, the detail beside it
/// in reading text that wraps when the overlay is narrow.
struct ConstraintChipView: View {
    let constraint: Constraint

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            ToneBadge(
                text: constraint.type.rawValue,
                tone: SolveTonePolicy.tone(for: constraint.type),
                systemImage: constraint.type.icon
            )
            Text(constraint.description)
                .font(OverlayType.body)
                .foregroundStyle(OverlayPalette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .overlayCard(.base, cornerRadius: DesignTokens.Radius.sm)
    }
}

/// Constraint chips in a wrapping row, one tone per kind.
struct ConstraintsFlowView: View {
    let constraints: [Constraint]

    var body: some View {
        WrappingFlowLayout(spacing: DesignTokens.Spacing.sm) {
            ForEach(constraints) { constraint in
                ConstraintChipView(constraint: constraint)
            }
        }
    }
}
