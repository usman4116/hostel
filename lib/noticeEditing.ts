import { supabase } from "@/lib/supabase";
import { bigintId, NOTICE_AUDIENCES, noticePublicationError } from "@/lib/canonical";

type NoticeInput = Record<string, unknown> & { audience: string; status: string; publish_date: string | null; expiry_date: string | null };
/** Keep recipient changes unpublished until both notice and recipient records are saved. */
export async function saveNoticeWithRecipients(payload: NoticeInput, recipients: string[], existing?: { id: string; updatedAt: string }) {
  const invalid = noticePublicationError(payload.status, payload.publish_date, payload.expiry_date);
  if (invalid) throw new Error(invalid);
  if (!NOTICE_AUDIENCES.some(a => a === payload.audience)) throw new Error("Choose a valid audience.");
  const uniqueRecipients = [...new Set(recipients)];
  if (payload.audience === "Selected Residents" && !uniqueRecipients.length) throw new Error("Select at least one resident.");
  if (payload.audience === "Staff" && !payload.staff_id) throw new Error("Select a staff member.");
  if (payload.audience === "Specific Room" && !payload.room_id) throw new Error("Select a room.");
  if (payload.audience === "Specific Resident" && !payload.resident_id) throw new Error("Select a resident.");
  if (existing && !existing.updatedAt) throw new Error("Reload the notice before editing.");
  const staged = { ...payload, status: "Draft", updated_at: new Date().toISOString() };
  const result = existing
    ? await supabase.from("notices").update(staged).eq("id", bigintId(existing.id)).eq("updated_at", existing.updatedAt).neq("status", "Archived").select("id::text, updated_at").maybeSingle()
    : await supabase.from("notices").insert(staged).select("id::text, updated_at").single();
  if (result.error || !result.data) throw new Error("Notice changed or could not be saved. Reload before retrying.");
  const id = bigintId(result.data.id);
  const { error: clearError } = await supabase.from("notice_recipients").delete().eq("notice_id", id);
  if (clearError) throw new Error("Notice remains Draft: recipients could not be updated. Reload before retrying.");
  if (payload.audience === "Selected Residents") {
    const { error } = await supabase.from("notice_recipients").insert(uniqueRecipients.map(resident_id => ({ notice_id: id, resident_id })));
    if (error) throw new Error("Notice remains Draft: selected recipients could not be saved. Reload before retrying.");
  }
  const { data: completed, error: completionError } = await supabase.from("notices")
    .update({ status: payload.status, updated_at: new Date().toISOString() })
    .eq("id", id).eq("status", "Draft").eq("updated_at", result.data.updated_at).select("id::text").maybeSingle();
  if (completionError || !completed) throw new Error("Notice changed while recipients were saved. Reload and review its status before publishing.");
  return { id };
}
