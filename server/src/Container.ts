import { AccessPolicy, type AppConfig } from "./config/AppConfig.js";
import { TotpKeyRing } from "./crypto/TotpKeyRing.js";
import { TotpSecretCipher } from "./crypto/TotpSecretCipher.js";
import { Database } from "./db/Database.js";
import { MigrationRunner } from "./db/Migrations.js";
import { EntitlementResolver } from "./domain/Entitlement.js";
import { PlanCatalog } from "./domain/Subscription.js";
import { ClientAddressResolver, FixedWindowRateLimiter } from "./http/middleware/RateLimit.js";
import { AccessStatsQuery } from "./repositories/AccessStatsQuery.js";
import { ApiTokenRepository } from "./repositories/ApiTokenRepository.js";
import { AuditCheckpointRepository } from "./repositories/AuditCheckpointRepository.js";
import { AuditLogRepository } from "./repositories/AuditLogRepository.js";
import { CheckoutRepository } from "./repositories/CheckoutRepository.js";
import { SessionRepository } from "./repositories/SessionRepository.js";
import { StripeEventRepository } from "./repositories/StripeEventRepository.js";
import { SubscriptionRepository } from "./repositories/SubscriptionRepository.js";
import { TotpRepository } from "./repositories/TotpRepository.js";
import { UserRepository } from "./repositories/UserRepository.js";
import { AdminBootstrap } from "./services/AdminBootstrap.js";
import { AdminActorGuard } from "./services/AdminActorGuard.js";
import { AdminService } from "./services/AdminService.js";
import { ApiTokenService } from "./services/ApiTokenService.js";
import { AuditChainVerifier } from "./services/AuditChainVerifier.js";
import { AuthService } from "./services/AuthService.js";
import { BillingService } from "./services/BillingService.js";
import { BillingWebhookService } from "./services/BillingWebhookService.js";
import { EntitlementService } from "./services/EntitlementService.js";
import { LoginThrottle } from "./services/LoginThrottle.js";
import { PasswordHasher } from "./services/PasswordHasher.js";
import { RateLimitAdminService } from "./services/RateLimitAdminService.js";
import { SessionManagementService } from "./services/SessionManagementService.js";
import { SessionPruneScheduler } from "./services/SessionPruneScheduler.js";
import { TokenService } from "./services/TokenService.js";
import { TotpSecretMigrator } from "./services/TotpSecretMigrator.js";
import { TotpService } from "./services/TotpService.js";
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
  readonly totpCodes: TotpRepository;
  readonly subscriptions: SubscriptionRepository;
  readonly audit: AuditLogRepository;
  readonly auditCheckpoints: AuditCheckpointRepository;
  readonly auditVerifier: AuditChainVerifier;
  readonly stripeEvents: StripeEventRepository;
  readonly entitlements: EntitlementService;
  readonly bootstrap: AdminBootstrap;
  readonly totpKeys: TotpKeyRing;
  readonly totpMigrator: TotpSecretMigrator;
  readonly totp: TotpService;
  readonly auth: AuthService;
  readonly billing: BillingService;
  readonly billingWebhook: BillingWebhookService;
  readonly admin: AdminService;
  readonly sessionManagement: SessionManagementService;
  readonly apiTokenService: ApiTokenService;
  readonly rateLimitAdmin: RateLimitAdminService;
  readonly stats: AccessStatsQuery;
  readonly clientAddress: ClientAddressResolver;
  readonly sessionPruner: SessionPruneScheduler;
  readonly credentialLimiter: FixedWindowRateLimiter;
  readonly adminReadLimiter: FixedWindowRateLimiter;
  readonly adminWriteLimiter: FixedWindowRateLimiter;
  readonly billingLimiter: FixedWindowRateLimiter;
  readonly totpLimiter: FixedWindowRateLimiter;
  readonly apiTokenLimiter: FixedWindowRateLimiter;

  constructor(
    readonly config: AppConfig,
    overrides: ContainerOverrides = {},
  ) {
    const clock = overrides.clock ?? (() => new Date());
    const policy = new AccessPolicy(config);
    const hasher = overrides.hasher ?? new PasswordHasher();

    this.database = new Database(config.DATABASE_PATH);
    new MigrationRunner().run(this.database);

    this.users = new UserRepository(this.database);
    this.sessions = new SessionRepository(this.database);
    this.sessionPruner = new SessionPruneScheduler(this.sessions, undefined, clock);
    this.apiTokens = new ApiTokenRepository(this.database);
    this.totpCodes = new TotpRepository(this.database);
    this.subscriptions = new SubscriptionRepository(this.database);
    this.audit = new AuditLogRepository(this.database);
    this.auditCheckpoints = new AuditCheckpointRepository(this.database);
    this.auditVerifier = new AuditChainVerifier(this.audit, this.auditCheckpoints, clock);
    this.stripeEvents = new StripeEventRepository(this.database);

    const resolver = new EntitlementResolver({ pastDueGraceDays: policy.pastDueGraceDays, offlineGraceDays: policy.offlineGraceDays });
    this.entitlements = new EntitlementService(this.subscriptions, resolver, clock);
    this.bootstrap = new AdminBootstrap(config.ADMIN_EMAILS, config.ADMIN_BOOTSTRAP_SECRET);
    this.totpKeys = TotpKeyRing.fromConfig(config);
    const totpCipher = new TotpSecretCipher(this.totpKeys);
    this.totpMigrator = new TotpSecretMigrator(this.totpKeys, totpCipher, this.totpCodes);
    this.totp = new TotpService(this.database, this.users, this.totpCodes, this.sessions, this.audit, hasher, totpCipher, clock);

    const loginThrottle = new LoginThrottle(this.database);
    const adminGuard = new AdminActorGuard(this.users);
    this.auth = new AuthService(
      this.database,
      this.users,
      this.sessions,
      this.apiTokens,
      this.audit,
      hasher,
      new TokenService(),
      this.entitlements,
      this.bootstrap,
      policy,
      this.totp,
      loginThrottle,
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

    this.admin = new AdminService(
      this.database, this.users, this.sessions, this.subscriptions, this.audit, this.entitlements, this.totpCodes, this.apiTokens, adminGuard, clock,
    );
    this.stats = new AccessStatsQuery(this.database);
    this.clientAddress = ClientAddressResolver.fromConfig(config);
    this.credentialLimiter = new FixedWindowRateLimiter({ windowMs: 60_000, max: 10 });
    this.adminReadLimiter = new FixedWindowRateLimiter({ windowMs: 60_000, max: 120 });
    this.adminWriteLimiter = new FixedWindowRateLimiter({ windowMs: 60_000, max: 40 });
    this.billingLimiter = new FixedWindowRateLimiter({ windowMs: 60_000, max: 20 });
    this.totpLimiter = new FixedWindowRateLimiter({ windowMs: 60_000, max: 10 });
    this.apiTokenLimiter = new FixedWindowRateLimiter({ windowMs: 60_000, max: 10 });
    this.sessionManagement = new SessionManagementService(this.database, this.users, this.sessions, this.audit, adminGuard, clock);
    this.apiTokenService = new ApiTokenService(this.database, this.users, this.apiTokens, this.audit, clock);
    this.rateLimitAdmin = new RateLimitAdminService(
      this.database,
      this.audit,
      {
        credential: this.credentialLimiter,
        adminRead: this.adminReadLimiter,
        adminWrite: this.adminWriteLimiter,
        billing: this.billingLimiter,
        totp: this.totpLimiter,
        apiToken: this.apiTokenLimiter,
      },
      loginThrottle,
      adminGuard,
      clock,
    );
  }

  /** Startup work that touches data: prune dead sessions (then hourly) and move TOTP seeds onto the primary key. */
  prepare(): void {
    this.sessionPruner.pruneNow();
    this.sessionPruner.start();
    const totp = this.totpMigrator.run();
    if (totp.reencrypted > 0) console.log(`[server] re-encrypted ${totp.reencrypted} TOTP seed(s) under the primary key`);
    if (totp.unreadable > 0) console.warn(`[server] ${totp.unreadable} TOTP seed(s) could not be decrypted; those users need a backup code or an admin TOTP reset`);
  }

  checkDatabase(): void {
    this.database.get("SELECT 1 FROM users LIMIT 1");
    this.database.get("SELECT stripe_customer_id FROM subscriptions LIMIT 1");
  }

  close(): void {
    this.sessionPruner.stop();
    this.database.close();
  }

  private static gatewayFor(config: AppConfig): StripeGateway {
    if (!config.STRIPE_SECRET_KEY) return new UnconfiguredStripeGateway();
    const prices = [config.STRIPE_PRICE_MONTHLY, config.STRIPE_PRICE_ANNUAL].filter((price) => price !== undefined);
    return new StripeSdkGateway(config.STRIPE_SECRET_KEY, config.STRIPE_WEBHOOK_SECRET, prices);
  }
}
