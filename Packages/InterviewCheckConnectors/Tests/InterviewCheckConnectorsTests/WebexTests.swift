import XCTest
@testable import InterviewCheckConnectors

final class WebexTests: XCTestCase {
    private func connector(_ stub: StubTransport) throws -> WebexMeetingsConnector {
        try WebexMeetingsConnector(credentials: ConnectorCredentials(fields: [:]), transport: stub, accessToken: { "wt" })
    }

    func testScheduledMeetingsWithTheOutsideInviteeAsCandidate() async throws {
        let stub = StubTransport()
        stub.on("GET", "meetingInvitees?meetingId=M1", json: #"{"items":[{"email":"jane.doe@gmail.com","displayName":"Jane Doe","coHost":false,"panelist":false},{"email":"lee@acme.com","displayName":"Lee Engineer","coHost":true}]}"#)
        stub.on("GET", "webexapis.com/v1/meetings?", json: #"""
        {"items":[
          {"id":"M1","title":"Interview: Jane Doe - Backend Engineer","start":"2026-11-10T15:00:00Z","end":"2026-11-10T16:00:00Z",
           "webLink":"https://acme.webex.com/acme/j.php?MTID=m123","hostEmail":"sam@acme.com","hostDisplayName":"Sam Recruiter","state":"active"},
          {"id":"M2","title":"Weekly sync","start":"2026-11-11T15:00:00Z","end":"2026-11-11T16:00:00Z","hostEmail":"sam@acme.com","state":"active"}]}
        """#)
        let interviews = try await connector(stub).upcomingInterviews(from: date("2026-11-07T00:00:00Z"), to: date("2026-11-21T00:00:00Z"))
        XCTAssertEqual(interviews.count, 1)
        XCTAssertEqual(interviews[0].source, .webex)
        XCTAssertEqual(interviews[0].candidate?.email, "jane.doe@gmail.com")
        XCTAssertEqual(interviews[0].job?.title, "Backend Engineer")
        XCTAssertEqual(interviews[0].meetingURL?.host, "acme.webex.com")
        XCTAssertEqual(stub.requests(containing: "meetingInvitees").count, 1, "invitees only for interviews")
        XCTAssertTrue(stub.requests(containing: "meetingType=scheduledMeeting").first != nil)
    }

    func testTranscriptAndAudioJoinOneRecording() async throws {
        let stub = StubTransport()
        stub.on("GET", "meetingTranscripts?", json: #"{"items":[{"id":"T1","meetingId":"I1","meetingTopic":"Technical interview - Jane Doe","startTime":"2026-11-06T15:00:00Z","vttDownloadLink":"https://webexapis.com/v1/meetingTranscripts/T1/download?format=vtt","status":"available"},{"id":"T2","meetingId":"I2","meetingTopic":"Team retro","startTime":"2026-11-06T17:00:00Z","status":"available"}]}"#)
        stub.on("GET", "recordings/R1", json: #"{"id":"R1","temporaryDirectDownloadLinks":{"audioDownloadLink":"https://cdn.webex.com/audio/R1.mp3?token=x","recordingDownloadLink":"https://cdn.webex.com/R1.mp4?token=x","expiration":"2026-11-08T09:00:00Z"}}"#)
        stub.on("GET", "v1/recordings?", json: #"{"items":[{"id":"R1","meetingId":"I1","topic":"Technical interview - Jane Doe","timeRecorded":"2026-11-06T15:00:05Z","durationSeconds":3300,"status":"available"}]}"#)
        stub.on("GET", "meetings/I1", json: #"{"id":"I1","webLink":"https://acme.webex.com/acme/j.php?MTID=m123"}"#)
        let recordings = try await connector(stub).recordings(since: date("2026-11-01T00:00:00Z"))
        XCTAssertEqual(recordings.count, 1, "the retro is not an interview")
        let recording = try XCTUnwrap(recordings.first)
        XCTAssertEqual(Set(recording.files.map(\.kind)), [.transcript, .audio])
        let audio = try XCTUnwrap(recording.files.first { $0.kind == .audio })
        XCTAssertEqual(audio.url.absoluteString, "https://webexapis.com/v1/recordings/R1", "the lasting address, not the hours-long link")
        XCTAssertEqual(recording.files.first { $0.kind == .transcript }?.needsAuth, true)
        XCTAssertTrue(stub.requests(containing: "recordings/R1").isEmpty, "no detail calls while listing")

        // Downloading asks for a fresh direct link and sends no Webex token to it.
        stub.on("GET", "cdn.webex.com/audio/R1.mp3", json: "ID3")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("webex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = try await connector(stub).download(audio, into: folder)
        XCTAssertEqual(saved.pathExtension, "mp3")
        XCTAssertEqual(stub.requests(containing: "recordings/R1").first?.value(forHTTPHeaderField: "Authorization"), "Bearer wt")
        XCTAssertNil(stub.requests(containing: "cdn.webex.com").first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(recording.duration, 3300)
        XCTAssertEqual(recording.meetingURL?.host, "acme.webex.com")
    }

    func testWebexTranscriptSpeakers() {
        let vtt = "WEBVTT\n\n1 \"Jane Doe\" (2392048128)\n00:00:01.000 --> 00:00:04.500\nJane Doe: I would start with a token bucket.\n\n2 \"Lee Engineer\" (1)\n00:00:05.000 --> 00:00:06.000\nLee Engineer: Why that one?\n"
        let cues = WebVTT.cues(in: vtt)
        XCTAssertEqual(cues.map(\.speaker), ["Jane Doe", "Lee Engineer"])
        XCTAssertEqual(cues.first?.text, "I would start with a token bucket.")
    }

    func testSignInUsesTheRegisteredPort() {
        XCTAssertEqual(WebexConnectorProvider.redirectPort, 53_871)
        XCTAssertTrue(ConnectorCatalog.descriptor(.webex).setup.contains("http://127.0.0.1:53871/callback"))
    }
}
