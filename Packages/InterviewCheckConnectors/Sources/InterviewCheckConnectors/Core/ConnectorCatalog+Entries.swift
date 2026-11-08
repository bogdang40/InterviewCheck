import Foundation

/// Every connector the app offers, with what it needs and what it brings.
public enum ConnectorCatalog {
    public static var all: [ConnectorDescriptor] { ConnectorKind.allCases.map(descriptor) }

    public static func descriptor(_ kind: ConnectorKind) -> ConnectorDescriptor {
        switch kind {
        case .appleCalendar:
            return entry(kind, "Calendar on this Mac", .calendar, "Interviews from every calendar this Mac syncs (iCloud, Google, Exchange, Outlook).",
                         .system, [.upcomingInterviews], setup: "Allow Calendar access when asked. Events with \u{201C}interview\u{201D}, \u{201C}screen\u{201D} or \u{201C}onsite\u{201D} in the title are picked up.", tested: true)
        case .icsFile:
            return entry(kind, "Invite files (.ics)", .calendar, "Drop an interview invite from any email into the app.",
                         .system, [.upcomingInterviews, .emailInvites], setup: "Drag a .ics invite onto the Interview screen, or use File \u{203A} Import Invite.", tested: true)
        case .google:
            return entry(kind, "Google Workspace", .calendar, "Interviews from Google Calendar (including invites from Gmail) and Google Meet transcripts with speakers and timing.",
                         .oauth(GoogleConnectorProvider.provider, clientFields: oauthClient + [keywords]), [.upcomingInterviews, .transcripts],
                         setup: "In Google Cloud Console enable the Calendar and Meet APIs and create an OAuth client of type Desktop app. Paste its client ID (and secret), then Sign In. Meet transcripts are available for meetings you organised, for 30 days.",
                         docs: "https://developers.google.com/workspace/calendar/api/v3/reference/events/list")
        case .microsoft365:
            return entry(kind, "Microsoft 365", .calendar, "Interviews from Outlook calendars and Teams meeting transcripts with speakers and timing.",
                         .oauth(MicrosoftConnectorProvider.provider(), clientFields: [
                             CredentialField("clientID", "Application (client) ID"),
                             CredentialField("tenant", "Tenant", placeholder: "organizations, or your tenant ID", optional: true),
                             CredentialField("transcripts", "Teams transcripts and recordings (needs admin consent)", toggle: true),
                             keywords]),
                         [.upcomingInterviews, .transcripts, .recordings],
                         setup: "Register an app in Microsoft Entra (Mobile and desktop platform, redirect http://localhost/callback, no secret) with delegated Calendars.Read and OnlineMeetings.Read. For Teams transcripts add OnlineMeetingTranscript.Read.All and OnlineMeetingRecording.Read.All and have an admin grant consent.",
                         docs: "https://learn.microsoft.com/graph/api/onlinemeeting-list-transcripts")
        case .zoom:
            return entry(kind, "Zoom", .meetings, "Zoom meetings you host and their cloud recordings: the audio-only file is scored like any recording.",
                         .oauth(ZoomConnectorProvider.provider, clientFields: oauthClient + [keywords]), [.upcomingInterviews, .recordings, .transcripts],
                         setup: "In the Zoom App Marketplace create a General app (user-managed), turn on Use Public Client OAuth, add redirect http://127.0.0.1/callback and the scopes user:read:user, meeting:read:list_meetings, cloud_recording:read:list_user_recordings. Cloud recordings need a Pro plan.",
                         docs: "https://developers.zoom.us/docs/api/meetings/")
        case .greenhouse:
            return entry(kind, "Greenhouse", .ats, "Scheduled interviews, candidates, r\u{00E9}sum\u{00E9}s, job posts, and private notes.",
                         .fields([CredentialField("clientID", "Client ID"),
                                  CredentialField("clientSecret", "Client secret", secret: true),
                                  CredentialField("userID", "Act as user ID", placeholder: "Optional: a Site Admin's user ID", optional: true)]),
                         [.upcomingInterviews, .candidates, .resumes, .jobDescriptions, .notes],
                         setup: "Greenhouse \u{203A} Configure \u{203A} Dev Center \u{203A} API Credentials \u{203A} Create \u{201C}Harvest V3 (OAuth)\u{201D} credentials with the interviews, interviewers, applications, candidates, attachments, jobs and job_posts list scopes (and notes:create to post notes). Harvest v1/v2 keys were retired in August 2026.",
                         docs: "https://harvestdocs.greenhouse.io/docs/authentication")
        case .lever:
            return entry(kind, "Lever", .ats, "Interviews on active opportunities, candidates, r\u{00E9}sum\u{00E9}s, postings and notes.",
                         .fields([CredentialField("apiKey", "API key", secret: true)]),
                         [.upcomingInterviews, .candidates, .resumes, .jobDescriptions, .notes],
                         setup: "A Lever Super Admin creates a key in Settings \u{203A} Integrations and API \u{203A} API Credentials with read access to opportunities, interviews, resumes and postings (and write for notes). Lever has no interview feed, so the first sync reads each open candidate.",
                         docs: "https://hire.lever.co/developer/documentation")
        case .ashby:
            return entry(kind, "Ashby", .ats, "Interview schedules, candidates, r\u{00E9}sum\u{00E9}s, job postings and notes.",
                         .fields([CredentialField("apiKey", "API key", secret: true)]),
                         [.upcomingInterviews, .candidates, .resumes, .jobDescriptions, .notes],
                         setup: "An Ashby Admin creates a key at Admin \u{203A} API Keys with Interviews, Candidates and Jobs read (Candidates write and \u{201C}non-offer private fields\u{201D} for private notes).",
                         docs: "https://developers.ashbyhq.com/")
        case .workable:
            return entry(kind, "Workable", .ats, "Interview events, candidates, r\u{00E9}sum\u{00E9}s, job descriptions and comments.",
                         .fields([CredentialField("subdomain", "Account subdomain", placeholder: "acme"),
                                  CredentialField("apiKey", "API access token", secret: true),
                                  CredentialField("memberID", "Your member ID (for comments)", optional: true)]),
                         [.upcomingInterviews, .candidates, .resumes, .jobDescriptions, .notes],
                         setup: "A Workable Admin generates an account token under Integrations with r_jobs and r_candidates (w_comments to post comments). Your member ID limits the list to your own interviews and is needed for comments.",
                         docs: "https://workable.readme.io/reference")
        case .smartRecruiters, .bambooHR, .teamtailor, .recruitee, .jazzHR, .breezyHR, .personio, .zohoRecruit, .workday, .icims:
            return MoreATSCatalog.descriptor(kind)
        case .merge, .kombo, .apideck, .unifiedTo:
            return UnifiedCatalog.descriptor(kind)
        case .mcp:
            return entry(kind, "MCP server", .mcp, "Any Model Context Protocol server your company runs or an HR vendor provides.",
                         .fields([CredentialField("url", "Server URL", placeholder: "https://mcp.example.com/mcp"),
                                  CredentialField("token", "Bearer token", secret: true, optional: true)]),
                         [.upcomingInterviews, .candidates, .jobDescriptions],
                         setup: "Paste the server's streamable HTTP URL and token. Its tools are listed; interviews are read through your AI provider.",
                         docs: "https://modelcontextprotocol.io/")
        }
    }

    static let keywords = CredentialField("keywords", "Extra title words", placeholder: "Optional, e.g. pairing, debrief", optional: true)
    static let oauthClient = [CredentialField("clientID", "OAuth client ID"),
                              CredentialField("clientSecret", "OAuth client secret", secret: true, optional: true)]

    static func entry(_ kind: ConnectorKind, _ name: String, _ category: ConnectorCategory, _ summary: String,
                      _ auth: ConnectorAuth, _ capabilities: [ConnectorCapability], setup: String,
                      docs: String? = nil, tested: Bool = false) -> ConnectorDescriptor {
        ConnectorDescriptor(kind: kind, name: name, category: category, summary: summary, auth: auth,
                            capabilities: capabilities, setup: setup, docsURL: docs.flatMap(URL.init(string:)),
                            isUntestedAgainstLiveAccount: !tested)
    }
}
