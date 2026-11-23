export interface ProductionRuleInput {
  readonly NODE_ENV?: string | undefined;
  readonly PUBLIC_BASE_URL: string;
  readonly STRIPE_SECRET_KEY?: string | undefined;
  readonly STRIPE_WEBHOOK_SECRET?: string | undefined;
  readonly STRIPE_PRICE_MONTHLY?: string | undefined;
  readonly STRIPE_PRICE_ANNUAL?: string | undefined;
}

const STRIPE_KEYS = ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET", "STRIPE_PRICE_MONTHLY", "STRIPE_PRICE_ANNUAL"] as const;

/**
 * Checks that only apply when NODE_ENV=production (the Docker image sets it).
 * Development keeps the permissive defaults so the server runs with nothing
 * configured.
 */
export class ProductionConfigRules {
  static issues(config: ProductionRuleInput): string[] {
    if (config.NODE_ENV !== "production") return [];
    const issues: string[] = [];
    if (new URL(config.PUBLIC_BASE_URL).protocol !== "https:") {
      issues.push("PUBLIC_BASE_URL: must use https in production (set it to the public origin, for example https://<app>.fly.dev)");
    }
    const missing = STRIPE_KEYS.filter((key) => !config[key]);
    if (missing.length > 0 && missing.length < STRIPE_KEYS.length) {
      issues.push(`STRIPE: billing is partly configured; also set ${missing.join(", ")} or clear all four Stripe values`);
    }
    return issues;
  }
}
