import { NextRequest } from "next/server";
import { apiError, apiJson, requireStaff } from "@/lib/adminApiAuth";
import { supabaseAdmin } from "@/lib/supabaseAdmin";
import { getContractTerms, hasResidentSignature } from "@/lib/contractWorkflow";

export async function POST(request: NextRequest) {
  const auth = await requireStaff(request, ["super admin", "admin", "manager", "staff"]);
  if (auth.response) return auth.response;
  const body = await request.json().catch(() => null);
  const action = body?.action;
  if (typeof body?.contractId !== "string" || !["Approved", "Rejected", "Re-sign Required"].includes(action)) return apiError("Invalid contract review.", 400);
  const { data: contract, error } = await supabaseAdmin.from("contracts")
    .select("id, resident_id, admission_id, status, contract_content, resident_signature_url, resident_signature_status, signed_by_resident, signed_at, updated_at")
    .eq("id", body.contractId).maybeSingle();
  if (error || !contract) return apiError("Contract could not be loaded.", 404);
  const { data: admission, error: admissionError } = await supabaseAdmin.from("admissions")
    .select("id, status").eq("id", contract.admission_id).eq("resident_id", contract.resident_id).maybeSingle();
  if (admissionError || admission?.status !== "Pending" || contract.status !== "Pending Signature") return apiError("Only the contract of a Pending admission can be reviewed.", 409);
  const allowed = action === "Re-sign Required" ? ["Submitted", "Signed", "Rejected"] : ["Submitted", "Signed"];
  if (!allowed.includes(contract.resident_signature_status) || (action === "Approved" && (!hasResidentSignature(contract) || !getContractTerms(contract)))) return apiError("A complete submitted signature and contract terms are required for approval.", 409);
  const { data: updated, error: updateError } = await supabaseAdmin.from("contracts")
    .update({ resident_signature_status: action, updated_at: new Date().toISOString() })
    .eq("id", contract.id).eq("admission_id", admission.id).eq("status", "Pending Signature")
    .eq("resident_signature_status", contract.resident_signature_status).eq("updated_at", contract.updated_at)
    .select("resident_signature_status").maybeSingle();
  if (updateError || !updated) return apiError("Contract changed during review. Refresh before retrying.", 409);
  return apiJson(updated);
}
