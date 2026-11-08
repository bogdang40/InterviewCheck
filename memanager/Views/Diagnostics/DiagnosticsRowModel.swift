import Foundation

/// One label and value pair in the diagnostics panel.
struct DiagnosticsRow: Identifiable, Equatable {
    let label: String
    let value: String

    var id: String { label }
}

/// A subsystem's rows with the disclosure state it opens in.
struct DiagnosticsGroup: Identifiable, Equatable {
    let title: String
    let systemImage: String
    let rows: [DiagnosticsRow]
    var startsCollapsed: Bool = false

    var id: String { title }
}
