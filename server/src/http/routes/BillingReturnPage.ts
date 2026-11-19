import { createHash } from "node:crypto";

export const BILLING_RETURN_STYLE = `
  :root { color-scheme: light dark; }
  body { margin: 0; font: 16px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", Helvetica, Arial, sans-serif;
         display: grid; place-items: center; min-height: 100vh; background: #f5f5f7; color: #1d1d1f; }
  @media (prefers-color-scheme: dark) { body { background: #111; color: #f5f5f7; } }
  main { max-width: 28rem; padding: 2rem; text-align: center; }
  h1 { font-size: 1.4rem; margin: 0 0 .5rem; }
  p { margin: .5rem 0; opacity: .85; }
  a.button { display: inline-block; margin-top: 1rem; padding: .6rem 1.2rem; border-radius: 8px;
             background: #0071e3; color: #fff; text-decoration: none; font-weight: 600; }
`;
export const BILLING_RETURN_STYLE_HASH = `sha256-${createHash("sha256").update(BILLING_RETURN_STYLE, "utf8").digest("base64")}`;

/**
 * Minimal, dependency free page shown in the browser after Stripe. It
 * bounces to the desktop app through its URL scheme and tells the person
 * what to do if the bounce did not happen.
 */
export class BillingReturnPage {
  constructor(private readonly appUrlScheme: string) {}

  render(status: string): string {
    const safeStatus = BillingReturnPage.normalize(status);
    const deepLink = `${this.appUrlScheme}://billing/${safeStatus}`;
    const copy = BillingReturnPage.copyFor(safeStatus);
    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="1;url=${deepLink}">
<title>InterviewCheck</title>
<style>${BILLING_RETURN_STYLE}</style>
</head>
<body>
<main>
  <h1>${copy.title}</h1>
  <p>${copy.body}</p>
  <p>You can close this tab and return to InterviewCheck.</p>
  <a class="button" href="${deepLink}">Open InterviewCheck</a>
</main>
</body>
</html>`;
  }

  private static normalize(status: string): "success" | "cancel" | "portal" {
    return status === "cancel" || status === "portal" ? status : "success";
  }

  private static copyFor(status: "success" | "cancel" | "portal"): { title: string; body: string } {
    switch (status) {
      case "success":
        return { title: "Checkout complete", body: "Open InterviewCheck to check whether your subscription is active." };
      case "cancel":
        return { title: "Checkout cancelled", body: "Open InterviewCheck to view your account or continue checkout." };
      case "portal":
        return { title: "Returned from billing", body: "Open InterviewCheck to view your account status." };
    }
  }
}
