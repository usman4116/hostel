import { supabase } from "@/lib/supabase";
import { roundMoney, type BillLifecycleStatus } from "./financialMath";
export { deriveBillStatus, roundMoney, type BillLifecycleStatus } from "./financialMath";

export async function getVerifiedPaymentTotal(
  billId: string,
  excludePaymentId?: string,
) {
  let paymentQuery = supabase
    .from("payments")
    .select("id, bill_id, amount")
    .eq("payment_status", "Verified");

  if (excludePaymentId) paymentQuery = paymentQuery.neq("id", excludePaymentId);

  let allocationQuery = supabase.from("payment_allocations").select("payment_id, amount").eq("bill_id", billId);
  if (excludePaymentId) allocationQuery = allocationQuery.neq("payment_id", excludePaymentId);

  const [{ data: payments, error: paymentError }, { data: allocations, error: allocationError }] = await Promise.all([
    paymentQuery,
    allocationQuery,
  ]);
  if (paymentError) throw paymentError;
  if (allocationError) throw allocationError;

  const effectivePaymentIds = new Set((payments ?? []).map((payment) => String(payment.id)));
  const effectiveAllocations = (allocations ?? []).filter((allocation) => effectivePaymentIds.has(String(allocation.payment_id)));
  const allocatedPaymentIds = new Set(effectiveAllocations.map((allocation) => String(allocation.payment_id)));
  const allocatedTotal = effectiveAllocations.reduce((sum, allocation) => sum + Number(allocation.amount ?? 0), 0);
  const legacyTotal = (payments ?? [])
    .filter((payment) => payment.bill_id === billId && !allocatedPaymentIds.has(String(payment.id)))
    .reduce((sum, payment) => sum + Number(payment.amount ?? 0), 0);

  return roundMoney(allocatedTotal + legacyTotal);
}

/** Reconcile against the ledger inside the database transaction, not a browser snapshot. */
export async function refreshBillFinancials(billId: string) {
  const { data, error } = await supabase.rpc("refresh_bill_financials", { p_bill_id: billId });
  if (error) throw error;
  if (!data) throw new Error("The bill could not be reconciled.");
  return data as { paid: number; balance: number; status: BillLifecycleStatus; total: number };
}
