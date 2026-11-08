import SwiftUI

/// Ask: the questions to raise before building, in three groups with the
/// assumption to state when the interviewer leaves the choice open.
struct QuestionsSectionView: View {
    let content: QuestionsContent
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        if content.isEmpty {
            MarkdownRenderer(text: content.rawContent, fontSize: settings.fontSize)
        } else {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                ForEach(QuestionGroupResolver.groups(from: content)) { group in
                    QuestionGroupView(group: group, fontSize: settings.fontSize)
                }
            }
        }
    }
}

/// One group: a heading with the count, then numbered rows in a card.
struct QuestionGroupView: View {
    let group: QuestionGroup
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SurfaceHeader(
                group.title,
                systemImage: group.systemImage,
                count: group.questions.count,
                prominence: .heading
            )
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(group.questions.enumerated()), id: \.element.id) { offset, question in
                    if offset > 0 {
                        Hairline()
                    }
                    QuestionRowView(
                        number: group.firstNumber + offset,
                        question: question,
                        fontSize: fontSize
                    )
                }
            }
            .overlayCard(.base)
        }
    }
}
