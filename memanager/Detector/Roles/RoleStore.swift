import Combine
import Foundation

/// The detector's per-role data: the pasted job description, the cheater
/// prompts, and the planned questions. Each role is a Workspace; this store
/// keeps what the Workspace folder does not.
@MainActor
final class RoleStore: ObservableObject {
    static let shared = RoleStore()

    /// Bumped on every save so screens showing a role redraw.
    @Published private(set) var revision = 0
    /// Loaded lazily and silently, so reading a role from a view body never
    /// publishes a change mid-draw.
    private var cache: [UUID: RoleProfile] = [:]
    private let database: SessionDatabase

    init(database: SessionDatabase = .shared) {
        self.database = database
    }

    func profile(for workspaceID: UUID) -> RoleProfile {
        if let cached = cache[workspaceID] { return cached }
        let loaded = database.loadRoleProfile(workspaceID: workspaceID.uuidString)
            ?? RoleProfile(workspaceID: workspaceID.uuidString)
        cache[workspaceID] = loaded
        return loaded
    }

    /// Saves the profile and mirrors the job description into the role's
    /// folder ("Job Description/job-description.md"), so it sits beside the
    /// interviewer's other files.
    func save(_ profile: RoleProfile, workspace: JobWorkspace?) {
        var updated = profile
        updated.updatedAt = Date()
        if let id = UUID(uuidString: profile.workspaceID) { cache[id] = updated }
        revision += 1
        database.saveRoleProfile(updated)
        if let workspace { writeJobDescription(updated.jobDescription, into: workspace) }
    }

    private func writeJobDescription(_ text: String, into workspace: JobWorkspace) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let folder = workspace.folderURL.appendingPathComponent("Job Description", isDirectory: true)
        let file = folder.appendingPathComponent("job-description.md")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try (trimmed + "\n").write(to: file, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[RoleStore] Could not write job description: \(error.localizedDescription)")
        }
    }
}
