import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Interview section: setup, the live interview, and its summary.
struct InterviewView: View {
    @ObservedObject private var controller = InterviewController.shared

    var body: some View {
        switch controller.phase {
        case .setup:
            InterviewSetupForm(controller: controller)
        case .live:
            InterviewLiveScreen(controller: controller, timeline: .shared)
        case .ended:
            InterviewSummaryView(controller: controller)
        }
    }
}

/// Before the interview: role, candidate, resume, and the notice.
struct InterviewSetupForm: View {
    @ObservedObject var controller: InterviewController
    @ObservedObject private var roles = RoleStore.shared
    @ObservedObject private var settings = DetectorSettings.shared
    var readiness: DetectorReadiness = .current()
    @State private var isImportingResume = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            UpcomingInterviewsSection(controller: controller)

            if !readiness.problems.isEmpty {
                Section {
                    ReadinessRow(isDone: readiness.hasDeepgramKey, title: "Deepgram key",
                                 detail: "Times every word of the candidate's answers, so the pause before an answer shows.")
                    ReadinessRow(isDone: readiness.usableLineupCount > 0, title: "Claude or OpenAI key",
                                 detail: "Writes the answers AI tools would give, to compare the candidate's answer with.")
                    HStack {
                        SettingsLink { Text("Add Keys in Settings\u{2026}") }
                        Button("Watch the Demo") { openWindow(id: AppWindowID.demo) }
                            .help("A scripted 90-second interview through the real detector. No keys or microphone needed.")
                        Spacer()
                    }
                } header: {
                    Text("Before your first interview")
                } footer: {
                    Text("The demo needs no keys: it shows a reading answer being caught, start to report.")
                }
            }

            Section {
                Picker("Role", selection: $roles.selectedRoleID) {
                    Text("No role").tag(String?.none)
                    ForEach(roles.roles) { role in
                        Text(role.displayTitle).tag(Optional(role.id))
                    }
                }
                if let role = roles.selectedRole {
                    LabeledContent("Planned questions", value: "\(role.plannedQuestions.count)")
                    LabeledContent("AI-tool prompts", value: "\(role.enabledPrompts.count) enabled")
                }
                Button("New Role\u{2026}") { AppNavigation.shared.requestNewRole() }
            } header: {
                Text("Role")
            } footer: {
                Text("The job description and AI-tool prompts come from the role.")
            }

            Section {
                TextField("Name", text: $controller.candidateName, prompt: Text("Full name"))
                if let earlier = PreviousInterviews.latest(for: controller.candidateName) {
                    LabeledContent("Interviewed before") {
                        Button {
                            AppNavigation.shared.showReport(earlier.id)
                        } label: {
                            Text([earlier.startedAt.formatted(date: .abbreviated, time: .omitted), earlier.roleTitle,
                                  earlier.overallPercent.map { "\($0)% overall" }]
                                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                        }
                        .buttonStyle(.link)
                        .help("Open that interview's report")
                    }
                }
                LabeledContent("Resume") {
                    HStack {
                        Text(controller.resumeFileName ?? "None")
                            .foregroundStyle(controller.resumeFileName == nil ? .secondary : .primary)
                            .lineLimit(1)
                        if controller.resumeFileName != nil {
                            Button("Remove") {
                                controller.resumeText = ""
                                controller.resumeFileName = nil
                            }
                        }
                        Button("Choose\u{2026}") { isImportingResume = true }
                    }
                }
            } header: {
                Text("Candidate")
            } footer: {
                Text("Cheating tools are loaded with the candidate's resume, so the AI answers are too.")
            }

            Section {
                Text(settings.consentNotice)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Toggle("I told the candidate the interview is transcribed and checked",
                           isOn: $controller.consentConfirmed)
                    Spacer()
                    Button("Copy Notice") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(settings.consentNotice, forType: .string)
                    }
                }
            } header: {
                Text("Tell the candidate")
            } footer: {
                Text("Recording laws differ by place; some require everyone on the call to agree.")
            }

        }
        .formStyle(.grouped)
        // Start stays in view, and says what it is waiting for.
        .safeAreaInset(edge: .bottom, spacing: 0) { startBar }
        .navigationTitle("New Interview")
        .fileImporter(isPresented: $isImportingResume, allowedContentTypes: DocumentText.contentTypes) { result in
            if case .success(let url) = result { importResume(url) }
        }
    }

    private var startBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Group {
                    if let message = controller.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else if !controller.consentConfirmed {
                        Label("Tell the candidate the interview is transcribed and checked, then switch on the confirmation above.",
                              systemImage: "hand.raised")
                            .foregroundStyle(.secondary)
                    } else {
                        Label(readyLine, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .lineLimit(2)
                Spacer(minLength: 12)
                Button("Start Interview") { Task { await InterviewPermissions.shared.startInterview(controller) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!controller.consentConfirmed)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    /// "Ready: Jordan Rivera · Senior Backend Engineer"
    private var readyLine: String {
        let parts = [controller.candidateName.trimmingCharacters(in: .whitespaces), roles.selectedRole?.displayTitle ?? ""]
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "Ready to start" : "Ready: " + parts.joined(separator: " \u{00B7} ")
    }

    private func importResume(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            controller.resumeText = try DocumentText.read(url)
            controller.resumeFileName = url.lastPathComponent
        } catch {
            controller.errorMessage = "Could not read that file: \(error.localizedDescription)"
        }
    }
}

/// One setup step: done (green check) or still to do.
struct ReadinessRow: View {
    let isDone: Bool
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDone ? Color.green : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDone ? "Done" : "Not set up")
    }
}

/// What is missing before the detector can do its job.
struct DetectorReadiness: Equatable {
    var hasDeepgramKey: Bool
    var usableLineupCount: Int

    var problems: [String] {
        var list: [String] = []
        if !hasDeepgramKey {
            list.append("Add a Deepgram key in Settings. Timing the candidate's answers needs it.")
        }
        if usableLineupCount == 0 {
            list.append("Add a Claude or OpenAI key in Settings to generate the AI answers to compare against.")
        }
        return list
    }

    @MainActor static func current() -> DetectorReadiness {
        DetectorReadiness(
            hasDeepgramKey: VoiceSignatureStore.shared.hasDeepgramApiKey,
            usableLineupCount: DetectorSettings.shared.usableLineup().count
        )
    }
}
