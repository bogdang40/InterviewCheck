import SwiftUI

/// The key hints the status bar shows for each place in the app.
enum StatusHintCatalog {
    typealias Hint = (label: String, shortcut: String)

    static func hints(surface: MentorSurface, screen: OverlayScreen) -> [Hint] {
        let hide: Hint = ("Hide", ShortcutCatalog.toggleOverlay)
        guard screen == .mentor else {
            return [("Settings", ShortcutCatalog.openSettings), hide]
        }
        switch surface {
        case .assist:
            return [("Generate", ShortcutCatalog.quickAssist), ("Follow up", ShortcutCatalog.quickAssistFollowUp), hide]
        case .solve:
            return [("Solve", ShortcutCatalog.solve), ("Sections", "Cmd+1-5"), hide]
        case .design:
            return [("Design", ShortcutCatalog.solveSystemDesign), ("Steps", "Cmd+Option+Left/Right"), hide]
        case .transcript:
            return [("Capture", ShortcutCatalog.screenshot), ("Mark me", "Cmd+Shift+M"), hide]
        }
    }
}

/// Bottom band: live state, context counters, provider, and the hints
/// that apply right now. Pure presentation over a fixed set of inputs.
struct StatusBar: View {
    let width: CGFloat
    let dotState: StatusDotState
    let providerName: String
    let transcriptCount: Int
    let screenshotCount: Int
    let workspaceTitle: String?
    let hints: [StatusHintCatalog.Hint]
    var keyboardStatus: String? = nil

    private var visibleHints: [StatusHintCatalog.Hint] {
        switch OverlayLayout.breakpoint(for: width) {
        case .compact: return Array(hints.suffix(1))
        case .regular: return Array(hints.suffix(1))
        case .wide: return Array(hints.suffix(2))
        }
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            HStack(spacing: 4) {
                StatusDot(state: dotState, size: 6)
                Text(dotState.label)
                    .font(OverlayType.captionStrong)
                    .foregroundStyle(OverlayPalette.textSecondary)
            }

            Hairline(axis: .vertical).frame(height: 12)

            if width >= 700 {
                counter("waveform", transcriptCount, help: "Transcript entries")
                counter("photo.on.rectangle", screenshotCount, help: "Screenshots in context")
            }

            if width >= 1000, let workspaceTitle, !workspaceTitle.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(OverlayType.symbol(9))
                    Text(workspaceTitle)
                        .font(OverlayType.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(OverlayPalette.textTertiary)
                .frame(maxWidth: 140, alignment: .leading)
                .help("Active workspace")
            }

            HStack(spacing: 4) {
                Image(systemName: keyboardStatus == nil ? "cpu" : "keyboard")
                    .font(OverlayType.symbol(9))
                Text(keyboardStatus ?? providerName)
                    .font(OverlayType.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(OverlayPalette.textTertiary)
            .frame(maxWidth: 160, alignment: .leading)
            .help(keyboardStatus ?? "Active model. \(KeyCapFormatter.glyphs(for: ShortcutCatalog.cycleProvider)) cycles providers.")

            Spacer(minLength: DesignTokens.Spacing.sm)

            HStack(spacing: DesignTokens.Spacing.md) {
                ForEach(Array(visibleHints.enumerated()), id: \.offset) { _, hint in
                    KeyHint(label: hint.label, shortcut: hint.shortcut)
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .frame(height: OverlayLayout.statusBarHeight)
        .padding(.bottom, 5)
    }

    private func counter(_ systemImage: String, _ value: Int, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(OverlayType.symbol(9))
            Text("\(value)")
                .font(OverlayType.monoMicro)
        }
        .foregroundStyle(value > 0 ? OverlayPalette.textSecondary : OverlayPalette.textTertiary)
        .help(help)
    }
}
