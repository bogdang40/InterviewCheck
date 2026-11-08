import SwiftUI

/// Shared status glyph for tool rows: a breathing dot while running, a
/// check on completion, a cross on failure.
struct QuickAssistFlowToolStatusIcon: View {
    let state: QuickAssistToolTraceStepState

    var body: some View {
        switch state {
        case .running:
            StatusDot(state: .processing, size: 6)
        case .completed:
            Image(systemName: "checkmark")
                .font(OverlayType.monoMicro)
                .foregroundStyle(OverlayTone.success.color)
                .frame(width: 12, height: 12)
        case .failed:
            Image(systemName: "xmark")
                .font(OverlayType.monoMicro)
                .foregroundStyle(OverlayTone.critical.color)
                .frame(width: 12, height: 12)
        }
    }
}
