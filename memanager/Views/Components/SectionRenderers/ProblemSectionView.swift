import SwiftUI

/// Understand: the problem restated, its constraints, the key insight, and
/// why the approach holds. Four labelled blocks, one emphasised.
struct ProblemSectionView: View {
    let content: ProblemContent
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        if content.hasStructuredContent {
            structured
        } else {
            fallback
        }
    }

    private var structured: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            if let restatement = presentable(content.restatement) {
                labelled("Restatement") {
                    RestatementView(content: restatement, fontSize: settings.fontSize)
                }
            }
            if !content.constraints.isEmpty {
                labelled("Constraints") {
                    ConstraintsFlowView(constraints: content.constraints)
                }
            }
            if let insight = presentable(content.insight) {
                labelled("Key insight") {
                    InsightView(content: insight, fontSize: settings.fontSize)
                }
            }
            if let proof = presentable(content.correctnessProof) {
                labelled("Why it works") {
                    CorrectnessProofView(content: proof, fontSize: settings.fontSize)
                }
            }
        }
    }

    @ViewBuilder
    private var fallback: some View {
        if let raw = presentable(content.rawContent) {
            MarkdownRenderer(text: raw, fontSize: settings.fontSize)
        } else {
            Text("No problem analysis yet.")
                .font(OverlayType.body)
                .foregroundStyle(OverlayPalette.textSecondary)
        }
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            FieldLabel(text: title)
            content()
        }
    }

    private func presentable(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
