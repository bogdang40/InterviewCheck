import type { MiddlewareHandler } from "hono";
import type { AuthSession } from "../../domain/Session.js";
import type { User } from "../../domain/User.js";
import type { AuthService } from "../../services/AuthService.js";
import { HttpError } from "../HttpError.js";

export type AuthVariables = {
  user: User;
  session: AuthSession;
};

export type AuthEnv = { Variables: AuthVariables };

export class BearerTokenExtractor {
  static extract(header: string | undefined): string | null {
    if (!header) return null;
    const [scheme, token] = header.split(" ");
    if (!scheme || scheme.toLowerCase() !== "bearer" || !token) return null;
    return token.trim();
  }
}

export function authenticate(auth: AuthService): MiddlewareHandler<AuthEnv> {
  return async (c, next) => {
    const token = BearerTokenExtractor.extract(c.req.header("authorization"));
    if (!token) throw new HttpError(401, "unauthenticated", "Sign in required.");
    const result = await auth.authenticate(token);
    if (!result) throw new HttpError(401, "session_invalid", "Your session has expired. Please sign in again.");
    c.set("user", result.user);
    c.set("session", result.session);
    await next();
  };
}

export function requireAdmin(): MiddlewareHandler<AuthEnv> {
  return async (c, next) => {
    const user = c.get("user");
    if (!user || user.role !== "admin") throw new HttpError(403, "forbidden", "Admin access required.");
    await next();
  };
}
