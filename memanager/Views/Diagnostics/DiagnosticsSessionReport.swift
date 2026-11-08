import Foundation

/// Session rows: state, ids, view flags, and the failure coach.
@MainActor
struct DiagnosticsSessionReport {
    let controller: SessionController
    let settings: SettingsManager

    var group: DiagnosticsGroup {
        DiagnosticsGroup(title: "Session", systemImage: "waveform.circle", rows: rows)
    }

    var rows: [DiagnosticsRow] {
        let finding = controller.activeCoachFindings.first
        return [
            DiagnosticsRow(label: "State", value: DiagnosticsValueFormatter.sessionState(controller.session.state)),
            DiagnosticsRow(label: "Started", value: DiagnosticsValueFormatter.timestamp(controller.session.startedAt)),
            DiagnosticsRow(label: "Session ID", value: String(controller.session.id.uuidString.prefix(8))),
            DiagnosticsRow(label: "Loading", value: DiagnosticsValueFormatter.bool(controller.isLoading)),
            DiagnosticsRow(label: "Quick Assist", value: DiagnosticsValueFormatter.bool(controller.isQuickAssistLoading)),
            DiagnosticsRow(label: "Transcript View", value: DiagnosticsValueFormatter.bool(controller.isTranscriptViewVisible)),
            DiagnosticsRow(label: "Quick Assist View", value: DiagnosticsValueFormatter.bool(controller.isQuickAssistViewVisible)),
            DiagnosticsRow(label: "Coach Enabled", value: DiagnosticsValueFormatter.bool(settings.hubFailureCoachEnabled)),
            DiagnosticsRow(label: "Coach Findings", value: "\(controller.activeCoachFindings.count)"),
            DiagnosticsRow(label: "Coach Last Type", value: finding?.issueType.rawValue ?? "n/a"),
            DiagnosticsRow(label: "Coach Last Time", value: DiagnosticsValueFormatter.timeAgo(finding?.updatedAt))
        ]
    }
}
