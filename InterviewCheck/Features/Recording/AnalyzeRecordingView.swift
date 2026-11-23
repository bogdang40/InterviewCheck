import InterviewCheckConnectors
import SwiftUI
import UniformTypeIdentifiers

/// File › Analyze Recording: turn a recorded interview into a report.
struct AnalyzeRecordingView: View {
    @ObservedObject var analyzer: RecordingAnalyzer
    @ObservedObject private var roles = RoleStore.shared
    @ObservedObject private var connectors = ConnectorManager.shared
    @State private var meeting: ExternalRecording?
    @State private var meetingError: String?
    @State private var file: URL?
    @State private var duration: TimeInterval?
    @State private var candidateName = ""
    @State private var roleID: String? = RoleStore.shared.selectedRoleID
    @State private var consent = false
    @State private var consentConfirmedAt: Date?
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Analyze a Recording").font(.title2.weight(.semibold))
            switch analyzer.step {
            case .idle:
                setup
            case .preparing:
                progress("Reading the recording\u{2026}")
            case .transcribing:
                progress("Transcribing with word timings. Long recordings take a few minutes.")
            case .chooseSpeaker:
                speakerChoice
            case .answering(let question, let total):
                progress("Generating AI answers and scoring answer \(question) of \(total)\u{2026}",
                         value: Double(question - 1) / Double(max(total, 1)))
            case .finished(_, let questions):
                Label("Done: \(questions) answers scored. The report is open in Reports.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                footer(primary: "Close") { analyzer.isPresented = false }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                footer(primary: "Start Over") { analyzer.reset() }
            }
        }
        .padding(24)
        .frame(width: 560)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result {
                meeting = nil
                file = url
                Task { duration = await RecordingAudio.duration(of: url) }
            }
        }
    }

    private var setup: some View {
        Form {
            if !connectors.recordings.isEmpty {
                Section("From your meetings") {
                    ForEach(connectors.recordings.prefix(6), id: \.recording.id) { item in
                        meetingRow(item.recording, analyzed: item.interviewID != nil)
                    }
                }
            }
            LabeledContent("Recording") {
                HStack {
                    Text(meeting?.title ?? file?.lastPathComponent ?? "None").lineLimit(1)
                        .foregroundStyle(file == nil && meeting == nil ? .secondary : .primary)
                    if let duration {
                        Text(Duration.seconds(duration).formatted(.time(pattern: .hourMinuteSecond))).foregroundStyle(.secondary)
                    }
                    Button("Choose\u{2026}") { isImporting = true }
                }
            }
            TextField("Candidate", text: $candidateName, prompt: Text("Full name"))
            Picker("Role", selection: $roleID) {
                Text("No role").tag(String?.none)
                ForEach(roles.roles) { Text($0.displayTitle).tag(Optional($0.id)) }
            }
            Toggle("The candidate agreed to this interview being recorded, transcribed and checked", isOn: $consent)
                .onChange(of: consent) { _, confirmed in consentConfirmedAt = confirmed ? Date() : nil }
            Text("Audio or video files (Zoom, Meet, Teams and Webex recordings work). Uses your Deepgram and AI keys.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if let meetingError { Text(meetingError).font(.callout).foregroundStyle(.orange) }
                footer(primary: "Analyze", disabled: (file == nil && meeting == nil) || !consent,
                       waitingFor: file == nil && meeting == nil ? "Choose a recording"
                           : (!consent ? "Confirm the candidate agreed to the recording" : nil)) {
                    let role = roles.role(id: roleID)
                    if let meeting {
                        meetingError = nil
                        Task {
                            do {
                                try await connectors.analyze(meeting, with: analyzer, candidateName: candidateName,
                                                             role: role, consentConfirmedAt: consentConfirmedAt ?? Date())
                            } catch {
                                meetingError = error.localizedDescription
                            }
                        }
                    } else if let file {
                        analyzer.start(file: file, candidateName: candidateName, role: role,
                                       consentConfirmedAt: consentConfirmedAt ?? Date())
                    }
                }
            }
        }
    }

    private func meetingRow(_ recording: ExternalRecording, analyzed: Bool) -> some View {
        Button {
            meeting = recording
            file = nil
            duration = recording.duration
            if let match = connectors.interview(for: recording) {
                if candidateName.isEmpty { candidateName = match.candidate?.name ?? "" }
                if let title = match.job?.title,
                   let role = roles.roles.first(where: { $0.name.caseInsensitiveCompare(title) == .orderedSame }) {
                    roleID = role.id
                }
            }
        } label: {
            HStack {
                Image(systemName: meeting?.id == recording.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(meeting?.id == recording.id ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.title).lineLimit(1)
                    Text([recording.source.descriptor.name,
                          recording.startedAt.formatted(date: .abbreviated, time: .shortened),
                          recording.bestMediaFile != nil ? "audio" : "transcript only"]
                            .joined(separator: " \u{00B7} "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if analyzed { Tag(text: "Scored", color: .green) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var speakerChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which voice is the candidate?").font(.headline)
            Text("Everyone else is treated as an interviewer.").foregroundStyle(.secondary)
            Picker("Candidate", selection: $analyzer.candidateSpeaker) {
                ForEach(analyzer.speakers) { speaker in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(speaker.name ?? "Voice \(speaker.id + 1)") \u{00B7} \(speaker.wordCount) words").font(.body.weight(.medium))
                        Text("\u{201C}\(speaker.sample)\u{2026}\u{201D}").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .tag(Optional(speaker.id))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            footer(primary: "Score the Answers", disabled: analyzer.candidateSpeaker == nil) { analyzer.analyze() }
        }
    }

    private func progress(_ text: String, value: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let value { ProgressView(value: value) } else { ProgressView() }
            Text(text).foregroundStyle(.secondary)
            footer(primary: "Hide", cancel: false) { analyzer.isPresented = false }
        }
    }

    private func footer(primary: String, disabled: Bool = false, waitingFor: String? = nil, cancel: Bool = true,
                        action: @escaping () -> Void) -> some View {
        HStack {
            if cancel {
                Button("Cancel") {
                    analyzer.reset()
                    analyzer.isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            Spacer()
            // A greyed-out button says what it is waiting for.
            if disabled, let waitingFor {
                Text(waitingFor).font(.callout).foregroundStyle(.secondary)
            }
            Button(primary, action: action)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(disabled)
        }
    }
}
