import { z } from "zod";
import { PLANS } from "../domain/Subscription.js";
import { USER_ROLES } from "../domain/User.js";

export const credentialsSchema = z.object({
  email: z.string().trim().email().max(254),
  password: z.string().min(10, "Password must be at least 10 characters.").max(200),
  deviceName: z.string().trim().max(120).optional(),
  adminSecret: z.string().max(200).optional(),
});

export const checkoutSchema = z.object({
  plan: z.enum(PLANS),
});

export const adminListQuerySchema = z.object({
  q: z.string().trim().max(200).optional(),
  limit: z.coerce.number().int().min(1).max(200).optional(),
  cursor: z.string().max(400).optional(),
});

export const adminPatchSchema = z
  .object({
    role: z.enum(USER_ROLES).optional(),
    disabled: z.boolean().optional(),
    complimentaryUntil: z.string().datetime({ offset: true }).nullable().optional(),
  })
  .refine((patch) => Object.keys(patch).length > 0, { message: "Provide at least one field to update." });

export type CredentialsBody = z.infer<typeof credentialsSchema>;
export type CheckoutBody = z.infer<typeof checkoutSchema>;
export type AdminPatchBody = z.infer<typeof adminPatchSchema>;
