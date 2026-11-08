import SwiftUI

/// The decision stays beside the explanation. Construction metadata belongs
/// in a disclosure and never becomes candidate speech.
struct DesignStepDetailRows: View {
    let context: DesignStepContext
    let decision: String
    let tradeOff: String?
    let fontSize: CGFloat
    @State private var showsContext = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if DesignTextValidator.isMeaningful(decision) {
                BadgeLabelledRow(label: "Decision", value: decision, tone: .info, fontSize: fontSize)
            }
            if let tradeOff {
                BadgeLabelledRow(label: "Tradeoff", value: tradeOff, tone: .neutral, fontSize: fontSize)
            }
            if !context.rows.isEmpty {
                DisclosureGroup("Step context", isExpanded: $showsContext) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        ForEach(context.rows) { row in
                            BadgeLabelledRow(label: row.label, value: row.value, tone: .neutral, fontSize: fontSize)
                        }
                    }
                    .padding(.top, DesignTokens.Spacing.sm)
                }
                .font(OverlayType.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
