import Stripe from "stripe";
import { HttpError } from "../http/HttpError.js";

/**
 * Turns transient Stripe failures into a stable billing_unavailable error.
 * Connection and rate limit errors mean "try again" (503); an error Stripe
 * itself reports is a bad gateway (502). Anything else (invalid request,
 * authentication, permission) points at our own configuration or code and
 * stays an internal error.
 */
export class StripeErrorTranslator {
  static toHttpError(error: unknown): HttpError | null {
    if (!(error instanceof Stripe.errors.StripeError)) return null;
    switch (error.type) {
      case "StripeConnectionError":
      case "StripeRateLimitError":
        return new HttpError(503, "billing_unavailable", "The billing provider is unavailable. Try again shortly.");
      case "StripeAPIError":
        return new HttpError(502, "billing_unavailable", "The billing provider returned an error. Try again shortly.");
      default:
        return null;
    }
  }
}
