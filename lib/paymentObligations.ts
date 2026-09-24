import { buildResidentFinancialSummary, type FinancialRow, type ResidentFinancialSummary } from "./residentFinancialSummary";
import { combinedPaymentAllocations } from "./paymentAllocations";

export function combinedPaymentPreview(summary: ResidentFinancialSummary) {
  const allocations = [
    { purpose: "Rent", amount: summary.monthlyRentDue },
    { purpose: "Security Deposit", amount: summary.depositBalance },
  ].filter(item => item.amount > 0);
  return {
    allocations,
    total: Math.round(allocations.reduce((sum, item) => sum + item.amount, 0) * 100) / 100,
    canSubmit: allocations.length === 2,
  };
}

export function combinedPaymentAllocationError(
  summary: ResidentFinancialSummary,
  submittedAmount: number,
) {
  return combinedPaymentAllocations(
    summary.monthlyRentDue,
    summary.depositBalance,
    submittedAmount,
  )
    ? null
    : "Combined payment must equal the exact current Rent + Security Deposit balance. Submit partial amounts through the individual options.";
}

/** Staff preview uses exactly the same discount/payment allocation as the account summary. */
export function receiptAllocation(bill: FinancialRow, payments: FinancialRow[], amount: number) {
  const admission = { id: bill.admission_id, status: "Active", monthly_rent: 0, security_deposit: 0, deposit_status: "Pending" };
  const input = { admission, room: null, bed: null, bills: [bill], payments };
  const before = buildResidentFinancialSummary(input);
  const after = buildResidentFinancialSummary({ ...input, payments: [...payments, { bill_id: bill.id, amount, payment_status: "Verified" }] });
  const rent = Math.round((before.monthlyRentDue - after.monthlyRentDue) * 100) / 100;
  const deposit = Math.round((before.depositBalance - after.depositBalance) * 100) / 100;
  return { rent, deposit, other: Math.round((amount - rent - deposit) * 100) / 100, exceedsBalance: amount > before.totalOutstanding };
}

/** A receipt pays one bill and one currently outstanding obligation. Rent is
 * allocated first; other charges become selectable after that rent is cleared. */
export function billPaymentObligation(bill: FinancialRow, payments: FinancialRow[]) {
  const summary = buildResidentFinancialSummary({
    admission: { id: bill.admission_id, status: "Active", monthly_rent: 0, security_deposit: 0, deposit_status: "Pending" },
    room: null, bed: null, bills: [bill], payments,
  });
  if (bill.bill_type === "Security Deposit") return { purpose: "Security Deposit", amount: summary.depositBalance };
  if (summary.monthlyRentDue > 0) return { purpose: "Rent", amount: summary.monthlyRentDue };
  return { purpose: "Other Charges", amount: summary.totalOutstanding };
}

export function receiptPurposeError(bill: FinancialRow, payments: FinancialRow[], amount: number, purpose: string) {
  if (purpose === "Rent + Security Deposit") return "Combined payments must be submitted through the combined payment flow.";
  const obligation = billPaymentObligation(bill, payments);
  if (purpose && purpose !== obligation.purpose) return "The receipt purpose no longer matches the outstanding obligation. Review the receipt before proceeding.";
  if (!Number.isFinite(amount) || amount <= 0 || amount > obligation.amount) return "The receipt amount exceeds the selected obligation or is invalid.";
  return null;
}
