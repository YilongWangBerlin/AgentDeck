// Renders data.json (schema agentdeck.usage/v1) produced by the AgentDeck Mac app.
// No build step and no dependencies. Dates are the publisher's local days, handled as plain
// YYYY-MM-DD strings with UTC arithmetic so the viewer's time zone never shifts them.
"use strict";

const SOURCES = { claude_code: "Claude Code", codex: "Codex" };
const HOBBIT_TOKENS = 123500; // about 95,000 words at about 1.3 tokens per word
const MIN_WEEKS = 26;
const state = { tab: "overview", source: "all", range: "all", chartModel: null, cache: true };
let data = null;

const $ = (id) => document.getElementById(id);
const el = (tag, attrs = {}, text) => {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  if (text !== undefined) node.textContent = text;
  return node;
};

// ---------- formatting ----------

function compact(n) {
  const units = [[1e12, "T"], [1e9, "B"], [1e6, "M"], [1e3, "K"]];
  let i = units.findIndex(([scale]) => Math.abs(n) >= scale);
  if (i < 0) return String(n);
  if (Math.abs(n) / units[i][0] >= 999.5 && i > 0) i -= 1;
  const scaled = n / units[i][0];
  const text = Math.abs(scaled) < 99.95 ? scaled.toFixed(1) : scaled.toFixed(0);
  return text.replace(/\.0$/, "") + units[i][1];
}
const number = (n) => n.toLocaleString("en-US");
const hourLabel = (h) => `${h % 12 === 0 ? 12 : h % 12} ${h < 12 ? "AM" : "PM"}`;

function modelName(model) {
  const parts = model.split("-");
  if (parts.length < 3 || parts[0] !== "claude") return model;
  const version = [];
  for (const part of parts.slice(2)) {
    if (part.length <= 2 && /^\d+$/.test(part)) version.push(part); else break;
  }
  return version.length ? `${parts[1][0].toUpperCase()}${parts[1].slice(1)} ${version.join(".")}` : model;
}

// ---------- dates ----------

const toTime = (day) => Date.UTC(+day.slice(0, 4), +day.slice(5, 7) - 1, +day.slice(8, 10));
const toDay = (time) => new Date(time).toISOString().slice(0, 10);
const addDays = (day, n) => toDay(toTime(day) + n * 86400000);
const weekday = (day) => new Date(toTime(day)).getUTCDay(); // 0 = Sunday
const dayLabel = (day) => new Date(toTime(day)).toLocaleDateString("en-GB",
  { weekday: "short", day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });

// ---------- data selection ----------

function rows({ ignoreModel = true } = {}) {
  const today = data.generated_on;
  const first = state.range === "all" ? null : addDays(today, -(state.range === "30d" ? 29 : 6));
  return data.daily.filter((row) =>
    (state.source === "all" || row.source === state.source) &&
    (!first || row.date >= first) &&
    (ignoreModel || !state.chartModel || row.model === state.chartModel));
}

const totalOf = (t) => t.input + t.output + t.cache_read + t.cache_write;

// ---------- rendering ----------

function render() {
  for (const button of document.querySelectorAll("[data-tab]")) {
    button.setAttribute("aria-selected", String(button.dataset.tab === state.tab));
  }
  for (const button of document.querySelectorAll("[data-range]")) {
    button.setAttribute("aria-pressed", String(button.dataset.range === state.range));
  }
  for (const button of document.querySelectorAll("[data-source]")) {
    button.setAttribute("aria-pressed", String(button.dataset.source === state.source));
  }
  $("overview").hidden = state.tab !== "overview";
  $("models").hidden = state.tab !== "models";
  if (state.tab === "overview") { renderStats(); renderHeatmap(); } else { renderModels(); renderChart(); }
}

function renderStats() {
  const s = data.summaries[state.range][state.source];
  const cards = [
    ["Sessions", number(s.sessions)],
    ["Messages", number(s.messages), "Model responses, each counted once"],
    ["Total tokens", compact(s.tokens.total), "Input, output and cache tokens, each response counted once"],
    ["Active days", number(s.active_days)],
    ["Peak hour", s.peak_hour == null ? "–" : hourLabel(s.peak_hour), "Local hour with the most responses"],
    ["Favorite model", s.favorite_model ? modelName(s.favorite_model) : "–", "Model with the most tokens", true],
  ];
  $("stats").replaceChildren(...cards.map(([label, value, help, plain]) => {
    const card = el("div", { class: "stat" });
    if (help) card.title = help;
    card.append(el("div", { class: "label" }, label), el("div", { class: plain ? "value plain" : "value" }, value));
    return card;
  }));
  const books = Math.round(s.tokens.total / HOBBIT_TOKENS);
  $("fun").textContent = books >= 1 ? `That's about ${number(books)}× The Hobbit.` : "";
  $("fun").title = "The Hobbit is about 123,500 tokens: about 95,000 words at about 1.3 tokens per word.";
}

function quantiles(values) {
  const sorted = [...values].sort((a, b) => a - b);
  if (!sorted.length) return [];
  return [0.25, 0.5, 0.75].map((q) => sorted[Math.max(0, Math.ceil(q * sorted.length) - 1)]);
}

function renderHeatmap() {
  const byDay = new Map();
  for (const row of rows()) {
    const entry = byDay.get(row.date) || { total: 0, sources: {}, input: 0, output: 0, cache: 0 };
    const t = row.tokens;
    entry.total += totalOf(t);
    entry.sources[row.source] = (entry.sources[row.source] || 0) + totalOf(t);
    entry.input += t.input; entry.output += t.output; entry.cache += t.cache_read + t.cache_write;
    byDay.set(row.date, entry);
  }
  const thresholds = quantiles([...byDay.values()].map((e) => e.total).filter((v) => v > 0));
  const level = (v) => v <= 0 ? 0 : (thresholds.findIndex((t) => v <= t) + 1 || thresholds.length + 1);

  const today = data.generated_on;
  const currentWeek = addDays(today, -weekday(today));
  const earliest = [...byDay.keys()].sort()[0] || today;
  const earliestWeek = addDays(earliest, -weekday(earliest));
  const weeks = Math.max(MIN_WEEKS, Math.round((toTime(currentWeek) - toTime(earliestWeek)) / 604800000) + 1);
  const start = addDays(currentWeek, -7 * (weeks - 1));

  const grid = $("heatmap");
  grid.style.gridTemplateColumns = `repeat(${weeks}, 1fr)`;
  const cells = [];
  for (let i = 0; i < weeks * 7; i++) {
    const day = addDays(start, i);
    if (day > today) { cells.push(el("div", { class: "cell empty" })); continue; }
    const entry = byDay.get(day);
    const cell = el("div", { class: `cell l${level(entry ? entry.total : 0)}` });
    cell.dataset.tip = tooltip(day, entry);
    cells.push(cell);
  }
  grid.replaceChildren(...cells);
}

function tooltip(day, entry) {
  if (!entry) return `${dayLabel(day)}\nNo usage`;
  const lines = [`${dayLabel(day)}`, `${compact(entry.total)} tokens`];
  for (const [source, total] of Object.entries(entry.sources)) lines.push(`${SOURCES[source]}: ${compact(total)}`);
  lines.push(`input ${compact(entry.input)} · output ${compact(entry.output)} · cache ${compact(entry.cache)}`);
  return lines.join("\n");
}

function modelTotals() {
  const byModel = new Map();
  for (const row of rows()) {
    const key = row.model || SOURCES[row.source];
    const entry = byModel.get(key) || { total: 0, messages: 0, isModel: !!row.model };
    entry.total += totalOf(row.tokens);
    entry.messages += row.messages;
    byModel.set(key, entry);
  }
  return [...byModel.entries()].sort((a, b) => b[1].total - a[1].total);
}

function renderModels() {
  const models = modelTotals();
  const sum = Math.max(1, models.reduce((s, [, e]) => s + e.total, 0));
  $("model-list").replaceChildren(...models.map(([model, entry]) => {
    const share = entry.total / sum;
    const row = el("div", { class: "model", title: `${number(entry.messages)} responses` });
    const bar = el("div", { class: "bar" });
    const fill = el("span");
    fill.style.width = `${Math.max(0.3, share * 100)}%`;
    bar.append(fill);
    row.append(el("span", { class: "name" }, entry.isModel ? modelName(model) : model), bar,
      el("span", { class: "num" }, compact(entry.total)), el("span", { class: "share" }, `${Math.round(share * 100)}%`));
    return row;
  }));

  const filters = $("chart-filters");
  const buttons = [["All models", null], ...models.filter(([, e]) => e.isModel).slice(0, 4).map(([m]) => [modelName(m), m])]
    .map(([label, model]) => {
      const button = el("button", { class: "chip", "aria-pressed": String(state.chartModel === model) }, label);
      button.onclick = () => { state.chartModel = model; render(); };
      return button;
    });
  const cache = el("button", { class: "chip", "aria-pressed": String(state.cache) }, "Cache");
  cache.onclick = () => { state.cache = !state.cache; render(); };
  filters.replaceChildren(...buttons, cache);
}

/// The smallest 1, 2, 2.5 or 5 × 10^k at or above `value`, so axis ticks are round numbers.
function niceCeiling(value) {
  const power = 10 ** Math.floor(Math.log10(value));
  return [1, 2, 2.5, 5, 10].map((m) => m * power).find((v) => v >= value);
}

function renderChart() {
  const byDay = new Map();
  for (const row of rows({ ignoreModel: false })) {
    const entry = byDay.get(row.date) || { input: 0, output: 0, cache: 0 };
    entry.input += row.tokens.input;
    entry.output += row.tokens.output;
    entry.cache += state.cache ? row.tokens.cache_read + row.tokens.cache_write : 0;
    byDay.set(row.date, entry);
  }
  const today = data.generated_on;
  const days = [...byDay.keys()].sort();
  const first = state.range === "all" ? (days[0] || today) : addDays(today, -(state.range === "30d" ? 29 : 6));
  const count = Math.round((toTime(today) - toTime(first)) / 86400000) + 1;
  const max = niceCeiling(Math.max(1, ...[...byDay.values()].map((e) => e.input + e.output + e.cache)));

  const W = 820, H = 240, left = 4, right = 44, top = 8, bottom = 22;
  const plotW = W - left - right, plotH = H - top - bottom;
  const svgNS = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(svgNS, "svg");
  svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
  svg.setAttribute("role", "img");
  svg.setAttribute("aria-label", "Daily tokens split into input, output and cache");
  const add = (tag, attrs, text) => {
    const node = document.createElementNS(svgNS, tag);
    for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
    if (text !== undefined) node.textContent = text;
    svg.append(node);
    return node;
  };
  for (let i = 0; i <= 4; i++) {
    const y = top + plotH - (plotH * i) / 4;
    add("line", { x1: left, x2: left + plotW, y1: y, y2: y, class: "grid" });
    add("text", { x: W - right + 6, y: y + 4 }, compact(Math.round((max * i) / 4)));
  }
  const step = plotW / count;
  const barWidth = Math.max(1, step * 0.72);
  for (let i = 0; i < count; i++) {
    const day = addDays(first, i);
    if (count > 31 ? day.endsWith("-01") : i % 7 === 0) {
      const label = new Date(toTime(day)).toLocaleDateString("en-GB",
        count > 31 ? { month: "short", timeZone: "UTC" } : { day: "numeric", month: "short", timeZone: "UTC" });
      add("text", { x: left + i * step, y: H - 6 }, label);
    }
    const entry = byDay.get(day);
    if (!entry) continue;
    let y = top + plotH;
    for (const kind of ["input", "output", "cache"]) {
      const h = (entry[kind] / max) * plotH;
      if (h <= 0) continue;
      y -= h;
      const rect = add("rect", { x: left + i * step + (step - barWidth) / 2, y, width: barWidth, height: h, rx: Math.min(2, barWidth / 3), style: `fill:var(--${kind})` });
      rect.dataset.tip = `${dayLabel(day)}\ninput ${compact(entry.input)} · output ${compact(entry.output)}${state.cache ? ` · cache ${compact(entry.cache)}` : ""}`;
    }
  }
  $("chart").replaceChildren(svg);
}

// ---------- tooltip ----------

const tip = $("tooltip");
document.addEventListener("mouseover", (event) => {
  const target = event.target.closest("[data-tip]");
  if (!target) { tip.hidden = true; return; }
  tip.textContent = target.dataset.tip;
  tip.hidden = false;
});
document.addEventListener("mousemove", (event) => {
  if (tip.hidden) return;
  const x = Math.min(event.clientX + 14, window.innerWidth - tip.offsetWidth - 8);
  const y = event.clientY + 16 + tip.offsetHeight > window.innerHeight ? event.clientY - tip.offsetHeight - 12 : event.clientY + 16;
  tip.style.left = `${x}px`;
  tip.style.top = `${y}px`;
});

// ---------- start ----------

function setUp() {
  const sources = $("sources");
  const choices = [["all", "All"], ...data.sources.map((s) => [s, SOURCES[s] || s])];
  if (choices.length > 2) {
    sources.replaceChildren(...choices.map(([source, label]) => {
      const button = el("button", { class: "chip", "data-source": source }, label);
      button.onclick = () => { state.source = source; state.chartModel = null; render(); };
      return button;
    }));
  }
  for (const button of document.querySelectorAll("[data-tab]")) button.onclick = () => { state.tab = button.dataset.tab; render(); };
  for (const button of document.querySelectorAll("[data-range]")) button.onclick = () => { state.range = button.dataset.range; render(); };

  const generated = new Date(data.generated_at);
  $("note").textContent = `Each model response is counted once, with its input, output and cache tokens. ` +
    `Days are in my local time. Last updated ${generated.toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" })}.`;
  render();
}

fetch("data.json", { cache: "no-cache" })
  .then((response) => { if (!response.ok) throw new Error(`HTTP ${response.status}`); return response.json(); })
  .then((json) => {
    if (json.schema !== "agentdeck.usage/v1") throw new Error(`unsupported schema ${json.schema}`);
    data = json;
    setUp();
  })
  .catch((error) => {
    $("error").hidden = false;
    $("error").textContent = `Could not load the usage data (${error.message}).`;
  });
