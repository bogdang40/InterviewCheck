import type { AppConfig } from "../config/AppConfig.js";
import { KeyMaterial } from "./KeyMaterial.js";
import { LegacyTotpKey } from "./LegacyTotpKey.js";

export interface TotpKey {
  readonly kid: string;
  readonly key: Buffer;
}

export type TotpKeyRingConfig = Pick<
  AppConfig,
  | "TOTP_ENCRYPTION_KEY"
  | "TOTP_ENCRYPTION_KEY_ID"
  | "TOTP_ENCRYPTION_RETIRED_KEYS"
  | "ADMIN_BOOTSTRAP_SECRET"
  | "STRIPE_SECRET_KEY"
  | "STRIPE_WEBHOOK_SECRET"
  | "DATABASE_PATH"
>;

/**
 * Chooses which key encrypts new TOTP seeds and which keys may decrypt old
 * ones. The primary key writes; retired keys and the legacy derivation only
 * read, so rotation is: add the new key as primary, move the old one to the
 * retired list, and let verifications re-encrypt.
 */
export class TotpKeyRing {
  constructor(
    private readonly primary: TotpKey | null,
    private readonly retired: ReadonlyMap<string, Buffer>,
    private readonly legacy: LegacyTotpKey,
  ) {
    if (primary && primary.key.length !== KeyMaterial.KEY_BYTES) throw new Error("TOTP encryption key must be 32 bytes.");
  }

  static fromConfig(config: TotpKeyRingConfig): TotpKeyRing {
    const legacy = new LegacyTotpKey(config);
    const primaryKey = config.TOTP_ENCRYPTION_KEY ? KeyMaterial.decode32(config.TOTP_ENCRYPTION_KEY) : null;
    if (config.TOTP_ENCRYPTION_KEY && !primaryKey) throw new Error("TOTP_ENCRYPTION_KEY must be 32 bytes of base64.");
    const retired = config.TOTP_ENCRYPTION_RETIRED_KEYS ?? new Map<string, Buffer>();
    const primary = primaryKey ? { kid: config.TOTP_ENCRYPTION_KEY_ID, key: primaryKey } : null;
    return new TotpKeyRing(primary, retired, legacy);
  }

  /** False means new seeds still use the legacy derivation (pre key ring behaviour). */
  get hasDedicatedKey(): boolean {
    return this.primary !== null;
  }

  current(): TotpKey | null {
    return this.primary;
  }

  keyFor(kid: string): Buffer | null {
    if (this.primary?.kid === kid) return this.primary.key;
    return this.retired.get(kid) ?? null;
  }

  legacyKey(): Buffer {
    return this.legacy.key();
  }
}
