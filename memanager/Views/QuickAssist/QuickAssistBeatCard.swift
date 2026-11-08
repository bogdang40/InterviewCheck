import SwiftUI

/// A semantic icon and open text row keep the desktop visible through the answer.
/// Unknown section titles retain their ordinal and STAR actions retain emphasis.
struct QuickAssistBeatCard: View {
    let section: QuickAssistSectionModel
    let plan: QuickAssistBeatPlan
    let fontSize: CGFloat
    let markdownRenderMode: MarkdownTextRenderMode
    let renderSeed: String?
    let maxWidth: CGFloat
    let mermaidHeight: CGFloat
    let mermaidActivation: MermaidActivation
    let mermaidStaggered: Bool

    var body: some View {
        HStack(alignment: .top, spacing: maxWidth < 520 ? 14 : 22) {
            icon
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                header
                if let subtitle = section.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: maxWidth, alignment: .leading)
                }
                QuickAssistBeatBody(
                    section: section,
                    fontSize: fontSize,
                    markdownRenderMode: markdownRenderMode,
                    renderSeed: renderSeed,
                    maxWidth: maxWidth,
                    mermaidHeight: mermaidHeight,
                    mermaidActivation: mermaidActivation,
                    mermaidStaggered: mermaidStaggered
                )
            }
        }
        .padding(.vertical, DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = plan.title {
                Text(title)
                    .font(OverlayType.bodyStrong(fontSize))
                    .fontWeight(.semibold)
                    .foregroundStyle(OverlayPalette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caption = plan.caption {
                Text(caption)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var icon: some View {
        let size: CGFloat = maxWidth < 520 ? 40 : 56
        return Group {
            if let symbol = symbol {
                Image(systemName: symbol).font(.system(size: size * 0.43, weight: .light))
            } else {
                Text("\(plan.number)").font(OverlayType.bodyStrong(fontSize))
            }
        }
        .foregroundStyle(OverlayPalette.accent)
        .frame(width: size, height: size)
        .background(OverlayPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(
            plan.isEmphasized ? OverlayPalette.accentStroke : OverlayPalette.hairlineStrong,
            lineWidth: 1
        ))
        .accessibilityHidden(true)
    }

    private var symbol: String? {
        let title = plan.title?.lowercased().filter(\.isLetter) ?? ""
        switch title {
        case "approach", "implementation", "solution": return "externaldrive"
        case "tradeoff", "tradeoffs", "constraints": return "scalemass"
        case "nextstep", "nextsteps", "action", "actions": return "arrow.right"
        case "situation", "context", "background": return "text.alignleft"
        case "task", "goal": return "scope"
        case "result", "results", "outcome": return "checkmark.circle"
        case "lesson", "learning", "reflection": return "lightbulb"
        default: return nil
        }
    }
}
