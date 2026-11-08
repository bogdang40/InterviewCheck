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
        case .imapMail:
            return entry(kind, "Mail (IMAP)", .mail, "Interview invites from any mailbox: Gmail, iCloud, Yahoo, Fastmail, Zoho or your company\u{2019}s mail server. Updates and cancellations are followed.",
                         .fields([
                             CredentialField("email", "Email address", placeholder: "you@company.com"),
                             CredentialField("password", "App password", placeholder: "An app password, not your normal password", secret: true),
                             CredentialField("host", "IMAP server", placeholder: "Filled in for Gmail, iCloud, Yahoo, Fastmail; otherwise imap.example.com", optional: true),
                             CredentialField("folder", "Folder", placeholder: "INBOX, or [Gmail]/All Mail, or a folder kept for interviews", optional: true),
                             keywords,
                             CredentialField("everyInvite", "Every invite in this folder is an interview", toggle: true),
                         ]),
                         [.upcomingInterviews, .emailInvites],
                         setup: "Make an app password for InterviewCheck: Google Account \u{203A} Security \u{203A} App passwords (needs 2-Step Verification); Apple Account \u{203A} Sign-In and Security \u{203A} App-Specific Passwords; Yahoo \u{203A} Account security \u{203A} App passwords; Fastmail \u{203A} Settings \u{203A} Privacy & Security \u{203A} App passwords. The mailbox is only read: nothing is sent, moved or marked as read. For Outlook and Microsoft 365 mailboxes use the Microsoft 365 connector (their invites are already in Outlook\u{2019}s calendar).",
                         docs: "https://support.google.com/accounts/answer/185833")
        case .calendly:
            return entry(kind, "Calendly", .scheduling, "Screens and interviews booked through your Calendly links: the candidate\u{2019}s name, email and LinkedIn link, and the meeting link.",
                         .fields([CredentialField("apiKey", "Personal access token", secret: true), keywords, everyBooking]),
                         [.upcomingInterviews, .candidates],
                         setup: "In Calendly open Integrations & apps \u{203A} API and webhooks \u{203A} Personal access tokens, create a token with the scheduled_events:read and users:read scopes, and paste it here. Bookings whose event name reads like an interview are used (\u{201C}Phone Screen\u{201D}, \u{201C}Technical Interview\u{201D}); turn on the switch if this Calendly is only for interviews.",
                         docs: "https://developer.calendly.com/docs/authentication/how-to-authenticate-with-personal-access-tokens")
        case .calCom:
            return entry(kind, "Cal.com", .scheduling, "Screens and interviews booked through your Cal.com links (cal.com or self-hosted): the candidate\u{2019}s name and email, and the meeting link.",
                         .fields([CredentialField("apiKey", "API key", placeholder: "cal_live_\u{2026}", secret: true),
                                  CredentialField("url", "API address", placeholder: "Optional, for self-hosted: https://cal.example.com/api/v2", optional: true),
                                  keywords, everyBooking]),
                         [.upcomingInterviews, .candidates],
                         setup: "In Cal.com open Settings \u{203A} Developer \u{203A} API Keys, create a key and paste it here. Bookings whose title reads like an interview are used; turn on the switch if this account is only for interviews.",
                         docs: "https://cal.com/docs/api-reference/v2/bookings/get-all-bookings")
        case .google:
            return entry(kind, "Google Workspace", .calendar, "Interviews from Google Calendar (including invites from Gmail) and Google Meet transcripts with speakers and timing.",
                         .oauth(GoogleConnectorProvider.provider, clientFields: oauthClient + [
                             CredentialField("calendars", "Other calendars", placeholder: "Optional: calendar IDs, e.g. interviews@acme.com", optional: true),
                             keywords]), [.upcomingInterviews, .transcripts],
                         setup: "In Google Cloud Console enable the Calendar and Meet APIs and create an OAuth client of type Desktop app. Paste its client ID (and secret), then Sign In. Your primary calendar is read; add a team calendar under Other calendars (its ID is in Google Calendar \u{203A} Settings \u{203A} Integrate calendar). Meet transcripts are available for meetings you organised, for 30 days.",
                         docs: "https://developers.google.com/workspace/calendar/api/v3/reference/events/list")
        case .microsoft365:
            return entry(kind, "Microsoft 365", .calendar, "Interviews from Outlook calendars and Teams meeting transcripts with speakers and timing.",
                         .oauth(MicrosoftConnectorProvider.provider(), clientFields: [
                             CredentialField("clientID", "Application (client) ID"),
                             CredentialField("tenant", "Tenant", placeholder: "organizations, or your tenant ID", optional: true),
                             CredentialField("transcripts", "Teams transcripts and recordings (needs admin consent)", toggle: true),
                             CredentialField("calendars", "Other calendars", placeholder: "Optional: calendar names, e.g. Interviews", optional: true),
                             keywords]),
                         [.upcomingInterviews, .transcripts, .recordings],
                         setup: "Register an app in Microsoft Entra (Mobile and desktop platform, redirect http://localhost/callback, no secret) with delegated Calendars.Read and OnlineMeetings.Read (and Calendars.Read.Shared to read a shared team calendar named under Other calendars; sign in again after adding one). For Teams transcripts add OnlineMeetingTranscript.Read.All and OnlineMeetingRecording.Read.All and have an admin grant consent.",
                         docs: "https://learn.microsoft.com/graph/api/onlinemeeting-list-transcripts")
        case .zoom:
            return entry(kind, "Zoom", .meetings, "Zoom meetings you host and their cloud recordings: the audio-only file is scored like any recording.",
                         .oauth(ZoomConnectorProvider.provider, clientFields: oauthClient + [keywords]), [.upcomingInterviews, .recordings, .transcripts],
                         setup: "In the Zoom App Marketplace create a General app (user-managed), turn on Use Public Client OAuth, add redirect http://127.0.0.1/callback and the scopes user:read:user, meeting:read:list_meetings, cloud_recording:read:list_user_recordings. Cloud recordings need a Pro plan.",
                         docs: "https://developers.zoom.us/docs/api/meetings/")
        case .webex:
            return entry(kind, "Webex", .meetings, "Webex meetings you host, their invitees, and afterwards the transcript (with speaker names) and recording audio to score.",
                         .oauth(WebexConnectorProvider.provider, clientFields: [
                             CredentialField("clientID", "Integration client ID"),
                             CredentialField("clientSecret", "Integration client secret", secret: true),
                             keywords,
                         ]), [.upcomingInterviews, .recordings, .transcripts],
                         setup: "On developer.webex.com open My Webex Apps \u{203A} Create a New App \u{203A} Integration. Add the redirect URI http://127.0.0.1:53871/callback and the scopes spark:people_read, meeting:schedules_read, meeting:transcripts_read and meeting:recordings_read. Paste the client ID and secret, then Sign In. Transcripts need Webex Assistant turned on in the meeting; recordings need cloud recording.",
                         docs: "https://developer.webex.com/docs/meetings")
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
        case .greenhouseMCP:
            return entry(kind, "Greenhouse (MCP sign-in)", .mcp, "Sign in as yourself through Greenhouse's MCP server: no API credentials or admin keys.",
                         .mcp, [.upcomingInterviews],
                         setup: "A Greenhouse Site Admin enables MCP and approves the client under Dev Center \u{203A} MCP Access \u{203A} Clients (allow redirect http://127.0.0.1/callback). Interview tools may need write scopes enabled by the admin.",
                         docs: "https://support.greenhouse.io/")
        case .ashbyMCP:
            return entry(kind, "Ashby (MCP sign-in)", .mcp, "Your upcoming interviews through Ashby's MCP server, signed in as yourself.",
                         .mcp, [.upcomingInterviews],
                         setup: "An Ashby Admin turns on the MCP server under Admin \u{203A} Organization Setup \u{203A} Opt-In Features. Then Sign In.",
                         docs: "https://mcp.ashbyhq.com/")
        case .workableMCP:
            return entry(kind, "Workable (MCP sign-in)", .mcp, "Interview events through Workable's MCP server, signed in as yourself.",
                         .mcp, [.upcomingInterviews],
                         setup: "Sign In with your Workable account; Workable's MCP server is on for all plans.",
                         docs: "https://mcp.workable.com/")
        case .mcp:
            return entry(kind, "Other MCP server", .mcp, "Any Model Context Protocol server your company runs or an HR vendor provides.",
                         .mcp, [.upcomingInterviews],
                         setup: "Paste the server's streamable HTTP URL. Sign in with the browser, or paste a token if the server gives you one.",
                         docs: "https://modelcontextprotocol.io/")
        }
    }

    static let everyBooking = CredentialField("everyBooking", "Every booking is an interview", toggle: true)
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
