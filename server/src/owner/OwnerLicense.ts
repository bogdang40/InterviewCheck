/**
 * The owner license: a small signed document that unlocks the macOS app on
 * one Mac without any server. The app embeds the Ed25519 public key; only
 * the holder of the private key can issue licenses. The payload bytes are
 * signed exactly as encoded, so verifiers never need canonical JSON.
 */
export interface OwnerLicensePayload {
  readonly version: 1;
  readonly email: string;
  /** IOPlatformUUID of the Mac this license is bound to. */
  readonly deviceID: string;
  readonly issuedAt: string;
  readonly expiresAt: string | null;
  readonly note: string | null;
}

/** What is written to disk: base64 payload bytes plus base64 signature. */
export interface OwnerLicenseEnvelope {
  readonly payload: string;
  readonly signature: string;
}

export const OWNER_LICENSE_VERSION = 1 as const;

/** Default locations next to the deployed app. */
export const OWNER_LICENSE_DEFAULT_PATH = "~/.memanager/owner.license";
export const OWNER_SIGNING_KEY_DEFAULT_PATH = "~/.memanager/owner-signing.key";
