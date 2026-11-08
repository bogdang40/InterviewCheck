import SwiftUI

/// Row content for one session: when and how long, the provider, the
/// verification health bar, thread and word counts, and one line of the
/// debrief so the list can be scanned without opening anything.
struct SessionCardView: View {
    let session: SessionRecord
    let metadata: SessionCardMetadata?
    var isActive = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            titleRow
            providerRow
            if let metadata, metadata.totalTurns > 0 {
                SessionHealthBar(metadata: metadata)
            }
            countsRow
            if let preview = metadata?.debriefPreview, !preview.isEmpty {
                Text(preview)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(SessionCardFormatter.dateLabel(session.startedAt))
                .font(OverlayType.callout)
                .foregroundStyle(OverlayPalette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: DesignTokens.Spacing.xs)
            Text(SessionCardFormatter.durationLabel(startedAt: session.startedAt, endedAt: session.endedAt, isActive: isActive))
                .font(OverlayType.monoMicro)
                .foregroundStyle(isActive ? OverlayTone.success.color : OverlayPalette.textTertiary)
        }
    }

    @ViewBuilder
    private var providerRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if let provider = session.provider, !provider.isEmpty {
                Label(provider, systemImage: "cpu")
                    .lineLimit(1)
            }
            if session.screenshotCount > 0 {
                Label("\(session.screenshotCount)", systemImage: "photo")
            }
            if session.hasResponse {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(OverlayTone.success.color)
            }
        }
        .font(OverlayType.caption)
        .foregroundStyle(OverlayPalette.textSecondary)
    }

    @ViewBuilder
    private var countsRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if let metadata {
                ToneBadge(text: metadata.dominantTier.badgeLabel, tone: metadata.dominantTier.badgeTone, style: .outline)
                if metadata.threadCount > 0 {
                    Text(SessionCardFormatter.countLabel(metadata.threadCount, singular: "thread", plural: "threads"))
                }
            }
            if session.transcriptWordCount > 0 {
                Text(SessionCardFormatter.countLabel(session.transcriptWordCount, singular: "word", plural: "words"))
            }
        }
        .font(OverlayType.caption)
        .foregroundStyle(OverlayPalette.textTertiary)
    }
}
