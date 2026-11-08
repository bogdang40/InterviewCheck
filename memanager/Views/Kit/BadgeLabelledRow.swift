import SwiftUI

/// A tone badge as the label, then the value: Decision, Trade off, Builds
/// on. Labels share one width so a stack of rows reads as a small table.
struct BadgeLabelledRow: View {
    let label: String
    let value: String
    var tone: OverlayTone = .neutral
    var fontSize: CGFloat = 13
    var labelWidth: CGFloat = 96

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            ToneBadge(text: label, tone: tone)
                .frame(width: labelWidth, alignment: .leading)
            Text(value)
                .font(OverlayType.body(fontSize))
                .foregroundStyle(OverlayPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
