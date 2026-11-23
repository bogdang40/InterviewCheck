import { z } from "zod";
import { KeyMaterial } from "../crypto/KeyMaterial.js";
import { TRUSTED_PROXY_HEADERS } from "../http/middleware/ClientAddressResolver.js";

/**
 * Typed, validated process configuration. Everything the server needs from
 * the environment is parsed once here so the rest of the code never touches
 * process.env directly.
 */
const emailList = z
  .string()
  .default("")
  .transform((raw) =>
    raw
      .split(",")
      .map((value) => value.trim().toLowerCase())
      .filter((value) => value.length > 0),
  );

const optionalSecret = z
  .string()
  .optional()
  .transform((value) => (value && value.length > 0 ? value : undefined));

const days = (fallback: number) => z.coerce.number().int().min(0).max(3650).default(fallback);

const encryptionKey = optionalSecret.refine((value) => value === undefined || KeyMaterial.decode32(value) !== null, {
  message: "must be 32 bytes encoded as base64 (generate with: openssl rand -base64 32)",
});

const retiredKeys = optionalSecret.transform((value, context) => {
  if (value === undefined) return undefined;
  const keys = KeyMaterial.parseKeyList(value);
  if (!keys) {
    context.addIssue({ code: "custom", message: "must be a comma separated list of kid:base64 entries with 32 byte keys" });
    return z.NEVER;
  }
  return keys as ReadonlyMap<string, Buffer>;
});

const schema = z.object({
  HOST: z.string().trim().min(1).default("0.0.0.0"),
  PORT: z.coerce.number().int().min(1).max(65535).default(8787),
  PUBLIC_BASE_URL: z.string().url().default("http://localhost:8787"),
  DATABASE_PATH: z.string().min(1).default("./data/access.sqlite"),
  ADMIN_EMAILS: emailList,
  ADMIN_BOOTSTRAP_SECRET: optionalSecret,
  TOTP_ENCRYPTION_KEY: encryptionKey,
  TOTP_ENCRYPTION_KEY_ID: z.string().trim().regex(/^[A-Za-z0-9_-]{1,32}$/, "must be 1 to 32 letters, digits, _ or -").default("k1"),
  TOTP_ENCRYPTION_RETIRED_KEYS: retiredKeys,
  TRUST_PROXY: z
    .enum(["true", "false"])
    .default("false")
    .transform((value) => value === "true"),
  // Fly sets Fly-Client-IP and overwrites any client copy; nginx style proxies append to X-Forwarded-For.
  TRUSTED_PROXY_HEADER: z.enum(TRUSTED_PROXY_HEADERS).default("fly-client-ip"),
  STRIPE_SECRET_KEY: optionalSecret,
  STRIPE_WEBHOOK_SECRET: optionalSecret,
  STRIPE_PRICE_MONTHLY: optionalSecret,
  STRIPE_PRICE_ANNUAL: optionalSecret,
  TRIAL_DAYS: days(0),
  PAST_DUE_GRACE_DAYS: days(3),
  OFFLINE_GRACE_DAYS: days(7),
  SESSION_TTL_DAYS: z.coerce.number().int().min(1).max(365).default(30),
  APP_URL_SCHEME: z
    .string()
    .regex(/^[a-z][a-z0-9+.-]*$/i, "must be a valid URL scheme")
    .default("interviewcheck"),
});

export type AppConfig = Readonly<z.infer<typeof schema>>;

export class AppConfigLoader {
  static fromEnvironment(env: NodeJS.ProcessEnv = process.env): AppConfig {
    const parsed = schema.safeParse(env);
    if (!parsed.success) {
      const issues = parsed.error.issues.map((issue) => `${issue.path.join(".")}: ${issue.message}`);
      throw new Error(`Invalid server configuration:\n  ${issues.join("\n  ")}`);
    }
    return Object.freeze(parsed.data);
  }

  /** Configuration suitable for unit tests: in-memory database, no Stripe. */
  static forTesting(overrides: Partial<AppConfig> = {}): AppConfig {
    const base = AppConfigLoader.fromEnvironment({ DATABASE_PATH: ":memory:" });
    return Object.freeze({ ...base, ...overrides });
  }
}

export class AccessPolicy {
  readonly trialDays: number;
  readonly pastDueGraceDays: number;
  readonly offlineGraceDays: number;
  readonly sessionTtlDays: number;

  constructor(config: Pick<AppConfig, "TRIAL_DAYS" | "PAST_DUE_GRACE_DAYS" | "OFFLINE_GRACE_DAYS" | "SESSION_TTL_DAYS">) {
    this.trialDays = config.TRIAL_DAYS;
    this.pastDueGraceDays = config.PAST_DUE_GRACE_DAYS;
    this.offlineGraceDays = config.OFFLINE_GRACE_DAYS;
    this.sessionTtlDays = config.SESSION_TTL_DAYS;
  }
}

export const MILLISECONDS_PER_DAY = 24 * 60 * 60 * 1000;
