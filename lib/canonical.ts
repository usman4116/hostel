export type UUID = string;
export type BigintId = string | number;

/** Reject numeric IDs that have already lost precision. */
export function bigintId(value: unknown): string {
  if (typeof value === "number" && !Number.isSafeInteger(value)) throw new Error("Unsafe numeric ID");
  const result = String(value ?? "");
  if (!/^[1-9]\d*$/.test(result)) throw new Error("Invalid numeric ID");
  return result;
}

export function billingMonth(value: unknown): string {
  const result = String(value ?? "").trim();
  if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(result)) throw new Error("Use a valid YYYY-MM billing month");
  return result;
}

export const NOTICE_STATUSES = ["Draft", "Published", "Cancelled", "Archived"] as const;
export const NOTICE_AUDIENCES = ["All Residents", "Selected Residents", "Specific Room", "Specific Resident", "Staff"] as const;
export const CONTRACT_STATUSES = ["Draft", "Pending Signature", "Active", "Expired", "Cancelled", "Terminated"] as const;
export const ADMISSION_STATUSES = ["Pending", "Active", "Completed", "Cancelled", "Archived"] as const;
export const ROOM_STATUSES = ["Available", "Partially Occupied", "Occupied", "Maintenance", "Inactive"] as const;
export const PAYMENT_STATUSES = ["Pending", "Verified", "Rejected", "Cancelled"] as const;
export type NoticeStatus = (typeof NOTICE_STATUSES)[number];
export type NoticeAudience = (typeof NOTICE_AUDIENCES)[number];

export function validDate(value: unknown): value is string {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value) &&
    Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value;
}

export function noticePublicationError(status: string, publishDate: string | null, expiryDate: string | null): string | null {
  if (!NOTICE_STATUSES.some(item => item === status)) return "Choose a valid notice status.";
  if (status === "Published" && !validDate(publishDate)) return "Published notices require a valid publication date.";
  if (publishDate && !validDate(publishDate)) return "Invalid publication date.";
  if (expiryDate && (!validDate(expiryDate) || (publishDate && expiryDate < publishDate))) return "Expiry must be a valid date on or after publication.";
  return null;
}
