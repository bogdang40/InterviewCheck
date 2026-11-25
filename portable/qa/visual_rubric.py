"""Shared visual hierarchy, contrast, layout, and mobile touch-target rubric for QA."""

ADMIN_TABS = (
    "Models", "Accounts", "Usage", "Audit log", "Diagnostics",
    "Playground", "Security", "Prompts & SLA", "Compliance",
)

TOKEN_CONTRAST_KEYS = (
    "ink_on_surface", "muted_on_surface", "secondary_on_surface",
    "green_ink_on_selected", "error_on_error_bg", "attention_on_warning_bg",
)

AUDIT_JS = """() => {
  const doc = document.documentElement;
  const scrollWidth = doc.scrollWidth, clientWidth = doc.clientWidth;
  const isVisible = (el) => {
    const cs = getComputedStyle(el);
    if (cs.display === "none" || cs.visibility === "hidden" || el.closest(".sr-only, [hidden]")) return false;
    // A collapsed <details> keeps a layout box for its content, but it cannot be seen or tapped.
    if (el.closest("details:not([open])") && !el.closest("summary")) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };
  const clipped = [];
  for (const el of document.querySelectorAll("button, a, input, select, textarea, summary, h1, h2")) {
    if (el.closest('[role="tablist"].admin-tabs') || !isVisible(el)) continue;
    const r = el.getBoundingClientRect();
    if (r.right > window.innerWidth + 1 || r.left < -1)
      clipped.push({ tag: el.tagName, text: (el.textContent || "").trim().slice(0, 40), left: r.left, right: r.right });
  }
  const tabList = document.querySelector('[role="tablist"].admin-tabs');
  if (tabList) {
    const sRect = tabList.getBoundingClientRect();
    for (const tab of tabList.querySelectorAll('.admin-tab[aria-selected="true"]')) {
      if (!isVisible(tab)) continue;
      const tRect = tab.getBoundingClientRect();
      if (tRect.left < sRect.left - 1 || tRect.right > sRect.right + 1)
        clipped.push({ tag: "TAB", text: (tab.textContent || "").trim().slice(0, 40), left: tRect.left, right: tRect.right });
    }
  }
  const overlaps = [];
  const groups = [
    ".studio-actions", ".record-actions", ".role-row", ".sidebar nav",
    ".admin-model-actions", ".admin-header-actions", ".admin-tabs",
    ".brief-bulk-actions", '[aria-label="Assignment queues"]',
  ];
  for (const g of groups) {
    for (const container of document.querySelectorAll(g)) {
      const items = [...container.querySelectorAll("a, button")].filter(isVisible);
      for (let i = 0; i < items.length; i++) {
        for (let j = i + 1; j < items.length; j++) {
          if (items[i].contains(items[j]) || items[j].contains(items[i])) continue;
          const a = items[i].getBoundingClientRect(), b = items[j].getBoundingClientRect();
          const ix = Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left));
          const iy = Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
          if (ix > 1 && iy > 1) overlaps.push({ group: g, ix, iy });
        }
      }
    }
  }
  const canvas = document.createElement("canvas");
  canvas.width = 1; canvas.height = 1;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  const parseColor = (c) => {
    ctx.clearRect(0, 0, 1, 1); ctx.fillStyle = "rgba(0,0,0,0)"; ctx.fillStyle = c; ctx.fillRect(0, 0, 1, 1);
    return [...ctx.getImageData(0, 0, 1, 1).data];
  };
  const blendOver = (c, base) => {
    ctx.clearRect(0, 0, 1, 1); ctx.fillStyle = `rgb(${base[0]},${base[1]},${base[2]})`; ctx.fillRect(0, 0, 1, 1);
    ctx.fillStyle = c; ctx.fillRect(0, 0, 1, 1);
    return [...ctx.getImageData(0, 0, 1, 1).data].slice(0, 3);
  };
  const rgb = (token) => {
    const n = document.createElement("span"); n.style.color = `var(${token})`; document.body.append(n);
    const c = parseColor(getComputedStyle(n).color).slice(0, 3); n.remove(); return c;
  };
  const lum = (c) => c.reduce((acc, v, i) => {
    const s = v / 255;
    return acc + [0.2126, 0.7152, 0.0722][i] * (s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4);
  }, 0);
  const contrastPair = (c1, c2) => {
    const [a, b] = [lum(c1), lum(c2)].sort((x, y) => y - x);
    return Number(((a + 0.05) / (b + 0.05)).toFixed(2));
  };
  const ratio = (fg, bg) => contrastPair(rgb(fg), rgb(bg));
  const surfaceRgb = rgb("--surface");
  const nearestOpaqueBg = (el, includeSelf = false) => {
    const layers = [];
    let cur = includeSelf ? el : el.parentElement;
    while (cur) {
      const bg = getComputedStyle(cur).backgroundColor, rgba = parseColor(bg);
      if (rgba[3] > 0) { layers.push(bg); if (rgba[3] >= 254) break; }
      cur = cur.parentElement;
    }
    let acc = surfaceRgb;
    for (let i = layers.length - 1; i >= 0; i--) acc = blendOver(layers[i], acc);
    return acc;
  };
  const headingEl = document.querySelector("main#main-content h1") || document.querySelector("main#main-content");
  const headingRatio = headingEl
    ? contrastPair(parseColor(getComputedStyle(headingEl).color).slice(0, 3), nearestOpaqueBg(headingEl, true)) : null;
  const bodyRatio = contrastPair(
    parseColor(getComputedStyle(document.body).color).slice(0, 3), nearestOpaqueBg(document.body, true),
  );
  const controlSelector = [
    "select", 'input:not([type="checkbox"]):not([type="radio"]):not([type="hidden"])',
    "textarea", ".search", ".archive-search > span",
    '[data-slot="button"][data-variant="outline"]', ".header-tools .search-launch",
  ].join(", ");
  const controlRatios = [], controlFailures = [];
  for (const el of document.querySelectorAll(controlSelector)) {
    if (!isVisible(el) || el.matches(":disabled")) continue;
    const cs = getComputedStyle(el);
    if (parseFloat(cs.borderTopWidth) <= 0 || cs.borderTopStyle === "none") continue;
    const borderRgba = parseColor(cs.borderTopColor);
    if (borderRgba[3] === 0) continue;
    const bg = nearestOpaqueBg(el, false);
    const borderRgb = borderRgba[3] >= 254 ? borderRgba.slice(0, 3) : blendOver(cs.borderTopColor, bg);
    const borderRatio = contrastPair(borderRgb, bg);
    controlRatios.push(borderRatio);
    if (borderRatio < 3.0) controlFailures.push({
      tag: el.tagName, className: typeof el.className === "string" ? el.className.slice(0, 60) : "",
      text: (el.getAttribute("aria-label") || el.textContent || "").trim().slice(0, 40), ratio: borderRatio,
    });
  }
  const touchTargetFailures = [];
  if (window.innerWidth <= 480) {
    const touchSel = 'button, [role="tab"], .admin-header-actions a, [aria-label="Assignment queues"] button';
    for (const el of document.querySelectorAll(touchSel)) {
      if (!isVisible(el) || (el.matches("[data-slot='badge'], .badge") && !el.querySelector("svg"))) continue;
      const r = el.getBoundingClientRect();
      if (r.height < 43.5) touchTargetFailures.push({
        tag: el.tagName, text: (el.getAttribute("aria-label") || el.textContent || "").trim().slice(0, 40),
        height: Number(r.height.toFixed(1)),
      });
    }
  } else if (window.matchMedia("(pointer: coarse)").matches) {
    // Touch tablets keep the desktop layout, so only shared buttons carry the 44px minimum there.
    for (const el of document.querySelectorAll('[data-slot="button"]')) {
      if (!isVisible(el)) continue;
      const r = el.getBoundingClientRect();
      const iconOnly = (el.getAttribute("data-size") || "").startsWith("icon");
      if (r.height < 43.5 || (iconOnly && r.width < 43.5)) touchTargetFailures.push({
        tag: el.tagName, text: (el.getAttribute("aria-label") || el.textContent || "").trim().slice(0, 40),
        height: Number(r.height.toFixed(1)), width: Number(r.width.toFixed(1)),
      });
    }
  }
  const tableFailures = [];
  if (window.innerWidth <= 480) {
    for (const table of document.querySelectorAll("table")) {
      if (!isVisible(table)) continue;
      const wrap = table.parentElement;
      const wrapOverflow = wrap && wrap !== document.body && wrap.scrollWidth > wrap.clientWidth + 2;
      const tableOverflow = table.scrollWidth > table.clientWidth + 2;
      const label = (table.querySelector("caption")?.textContent || "").trim().slice(0, 40) || "table";
      if (tableOverflow || wrapOverflow) {
        tableFailures.push({
          caption: label, reason: "inner_overflow",
          scrollWidth: wrapOverflow ? wrap.scrollWidth : table.scrollWidth,
          clientWidth: wrapOverflow ? wrap.clientWidth : table.clientWidth,
        });
      }
      const tableDisplay = getComputedStyle(table).display;
      for (const tr of table.querySelectorAll("tr")) {
        const thead = tr.closest("thead");
        if (thead) {
          const hr = thead.getBoundingClientRect();
          if (hr.width <= 4 || hr.height <= 4 || getComputedStyle(thead).clipPath === "inset(50%)") continue;
        }
        if (!isVisible(tr)) continue;
        const cells = [...tr.children].filter((c) => (c.tagName === "TH" || c.tagName === "TD") && isVisible(c));
        if (cells.length >= 3) {
          const minW = Math.min(...cells.map((c) => c.getBoundingClientRect().width));
          if (tableDisplay === "table" || minW < 110) {
            tableFailures.push({
              caption: label, reason: "squished_columns",
              cols: cells.length, minCellWidth: Number(minW.toFixed(1)), display: tableDisplay,
            });
            break;
          }
        }
      }
    }
  }
  return {
    scrollWidth, clientWidth, overflow: scrollWidth > clientWidth,
    clipped_count: clipped.length, clipped, overlap_count: overlaps.length, overlaps,
    touch_target_failures: touchTargetFailures,
    table_failures: tableFailures,
    contrast: {
      ink_on_surface: ratio("--ink", "--surface"), muted_on_surface: ratio("--muted", "--surface"),
      secondary_on_surface: ratio("--secondary-ink", "--surface"), green_ink_on_selected: ratio("--green-ink", "--selected-bg"),
      error_on_error_bg: ratio("--error-text", "--error-bg"), attention_on_warning_bg: ratio("--attention", "--warning-bg"),
      input_border_on_surface: ratio("--color-input", "--surface"), heading_ratio: headingRatio, body_ratio: bodyRatio,
      control_border_min: controlRatios.length ? Math.min(...controlRatios) : null, control_border_failures: controlFailures,
    },
    csp_violations: window.__icCspViolations || [],
    data_theme: doc.dataset.theme || "", color_scheme: getComputedStyle(doc).colorScheme,
  };
}"""


def _contrast_failures(record: dict) -> list[str]:
    contrast = record.get("contrast") or {}
    failures = []
    for key in TOKEN_CONTRAST_KEYS:
        val = contrast.get(key)
        if val is not None and val < 4.5:
            failures.append(f"contrast {key}={val} (< 4.5)")
    for key in ("heading_ratio", "body_ratio"):
        val = contrast.get(key, record.get(key))
        if val is not None and val < 4.5:
            failures.append(f"contrast {key}={val} (< 4.5)")
    input_border = contrast.get("input_border_on_surface")
    if input_border is not None and input_border < 3.0:
        failures.append(f"input_border_on_surface={input_border} (< 3.0)")
    border_min = contrast.get("control_border_min")
    if (border_min is not None and border_min < 3.0) or contrast.get("control_border_failures"):
        failures.append(f"control_border_min={border_min} (< 3.0)")
    return failures


def record_passes_rubric(record: dict) -> list[str]:
    """Return human-readable rubric failure reasons for a single audit record."""
    failures = []
    if record.get("overflow") or record.get("scrollWidth", 0) > record.get("clientWidth", 0):
        failures.append(f"overflow {record.get('scrollWidth')} > {record.get('clientWidth')}")
    clipped = record.get("clipped") or []
    if record.get("clipped_count", len(clipped)) > 0 or clipped:
        failures.append(f"clipped controls ({max(record.get('clipped_count', 0), len(clipped))})")
    overlaps = record.get("overlaps") or []
    if record.get("overlap_count", len(overlaps)) > 0 or overlaps:
        failures.append(f"overlapping controls ({max(record.get('overlap_count', 0), len(overlaps))})")
    failures.extend(_contrast_failures(record))
    if record.get("touch_target_failures"):
        failures.append(f"touch targets < 44px ({len(record['touch_target_failures'])})")
    if record.get("table_failures"):
        failures.append(f"mobile table overflow/squish ({len(record['table_failures'])})")
    c_errs, p_errs, s_errs = record.get("console_errors") or [], record.get("page_errors") or [], record.get("server_errors") or []
    if c_errs or p_errs or s_errs:
        failures.append(f"runtime errors (console={len(c_errs)}, page={len(p_errs)}, server={len(s_errs)})")
    if record.get("csp_violations"):
        failures.append(f"CSP violations ({len(record['csp_violations'])})")
    return failures


def summarize_records(records: list[dict]) -> dict:
    """Aggregate visual rubric pass/fail counts across captured audit records."""
    overflow_f = sum(1 for r in records if r.get("overflow") or r.get("scrollWidth", 0) > r.get("clientWidth", 0))
    clipped_f = sum(1 for r in records if r.get("clipped_count", 0) > 0 or bool(r.get("clipped")))
    overlap_f = sum(1 for r in records if r.get("overlap_count", 0) > 0 or bool(r.get("overlaps")))
    contrast_f = sum(1 for r in records if _contrast_failures(r))
    touch_f = sum(1 for r in records if r.get("touch_target_failures"))
    table_f = sum(1 for r in records if r.get("table_failures"))
    console_f = sum(1 for r in records if r.get("console_errors") or r.get("page_errors") or r.get("server_errors"))
    csp_f = sum(1 for r in records if r.get("csp_violations"))
    border_vals = [
        (r.get("contrast") or {}).get("control_border_min")
        for r in records if (r.get("contrast") or {}).get("control_border_min") is not None
    ]
    total_failures = overflow_f + clipped_f + overlap_f + contrast_f + touch_f + table_f + console_f + csp_f
    return {
        "total_screenshots": len(records),
        "overflow_failures": overflow_f, "clipped_failures": clipped_f, "overlap_failures": overlap_f,
        "contrast_failures": contrast_f, "touch_target_failures": touch_f, "table_failures": table_f,
        "console_error_failures": console_f, "csp_failures": csp_f,
        "control_border_min": min(border_vals, default=None),
        "passed": bool(records) and total_failures == 0 and all(not record_passes_rubric(r) for r in records),
    }
