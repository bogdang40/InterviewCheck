import SwiftUI
import UniformTypeIdentifiers

/// File › Analyze Recording: turn a recorded interview into a report.
struct AnalyzeRecordingView: View {
    @ObservedObject var analyzer: RecordingAnalyzer
    @ObservedObject private var roles = RoleStore.shared
    @State private var file: URL?
    @State private var duration: TimeInterval?
    @State private var candidateName = ""
    @State private var roleID: String? = RoleStore.shared.selectedRoleID
    @State private var consent = false
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
                file = url
                Task { duration = await RecordingAudio.duration(of: url) }
            }
        }
    }

    private var setup: some View {
        Form {
            LabeledContent("Recording") {
                HStack {
                    Text(file?.lastPathComponent ?? "None").lineLimit(1).foregroundStyle(file == nil ? .secondary : .primary)
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
            Text("Audio or video files (Zoom, Meet and Teams recordings work). Uses your Deepgram and AI keys.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            footer(primary: "Analyze", disabled: file == nil || !consent) {
                guard let file else { return }
                analyzer.start(file: file, candidateName: candidateName, role: roles.role(id: roleID))
            }
        }
    }

    private var speakerChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which voice is the candidate?").font(.headline)
            Text("Everyone else is treated as an interviewer.").foregroundStyle(.secondary)
            Picker("Candidate", selection: $analyzer.candidateSpeaker) {
                ForEach(analyzer.speakers) { speaker in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice \(speaker.id + 1) \u{00B7} \(speaker.wordCount) words").font(.body.weight(.medium))
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

    private func footer(primary: String, disabled: Bool = false, cancel: Bool = true,
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
            Button(primary, action: action)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(disabled)
        }
    }
}
