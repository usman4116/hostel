import "server-only";

import nodemailer from "nodemailer";

function text(value: unknown) {
  return String(value ?? "").trim();
}

export function gmailSenderConfigured() {
  return Boolean(text(process.env.GMAIL_USER) && text(process.env.GMAIL_APP_PASSWORD));
}

export async function sendGmailEmail(input: {
  to: string;
  subject: string;
  text: string;
  html?: string;
}) {
  const user = text(process.env.GMAIL_USER);
  const password = text(process.env.GMAIL_APP_PASSWORD);

  if (!user || !password) {
    throw new Error("gmail_configuration_missing");
  }

  const transporter = nodemailer.createTransport({
    service: "gmail",
    auth: {
      user,
      pass: password,
    },
  });

  const fromName = text(process.env.NOTIFICATION_EMAIL_FROM_NAME) || "University Girls Hostel";

  const result = await transporter.sendMail({
    from: `${fromName} <${user}>`,
    to: input.to,
    subject: input.subject,
    text: input.text,
    html: input.html,
  });

  return {
    messageId: result.messageId || null,
  };
}
