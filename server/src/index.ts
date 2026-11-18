import { serve } from "@hono/node-server";
import { AppConfigLoader } from "./config/AppConfig.js";
import { Container } from "./Container.js";
import { AppFactory } from "./http/App.js";

const config = AppConfigLoader.fromEnvironment();
const container = new Container(config);
container.prepare();

const app = AppFactory.create(container);
const server = serve({ fetch: app.fetch, hostname: config.HOST, port: config.PORT }, (info) => {
  console.log(`[server] InterviewCheck access server listening on ${info.address}:${info.port}`);
  console.log(`[server] billing ${container.billing.isConfigured ? "configured" : "NOT configured (set STRIPE_* env vars)"}`);
  if (!container.bootstrap.isConfigured) {
    console.warn("[server] ADMIN_EMAILS or ADMIN_BOOTSTRAP_SECRET missing: no signup can claim admin (promote via SQL instead)");
  }
});

const shutdown = (signal: string) => {
  console.log(`[server] ${signal} received, shutting down`);
  server.close(() => {
    container.close();
    process.exit(0);
  });
};
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
