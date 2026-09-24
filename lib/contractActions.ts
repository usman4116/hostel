import { normalizeIdentityEmail } from "@/lib/identity";
import { supabase } from "@/lib/supabase";

/** Preflight for the existing staff admission action; database authorization remains mandatory. */
export async function requireContractStaff() {
  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user?.email) throw new Error("Your staff session could not be verified.");
  const { data: staff, error: staffError } = await supabase.from("staff_users")
    .select("role, status").eq("email", normalizeIdentityEmail(data.user.email)).maybeSingle();
  if (staffError || staff?.status !== "Active" || !["super admin", "admin", "manager", "staff"].includes(String(staff.role).toLowerCase())) throw new Error("An active staff or administrator account is required.");
}

export async function reviewContractSignature(contractId: string, action: "Approved" | "Rejected" | "Re-sign Required") {
  const { data, error } = await supabase.auth.getSession();
  if (error || !data.session) throw new Error("Your staff session could not be verified.");
  const response = await fetch("/api/contracts/review", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + data.session.access_token }, body: JSON.stringify({ contractId, action }) });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || "Contract review failed.");
  return result as { resident_signature_status: string };
}
