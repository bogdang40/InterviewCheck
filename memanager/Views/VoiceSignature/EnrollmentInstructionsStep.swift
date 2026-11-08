import SwiftUI

/// First step of the wizard: what to expect and the start button.
struct EnrollmentInstructionsStep: View {
    let micPermissionGranted: Bool
    let onStart: () -> Void
    var onRequestPermission: () -> Void = {}
    var onOpenPermissions: () -> Void = {}

    private static let instructions: [(icon: String, text: String)] = [
        ("speaker.wave.2", "Find a quiet room"),
        ("person.fill", "Only you should be speaking"),
        ("clock", "Speak naturally for about thirty seconds"),
        ("waveform", "Keep talking until the ring is full")
    ]

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            VStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "waveform.badge.mic")
                    .font(OverlayType.display)
                    .foregroundStyle(OverlayPalette.accent)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(OverlayPalette.accentTint))
                Text("Enroll your voice")
                    .font(OverlayType.display)
                    .foregroundStyle(OverlayPalette.textPrimary)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.instructions.enumerated()), id: \.offset) { index, instruction in
                    HStack(spacing: DesignTokens.Spacing.md) {
                        Image(systemName: instruction.icon)
                            .font(OverlayType.callout)
                            .foregroundStyle(OverlayPalette.textSecondary)
                            .frame(width: 20)
                        Text(instruction.text)
                            .font(OverlayType.body)
                            .foregroundStyle(OverlayPalette.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.sm)
                    if index < Self.instructions.count - 1 {
                        Hairline().padding(.horizontal, DesignTokens.Spacing.md)
                    }
                }
            }
            .overlayCard(.base, cornerRadius: DesignTokens.Radius.md)

            Spacer(minLength: 0)

            if !micPermissionGranted {
                ToneBanner(tone: .warning, message: "Microphone permission is required before enrollment can start.", actions: [
                    BannerAction(title: "Allow microphone", action: onRequestPermission),
                    BannerAction(title: "Open System Settings", action: onOpenPermissions)
                ])
            }

            Button(action: onStart) {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                    Text("Start enrollment")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.overlayPrimary)
            .disabled(!micPermissionGranted)
        }
    }
}
