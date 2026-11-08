import SwiftUI

/// Proportional bar of verification outcomes for a session: verified,
/// needs review, and failed segments over a hairline track that stands in
/// for pending turns. Hidden when the session has no turns.
struct SessionHealthBar: View {
    let metadata: SessionCardMetadata
    var height: CGFloat = 4

    var body: some View {
        if metadata.totalTurns > 0 {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    segment(metadata.verifiedFraction, tone: .success, width: geometry.size.width)
                    segment(metadata.needsReviewFraction, tone: .warning, width: geometry.size.width)
                    segment(metadata.failedFraction, tone: .critical, width: geometry.size.width)
                    Spacer(minLength: 0)
                }
                .background(Capsule().fill(OverlayPalette.hairlineStrong))
                .clipShape(Capsule())
            }
            .frame(height: height)
            .accessibilityLabel(accessibilityText)
        }
    }

    @ViewBuilder
    private func segment(_ fraction: Double, tone: OverlayTone, width: CGFloat) -> some View {
        if fraction > 0 {
            Rectangle()
                .fill(tone.color)
                .frame(width: width * fraction)
        }
    }

    private var accessibilityText: String {
        "\(metadata.verifiedCount) verified, \(metadata.needsReviewCount) need review, \(metadata.failedCount) failed, \(metadata.pendingCount) pending"
    }
}
