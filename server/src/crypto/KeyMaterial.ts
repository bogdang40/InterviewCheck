const BASE64_PATTERN = /^[A-Za-z0-9+/_-]+={0,2}$/;
const KEY_ID_PATTERN = /^[A-Za-z0-9_-]{1,32}$/;

/** Parses operator supplied symmetric key material (base64 or base64url, exactly 32 bytes). */
export class KeyMaterial {
  static readonly KEY_BYTES = 32;

  static decode32(raw: string): Buffer | null {
    const value = raw.trim();
    if (!BASE64_PATTERN.test(value)) return null;
    const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
    const key = Buffer.from(normalized, "base64");
    return key.length === KeyMaterial.KEY_BYTES ? key : null;
  }

  static isValidKeyId(kid: string): boolean {
    return KEY_ID_PATTERN.test(kid);
  }

  /** Parses `kid:base64,kid:base64`. Returns null when any entry is malformed or a kid repeats. */
  static parseKeyList(raw: string): Map<string, Buffer> | null {
    const keys = new Map<string, Buffer>();
    for (const entry of raw.split(",").map((part) => part.trim()).filter(Boolean)) {
      const separator = entry.indexOf(":");
      if (separator <= 0) return null;
      const kid = entry.slice(0, separator);
      const key = KeyMaterial.decode32(entry.slice(separator + 1));
      if (!KeyMaterial.isValidKeyId(kid) || !key || keys.has(kid)) return null;
      keys.set(kid, key);
    }
    return keys;
  }
}
