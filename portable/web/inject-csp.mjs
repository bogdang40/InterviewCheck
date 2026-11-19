import { createHash } from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const require = createRequire(import.meta.url);
const { buildCustomRoute } = require("next/dist/server/lib/router-utils/filesystem");

const STATIC_ASSET_CSP = "default-src 'none'; frame-ancestors 'none'";
const SCRIPT_RE = /<script\b([^>]*)>([\s\S]*?)<\/script>/gi;
const SRC_ATTR_RE = /(?:^|\s)src\s*=/i;

function extractScriptHashes(htmlPath) {
  const html = fs.readFileSync(htmlPath, "utf8");
  const hashes = [];
  const seen = new Set();
  for (const match of html.matchAll(SCRIPT_RE)) {
    const [, attrs, body] = match;
    if (SRC_ATTR_RE.test(attrs) || !body) continue;
    const token = `'sha256-${createHash("sha256").update(body, "utf8").digest("base64")}'`;
    if (!seen.has(token)) {
      seen.add(token);
      hashes.push(token);
    }
  }
  return hashes;
}

function buildHtmlCsp(hashes) {
  const scriptSrc = hashes.length ? `'self' ${hashes.join(" ")}` : "'self'";
  return (
    `default-src 'self'; script-src ${scriptSrc}; style-src 'self' 'unsafe-inline'; ` +
    "img-src 'self' data: blob:; font-src 'self'; media-src 'self' blob:; " +
    "connect-src 'self' ws: wss:; object-src 'none'; base-uri 'self'; " +
    "form-action 'self'; frame-ancestors 'none'; report-uri /api/csp-report"
  );
}

function collectHtmlFiles(dir, prefix = "") {
  const entries = [];
  if (!fs.existsSync(dir)) return entries;
  for (const item of fs.readdirSync(dir, { withFileTypes: true })) {
    const rel = prefix ? `${prefix}/${item.name}` : item.name;
    const full = path.join(dir, item.name);
    if (item.isDirectory()) entries.push(...collectHtmlFiles(full, rel));
    else if (item.isFile() && item.name.endsWith(".html")) entries.push({ rel, full });
  }
  return entries;
}

function main() {
  const distDir = path.resolve(process.cwd(), process.env.INTERVIEWCHECK_NEXT_DIST_DIR || ".next-server");
  const manifestPath = path.join(distDir, "routes-manifest.json");
  if (!fs.existsSync(manifestPath)) {
    throw new Error(`Missing routes-manifest.json at ${manifestPath}`);
  }
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  const appDir = path.join(distDir, "server", "app");
  const htmlFiles = collectHtmlFiles(appDir);

  let fallbackHashes = [];
  const routeRules = [];
  for (const { rel, full } of htmlFiles) {
    if (rel === "_global-error.html") continue;
    const hashes = extractScriptHashes(full);
    if (rel === "_not-found.html") {
      fallbackHashes = hashes;
      continue;
    }
    const source = rel === "index.html" ? "/" : `/${rel.slice(0, -5)}`;
    routeRules.push(
      buildCustomRoute("header", { source, headers: [{ key: "Content-Security-Policy", value: buildHtmlCsp(hashes) }] }, "", false)
    );
  }

  const fallbackCsp = buildHtmlCsp(fallbackHashes);
  const existing = (Array.isArray(manifest.headers) ? manifest.headers : []).filter(
    (rule) =>
      rule.source !== "/_next/:path*" &&
      !routeRules.some((r) => r.source === rule.source)
  );
  const updatedBase = existing.map((rule) => ({
    ...rule,
    headers: rule.headers.map((h) =>
      h.key.toLowerCase() === "content-security-policy" ? { ...h, value: fallbackCsp } : h
    ),
  }));
  const staticRule = buildCustomRoute(
    "header",
    { source: "/_next/:path*", headers: [{ key: "Content-Security-Policy", value: STATIC_ASSET_CSP }] },
    "",
    false
  );
  manifest.headers = [...updatedBase, staticRule, ...routeRules];
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n", "utf8");
}

main();
