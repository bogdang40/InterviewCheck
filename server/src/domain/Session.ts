export interface AuthSession {
  readonly id: string;
  readonly userId: string;
  readonly tokenHash: string;
  readonly deviceName: string | null;
  readonly createdAt: Date;
  readonly expiresAt: Date;
  readonly lastSeenAt: Date;
  readonly revokedAt: Date | null;
}

export class AuthSessionRules {
  /** Sessions are extended when less than half their lifetime remains. */
  static shouldExtend(session: AuthSession, ttlMillis: number, now: Date): boolean {
    const remaining = session.expiresAt.getTime() - now.getTime();
    return remaining < ttlMillis / 2;
  }

  static isUsable(session: AuthSession, now: Date): boolean {
    return session.revokedAt === null && session.expiresAt > now;
  }
}
