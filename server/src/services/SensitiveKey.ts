import { createHash } from "node:crypto";

/** Fingerprints and masks identifiers (addresses, emails, tokens) before they leave the server. */
export class SensitiveKey {
  static hash(value: string): string {
    return createHash("sha256").update(value, "utf8").digest("hex");
  }

  static mask(value: string): string {
    const atIndex = value.indexOf("@");
    if (atIndex > 0) return `${value.slice(0, 1)}***${value.slice(atIndex)}`;
    if (value.endsWith("/64")) {
      const prefix = value.slice(0, -3).split(":").slice(0, 2).join(":");
      return `${prefix}:*:*:*::/64`;
    }
    const octets = value.split(".");
    if (octets.length === 4) return `${octets[0]}.${octets[1]}.*.*`;
    return value.length <= 2 ? "***" : `${value.slice(0, 2)}***`;
  }
}
