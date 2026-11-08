import { createPrivateKey, sign } from "node:crypto";
import { describe, expect, it } from "vitest";
import { MacDeviceID } from "../src/owner/MacDeviceID.js";
import { OwnerLicenseError, OwnerLicenseSigner } from "../src/owner/OwnerLicenseSigner.js";

const DEVICE = "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9";
const NOW = new Date("2026-09-03T12:00:00Z");

describe("owner license", () => {
  const pair = OwnerLicenseSigner.generateKeyPair();

  it("issues a license the embedded public key verifies", () => {
    const envelope = OwnerLicenseSigner.issue(pair.privateKeyPem, { email: " Owner@Example.com ", deviceID: DEVICE.toLowerCase(), issuedAt: NOW });
    const payload = OwnerLicenseSigner.verify(envelope, pair.publicKeyBase64, DEVICE, NOW);
    expect(payload).toMatchObject({ version: 1, email: "owner@example.com", deviceID: DEVICE, expiresAt: null, note: null });
    expect(Buffer.from(pair.publicKeyBase64, "base64")).toHaveLength(32);
    expect(OwnerLicenseSigner.publicKeyBase64(pair.privateKeyPem)).toBe(pair.publicKeyBase64);
  });

  it("refuses a license bound to another Mac", () => {
    const envelope = OwnerLicenseSigner.issue(pair.privateKeyPem, { email: "owner@example.com", deviceID: DEVICE, issuedAt: NOW });
    expect(() => OwnerLicenseSigner.verify(envelope, pair.publicKeyBase64, "FFFFFFFF-0000-0000-0000-000000000000", NOW)).toThrowError(OwnerLicenseError);
    try {
      OwnerLicenseSigner.verify(envelope, pair.publicKeyBase64, "FFFFFFFF-0000-0000-0000-000000000000", NOW);
    } catch (error) {
      expect((error as OwnerLicenseError).code).toBe("wrong_device");
    }
  });

  it("refuses an expired license and accepts one that has not expired", () => {
    const envelope = OwnerLicenseSigner.issue(pair.privateKeyPem, { email: "owner@example.com", deviceID: DEVICE, issuedAt: NOW, expiresAt: new Date("2026-10-01T00:00:00Z") });
    expect(OwnerLicenseSigner.verify(envelope, pair.publicKeyBase64, DEVICE, NOW).expiresAt).toBe("2026-10-01T00:00:00.000Z");
    expect(() => OwnerLicenseSigner.verify(envelope, pair.publicKeyBase64, DEVICE, new Date("2026-10-01T00:00:00Z"))).toThrowError(/expired/);
  });

  it("refuses a tampered payload and a license signed by another key", () => {
    const envelope = OwnerLicenseSigner.issue(pair.privateKeyPem, { email: "owner@example.com", deviceID: DEVICE, issuedAt: NOW });
    const tampered = { ...envelope, payload: Buffer.from(JSON.stringify({ ...JSON.parse(Buffer.from(envelope.payload, "base64").toString()), email: "thief@example.com" })).toString("base64") };
    expect(() => OwnerLicenseSigner.verify(tampered, pair.publicKeyBase64, DEVICE, NOW)).toThrowError(/signature/);
    const other = OwnerLicenseSigner.generateKeyPair();
    expect(() => OwnerLicenseSigner.verify(envelope, other.publicKeyBase64, DEVICE, NOW)).toThrowError(/signature/);
    expect(() => OwnerLicenseSigner.verify({ payload: "", signature: "" }, pair.publicKeyBase64, DEVICE, NOW)).toThrowError(/not a license/);
  });

  it("validates the request before signing", () => {
    expect(() => OwnerLicenseSigner.issue(pair.privateKeyPem, { email: "nope", deviceID: DEVICE, issuedAt: NOW })).toThrowError(/email/);
    expect(() => OwnerLicenseSigner.issue(pair.privateKeyPem, { email: "a@b.c", deviceID: "short", issuedAt: NOW })).toThrowError(/deviceID/);
    expect(() => OwnerLicenseSigner.issue(pair.privateKeyPem, { email: "a@b.c", deviceID: "not-a-uuid-but-long-enough", issuedAt: NOW })).toThrowError(/deviceID/);
    expect(() => OwnerLicenseSigner.issue(pair.privateKeyPem, { email: "a@b.c", deviceID: DEVICE, issuedAt: NOW, expiresAt: new Date("garbage") })).toThrowError(/expiresAt/);
    expect(() => OwnerLicenseSigner.issue(pair.privateKeyPem, { email: "a@b.c", deviceID: DEVICE, issuedAt: NOW, expiresAt: new Date("2020-01-01T00:00:00Z") })).toThrowError(/after issuedAt/);
  });

  it("treats an unparseable expiry as malformed rather than as no expiry", () => {
    const envelope = OwnerLicenseSigner.issue(pair.privateKeyPem, { email: "owner@example.com", deviceID: DEVICE, issuedAt: NOW });
    const payload = JSON.parse(Buffer.from(envelope.payload, "base64").toString()) as Record<string, unknown>;
    const bytes = Buffer.from(JSON.stringify({ ...payload, expiresAt: "never" }));
    const forged = { payload: bytes.toString("base64"), signature: sign(null, bytes, createPrivateKey(pair.privateKeyPem)).toString("base64") };
    expect(() => OwnerLicenseSigner.verify(forged, pair.publicKeyBase64, DEVICE, NOW)).toThrowError(/expiresAt is not a date/);
  });

  it("reads the IOPlatformUUID out of ioreg output", () => {
    const output = `+-o MacBookPro18,3  <class IOPlatformExpertDevice>\n    {\n      "IOPlatformUUID" = "0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9"\n    }`;
    expect(MacDeviceID.read(() => output)).toBe(DEVICE);
    expect(() => MacDeviceID.read(() => "nothing here")).toThrowError(/IOPlatformUUID/);
  });
});
