import SwiftUI

/// Roles: a list beside the selected role's editor.
struct RolesView: View {
    @ObservedObject private var store = RoleStore.shared
    @ObservedObject private var navigation = AppNavigation.shared
    @State private var selection: String?
    @State private var confirmDelete: RoleProfile?

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(store.roles) { role in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(role.displayTitle).lineLimit(1)
                            if role.id == store.selectedRoleID {
                                Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                                    .help("Used for the next interview")
                            }
                        }
                        Text("\(role.plannedQuestions.count) questions \u{00B7} updated \(role.updatedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(role.id)
                    .contextMenu {
                        Button("Use for Next Interview") { store.selectedRoleID = role.id }
                        Button("Delete\u{2026}", role: .destructive) { confirmDelete = role }
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            .overlay {
                if store.roles.isEmpty {
                    ContentUnavailableView {
                        Label("No Roles", systemImage: "briefcase")
                    } description: {
                        Text("A role holds the job description, your planned questions and the cheater prompts.")
                    } actions: {
                        Button("New Role") { newRole() }
                    }
                }
            }

            Group {
                if let id = selection, let role = store.role(id: id) {
                    RoleEditor(role: role).id(role.id)
                } else {
                    ContentUnavailableView("Select a Role", systemImage: "briefcase",
                                           description: Text("Or create one with File \u{203A} New Role (\u{21E7}\u{2318}N)."))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Roles")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { newRole() } label: { Label("New Role", systemImage: "plus") }
                Button { if let id = selection { confirmDelete = store.role(id: id) } } label: {
                    Label("Delete Role", systemImage: "trash")
                }
                .disabled(selection == nil)
            }
        }
        .onAppear {
            if selection == nil { selection = store.selectedRoleID ?? store.roles.first?.id }
            handleNewRoleRequest()
        }
        .onChange(of: navigation.newRoleRequest) { _, _ in handleNewRoleRequest() }
        .confirmationDialog("Delete \u{201C}\(confirmDelete?.displayTitle ?? "")\u{201D}?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete Role", role: .destructive) {
                if let role = confirmDelete {
                    store.delete(role.id)
                    if selection == role.id { selection = store.roles.first?.id }
                }
                confirmDelete = nil
            }
        } message: {
            Text("Its questions and prompts are removed. Past interview reports are kept.")
        }
    }

    private func newRole() {
        let role = store.create()
        selection = role.id
    }

    private func handleNewRoleRequest() {
        guard navigation.newRoleRequest != nil else { return }
        navigation.newRoleRequest = nil
        newRole()
    }
}
