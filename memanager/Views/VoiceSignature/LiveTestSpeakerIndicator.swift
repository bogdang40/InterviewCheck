import SwiftUI

/// The three speaker labels with the current one lit.
struct LiveTestSpeakerIndicator: View {
    let current: SpeakerLabel

    private static let order: [SpeakerLabel] = [.me, .other, .unknown]

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            ForEach(Self.order, id: \.self) { label in
                LiveTestSpeakerBadge(label: label, isActive: label == current)
            }
        }
        .accessibilityLabel("Current speaker \(current.displayName)")
    }
}

struct LiveTestSpeakerBadge: View {
    let label: SpeakerLabel
    let isActive: Bool

    private var tone: OverlayTone {
        switch label {
        case .me: return .success
        case .other: return .info
        case .unknown: return .warning
        }
    }

    private var systemImage: String {
        switch label {
        case .me: return "person.fill"
        case .other: return "person.2.fill"
        case .unknown: return "questionmark"
        }
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            ZStack {
                Circle()
                    .fill(isActive ? tone.tint : OverlayPalette.surfaceRaised)
                Circle()
                    .stroke(isActive ? tone.stroke : OverlayPalette.hairline, lineWidth: 1)
                Image(systemName: systemImage)
                    .font(OverlayType.title)
                    .foregroundStyle(isActive ? tone.color : OverlayPalette.textTertiary)
            }
            .frame(width: 44, height: 44)
            .animation(DesignTokens.Motion.focus, value: isActive)

            Text(label.displayName)
                .font(OverlayType.micro)
                .textCase(.uppercase)
                .kerning(0.3)
                .foregroundStyle(isActive ? tone.color : OverlayPalette.textTertiary)
        }
    }
}
