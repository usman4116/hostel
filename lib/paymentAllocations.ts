import { roundMoney } from "./financialMath";

export type CombinedPaymentAllocation = {
  purpose: "Rent" | "Security Deposit";
  amount: number;
};

export function combinedPaymentAllocations(
  rentOutstanding: number,
  depositOutstanding: number,
  submittedAmount: number,
): CombinedPaymentAllocation[] | null {
  const rent = roundMoney(Number(rentOutstanding));
  const deposit = roundMoney(Number(depositOutstanding));
  const amount = roundMoney(Number(submittedAmount));
  const total = roundMoney(rent + deposit);

  if (!Number.isFinite(rent) || !Number.isFinite(deposit) || !Number.isFinite(amount)) return null;
  if (rent <= 0 || deposit <= 0 || amount !== total) return null;

  return [
    { purpose: "Rent", amount: rent },
    { purpose: "Security Deposit", amount: deposit },
  ];
}

export function allocationTotal(allocations: Array<{ amount: number }>) {
  return roundMoney(allocations.reduce((sum, allocation) => sum + Number(allocation.amount || 0), 0));
}

export function paymentBillAmounts(
  payment: { amount?: number; bill_id?: string | null; payment_status?: string },
  allocations: Array<{ bill_id: string; amount: number }>,
) {
  if (payment.payment_status !== "Verified") return [];
  if (allocations.length) return allocations;
  if (!payment.bill_id || payment.payment_status !== "Verified") return [];
  return [{ bill_id: payment.bill_id, amount: Number(payment.amount || 0) }];
}
