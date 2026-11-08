import InterviewCheckConnectors
import SwiftUI

/// Review and send the summary note to the ATS. Nothing is sent until the
/// interviewer presses Send.
struct SendSummarySheet: View {
    let report: InterviewReportData
    let interview: ExternalInterview
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isSending = false
    @State private var error: String?
    @State private var sent = false

    private var systemName: String { interview.source.descriptor.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send Summary to \(systemName)").font(.title2.weight(.semibold))
            Text("Added as a private note on \(interview.candidate?.name ?? "the candidate") where \(systemName) allows it. Edit it first if you like.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text("Check your company's rules on recording AI-assisted assessments before sharing scores in the ATS.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            if sent { Label("Sent to \(systemName).", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if isSending { ProgressView().controlSize(.small) }
                Button(sent ? "Done" : "Send") {
                    if sent { dismiss(); return }
                    isSending = true
                    error = nil
                    Task {
                        do {
                            try await ConnectorManager.shared.sendNote(text, to: interview)
                            sent = true
                        } catch {
                            self.error = error.localizedDescription
                        }
                        isSending = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { text = SummaryNote.make(report) }
    }
}
