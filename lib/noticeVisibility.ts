import { bigintId, validDate } from "./canonical";

export type NoticeVisibilityRecord = {
  id: string | number;
  audience?: string | null;
  resident_id?: string | null;
  room_id?: string | null;
  status?: string | null;
  publish_date?: string | null;
  expiry_date?: string | null;
  priority?: string | null;
  created_at?: string | null;
  show_as_popup?: boolean | null;
};

const normalized = (value: unknown) =>
  value == null ? "" : String(value).trim().toLowerCase();

export const currentNoticeDate = () => new Date().toISOString().slice(0, 10);

export function isNoticeVisibleToResident(
  notice: NoticeVisibilityRecord,
  residentId: string,
  roomId: string,
  currentDate = currentNoticeDate(),
  selectedNoticeIds: ReadonlySet<string> = new Set(),
) {
  try { bigintId(notice.id); } catch { return false; }
  if (!residentId) return false;
  if (normalized(notice.status) !== "published") {
    return false;
  }

  if (!validDate(notice.publish_date) || notice.publish_date > currentDate) return false;
  if (notice.expiry_date && (!validDate(notice.expiry_date) || notice.expiry_date < notice.publish_date || notice.expiry_date < currentDate)) return false;

  const audience = normalized(notice.audience);

  if (audience === "all residents") return true;
  if (audience === "selected residents") return selectedNoticeIds.has(String(notice.id));
  if (
    audience === "specific resident"
  ) {
    return notice.resident_id === residentId;
  }
  if (
    audience === "specific room"
  ) {
    return Boolean(roomId) && notice.room_id === roomId;
  }

  return false;
}

const priorityRank: Record<string, number> = {
  urgent: 5,
  high: 4,
  medium: 3,
  normal: 2,
  low: 1,
};

export function compareNoticeProminence(
  left: NoticeVisibilityRecord,
  right: NoticeVisibilityRecord,
) {
  const priorityDifference =
    (priorityRank[normalized(right.priority)] ?? 0) -
    (priorityRank[normalized(left.priority)] ?? 0);

  if (priorityDifference !== 0) return priorityDifference;

  const publishDateDifference = (right.publish_date || "").localeCompare(
    left.publish_date || "",
  );
  if (publishDateDifference !== 0) return publishDateDifference;

  const createdDateDifference = (right.created_at || "").localeCompare(
    left.created_at || "",
  );
  if (createdDateDifference !== 0) return createdDateDifference;

  return String(right.id).length - String(left.id).length || String(right.id).localeCompare(String(left.id));
}
