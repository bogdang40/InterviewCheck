import { createHash, randomBytes } from "node:crypto";
import { MILLISECONDS_PER_DAY } from "../config/AppConfig.js";
import type { Database } from "../db/Database.js";
import type { AuthSession } from "../domain/Session.js";
import type { User } from "../domain/User.js";
import { HttpError } from "../http/HttpError.js";
import { ClientAddressResolver, type FixedWindowRateLimiter } from "../http/middleware/RateLimit.js";
import { API_TOKEN_SCOPES, type ApiTokenRecord, type ApiTokenRepository, type ApiTokenScope } from "../repositories/ApiTokenRepository.js";
import type { AuditLogRepository } from "../repositories/AuditLogRepository.js";
import type { SessionRepository } from "../repositories/SessionRepository.js";
import type { UserRepository } from "../repositories/UserRepository.js";

export type LimiterName = "credential" | "adminRead" | "adminWrite" | "billing";

export interface SessionView {
  readonly id: string;
  readonly deviceName: string | null;
  readonly createdAt: string;
  readonly expiresAt: string;
  readonly lastSeenAt: string;
  readonly isCurrent: boolean;
}

export type AdminSessionView = Omit<SessionView, "isCurrent">;

export interface ApiTokenView {
  readonly id: string;
  readonly name: string;
  readonly tokenPrefix: string;
  readonly scopes: readonly ApiTokenScope[];
  readonly createdAt: string;
  readonly expiresAt: string | null;
  readonly lastUsedAt: string | null;
}

export interface CreatedApiTokenView {
  readonly token: string;
  readonly apiToken: ApiTokenView;
}

export interface RateLimitEntryView {
  readonly source: "memory" | "login_windows" | "login_email_windows";
  readonly limiter: string;
  readonly keyHash: string;
  readonly maskedKey: string;
  readonly count: number;
  readonly max: number;
  readonly remaining: number;
  readonly resetAt: string;
  readonly resetInSeconds: number;
}

export interface RateLimitClearFilter {
  readonly limiter?: LimiterName | undefined;
  readonly keyHash?: string | undefined;
  readonly key?: string | undefined;
}

const VALID_SCOPE_SET = new Set<string>(API_TOKEN_SCOPES);
const LOGIN_IP_WINDOW_MS = 60_000;
const LOGIN_EMAIL_WINDOW_MS = 15 * 60_000;
const LOGIN_WINDOW_MAX = 10;

export class SecurityService {
  constructor(
    private readonly database: Database,
    private readonly users: UserRepository,
    private readonly sessions: SessionRepository,
    private readonly apiTokens: ApiTokenRepository,
    private readonly audit: AuditLogRepository,
    private readonly limiters: Readonly<Record<LimiterName, FixedWindowRateLimiter>>,
    private readonly clock: () => Date = () => new Date(),
  ) {}

  listSessions(user: User, currentSession: AuthSession): { sessions: SessionView[] } {
    const rows = this.sessions.listActiveForUser(user.id, this.clock());
    return {
      sessions: rows.map((session) => ({ ...SecurityService.toSessionView(session), isCurrent: session.id === currentSession.id })),
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

  listApiTokens(user: User): { tokens: ApiTokenView[] } {
    return { tokens: this.apiTokens.listActiveForUser(user.id).map(SecurityService.toTokenView) };
  }

  createApiToken(user: User, input: { name: string; scopes: readonly ApiTokenScope[]; ttlDays?: number | null | undefined }): CreatedApiTokenView {
    const scopes = [...new Set(input.scopes)];
    if (scopes.length === 0 || scopes.some((scope) => !VALID_SCOPE_SET.has(scope))) {
      throw new HttpError(400, "validation_failed", "Provide at least one valid token scope.");
    }
    if (scopes.includes("admin:models") && user.role !== "admin") {
      throw new HttpError(403, "forbidden", "Admin role is required for the admin:models scope.");
    }
    const now = this.clock();
    const expiresAt = input.ttlDays != null ? new Date(now.getTime() + input.ttlDays * MILLISECONDS_PER_DAY) : null;
    const rawToken = `ic_tok_${randomBytes(32).toString("base64url")}`;
    const tokenPrefix = rawToken.slice(0, 14);
    const tokenHash = SecurityService.hashKey(rawToken);

    return this.database.transaction(() => {
      const currentUser = this.users.findById(user.id);
      if (!currentUser || currentUser.disabled) throw new HttpError(403, "account_disabled", "This account has been disabled.");
      if (scopes.includes("admin:models") && currentUser.role !== "admin") {
        throw new HttpError(403, "forbidden", "Admin role is required for the admin:models scope.");
      }
      const created = this.apiTokens.create({ userId: currentUser.id, name: input.name, tokenPrefix, tokenHash, scopes, expiresAt }, now);
      this.audit.record(
        {
          actorUserId: currentUser.id,
          action: "auth.token_create",
          targetUserId: currentUser.id,
          details: { tokenId: created.id, name: created.name, scopes: created.scopes, expiresAt: created.expiresAt?.toISOString() ?? null },
        },
        now,
      );
      return { token: rawToken, apiToken: SecurityService.toTokenView(created) };
    });
  }

  revokeApiToken(user: User, tokenId: string): { revoked: true; id: string } {
    const now = this.clock();
    return this.database.transaction(() => {
      if (!this.apiTokens.revokeOwned(tokenId, user.id, now)) {
        throw new HttpError(404, "token_not_found", "API token not found.");
      }
      this.audit.record({ actorUserId: user.id, action: "auth.token_revoke", targetUserId: user.id, details: { tokenId } }, now);
      return { revoked: true, id: tokenId };
    });
  }

  verifyApiToken(rawToken: string, requiredScope?: ApiTokenScope): { user: User; apiToken: ApiTokenRecord } | null {
    if (!rawToken.startsWith("ic_tok_") || rawToken.length < 40 || rawToken.length > 160) return null;
    const record = this.apiTokens.findByTokenHash(SecurityService.hashKey(rawToken));
    const now = this.clock();
    if (!record || record.revokedAt !== null) return null;
    if (record.expiresAt !== null && record.expiresAt <= now) return null;
    const user = this.users.findById(record.userId);
    if (!user || user.disabled) return null;
    if (record.scopes.includes("admin:models") && user.role !== "admin") return null;
    if (requiredScope && !record.scopes.includes(requiredScope)) return null;
    this.apiTokens.touchLastUsed(record.id, now);
    return { user, apiToken: record };
  }

  listUserSessions(targetUserId: string): { userId: string; sessions: AdminSessionView[] } {
    const target = this.users.findById(targetUserId);
    if (!target) throw new HttpError(404, "user_not_found", "No user with that id.");
    return {
      userId: target.id,
      sessions: this.sessions.listActiveForUser(target.id, this.clock()).map(SecurityService.toSessionView),
    };
  }

  revokeUserSessions(actor: User, targetUserId: string, sessionId?: string): { userId: string; revokedCount: number } {
    const now = this.clock();
    return this.database.transaction(() => {
      const currentActor = this.requireActiveAdmin(actor.id);
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

  listRateLimits(): { entries: RateLimitEntryView[]; total: number } {
    const entries: RateLimitEntryView[] = [];
    for (const [name, limiter] of Object.entries(this.limiters) as Array<[LimiterName, FixedWindowRateLimiter]>) {
      for (const bucket of limiter.snapshot()) {
        entries.push({
          source: "memory",
          limiter: name,
          keyHash: SecurityService.hashKey(bucket.key),
          maskedKey: SecurityService.maskKey(bucket.key),
          count: bucket.count,
          max: bucket.max,
          remaining: bucket.remaining,
          resetAt: new Date(bucket.resetAt).toISOString(),
          resetInSeconds: bucket.resetInSeconds,
        });
      }
    }
    const nowMs = this.clock().getTime();
    this.collectDbWindows("login_windows", "address", LOGIN_IP_WINDOW_MS, nowMs, entries);
    this.collectDbWindows("login_email_windows", "email", LOGIN_EMAIL_WINDOW_MS, nowMs, entries);
    return { entries, total: entries.length };
  }

  clearRateLimits(actor: User, filter: RateLimitClearFilter = {}): { cleared: number } {
    const now = this.clock();
    return this.database.transaction(() => {
      const currentActor = this.requireActiveAdmin(actor.id);
      const targetLimiters = filter.limiter
        ? ([[filter.limiter, this.limiters[filter.limiter]]] as Array<[LimiterName, FixedWindowRateLimiter]>)
        : (Object.entries(this.limiters) as Array<[LimiterName, FixedWindowRateLimiter]>);
      const normalizedKey = filter.key ? ClientAddressResolver.normalizeAddress(filter.key) : undefined;
      const targetHash = filter.keyHash?.toLowerCase();
      let cleared = 0;

      for (const [, limiter] of targetLimiters) {
        if (targetHash || filter.key !== undefined) {
          for (const bucket of limiter.snapshot()) {
            const hashMatches = targetHash ? SecurityService.hashKey(bucket.key) === targetHash : false;
            const keyMatches = filter.key !== undefined && (bucket.key === filter.key || bucket.key === normalizedKey);
            if (hashMatches || keyMatches) cleared += limiter.clear(bucket.key);
          }
        } else {
          cleared += limiter.clear();
        }
      }

      if (!filter.limiter || filter.limiter === "credential") {
        cleared += this.clearDbWindows("login_windows", "address", targetHash, filter.key, normalizedKey);
        cleared += this.clearDbWindows("login_email_windows", "email", targetHash, filter.key, normalizedKey);
      }

      this.audit.record(
        {
          actorUserId: currentActor.id,
          action: "admin.rate_limit_unlock",
          details: { limiter: filter.limiter ?? "all", keyHash: targetHash ?? (normalizedKey ? SecurityService.hashKey(normalizedKey) : null), cleared },
        },
        now,
      );
      return { cleared };
    });
  }

  private collectDbWindows(
    table: "login_windows" | "login_email_windows",
    column: "address" | "email",
    windowMs: number,
    nowMs: number,
    out: RateLimitEntryView[],
  ): void {
    const rows = this.database.all<{ k: string; start: number; hits: number }>(`SELECT ${column} AS k, start, hits FROM ${table} WHERE start > ?`, nowMs - windowMs);
    for (const row of rows) {
      const resetAtMs = Number(row.start) + windowMs;
      out.push({
        source: table,
        limiter: "credential",
        keyHash: SecurityService.hashKey(row.k),
        maskedKey: SecurityService.maskKey(row.k),
        count: Number(row.hits),
        max: LOGIN_WINDOW_MAX,
        remaining: Math.max(0, LOGIN_WINDOW_MAX - Number(row.hits)),
        resetAt: new Date(resetAtMs).toISOString(),
        resetInSeconds: Math.max(1, Math.ceil((resetAtMs - nowMs) / 1000)),
      });
    }
  }

  private clearDbWindows(table: "login_windows" | "login_email_windows", column: "address" | "email", targetHash?: string, rawKey?: string, normalizedKey?: string): number {
    if (!targetHash && rawKey === undefined) return Number(this.database.run(`DELETE FROM ${table}`).changes);
    const rows = this.database.all<{ k: string }>(`SELECT ${column} AS k FROM ${table}`);
    let count = 0;
    for (const row of rows) {
      const hashMatches = targetHash ? SecurityService.hashKey(row.k) === targetHash : false;
      const keyMatches = rawKey !== undefined && (row.k === rawKey || row.k === normalizedKey);
      if (hashMatches || keyMatches) count += Number(this.database.run(`DELETE FROM ${table} WHERE ${column} = ?`, row.k).changes);
    }
    return count;
  }

  private requireActiveAdmin(actorId: string): User {
    const currentActor = this.users.findById(actorId);
    if (!currentActor || currentActor.disabled || currentActor.role !== "admin") {
      throw new HttpError(403, "forbidden", "Admin access required.");
    }
    return currentActor;
  }

  private static toSessionView(session: AuthSession): AdminSessionView {
    return {
      id: session.id,
      deviceName: session.deviceName,
      createdAt: session.createdAt.toISOString(),
      expiresAt: session.expiresAt.toISOString(),
      lastSeenAt: session.lastSeenAt.toISOString(),
    };
  }

  private static toTokenView(record: ApiTokenRecord): ApiTokenView {
    return {
      id: record.id,
      name: record.name,
      tokenPrefix: record.tokenPrefix,
      scopes: record.scopes,
      createdAt: record.createdAt.toISOString(),
      expiresAt: record.expiresAt?.toISOString() ?? null,
      lastUsedAt: record.lastUsedAt?.toISOString() ?? null,
    };
  }

  private static hashKey(value: string): string {
    return createHash("sha256").update(value, "utf8").digest("hex");
  }

  private static maskKey(value: string): string {
    const atIndex = value.indexOf("@");
    if (atIndex > 0) return `${value.slice(0, 1)}***${value.slice(atIndex)}`;
    if (value.endsWith("/64")) {
      const prefix = value.slice(0, -3).split(":").slice(0, 2).join(":");
      return `${prefix}:*:*:*::/64`;
    }
    const octets = value.split(".");
    if (octets.length === 4) return `${octets[0]}.${octets[1]}.*.*`;
    return value.length <= 2 ? "***" : `${value.slice(0, 2)}***`;
  }
}
