import AppKit
import InterviewCheckConnectors
import SwiftUI

/// The next interviews from connected systems, at the top of the setup
/// form. Prepare fills the candidate, role and résumé in one click.
struct UpcomingInterviewsSection: View {
    @ObservedObject var controller: InterviewController
    @ObservedObject private var connectors = ConnectorManager.shared
    @State private var preparingID: String?
    @State private var notes: [String] = []

    private var next: [ExternalInterview] {
        Array(connectors.upcoming.filter { ($0.endsAt ?? $0.startsAt.addingTimeInterval(3600)) > Date() }.prefix(6))
    }

    var body: some View {
        if !connectors.accounts.isEmpty || !connectors.upcoming.isEmpty {
            Section {
                if next.isEmpty {
                    Text(connectors.isSyncing ? "Checking your connected systems\u{2026}" : "No interviews in the next two weeks.")
                        .foregroundStyle(.secondary)
                }
                ForEach(next) { interview in
                    row(interview)
                }
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Upcoming Interviews")
                    Spacer()
                    if connectors.isSyncing { ProgressView().controlSize(.mini) }
                    Button { Task { await connectors.syncAll() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Check connected systems now")
                        .disabled(connectors.isSyncing)
                }
            } footer: {
                Text("From \(sourceNames). Prepare fills in the candidate, the role and job description, and the r\u{00E9}sum\u{00E9}.")
            }
        }
    }

    private var sourceNames: String {
        let names = connectors.accounts.map { $0.kind.descriptor.name }
        return names.isEmpty ? "invites you added" : ListFormatter.localizedString(byJoining: names)
    }

    private func row(_ interview: ExternalInterview) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(interview.candidate?.name ?? interview.title).lineLimit(1)
                Text([interview.startsAt.formatted(.relative(presentation: .named)),
                      interview.startsAt.formatted(date: .abbreviated, time: .shortened),
                      interview.job?.title, interview.source.descriptor.name]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let link = interview.meetingURL {
                Button("Join") {
                    NSWorkspace.shared.open(link)
                    // Joining also prepares the interview, unless that is done.
                    guard controller.externalRef != interview.id, preparingID == nil else { return }
                    preparingID = interview.id
                    Task {
                        notes = await connectors.prepare(interview, controller: controller)
                        preparingID = nil
                    }
                }
                .help("Open the \(MeetingLinks.platform(of: link).title) link and prepare this interview")
            }
            Button(preparingID == interview.id ? "Preparing\u{2026}" : "Prepare") {
                preparingID = interview.id
                Task {
                    notes = await connectors.prepare(interview, controller: controller)
                    preparingID = nil
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(preparingID != nil)
        }
        .padding(.vertical, 2)
    }
}
