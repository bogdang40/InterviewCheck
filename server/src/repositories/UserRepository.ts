import { randomUUID } from "node:crypto";
import { Database, dateFromSql, sqlBool, sqlDate } from "../db/Database.js";
import type { User, UserRole } from "../domain/User.js";

interface UserRow {
  id: string;
  email: string;
  password_hash: string;
  role: UserRole;
  disabled: number;
  trial_ends_at: number | null;
  complimentary_until: number | null;
  stripe_customer_id: string | null;
  created_at: number;
  updated_at: number;
  last_login_at: number | null;
}

export interface CreateUserInput {
  email: string;
  passwordHash: string;
  role: UserRole;
  trialEndsAt: Date | null;
}

export interface UserPatch {
  role?: UserRole | undefined;
  disabled?: boolean | undefined;
  complimentaryUntil?: Date | null | undefined;
  stripeCustomerId?: string | null;
  lastLoginAt?: Date;
  passwordHash?: string | undefined;
}

export interface UserPage {
  users: User[];
  nextCursor: string | null;
}

const COLUMNS =
  "id, email, password_hash, role, disabled, trial_ends_at, complimentary_until, stripe_customer_id, created_at, updated_at, last_login_at";

export class UserRepository {
  constructor(private readonly db: Database) {}

  create(input: CreateUserInput, now: Date = new Date()): User {
    const id = randomUUID();
    this.db.run(
      `INSERT INTO users (${COLUMNS}) VALUES (?, ?, ?, ?, 0, ?, NULL, NULL, ?, ?, NULL)`,
      id,
      input.email,
      input.passwordHash,
      input.role,
      sqlDate(input.trialEndsAt),
      now.getTime(),
      now.getTime(),
    );
    return this.requireById(id);
  }

  findById(id: string): User | null {
    const row = this.db.get<UserRow>(`SELECT ${COLUMNS} FROM users WHERE id = ?`, id);
    return row ? UserRepository.toUser(row) : null;
  }

  requireById(id: string): User {
    const user = this.findById(id);
    if (!user) throw new Error(`User ${id} not found`);
    return user;
  }

  findByEmail(email: string): User | null {
    const row = this.db.get<UserRow>(`SELECT ${COLUMNS} FROM users WHERE email = ?`, email);
    return row ? UserRepository.toUser(row) : null;
  }

  findByStripeCustomerId(customerId: string): User | null {
    const row = this.db.get<UserRow>(`SELECT ${COLUMNS} FROM users WHERE stripe_customer_id = ?`, customerId);
    return row ? UserRepository.toUser(row) : null;
  }

  bindStripeCustomer(id: string, customerId: string, now: Date): string {
    this.db.run("UPDATE users SET stripe_customer_id = ?, updated_at = ? WHERE id = ? AND stripe_customer_id IS NULL", customerId, now.getTime(), id);
    return this.requireById(id).stripeCustomerId ?? customerId;
  }

  /** Password hashes are only ever read here, never through the User type. */
  passwordHash(userId: string): string | null {
    const row = this.db.get<{ password_hash: string }>("SELECT password_hash FROM users WHERE id = ?", userId);
    return row?.password_hash ?? null;
  }

  update(id: string, patch: UserPatch, now: Date = new Date()): User {
    const assignments: string[] = ["updated_at = ?"];
    const params: Array<string | number | null> = [now.getTime()];
    if (patch.role !== undefined) {
      assignments.push("role = ?");
      params.push(patch.role);
    }
    if (patch.disabled !== undefined) {
      assignments.push("disabled = ?");
      params.push(sqlBool(patch.disabled));
    }
    if (patch.complimentaryUntil !== undefined) {
      assignments.push("complimentary_until = ?");
      params.push(sqlDate(patch.complimentaryUntil));
    }
    if (patch.stripeCustomerId !== undefined) {
      assignments.push("stripe_customer_id = ?");
      params.push(patch.stripeCustomerId);
    }
    if (patch.lastLoginAt !== undefined) {
      assignments.push("last_login_at = ?");
      params.push(patch.lastLoginAt.getTime());
    }
    if (patch.passwordHash !== undefined) {
      assignments.push("password_hash = ?");
      params.push(patch.passwordHash);
    }
    params.push(id);
    this.db.run(`UPDATE users SET ${assignments.join(", ")} WHERE id = ?`, ...params);
    return this.requireById(id);
  }

  countByRole(role: UserRole): number {
    const row = this.db.get<{ n: number }>("SELECT COUNT(*) AS n FROM users WHERE role = ? AND disabled = 0", role);
    return Number(row?.n ?? 0);
  }

  count(): number {
    const row = this.db.get<{ n: number }>("SELECT COUNT(*) AS n FROM users");
    return Number(row?.n ?? 0);
  }

  /** Keyset pagination ordered by newest first; cursor is the last created_at|id pair. */
  list(options: { query?: string | undefined; limit: number; cursor?: string | undefined }): UserPage {
    const limit = Math.max(1, Math.min(options.limit, 200));
    const clauses: string[] = [];
    const params: Array<string | number> = [];
    if (options.query) {
      const escaped = options.query.trim().toLowerCase().replace(/[\\%_]/g, (character) => `\\${character}`);
      clauses.push("email LIKE ? ESCAPE '\\'");
      params.push(`%${escaped}%`);
    }
    const cursor = UserRepository.decodeCursor(options.cursor);
    if (cursor) {
      clauses.push("(created_at < ? OR (created_at = ? AND id < ?))");
      params.push(cursor.createdAt, cursor.createdAt, cursor.id);
    }
    const where = clauses.length ? `WHERE ${clauses.join(" AND ")}` : "";
    const rows = this.db.all<UserRow>(
      `SELECT ${COLUMNS} FROM users ${where} ORDER BY created_at DESC, id DESC LIMIT ?`,
      ...params,
      limit + 1,
    );
    const page = rows.slice(0, limit).map(UserRepository.toUser);
    const last = rows.length > limit ? page[page.length - 1] : undefined;
    return {
      users: page,
      nextCursor: last ? UserRepository.encodeCursor(last) : null,
    };
  }

  private static encodeCursor(user: User): string {
    return Buffer.from(`${user.createdAt.getTime()}|${user.id}`, "utf8").toString("base64url");
  }

  private static decodeCursor(cursor: string | undefined): { createdAt: number; id: string } | null {
    if (!cursor) return null;
    const [createdAt, id] = Buffer.from(cursor, "base64url").toString("utf8").split("|");
    if (!createdAt || !id || Number.isNaN(Number(createdAt))) return null;
    return { createdAt: Number(createdAt), id };
  }

  private static toUser(row: UserRow): User {
    return {
      id: row.id,
      email: row.email,
      role: row.role,
      disabled: row.disabled === 1,
      trialEndsAt: dateFromSql(row.trial_ends_at),
      complimentaryUntil: dateFromSql(row.complimentary_until),
      stripeCustomerId: row.stripe_customer_id,
      createdAt: new Date(Number(row.created_at)),
      updatedAt: new Date(Number(row.updated_at)),
      lastLoginAt: dateFromSql(row.last_login_at),
    };
  }
}
