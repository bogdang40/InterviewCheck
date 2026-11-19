import { z } from "zod";
import { PLANS } from "../domain/Subscription.js";
import { USER_ROLES } from "../domain/User.js";

export const credentialsSchema = z.object({
  email: z.string().trim().email().max(254),
  password: z.string().min(10, "Password must be at least 10 characters.").max(200),
  deviceName: z.string().trim().max(120).optional(),
  adminSecret: z.string().max(200).optional(),
});

export const passwordChangeSchema = z.object({
  currentPassword: z.string().min(10, "Password must be at least 10 characters.").max(200),
  newPassword: z.string().min(10, "Password must be at least 10 characters.").max(200),
});

export const checkoutSchema = z.object({
  plan: z.enum(PLANS),
});

const strictPositiveIntSchema = (label: string, max: number) =>
  z
    .string()
    .trim()
    .regex(/^\d+$/, `${label} must be a positive integer.`)
    .transform(Number)
    .pipe(z.number().int().min(1).max(max));

const strictLimitSchema = strictPositiveIntSchema("Limit", 200);
const strictBeforeIdSchema = strictPositiveIntSchema("beforeId", Number.MAX_SAFE_INTEGER);

const isoOffsetTimestampSchema = z
  .string()
  .datetime({ offset: true, message: "Timestamp must be ISO-8601 with a timezone offset." })
  .refine((value) => !Number.isNaN(Date.parse(value)), { message: "Invalid timestamp." });

export const adminListQuerySchema = z.object({
  q: z.string().trim().max(200).optional(),
  limit: strictLimitSchema.optional(),
  cursor: z.string().max(400).optional(),
});

export const adminAuditQuerySchema = z.object({
  q: z.string().trim().max(200).optional(),
  action: z.string().trim().max(120).optional(),
  actor: z.string().trim().max(128).optional(),
  since: isoOffsetTimestampSchema.optional(),
  until: isoOffsetTimestampSchema.optional(),
  beforeId: strictBeforeIdSchema.optional(),
  limit: strictLimitSchema.optional(),
});

export const uuidParamSchema = z.object({
  id: z.string().uuid("Invalid user id."),
});

export const adminPatchSchema = z
  .object({
    role: z.enum(USER_ROLES).optional(),
    disabled: z.boolean().optional(),
    complimentaryUntil: z.string().datetime({ offset: true }).nullable().optional(),
  })
  .refine((patch) => Object.keys(patch).length > 0, { message: "Provide at least one field to update." });

export type CredentialsBody = z.infer<typeof credentialsSchema>;
export type PasswordChangeBody = z.infer<typeof passwordChangeSchema>;
export type CheckoutBody = z.infer<typeof checkoutSchema>;
export type AdminAuditQuery = z.infer<typeof adminAuditQuerySchema>;
export type AdminPatchBody = z.infer<typeof adminPatchSchema>;
