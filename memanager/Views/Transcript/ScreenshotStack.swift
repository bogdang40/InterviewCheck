import SwiftUI

/// Thumbnails of the captured screens, newest first, with per item
/// removal and a clear all action.
struct ScreenshotStack: View {
    let screenshots: [Screenshot]
    let onRemove: (UUID) -> Void
    let onClearAll: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 6)]

    var body: some View {
        if screenshots.isEmpty {
            Text("Capture the screen to give the model what you are looking at.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(screenshots.reversed()) { screenshot in
                        ScreenshotThumbnail(screenshot: screenshot) {
                            onRemove(screenshot.id)
                        }
                    }
                }
                Button("Clear all", role: .destructive, action: onClearAll)
                    .buttonStyle(.overlay(.ghost, size: .small))
            }
        }
    }
}

struct ScreenshotThumbnail: View {
    let screenshot: Screenshot
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: screenshot.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                        .stroke(OverlayPalette.hairlineStrong, lineWidth: 1)
                )

            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(OverlayType.symbol(8, weight: .bold))
                        .foregroundStyle(OverlayPalette.textPrimary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(OverlayPalette.canvas.opacity(0.7)))
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Remove screenshot")
            }
        }
        .onHover { isHovering = $0 }
    }
}
