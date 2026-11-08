import SwiftUI

/// Where a chunk sits relative to the teleprompter cursor.
enum SpeakableChunkReadingState: Equatable {
    case plain
    case past
    case current
    case upcoming

    static func resolve(index: Int, teleprompterEnabled: Bool, currentIndex: Int) -> SpeakableChunkReadingState {
        guard teleprompterEnabled else { return .plain }
        if index == currentIndex { return .current }
        return index < currentIndex ? .past : .upcoming
    }

    var textColor: Color {
        switch self {
        case .plain, .current: return OverlayPalette.textPrimary
        case .past: return OverlayPalette.textTertiary
        case .upcoming: return OverlayPalette.textSecondary
        }
    }
}

/// One chunk of narration. The chunk under the cursor gets the accent edge
/// and primary text; what was already said fades to tertiary and what is
/// coming waits in secondary.
struct SpeakableChunkRow: View {
    let chunk: SpeakableChunk
    let fontSize: CGFloat
    let showsIndicator: Bool
    let state: SpeakableChunkReadingState

    private static let indicatorWidth: CGFloat = 16

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            if showsIndicator {
                Text("\(chunk.number)")
                    .font(OverlayType.monoMicro)
                    .foregroundStyle(state == .current ? OverlayPalette.accent : OverlayPalette.textTertiary)
                    .frame(width: Self.indicatorWidth, alignment: .trailing)
                    .padding(.top, DesignTokens.Spacing.xxs)
            }
            Text(chunk.content)
                .font(state == .current ? OverlayType.bodyStrong(fontSize) : OverlayType.body(fontSize))
                .foregroundStyle(state.textColor)
                .lineSpacing(DesignTokens.Spacing.xxs)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(state == .current ? OverlayPalette.surfaceRaised : .clear))
        .overlay(alignment: .leading) {
            if state == .current {
                Capsule()
                    .fill(OverlayPalette.accent)
                    .frame(width: 3)
                    .padding(.vertical, DesignTokens.Spacing.sm)
                    .padding(.leading, DesignTokens.Spacing.xxs)
            }
        }
        .clipShape(shape)
        .animation(DesignTokens.Motion.focus, value: state)
    }
}
