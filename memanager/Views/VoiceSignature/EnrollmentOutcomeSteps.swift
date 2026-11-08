import SwiftUI

/// Final step when the profile was saved.
struct EnrollmentCompletedStep: View {
    let onDone: () -> Void

    var body: some View {
        OverlayEmptyState(
            systemImage: "checkmark",
            title: "Enrollment complete",
            message: "Your voice signature is saved. Turn on voice recognition to label your speech in conversations.",
            primary: EmptyStateAction(title: "Done", action: onDone)
        )
    }
}

/// Final step when enrollment failed.
struct EnrollmentErrorStep: View {
    let error: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            OverlayEmptyState(
                systemImage: "exclamationmark.triangle",
                title: "Enrollment failed",
                message: "Check the microphone and the AccessKey, then try again.",
                primary: EmptyStateAction(title: "Try again", action: onRetry),
                secondary: EmptyStateAction(title: "Cancel", action: onDismiss)
            )
            ToneBanner(tone: .critical, message: error)
        }
    }
}
