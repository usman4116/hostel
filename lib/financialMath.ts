import { isUnapprovedBill } from "./billApproval";

export type BillLifecycleStatus =
  | "Draft"
  | "Pending Approval"
  | "Pending"
  | "Partially Paid"
  | "Paid"
  | "Overdue"
  | "Cancelled";

export function roundMoney(value: number) {
  return Math.round((value + Number.EPSILON) * 100) / 100;
}

export function deriveBillStatus(
  total: number,
  paid: number,
  dueDate: string | null | undefined,
  currentStatus?: string | null,
): BillLifecycleStatus {
  if (currentStatus === "Cancelled") return "Cancelled";

  // A bill awaiting admin approval keeps that status until it is released,
  // so it never ages into Pending or Overdue while still unpublished.
  if (isUnapprovedBill(currentStatus)) {
    return currentStatus as BillLifecycleStatus;
  }

  const balance = Math.max(roundMoney(total - paid), 0);
  if (total > 0 && balance === 0) return "Paid";
  if (paid > 0) return "Partially Paid";

  if (dueDate) {
    const endOfDueDate = new Date(`${dueDate}T23:59:59`);
    if (!Number.isNaN(endOfDueDate.getTime()) && endOfDueDate < new Date()) {
      return "Overdue";
    }
  }

  return "Pending";
}

