import SwiftUI

enum TranscriptDensity {
    case compact
    case regular

    var labelWidth: CGFloat {
        switch self {
        case .compact: return 52
        case .regular: return 72
        }
    }

    var rowSpacing: CGFloat {
        switch self {
        case .compact: return 6
        case .regular: return 10
        }
    }
}

/// A transcript line: speaker label in a fixed column, then the text. The
/// user's own lines recede; the other party's lines carry their speaker
/// color and a question marker when they read as a question.
struct TranscriptRow: View {
    let row: TranscriptRowModel
    let density: TranscriptDensity
    let fontSize: CGFloat
    var useSourceBasedIdentification: Bool = false
    var onSpeakerTapped: ((Int) -> Void)? = nil

    private var isTappable: Bool {
        guard !useSourceBasedIdentification else { return false }
        return !row.speaker.isMe && row.deepgramSpeakerId != nil && !row.isPartial
    }

    private var speakerColor: Color {
        switch row.speaker {
        case .me: return OverlayPalette.textTertiary
        case .speaker(let index): return OverlayPalette.speaker(index)
        case .unknown: return OverlayPalette.textSecondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Text(row.speakerLabel)
                .font(OverlayType.captionStrong)
                .foregroundStyle(speakerColor)
                .lineLimit(1)
                .frame(width: density.labelWidth, alignment: .trailing)

            Text(row.text)
                .font(OverlayType.body(fontSize))
                .foregroundStyle(row.speaker.isMe ? OverlayPalette.textSecondary : OverlayPalette.textPrimary)
                .opacity(row.isPartial ? 0.7 : 1)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if row.isQuestion {
                ToneBadge(text: "Q", tone: .info, style: .outline, monospaced: true)
            }

            if isTappable {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(OverlayType.symbol(10, weight: .regular))
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .help("Mark this speaker as you")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = row.deepgramSpeakerId, isTappable {
                onSpeakerTapped?(id)
            }
        }
    }
}
