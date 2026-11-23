import { createHash, randomBytes, scryptSync } from "node:crypto";
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, statSync, writeSync } from "node:fs";
import { dirname, join } from "node:path";
import type { AppConfig } from "../config/AppConfig.js";

const DERIVED_KEY_CACHE = new Map<string, Buffer>();

export type LegacyTotpKeyConfig = Pick<AppConfig, "ADMIN_BOOTSTRAP_SECRET" | "STRIPE_SECRET_KEY" | "STRIPE_WEBHOOK_SECRET" | "DATABASE_PATH">;

/**
 * The key derivation used before TOTP_ENCRYPTION_KEY existed. Kept only so
 * seeds written by older releases stay readable until they are re-encrypted.
 * Resolved lazily: a deployment with a dedicated key and no legacy rows never
 * derives it (and never creates the fallback key file).
 */
export class LegacyTotpKey {
  private cached: Buffer | null = null;

  constructor(private readonly config: LegacyTotpKeyConfig) {}

  key(): Buffer {
    this.cached ??= LegacyTotpKey.derive(this.config);
    return this.cached;
  }

  private static derive(config: LegacyTotpKeyConfig): Buffer {
    const secret = config.ADMIN_BOOTSTRAP_SECRET ?? config.STRIPE_SECRET_KEY ?? config.STRIPE_WEBHOOK_SECRET;
    if (secret) {
      const digest = createHash("sha256").update(secret, "utf8").digest("hex");
      let key = DERIVED_KEY_CACHE.get(digest);
      if (!key) {
        key = scryptSync(secret, "interviewcheck-totp-aes-256-gcm-v1", 32);
        DERIVED_KEY_CACHE.set(digest, key);
      }
      return key;
    }
    if (config.DATABASE_PATH !== ":memory:") {
      return LegacyTotpKey.loadOrCreateFileKey(join(dirname(config.DATABASE_PATH), ".totp_secret.key"));
    }
    return randomBytes(32);
  }

  private static loadOrCreateFileKey(filePath: string): Buffer {
    mkdirSync(dirname(filePath), { recursive: true, mode: 0o700 });
    if (!existsSync(filePath)) {
      const encoded = randomBytes(32).toString("base64url");
      try {
        const fd = openSync(filePath, "wx", 0o600);
        try {
          writeSync(fd, encoded);
        } finally {
          closeSync(fd);
        }
      } catch (error) {
        if ((error as { code?: string }).code !== "EEXIST") throw error;
      }
    }
    if (process.platform !== "win32" && (statSync(filePath).mode & 0o077) !== 0) {
      throw new Error("TOTP secret key file permissions are too broad; restrict to 0600.");
    }
    const key = Buffer.from(readFileSync(filePath, "utf8").trim(), "base64url");
    if (key.length !== 32) throw new Error("TOTP secret key file is invalid.");
    return key;
  }
}
