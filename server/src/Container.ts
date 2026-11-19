import { AccessPolicy, type AppConfig } from "./config/AppConfig.js";
import { Database } from "./db/Database.js";
import { MigrationRunner } from "./db/Migrations.js";
import { EntitlementResolver } from "./domain/Entitlement.js";
import { PlanCatalog } from "./domain/Subscription.js";
import { FixedWindowRateLimiter } from "./http/middleware/RateLimit.js";
import { ApiTokenRepository } from "./repositories/ApiTokenRepository.js";
import { AuditLogRepository } from "./repositories/AuditLogRepository.js";
import { CheckoutRepository } from "./repositories/CheckoutRepository.js";
import { SessionRepository } from "./repositories/SessionRepository.js";
import { StripeEventRepository } from "./repositories/StripeEventRepository.js";
import { SubscriptionRepository } from "./repositories/SubscriptionRepository.js";
import { UserRepository } from "./repositories/UserRepository.js";
import { AdminBootstrap } from "./services/AdminBootstrap.js";
import { AdminService } from "./services/AdminService.js";
import { AuthService } from "./services/AuthService.js";
import { BillingService } from "./services/BillingService.js";
import { BillingWebhookService } from "./services/BillingWebhookService.js";
import { EntitlementService } from "./services/EntitlementService.js";
import { PasswordHasher } from "./services/PasswordHasher.js";
import { SecurityService } from "./services/SecurityService.js";
import { TokenService } from "./services/TokenService.js";
import { StripeSdkGateway } from "./stripe/StripeSdkGateway.js";
import { UnconfiguredStripeGateway, type StripeGateway } from "./stripe/StripeGateway.js";

export interface ContainerOverrides {
  gateway?: StripeGateway;
  clock?: () => Date;
  hasher?: PasswordHasher;
}

/** Composition root. Wires every collaborator once; nothing else uses `new` across layers. */
export class Container {
  readonly database: Database;
  readonly users: UserRepository;
  readonly sessions: SessionRepository;
  readonly apiTokens: ApiTokenRepository;
  readonly subscriptions: SubscriptionRepository;
  readonly audit: AuditLogRepository;
  readonly stripeEvents: StripeEventRepository;
  readonly entitlements: EntitlementService;
  readonly bootstrap: AdminBootstrap;
  readonly auth: AuthService;
  readonly billing: BillingService;
  readonly billingWebhook: BillingWebhookService;
  readonly admin: AdminService;
  readonly security: SecurityService;
  readonly credentialLimiter: FixedWindowRateLimiter;
  readonly adminReadLimiter: FixedWindowRateLimiter;
  readonly adminWriteLimiter: FixedWindowRateLimiter;
  readonly billingLimiter: FixedWindowRateLimiter;

  constructor(
    readonly config: AppConfig,
    overrides: ContainerOverrides = {},
  ) {
    const clock = overrides.clock ?? (() => new Date());
    const policy = new AccessPolicy(config);

    this.database = new Database(config.DATABASE_PATH);
    new MigrationRunner().run(this.database);

    this.users = new UserRepository(this.database);
    this.sessions = new SessionRepository(this.database);
    this.apiTokens = new ApiTokenRepository(this.database);
    this.subscriptions = new SubscriptionRepository(this.database);
    this.audit = new AuditLogRepository(this.database);
    this.stripeEvents = new StripeEventRepository(this.database);

    const resolver = new EntitlementResolver({ pastDueGraceDays: policy.pastDueGraceDays, offlineGraceDays: policy.offlineGraceDays });
    this.entitlements = new EntitlementService(this.subscriptions, resolver, clock);
    this.bootstrap = new AdminBootstrap(config.ADMIN_EMAILS, config.ADMIN_BOOTSTRAP_SECRET);

    this.auth = new AuthService(
      this.database,
      this.users,
      this.sessions,
      this.audit,
      overrides.hasher ?? new PasswordHasher(),
      new TokenService(),
      this.entitlements,
      this.bootstrap,
      policy,
      clock,
    );

    const gateway = overrides.gateway ?? Container.gatewayFor(config);
    const catalog = new PlanCatalog({ monthly: config.STRIPE_PRICE_MONTHLY, annual: config.STRIPE_PRICE_ANNUAL });
    const checkouts = new CheckoutRepository(this.database);
    this.billing = new BillingService(
      gateway,
      catalog,
      this.users,
      checkouts,
      this.audit,
      `${config.PUBLIC_BASE_URL.replace(/\/$/, "")}/v1/billing/return`,
      clock,
    );
    this.billingWebhook = new BillingWebhookService(
      gateway,
      catalog,
      this.users,
      this.subscriptions,
      checkouts,
      this.stripeEvents,
      this.audit,
      clock,
    );

    this.admin = new AdminService(this.database, this.users, this.sessions, this.subscriptions, this.audit, this.entitlements, clock);
    this.credentialLimiter = new FixedWindowRateLimiter({ windowMs: 60_000, max: 10 });
    this.adminReadLimiter = new FixedWindowRateLimiter({ windowMs: 60_000, max: 120 });
    this.adminWriteLimiter = new FixedWindowRateLimiter({ windowMs: 60_000, max: 40 });
    this.billingLimiter = new FixedWindowRateLimiter({ windowMs: 60_000, max: 20 });
    this.security = new SecurityService(
      this.database,
      this.users,
      this.sessions,
      this.apiTokens,
      this.audit,
      {
        credential: this.credentialLimiter,
        adminRead: this.adminReadLimiter,
        adminWrite: this.adminWriteLimiter,
        billing: this.billingLimiter,
      },
      clock,
    );
  }

  /** Startup work that touches data: prune dead sessions. */
  prepare(): void {
    const pruned = this.sessions.deleteExpired();
    if (pruned > 0) console.log(`[server] pruned ${pruned} expired session(s)`);
  }

  checkDatabase(): void {
    this.database.get("SELECT 1 FROM users LIMIT 1");
    this.database.get("SELECT stripe_customer_id FROM subscriptions LIMIT 1");
  }

  close(): void {
    this.database.close();
  }

  private static gatewayFor(config: AppConfig): StripeGateway {
    if (!config.STRIPE_SECRET_KEY) return new UnconfiguredStripeGateway();
    const prices = [config.STRIPE_PRICE_MONTHLY, config.STRIPE_PRICE_ANNUAL].filter((price) => price !== undefined);
    return new StripeSdkGateway(config.STRIPE_SECRET_KEY, config.STRIPE_WEBHOOK_SECRET, prices);
  }
}
