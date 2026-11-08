import Foundation

/// Reads interviews out of JSON whose exact shape is not known in advance
/// (MCP tool results change without notice): any object with a start time
/// and a candidate or title counts, wherever it sits.
public enum InterviewJSONMapper {
    static let startKeys = ["starts_at", "startsAt", "start_time", "startTime", "start_at", "startAt", "starting_at",
                            "start", "start_datetime", "Start_DateTime", "scheduled_at", "date"]
    static let endKeys = ["ends_at", "endsAt", "end_time", "endTime", "end_at", "endAt", "ending_at", "end", "End_DateTime"]
    static let linkKeys = ["meeting_url", "meetingUrl", "meetingLink", "meeting_link", "video_url", "videoUrl",
                           "video_conferencing_url", "join_url", "joinUrl", "conference.url", "location"]
    static let titleKeys = ["title", "name", "subject", "summary", "interview.title", "interview_name"]

    public static func interviews(in json: JSONValue, source: ConnectorKind) -> [ExternalInterview] {
        var found: [ExternalInterview] = []
        walk(json, depth: 0) { object in
            guard let interview = interview(from: object, source: source) else { return false }
            found.append(interview)
            return true
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }
    }

    /// Visits objects depth-first; stops descending when `visit` takes one.
    static func walk(_ json: JSONValue, depth: Int, _ visit: (JSONValue) -> Bool) {
        guard depth < 8 else { return }
        switch json {
        case .array(let items): items.forEach { walk($0, depth: depth + 1, visit) }
        case .object(let fields):
            if visit(json) { return }
            fields.values.forEach { walk($0, depth: depth + 1, visit) }
        default: break
        }
    }

    static func first(_ object: JSONValue, _ keys: [String]) -> JSONValue? {
        keys.lazy.map { object.at($0) }.first { !$0.isNull }
    }

    static func interview(from object: JSONValue, source: ConnectorKind) -> ExternalInterview? {
        guard let start = first(object, startKeys), let startsAt = start.date ?? start["dateTime"].date ?? start["date_time"].date
        else { return nil }
        let candidateName = first(object, ["candidate.name", "candidateName", "candidate_name", "Candidate_Name.name",
                                           "application.candidate.name"])?.string
            ?? [object.at("candidate.firstName").string, object.at("candidate.lastName").string].compactMap { $0 }
                .joined(separator: " ").nilIfEmpty
        let title = first(object, titleKeys)?.string
        guard candidateName != nil || title != nil else { return nil }
        let id = first(object, ["id", "uuid", "interview_id", "interviewId", "event_id"])?.string
            ?? "\(Int(startsAt.timeIntervalSince1970))-\(candidateName ?? title ?? "")"
        let linkText = linkKeys.compactMap { object.at($0).string }
        let jobTitle = first(object, ["job.title", "job.name", "jobTitle", "job_title", "Job_Opening_Name.name", "posting.title"])?.string
        let jobID = first(object, ["job.id", "jobId", "job_id", "job.shortcode", "Job_Opening_Name.id"])?.string
        let end = first(object, endKeys)
        return ExternalInterview(
            source: source, externalID: id, title: title ?? "Interview", startsAt: startsAt,
            endsAt: end?.date ?? end?["dateTime"].date,
            meetingURL: MeetingLinks.first(in: linkText) ?? linkText.compactMap { URL(string: $0) }.first(where: { $0.scheme == "https" }),
            candidate: candidateName.map {
                ExternalCandidate(externalID: first(object, ["candidate.id", "candidateId", "candidate_id"])?.string, name: $0,
                                  email: first(object, ["candidate.email", "candidateEmail", "candidate.primaryEmailAddress.value"])?.string)
            },
            job: (jobID ?? jobTitle).map { _ in ExternalJob(externalID: jobID ?? "", title: jobTitle ?? "Job") },
            applicationID: first(object, ["application.id", "applicationId", "application_id"])?.string
        )
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
