import { TotpDecryptionError, type TotpSecretCipher } from "../crypto/TotpSecretCipher.js";
import type { TotpKeyRing } from "../crypto/TotpKeyRing.js";
import type { TotpRepository } from "../repositories/TotpRepository.js";

export interface TotpMigrationResult {
  readonly reencrypted: number;
  readonly unreadable: number;
}

/**
 * Re-encrypts every seed that is not under the primary key, so that once a
 * dedicated key is configured the legacy secrets can be rotated without
 * waiting for each user to sign in. Seeds that cannot be opened are left as
 * they are; those users sign in with a backup code or get an admin reset.
 */
export class TotpSecretMigrator {
  constructor(
    private readonly keys: TotpKeyRing,
    private readonly cipher: TotpSecretCipher,
    private readonly totp: TotpRepository,
  ) {}

  run(): TotpMigrationResult {
    if (!this.keys.hasDedicatedKey) return { reencrypted: 0, unreadable: 0 };
    let reencrypted = 0;
    let unreadable = 0;
    for (const row of this.totp.listSecrets()) {
      if (this.cipher.isCurrent(row.secretEnc)) continue;
      try {
        const opened = this.cipher.decrypt(row.secretEnc, row.userId);
        if (this.totp.replaceSecret(row.userId, row.secretEnc, this.cipher.encrypt(opened.secret, row.userId))) reencrypted += 1;
      } catch (error) {
        if (!(error instanceof TotpDecryptionError)) throw error;
        unreadable += 1;
      }
    }
    return { reencrypted, unreadable };
  }
}
