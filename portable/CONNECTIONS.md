# Portable connections

Run FastAPI on the operator's loopback interface. Set environment variables in the shell that starts the service. The browser reads availability flags. Keys stay in the server process. Each workstation has one operator and one local database.

## Capture and reference answers

In a consented interview, open **Capture audio**. Select the call tab or the microphone, confirm transfer to Deepgram, then start transcription. For a browser call, enable audio in the browser's sharing picker. The display picker can require a video track. Only the selected audio track enters the recorder. System audio depends on the operating system, browser, and selected surface. A browser that returns no audio track shows an error. Microphone capture and file import are available separately.

Stop capture to flush the final words. Edit the excerpt before applying it to the answer. Each live stream has limits of 30 minutes and 24 MiB. Shorter clips make attribution easier. For prerecorded speech, select an audio or video file under 24 MiB, confirm transfer, pick a speaker and a turn, then edit the text. Unknown speakers require manual identification. **Discard excerpt** removes the pending text. Raw audio stays in memory during transfer. The Deepgram service receives the selected audio when the operator requests transcription. [Deepgram live audio](https://developers.deepgram.com/reference/speech-to-text/listen-streaming) and [recorded audio](https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded).

| Function | Server configuration |
| --- | --- |
| Transcription | DEEPGRAM_API_KEY |
| OpenAI reference | OPENAI_API_KEY and INTERVIEWCHECK_REFERENCE_MODEL |
| Embedded accounts | INTERVIEWCHECK_ACCESS_MODE=embedded and INTERVIEWCHECK_OPERATOR_EMAIL |
| Remote account service | INTERVIEWCHECK_ACCESS_URL and INTERVIEWCHECK_OPERATOR_EMAIL |

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

Set `INTERVIEWCHECK_ACCESS_MODE=embedded` and `INTERVIEWCHECK_OPERATOR_EMAIL` to run accounts in the workspace FastAPI process. Start the workspace, open **Account**, and create the operator account. A local review database has one operator. The service enforces the configured email before returning workspace data. Set `TRIAL_DAYS` to grant new accounts a trial. The default is zero days. For public operation also set `INTERVIEWCHECK_SIGNUP_SECRET` to a strong invitation code before registration. Public embedded registration requires this code. The account service stores only scrypt password hashes and hashed session tokens. The browser receives a session cookie with HttpOnly and SameSite Strict attributes. Public HTTPS mode sets Secure.

If you choose **Sign out** during a password change, the app waits for that request to finish, then signs out. Browsers that permit Web Locks also coordinate this order across open app tabs on the same origin. When Web Locks are unavailable, the order applies within the current page. If the password change was not confirmed and you see the sign in screen, a notice remains until you dismiss it, sign in, or reload the page.

The default account database is `access.sqlite3` beside the review database. Set `INTERVIEWCHECK_ACCESS_DB` to override it. Stop the original Node access service and use a consistent SQLite backup to migrate existing users, device sessions, grants and subscriptions. Both account services upgrade older schemas to version 5. Keep a preupgrade backup for rollback and use one writer per database. The native production scrypt format is compatible. Use a separate file for the review database. `SESSION_TTL_DAYS` defaults to 30. Disabled accounts and revoked or expired sessions lose access.

For subscriptions, set `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, and at least one of `STRIPE_PRICE_MONTHLY` and `STRIPE_PRICE_ANNUAL`. Enable the Stripe customer portal. Set `PUBLIC_BASE_URL` to the externally reachable service origin, or use the configured public workspace origin. During local testing set it to the browser entry origin including the port, and run `stripe listen --forward-to http://localhost:3000/v1/billing/webhook` for the Next.js app. Use port 8765 for the packaged edition. Configure Stripe to deliver checkout.session.completed and customer.subscription.created, updated, paused, resumed, and deleted events to `/v1/billing/webhook`. The service verifies the raw request signature and timestamp before it processes a delivery. It rechecks changed subscriptions with Stripe and commits the entitlement update and replay record in one transaction.

**Open checkout** opens the selected plan in Stripe. **Billing portal** opens the customer portal. When Stripe returns, open **Account** and choose **Refresh access**. A checkout return alone does not grant access. The signed subscription event must have arrived. Past due grace starts when the status changed and defaults to three days, configurable with `PAST_DUE_GRACE_DAYS`. Only configured subscription prices qualify.

For a separate account service, run `python -m uvicorn api.account_server:app --host 127.0.0.1 --port 8787` from the portable directory, with the account environment above and an invitation code. Configure the reverse proxy for HTTPS before exposing that service. Its `/v1` routes serve accounts and billing only. Point the workspace at it with `INTERVIEWCHECK_ACCESS_URL` and set the operator email. An existing compatible Node access service can also serve this remote mode. The packaged app needs no Node account service.

## Account administration

An administrator can search users, grant or revoke complimentary access, change a role, disable an account, and inspect recent audit entries in **Account**. The UI asks for confirmation before applying changes. Disabling an account revokes its sessions. The service protects the last active administrator from demotion or removal. To provision an initial administrator, configure the email in `ADMIN_EMAILS` and set `ADMIN_BOOTSTRAP_SECRET`, then enter that secret under **Administrator setup** at signup. In public mode the separate operator invitation is also required. Existing native administrator roles are retained when an access database is migrated.

The Python access API provides the native admin operations at `/v1/admin/stats`, `/v1/admin/users`, `/v1/admin/users/{id}` and `/v1/admin/audit`. An authenticated admin bearer token is required. An embedded workspace admits only the assigned operator. A separately deployed access service can manage membership for multiple workstations.

## Verification

The integration tests replace network transport and exercise request construction, error handling, speaker selection data, provider consent, schedule and CSV parsing, access cookies, entitlement checks, recording selection and streaming flush. They do not measure detection accuracy, hardware audio support or tenant permissions.

## Connection setup directory

Open **Connections** and find a provider or task under **Connection setup**. Select a provider and expand its operation. Each operation lists its own required settings and any alternative credential group. The directory displays server setting names and whether each is present. Keys, service URLs, local paths, account identities and token values stay out of the response. Set variables in the process environment and restart the service after changing its environment.

**Configured** means the required setup is present for that operation. It establishes neither successful authentication nor sufficient vendor permissions. For example, Workable lookup can be configured while private notes still require the workstation member setting. Zoom transcripts can be configured while transcribing a recording also requires Deepgram. Remote billing is labeled **Managed by account service** because the workspace cannot infer the remote Stripe configuration. File imports are labeled **Ready locally**. The directory performs no vendor authentication, OAuth refresh, transcription, generation, payment or send operation. In a gated workspace, the authenticated operator can inspect the directory.

## Local audio preflight

Use **Audio preflight** in New interview or Connections to test your own voice or a test call. **Test microphone** requests a microphone. **Test shared call audio** opens the browser's surface picker. Choose a call tab and enable audio if the browser offers it. The check measures the root mean square signal level for three seconds. A quiet result can mean that the selected source was silent. The result describes the selected stream during that interval.

The test uses the browser's audio analyser. It creates no recording or transcript, stores no measurements and sends no audio to a service. **Stop audio check**, permission cancellation, an ended source, closing the panel, hiding the tab or leaving the page releases the tracks and audio context. A permission result arriving after cancellation is discarded. Browser and operating system support determine whether a selected sharing surface provides an audio track.
