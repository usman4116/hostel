import "server-only";

import { sendTransactionalEmail } from "@/lib/email/resendClient";
import { gmailSenderConfigured, sendGmailEmail } from "@/lib/email/gmailClient";

export type ResidentCredentialsEmailDetails = {
  residentName: string;
  email: string;
  temporaryPassword: string;
  portalLoginUrl: string;
  hostelName?: string;
  isReset?: boolean;
};

function escapeHtml(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export function buildResidentCredentialsEmail(
  details: ResidentCredentialsEmailDetails,
) {
  const hostelName =
    details.hostelName?.trim() ||
    process.env.NEXT_PUBLIC_HOSTEL_NAME?.trim() ||
    "University Girls Hostel";
  const actionLabel = details.isReset
    ? "Your Resident Portal password has been reset"
    : "Your Resident Portal account has been created";
  const subject = details.isReset
    ? `${hostelName} — Resident Portal Password Reset`
    : `Welcome to ${hostelName} — Your Resident Portal Login Credentials`;

  const text = [
    `Hello ${details.residentName || "Resident"},`,
    "",
    `${actionLabel}. Use the credentials below to sign in to the Resident Portal:`,
    "",
    `Login Email: ${details.email}`,
    `Temporary Password: ${details.temporaryPassword}`,
    `Resident Portal Login: ${details.portalLoginUrl}`,
    "",
    "For your security, you will be asked to set a new password when you first sign in.",
    "",
    hostelName,
  ].join("\n");

  const html = `<!doctype html>
<html lang="en">
  <body style="margin:0;padding:24px;background:#f1f5f9;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:#0f172a">
    <table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;max-width:600px;margin:0 auto;background:#ffffff;border-radius:16px;overflow:hidden;border:1px solid #e2e8f0">
      <tr>
        <td style="padding:24px 28px;background:#4338ca;color:#ffffff">
          <p style="margin:0;font-size:12px;letter-spacing:0.18em;text-transform:uppercase;opacity:0.85">${escapeHtml(hostelName)}</p>
          <h1 style="margin:6px 0 0;font-size:22px;font-weight:700">Resident Portal Credentials</h1>
        </td>
      </tr>
      <tr>
        <td style="padding:28px">
          <p style="margin:0 0 16px;font-size:15px">Hello ${escapeHtml(details.residentName || "Resident")},</p>
          <p style="margin:0 0 20px;font-size:14px;color:#475569;line-height:1.6">
            ${escapeHtml(actionLabel)}. You can now sign in to the Resident Portal using the login details below:
          </p>

          <div style="margin:20px 0;padding:18px 20px;background:#f8fafc;border:1px solid #cbd5e1;border-radius:12px">
            <p style="margin:0 0 10px;font-size:14px;color:#334155">
              <strong>Login Email:</strong> <span style="font-family:monospace;color:#0f172a">${escapeHtml(details.email)}</span>
            </p>
            <p style="margin:0;font-size:14px;color:#334155">
              <strong>Temporary Password:</strong> <span style="font-family:monospace;font-weight:700;color:#4338ca">${escapeHtml(details.temporaryPassword)}</span>
            </p>
          </div>

          <p style="margin:0 0 22px;font-size:13px;color:#64748b;line-height:1.6">
            For your security, please change this temporary password immediately after signing in.
          </p>

          <a href="${escapeHtml(details.portalLoginUrl)}"
             style="display:inline-block;padding:13px 22px;background:#4338ca;color:#ffffff;font-size:14px;font-weight:700;border-radius:12px;text-decoration:none">
            Sign In to Resident Portal
          </a>

          <p style="margin:22px 0 0;font-size:12px;color:#64748b;line-height:1.6">
            Portal URL: <a href="${escapeHtml(details.portalLoginUrl)}" style="color:#4338ca">${escapeHtml(details.portalLoginUrl)}</a>
          </p>
        </td>
      </tr>
      <tr>
        <td style="padding:16px 28px;background:#f8fafc;border-top:1px solid #e2e8f0;font-size:12px;color:#64748b">
          This is an automated account notification from ${escapeHtml(hostelName)}. Do not share your password with anyone.
        </td>
      </tr>
    </table>
  </body>
</html>`;

  return { subject, html, text };
}

export async function sendResidentCredentialsEmail(
  details: ResidentCredentialsEmailDetails,
): Promise<{ sent: boolean; provider: "resend" | "gmail" | null; error: string | null }> {
  const { subject, html, text } = buildResidentCredentialsEmail(details);

  const resendDispatch = await sendTransactionalEmail({
    to: details.email,
    subject,
    html,
    text,
  });

  if (resendDispatch.status === "sent") {
    return { sent: true, provider: "resend", error: null };
  }

  if (gmailSenderConfigured()) {
    try {
      await sendGmailEmail({
        to: details.email,
        subject,
        text,
        html,
      });
      return { sent: true, provider: "gmail", error: null };
    } catch (gmailError) {
      return {
        sent: false,
        provider: null,
        error:
          gmailError instanceof Error
            ? gmailError.message
            : resendDispatch.error || "Failed to send credentials email.",
      };
    }
  }

  return {
    sent: false,
    provider: null,
    error: resendDispatch.error || "Email configuration is required.",
  };
}
