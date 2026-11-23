import { isIP } from "node:net";
import type { Context } from "hono";
import { getConnInfo } from "@hono/node-server/conninfo";

export const TRUSTED_PROXY_HEADERS = ["fly-client-ip", "x-forwarded-for"] as const;
export type TrustedProxyHeader = (typeof TRUSTED_PROXY_HEADERS)[number];

/**
 * Picks the address to rate limit on. Only the one header the configured
 * proxy sets is read (TRUSTED_PROXY_HEADER), and only when TRUST_PROXY is on.
 * Any other forwarded header is client supplied and ignored: behind nginx a
 * client can send its own Fly-Client-IP, and behind Fly it can send its own
 * X-Forwarded-For prefix. For X-Forwarded-For only the last hop, the one the
 * proxy appended, is used.
 */
export class ClientAddressResolver {
  constructor(private readonly trustedHeader: TrustedProxyHeader | null) {}

  static fromConfig(config: { readonly TRUST_PROXY: boolean; readonly TRUSTED_PROXY_HEADER: TrustedProxyHeader }): ClientAddressResolver {
    return new ClientAddressResolver(config.TRUST_PROXY ? config.TRUSTED_PROXY_HEADER : null);
  }

  resolve(c: Context): string {
    const forwarded = this.trustedHeader ? this.forwardedAddress(c, this.trustedHeader) : null;
    if (forwarded) return ClientAddressResolver.normalizeAddress(forwarded);
    try {
      return ClientAddressResolver.normalizeAddress(getConnInfo(c).remote.address ?? "unknown");
    } catch {
      return "unknown";
    }
  }

  private forwardedAddress(c: Context, header: TrustedProxyHeader): string | null {
    if (header === "fly-client-ip") return c.req.header("fly-client-ip")?.trim() || null;
    const hops = (c.req.header("x-forwarded-for") ?? "").split(",").map((hop) => hop.trim()).filter(Boolean);
    return hops[hops.length - 1] ?? null;
  }

  /** Normalizes IPv6 addresses to their canonical /64 prefix; preserves IPv4 and IPv4-mapped IPv6. */
  static normalizeAddress(raw: string): string {
    let addr = raw.trim();
    if (!addr) return "unknown";
    const bracketMatch = /^\[([^\]]+)\](?::\d+)?$/.exec(addr);
    if (bracketMatch?.[1]) addr = bracketMatch[1];
    const ipv4PortMatch = /^(\d+\.\d+\.\d+\.\d+):\d+$/.exec(addr);
    if (ipv4PortMatch?.[1] && isIP(ipv4PortMatch[1]) === 4) return ipv4PortMatch[1];
    const zoneIndex = addr.indexOf("%");
    if (zoneIndex > 0) addr = addr.slice(0, zoneIndex);
    const family = isIP(addr);
    if (family === 4) return addr;
    if (family !== 6) return addr;
    const words = ClientAddressResolver.parseIpv6Words(addr);
    if (!words) return addr;
    if (words[0] === 0 && words[1] === 0 && words[2] === 0 && words[3] === 0 && words[4] === 0 && words[5] === 0xffff) {
      return `${words[6]! >> 8}.${words[6]! & 0xff}.${words[7]! >> 8}.${words[7]! & 0xff}`;
    }
    words[4] = 0;
    words[5] = 0;
    words[6] = 0;
    words[7] = 0;
    return `${ClientAddressResolver.formatIpv6(words)}/64`;
  }

  private static parseIpv6Words(addr: string): number[] | null {
    const doubleColonParts = addr.split("::");
    if (doubleColonParts.length > 2) return null;
    const expandHalf = (half: string): number[] => {
      if (!half) return [];
      const segments = half.split(":");
      const out: number[] = [];
      for (let i = 0; i < segments.length; i += 1) {
        const seg = segments[i]!;
        if (seg.includes(".")) {
          const octets = seg.split(".").map(Number);
          if (octets.length !== 4) return [];
          out.push((octets[0]! << 8) | octets[1]!, (octets[2]! << 8) | octets[3]!);
        } else {
          out.push(Number.parseInt(seg, 16));
        }
      }
      return out;
    };
    const left = expandHalf(doubleColonParts[0] ?? "");
    if (doubleColonParts.length === 1) return left.length === 8 ? left : null;
    const right = expandHalf(doubleColonParts[1] ?? "");
    const missing = 8 - left.length - right.length;
    if (missing < 1) return null;
    return [...left, ...new Array<number>(missing).fill(0), ...right];
  }

  private static formatIpv6(words: readonly number[]): string {
    let bestStart = -1;
    let bestLen = 0;
    let curStart = -1;
    let curLen = 0;
    for (let i = 0; i < 8; i += 1) {
      if (words[i] === 0) {
        if (curStart === -1) curStart = i;
        curLen += 1;
        if (curLen > bestLen) {
          bestStart = curStart;
          bestLen = curLen;
        }
      } else {
        curStart = -1;
        curLen = 0;
      }
    }
    if (bestLen < 2) bestStart = -1;
    const parts: string[] = [];
    for (let i = 0; i < 8; i += 1) {
      if (i === bestStart) {
        parts.push("");
        if (i === 0) parts.push("");
        i += bestLen - 1;
        if (i === 7) parts.push("");
      } else {
        parts.push(words[i]!.toString(16));
      }
    }
    return parts.join(":");
  }
}
