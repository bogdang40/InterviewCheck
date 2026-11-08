import type { Context } from "hono";
import type { ZodTypeAny, z } from "zod";
import { HttpError } from "./HttpError.js";

/** Parse and validate a JSON body; malformed input becomes a 400 with details. */
export async function parseJsonBody<Schema extends ZodTypeAny>(c: Context, schema: Schema): Promise<z.infer<Schema>> {
  let raw: unknown;
  try {
    raw = await c.req.json();
  } catch {
    throw new HttpError(400, "invalid_json", "Request body must be valid JSON.");
  }
  return validate(schema, raw);
}

export function parseQuery<Schema extends ZodTypeAny>(c: Context, schema: Schema): z.infer<Schema> {
  return validate(schema, c.req.query());
}

function validate<Schema extends ZodTypeAny>(schema: Schema, raw: unknown): z.infer<Schema> {
  const result = schema.safeParse(raw);
  if (!result.success) {
    const first = result.error.issues[0];
    const where = first?.path.length ? `${first.path.join(".")}: ` : "";
    throw new HttpError(400, "validation_failed", `${where}${first?.message ?? "Invalid request."}`);
  }
  return result.data;
}
