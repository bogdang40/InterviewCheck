import SwiftUI

/// The finished solution once, with how it was reached in the subtitle.
struct ImplementationFullCodeView: View {
    let content: ImplementationContent

    private var subtitle: String {
        let lines = ImplementationStepPresenter.lineCount(of: content.finalCode)
        return "\(content.steps.count) steps, \(lines) lines"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SurfaceHeader(
                "Full code",
                systemImage: "chevron.left.forwardslash.chevron.right",
                subtitle: subtitle,
                prominence: .heading
            )
            CodeBlockView(code: content.finalCode, language: content.language)
            Text("Generated code · Not executed")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
        }
    }
}
