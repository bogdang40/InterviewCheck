import SwiftUI

/// Review: the cases to walk through out loud, grouped as base, edge and
/// error, each a plain row with no hidden state.
struct TestsSectionView: View {
    let content: TestsContent
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text("Suggested checks · Expected results · Code not executed")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
            if content.isEmpty {
                MarkdownRenderer(text: content.rawContent, fontSize: settings.fontSize)
            } else {
                ForEach(TestGroupResolver.groups(from: content)) { group in
                    TestGroupView(group: group)
                }
            }
        }
    }
}

/// One group: a heading with the count, then the rows in a card.
struct TestGroupView: View {
    let group: TestGroup

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SurfaceHeader(
                group.title,
                systemImage: group.id.icon,
                count: group.cases.count,
                prominence: .heading
            )
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(group.cases.enumerated()), id: \.element.id) { offset, testCase in
                    if offset > 0 {
                        Hairline()
                    }
                    TestCaseRow(testCase: testCase, tone: group.tone)
                }
            }
            .overlayCard(.base)
        }
    }
}
