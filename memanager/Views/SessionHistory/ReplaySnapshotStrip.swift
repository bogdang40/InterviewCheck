import SwiftUI

/// Encrypted screenshots taken during the session, decrypted for display.
struct ReplaySnapshotStrip: View {
    let snapshots: [SessionReplaySnapshot]

    @State private var isExpanded = true
    @State private var selectedSnapshot: SessionReplaySnapshot?

    private let thumbnailSize = CGSize(width: 180, height: 112)

    var body: some View {
        Group {
        if !snapshots.isEmpty {
            DisclosureCard("Snapshots", systemImage: "photo.on.rectangle", count: snapshots.count, isExpanded: $isExpanded) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                        ForEach(snapshots) { snapshot in
                            Button { selectedSnapshot = snapshot } label: { thumbnail(snapshot) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open captured screen from \(ReplayPresentation.timeLabel(snapshot.record.capturedAt))")
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        }
        .sheet(item: $selectedSnapshot) { snapshot in
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SurfaceHeader("Captured screen", subtitle: snapshot.record.capturedAt.formatted()) {
                    Button("Close") { selectedSnapshot = nil }.buttonStyle(.overlaySecondary)
                }
                if let image = snapshot.image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ToneBanner(tone: .warning, title: "Image unavailable", message: "This saved capture could not be decrypted.")
                }
            }
            .padding(DesignTokens.Spacing.lg)
            .frame(minWidth: 340, idealWidth: 720, minHeight: 300, idealHeight: 520)
            .background(OverlayPalette.canvas)
        }
    }

    private func thumbnail(_ snapshot: SessionReplaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Group {
                if let image = snapshot.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ZStack {
                        OverlayTone.warning.tint
                        Label("Unable to decrypt", systemImage: "lock.slash")
                            .font(OverlayType.caption)
                            .foregroundStyle(OverlayPalette.textSecondary)
                    }
                }
            }
            .frame(width: thumbnailSize.width, height: thumbnailSize.height)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .stroke(OverlayPalette.hairline, lineWidth: 1)
            )
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(ReplayPresentation.timeLabel(snapshot.record.capturedAt))
                Text("\(snapshot.record.width)x\(snapshot.record.height)")
            }
            .font(OverlayType.monoMicro)
            .foregroundStyle(OverlayPalette.textTertiary)
        }
    }
}
