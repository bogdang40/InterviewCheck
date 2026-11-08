import { describe, expect, it } from "vitest";
import { PasswordHasher } from "../src/services/PasswordHasher.js";
import { TokenService } from "../src/services/TokenService.js";

const hasher = new PasswordHasher({ cost: 1024, blockSize: 8, parallelization: 1 });

describe("PasswordHasher", () => {
  it("round trips a password and rejects a wrong one", async () => {
    const encoded = await hasher.hash("correct horse battery");
    expect(encoded.startsWith("scrypt$1024$8$1$")).toBe(true);
    expect(await hasher.verify("correct horse battery", encoded)).toBe(true);
    expect(await hasher.verify("correct horse batteries", encoded)).toBe(false);
  });

  it("uses a fresh salt per hash", async () => {
    const a = await hasher.hash("same password");
    const b = await hasher.hash("same password");
    expect(a).not.toBe(b);
  });

  it("rejects malformed encodings without throwing", async () => {
    expect(await hasher.verify("x", "not-a-hash")).toBe(false);
    expect(await hasher.verify("x", "scrypt$abc$8$1$AAAA$BBBB")).toBe(false);
  });

  it("produces a decoy hash that verifies nothing predictable", async () => {
    const decoy = await hasher.decoyHash();
    expect(await hasher.verify("", decoy)).toBe(false);
  });
});

describe("TokenService", () => {
  it("generates prefixed tokens with stable hashes", () => {
    const tokens = new TokenService();
    const token = tokens.generate();
    expect(tokens.looksValid(token)).toBe(true);
    expect(tokens.hash(token)).toBe(tokens.hash(token));
    expect(tokens.hash(token)).toHaveLength(64);
    expect(tokens.looksValid("short")).toBe(false);
  });
});
