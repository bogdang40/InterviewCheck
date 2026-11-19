import { randomUUID } from "node:crypto";
import { Database, dateFromSql, sqlDate } from "../db/Database.js";

export const API_TOKEN_SCOPES = [
  "read:interviews",
  "write:interviews",
  "export:reports",
  "read:telemetry",
  "admin:models",
] as const;

export type ApiTokenScope = (typeof API_TOKEN_SCOPES)[number];

export interface ApiTokenRecord {
  readonly id: string;
  readonly userId: string;
  readonly name: string;
  readonly tokenPrefix: string;
  readonly scopes: readonly ApiTokenScope[];
  readonly createdAt: Date;
  readonly expiresAt: Date | null;
  readonly lastUsedAt: Date | null;
  readonly revokedAt: Date | null;
}

interface ApiTokenRow {
  id: string;
  user_id: string;
  name: string;
  token_prefix: string;
  scopes_json: string;
  created_at: number;
  expires_at: number | null;
  last_used_at: number | null;
  revoked_at: number | null;
}

const COLUMNS = "id, user_id, name, token_prefix, scopes_json, created_at, expires_at, last_used_at, revoked_at";
const VALID_SCOPES = new Set<string>(API_TOKEN_SCOPES);

export class ApiTokenRepository {
  constructor(private readonly db: Database) {}

  create(
    input: {
      userId: string;
      name: string;
      tokenPrefix: string;
      tokenHash: string;
      scopes: readonly ApiTokenScope[];
      expiresAt: Date | null;
    },
    now: Date = new Date(),
  ): ApiTokenRecord {
    const id = randomUUID();
    this.db.run(
      `INSERT INTO api_tokens (id, user_id, name, token_prefix, token_hash, scopes_json, created_at, expires_at, last_used_at, revoked_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)`,
      id,
      input.userId,
      input.name,
      input.tokenPrefix,
      input.tokenHash,
      JSON.stringify(input.scopes),
      now.getTime(),
      sqlDate(input.expiresAt),
    );
    const created = this.findById(id);
    if (!created) throw new Error("API token insert did not persist");
    return created;
  }

  findById(id: string): ApiTokenRecord | null {
    const row = this.db.get<ApiTokenRow>(`SELECT ${COLUMNS} FROM api_tokens WHERE id = ?`, id);
    return row ? ApiTokenRepository.toRecord(row) : null;
  }

  findByTokenHash(tokenHash: string): ApiTokenRecord | null {
    const row = this.db.get<ApiTokenRow>(`SELECT ${COLUMNS} FROM api_tokens WHERE token_hash = ?`, tokenHash);
    return row ? ApiTokenRepository.toRecord(row) : null;
  }

  listActiveForUser(userId: string): ApiTokenRecord[] {
    const rows = this.db.all<ApiTokenRow>(
      `SELECT ${COLUMNS} FROM api_tokens WHERE user_id = ? AND revoked_at IS NULL ORDER BY created_at DESC, id DESC`,
      userId,
    );
    return rows.map(ApiTokenRepository.toRecord);
  }

  touchLastUsed(id: string, now: Date = new Date()): void {
    this.db.run("UPDATE api_tokens SET last_used_at = ? WHERE id = ?", now.getTime(), id);
  }

  revokeOwned(id: string, userId: string, now: Date = new Date()): boolean {
    const result = this.db.run(
      "UPDATE api_tokens SET revoked_at = ? WHERE id = ? AND user_id = ? AND revoked_at IS NULL",
      now.getTime(),
      id,
      userId,
    );
    return Number(result.changes) > 0;
  }

  private static toRecord(row: ApiTokenRow): ApiTokenRecord {
    return {
      id: row.id,
      userId: row.user_id,
      name: row.name,
      tokenPrefix: row.token_prefix,
      scopes: ApiTokenRepository.parseScopes(row.scopes_json),
      createdAt: new Date(Number(row.created_at)),
      expiresAt: dateFromSql(row.expires_at),
      lastUsedAt: dateFromSql(row.last_used_at),
      revokedAt: dateFromSql(row.revoked_at),
    };
  }

  private static parseScopes(raw: string): ApiTokenScope[] {
    try {
      const parsed = JSON.parse(raw);
      if (!Array.isArray(parsed)) return [];
      return parsed.filter((item): item is ApiTokenScope => typeof item === "string" && VALID_SCOPES.has(item));
    } catch {
      return [];
    }
  }
}
