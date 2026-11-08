import SwiftUI

/// Microphone level as a thin track with a quality word beside the label.
struct VoiceLevelMeter: View {
    let level: Float
    var showsQuality: Bool = true

    private var quality: VoiceLevelQuality {
        VoiceLevelQuality(level: level)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                FieldLabel(text: "Audio level")
                Spacer(minLength: 0)
                if showsQuality {
                    Text(quality.label)
                        .font(OverlayType.caption)
                        .foregroundStyle(quality.tone.color)
                }
            }
            ProgressTrack(progress: Double(min(max(level, 0), 1)), tone: quality.tone, height: 6)
                .animation(DesignTokens.Motion.focus, value: level)
        }
        .accessibilityLabel("Audio level \(quality.label)")
    }
}
