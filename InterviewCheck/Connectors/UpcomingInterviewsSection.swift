import AppKit
import InterviewCheckConnectors
import SwiftUI

/// The next interviews from connected systems, at the top of the setup
/// form. Prepare fills the candidate, role and résumé in one click.
struct UpcomingInterviewsSection: View {
    @ObservedObject var controller: InterviewController
    @ObservedObject var connectors: ConnectorManager = .shared
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("From \(sourceNames). Prepare fills in the candidate, the role and job description, and the r\u{00E9}sum\u{00E9}.")
                    if connectors.hiddenForOthers > 0 || connectors.showsAllInterviews {
                        HStack(spacing: 6) {
                            Text(connectors.showsAllInterviews
                                 ? "Showing every interviewer's interviews."
                                 : "\(connectors.hiddenForOthers) interview\(connectors.hiddenForOthers == 1 ? "" : "s") for other interviewers hidden.")
                            Button(connectors.showsAllInterviews ? "Only Mine" : "Show All") {
                                connectors.showsAllInterviews.toggle()
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
        }
    }

    private var sourceNames: String {
        var names: [String] = []
        for kind in connectors.upcoming.map(\.source) + connectors.accounts.map(\.kind) {
            let name = kind == .icsFile ? "invites you added" : kind.descriptor.vendorName
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? "your connections" : ListFormatter.localizedString(byJoining: names)
    }

    private func row(_ interview: ExternalInterview) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(interview.candidate?.name ?? interview.title).lineLimit(1)
                    if UpcomingTime.isSoon(interview.startsAt) { Tag(text: "Soon", color: .orange) }
                    // The setup already holds this interview (prepared by hand or automatically).
                    if controller.preparedFrom == interview.id, controller.externalRef != nil, controller.phase == .setup {
                        Tag(text: "Ready", color: .green)
                    }
                }
                Text([UpcomingTime.label(interview.startsAt), interview.job?.title, interview.source.descriptor.vendorName]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let link = interview.meetingURL {
                Button("Join") {
                    NSWorkspace.shared.open(link)
                    AutoPrepare.shared.markJoined(interview.id)
                    // Joining also prepares the interview, unless that is done.
                    let ready = controller.preparedFrom == interview.id && controller.externalRef != nil
                    guard !ready, preparingID == nil else { return }
                    preparingID = interview.id
                    Task {
                        notes = await connectors.prepare(interview, controller: controller)
                        preparingID = nil
                    }
                }
                .help("Open the \(MeetingLinks.platform(of: link).title) link and prepare this interview")
                .accessibilityLabel("Join \(MeetingLinks.platform(of: link).title) call with \(interview.candidate?.name ?? interview.title)")
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
            .accessibilityLabel("Prepare interview with \(interview.candidate?.name ?? interview.title)")
        }
        .padding(.vertical, 2)
    }
}
