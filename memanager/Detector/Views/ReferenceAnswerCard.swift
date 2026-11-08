import SwiftUI

/// One AI answer, streaming in, labelled with its provider, model and prompt.
struct ReferenceAnswerCard: View {
    let answer: ReferenceAnswerRecord
    var isBestMatch = false
    var height: CGFloat = 210

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: 6) {
                Text(DetectorModelNames.providerShort(answer.provider, model: answer.model))
                    .font(OverlayType.heading)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isBestMatch { ToneBadge(text: "Closest match", tone: .critical, style: .solid) }
            }
            HStack(spacing: 6) {
                ToneBadge(text: answer.promptName, tone: .info)
                Spacer(minLength: 0)
                status
            }
            ScrollView {
                Text(answer.text.isEmpty ? placeholder : answer.text)
                    .font(OverlayType.body)
                    .foregroundStyle(answer.text.isEmpty ? OverlayPalette.textTertiary : OverlayPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: height)
            if let error = answer.error {
                Text(error)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.critical)
                    .lineLimit(2)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .overlayCard(.base, stroke: isBestMatch ? OverlayTone.critical.stroke : nil)
    }

    private var placeholder: String {
        answer.error == nil ? "Writing\u{2026}" : "No answer"
    }

    @ViewBuilder private var status: some View {
        if answer.isStreaming {
            ProgressView().controlSize(.small)
        } else if let first = answer.firstSentenceSeconds, answer.error == nil {
            Text("first line after \(ScoreNotes.seconds(first))")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textTertiary)
                .help("How long a candidate using this tool would wait before they could start reading.")
        }
    }
}

/// AI answers side by side, wrapping to fit the width.
struct ReferenceAnswerGrid: View {
    let answers: [ReferenceAnswerRecord]
    var bestMatchLabel: String?
    let width: CGFloat

    private var columns: [GridItem] {
        let count = width >= 900 ? 3 : width >= 560 ? 2 : 1
        return Array(repeating: GridItem(.flexible(), spacing: DesignTokens.Spacing.md, alignment: .top), count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: DesignTokens.Spacing.md) {
            ForEach(answers) { answer in
                ReferenceAnswerCard(answer: answer, isBestMatch: bestMatchLabel == answer.label)
            }
        }
    }
}
