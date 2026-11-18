# Portable connections

Run FastAPI on the operator's loopback interface. Set environment variables in the shell that starts the service. The browser reads availability flags. Keys stay in the server process. Each workstation has one operator and one local database.

## Capture and reference answers

In a consented interview, open **Capture audio**. Select the call tab or the microphone, confirm transfer to Deepgram, then start transcription. For a browser call, enable audio in the browser's sharing picker. The display picker can require a video track. Only the selected audio track enters the recorder. System audio depends on the operating system, browser, and selected surface. A browser that returns no audio track shows an error. Microphone capture and file import are available separately.

Stop capture to flush the final words. Edit the excerpt before applying it to the answer. Each live stream has limits of 30 minutes and 24 MiB. Shorter clips make attribution easier. For prerecorded speech, select an audio or video file under 24 MiB, confirm transfer, pick a speaker and a turn, then edit the text. Unknown speakers require manual identification. **Discard excerpt** removes the pending text. Raw audio stays in memory during transfer. The Deepgram service receives the selected audio when the operator requests transcription. [Deepgram live audio](https://developers.deepgram.com/reference/speech-to-text/listen-streaming) and [recorded audio](https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded).

| Function | Server configuration |
| --- | --- |
| Transcription | DEEPGRAM_API_KEY |
| OpenAI reference | OPENAI_API_KEY and INTERVIEWCHECK_REFERENCE_MODEL |
| Account service | INTERVIEWCHECK_ACCESS_URL and INTERVIEWCHECK_OPERATOR_EMAIL |

A generated reference sends the question and role to the provider. The operator can inspect and edit it before comparison. Supplied references and local transcripts work without credentials.

## Scheduling and meeting files

**Connections** reads iCalendar files and candidate CSV files locally. CSV headers are `candidate,role`. The calendar importer honors cancelled events and later revisions in the same file. Export individual occurrences for recurring series. A calendar's optional X-INTERVIEWCHECK-CANDIDATE and X-INTERVIEWCHECK-ROLE properties prefill the form. The operator verifies both fields before starting.

| Service | Environment variable | Available action |
| --- | --- | --- |
| Google Calendar | GOOGLE_CALENDAR_ACCESS_TOKEN | Upcoming primary calendar events |
| Microsoft 365 | MS_GRAPH_ACCESS_TOKEN | Upcoming calendar events |
| Google Meet | GOOGLE_MEET_ACCESS_TOKEN | Recent conferences and transcript entries |
| Teams | TEAMS_ACCESS_TOKEN | Recent calendar occurrences, transcripts and recordings |
| Mailbox invitations | IMAP_HOST, IMAP_USERNAME and IMAP_PASSWORD | Import invitations from a configured IMAP mailbox |
| Calendly | CALENDLY_ACCESS_TOKEN | Upcoming bookings and invitee lookup on selection |
| Cal.com | CALCOM_API_KEY | Upcoming bookings and attendee names |
| Zoom | ZOOM_ACCESS_TOKEN | Upcoming hosted meetings and recent cloud files |
| Webex | WEBEX_ACCESS_TOKEN | Upcoming meetings, transcripts and recordings |

Click a sync button to request up to 100 upcoming records for 30 days. File import and lookup are explicit. Browsing a source creates no local interview. Most APIs need delegated read scopes and access to the meeting as its host or organizer. Supply a current vendor token and replace it when it expires. Google and Microsoft also support renewal. Configure GOOGLE_CLIENT_ID and GOOGLE_REFRESH_TOKEN, or MS_GRAPH_CLIENT_ID and MS_GRAPH_REFRESH_TOKEN. A confidential client also needs GOOGLE_CLIENT_SECRET or MS_GRAPH_CLIENT_SECRET. MS_GRAPH_TENANT defaults to common. The service refreshes once per provider, caches the access token until shortly before expiry, and keeps any rotated refresh token in memory. Provision a current refresh token again if the provider invalidates the original after a process restart. The original grant determines available scopes. Google Calendar and Meet share the configured Google grant, and Microsoft calendar and Teams share the Microsoft grant.

Under **Capture audio**, **Meeting recordings** lists recent Zoom and Webex files for configured accounts. A server issued selection expires after 15 minutes. For Meet and Teams, list recent meetings, select one, then list its files. Teams restricts files to the selected occurrence of a recurring meeting. Google Meet reads transcript entries in chronological order and preserves distinct participant identities. Choosing a saved transcript presents the speaker selection. Choosing audio or video requires consent for transfer to Deepgram. The server limits downloads to vendor HTTPS domains, strips authorization across host changes, and bounds the file size. If the vendor uses a different download host or supplies a larger file, use a local excerpt.

## Applicant tracking

**Connections** can look up a candidate by email with any configured directory. Results prefill the interview setup after the operator selects a row. A missing job title can be entered manually. Tests cover vendor payload fixtures. Access to a live tenant requires the vendor's credentials and read scopes.

| Directory | Configuration |
| --- | --- |
| Ashby | ASHBY_API_KEY |
| Lever | LEVER_API_KEY |
| Greenhouse Harvest v3 | GREENHOUSE_CLIENT_ID and GREENHOUSE_CLIENT_SECRET |
| Merge | MERGE_API_KEY and MERGE_ACCOUNT_TOKEN |
| Workable | WORKABLE_API_KEY and WORKABLE_SUBDOMAIN |
| Teamtailor | TEAMTAILOR_API_KEY and optional TEAMTAILOR_REGION=na |
| SmartRecruiters | SMARTRECRUITERS_API_KEY |
| BambooHR | BAMBOOHR_API_KEY and BAMBOOHR_SUBDOMAIN |
| Recruitee | RECRUITEE_API_KEY and RECRUITEE_COMPANY_ID |
| Personio | PERSONIO_CLIENT_ID and PERSONIO_CLIENT_SECRET |
| JobAdder | JOBADDER_ACCESS_TOKEN |
| Kombo | KOMBO_API_KEY and KOMBO_INTEGRATION_ID. Optional KOMBO_REGION is us or ca. |
| Unified.to | UNIFIED_API_KEY and UNIFIED_CONNECTION_ID. Optional UNIFIED_REGION is eu or au. |

## Accounts and billing

Run the existing access service with its documented settings and point INTERVIEWCHECK_ACCESS_URL at its origin. Use HTTPS for a remote service. Assign the allowed email with INTERVIEWCHECK_OPERATOR_EMAIL. Sign up or sign in from **Connections**. FastAPI checks account membership on workspace requests and when a live transcription stream starts. Only an active entitlement for the operator opens the workspace. The access token is stored in an HTTP only session cookie.

**Open checkout** and **Billing portal** use the existing Stripe service. After returning from Stripe, open the portable workspace and select **Refresh access**. The native billing return page also offers its macOS application link. Without Stripe configuration the access server reports that billing is unavailable. Personal provider tokens and billing credentials are separate. [Access server setup](../server/README.md).

## Verification

The integration tests replace network transport and exercise request construction, error handling, speaker selection data, provider consent, schedule and CSV parsing, access cookies, entitlement checks, recording selection and streaming flush. They do not measure detection accuracy, hardware audio support or tenant permissions.
