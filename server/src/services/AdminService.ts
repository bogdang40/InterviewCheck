import type { PublicSubscription } from "../domain/Subscription.js";
import type { PublicUser, User, UserRole } from "../domain/User.js";
import type { Entitlement } from "../domain/Entitlement.js";
import { HttpError } from "../http/HttpError.js";
import type { AuditEntry, AuditLogRepository } from "../repositories/AuditLogRepository.js";
import type { SessionRepository } from "../repositories/SessionRepository.js";
import type { SubscriptionRepository } from "../repositories/SubscriptionRepository.js";
import type { UserRepository } from "../repositories/UserRepository.js";
import type { EntitlementService } from "./EntitlementService.js";

export interface AdminUserView {
  readonly user: PublicUser;
  readonly entitlement: Entitlement;
  readonly subscription: PublicSubscription | null;
  readonly lastLoginAt: string | null;
}

export interface AdminUserPatch {
  role?: UserRole | undefined;
  disabled?: boolean | undefined;
  complimentaryUntil?: Date | null | undefined;
}

export interface AdminStats {
  readonly totalUsers: number;
  readonly admins: number;
  readonly liveSubscriptions: number;
}

export class AdminService {
  constructor(
    private readonly users: UserRepository,
    private readonly sessions: SessionRepository,
    private readonly subscriptions: SubscriptionRepository,
    private readonly audit: AuditLogRepository,
    private readonly entitlements: EntitlementService,
    private readonly clock: () => Date = () => new Date(),
  ) {}

  listUsers(options: { query?: string | undefined; limit?: number | undefined; cursor?: string | undefined }): { users: AdminUserView[]; nextCursor: string | null } {
    const page = this.users.list({ query: options.query, limit: options.limit ?? 50, cursor: options.cursor });
    return { users: page.users.map((user) => this.view(user)), nextCursor: page.nextCursor };
  }

  getUser(id: string): AdminUserView {
    const user = this.users.findById(id);
    if (!user) throw new HttpError(404, "user_not_found", "No user with that id.");
    return this.view(user);
  }

  updateUser(actor: User, targetId: string, patch: AdminUserPatch): AdminUserView {
    const target = this.users.findById(targetId);
    if (!target) throw new HttpError(404, "user_not_found", "No user with that id.");
    this.guardLastAdmin(actor, target, patch);

    const now = this.clock();
    const updated = this.users.update(
      target.id,
      {
        ...(patch.role !== undefined ? { role: patch.role } : {}),
        ...(patch.disabled !== undefined ? { disabled: patch.disabled } : {}),
        ...(patch.complimentaryUntil !== undefined ? { complimentaryUntil: patch.complimentaryUntil } : {}),
      },
      now,
    );
    if (patch.disabled === true) {
      this.sessions.revokeAllForUser(target.id, now);
    }
    this.audit.record(
      {
        actorUserId: actor.id,
        action: "admin.update_user",
        targetUserId: target.id,
        details: {
          role: patch.role ?? null,
          disabled: patch.disabled ?? null,
          complimentaryUntil: patch.complimentaryUntil === undefined ? null : (patch.complimentaryUntil?.toISOString() ?? "cleared"),
        },
      },
      now,
    );
    return this.view(updated);
  }

  stats(): AdminStats {
    return {
      totalUsers: this.users.count(),
      admins: this.users.countByRole("admin"),
      liveSubscriptions: this.subscriptions.countLive(),
    };
  }

  recentAudit(limit = 100): AuditEntry[] {
    return this.audit.recent(limit);
  }

  private guardLastAdmin(actor: User, target: User, patch: AdminUserPatch): void {
    const demotes = patch.role === "user" || patch.disabled === true;
    if (!demotes || target.role !== "admin") return;
    // countByRole counts active admins only, so a disabled target is not in
    // it and demoting them cannot reduce coverage.
    const activeAdminsAfter = this.users.countByRole("admin") - (target.disabled ? 0 : 1);
    if (activeAdminsAfter < 1) {
      throw new HttpError(409, "last_admin", "Cannot remove the last active admin.");
    }
    if (actor.id === target.id && patch.disabled === true) {
      throw new HttpError(409, "self_disable", "Admins cannot disable their own account.");
    }
  }

  private view(user: User): AdminUserView {
    const snapshot = this.entitlements.snapshotFor(user);
    return {
      user: snapshot.user,
      entitlement: snapshot.entitlement,
      subscription: snapshot.subscription,
      lastLoginAt: user.lastLoginAt?.toISOString() ?? null,
    };
  }
}
