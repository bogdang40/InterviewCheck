import AppKit
import SwiftUI

/// Before the interview: role, candidate, resume, the recording notice, and
/// whether the keys the detector needs are in place.
struct InterviewSetupView: View {
    @ObservedObject var controller: InterviewController
    @ObservedObject var settings: DetectorSettings
    let workspace: JobWorkspace?
    let readiness: DetectorReadiness
    let onChooseRole: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New interview").font(OverlayType.display).foregroundStyle(OverlayPalette.textPrimary)
                    Text("Press Question asked after each question. You will see what AI tools would have said, and how the candidate's answer compares.")
                        .font(OverlayType.body).foregroundStyle(OverlayPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(readiness.problems, id: \.self) { problem in
                    ToneBanner(tone: .warning, message: problem,
                               actions: [BannerAction(title: "Open Settings", action: onOpenSettings)])
                }

                LabeledField("Role", hint: "The job description and cheater prompts come from the role.") {
                    HStack {
                        Text(workspace?.displayTitle ?? "No role chosen")
                            .font(OverlayType.body)
                            .foregroundStyle(workspace == nil ? OverlayPalette.textTertiary : OverlayPalette.textPrimary)
                        Spacer(minLength: 0)
                        Button(workspace == nil ? "Choose role" : "Change", action: onChooseRole)
                            .buttonStyle(.overlay(.secondary, size: .small))
                    }
                    .overlayField()
                }

                LabeledField("Candidate") {
                    OverlayTextInput(placeholder: "Full name", text: $controller.candidateName)
                }

                LabeledField("Resume (optional)",
                             hint: "Cheating tools are loaded with the candidate's resume, so the AI answers are too.") {
                    HStack {
                        Text(controller.resumeFileName ?? "No resume added")
                            .font(OverlayType.body)
                            .foregroundStyle(controller.resumeFileName == nil ? OverlayPalette.textTertiary : OverlayPalette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if controller.resumeFileName != nil {
                            Button("Remove") { controller.resumeText = ""; controller.resumeFileName = nil }
                                .buttonStyle(.overlay(.ghost, size: .small))
                        }
                        Button("Add PDF or text", action: pickResume)
                            .buttonStyle(.overlay(.secondary, size: .small))
                    }
                    .overlayField()
                }

                consentCard

                HStack {
                    Spacer(minLength: 0)
                    Button("Start interview", systemImage: "record.circle") { controller.start() }
                        .buttonStyle(.overlay(.primary))
                        .disabled(!controller.consentConfirmed)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var consentCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            FieldLabel(text: "Tell the candidate")
            Text(settings.consentNotice)
                .font(OverlayType.body)
                .foregroundStyle(OverlayPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                Toggle(isOn: $controller.consentConfirmed) {
                    Text("I told the candidate the interview is transcribed and checked")
                        .font(OverlayType.callout)
                        .foregroundStyle(OverlayPalette.textPrimary)
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: 0)
                Button("Copy notice", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(settings.consentNotice, forType: .string)
                }
                .buttonStyle(.overlay(.ghost, size: .small))
            }
            Text("Recording laws differ by place; some require everyone on the call to agree.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textTertiary)
        }
        .padding(DesignTokens.Spacing.lg)
        .overlayCard(.raised, accentEdge: !controller.consentConfirmed)
    }

    private func pickResume() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText, .text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let kind: ModeAttachmentKind = url.pathExtension.lowercased() == "pdf" ? .pdf
            : url.pathExtension.lowercased() == "md" ? .markdown : .text
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
            list.append("Add a Deepgram key. Timing the candidate's answers needs it (Settings, Voice).")
        }
        if usableLineupCount == 0 {
            list.append("Add a Claude or OpenAI key to generate the AI answers to compare against (Settings, AI Provider).")
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
