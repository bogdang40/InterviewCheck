import { AppConfigLoader, type AppConfig } from "../../src/config/AppConfig.js";
import { Container } from "../../src/Container.js";
import { AppFactory } from "../../src/http/App.js";
import { PasswordHasher } from "../../src/services/PasswordHasher.js";
import { FakeStripeGateway } from "./FakeStripeGateway.js";

export interface TestHarness {
  container: Container;
  gateway: FakeStripeGateway;
  app: ReturnType<typeof AppFactory.create>;
  clock: { now: Date };
  config: AppConfig;
}

/** Cheap scrypt so the suite stays fast; production uses the defaults. */
const FAST_HASHER = new PasswordHasher({ cost: 1024, blockSize: 8, parallelization: 1 });

export function buildHarness(overrides: Partial<AppConfig> = {}): TestHarness {
  const clock = { now: new Date("2026-09-02T12:00:00Z") };
  const gateway = new FakeStripeGateway();
  const config = AppConfigLoader.forTesting({
    ADMIN_EMAILS: ["owner@example.com"],
    ADMIN_BOOTSTRAP_SECRET: "bootstrap-secret",
    STRIPE_SECRET_KEY: "sk_test_fake",
    STRIPE_PRICE_MONTHLY: "price_monthly",
    STRIPE_PRICE_ANNUAL: "price_annual",
    ...overrides,
  });
  const container = new Container(config, { gateway, clock: () => clock.now, hasher: FAST_HASHER });
  const app = AppFactory.create(container, { quiet: true });
  return { container, gateway, app, clock, config };
}

export async function json<T>(response: Response): Promise<T> {
  return (await response.json()) as T;
}

export function post(app: TestHarness["app"], path: string, body: unknown, token?: string): Promise<Response> {
  return app.request(path, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
}

export function get(app: TestHarness["app"], path: string, token?: string): Promise<Response> {
  return app.request(path, { headers: token ? { authorization: `Bearer ${token}` } : {} });
}

export function patch(app: TestHarness["app"], path: string, body: unknown, token: string): Promise<Response> {
  return app.request(path, {
    method: "PATCH",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
}
