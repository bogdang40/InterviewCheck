# Connecting InterviewCheck

Connections (⌘4) links InterviewCheck to the systems interviews already live in.
Once connected, the Interview screen lists upcoming interviews. **Prepare** fills in
the candidate, the role with its job description, and the résumé. A reminder
arrives before each interview. Meeting recordings can be scored, and a report can
send a private summary note back to the ATS.

Keys and sign-ins are kept in the macOS Keychain. Interview data is read from each
system and kept on the interviewer's Mac. Nothing is sent to InterviewCheck's own
server.

All connectors were built from each vendor's published API documentation (November
2026). They have been tested against those documented responses, not yet against
live customer accounts. Check the first sync of each new system.
[LIVE-TEST-CHECKLIST.md](LIVE-TEST-CHECKLIST.md) lists what to check on each first sync
and which documented details are still unconfirmed.

## Start here: no setup

| Source | What it brings | Setup |
|---|---|---|
| **Calendar on this Mac** | Interviews from every calendar macOS syncs (iCloud, Google, Exchange, Outlook) | Allow Calendar access. Events with "interview", "screen" or "onsite" in the title are used. Add extra title words if your team uses others. |
| **Invite files (.ics)** | One interview per dropped invite | Drag the invite from any email. Outlook's Windows time zones are understood. |
| **Calendar feed (iCal link)** | Interviews from any calendar's secret iCal address (Google, Outlook, iCloud, Fastmail, scheduling tools) | Paste the address (`https://…` or `webcal://…`, several one per line). It is a secret: anyone with it can read the calendar. Feeds refresh every few hours on the provider's side. If a feed cannot be read, the sync reports it and keeps the last good list. |

A calendar invite rarely contains a job description or résumé. When an ATS is also
connected, Prepare looks the candidate up there by email and fills those in. Any
summary note then goes to that ATS.

Interviews from an ATS or unified API show only when **you** are one of the
interviewers. Your email comes from a connected Google, Microsoft 365 or Zoom
account, or from the "Your work email" field at the top of Connections. Systems that list
interviewers by name only (Workable, Zoho Recruit, SmartRecruiters, Unified.to, MCP) are
matched by the full name you add to that field ("lee@acme.com, Lee Park").

## Mail (any mailbox, over IMAP)

**Mail (IMAP)** reads interview invites straight from a mailbox: Gmail, iCloud, Yahoo,
AOL, Fastmail, Zoho, GMX, or a company mail server. It is useful when invites are not
accepted into a calendar, or when a shared mailbox such as interviews@ receives them.

1. Make an app password for InterviewCheck:
   - Gmail: Google Account › Security › App passwords (needs 2-Step Verification).
   - iCloud: Apple Account › Sign-In and Security › App-Specific Passwords.
   - Yahoo: Account security › App passwords. Fastmail: Settings › Privacy & Security › App passwords.
2. In Connections › Mail (IMAP), enter the address and the app password. The server is
   filled in for the big providers; for others type it (`imap.example.com`, or `host:port`).
3. Optionally pick a folder (`[Gmail]/All Mail` finds archived invites too), add title
   words, or turn on **Every invite in this folder is an interview** for a mailbox kept
   only for interviews.

How it reads:
- The mailbox is only read: it is opened with EXAMINE, and parts are fetched with
  BODY.PEEK, so nothing is marked as read, moved or sent.
- Only the calendar parts (text/calendar, application/ics or *.ics) of messages from the
  last 60 days are downloaded, up to the newest 500 messages and 150 invites per sync.
- When an invite is updated, the version with the highest SEQUENCE (then the newest
  message) wins. A cancellation (METHOD:CANCEL or STATUS:CANCELLED) removes the interview.
- **Résumés from mail:** when you press Prepare and no ATS has the candidate's résumé, the
  mailbox server is searched (last 90 days) for the candidate's name or email. A PDF, Word,
  RTF or ODT attachment is taken only if its file name has the candidate's first and last name
  (or it looks like a CV and the subject has them). A surname
  alone or a one-word name never matches; titles and middle names are not needed. Prepare
  says which file and sender it used.
  Only Prepare and Join in the app and the Shortcuts actions use mail résumés (they show
  that note); automatic Prepare, the Dock, links and reminders do not. Turn it
  off with "Don't look for résumés in mail".
- Outlook and Microsoft 365 mailboxes no longer accept app passwords. Use the Microsoft
  365 connector; their invites are already in the Outlook calendar.
- Proton Mail works through Proton Mail Bridge on the Mac (`127.0.0.1:1143` is not TLS,
  so it is not supported yet).

## Booking links (Calendly, Cal.com)

Many first-round screens are booked through a scheduling link. The person who booked
is the candidate; their email lets Prepare find them in a connected ATS.

| Tool | Credential | What comes in |
|---|---|---|
| **Calendly** | Personal access token (Integrations & apps › API and webhooks) with `scheduled_events:read` and `users:read` | Your active bookings, the invitee's name and email, a LinkedIn or GitHub link typed into a booking question, the meeting link |
| **Cal.com** | API key (Settings › Developer › API Keys); self-hosted instances add their `https://…/api/v2` address | Upcoming accepted bookings, the attendee's name and email, the meeting link (Cal Video included) |

Only bookings whose name reads like an interview are used ("Phone Screen",
"Technical Interview"). Turn on **Every booking is an interview** when the account is
used only for hiring. A job title is taken from the booking name only when it names a
job ("Phone Screen - Backend Engineer").

## Calendars and meeting tools (browser sign-in)

Each company registers its own OAuth app once and pastes the client ID. Each
interviewer then signs in with the browser. There is no client secret for Microsoft
and Zoom (they are public clients). The redirect is a loopback address on the Mac.

**Google Workspace** (Calendar and Meet transcripts)
1. In Google Cloud Console, create a project and enable the Google Calendar API and the Google Meet REST API.
2. Configure the OAuth consent screen. Internal apps on your Workspace domain skip Google's verification.
3. Create an OAuth client of type **Desktop app**. Paste its client ID (and secret) into Connections, then Sign In.
4. Scopes requested: `calendar.events.readonly` and `meetings.space.readonly`.

Notes:
- Your primary calendar is read. Add a team calendar (for example interviews@acme.com) under
  **Other calendars**; its ID is in Google Calendar › Settings › Integrate calendar. An event
  on both calendars counts once, and a calendar that cannot be read is named on the account.
- Meet transcripts are available for meetings you organised, for 30 days.
- Gmail and Drive are not used. Their scopes are "restricted" and require a security
  assessment, and interview invites reach Google Calendar anyway.

**Microsoft 365** (Outlook calendar and Teams transcripts)
1. In Microsoft Entra, open App registrations and choose New registration. Under Mobile and desktop applications, add the redirect URI `http://localhost/callback`. Do not create a secret.
2. Add the delegated permissions `Calendars.Read` and `OnlineMeetings.Read`.
3. For Teams transcripts and recordings, also add `OnlineMeetingTranscript.Read.All` and `OnlineMeetingRecording.Read.All`, and have an admin grant consent. Then turn on the Teams transcripts switch in Connections.

Notes:
- Your default calendar is read. Name other calendars (for example "Interviews") under
  **Other calendars**. A shared team calendar also needs `Calendars.Read.Shared`; sign in
  again after adding one.
- **Look for résumés in Outlook mail** (off by default) adds `Mail.Read`: when no ATS has the
  candidate's résumé, Prepare searches the last 90 days of Outlook mail for the candidate's
  name and email, with the same strict matching as the IMAP mailbox.
- Attendees can read transcripts. Only the organiser can download recordings.
- An admin can turn off transcript access for apps. The app then explains this.

**Zoom** (hosted meetings and cloud recordings)
1. In the Zoom App Marketplace, create a General app (user-managed) and turn on **Use Public Client OAuth**.
2. Add the redirect `http://127.0.0.1/callback` and the scopes `user:read:user`, `meeting:read:list_meetings` and `cloud_recording:read:list_user_recordings`.
3. Paste the client ID into Connections and Sign In.

Notes:
- Only meetings you host are listed.
- Cloud recording needs a Pro plan. The audio-only file is what gets scored.

**Webex** (hosted meetings, transcripts and recordings)
1. On developer.webex.com open My Webex Apps › Create a New App › Integration.
2. Add the redirect URI `http://127.0.0.1:53871/callback` (Webex matches the port exactly,
   so the app always listens on this one) and the scopes `spark:people_read`,
   `meeting:schedules_read`, `meeting:transcripts_read` and `meeting:recordings_read`.
3. Paste the client ID and secret into Connections and Sign In.

Notes:
- Only meetings you host are listed; the outside invitee is taken as the candidate.
- Transcripts need Webex Assistant turned on in the meeting. Recordings need cloud
  recording; the audio file is fetched through Webex's short-lived direct link.

## Applicant tracking systems

| System | Upcoming interviews | Job text | Résumé | Private note | Credential |
|---|---|---|---|---|---|
| Greenhouse | ✓ | ✓ (job posts) | ✓ | ✓ | Harvest **v3** OAuth client ID + secret (v1/v2 keys were retired on 31 Aug 2026) |
| Lever | ✓ (read per open candidate) | ✓ | ✓ | ✓ (secret note) | API key (Super Admin) |
| Ashby | ✓ | ✓ | ✓ | ✓ | API key (Admin), with Interviews, Candidates and Jobs read |
| Workable | ✓ | ✓ | ✓ | ✓ (comment, admins only) | Account subdomain + token; member ID for comments |
| SmartRecruiters | ✓ (candidates in the Interview step) | ✓ | ✓ | Shared message (no private notes) | OAuth client or API key |
| Recruitee | ✓ (your events) | ✓ | ✓ | ✓ (only you) | Company ID + personal API token |
| Zoho Recruit | ✓ | ✓ | ✓ | Note | Self Client: client ID, secret, refresh token |
| Teamtailor | from calendar | ✓ | ✓ | Note | Admin API key; your user ID for notes |
| BambooHR | from calendar | – (not in its API) | ✓ | Comment | Subdomain + API key |
| JazzHR | from calendar | ✓ | ✓ | ✓ (only you) | API key |
| Breezy HR | from calendar | ✓ | ✓ | Team note | Personal access token |
| Personio | from calendar | – | – | – | Client ID + secret (Recruiting read) |
| Bullhorn (staffing) | ✓ (Interview appointments) | ✓ | ✓ | – (notes cannot be private) | API key from Bullhorn Support + API user name; browser sign-in |
| JobAdder (staffing) | ✓ (interviews + scheduler events) | ✓ | ✓ | – (notes cannot be private) | Approved developer app (client ID + secret); browser sign-in |

Bullhorn and JobAdder match the sign-in redirect exactly, so register
`http://127.0.0.1:53871/callback`; InterviewCheck always listens on that port for them (and
for Webex). Bullhorn's sign-in host depends on the customer's data center, which is found
from the API user name before the browser opens; only `*.bullhornstaffing.com` addresses are
accepted. Bullhorn reads appointments of the type "Interview" unless other types are named.
JobAdder reads both `/interviews` and the newer scheduler's `/events`, merged.

"From calendar" means the vendor's API has no interview schedule. The interview
comes from the interviewer's calendar, and the ATS supplies the candidate, job and
résumé through an email lookup.

The exact admin menu paths are shown in each connector's setup text in the app.

## Workday, iCIMS, SAP SuccessFactors, Oracle Taleo, Jobvite and the long tail

These are reached through a unified API account the company already has (or opens):

| Unified API | Best for | Notes |
|---|---|---|
| **Merge** | Workday, SuccessFactors, Taleo, Greenhouse, Lever, Ashby (interviews in 11 ATSs) | API key + linked-account token. Daily sync on the entry plan. Notes on 9 ATSs (private only on Greenhouse). |
| **Kombo** | Workday, SuccessFactors, SmartRecruiters, Personio, HiBob (interviews in 18 ATSs) | API key + integration ID. One call carries candidate and job. Data refreshes about every 3 hours. |
| **Unified.to** | iCIMS, Jobvite, Taleo BE, Oracle HCM (interviews in 55 ATSs) | Workspace token + connection ID. Live data. Workday interviews come without times; use Merge or Kombo for Workday. |
| **Apideck** | Job descriptions and applicants only | No interviews or notes in its ATS API. |

## MCP servers (sign in as yourself)

Greenhouse, Ashby and Workable run official Model Context Protocol servers. An
interviewer signs in with their own account: there are no API keys and no admin
credential in the app. The app registers itself as a public client and uses PKCE.

- **Greenhouse MCP** (`https://mcp.greenhouse.io/mcp`): a Site Admin enables MCP and
  approves the client under Dev Center › MCP Access › Clients, allowing the redirect
  `http://127.0.0.1/callback`. Interview tools may need write scopes enabled by the admin.
- **Ashby MCP** (`https://mcp.ashbyhq.com/mcp/v1`): an Admin turns it on under
  Organization Setup › Opt-In Features.
- **Workable MCP** (`https://mcp.workable.com/mcp`): available on all plans.
- **Any other MCP server:** paste its URL, then sign in or paste a token.

MCP tools can change without notice (Ashby says so). The app reads interviews from
whichever interview tool the server offers, and tolerates changes to the shape of
its results.

## Automation

- Upcoming interviews refresh at launch, every 15 minutes, and when the app comes to the front.
- Reminders arrive 10 minutes before each interview (adjustable or off in Connections), with **Prepare**.
- **Get Next Interview Ready** (on by default, in the Connections toolbar) prepares the next
  interview by itself at reminder time: candidate, role with job description, and résumé.
  It never starts the interview or ticks the consent box, never switches the window, waits
  while the Roles editor is open, and never replaces setup the interviewer typed. A setup it
  filled and nobody touched moves on to the next interview once that interview has ended.
- **Open the Meeting When It Starts** (off by default, same menu) opens the prepared
  interview's meeting link about a minute before the start, once (not after a manual Join).
- **Settings › Privacy › Save a PDF of each report** writes every finished report (live or
  scored in the background) into a chosen folder. Those files are not removed by the
  retention setting.
- **Score recordings automatically** (off by default) scores new recordings of scheduled
  interviews in the background and sends a "Report ready" notification.
  Turn it on only if candidates are told interviews are recorded and checked.
- **Roles › Share › Import from ATS** turns open jobs (Greenhouse, Lever, Ashby, Workable, Recruitee,
  Teamtailor, SmartRecruiters, Merge, Kombo, Unified.to) into roles with their job descriptions.
- When Prepare creates a role from an ATS job, the role's questions and tailored
  prompts are drafted in the background.
- Shortcuts actions: Prepare Next Interview, Join Next Interview (prepares it if needed and opens the meeting), Sync Interview Connections, Open Latest Interview Report.
- The Dock menu lists the next interviews.
- Links `interviewcheck://prepare-next`, `interviewcheck://join-next`, `interviewcheck://sync` and `interviewcheck://report/latest`.

## For the product owner: what needs a server later

Selling to many companies will need a small backend for credentials that should not
ship inside a desktop app:
- Each vendor's partner OAuth secret: Greenhouse partner sign-in, Lever OAuth and Workable partner tokens.
- The unified APIs' workspace keys: Merge, Kombo, Unified.to and Apideck.

Until then, each company uses its own keys, which stay in that interviewer's Keychain. The proposed server design is in [backend-plan.md](backend-plan.md).
