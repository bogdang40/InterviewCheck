import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

const BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/** RFC 6238 TOTP (HMAC-SHA1, 6 digits, 30 second steps) and the Base32 encoding authenticator apps use. */
export class TotpAlgorithm {
  static randomSecret(): string {
    return TotpAlgorithm.encodeBase32(randomBytes(20));
  }

  static generateCode(secretBase32: string, nowMs: number, stepOffset = 0): string {
    const key = TotpAlgorithm.decodeBase32(secretBase32);
    const step = Math.floor(nowMs / 1000 / 30) + stepOffset;
    if (!Number.isSafeInteger(step) || step < 0) throw new RangeError("TOTP step must be a non-negative integer.");
    const msg = Buffer.alloc(8);
    msg.writeBigUInt64BE(BigInt(step));
    const digest = createHmac("sha1", key).update(msg).digest();
    const o = digest[digest.length - 1]! & 0x0f;
    const bin = ((digest[o]! & 0x7f) << 24) | ((digest[o + 1]! & 0xff) << 16) | ((digest[o + 2]! & 0xff) << 8) | (digest[o + 3]! & 0xff);
    return String(bin % 1_000_000).padStart(6, "0");
  }

  /** Accepts the previous, current and next step; returns the matched step or null. */
  static matchStep(secretBase32: string, rawCode: string, nowMs: number): number | null {
    const candidate = rawCode.trim();
    if (!/^\d{6}$/.test(candidate) || !Number.isFinite(nowMs)) return null;
    const baseStep = Math.floor(nowMs / 1000 / 30);
    const candidateBuf = Buffer.from(candidate, "utf8");
    let matchedStep: number | null = null;
    for (const offset of [-1, 0, 1]) {
      const step = baseStep + offset;
      if (step < 0) continue;
      if (timingSafeEqual(candidateBuf, Buffer.from(TotpAlgorithm.generateCode(secretBase32, nowMs, offset), "utf8"))) {
        matchedStep = step;
      }
    }
    return matchedStep;
  }

  static encodeBase32(bytes: Buffer): string {
    let bits = 0, value = 0, out = "";
    for (const byte of bytes) {
      value = (value << 8) | byte;
      bits += 8;
      while (bits >= 5) { out += BASE32[(value >>> (bits - 5)) & 31]!; bits -= 5; }
    }
    return bits > 0 ? out + BASE32[(value << (5 - bits)) & 31]! : out;
  }

  static decodeBase32(encoded: string): Buffer {
    let bits = 0, value = 0;
    const out: number[] = [];
    for (const ch of encoded.trim().replace(/=+$/, "").toUpperCase()) {
      const idx = BASE32.indexOf(ch);
      if (idx === -1) throw new Error("Invalid Base32 secret.");
      value = (value << 5) | idx;
      bits += 5;
      if (bits >= 8) { out.push((value >>> (bits - 8)) & 0xff); bits -= 8; }
    }
    return Buffer.from(out);
  }
}
