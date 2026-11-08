import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { MacDeviceID } from "../owner/MacDeviceID.js";
import { OWNER_LICENSE_DEFAULT_PATH, OWNER_SIGNING_KEY_DEFAULT_PATH, type OwnerLicenseEnvelope } from "../owner/OwnerLicense.js";
import { OwnerLicenseSigner } from "../owner/OwnerLicenseSigner.js";

/**
 * Owner license command line.
 *
 *   npm run owner-license -- keygen
 *   npm run owner-license -- issue --email you@example.com --device auto
 *   npm run owner-license -- verify --public-key <base64> --device auto
 *   npm run owner-license -- public-key
 *
 * keygen writes the private key to ~/.memanager/owner-signing.key (mode 600)
 * and prints the public key to paste into OwnerLicensePublicKey.swift.
 * issue writes ~/.memanager/owner.license, which the app reads at launch.
 */
class OwnerLicenseCommand {
  constructor(private readonly args: readonly string[]) {}

  run(): void {
    const [command = "help"] = this.args;
    switch (command) {
      case "keygen": return this.keygen();
      case "issue": return this.issue();
      case "verify": return this.verify();
      case "public-key": return this.publicKey();
      default: return this.help();
    }
  }

  private keygen(): void {
    const keyPath = this.path("--key", OWNER_SIGNING_KEY_DEFAULT_PATH);
    if (existsSync(keyPath) && !this.flag("--force")) {
      throw new Error(`${keyPath} already exists; pass --force to overwrite (existing licenses would stop verifying against a new key)`);
    }
    const pair = OwnerLicenseSigner.generateKeyPair();
    mkdirSync(dirname(keyPath), { recursive: true });
    writeFileSync(keyPath, pair.privateKeyPem, { mode: 0o600 });
    chmodSync(keyPath, 0o600);
    console.log(`private key: ${keyPath}`);
    console.log(`public key (paste into memanager/Access/Services/OwnerLicensePublicKey.swift):`);
    console.log(pair.publicKeyBase64);
  }

  private issue(): void {
    const email = this.value("--email");
    if (!email) throw new Error("--email is required");
    const privateKeyPem = readFileSync(this.path("--key", OWNER_SIGNING_KEY_DEFAULT_PATH), "utf8");
    const expires = this.value("--expires");
    const envelope = OwnerLicenseSigner.issue(privateKeyPem, {
      email,
      deviceID: this.device(),
      issuedAt: new Date(),
      expiresAt: expires ? new Date(expires) : null,
      note: this.value("--note") ?? null,
    });
    const outPath = this.path("--out", OWNER_LICENSE_DEFAULT_PATH);
    if (existsSync(outPath) && !this.flag("--force")) {
      throw new Error(`${outPath} already exists; pass --force to replace it`);
    }
    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(outPath, JSON.stringify(envelope, null, 2) + "\n", { mode: 0o600 });
    console.log(`license written: ${outPath}`);
  }

  private verify(): void {
    const publicKey = this.value("--public-key");
    if (!publicKey) throw new Error("--public-key <base64> is required");
    const file = this.path("--file", OWNER_LICENSE_DEFAULT_PATH);
    const envelope = JSON.parse(readFileSync(file, "utf8")) as OwnerLicenseEnvelope;
    const payload = OwnerLicenseSigner.verify(envelope, publicKey, this.device(), new Date());
    console.log(`valid license for ${payload.email} on ${payload.deviceID}${payload.expiresAt ? `, expires ${payload.expiresAt}` : ""}`);
  }

  private publicKey(): void {
    console.log(OwnerLicenseSigner.publicKeyBase64(readFileSync(this.path("--key", OWNER_SIGNING_KEY_DEFAULT_PATH), "utf8")));
  }

  private help(): void {
    console.log("usage: owner-license <keygen|issue|verify|public-key> [--email x] [--device auto|UUID] [--expires ISO] [--note text] [--key path] [--out path] [--file path] [--public-key base64] [--force]");
  }

  private device(): string {
    const raw = this.value("--device") ?? "auto";
    return raw === "auto" ? MacDeviceID.read() : raw;
  }

  private value(flag: string): string | undefined {
    const index = this.args.indexOf(flag);
    if (index < 0) return undefined;
    const next = this.args[index + 1];
    if (next === undefined || next.startsWith("--")) throw new Error(`${flag} needs a value`);
    return next;
  }

  private flag(flag: string): boolean {
    return this.args.includes(flag);
  }

  private path(flag: string, fallback: string): string {
    const raw = this.value(flag) ?? fallback;
    return resolve(raw.startsWith("~/") ? `${homedir()}/${raw.slice(2)}` : raw);
  }
}

try {
  new OwnerLicenseCommand(process.argv.slice(2)).run();
} catch (error) {
  console.error(`owner-license: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}
