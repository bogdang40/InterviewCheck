import SwiftUI

/// Minimal creation form. The folder is provisioned immediately so the user
/// can start dropping files in before filling in details.
struct WorkspaceCreateSheet: View {
    @ObservedObject var store: WorkspaceStore
    let onCreated: (JobWorkspace) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var company = ""
    @State private var role = ""
    @State private var status: JobWorkspaceStatus = .researching
    @State private var errorMessage: String?

    var body: some View {
        OverlaySheetFrame(
            title: "New job workspace",
            subtitle: "Creates a folder under \(WorkspaceFolderProvisioner.defaultRootDirectory().path) with shelves for the job description, resume, projects, interviews, notes, and journal.",
            primaryTitle: "Create",
            isPrimaryEnabled: canCreate,
            onPrimary: create,
            onCancel: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                    LabeledField("Company") {
                        OverlayTextInput(placeholder: "Stripe", text: $company)
                    }
                    LabeledField("Role") {
                        OverlayTextInput(placeholder: "Staff Engineer, Payments", text: $role)
                    }
                }
                LabeledField("Name", hint: "Optional, defaults to company and role") {
                    OverlayTextInput(placeholder: "Workspace name", text: $name)
                }
                LabeledField("Stage") {
                    WorkspaceStageMenu(status: $status)
                }
                if let errorMessage {
                    ToneBanner(tone: .critical, message: errorMessage)
                }
            }
        }
    }

    private var canCreate: Bool {
        ![name, company, role].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func create() {
        guard canCreate else { return }
        do {
            let workspace = try store.createWorkspace(
                name: name.trimmingCharacters(in: .whitespaces),
                company: company.trimmingCharacters(in: .whitespaces),
                role: role.trimmingCharacters(in: .whitespaces),
                status: status
            )
            onCreated(workspace)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
