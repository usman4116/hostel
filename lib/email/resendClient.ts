import "server-only";

import { Resend } from "resend";
import { gmailSenderConfigured, sendGmailEmail } from "@/lib/email/gmailClient";

export type EmailDispatchStatus =
  | "sent"
  | "skipped"
  | "configuration_required"
  | "failed";

export type EmailDispatchResult = {
  status: EmailDispatchStatus;
  providerMessageId: string | null;
  error: string | null;
};

export type EmailRequest = {
  to: string;
  subject: string;
  html: string;
  text: string;
  /** Stable key so a retried approval never double-sends the same bill email. */
  idempotencyKey?: string;
};

function text(value: unknown) {
  return String(value ?? "").trim();
}

let cachedClient: Resend | null = null;

function resendClient(apiKey: string) {
  if (!cachedClient) cachedClient = new Resend(apiKey);
  return cachedClient;
}

export function emailSenderConfigured() {
  return Boolean(
    (text(process.env.RESEND_API_KEY) && text(process.env.NOTIFICATION_EMAIL_FROM)) ||
      gmailSenderConfigured(),
  );
}

export function emailFromAddress() {
  const fromAddress = text(process.env.NOTIFICATION_EMAIL_FROM);
  const fromName = text(process.env.NOTIFICATION_EMAIL_FROM_NAME) || "StayHub";
  return fromAddress ? `${fromName} <${fromAddress}>` : "";
}

/** Sends one transactional email through the Resend SDK, with automatic fallback to Gmail SMTP if Resend sandbox rejects the recipient. Never throws. */
export async function sendTransactionalEmail(
  request: EmailRequest,
): Promise<EmailDispatchResult> {
  const recipient = text(request.to).toLowerCase();
  if (!recipient) {
    return { status: "skipped", providerMessageId: null, error: "recipient_email_missing" };
  }

  const apiKey = text(process.env.RESEND_API_KEY);
  const from = emailFromAddress();
  const resendConfigured = Boolean(apiKey && from);
  const gmailConfigured = gmailSenderConfigured();

  if (!resendConfigured && !gmailConfigured) {
    return {
      status: "configuration_required",
      providerMessageId: null,
      error: "resend_configuration_missing",
    };
  }

  let resendError: string | null = null;

  if (resendConfigured) {
    try {
      const { data, error } = await resendClient(apiKey).emails.send(
        {
          from,
          to: [recipient],
          subject: request.subject,
          html: request.html,
          text: request.text,
        },
        request.idempotencyKey ? { idempotencyKey: request.idempotencyKey } : undefined,
      );

      if (!error) {
        return { status: "sent", providerMessageId: text(data?.id) || null, error: null };
      }

      resendError = text(error.message) || "resend_send_failed";
      console.warn("[email] Resend rejected the message.", {
        name: error.name,
        message: error.message,
      });
    } catch (caught) {
      resendError =
        caught instanceof Error && caught.message.trim()
          ? caught.message
          : "resend_send_failed";
      console.warn("[email] Resend request failed.", { message: resendError });
    }
  }

  if (gmailConfigured) {
    try {
      const gmailResult = await sendGmailEmail({
        to: recipient,
        subject: request.subject,
        text: request.text,
        html: request.html,
      });
      console.info("[email] Delivered via Gmail SMTP fallback.", {
        to: recipient,
        messageId: gmailResult.messageId,
      });
      return {
        status: "sent",
        providerMessageId: gmailResult.messageId,
        error: null,
      };
    } catch (gmailCaught) {
      const gmailMessage =
        gmailCaught instanceof Error && gmailCaught.message.trim()
          ? gmailCaught.message
          : "gmail_send_failed";
      console.warn("[email] Gmail fallback failed.", { message: gmailMessage });
      return {
        status: "failed",
        providerMessageId: null,
        error: resendError || gmailMessage,
      };
    }
  }

  return {
    status: "failed",
    providerMessageId: null,
    error: resendError || "resend_send_failed",
  };
}

