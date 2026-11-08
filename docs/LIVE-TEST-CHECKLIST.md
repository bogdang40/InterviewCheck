# First live test of each connector

Every connector was built from the vendor's published documentation and tested
against recorded responses (`swift test` in `Packages/InterviewCheckConnectors`).
None has met a real account yet. This list is for the first real sync of each one:
what is needed, what to look at, and which documented details are still unconfirmed.

How to look: Connections (⌘4) › the system › **Sync Now**. The detail page shows the
account, the number of upcoming interviews, any error, and any "Stopped after …" note.
Interview › Upcoming Interviews shows what came in; **Prepare** shows what fills in.

Order suggested by how many customers each reaches and how little setup it needs.

## No admin needed

| System | Needs | Check | Unconfirmed |
|---|---|---|---|
| Calendar on this Mac | Calendar access | An event titled "Interview with …" appears; the outside guest becomes the candidate | – |
| Calendar feed (iCal link) | A Google "Secret address in iCal format" | Times are right in your time zone; a cancelled event disappears after the provider refreshes the feed (Google: hours) | Recurring interviews show only if their first date is in range (RRULE is not expanded) |
| Mail (IMAP) | Gmail with 2-Step Verification and an app password | Verify shows "address · INBOX (N messages)"; an invite from another company appears; a cancellation email removes it; nothing is marked as read in Gmail; email yourself "Jane_Doe_CV.pdf", then Prepare a Jane Doe interview with no ATS résumé: it is found and named | Exchange/Outlook-originated invites inside Gmail; folders with non-ASCII names; forwarded invites (message/rfc822) are not read |
| Calendly | A personal access token | A booking named "Phone Screen …" appears with the invitee's email; a LinkedIn answer becomes the profile link | Event types with several invitees (only the first is the candidate) |
| Cal.com | An API key | Upcoming and finished bookings; Cal Video links | Header `cal-api-version: 2026-05-01` accepted by self-hosted versions |

## Calendars and meetings (company registers an OAuth app once)

| System | Check | Unconfirmed |
|---|---|---|
| Google Workspace | Primary and a team calendar (Other calendars); Meet transcript after a meeting you organised | – |
| Microsoft 365 | Outlook events; a named team calendar after signing in again; Teams transcript with admin consent | `Calendars.Read.Shared` on a tenant that blocks user consent |
| Zoom | Upcoming meetings you host; the audio file of a cloud recording scores | Loopback redirect without a port in the Zoom app settings |
| Webex | Meetings you host with invitees; a transcript (Webex Assistant on) and the recording audio, fetched days later | Exact port match `http://127.0.0.1:53871/callback`; PKCE alongside the client secret; `temporaryDirectDownloadLinks` for non-hosts |

## Applicant tracking

| System | Check | Unconfirmed |
|---|---|---|
| Greenhouse (Harvest v3) | Your scheduled interviews only ("Show all" for others); job post text; résumé; Send Summary as a private note | – |
| Lever, Ashby, Workable | Interviews, job text, résumé, note | Workable comments need a member ID |
| SmartRecruiters, Recruitee, Zoho Recruit | Interviews from the Interview step / your events | Zoho data-center domain (zoho.com, .eu, .in …) |
| Teamtailor, BambooHR, JazzHR, Breezy, Personio | No interview API: a calendar invite is matched to the candidate by email | – |
| Bullhorn | Interview-type appointments; an invited colleague sees them too; résumé attachment | The appointment type is literally "Interview" in the agency's list (else name it); loopback redirect accepted by Bullhorn Support; whether PKCE is ignored |
| JobAdder | Interviews and the scheduler's events merged; résumé | App approval; loopback redirect accepted; whether `read` alone covers /interviews and /events; whether `/candidates?Email=` filters |
| Merge, Kombo, Unified.to, Apideck | Interviews (not Apideck), job text, résumé | Per-ATS field coverage differs; check the first few interviews against the ATS |
| MCP (Greenhouse, Ashby, Workable) | Sign-in in the browser; the tools list; interviews read from whichever interview tool the server offers | Tool names and result shapes (vendors say they may change) |

## Known limitation to check

Some sources give interviewers by name only (Workable without a member ID, Zoho Recruit,
SmartRecruiters, Unified.to, MCP servers). "Only interviews you are on" matches by email,
so their interviews all count as yours: in a large company Upcoming, reminders and
automatic Prepare would cover everyone's interviews. On the first sync of such a source,
check the count. If it is the whole company, set Workable's member ID, or use a calendar
connection instead for that team.

## After the first sync

- **Prepare:** candidate, role with the job description and résumé fill in, with no
  "Preparation stopped" message. Prepare an interview from a calendar invite while an
  ATS is connected: the ATS candidate should be found by email.
- **Automation:** with Get Next Interview Ready on, the next interview fills in at
  reminder time and shows **Ready**. Typing into the setup first must stop it.
- **Recordings:** File › Analyze Recording lists the meeting; with Score Recordings
  Automatically on, a "Report ready" notification arrives after the meeting.
- **Report PDFs:** with a folder chosen in Settings › Privacy, a PDF appears when an
  interview ends.

Report anything odd with the connector name, the error text from its detail page,
and what was expected. Never paste keys or app passwords into a report.
