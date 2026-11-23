import { randomBytes } from "node:crypto";
import { describe, expect, it } from "vitest";
import { AppConfigLoader } from "../src/config/AppConfig.js";

const STRIPE = {
  STRIPE_SECRET_KEY: "sk_live_x",
  STRIPE_WEBHOOK_SECRET: "whsec_x",
  STRIPE_PRICE_MONTHLY: "price_m",
  STRIPE_PRICE_ANNUAL: "price_a",
};

const PRODUCTION = { NODE_ENV: "production", DATABASE_PATH: ":memory:", PUBLIC_BASE_URL: "https://access.example.com" };

describe("AppConfigLoader", () => {
  it("accepts the documented Fly deployment: production, https origin and all four Stripe values", () => {
    const config = AppConfigLoader.fromEnvironment({ ...PRODUCTION, ...STRIPE, TRUST_PROXY: "true", PORT: "8787" });
    expect(config.PUBLIC_BASE_URL).toBe("https://access.example.com");
    expect(config.TRUSTED_PROXY_HEADER).toBe("fly-client-ip");
  });

  it("accepts production without any Stripe configuration (billing off)", () => {
    expect(() => AppConfigLoader.fromEnvironment(PRODUCTION)).not.toThrow();
  });

  it("requires an https PUBLIC_BASE_URL in production", () => {
    expect(() => AppConfigLoader.fromEnvironment({ ...PRODUCTION, PUBLIC_BASE_URL: "http://access.example.com" })).toThrow(
      /PUBLIC_BASE_URL: must use https in production/,
    );
    expect(() => AppConfigLoader.fromEnvironment({ NODE_ENV: "production", DATABASE_PATH: ":memory:" })).toThrow(/PUBLIC_BASE_URL/);
  });

  it("makes Stripe configuration all or nothing in production", () => {
    const partial = { ...PRODUCTION, STRIPE_SECRET_KEY: "sk_live_x", STRIPE_PRICE_MONTHLY: "price_m" };
    expect(() => AppConfigLoader.fromEnvironment(partial)).toThrow(/STRIPE_WEBHOOK_SECRET, STRIPE_PRICE_ANNUAL/);
  });

  it("parses TOTP_SETUP_REQUIRES_PASSWORD as a strict boolean defaulting to false", () => {
    expect(AppConfigLoader.fromEnvironment({ DATABASE_PATH: ":memory:" }).TOTP_SETUP_REQUIRES_PASSWORD).toBe(false);
    expect(AppConfigLoader.fromEnvironment({ DATABASE_PATH: ":memory:", TOTP_SETUP_REQUIRES_PASSWORD: "true" }).TOTP_SETUP_REQUIRES_PASSWORD).toBe(true);
    expect(() => AppConfigLoader.fromEnvironment({ DATABASE_PATH: ":memory:", TOTP_SETUP_REQUIRES_PASSWORD: "yes" })).toThrow(/TOTP_SETUP_REQUIRES_PASSWORD/);
  });

  it("keeps development permissive", () => {
    expect(() => AppConfigLoader.fromEnvironment({ DATABASE_PATH: ":memory:", STRIPE_SECRET_KEY: "sk_test_x" })).not.toThrow();
  });

  it("validates the trusted proxy header and the TOTP key material", () => {
    expect(() => AppConfigLoader.fromEnvironment({ DATABASE_PATH: ":memory:", TRUSTED_PROXY_HEADER: "x-real-ip" })).toThrow(/TRUSTED_PROXY_HEADER/);
    expect(() => AppConfigLoader.fromEnvironment({ DATABASE_PATH: ":memory:", TOTP_ENCRYPTION_KEY: "too-short" })).toThrow(/TOTP_ENCRYPTION_KEY/);
    const key = randomBytes(32).toString("base64");
    const config = AppConfigLoader.fromEnvironment({
      DATABASE_PATH: ":memory:",
      TOTP_ENCRYPTION_KEY: key,
      TOTP_ENCRYPTION_KEY_ID: "2026-11",
      TOTP_ENCRYPTION_RETIRED_KEYS: `k1:${randomBytes(32).toString("base64url")}`,
    });
    expect(config.TOTP_ENCRYPTION_RETIRED_KEYS?.get("k1")).toHaveLength(32);
    expect(() => AppConfigLoader.fromEnvironment({ DATABASE_PATH: ":memory:", TOTP_ENCRYPTION_RETIRED_KEYS: "k1:abc" })).toThrow(
      /TOTP_ENCRYPTION_RETIRED_KEYS/,
    );
    expect(() => AppConfigLoader.fromEnvironment({ DATABASE_PATH: ":memory:", TOTP_ENCRYPTION_KEY_ID: "bad id" })).toThrow(/TOTP_ENCRYPTION_KEY_ID/);
  });
});
