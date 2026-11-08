import { AccessPolicy, type AppConfig } from "./config/AppConfig.js";
import { Database } from "./db/Database.js";
import { MigrationRunner } from "./db/Migrations.js";
import { EntitlementResolver } from "./domain/Entitlement.js";
import { PlanCatalog } from "./domain/Subscription.js";
import { FixedWindowRateLimiter } from "./http/middleware/RateLimit.js";
import { AuditLogRepository } from "./repositories/AuditLogRepository.js";
import { SessionRepository } from "./repositories/SessionRepository.js";
import { StripeEventRepository } from "./repositories/StripeEventRepository.js";
import { SubscriptionRepository } from "./repositories/SubscriptionRepository.js";
import { UserRepository } from "./repositories/UserRepository.js";
import { AdminBootstrap } from "./services/AdminBootstrap.js";
import { AdminService } from "./services/AdminService.js";
import { AuthService } from "./services/AuthService.js";
import { BillingService } from "./services/BillingService.js";
import { EntitlementService } from "./services/EntitlementService.js";
import { PasswordHasher } from "./services/PasswordHasher.js";
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
  readonly subscriptions: SubscriptionRepository;
  readonly audit: AuditLogRepository;
  readonly stripeEvents: StripeEventRepository;
  readonly entitlements: EntitlementService;
  readonly bootstrap: AdminBootstrap;
  readonly auth: AuthService;
  readonly billing: BillingService;
  readonly admin: AdminService;
  readonly credentialLimiter: FixedWindowRateLimiter;

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
    this.subscriptions = new SubscriptionRepository(this.database);
    this.audit = new AuditLogRepository(this.database);
    this.stripeEvents = new StripeEventRepository(this.database);

    const resolver = new EntitlementResolver({ pastDueGraceDays: policy.pastDueGraceDays, offlineGraceDays: policy.offlineGraceDays });
    this.entitlements = new EntitlementService(this.subscriptions, resolver, clock);
    this.bootstrap = new AdminBootstrap(config.ADMIN_EMAILS, config.ADMIN_BOOTSTRAP_SECRET);

    this.auth = new AuthService(
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
    this.billing = new BillingService(
      gateway,
      catalog,
      this.users,
      this.subscriptions,
      this.stripeEvents,
      this.audit,
      config.PUBLIC_BASE_URL.replace(/\/$/, ""),
      clock,
    );

    this.admin = new AdminService(this.users, this.sessions, this.subscriptions, this.audit, this.entitlements, clock);
    this.credentialLimiter = new FixedWindowRateLimiter({ windowMs: 60_000, max: 10 });
  }

  /** Startup work that touches data: prune dead sessions. */
  prepare(): void {
    const pruned = this.sessions.deleteExpired();
    if (pruned > 0) console.log(`[server] pruned ${pruned} expired session(s)`);
  }

  close(): void {
    this.database.close();
  }

  private static gatewayFor(config: AppConfig): StripeGateway {
    if (!config.STRIPE_SECRET_KEY) return new UnconfiguredStripeGateway();
    return new StripeSdkGateway(config.STRIPE_SECRET_KEY, config.STRIPE_WEBHOOK_SECRET);
  }
}
