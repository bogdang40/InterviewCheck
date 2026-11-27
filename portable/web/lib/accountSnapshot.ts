export type AccountSnapshot = { email: string; active: boolean; admin?: boolean }

export function readAccountSnapshot(value: unknown): AccountSnapshot {
  const account = value && typeof value === "object" ? value as Record<string, unknown> : null
  if (!account || typeof account.email !== "string" || !account.email || typeof account.active !== "boolean"
      || (account.admin !== undefined && typeof account.admin !== "boolean")) {
    throw new Error("The server did not confirm the account.")
  }
  return { email: account.email, active: account.active, ...(account.admin !== undefined ? { admin: account.admin } : {}) }
}
