import { randomBytes } from "node:crypto";
import { MILLISECONDS_PER_DAY } from "../config/AppConfig.js";
import type { Database } from "../db/Database.js";
import type { User } from "../domain/User.js";
import { HttpError } from "../http/HttpError.js";
import { API_TOKEN_SCOPES, type ApiTokenRecord, type ApiTokenRepository, type ApiTokenScope } from "../repositories/ApiTokenRepository.js";
import type { AuditLogRepository } from "../repositories/AuditLogRepository.js";
import type { UserRepository } from "../repositories/UserRepository.js";
import { SensitiveKey } from "./SensitiveKey.js";

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

const VALID_SCOPE_SET = new Set<string>(API_TOKEN_SCOPES);
export const MAX_ACTIVE_API_TOKENS_PER_USER = 25;

/**
 * Mints, lists, revokes and verifies scoped `ic_tok_` tokens. Only the
 * SHA-256 of a token is stored. No route authenticates with these tokens yet;
 * verifyApiToken is the hook for when one does.
 */
export class ApiTokenService {
  constructor(
    private readonly database: Database,
    private readonly users: UserRepository,
    private readonly apiTokens: ApiTokenRepository,
    private readonly audit: AuditLogRepository,
    private readonly clock: () => Date = () => new Date(),
  ) {}

  listApiTokens(user: User): { tokens: ApiTokenView[] } {
    return { tokens: this.apiTokens.listActiveForUser(user.id).map(ApiTokenService.toView) };
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
    const tokenHash = SensitiveKey.hash(rawToken);

    return this.database.transaction(() => {
      const currentUser = this.users.findById(user.id);
      if (!currentUser || currentUser.disabled) throw new HttpError(403, "account_disabled", "This account has been disabled.");
      if (scopes.includes("admin:models") && currentUser.role !== "admin") {
        throw new HttpError(403, "forbidden", "Admin role is required for the admin:models scope.");
      }
      if (this.apiTokens.countActiveForUser(currentUser.id, now) >= MAX_ACTIVE_API_TOKENS_PER_USER) {
        throw new HttpError(409, "token_limit_reached", `At most ${MAX_ACTIVE_API_TOKENS_PER_USER} active API tokens are allowed. Revoke one first.`);
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
      return { token: rawToken, apiToken: ApiTokenService.toView(created) };
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
    const record = this.apiTokens.findByTokenHash(SensitiveKey.hash(rawToken));
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

  private static toView(record: ApiTokenRecord): ApiTokenView {
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
}
