// Usage section for the homepage: stat line, heatmap and range toggle, rendered from
// agentdeck/data.json (schema agentdeck.usage/v1). The full view lives at agentdeck/index.html.
"use strict";
(() => {
  const root = document.getElementById("agentdeck-usage");
  if (!root) return;
  const SOURCES = { claude_code: "Claude Code", codex: "Codex" };
  let data = null;
  let range = "all";

  const el = (tag, cls, text) => {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  const compact = (n) => {
    const units = [[1e12, "T"], [1e9, "B"], [1e6, "M"], [1e3, "K"]];
    let i = units.findIndex(([s]) => Math.abs(n) >= s);
    if (i < 0) return String(n);
    if (Math.abs(n) / units[i][0] >= 999.5 && i > 0) i -= 1;
    const scaled = n / units[i][0];
    return (Math.abs(scaled) < 99.95 ? scaled.toFixed(1) : scaled.toFixed(0)).replace(/\.0$/, "") + units[i][1];
  };
  const number = (n) => n.toLocaleString("en-US");
  const hourLabel = (h) => `${h % 12 === 0 ? 12 : h % 12} ${h < 12 ? "AM" : "PM"}`;
  const modelName = (m) => {
    const p = m.split("-");
    if (p.length < 3 || p[0] !== "claude") return m;
    const v = [];
    for (const part of p.slice(2)) { if (part.length <= 2 && /^\d+$/.test(part)) v.push(part); else break; }
    return v.length ? `${p[1][0].toUpperCase()}${p[1].slice(1)} ${v.join(".")}` : m;
  };
  const toTime = (d) => Date.UTC(+d.slice(0, 4), +d.slice(5, 7) - 1, +d.slice(8, 10));
  const addDays = (d, n) => new Date(toTime(d) + n * 86400000).toISOString().slice(0, 10);
  const weekday = (d) => new Date(toTime(d)).getUTCDay();
  const dayLabel = (d) => new Date(toTime(d)).toLocaleDateString("en-GB",
    { weekday: "short", day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });

  const stats = el("dl", "usage-stats");
  const ranges = el("div", "usage-ranges");
  const heat = el("div", "usage-heat");
  const tip = el("div", "usage-tip");
  tip.hidden = true;

  function render() {
    for (const b of ranges.children) b.setAttribute("aria-pressed", String(b.dataset.range === range));
    const s = data.summaries[range].all;
    stats.replaceChildren(...[
      ["Sessions", number(s.sessions)],
      ["Messages", number(s.messages)],
      ["Tokens", compact(s.tokens.total)],
      ["Active days", number(s.active_days)],
      ["Peak hour", s.peak_hour == null ? "–" : hourLabel(s.peak_hour)],
      ["Favorite model", s.favorite_model ? modelName(s.favorite_model) : "–", true],
    ].map(([label, value, plain]) => {
      const item = el("div");
      item.append(el("dt", "", label), el("dd", plain ? "plain" : "", value));
      return item;
    }));

    const today = data.generated_on;
    const first = range === "all" ? null : addDays(today, -(range === "30d" ? 29 : 6));
    const byDay = new Map();
    for (const row of data.daily) {
      if (first && row.date < first) continue;
      const t = row.tokens, total = t.input + t.output + t.cache_read + t.cache_write;
      const e = byDay.get(row.date) || { total: 0, sources: {} };
      e.total += total;
      e.sources[row.source] = (e.sources[row.source] || 0) + total;
      byDay.set(row.date, e);
    }
    const sorted = [...byDay.values()].map((e) => e.total).filter((v) => v > 0).sort((a, b) => a - b);
    const q = sorted.length ? [0.25, 0.5, 0.75].map((p) => sorted[Math.max(0, Math.ceil(p * sorted.length) - 1)]) : [];
    const level = (v) => v <= 0 ? 0 : (q.findIndex((t) => v <= t) + 1 || q.length + 1);

    const currentWeek = addDays(today, -weekday(today));
    const earliest = [...byDay.keys()].sort()[0] || today;
    const weeks = Math.max(26, Math.round((toTime(currentWeek) - toTime(addDays(earliest, -weekday(earliest)))) / 604800000) + 1);
    const start = addDays(currentWeek, -7 * (weeks - 1));
    const cells = [];
    for (let i = 0; i < weeks * 7; i++) {
      const day = addDays(start, i);
      if (day > today) { cells.push(el("i", "empty")); continue; }
      const e = byDay.get(day);
      const cell = el("i", `l${level(e ? e.total : 0)}`);
      cell.dataset.tip = e
        ? [dayLabel(day), `${compact(e.total)} tokens`, ...Object.entries(e.sources).map(([k, v]) => `${SOURCES[k] || k}: ${compact(v)}`)].join("\n")
        : `${dayLabel(day)}\nNo usage`;
      cells.push(cell);
    }
    heat.replaceChildren(...cells);
    heat.scrollLeft = heat.scrollWidth;

  }

  for (const [key, label] of [["all", "All"], ["30d", "30d"], ["7d", "7d"]]) {
    const b = el("button", "", label);
    b.type = "button";
    b.dataset.range = key;
    b.onclick = () => { range = key; render(); };
    ranges.append(b);
  }
  const bar = el("div", "usage-bar");
  bar.append(stats, ranges);

  heat.addEventListener("mouseover", (event) => {
    const target = event.target.closest("[data-tip]");
    tip.hidden = !target;
    if (target) tip.textContent = target.dataset.tip;
  });
  heat.addEventListener("mouseleave", () => { tip.hidden = true; });
  heat.addEventListener("mousemove", (event) => {
    tip.style.left = `${Math.min(event.clientX + 12, window.innerWidth - tip.offsetWidth - 8)}px`;
    tip.style.top = `${event.clientY - tip.offsetHeight - 10}px`;
  });

  fetch("agentdeck/data.json", { cache: "no-cache" })
    .then((r) => { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then((json) => {
      if (json.schema !== "agentdeck.usage/v1") return;
      data = json;
      root.append(bar, heat);
      document.body.append(tip);
      render();
    })
    .catch(() => { root.closest("section")?.remove(); });
})();
