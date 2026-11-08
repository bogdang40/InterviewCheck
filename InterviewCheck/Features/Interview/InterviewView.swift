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

    var body: some View {
        Form {
            if !readiness.problems.isEmpty {
                Section {
                    ForEach(readiness.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    SettingsLink { Text("Open Settings\u{2026}") }
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
                    LabeledContent("Cheater prompts", value: "\(role.enabledPrompts.count) enabled")
                }
                Button("New Role\u{2026}") { AppNavigation.shared.requestNewRole() }
            } header: {
                Text("Role")
            } footer: {
                Text("The job description and cheater prompts come from the role.")
            }

            Section {
                TextField("Name", text: $controller.candidateName, prompt: Text("Full name"))
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

            Section {
                HStack {
                    if let message = controller.errorMessage {
                        Text(message).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Start Interview") { Task { await InterviewPermissions.shared.startInterview(controller) } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!controller.consentConfirmed)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New Interview")
        .fileImporter(isPresented: $isImportingResume, allowedContentTypes: [.pdf, .plainText, .text]) { result in
            if case .success(let url) = result { importResume(url) }
        }
    }

    private func importResume(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        let kind: ModeAttachmentKind = ext == "pdf" ? .pdf : ext == "md" ? .markdown : .text
        do {
            controller.resumeText = try DefaultModeTextExtractor.shared.extract(from: url, kind: kind).raw
            controller.resumeFileName = url.lastPathComponent
        } catch {
            controller.errorMessage = "Could not read that file: \(error.localizedDescription)"
        }
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
