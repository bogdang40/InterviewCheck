import SwiftUI

/// Sheet that runs recognition on the microphone and shows the label,
/// the smoothed score against the thresholds, and the recent history.
struct LiveTestView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = VoiceSignatureStore.shared
    @StateObject private var session: LiveTestSession

    static let sheetSize = CGSize(width: 480, height: 620)

    init(session: LiveTestSession? = nil) {
        _session = StateObject(wrappedValue: session ?? LiveTestSession())
    }

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeader("Voice recognition test", systemImage: "waveform.badge.magnifyingglass") {
                Button("Done") {
                    session.stop()
                    dismiss()
                }
                .buttonStyle(.overlay(.ghost, size: .small))
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.sm)

            Hairline()

            ScrollView {
            VStack(spacing: DesignTokens.Spacing.lg) {
                ToneBadge(text: session.isRunning ? "Microphone test running" : "Test stopped", tone: session.isRunning ? .info : .neutral, systemImage: "mic")
                LiveTestSpeakerIndicator(current: session.currentLabel)

                LiveTestGauge(
                    score: session.smoothedScore,
                    enterThreshold: store.thresholdEnterMe,
                    exitThreshold: store.thresholdExitMe
                )

                LiveTestThresholdLegend(enterThreshold: store.thresholdEnterMe, exitThreshold: store.thresholdExitMe)

                LiveTestHistoryChart(
                    history: session.history,
                    enterThreshold: store.thresholdEnterMe,
                    exitThreshold: store.thresholdExitMe
                )

                VoiceLevelMeter(level: session.audioLevel)

                Spacer(minLength: 0)

                if let error = session.errorMessage {
                    ToneBanner(tone: .critical, message: error)
                }

                Text("Similarity is a matching score, not verified identity.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignTokens.Spacing.lg)
            }

            VStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    session.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: session.isRunning ? "stop.fill" : "play.fill")
                        Text(session.isRunning ? "Stop test" : "Start test")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.overlay(session.isRunning ? .destructive : .primary))
                Button("Threshold settings") {
                    session.stop()
                    dismiss()
                    OverlayNavigator.shared.showSettings(.voice)
                }
                .buttonStyle(.overlay(.ghost, size: .small))
            }
            .padding(DesignTokens.Spacing.lg)
        }
        .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
        .background(OverlayPalette.readingSurface)
        .onDisappear { session.stop() }
    }
}

#if DEBUG && XCODE_RUNNING_FOR_PREVIEWS
#Preview {
    LiveTestView()
}
#endif
