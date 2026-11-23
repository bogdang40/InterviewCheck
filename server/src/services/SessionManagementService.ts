import type { Database } from "../db/Database.js";
import type { AuthSession } from "../domain/Session.js";
import type { User } from "../domain/User.js";
import { HttpError } from "../http/HttpError.js";
import type { AuditLogRepository } from "../repositories/AuditLogRepository.js";
import type { SessionRepository } from "../repositories/SessionRepository.js";
import type { UserRepository } from "../repositories/UserRepository.js";
import type { AdminActorGuard } from "./AdminActorGuard.js";

export interface SessionView {
  readonly id: string;
  readonly deviceName: string | null;
  readonly createdAt: string;
  readonly expiresAt: string;
  readonly lastSeenAt: string;
  readonly isCurrent: boolean;
}

export type AdminSessionView = Omit<SessionView, "isCurrent">;

/** Lists and revokes sign in sessions, for the signed in user and for admins. */
export class SessionManagementService {
  constructor(
    private readonly database: Database,
    private readonly users: UserRepository,
    private readonly sessions: SessionRepository,
    private readonly audit: AuditLogRepository,
    private readonly adminGuard: AdminActorGuard,
    private readonly clock: () => Date = () => new Date(),
  ) {}

  listSessions(user: User, currentSession: AuthSession): { sessions: SessionView[] } {
    const rows = this.sessions.listActiveForUser(user.id, this.clock());
    return {
      sessions: rows.map((session) => ({ ...SessionManagementService.toView(session), isCurrent: session.id === currentSession.id })),
    };
  }

  revokeOwnSession(user: User, currentSession: AuthSession, sessionId: string): { revoked: true; id: string } {
    const now = this.clock();
    return this.database.transaction(() => {
      if (!this.sessions.revokeOwned(sessionId, user.id, now)) {
        throw new HttpError(404, "session_not_found", "Session not found.");
      }
      this.audit.record(
        { actorUserId: user.id, action: "auth.session_revoke", targetUserId: user.id, details: { sessionId, isCurrent: sessionId === currentSession.id } },
        now,
      );
      return { revoked: true, id: sessionId };
    });
  }

  listUserSessions(targetUserId: string): { userId: string; sessions: AdminSessionView[] } {
    const target = this.users.findById(targetUserId);
    if (!target) throw new HttpError(404, "user_not_found", "No user with that id.");
    return {
      userId: target.id,
      sessions: this.sessions.listActiveForUser(target.id, this.clock()).map(SessionManagementService.toView),
    };
  }

  revokeUserSessions(actor: User, targetUserId: string, sessionId?: string): { userId: string; revokedCount: number } {
    const now = this.clock();
    return this.database.transaction(() => {
      const currentActor = this.adminGuard.requireActiveAdmin(actor.id);
      const target = this.users.findById(targetUserId);
      if (!target) throw new HttpError(404, "user_not_found", "No user with that id.");
      let revokedCount: number;
      if (sessionId !== undefined) {
        if (!this.sessions.revokeOwned(sessionId, target.id, now)) {
          throw new HttpError(404, "session_not_found", "Session not found.");
        }
        revokedCount = 1;
      } else {
        revokedCount = this.sessions.revokeAllForUser(target.id, now);
      }
      this.audit.record(
        { actorUserId: currentActor.id, action: "admin.revoke_sessions", targetUserId: target.id, details: { sessionId: sessionId ?? null, revokedCount } },
        now,
      );
      return { userId: target.id, revokedCount };
    });
  }

  private static toView(session: AuthSession): AdminSessionView {
    return {
      id: session.id,
      deviceName: session.deviceName,
      createdAt: session.createdAt.toISOString(),
      expiresAt: session.expiresAt.toISOString(),
      lastSeenAt: session.lastSeenAt.toISOString(),
    };
  }
}
