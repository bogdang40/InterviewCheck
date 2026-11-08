import { createHash, randomBytes } from "node:crypto";

/**
 * Opaque bearer tokens. The raw token goes to the client once; only its
 * SHA-256 digest is stored, so a database leak does not leak sessions.
 */
export class TokenService {
  static readonly PREFIX = "mm_";

  generate(): string {
    return TokenService.PREFIX + randomBytes(32).toString("base64url");
  }

  hash(token: string): string {
    return createHash("sha256").update(token, "utf8").digest("hex");
  }

  looksValid(token: string): boolean {
    return token.startsWith(TokenService.PREFIX) && token.length >= 40 && token.length <= 128;
  }
}
