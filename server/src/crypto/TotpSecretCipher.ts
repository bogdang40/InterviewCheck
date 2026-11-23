import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import type { TotpKeyRing } from "./TotpKeyRing.js";

/** Raised for any seed that cannot be opened; carries no key or ciphertext material. */
export class TotpDecryptionError extends Error {
  constructor(readonly reason: "unsupported_format" | "malformed" | "unknown_key" | "authentication_failed") {
    super(`TOTP seed could not be decrypted (${reason}).`);
    this.name = "TotpDecryptionError";
  }
}

export interface OpenedTotpSecret {
  readonly secret: string;
  /** False when the seed was written with a retired or legacy key and should be re-encrypted. */
  readonly isCurrent: boolean;
}

/**
 * AES-256-GCM with the user id as associated data, so a seed copied to
 * another account fails to open.
 *
 * Formats:
 *   v1:<iv>:<tag>:<body>        legacy derivation (no key id)
 *   v2:<kid>:<iv>:<tag>:<body>  key ring key named by kid
 */
export class TotpSecretCipher {
  constructor(private readonly keys: TotpKeyRing) {}

  encrypt(secret: string, userId: string): string {
    const current = this.keys.current();
    const key = current?.key ?? this.keys.legacyKey();
    const iv = randomBytes(12);
    const cipher = createCipheriv("aes-256-gcm", key, iv).setAAD(Buffer.from(userId, "utf8"));
    const body = Buffer.concat([cipher.update(secret, "utf8"), cipher.final()]);
    const sealed = `${iv.toString("base64url")}:${cipher.getAuthTag().toString("base64url")}:${body.toString("base64url")}`;
    return current ? `v2:${current.kid}:${sealed}` : `v1:${sealed}`;
  }

  decrypt(secretEnc: string, userId: string): OpenedTotpSecret {
    const parts = secretEnc.split(":");
    if (parts[0] === "v2" && parts.length === 5) {
      const key = this.keys.keyFor(parts[1]!);
      if (!key) throw new TotpDecryptionError("unknown_key");
      return { secret: TotpSecretCipher.open(key, parts.slice(2), userId), isCurrent: parts[1] === this.keys.current()?.kid };
    }
    if (parts[0] === "v1" && parts.length === 4) {
      return { secret: TotpSecretCipher.open(this.keys.legacyKey(), parts.slice(1), userId), isCurrent: !this.keys.hasDedicatedKey };
    }
    throw new TotpDecryptionError("unsupported_format");
  }

  isCurrent(secretEnc: string): boolean {
    const current = this.keys.current();
    if (!current) return secretEnc.startsWith("v1:");
    return secretEnc.startsWith(`v2:${current.kid}:`);
  }

  private static open(key: Buffer, sealed: readonly string[], userId: string): string {
    const [iv, tag, body] = sealed.map((part) => Buffer.from(part, "base64url")) as [Buffer, Buffer, Buffer];
    if (iv.length !== 12 || tag.length !== 16 || body.length === 0) throw new TotpDecryptionError("malformed");
    try {
      const decipher = createDecipheriv("aes-256-gcm", key, iv).setAAD(Buffer.from(userId, "utf8")).setAuthTag(tag);
      return Buffer.concat([decipher.update(body), decipher.final()]).toString("utf8");
    } catch {
      throw new TotpDecryptionError("authentication_failed");
    }
  }
}
