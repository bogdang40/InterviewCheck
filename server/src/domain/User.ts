export const USER_ROLES = ["user", "admin"] as const;
export type UserRole = (typeof USER_ROLES)[number];

export interface User {
  readonly id: string;
  readonly email: string;
  readonly role: UserRole;
  readonly disabled: boolean;
  readonly trialEndsAt: Date | null;
  readonly complimentaryUntil: Date | null;
  readonly stripeCustomerId: string | null;
  readonly createdAt: Date;
  readonly updatedAt: Date;
  readonly lastLoginAt: Date | null;
}

/** Wire shape returned to clients. Never includes password material. */
export interface PublicUser {
  readonly id: string;
  readonly email: string;
  readonly role: UserRole;
  readonly disabled: boolean;
  readonly createdAt: string;
  readonly trialEndsAt: string | null;
  readonly complimentaryUntil: string | null;
}

export class UserPresenter {
  static toPublic(user: User): PublicUser {
    return {
      id: user.id,
      email: user.email,
      role: user.role,
      disabled: user.disabled,
      createdAt: user.createdAt.toISOString(),
      trialEndsAt: user.trialEndsAt?.toISOString() ?? null,
      complimentaryUntil: user.complimentaryUntil?.toISOString() ?? null,
    };
  }
}

export class EmailNormalizer {
  static normalize(raw: string): string {
    return raw.trim().toLowerCase();
  }
}
