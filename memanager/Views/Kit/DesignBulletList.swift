import SwiftUI

/// Compact bullet list with an optional uppercase heading. Used for
/// requirement groups, responsibilities, and bottlenecks. Renders nothing
/// for an empty list so callers never show a bare heading.
struct DesignBulletList: View {
    var title: String? = nil
    var systemImage: String? = nil
    let items: [String]
    var fontSize: CGFloat = 13
    var tone: OverlayTone = .neutral

    private var markColor: Color {
        tone == .neutral ? OverlayPalette.textTertiary : tone.color
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                if let title {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if let systemImage {
                            Image(systemName: systemImage)
                                .font(OverlayType.micro)
                                .foregroundStyle(markColor)
                        }
                        FieldLabel(text: title)
                    }
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                        Circle()
                            .fill(markColor)
                            .frame(width: 4, height: 4)
                            .padding(.top, fontSize * 0.45)
                        Text(item)
                            .font(OverlayType.body(fontSize))
                            .foregroundStyle(OverlayPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}
