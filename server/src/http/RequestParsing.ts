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

/** Like parseJsonBody, but an empty body is validated as `{}`. */
export async function parseOptionalJsonBody<Schema extends ZodTypeAny>(c: Context, schema: Schema): Promise<z.infer<Schema>> {
  const rawText = await c.req.text();
  if (!rawText.trim()) {
    const empty = schema.safeParse({});
    if (empty.success) return empty.data;
    throw new HttpError(400, "invalid_json", "Request body must be valid JSON.");
  }
  let raw: unknown;
  try {
    raw = JSON.parse(rawText);
  } catch {
    throw new HttpError(400, "invalid_json", "Request body must be valid JSON.");
  }
  return validate(schema, raw);
}

export function parseQuery<Schema extends ZodTypeAny>(c: Context, schema: Schema): z.infer<Schema> {
  return validate(schema, c.req.query());
}

export function parseParams<Schema extends ZodTypeAny>(c: Context, schema: Schema): z.infer<Schema> {
  return validate(schema, c.req.param());
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
