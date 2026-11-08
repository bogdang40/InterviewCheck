import AppKit
import SwiftUI

/// What is stored, where it goes, how long it is kept, and how to delete it.
struct PrivacySettingsTab: View {
    @ObservedObject private var settings = DetectorSettings.shared
    @AppStorage("interviewcheck.diagnosticLogging") private var diagnostics = false
    @State private var confirmDeleteAll = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Picker("Keep interviews for", selection: $settings.retentionDays) {
                    ForEach(InterviewRetention.choices, id: \.days) { Text($0.title).tag($0.days) }
                }
                .onChange(of: settings.retentionDays) { _, days in
                    let removed = InterviewRetention.apply(days: days, database: .shared)
                    if removed > 0 { message = "Deleted \(removed) older interview\(removed == 1 ? "" : "s")." }
                }
                HStack {
                    Button("Show Data in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Self.dataFolder]) }
                    Spacer()
                    Button("Delete All Interviews\u{2026}", role: .destructive) { confirmDeleteAll = true }
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            } header: {
                Text("Interviews")
            } footer: {
                Text("Older interviews, and meeting recordings found by connectors, are deleted when the app opens. Roles are kept.")
            }

            Section("What is stored on this Mac") {
                Label("Transcripts with word timings, the AI answers, scores and reports, in the app's database.",
                      systemImage: "internaldrive")
                Label("Audio is never kept. Live audio streams to Deepgram; a meeting recording or r\u{00E9}sum\u{00E9} is downloaded to a temporary file, read, and deleted.",
                      systemImage: "waveform.slash")
                Label("From connected systems: upcoming interviews (candidate name and email, job title, meeting link) and the list of meeting recordings, refreshed every 15 minutes and removed when you disconnect.",
                      systemImage: "point.3.connected.trianglepath.dotted")
                Label("API keys and sign-ins, for AI providers and connected systems, are kept in the macOS Keychain.", systemImage: "key")
            }

            Section("What is sent where") {
                Label("Deepgram: the audio of both sides of the call, for transcription.", systemImage: "arrow.up.right")
                Label("Your AI providers: each question, the job description, the resume if added, and the candidate's answer text.",
                      systemImage: "arrow.up.right")
                Label("Connected systems are only read, except one thing: Send Summary adds the note you reviewed to the candidate in your ATS, and only when you press Send.",
                      systemImage: "arrow.up.right")
                Label("Recordings scored from Zoom, Teams, Meet or Webex go to Deepgram and your AI providers like any recording.",
                      systemImage: "arrow.up.right")
                Label("No interview content goes to \(AppBrand.name)'s own server; it only checks your account or subscription.",
                      systemImage: "hand.raised")
            }

            Section {
                Toggle("Write diagnostic logs", isOn: $diagnostics)
            } footer: {
                Text("For troubleshooting: connection states and device names in ~/Library/Logs/\(AppBrand.storageFolder). Never interview content.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete every interview?", isPresented: $confirmDeleteAll) {
            Button("Delete All Interviews", role: .destructive) {
                let removed = SessionDatabase.shared.deleteAllInterviews()
                message = "Deleted \(removed) interview\(removed == 1 ? "" : "s")."
            }
        } message: {
            Text("Transcripts, AI answers, scores and reports are removed. Roles are kept. This cannot be undone.")
        }
    }

    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppBrand.storageFolder, isDirectory: true)
    }
}
