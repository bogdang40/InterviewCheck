import SwiftUI

/// The code read aloud, one row per line with the source line in a gutter.
struct SpokenCodeLinesView: View {
    let lines: [SpokenLine]

    private static let gutterWidth: CGFloat = 30

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                FieldLabel(text: "Spoken code")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        if line.id > 0 {
                            Hairline()
                        }
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                            Text(line.gutter)
                                .font(OverlayType.monoMicro)
                                .foregroundStyle(OverlayPalette.textTertiary)
                                .frame(width: Self.gutterWidth, alignment: .trailing)
                            Text(line.spoken)
                                .font(OverlayType.body)
                                .foregroundStyle(OverlayPalette.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, DesignTokens.Spacing.xs)
                    }
                }
            }
        }
    }
}
