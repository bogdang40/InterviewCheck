import { createPrivateKey, createPublicKey, generateKeyPairSync, sign, verify, type KeyObject } from "node:crypto";
import { OWNER_LICENSE_VERSION, type OwnerLicenseEnvelope, type OwnerLicensePayload } from "./OwnerLicense.js";

export interface OwnerKeyPair {
  /** Raw 32 byte Ed25519 public key, standard base64. Embedded in the app. */
  readonly publicKeyBase64: string;
  /** PKCS#8 PEM. Stays with the owner, never in the repository. */
  readonly privateKeyPem: string;
}

export interface IssueRequest {
  readonly email: string;
  readonly deviceID: string;
  readonly issuedAt: Date;
  readonly expiresAt?: Date | null;
  readonly note?: string | null;
}

export class OwnerLicenseError extends Error {
  constructor(readonly code: "malformed" | "bad_signature" | "wrong_device" | "expired" | "unsupported_version", message: string) {
    super(message);
    this.name = "OwnerLicenseError";
  }
}

/** Issues and verifies owner licenses with Ed25519. Pure; no file system. */
export class OwnerLicenseSigner {
  static readonly DEVICE_ID_PATTERN = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;

  static generateKeyPair(): OwnerKeyPair {
    const { publicKey, privateKey } = generateKeyPairSync("ed25519");
    return {
      publicKeyBase64: OwnerLicenseSigner.rawPublicKeyBase64(publicKey),
      privateKeyPem: privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
    };
  }

  /** Raw public key (32 bytes) as standard base64, derived from a PEM private key. */
  static publicKeyBase64(privateKeyPem: string): string {
    const privateKey = createPrivateKey(privateKeyPem);
    return OwnerLicenseSigner.rawPublicKeyBase64(createPublicKey(privateKey));
  }

  static issue(privateKeyPem: string, request: IssueRequest): OwnerLicenseEnvelope {
    const email = request.email.trim().toLowerCase();
    const deviceID = request.deviceID.trim().toUpperCase();
    if (!email.includes("@")) throw new OwnerLicenseError("malformed", "email must contain @");
    if (!OwnerLicenseSigner.DEVICE_ID_PATTERN.test(deviceID)) throw new OwnerLicenseError("malformed", "deviceID must be an IOPlatformUUID (8-4-4-4-12 hex)");
    if (request.expiresAt && Number.isNaN(request.expiresAt.getTime())) throw new OwnerLicenseError("malformed", "expiresAt is not a date");
    if (request.expiresAt && request.expiresAt.getTime() <= request.issuedAt.getTime()) throw new OwnerLicenseError("malformed", "expiresAt must be after issuedAt");
    const payload: OwnerLicensePayload = {
      version: OWNER_LICENSE_VERSION,
      email,
      deviceID,
      issuedAt: request.issuedAt.toISOString(),
      expiresAt: request.expiresAt ? request.expiresAt.toISOString() : null,
      note: request.note ?? null,
    };
    const payloadBytes = Buffer.from(JSON.stringify(payload), "utf8");
    const signature = sign(null, payloadBytes, createPrivateKey(privateKeyPem));
    return { payload: payloadBytes.toString("base64"), signature: signature.toString("base64") };
  }

  /** Mirrors the macOS verifier so the two stay in step (see OwnerLicenseVerifier.swift). */
  static verify(envelope: OwnerLicenseEnvelope, publicKeyBase64: string, deviceID: string, now: Date): OwnerLicensePayload {
    const payloadBytes = Buffer.from(envelope.payload, "base64");
    const signature = Buffer.from(envelope.signature, "base64");
    const publicKey = OwnerLicenseSigner.publicKey(publicKeyBase64);
    if (payloadBytes.length === 0 || signature.length !== 64) throw new OwnerLicenseError("malformed", "envelope is not a license");
    if (!verify(null, payloadBytes, publicKey, signature)) throw new OwnerLicenseError("bad_signature", "signature does not match the embedded public key");
    let payload: OwnerLicensePayload;
    try {
      payload = JSON.parse(payloadBytes.toString("utf8")) as OwnerLicensePayload;
    } catch {
      throw new OwnerLicenseError("malformed", "payload is not JSON");
    }
    if (payload.version !== OWNER_LICENSE_VERSION) throw new OwnerLicenseError("unsupported_version", `license version ${String(payload.version)} is not supported`);
    if (payload.deviceID !== deviceID.trim().toUpperCase()) throw new OwnerLicenseError("wrong_device", "license is bound to a different Mac");
    if (Number.isNaN(new Date(payload.issuedAt).getTime())) throw new OwnerLicenseError("malformed", "issuedAt is not a date");
    if (payload.expiresAt !== null) {
      const expiry = new Date(payload.expiresAt).getTime();
      if (Number.isNaN(expiry)) throw new OwnerLicenseError("malformed", "expiresAt is not a date");
      if (expiry <= now.getTime()) throw new OwnerLicenseError("expired", "license has expired");
    }
    return payload;
  }

  private static rawPublicKeyBase64(publicKey: KeyObject): string {
    const jwk = publicKey.export({ format: "jwk" });
    if (typeof jwk.x !== "string") throw new Error("public key export did not include x");
    return Buffer.from(jwk.x, "base64url").toString("base64");
  }

  private static publicKey(rawBase64: string): KeyObject {
    const raw = Buffer.from(rawBase64, "base64");
    if (raw.length !== 32) throw new OwnerLicenseError("malformed", "public key must be 32 raw bytes");
    return createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: raw.toString("base64url") }, format: "jwk" });
  }
}
