import InterviewCheckConnectors
import SwiftUI

/// Connections: every system the app can read interviews, jobs, résumés and
/// recordings from, grouped by kind, beside the selected one's setup.
struct ConnectionsView: View {
    @ObservedObject private var connectors = ConnectorManager.shared
    @State private var selection: ConnectorKind? = .appleCalendar
    @State private var search = ""
    @State private var reminderMinutes = InterviewReminders.minutes
    @State private var autoScore = AutoScorer.shared.isEnabled
    @State private var autoPrepare = AutoPrepare.shared.isEnabled
    @State private var confirmAutoScore = false
    @State private var myEmails = ConnectorManager.shared.typedEmails

    private func kinds(in category: ConnectorCategory) -> [ConnectorKind] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return ConnectorKind.allCases.filter { kind in
            let descriptor = kind.descriptor
            guard descriptor.category == category else { return false }
            return query.isEmpty || "\(descriptor.name) \(descriptor.summary)".lowercased().contains(query)
        }
    }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                Section {
                    TextField("Your work email", text: $myEmails, prompt: Text("you@company.com"))
                        .onChange(of: myEmails) { _, value in connectors.typedEmails = value }
                        .help("Only interviews you are on are shown. Separate several addresses with commas.")
                    if !connectors.myEmails.isEmpty {
                        Text("Showing interviews for \(connectors.myEmails.sorted().joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                } header: {
                    Text("You")
                }
                ForEach(ConnectorCategory.allCases, id: \.self) { category in
                    let kinds = kinds(in: category)
                    if !kinds.isEmpty {
                        Section(category.title) {
                            ForEach(kinds) { kind in
                                ConnectorRow(kind: kind, account: connectors.account(kind),
                                             isSyncing: connectors.syncing.contains(kind))
                                    .tag(kind)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search systems")
            .frame(minWidth: 240, idealWidth: 290, maxWidth: 380)

            Group {
                if let kind = selection {
                    ConnectorDetailView(kind: kind, select: { selection = $0 }).id(kind)
                } else {
                    ContentUnavailableView("Select a System", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("Connect your ATS, calendar and meeting tools."))
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("Score new meeting recordings automatically?", isPresented: $confirmAutoScore) {
            Button("Turn On") {
                autoScore = true
                AutoScorer.shared.isEnabled = true
                Task { await AutoScorer.shared.run() }
            }
        } message: {
            Text("New recordings of scheduled interviews are transcribed and scored in the background with your Deepgram and AI keys, and you get a notification when each report is ready. Only turn this on if candidates are told their interviews are recorded and checked.")
        }
        .navigationTitle("Connections")
        .navigationSubtitle(connectors.accounts.isEmpty ? "" : "\(connectors.accounts.count) connected")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { autoScore }, set: { on in
                    if on { confirmAutoScore = true } else { autoScore = false; AutoScorer.shared.isEnabled = false }
                })) {
                    Label("Score Recordings Automatically", systemImage: "wand.and.stars")
                }
                .toggleStyle(.button)
                .help("Score new Zoom, Teams, Meet and Webex recordings of scheduled interviews as they arrive")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $autoPrepare) {
                    Label("Get Next Interview Ready", systemImage: "person.crop.circle.badge.clock")
                }
                .toggleStyle(.button)
                .help("A few minutes before each interview, fill in the candidate, role and r\u{00E9}sum\u{00E9} by itself (never over setup you typed, never starts the interview)")
                .onChange(of: autoPrepare) { _, on in
                    AutoPrepare.shared.isEnabled = on
                    if on { Task { await AutoPrepare.shared.tick() } }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Picker(selection: $reminderMinutes) {
                    ForEach(InterviewReminders.choices, id: \.self) { minutes in
                        Text(minutes == 0 ? "No reminders" : "Remind \(minutes) min before").tag(minutes)
                    }
                } label: {
                    Label("Reminders", systemImage: "bell")
                }
                .help("A notification before each upcoming interview, with Prepare")
                .onChange(of: reminderMinutes) { _, minutes in
                    InterviewReminders.minutes = minutes
                    InterviewReminders.shared.schedule(connectors.upcoming)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await connectors.syncAll() } } label: {
                    Label("Sync All", systemImage: "arrow.clockwise")
                }
                .help("Check every connected system now")
                .disabled(connectors.accounts.isEmpty || connectors.isSyncing)
            }
        }
    }
}

private struct ConnectorRow: View {
    let kind: ConnectorKind
    let account: ConnectorManager.Account?
    let isSyncing: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.descriptor.name).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if isSyncing {
                ProgressView().controlSize(.small)
            } else if let account {
                Image(systemName: account.lastError == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(account.lastError == nil ? .green : .orange)
                    .accessibilityLabel(account.lastError == nil ? "Connected" : "Needs attention")
            }
        }
        .padding(.vertical, 1)
    }

    private var status: String {
        if let account { return account.lastError == nil ? account.label : "Needs attention" }
        if !kind.routedThrough.isEmpty {
            return "Via " + ListFormatter.localizedString(byJoining: kind.routedThrough.map { $0.descriptor.name })
        }
        if !ConnectorFactory.implemented.contains(kind), kind != .icsFile { return "Coming soon" }
        return kind.descriptor.capabilities.prefix(2).map(\.title).joined(separator: ", ")
    }
}
