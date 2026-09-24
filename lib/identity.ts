/** Canonical identity equality, shared with normalize_identity_email() in SQL. */
export function normalizeIdentityEmail(value: unknown): string {
  return String(value ?? "").trim().toLowerCase();
}
