export type ContractReadinessRecord = {
  status?: string | null;
  resident_signature_url?: string | null;
  resident_signature_status?: string | null;
  signed_by_resident?: boolean | null;
  signed_at?: string | null;
  contract_content?: string | null;
};

export function getContractTerms(contract: ContractReadinessRecord) {
  return (contract.contract_content || "").trim();
}

export function hasResidentSignature(contract: ContractReadinessRecord) {
  return Boolean(
    (contract.resident_signature_url) &&
      ["Submitted", "Approved", "Signed"].includes(
        contract.resident_signature_status ?? "",
      ) &&
      contract.signed_by_resident &&
      contract.signed_at,
  );
}

export function isResidentSignatureApproved(
  contract: ContractReadinessRecord | null | undefined,
) {
  return Boolean(
    contract &&
      contract.resident_signature_status === "Approved" &&
      hasResidentSignature(contract),
  );
}

export function isContractSignedAndAccepted(
  contract: ContractReadinessRecord | null | undefined,
) {
  return Boolean(
    contract &&
      ["Pending Signature", "Active"].includes(contract.status ?? "") &&
      isResidentSignatureApproved(contract) &&
      getContractTerms(contract),
  );
}

export function isDepositVerified(status: string | null | undefined) {
  return status === "Held";
}

export function isAdmissionReadyForActivation(
  depositStatus: string | null | undefined,
  contract: ContractReadinessRecord | null | undefined,
) {
  return contract?.status === "Pending Signature" && isDepositVerified(depositStatus) && isContractSignedAndAccepted(contract);
}
