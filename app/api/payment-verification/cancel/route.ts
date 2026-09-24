import { normalizeIdentityEmail } from "@/lib/identity";
import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { supabaseAdmin } from "@/lib/supabaseAdmin";

const ALLOWED_ROLES = new Set(["super admin", "admin", "accountant"]);

function response(error: string, status: number) {
  return NextResponse.json({ error }, { status, headers: { "Cache-Control": "private, no-store" } });
}

export async function POST(request: NextRequest) {
  const header = request.headers.get("authorization") ?? "";
  const token = header.toLowerCase().startsWith("bearer ") ? header.slice(7).trim() : "";
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!token || !url || !key) return response("Your admin session could not be verified.", 401);
  const auth = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: authData, error: authError } = await auth.auth.getUser(token);
  const email = authData.user?.email?.trim().toLowerCase() ?? "";
  if (authError || !email) return response("Your admin session could not be verified.", 401);
  const { data: staff, error: staffError } = await supabaseAdmin.from("staff_users").select("role,status").eq("email", normalizeIdentityEmail(email)).maybeSingle();
  if (staffError || !staff || String(staff.status).toLowerCase() !== "active" || !ALLOWED_ROLES.has(String(staff.role).toLowerCase())) return response("You do not have permission to cancel payments.", 403);
  const body = await request.json().catch(() => null) as { paymentId?: unknown; reason?: unknown } | null;
  const paymentId = typeof body?.paymentId === "string" ? body.paymentId.trim() : "";
  const reason = typeof body?.reason === "string" ? body.reason.trim().slice(0, 2000) : "Payment cancelled by staff.";
  if (!paymentId) return response("A payment is required.", 400);
  const { data, error } = await supabaseAdmin.rpc("cancel_payment_with_allocations", { p_payment_id: paymentId, p_actor: email, p_reason: reason || "Payment cancelled by staff." });
  if (error || !data) return response(error?.message || "The payment could not be cancelled.", 409);
  return NextResponse.json({ message: "Payment cancelled and affected balances recalculated.", data }, { headers: { "Cache-Control": "private, no-store" } });
}
