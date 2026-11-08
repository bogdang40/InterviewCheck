import XCTest
@testable import InterviewCheckConnectors

final class MeetingConnectorTests: XCTestCase {
    private let from = date("2026-11-07T00:00:00Z")
    private let to = date("2026-11-21T00:00:00Z")
    private let token: AccessTokenProvider = { "user-token" }

    func testWebVTTFromTeamsAndZoom() {
        let teams = "WEBVTT\n\n00:00:16.246 --> 00:00:17.726\n<v Jane Doe>This is a transcript test.</v>\n\n00:01:02.000 --> 00:01:04.500\n<v Sam Lead>Next question.</v>\n"
        XCTAssertEqual(WebVTT.cues(in: teams), [
            TranscriptCue(start: 16.246, end: 17.726, speaker: "Jane Doe", text: "This is a transcript test."),
            TranscriptCue(start: 62, end: 64.5, speaker: "Sam Lead", text: "Next question."),
        ])
        let zoom = "WEBVTT\n\n1\n00:00:01.000 --> 00:00:03.000\nSam Lead: How would you design it?\n"
        XCTAssertEqual(WebVTT.cues(in: zoom).first?.speaker, "Sam Lead")
        XCTAssertEqual(WebVTT.cues(in: zoom).first?.text, "How would you design it?")
        let round = WebVTT.cues(in: WebVTT.text(WebVTT.cues(in: teams)))
        XCTAssertEqual(round, WebVTT.cues(in: teams), "writing and reading back keeps the cues")
    }

    func testGoogleCalendarInterviewsWithMeetLink() async throws {
        let stub = StubTransport()
        stub.on("GET", "calendars/primary/events", json: #"{"items":[{"id":"abc123","status":"confirmed","summary":"Interview: Jane Doe (Backend)","description":"Join Zoom<br>https://us02web.zoom.us/j/81234567890?pwd=x","start":{"dateTime":"2026-11-10T14:00:00-05:00"},"end":{"dateTime":"2026-11-10T15:00:00-05:00"},"organizer":{"email":"recruiter@example.com"},"attendees":[{"email":"me@example.com","self":true},{"email":"jane@candidate.dev","displayName":"Jane Doe"}],"hangoutLink":"https://meet.google.com/abc-mnop-xyz","conferenceData":{"entryPoints":[{"entryPointType":"video","uri":"https://meet.google.com/abc-mnop-xyz"}]}},{"id":"standup","summary":"Standup","start":{"dateTime":"2026-11-10T09:00:00Z"}},{"id":"gone","status":"cancelled","summary":"Interview","start":{"dateTime":"2026-11-10T09:00:00Z"}}]}"#)
        let connector = try GoogleWorkspaceConnector(credentials: ConnectorCredentials(), transport: stub, accessToken: token)
        let interviews = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(interviews.map(\.externalID), ["abc123"])
        XCTAssertEqual(interviews[0].startsAt, date("2026-11-10T19:00:00Z"))
        XCTAssertEqual(interviews[0].meetingURL?.host, "meet.google.com")
        XCTAssertEqual(interviews[0].candidate?.name, "Jane Doe")
        XCTAssertEqual(interviews[0].candidate?.email, "jane@candidate.dev")
        XCTAssertEqual(stub.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer user-token")
        XCTAssertTrue(stub.requests[0].url!.absoluteString.contains("singleEvents=true"))
    }

    func testGoogleMeetTranscriptBecomesVTT() async throws {
        let stub = StubTransport()
        stub.on("GET", "/v2/conferenceRecords?", json: #"{"conferenceRecords":[{"name":"conferenceRecords/abc","startTime":"2026-11-05T19:00:00Z","endTime":"2026-11-05T20:00:00Z"},{"name":"conferenceRecords/live","startTime":"2026-11-07T19:00:00Z"}]}"#)
        // More specific routes first: routes match by substring.
        stub.on("GET", "transcripts/t1/entries", json: #"{"transcriptEntries":[{"participant":"conferenceRecords/abc/participants/p1","text":"Tell me about a system you designed.","startTime":"2026-11-05T19:02:11.000Z","endTime":"2026-11-05T19:02:14.000Z"},{"participant":"conferenceRecords/abc/participants/p2","text":"Sure, a rate limiter.","startTime":"2026-11-05T19:02:20.000Z","endTime":"2026-11-05T19:02:23.500Z"}]}"#)
        stub.on("GET", "conferenceRecords/abc/transcripts", json: #"{"transcripts":[{"name":"conferenceRecords/abc/transcripts/t1","state":"FILE_GENERATED"}]}"#)
        stub.on("GET", "conferenceRecords/abc/participants", json: #"{"participants":[{"name":"conferenceRecords/abc/participants/p1","signedinUser":{"displayName":"Sam Lead"}},{"name":"conferenceRecords/abc/participants/p2","anonymousUser":{"displayName":"Jane Doe"}}]}"#)
        let connector = try GoogleWorkspaceConnector(credentials: ConnectorCredentials(), transport: stub, accessToken: token)
        let recordings = try await connector.recordings(since: date("2026-11-01T00:00:00Z"))
        XCTAssertEqual(recordings.map(\.externalID), ["conferenceRecords/abc"], "a meeting still running is skipped")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = try XCTUnwrap(recordings.first?.files.first)
        let file = try await connector.download(transcript, into: folder)
        let cues = WebVTT.cues(in: try String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(cues.map(\.speaker), ["Sam Lead", "Jane Doe"])
        XCTAssertEqual(cues.last?.start ?? 0, 9, accuracy: 0.01)
    }

    func testMicrosoftCalendarAndTeamsTranscripts() async throws {
        let stub = StubTransport()
        stub.on("GET", "/me/calendarView", json: #"{"value":[{"id":"AAMk1","subject":"Interview: Jane Doe","start":{"dateTime":"2026-11-10T19:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-11-10T20:00:00.0000000","timeZone":"UTC"},"organizer":{"emailAddress":{"name":"Me","address":"me@contoso.com"}},"attendees":[{"emailAddress":{"name":"Jane Doe","address":"jane@candidate.dev"}}],"onlineMeeting":{"joinUrl":"https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0"},"isCancelled":false}]}"#)
        stub.on("GET", "/me/onlineMeetings/M1/transcripts", json: #"{"value":[{"id":"T1"}]}"#)
        stub.on("GET", "/me/onlineMeetings/M1/recordings", json: #"{"value":[]}"#)
        stub.on("GET", "/me/onlineMeetings?", json: #"{"value":[{"id":"M1"}]}"#)
        let connector = try MicrosoftGraphConnector(credentials: ConnectorCredentials(fields: ["transcripts": "true"]),
                                                    transport: stub, accessToken: token)
        let interviews = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(interviews.first?.startsAt, date("2026-11-10T19:00:00Z"), "Graph times are UTC without a zone")
        XCTAssertEqual(MeetingLinks.platform(of: try XCTUnwrap(interviews.first?.meetingURL)), .teams)
        XCTAssertTrue((stub.requests[0].value(forHTTPHeaderField: "Prefer") ?? "").contains("outlook.timezone=\"UTC\""))

        let recordings = try await connector.recordings(since: date("2026-11-01T00:00:00Z"))
        XCTAssertEqual(recordings.first?.files.map(\.kind), [.transcript])
        XCTAssertTrue(recordings.first!.files[0].url.absoluteString.contains("transcripts/T1/content"))
        let lookup = try XCTUnwrap(stub.requests(containing: "/me/onlineMeetings?").first?.url?.absoluteString)
        XCTAssertTrue(lookup.contains("JoinWebUrl"))

        let off = try MicrosoftGraphConnector(credentials: ConnectorCredentials(), transport: stub, accessToken: token)
        let none = try await off.recordings(since: from)
        XCTAssertTrue(none.isEmpty, "transcripts stay off without admin consent")
    }

    func testZoomUpcomingAndAudioRecording() async throws {
        let stub = StubTransport()
        stub.on("GET", "/users/me/meetings", json: #"{"next_page_token":"","meetings":[{"id":97763643886,"topic":"Interview: Jane Doe","start_time":"2026-11-10T19:00:00Z","duration":60,"join_url":"https://us02web.zoom.us/j/97763643886?pwd=x"},{"id":1,"topic":"Weekly sync","start_time":"2026-11-10T19:00:00Z"}]}"#)
        stub.on("GET", "/users/me/recordings", json: #"{"meetings":[{"uuid":"BOKX==","id":6840331990,"topic":"Interview: Jane Doe","start_time":"2026-11-05T19:00:01Z","duration":58,"recording_files":[{"file_type":"MP4","file_extension":"MP4","download_url":"https://zoom.us/rec/download/v","status":"completed"},{"file_type":"M4A","file_extension":"M4A","download_url":"https://zoom.us/rec/download/a","status":"completed"},{"file_type":"TRANSCRIPT","file_extension":"VTT","download_url":"https://zoom.us/rec/download/t","status":"completed"},{"file_type":"CHAT","download_url":"https://zoom.us/rec/download/c"}]}]}"#)
        let connector = try ZoomMeetingsConnector(credentials: ConnectorCredentials(), transport: stub, accessToken: token)
        let upcoming = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(upcoming.map(\.title), ["Interview: Jane Doe"])
        XCTAssertEqual(upcoming[0].endsAt, date("2026-11-10T20:00:00Z"))
        let recordings = try await connector.recordings(since: date("2026-11-01T00:00:00Z"))
        XCTAssertEqual(recordings.first?.files.map(\.kind), [.video, .audio, .transcript])
        XCTAssertEqual(recordings.first?.bestMediaFile?.url.absoluteString, "https://zoom.us/rec/download/a")
        XCTAssertEqual(recordings.first?.duration, 58 * 60)
    }

    func testPublicClientTokenCallsSendNoSecret() async throws {
        let stub = StubTransport()
        stub.on("POST", "zoom.us/oauth/token", json: #"{"access_token":"z","refresh_token":"r","expires_in":3600}"#)
        let client = OAuthClient(provider: ZoomConnectorProvider.provider, clientID: "public-id", transport: stub)
        _ = try await client.exchange(code: "c", verifier: "v", redirectURI: URL(string: "http://127.0.0.1:5000/callback")!)
        XCTAssertNil(stub.requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(String(decoding: stub.requests[0].httpBody!, as: UTF8.self).contains("client_id=public-id"))

        let microsoft = StubTransport()
        microsoft.on("POST", "oauth2/v2.0/token", json: #"{"access_token":"m","expires_in":3600}"#)
        let graph = OAuthClient(provider: MicrosoftConnectorProvider.provider(transcripts: true), clientID: "app", transport: microsoft)
        _ = try await graph.exchange(code: "c", verifier: "v", redirectURI: URL(string: "http://localhost:5000/callback")!)
        let body = String(decoding: microsoft.requests[0].httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("OnlineMeetingTranscript.Read.All"), "Microsoft gets the scopes on the token call")
    }
}
