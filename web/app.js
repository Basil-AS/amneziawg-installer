const app = document.querySelector("#app");
const toastHost = document.querySelector("#toastHost");
let token = localStorage.getItem("panelToken") || "";
let statusState = null;
let dnsState = null;
let trafficState = null;
let latestClients = [];
let latestTokens = [];
let pollTimer = null;
let topTrafficMode = localStorage.getItem("topTrafficMode") || "30d";
const previousRx = new Map();
const previousTx = new Map();
const previousSampleAt = new Map();
const speedHistory = new Map();
const charts = new Map();
const configTextCache = new Map();
let trafficChart = null;
let openClientMenu = null;
const CLIENT_NAME_RE = /^[A-Za-z0-9_-]+$/;
const CLIENT_NAME_HINT_RU = "Используйте только латиницу, цифры, дефис и подчёркивание: A-Z, a-z, 0-9, _ и -";
const CLIENT_NAME_HINT_EN = "Use only Latin letters, digits, underscore and hyphen: A-Z, a-z, 0-9, _ and -";

const icons = {
  sun: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3v2.2M12 18.8V21M4.2 4.2l1.6 1.6M18.2 18.2l1.6 1.6M3 12h2.2M18.8 12H21M4.2 19.8l1.6-1.6M18.2 5.8l1.6-1.6"/><circle cx="12" cy="12" r="4"/></svg>',
  moon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M21 12.8A8.5 8.5 0 1 1 11.2 3 6.8 6.8 0 0 0 21 12.8Z"/></svg>',
  plus: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 5v14M5 12h14"/></svg>',
  logout: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M15 7V5a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h7a2 2 0 0 0 2-2v-2"/><path d="M10 12h11M18 9l3 3-3 3"/></svg>',
  power: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 2v10"/><path d="M18.4 6.6a9 9 0 1 1-12.8 0"/></svg>',
  file: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8Z"/><path d="M14 2v6h6"/></svg>',
  download: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/></svg>',
  qr: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4z"/><path d="M14 14h2v2h-2zM18 14h2v6h-4v-2M14 18v2"/></svg>',
  trash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 6h18M8 6V4h8v2M6 6l1 15h10l1-15"/><path d="M10 11v6M14 11v6"/></svg>',
  search: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>',
  key: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="7.5" cy="14.5" r="4.5"/><path d="M11 11 21 1M16 6l2 2M14 8l2 2"/></svg>',
  copy: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="9" y="9" width="11" height="11" rx="2"/><rect x="4" y="4" width="11" height="11" rx="2"/></svg>',
  help: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="9"/><path d="M9.5 9a2.6 2.6 0 0 1 5 1c0 2-2.5 2.2-2.5 4"/><path d="M12 17h.01"/></svg>',
  external: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M14 3h7v7"/><path d="M10 14 21 3"/><path d="M21 14v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5"/></svg>',
  github: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 .5a11.5 11.5 0 0 0-3.64 22.41c.58.11.79-.25.79-.56v-2.17c-3.22.7-3.9-1.37-3.9-1.37-.53-1.34-1.29-1.7-1.29-1.7-1.05-.72.08-.71.08-.71 1.16.08 1.77 1.19 1.77 1.19 1.03 1.77 2.7 1.26 3.36.96.1-.75.4-1.26.73-1.55-2.57-.29-5.27-1.29-5.27-5.73 0-1.27.45-2.3 1.19-3.11-.12-.29-.52-1.47.11-3.07 0 0 .97-.31 3.17 1.19a10.93 10.93 0 0 1 5.78 0c2.2-1.5 3.17-1.19 3.17-1.19.63 1.6.23 2.78.11 3.07.74.81 1.19 1.84 1.19 3.11 0 4.45-2.71 5.43-5.29 5.72.42.36.79 1.07.79 2.16v3.2c0 .31.21.68.8.56A11.5 11.5 0 0 0 12 .5Z"/></svg>',
  windows: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 4.5 10.5 3v8H3v-6.5Zm9-1.8L21 1v10h-9V2.7ZM3 13h7.5v8L3 19.5V13Zm9 0h9v10l-9-1.7V13Z"/></svg>',
  android: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="m8 6-2-3M16 6l2-3"/><path d="M5 10a7 7 0 0 1 14 0"/><rect x="5" y="10" width="14" height="9" rx="2"/><path d="M8 13h.01M16 13h.01M8 19v2M16 19v2M3 11v6M21 11v6"/></svg>',
  apple: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M15.7 12.8c0-2.3 1.9-3.4 2-3.5-1.1-1.6-2.8-1.8-3.4-1.8-1.4-.1-2.8.8-3.5.8-.7 0-1.8-.8-3-.8-1.5 0-2.9.9-3.7 2.2-1.6 2.8-.4 6.9 1.1 9.1.8 1.1 1.7 2.4 2.9 2.4 1.2 0 1.6-.8 3-.8 1.4 0 1.8.8 3 .8 1.3 0 2.1-1.2 2.8-2.3.9-1.3 1.3-2.6 1.3-2.7-.1 0-2.5-1-2.5-3.4ZM13.4 6c.6-.8 1.1-1.9.9-3-.9.1-2 .6-2.7 1.4-.6.7-1.1 1.8-1 2.9 1 .1 2-.5 2.8-1.3Z"/></svg>',
  linux: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3c2.2 0 3.7 1.7 3.7 4.5 0 1.4-.3 2.6-.8 3.6 1.8 1.4 3.1 3.8 3.1 6.1 0 2.2-1.8 3.8-6 3.8s-6-1.6-6-3.8c0-2.3 1.3-4.7 3.1-6.1-.5-1-.8-2.2-.8-3.6C8.3 4.7 9.8 3 12 3Z"/><path d="M10 8h.01M14 8h.01M9.5 15h5"/></svg>',
  router: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="10" width="18" height="8" rx="2"/><path d="M7 14h.01M11 14h.01M15 14h3M8 10V6M16 10V6M5 21h14"/></svg>',
  shield: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M9 12.75 11.25 15 15 9.75"/><path d="M12 3.75c2.1 1.95 4.95 3 7.88 3-.42 6.15-3.25 10.69-7.88 13.5-4.63-2.81-7.46-7.35-7.88-13.5 2.93 0 5.78-1.05 7.88-3Z"/></svg>',
  link: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M10.5 13.5 13.5 10.5"/><path d="M8.5 15.5 7 17a4 4 0 0 1-5.7-5.6l2.1-2.1A4 4 0 0 1 9 9"/><path d="M15.5 8.5 17 7a4 4 0 0 1 5.7 5.6l-2.1 2.1A4 4 0 0 1 15 15"/></svg>',
  pencil: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="m4 20 4.2-1 10.6-10.6a2.1 2.1 0 0 0-3-3L5.2 16 4 20Z"/><path d="m14.5 6.5 3 3"/></svg>',
  refresh: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M20 6v5h-5"/><path d="M4 18v-5h5"/><path d="M18.5 9A7 7 0 0 0 6.7 6.7L4 9"/><path d="M5.5 15a7 7 0 0 0 11.8 2.3L20 15"/></svg>',
  more: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="5" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="12" cy="19" r="1.5"/></svg>',
};

const theme = localStorage.getItem("panelTheme") || "light";
document.documentElement.dataset.theme = theme;

document.addEventListener("click", event => {
  if (!event.target.closest(".client-menu") && !event.target.closest("[data-menu-toggle]")) {
    closeClientMenus();
  }
});
document.addEventListener("keydown", event => {
  if (event.key === "Escape") closeClientMenus();
});

function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, ch => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[ch]));
}

function icon(name) {
  return `<span class="w-4 h-4 inline-flex shrink-0">${icons[name] || ""}</span>`;
}

function showToast(msg, type = "success") {
  const node = document.createElement("div");
  node.className = `min-w-64 max-w-sm rounded-lg border px-4 py-3 text-sm shadow-lg transition duration-300 translate-y-2 opacity-0 ${
    type === "error"
      ? "border-[var(--danger)] bg-[var(--panel)] text-[var(--danger)]"
      : "border-[var(--line)] bg-[var(--panel)] text-[var(--text)]"
  }`;
  node.textContent = msg;
  toastHost.appendChild(node);
  requestAnimationFrame(() => {
    node.classList.remove("translate-y-2", "opacity-0");
  });
  setTimeout(() => {
    node.classList.add("translate-y-2", "opacity-0");
    setTimeout(() => node.remove(), 320);
  }, 3000);
}

async function api(path, opt = {}) {
  const headers = Object.assign({"Authorization": "Bearer " + token}, opt.headers || {});
  if (opt.body && !(opt.body instanceof FormData)) headers["Content-Type"] = "application/json";
  const response = await fetch(path, Object.assign({}, opt, {headers}));
  if (!response.ok) {
    const text = await response.text();
    throw new Error(text || response.statusText);
  }
  const ctype = response.headers.get("content-type") || "";
  return ctype.includes("application/json") ? response.json() : response.blob();
}

async function copyText(value) {
  const text = String(value ?? "");
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }
  const area = document.createElement("textarea");
  area.value = text;
  area.setAttribute("readonly", "");
  area.style.position = "fixed";
  area.style.left = "-9999px";
  document.body.appendChild(area);
  area.select();
  try {
    if (!document.execCommand("copy")) throw new Error("copy failed");
  } finally {
    area.remove();
  }
}

function saveBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

async function configText(name) {
  if (configTextCache.has(name)) return configTextCache.get(name);
  const blob = await api(`/api/clients/${encodeURIComponent(name)}/config`);
  const text = await blob.text();
  configTextCache.set(name, text);
  return text;
}

function bytes(n) {
  n = Number(n || 0);
  for (const unit of ["B", "KiB", "MiB", "GiB", "TiB"]) {
    if (n < 1024) return `${n.toFixed(unit === "B" ? 0 : 1)} ${unit}`;
    n /= 1024;
  }
  return `${n.toFixed(1)} PiB`;
}

function speed(n) {
  return `${bytes(n)}/s`;
}

function trafficText(rx, tx, mode = "traffic") {
  return mode === "now"
    ? `↓ ${speed(rx)} · ↑ ${speed(tx)}`
    : `Down ${bytes(rx)} · Up ${bytes(tx)}`;
}

function compactTrafficText(rx, tx, mode = "traffic") {
  return mode === "now"
    ? `↓ ${speed(rx)} · ↑ ${speed(tx)}`
    : `↓ ${bytes(rx)} · ↑ ${bytes(tx)}`;
}

function normalizeP2pPorts(value) {
  const source = Array.isArray(value) ? value : String(value || "").split(/[,\s]+/);
  const seen = new Set();
  return source
    .map(port => Number.parseInt(String(port).trim(), 10))
    .filter(port => Number.isInteger(port) && port > 0 && port <= 65535 && !seen.has(port) && seen.add(port));
}

function timeAgo(value) {
  const ts = Number(value || 0);
  if (!ts) return "never";
  const diff = Math.max(0, Math.floor(Date.now() / 1000 - ts));
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)} mins ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)} hours ago`;
  return `${Math.floor(diff / 86400)} days ago`;
}

function isOnline(client) {
  return !client.disabled && Number(client.latestHandshakeAt || client.last_handshake || 0) > 0 &&
    Date.now() / 1000 - Number(client.latestHandshakeAt || client.last_handshake) < 180;
}

function recentlyActive(client) {
  const last = Number(client.latestHandshakeAt || client.last_handshake || 0);
  return !client.disabled && last > 0 && Date.now() / 1000 - last < 86400;
}

function fallbackHashBytes(value) {
  let hash = 2166136261;
  const bytes = [];
  for (const ch of String(value || "")) {
    hash ^= ch.charCodeAt(0);
    hash = Math.imul(hash, 16777619);
  }
  for (let i = 0; i < 32; i++) {
    hash ^= hash >>> 13;
    hash = Math.imul(hash, 1597334677);
    bytes.push((hash >>> ((i % 4) * 8)) & 255);
  }
  return bytes;
}

async function sha256Bytes(value) {
  const data = new TextEncoder().encode(value);
  if (!globalThis.crypto?.subtle) return fallbackHashBytes(value);
  const hash = await globalThis.crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(hash));
}

async function avatarHtml(name) {
  const label = String(name || "?").trim().toLowerCase();
  const bytes = await sha256Bytes(label);
  const hue = Math.round((bytes[0] / 255) * 359);
  const fg = `hsl(${hue} 68% 38%)`;
  const bg = "var(--soft)";
  const cells = [];
  for (let y = 0; y < 5; y++) {
    for (let x = 0; x < 3; x++) {
      if ((bytes[1 + y * 3 + x] & 1) !== 0) continue;
      cells.push(`<rect x="${x}" y="${y}" width="1" height="1" fill="${fg}"/>`);
      if (x !== 2) cells.push(`<rect x="${4 - x}" y="${y}" width="1" height="1" fill="${fg}"/>`);
    }
  }
  return `<svg class="w-10 h-10 rounded-md bg-[var(--soft)] shadow-sm ring-1 ring-[var(--line)]" viewBox="0 0 5 5" role="img" aria-label="${esc(name || "client")} identicon" shape-rendering="crispEdges"><rect width="5" height="5" fill="${bg}"/>${cells.join("")}</svg>`;
}

function setTheme(next) {
  document.documentElement.dataset.theme = next;
  localStorage.setItem("panelTheme", next);
  const btn = document.querySelector("#themeToggle");
  if (btn) btn.innerHTML = icon(next === "dark" ? "sun" : "moon");
}

function logout() {
  localStorage.removeItem("panelToken");
  token = "";
  clearInterval(pollTimer);
  renderLogin();
}

function buttonClasses(extra = "") {
  return `h-9 inline-flex items-center justify-center gap-2 rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 text-sm font-medium text-[var(--text)] transition hover:border-[var(--accent)] ${extra}`;
}

function primaryButtonClasses(extra = "") {
  return `h-9 inline-flex items-center justify-center gap-2 rounded-md border border-transparent bg-[var(--accent)] px-3 text-sm font-bold text-white transition hover:bg-[var(--accent-hover)] ${extra}`;
}

function iconButton(title, name, extra = "") {
  return `<button title="${esc(title)}" aria-label="${esc(title)}" class="${buttonClasses(`w-9 px-0 ${extra}`)}">${icon(name)}</button>`;
}

function actionButton(action, title, iconName, label, extra = "") {
  return `<button data-action="${esc(action)}" title="${esc(title)}" aria-label="${esc(title)}" class="${buttonClasses(`client-action ${extra}`)}">${icon(iconName)}<span class="client-action-label">${esc(label)}</span></button>`;
}

function closeClientMenus(except = null) {
  document.querySelectorAll(".client-menu").forEach(menu => {
    if (except && menu.id === except) return;
    menu.classList.add("hidden");
    const btn = document.querySelector(`[aria-controls="${menu.id}"]`);
    if (btn) btn.setAttribute("aria-expanded", "false");
  });
  if (!except) openClientMenu = null;
}

function p2pSummary(ports, disabled) {
  if (!ports.length) return "";
  const preview = ports.slice(0, 2).join(", ");
  const more = ports.length > 2 ? ` +${ports.length - 2}` : "";
  return `P2P: ${ports.length} port${ports.length === 1 ? "" : "s"} (${preview}${more})${disabled ? " off" : ""}`;
}

function renderMenuItem(action, iconName, label, extra = "") {
  return `<button type="button" data-action="${esc(action)}" class="client-menu-item ${extra}">${icon(iconName)}<span>${esc(label)}</span></button>`;
}

function renderLogin() {
  app.innerHTML = `
    <section class="min-h-screen grid place-items-center">
      <form id="loginForm" class="w-full max-w-sm rounded-lg border border-[var(--line)] bg-[var(--panel)] p-5 shadow-sm">
        <label class="sr-only" for="tokenInput">Token</label>
        <input id="tokenInput" class="h-11 w-full rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 text-[var(--text)] outline-none focus:border-[var(--accent)]" type="password" value="${esc(token)}" placeholder="Token" autocomplete="current-password" autofocus>
        <button class="${primaryButtonClasses("mt-4 w-full")}" type="submit">Login</button>
      </form>
    </section>
  `;
  const loginForm = document.querySelector("#loginForm");
  loginForm.onsubmit = async event => {
    event.preventDefault();
    token = document.querySelector("#tokenInput").value.trim();
    try {
      statusState = await api("/api/status");
      localStorage.setItem("panelToken", token);
      await renderPanel();
    } catch {
      localStorage.removeItem("panelToken");
      showToast("Token rejected", "error");
    }
  };
  document.querySelector("#tokenInput").addEventListener("keydown", event => {
    if (event.key !== "Enter") return;
    event.preventDefault();
    loginForm.requestSubmit();
  });
}

async function renderPanel() {
  clearInterval(pollTimer);
  if (trafficChart) {
    trafficChart.destroy();
    trafficChart = null;
  }
  app.innerHTML = `
    <header class="flex flex-col gap-4 py-4 sm:flex-row sm:items-center sm:justify-between">
      <div class="flex items-center gap-3">
        <div class="grid h-11 w-11 place-items-center rounded-lg bg-[var(--accent)] text-lg font-black text-white">AW</div>
        <div>
          <h1 class="text-xl font-semibold leading-tight">${esc(statusState.server_name || "AmneziaWG")}</h1>
          <p class="text-sm text-[var(--muted)]">v${esc(statusState.version)} · ${esc(statusState.fork)} · ${esc(statusState.role)}</p>
        </div>
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <button id="themeToggle" class="${buttonClasses("w-9 px-0")}" title="Theme">${icon(document.documentElement.dataset.theme === "dark" ? "sun" : "moon")}</button>
        <button id="helpButton" class="${buttonClasses("w-9 px-0")}" title="Help & Clients" aria-label="Help & Clients">${icon("help")}</button>
        <a href="https://github.com/Basil-AS/amneziawg-installer" target="_blank" rel="noopener" class="${buttonClasses("w-9 px-0")}" title="Repository" aria-label="Repository">${icon("github")}</a>
        <button id="addClient" class="${primaryButtonClasses()}">${icon("plus")}<span>Add Client</span></button>
        <button id="logout" class="${buttonClasses()}">${icon("logout")}<span>Logout</span></button>
      </div>
    </header>

    <section class="grid gap-3 sm:grid-cols-2 lg:grid-cols-6">
      <div class="rounded-lg border border-[var(--line)] bg-[var(--panel)] p-4">
        <p class="text-xs font-semibold uppercase text-[var(--muted)]">Active</p>
        <strong id="metricActive" class="mt-2 block text-2xl">0</strong>
      </div>
      <div class="rounded-lg border border-[var(--line)] bg-[var(--panel)] p-4">
        <p class="text-xs font-semibold uppercase text-[var(--muted)]">Clients</p>
        <strong id="metricClients" class="mt-2 block text-2xl">0</strong>
      </div>
      <div class="rounded-lg border border-[var(--line)] bg-[var(--panel)] p-4">
        <p class="text-xs font-semibold uppercase text-[var(--muted)]">Traffic Total</p>
        <strong id="metricTrafficTotal" class="mt-2 block text-2xl">-</strong>
        <p id="metricTrafficTotalSub" class="mt-1 text-xs text-[var(--muted)]">-</p>
      </div>
      <div class="rounded-lg border border-[var(--line)] bg-[var(--panel)] p-4">
        <p class="text-xs font-semibold uppercase text-[var(--muted)]">30 Days</p>
        <strong id="metricTraffic30d" class="mt-2 block text-2xl">-</strong>
        <p id="metricTraffic30dSub" class="mt-1 text-xs text-[var(--muted)]">-</p>
      </div>
      <div class="min-w-0 rounded-lg border border-[var(--line)] bg-[var(--panel)] p-4 sm:col-span-2">
        <p class="text-xs font-semibold uppercase text-[var(--muted)]">DNS</p>
        <strong id="metricDns" class="mt-2 flex min-w-0 items-center text-lg sm:text-2xl">-</strong>
      </div>
    </section>

    <section class="mt-3 rounded-lg border border-[var(--line)] bg-[var(--panel)] p-3">
      <div class="relative">
        <span class="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[var(--muted)]">${icon("search")}</span>
        <input id="searchInput" class="h-11 w-full rounded-md border border-[var(--line)] bg-[var(--soft)] pl-10 pr-3 text-[var(--text)] outline-none focus:border-[var(--accent)]" placeholder="Search by name or IP" autocomplete="off">
      </div>
    </section>

    <section class="mt-3 rounded-lg border border-[var(--line)] bg-[var(--panel)] p-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h2 class="text-base font-semibold">Traffic</h2>
        <p id="trafficUpdated" class="text-xs text-[var(--muted)]">Last 30 days</p>
      </div>
      <div id="trafficChart" class="mt-3 h-44"></div>
    </section>

    <section id="topTrafficPanel" class="mt-3 rounded-lg border border-[var(--line)] bg-[var(--panel)] p-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h2 class="text-base font-semibold">Top Clients</h2>
        <div class="flex rounded-md border border-[var(--line)] bg-[var(--soft)] p-1">
          <button data-top-mode="30d" class="top-mode h-8 rounded px-3 text-xs font-semibold transition">30d</button>
          <button data-top-mode="total" class="top-mode h-8 rounded px-3 text-xs font-semibold transition">Total</button>
          <button data-top-mode="now" class="top-mode h-8 rounded px-3 text-xs font-semibold transition">Now</button>
        </div>
      </div>
      <div id="topClientsList" class="mt-3 grid gap-2"></div>
    </section>

    <section id="accessPanel" class="mt-3 rounded-lg border border-[var(--line)] bg-[var(--panel)] p-4 ${statusState.role === "super" ? "" : "hidden"}">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold">Access Control</h2>
          <p class="text-sm text-[var(--muted)]">User tokens are limited to selected clients.</p>
        </div>
        <button id="newToken" class="${buttonClasses()}">${icon("key")}<span>Generate Token</span></button>
      </div>
      <div id="tokenList" class="mt-4 grid gap-2"></div>
    </section>

    <section id="advancedPanel" class="mt-3 rounded-lg border border-[var(--line)] bg-[var(--panel)] p-4 ${statusState.role === "super" ? "" : "hidden"}">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold">Advanced</h2>
          <p class="text-sm text-[var(--muted)]">Disruptive server-side operations.</p>
        </div>
        <button id="rotateProfile" class="${buttonClasses("border-amber-600 text-amber-700")}">${icon("refresh")}<span>Rotate AWG profile</span></button>
      </div>
    </section>

    <section id="clientsList" class="mt-4 overflow-hidden rounded-lg border border-[var(--line)] bg-[var(--panel)]"></section>
  `;
  document.querySelector("#themeToggle").onclick = () => setTheme(document.documentElement.dataset.theme === "dark" ? "light" : "dark");
  document.querySelector("#helpButton").onclick = showHelp;
  document.querySelector("#logout").onclick = logout;
  document.querySelector("#addClient").onclick = addClient;
  document.querySelector("#searchInput").oninput = applySearch;
  if (statusState.role === "super") document.querySelector("#newToken").onclick = newToken;
  if (statusState.role === "super") document.querySelector("#rotateProfile").onclick = rotateServerProfile;
  await loadAll();
  pollTimer = setInterval(loadClients, 2000);
}

async function loadAll() {
  const [dns] = await Promise.all([api("/api/dns"), loadClients()]);
  dnsState = dns;
  renderDnsMetric();
  if (statusState.role === "super") await loadTokens();
}

function renderDnsMetric() {
  const metric = document.querySelector("#metricDns");
  if (!metric || !dnsState) return;
  const label = dnsState.client_dns || dnsState.mode || "-";
  if (dnsState.adguard_enabled) {
    const url = `http://10.9.9.1:${dnsState.adguard_port || 3000}`;
    metric.innerHTML = `
      <span class="min-w-0 flex-1 truncate">${esc(label)}</span>
      <a class="ml-2 inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-[var(--line)] bg-[var(--soft)] text-[var(--accent)] transition hover:border-[var(--accent)]" href="${esc(url)}" target="_blank" rel="noopener" title="Open AdGuard" aria-label="Open AdGuard">${icon("external")}</a>
    `;
    metric.classList.add("flex", "items-center");
  } else {
    metric.textContent = label;
    metric.classList.remove("flex", "items-center");
  }
}

async function loadClients() {
  const now = Date.now();
  const payload = await api("/api/clients");
  const rows = Array.isArray(payload) ? payload : (payload.clients || []);
  trafficState = Array.isArray(payload) ? null : payload.traffic;
  latestClients = await Promise.all(rows.map(async client => {
    const rx = Number(client.rx || 0);
    const tx = Number(client.tx || 0);
    const prevTime = previousSampleAt.get(client.name);
    const prevRxBytes = previousRx.get(client.name);
    const prevTxBytes = previousTx.get(client.name);
    let rxSpeed = 0;
    let txSpeed = 0;
    if (prevTime && now > prevTime) {
      const elapsed = (now - prevTime) / 1000;
      if (rx >= Number(prevRxBytes || 0)) rxSpeed = (rx - Number(prevRxBytes || 0)) / elapsed;
      if (tx >= Number(prevTxBytes || 0)) txSpeed = (tx - Number(prevTxBytes || 0)) / elapsed;
    }
    const speedBps = rxSpeed + txSpeed;
    previousRx.set(client.name, rx);
    previousTx.set(client.name, tx);
    previousSampleAt.set(client.name, now);
    const history = speedHistory.get(client.name) || [];
    history.push(Math.max(0, Math.round(speedBps)));
    while (history.length > 30) history.shift();
    speedHistory.set(client.name, history);
    return Object.assign({}, client, {
      rxSpeedBps: rxSpeed,
      txSpeedBps: txSpeed,
      speedBps,
      traffic_total: client.traffic_total || {rx: 0, tx: 0, total: 0},
      totalBytes: Number(client.traffic_total?.total || 0),
      traffic_30d: client.traffic_30d || {rx: 0, tx: 0, total: 0},
      p2p_ports: normalizeP2pPorts(client.p2p_ports),
      avatar: await avatarHtml(client.name),
    });
  }));
  renderClients();
  document.querySelector("#metricClients").textContent = latestClients.length;
  document.querySelector("#metricActive").textContent = latestClients.filter(isOnline).length;
  renderTraffic();
  renderTopClients();
  if (statusState.role === "super") renderTokenList();
  applySearch();
}

function renderTraffic() {
  if (!trafficState) return;
  const total = trafficState.total || trafficState.current || {};
  const last30 = trafficState.last_30d || {};
  const totalMetric = document.querySelector("#metricTrafficTotal");
  const totalSub = document.querySelector("#metricTrafficTotalSub");
  const last30Metric = document.querySelector("#metricTraffic30d");
  const last30Sub = document.querySelector("#metricTraffic30dSub");
  if (totalMetric) totalMetric.textContent = bytes(total.total || 0);
  if (totalSub) totalSub.textContent = trafficText(total.rx || 0, total.tx || 0);
  if (last30Metric) last30Metric.textContent = bytes(last30.total || 0);
  if (last30Sub) last30Sub.textContent = trafficText(last30.rx || 0, last30.tx || 0);

  const updated = document.querySelector("#trafficUpdated");
  if (updated) updated.textContent = `${(trafficState.days || []).length || 30} day window`;
  if (!window.ApexCharts) return;
  const el = document.querySelector("#trafficChart");
  if (!el) return;
  if (trafficChart) trafficChart.destroy();
  const days = trafficState.days || [];
  trafficChart = new ApexCharts(el, {
    chart: {type: "bar", height: "100%", toolbar: {show: false}, animations: {enabled: false}},
    series: [{name: "Traffic", data: days.map(day => Number(day.total || 0))}],
    colors: ["var(--accent)"],
    plotOptions: {bar: {borderRadius: 3, columnWidth: "70%"}},
    dataLabels: {enabled: false},
    grid: {borderColor: "var(--line)", strokeDashArray: 3},
    xaxis: {
      categories: days.map(day => String(day.date || "").slice(5)),
      labels: {style: {colors: "var(--muted)"}, rotate: -45, hideOverlappingLabels: true},
      axisBorder: {show: false},
      axisTicks: {show: false},
    },
    yaxis: {labels: {style: {colors: "var(--muted)"}, formatter: value => bytes(value)}},
    tooltip: {y: {formatter: value => bytes(value)}},
  });
  trafficChart.render();
}

function topClientStats(client, mode) {
  if (mode === "now") {
    const rx = Number(client.rxSpeedBps || 0);
    const tx = Number(client.txSpeedBps || 0);
    return {rx, tx, total: rx + tx};
  }
  const data = mode === "total" ? (client.traffic_total || {}) : (client.traffic_30d || {});
  const rx = Number(data.rx || 0);
  const tx = Number(data.tx || 0);
  return {rx, tx, total: Number(data.total || rx + tx)};
}

function renderTopClients() {
  const host = document.querySelector("#topClientsList");
  if (!host) return;
  document.querySelectorAll("[data-top-mode]").forEach(btn => {
    const active = btn.dataset.topMode === topTrafficMode;
    btn.className = `top-mode h-8 rounded px-3 text-xs font-semibold transition ${active ? "bg-[var(--accent)] text-white" : "text-[var(--muted)] hover:text-[var(--text)]"}`;
    btn.onclick = () => {
      topTrafficMode = btn.dataset.topMode;
      localStorage.setItem("topTrafficMode", topTrafficMode);
      renderTopClients();
    };
  });
  const rows = latestClients
    .map(client => ({client, stats: topClientStats(client, topTrafficMode)}))
    .filter(row => row.stats.total > 0)
    .sort((a, b) => b.stats.total - a.stats.total)
    .slice(0, 10);
  if (!rows.length) {
    host.innerHTML = `<p class="rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 py-4 text-center text-sm text-[var(--muted)]">No traffic yet</p>`;
    return;
  }
  const max = Math.max(...rows.map(row => row.stats.total), 1);
  host.innerHTML = rows.map(({client, stats}, index) => {
    const totalPct = Math.max(2, Math.min(100, (stats.total / max) * 100));
    const rxPct = stats.total > 0 ? Math.max(0, Math.min(100, (stats.rx / stats.total) * 100)) : 0;
    const txPct = Math.max(0, 100 - rxPct);
    const amount = topTrafficMode === "now" ? speed(stats.total) : bytes(stats.total);
    return `
      <button data-jump-client="${esc(client.name)}" class="w-full rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 py-2 text-left transition hover:border-[var(--accent)]">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div class="min-w-0">
            <span class="mr-2 text-xs font-semibold text-[var(--muted)]">${index + 1}</span>
            <span class="font-semibold">${esc(client.name)}</span>
          </div>
          <strong class="text-sm">${esc(amount)}</strong>
        </div>
        <div class="mt-2 h-2 overflow-hidden rounded-full bg-[var(--panel)]">
          <div class="flex h-full overflow-hidden rounded-full" style="width:${totalPct}%">
            <span class="h-full bg-[var(--accent)]" style="width:${rxPct}%"></span>
            <span class="h-full bg-[var(--muted)]" style="width:${txPct}%"></span>
          </div>
        </div>
        <p class="mt-1 text-xs text-[var(--muted)]">${esc(trafficText(stats.rx, stats.tx, topTrafficMode))}</p>
      </button>
    `;
  }).join("");
  host.querySelectorAll("[data-jump-client]").forEach(btn => {
    btn.onclick = () => jumpToClient(btn.dataset.jumpClient);
  });
}

function jumpToClient(name) {
  const search = document.querySelector("#searchInput");
  if (search && search.value) {
    search.value = "";
    applySearch();
  }
  const card = Array.from(document.querySelectorAll(".client-card")).find(item => item.dataset.name === name);
  if (!card) return;
  card.scrollIntoView({behavior: "smooth", block: "center"});
  card.classList.add("ring-2", "ring-[var(--accent)]");
  setTimeout(() => card.classList.remove("ring-2", "ring-[var(--accent)]"), 1200);
}

function renderClients() {
  charts.forEach(chart => chart.destroy());
  charts.clear();
  closeClientMenus();
  const host = document.querySelector("#clientsList");
  if (!latestClients.length) {
    host.innerHTML = `<div class="p-8 text-center text-sm text-[var(--muted)]">No clients yet</div>`;
    return;
  }
  host.innerHTML = latestClients.map(client => {
    const online = isOnline(client);
    const active = recentlyActive(client);
    const ipv4 = client.ipv4 || client.ip || "-";
    const ipv6 = client.ipv6 || "";
    const ip = [client.ipv4 || client.ip, client.ipv6].filter(Boolean).join(" / ") || "-";
    const endpoint = client.endpoint || "-";
    const client30d = client.traffic_30d || {};
    const clientTotal = client.traffic_total || {};
    const p2pDisabled = (client.p2p_ports || []).length > 0 && client.p2p_enabled === false;
    const p2pTitle = (client.p2p_ports || []).join(", ");
    const p2pText = p2pSummary(client.p2p_ports || [], p2pDisabled);
    const menuId = `client-menu-${String(client.name).replace(/[^A-Za-z0-9_-]/g, "_")}`;
    const shieldClass = p2pDisabled ? "opacity-60" : "";
    const search = `${client.name} ${ip} ${endpoint} ${(client.p2p_ports || []).join(" ")}`.toLowerCase();
    return `
      <article class="client-card bg-[var(--panel)] border-b border-[var(--line)] p-4 relative last:border-b-0" data-name="${esc(client.name)}" data-search="${esc(search)}">
        <div class="relative z-10 shrink-0 self-start sm:self-auto">
          ${client.avatar}
          <span class="absolute -right-0.5 -bottom-0.5 grid h-3.5 w-3.5 place-items-center">
            ${online ? '<span class="absolute inline-flex h-full w-full rounded-full bg-green-500 opacity-75 animate-ping"></span><span class="relative inline-flex h-3 w-3 rounded-full bg-green-600 ring-2 ring-[var(--panel)]"></span>' : '<span class="relative inline-flex h-3 w-3 rounded-full bg-[var(--muted)] ring-2 ring-[var(--panel)]"></span>'}
          </span>
        </div>
        <div class="relative z-10 min-w-0 flex-1">
          <div class="flex min-w-0 flex-wrap items-center gap-2">
            <h3 class="min-w-0 truncate text-base font-semibold" title="${esc(client.name)}">${esc(client.name)}</h3>
            ${client.disabled ? '<span class="rounded-full border border-[var(--danger)] px-2 py-0.5 text-xs font-semibold text-[var(--danger)]">disabled</span>' : ""}
          </div>
          <div class="mt-1 flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 text-sm text-[var(--muted)]">
            <span class="shrink-0 font-mono text-xs text-[var(--text)]" title="${esc(ipv4)}">${esc(ipv4)}</span>
            ${ipv6 ? `<span class="min-w-0 max-w-full truncate font-mono text-xs" title="${esc(ipv6)}">${esc(ipv6)}</span>` : ""}
          </div>
          <p class="mt-1 text-xs text-[var(--muted)]">${active ? "Active recently" : "No recent traffic"} · Last seen ${esc(timeAgo(client.latestHandshakeAt || client.last_handshake))}</p>
          <p class="mt-1 truncate text-xs text-[var(--muted)]">Endpoint: ${esc(endpoint)}</p>
          ${p2pText ? `<p class="mt-2 inline-flex max-w-full rounded-full border border-[var(--line)] bg-[var(--soft)] px-2 py-0.5 text-[11px] font-medium text-[var(--muted)] ${p2pDisabled ? "opacity-60" : ""}" title="${esc(p2pTitle)}">${esc(p2pText)}</p>` : ""}
        </div>
        <div class="relative z-10 min-w-0 text-left sm:min-w-36 sm:text-right">
          <p class="flex flex-wrap gap-x-3 gap-y-1 text-sm font-semibold sm:justify-end"><span>↓ ${esc(speed(client.rxSpeedBps))}</span><span>↑ ${esc(speed(client.txSpeedBps))}</span></p>
          <p class="mt-1 text-xs text-[var(--muted)]" title="${esc(trafficText(clientTotal.rx || 0, clientTotal.tx || 0))}">Total ${esc(compactTrafficText(clientTotal.rx || 0, clientTotal.tx || 0))}</p>
          <p class="mt-1 text-xs text-[var(--muted)]" title="${esc(trafficText(client30d.rx || 0, client30d.tx || 0))}">30d ${esc(compactTrafficText(client30d.rx || 0, client30d.tx || 0))}</p>
          <div id="chart-${esc(client.name)}" class="client-sparkline mt-2"></div>
        </div>
        <div class="client-actions relative z-20 flex w-full shrink-0 flex-wrap justify-end gap-1 sm:w-auto">
          <button data-action="download-config" title="Download .conf" aria-label="Download .conf" class="${buttonClasses("client-action client-action-primary")}">${icon("download")}<span class="client-action-label">Download</span></button>
          ${actionButton("qr", "Show QR", "qr", "QR", "client-action-primary")}
          <button data-action="copy-config" title="Copy config" aria-label="Copy config" class="${buttonClasses("client-action client-action-primary")}">${icon("copy")}<span class="client-action-label">Copy</span></button>
          <button type="button" data-menu-toggle="${esc(menuId)}" aria-expanded="false" aria-controls="${esc(menuId)}" title="More actions" aria-label="More actions for ${esc(client.name)}" class="${buttonClasses("w-9 px-0")}">${icon("more")}</button>
          <div id="${esc(menuId)}" class="client-menu hidden" role="menu">
            ${renderMenuItem("copy-config", "copy", "Copy config")}
            ${renderMenuItem("copy-vpnuri", "link", "Copy vpn://")}
            ${renderMenuItem("copy-import-url", "link", "Copy import URL")}
            ${renderMenuItem("regenerate-config", "refresh", "Regenerate", "text-amber-700")}
            ${renderMenuItem("toggle", "power", client.disabled ? "Enable client" : "Disable client")}
            ${renderMenuItem("toggle-p2p", "shield", "P2P details / toggle", shieldClass)}
            ${renderMenuItem("delete", "trash", "Delete", "text-[var(--danger)]")}
          </div>
        </div>
      </article>
    `;
  }).join("");
  host.querySelectorAll("[data-action]").forEach(btn => {
    const card = btn.closest(".client-card");
    btn.onclick = () => {
      closeClientMenus();
      clientAction(card.dataset.name, btn.dataset.action);
    };
  });
  host.querySelectorAll("[data-menu-toggle]").forEach(btn => {
    btn.onclick = event => {
      event.stopPropagation();
      const id = btn.dataset.menuToggle;
      const expanded = btn.getAttribute("aria-expanded") === "true";
      closeClientMenus(expanded ? null : id);
      const menu = document.getElementById(id);
      if (!menu) return;
      menu.classList.toggle("hidden", expanded);
      btn.setAttribute("aria-expanded", expanded ? "false" : "true");
      openClientMenu = expanded ? null : id;
    };
  });
  drawCharts();
}

function drawCharts() {
  if (!window.ApexCharts) return;
  latestClients.forEach(client => {
    const el = document.getElementById(`chart-${client.name}`);
    if (!el) return;
    const chart = new ApexCharts(el, {
      chart: {type: "area", height: "100%", sparkline: {enabled: true}, animations: {enabled: false}},
      series: [{data: speedHistory.get(client.name) || []}],
      stroke: {curve: "smooth", width: 2, colors: ["var(--accent)"]},
      fill: {type: "solid", colors: ["var(--accent)"], opacity: 0.35},
      tooltip: {enabled: false},
      grid: {show: false},
      xaxis: {labels: {show: false}, axisBorder: {show: false}, axisTicks: {show: false}},
      yaxis: {show: false},
    });
    chart.render();
    charts.set(client.name, chart);
  });
}

function applySearch() {
  const q = (document.querySelector("#searchInput")?.value || "").trim().toLowerCase();
  document.querySelectorAll(".client-card").forEach(card => {
    card.classList.toggle("hidden", q && !card.dataset.search.includes(q));
  });
}

const helpClientGroups = [
  {
    name: "Windows",
    icon: "windows",
    subtitle: "Главные варианты: WireSock для split tunneling, AmneziaWG для официальной совместимости.",
    clients: [
      {name: "WireSock Secure Connect", status: "Recommended / Advanced", trafficSplit: "App split / NDIS / routes", description: "Продвинутый Windows-клиент с per-app split tunneling, KillSwitch и кастомной DPI-симуляцией.", support: ["supported", {state: "custom", text: "◇ AWG 1.5 custom"}, "supported"], links: [{label: "Download", url: "https://www.wiresock.net/wiresock-secure-connect/download/"}], platforms: "Windows", importMethod: ".conf + WireSock simulation settings", bestFor: "Тонкое разделение трафика по приложениям, маршрутам и сетям на Windows.", limitation: "Standard AWG 1.5 I1-I5 parameters are not imported directly. WireSock uses custom simulation settings instead. Best choice when Windows per-app split tunneling is more important than strict compatibility with official AmneziaWG config syntax."},
      {name: "AmneziaWG for Windows", status: "Recommended", trafficSplit: "Routes only", description: "Лучший лёгкий официальный AWG-клиент под Windows.", support: ["supported", "supported", "supported"], links: [{label: "GitHub Releases", url: "https://github.com/amnezia-vpn/amneziawg-windows-client/releases"}, {label: "Win7 patch", url: "https://github.com/stunndard/golangwin7patch/releases/latest"}], platforms: "Windows x64, ARM64, x86", importMethod: ".conf", bestFor: "Официальная совместимость с AmneziaWG-конфигами.", limitation: "Split tunneling в основном через AllowedIPs/routes, без удобного per-app split как у WireSock."},
      {name: "AmneziaVPN", status: "Full client", trafficSplit: "Routes / app features", description: "Полный VPN-клиент Amnezia.", support: ["supported", "supported", "supported"], links: [{label: "Official", url: "https://amnezia.org/downloads"}, {label: "GitHub", url: "https://github.com/amnezia-vpn/amnezia-client/releases"}], platforms: "Windows", importMethod: "vpn:// URI, QR, app flow", bestFor: "Onboarding, управление Amnezia-сервером и полный стек Amnezia.", limitation: "Тяжелее, чем отдельный AmneziaWG-клиент."},
      {name: "VeilBox", status: "Experimental", trafficSplit: "TUN / proxy rules", description: "Альтернативный клиент с AmneziaWG/VLESS.", support: ["unknown", "unknown", "warning"], links: [{label: "GitHub", url: "https://github.com/artem4150/VeilBox"}], platforms: "Windows", importMethod: "Depends on build", bestFor: "Экспериментальные гибридные сценарии.", limitation: "Не основной AWG-клиент."},
      {name: "Clash Verge Rev", status: "Experimental", trafficSplit: "Proxy rules", description: "Прокси-комбайн, не основной AWG-клиент.", support: ["warning", "warning", "warning"], links: [{label: "GitHub", url: "https://github.com/clash-verge-rev/clash-verge-rev/releases"}], platforms: "Windows", importMethod: "Proxy profiles", bestFor: "Proxy-rule based routing.", limitation: "Использовать как альтернативный proxy-клиент, не как основной AWG-клиент."},
    ],
  },
  {
    name: "Android",
    icon: "android",
    subtitle: "Главные варианты: WG Tunnel для advanced routing, AmneziaWG для лёгкого official flow.",
    clients: [
      {name: "WG Tunnel", status: "Recommended / Advanced", trafficSplit: "App split / auto tunnel", description: "Продвинутый Android-клиент для auto-tunnel, split tunneling, Always-On, lockdown и Android TV.", support: ["supported", "supported", {state: "supported", text: "✅ AWG 2.0 userspace"}], links: [{label: "Website", url: "https://wgtunnel.com/"}, {label: "GitHub", url: "https://github.com/wgtunnel/android/releases"}], platforms: "Android phones, tablets, Android TV", importMethod: ".conf, QR, manual import", bestFor: "Разделение по приложениям, авто-подключение, Android TV и advanced Android-сценарии.", limitation: "AmneziaWG works only through Userspace/Go backend. Kernel mode supports only standard WireGuard, not AmneziaWG."},
      {name: "AmneziaWG Android", status: "Recommended", trafficSplit: "App split", description: "Лёгкий официальный AWG-клиент под Android.", support: ["supported", "supported", "supported"], links: [{label: "Google Play", url: "https://play.google.com/store/apps/details?id=org.amnezia.awg"}, {label: "GitHub", url: "https://github.com/amnezia-vpn/amneziawg-android/releases"}], platforms: "Android phones, tablets", importMethod: ".conf, QR", bestFor: "Официальный лёгкий клиент без лишней сложности.", limitation: "Для самых продвинутых auto-tunnel сценариев лучше WG Tunnel."},
      {name: "AmneziaVPN", status: "Full client", trafficSplit: "App split", description: "Полный клиент Amnezia для Android.", support: ["supported", "supported", "supported"], links: [{label: "Official", url: "https://amnezia.org/downloads"}, {label: "GitHub", url: "https://github.com/amnezia-vpn/amnezia-client/releases"}], platforms: "Android phones, tablets", importMethod: "vpn:// URI, QR, app flow", bestFor: "Простой onboarding и полный клиент Amnezia.", limitation: "Тяжелее, чем отдельный AmneziaWG-клиент."},
    ],
  },
  {
    name: "iOS / iPadOS",
    icon: "apple",
    subtitle: "iOS does not provide normal per-app split tunneling for generic VPN clients.",
    clients: [
      {name: "AmneziaWG", status: "Recommended", trafficSplit: "No app split / OS-limited", description: "Лучший лёгкий AWG-клиент для iOS/iPadOS.", support: ["supported", "supported", "supported"], links: [{label: "App Store", url: "https://apps.apple.com/app/amneziawg/id6478942365"}], platforms: "iPhone, iPad", importMethod: ".conf, QR", bestFor: "Лёгкое подключение AWG на iOS.", limitation: "No normal per-app split tunneling due to iOS VPN limitations."},
      {name: "AmneziaVPN", status: "Full client", trafficSplit: "No app split / OS-limited", description: "Полный клиент Amnezia для iOS.", support: ["supported", "supported", "supported"], links: [{label: "App Store", url: "https://apps.apple.com/app/amnezia-vpn/id1600529900"}, {label: "Official", url: "https://amnezia.org/downloads"}], platforms: "iPhone, iPad", importMethod: "vpn:// URI, QR, app flow", bestFor: "Полный клиент Amnezia на iOS.", limitation: "iOS version may be unavailable in RU App Store region. No normal per-app split tunneling due to iOS VPN limitations."},
      {name: "DefaultVPN", status: "Fallback", trafficSplit: "No app split / OS-limited", description: "Альтернативный iOS-клиент.", support: ["supported", "supported", "warning"], links: [{label: "App Store", url: "https://apps.apple.com/app/defaultvpn/id6744725017"}], platforms: "iPhone, iPad", importMethod: ".conf", bestFor: "Запасной вариант для iOS.", limitation: "AWG 2.0 support should be treated cautiously. No normal per-app split tunneling due to iOS VPN limitations."},
      {name: "Clash Mi", status: "Experimental", trafficSplit: "Proxy rules", description: "Экспериментальный proxy-клиент, не основной AWG-клиент.", support: ["warning", "warning", "warning"], links: [{label: "App Store", url: "https://apps.apple.com/app/clash-mi/id6744321968"}], platforms: "iPhone, iPad", importMethod: "Proxy profiles", bestFor: "Proxy-rule based scenarios.", limitation: "Не основной AWG-клиент."},
    ],
  },
  {
    name: "macOS",
    icon: "apple",
    subtitle: "Универсальный full-client flow или лёгкий AWG-only путь.",
    clients: [
      {name: "AmneziaVPN", status: "Recommended / Full client", trafficSplit: "Routes / app features", description: "Лучший универсальный вариант для macOS.", support: ["supported", "supported", "supported"], links: [{label: "Official", url: "https://amnezia.org/downloads"}, {label: "GitHub", url: "https://github.com/amnezia-vpn/amnezia-client/releases"}], platforms: "macOS", importMethod: "vpn:// URI, QR, app flow", bestFor: "Полный Amnezia-клиент на macOS.", limitation: "Для лёгкого AWG-only сценария можно использовать AmneziaWG."},
      {name: "AmneziaWG", status: "Recommended", trafficSplit: "Routes only", description: "Лёгкий AWG-клиент для Apple ecosystem.", support: ["supported", "supported", "supported"], links: [{label: "App Store", url: "https://apps.apple.com/app/amneziawg/id6478942365"}], platforms: "macOS", importMethod: ".conf, QR", bestFor: "Лёгкий AWG-only клиент.", limitation: "Split tunneling в основном через маршруты."},
      {name: "VeilBox", status: "Experimental", trafficSplit: "TUN / proxy rules", description: "Альтернативный клиент.", support: ["unknown", "unknown", "warning"], links: [{label: "GitHub", url: "https://github.com/artem4150/VeilBox"}], platforms: "macOS", importMethod: "Depends on build", bestFor: "Экспериментальные гибридные сценарии.", limitation: "Не основной AWG-клиент."},
      {name: "Clash Verge Rev", status: "Experimental", trafficSplit: "Proxy rules", description: "Прокси-комбайн, не основной AWG-клиент.", support: ["warning", "warning", "warning"], links: [{label: "GitHub", url: "https://github.com/clash-verge-rev/clash-verge-rev/releases"}], platforms: "macOS", importMethod: "Proxy profiles", bestFor: "Proxy-rule based routing.", limitation: "Не основной AWG-клиент."},
    ],
  },
  {
    name: "Linux Desktop",
    icon: "linux",
    subtitle: "GUI-подключение для desktop Linux; proxy-клиенты остаются альтернативой.",
    clients: [
      {name: "AmneziaVPN", status: "Recommended", trafficSplit: "Routes / system rules", description: "Основной GUI-клиент для Linux Desktop.", support: ["supported", "supported", "supported"], links: [{label: "Official", url: "https://amnezia.org/downloads"}, {label: "GitHub", url: "https://github.com/amnezia-vpn/amnezia-client/releases"}], platforms: "Linux Desktop", importMethod: "vpn:// URI, QR, app flow", bestFor: "GUI-подключение на Linux.", limitation: "Для headless/server сценариев используются отдельные tools, но здесь показываются только OS-клиенты."},
      {name: "Clash Verge Rev", status: "Experimental", trafficSplit: "Proxy rules", description: "Прокси-комбайн, не основной AWG-клиент.", support: ["warning", "warning", "warning"], links: [{label: "GitHub", url: "https://github.com/clash-verge-rev/clash-verge-rev/releases"}], platforms: "Linux Desktop", importMethod: "Proxy profiles", bestFor: "Proxy-rule based routing.", limitation: "Не основной AWG-клиент."},
    ],
  },
  {
    name: "Routers / Embedded",
    icon: "router",
    subtitle: "Отдельный класс сценариев: не desktop/mobile apps, а маршрутизация устройств на уровне сети.",
    clients: [
      {name: "Keenetic", status: "Router", trafficSplit: "Routes / device rules", description: "Keenetic сценарий через Entware или прошивку с поддержкой AWG.", supportSummary: "depends on firmware / setup", links: [{label: "Guide", url: "https://gitlab.com/ShidlaSGC/keenetic-entware-awg-go/-/blob/main/README.md"}], platforms: "Keenetic routers", importMethod: "Firmware / Entware setup", bestFor: "Маршрутизация устройств через AWG на уровне роутера.", limitation: "Support depends on firmware and setup."},
      {name: "OpenWrt", status: "Router", trafficSplit: "Routes / firewall rules", description: "OpenWrt-сценарий для AWG на роутере.", supportSummary: "depends on package / build", links: [{label: "OpenWrt #1", url: "tg://resolve?domain=itdogchat&post=44512&comment=755535"}, {label: "OpenWrt #2", url: "tg://resolve?domain=itdogchat&post=44512&comment=759893"}], platforms: "OpenWrt routers", importMethod: "Package / build-specific setup", bestFor: "Policy routing, маршрутизация устройств и сетей через AWG.", limitation: "Package compatibility depends on OpenWrt version, target, subtarget and kernel ABI."},
    ],
  },
];

const helpSupportMeta = {
  supported: {icon: "✅", classes: "border-green-700/30 bg-green-500/10 text-green-700"},
  warning: {icon: "⚠️", classes: "border-amber-700/30 bg-amber-500/10 text-amber-700"},
  unsupported: {icon: "❌", classes: "border-[var(--danger)] bg-red-500/10 text-[var(--danger)]"},
  unknown: {icon: "?", classes: "border-[var(--line)] bg-[var(--panel)] text-[var(--muted)]"},
  custom: {icon: "◇", classes: "border-violet-700/30 bg-violet-500/10 text-violet-700"},
};

const helpStatusClasses = {
  Recommended: "border-green-700/30 bg-green-500/10 text-green-700",
  "Recommended / Advanced": "border-sky-700/30 bg-sky-500/10 text-sky-700",
  "Recommended / Full client": "border-green-700/30 bg-green-500/10 text-green-700",
  "Full client": "border-[var(--accent)] bg-[var(--panel)] text-[var(--accent)]",
  Advanced: "border-sky-700/30 bg-sky-500/10 text-sky-700",
  Fallback: "border-amber-700/30 bg-amber-500/10 text-amber-700",
  Experimental: "border-[var(--line)] bg-[var(--panel)] text-[var(--muted)]",
  Router: "border-violet-700/30 bg-violet-500/10 text-violet-700",
};

function renderHelpSupportBadge(label, support) {
  const detail = typeof support === "string" ? {state: support} : support;
  const meta = helpSupportMeta[detail.state] || helpSupportMeta.unknown;
  const text = detail.text || `${meta.icon} ${label}`;
  return `<span class="inline-flex items-center rounded-full border px-2 py-1 text-[11px] font-medium ${meta.classes}">${esc(text)}</span>`;
}

function renderHelpTrafficSplitBadge(value) {
  return `<span class="inline-flex items-center rounded-full border border-[var(--line)] bg-[var(--panel)] px-2 py-1 text-[11px] font-medium text-[var(--text)]">↔ ${esc(value)}</span>`;
}

function renderHelpLinks(links) {
  return links.map(link => `<a class="${buttonClasses("h-7 px-2 text-xs")}" href="${esc(link.url)}" target="_blank" rel="noopener">${esc(link.label)}</a>`).join("");
}

function renderHelpClientCard(client) {
  const support = client.supportSummary
    ? `<span class="inline-flex items-center rounded-full border border-violet-700/30 bg-violet-500/10 px-2 py-1 text-[11px] font-medium text-violet-700">◇ AWG ${esc(client.supportSummary)}</span>`
    : `${renderHelpSupportBadge("AWG 1.x", client.support[0])}${renderHelpSupportBadge("AWG 1.5", client.support[1])}${renderHelpSupportBadge("AWG 2.0", client.support[2])}`;
  return `
    <article class="rounded-lg border border-[var(--line)] bg-[var(--soft)] p-3 transition hover:border-[var(--accent)]">
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div class="min-w-0">
          <h4 class="font-semibold">${esc(client.name)}</h4>
          <p class="mt-1 text-xs text-[var(--muted)]">${esc(client.description)}</p>
        </div>
        <span class="inline-flex rounded-full border px-2 py-1 text-[11px] font-medium ${helpStatusClasses[client.status] || helpStatusClasses.Experimental}">${esc(client.status)}</span>
      </div>
      <div class="mt-3 flex flex-wrap gap-1.5">${support}</div>
      <div class="mt-2 flex flex-wrap gap-1.5">${renderHelpTrafficSplitBadge(client.trafficSplit)}</div>
      <div class="mt-3 flex flex-wrap gap-2">${renderHelpLinks(client.links)}</div>
      <details class="mt-3 rounded-md border border-[var(--line)] bg-[var(--panel)] px-3 py-2 text-xs text-[var(--muted)]">
        <summary class="cursor-pointer font-medium text-[var(--text)]">Details</summary>
        <div class="mt-2 grid gap-1.5">
          <p><span class="font-semibold text-[var(--text)]">Platforms:</span> ${esc(client.platforms)}</p>
          <p><span class="font-semibold text-[var(--text)]">Import:</span> ${esc(client.importMethod)}</p>
          <p><span class="font-semibold text-[var(--text)]">Traffic split:</span> ${esc(client.trafficSplit)}</p>
          <p><span class="font-semibold text-[var(--text)]">Best for:</span> ${esc(client.bestFor)}</p>
          <p><span class="font-semibold text-[var(--text)]">Limitations / notes:</span> ${esc(client.limitation)}</p>
        </div>
      </details>
    </article>
  `;
}

function renderHelpGroup(group) {
  return `
    <section class="overflow-hidden rounded-xl border border-[var(--line)] bg-[var(--panel)]">
      <div class="flex items-start gap-3 border-b border-[var(--line)] bg-[var(--soft)] px-3 py-3">
        <span class="mt-0.5 text-[var(--accent)]">${icon(group.icon)}</span>
        <div>
          <h3 class="font-semibold">${esc(group.name)}</h3>
          <p class="mt-0.5 text-xs text-[var(--muted)]">${esc(group.subtitle)}</p>
        </div>
      </div>
      <div class="grid gap-3 p-3 md:grid-cols-2">
        ${group.clients.map(renderHelpClientCard).join("")}
      </div>
    </section>
  `;
}

function showHelp() {
  showModal("Help & Clients", `
    <div class="grid gap-4 text-sm">
      <div class="rounded-lg border border-[var(--danger)] bg-[var(--soft)] px-3 py-3">
        <p class="font-bold text-[var(--danger)]">⚠️ Standard WireGuard clients WILL NOT WORK with AmneziaWG configs.</p>
        <p class="mt-1 text-xs text-[var(--muted)]">Если клиент ругается на неизвестные параметры S3, S4, I1 или H1, нужен клиент с полной поддержкой AWG 2.0.</p>
      </div>
      <div class="rounded-lg border border-[var(--line)] bg-[var(--soft)] px-3 py-3 text-xs text-[var(--muted)]">
        <p class="font-semibold text-[var(--text)]">Voice / Calls optimization</p>
        <p class="mt-1">MTU 1280 · PersistentKeepalive 25 · UDP conntrack timeout tuning · Full Cone NAT: not enabled by default · XUDP: not applicable to AWG.</p>
      </div>
      <div class="rounded-lg border border-[var(--line)] bg-[var(--soft)] px-3 py-3 text-xs text-[var(--muted)]">
        <p class="font-semibold text-[var(--text)]">WG Tunnel URL Import</p>
        <p class="mt-1">Copy import URL creates a token-protected HTTPS link that returns raw config text starting with [Interface]. Links expire after 1 hour by default. WG Tunnel requires HTTPS; a self-signed certificate may be rejected by the app. Use a trusted domain/certificate for best results.</p>
      </div>
      <div class="grid gap-4">
        ${helpClientGroups.map(renderHelpGroup).join("")}
      </div>
    </div>
  `);
}

async function addClient() {
  const name = await clientNameModal();
  if (!name) return;
  try {
    await api("/api/clients", {method: "POST", body: JSON.stringify({name})});
    showToast("Client added");
    await loadClients();
    if (statusState.role === "super") await loadTokens();
  } catch (error) {
    showToast("Could not add client", "error");
  }
}

async function clientAction(name, action) {
  try {
    if (action === "config") return showConfig(name);
    if (action === "qr") return showQr(name);
    if (action === "vpnuri") return showVpnUri(name);
    if (action === "download-config") return downloadConfig(name);
    if (action === "copy-config") return copyConfig(name);
    if (action === "copy-vpnuri") return copyVpnUri(name);
    if (action === "copy-import-url") return copyImportUrl(name);
    if (action === "regenerate-config") return regenerateConfig(name);
    if (action === "toggle") {
      await api(`/api/clients/${encodeURIComponent(name)}/toggle`, {method: "POST", body: "{}"});
      showToast("Client toggled");
      return loadClients();
    }
    if (action === "toggle-p2p") {
      await api(`/api/clients/${encodeURIComponent(name)}/p2p/toggle`, {method: "POST", body: "{}"});
      showToast("P2P ports toggled");
      return loadClients();
    }
    if (action === "delete") {
      const ok = await confirmModal("Delete Client", `Delete ${name}?`, "Delete", true);
      if (!ok) return;
      await api(`/api/clients/${encodeURIComponent(name)}`, {method: "DELETE"});
      showToast("Client deleted");
      await loadClients();
      if (statusState.role === "super") await loadTokens();
    }
  } catch (error) {
    showToast("Failed", "error");
  }
}

async function regenerateConfig(name) {
  const ok = await confirmModal(
    "Regenerate config",
    `Regenerate config for "${name}"?\nThe old client config will stop working. Traffic history and client name will be preserved.`,
    "Regenerate",
    false
  );
  if (!ok) return;
  const body = {};
  try {
    if (typeof window.generateAwgI1 === "function" && typeof window.pickAwgI1Sni === "function" && window.crypto?.subtle) {
      const sni = window.pickAwgI1Sni();
      body.i1 = await window.generateAwgI1(sni, 0);
      body.i1_sni = sni;
    }
  } catch (error) {
    const fallback = await confirmModal(
      "Regenerate without browser I1?",
      "Browser-side AWG I1 generation failed. Continue with server fallback?",
      "Continue",
      false
    );
    if (!fallback) return;
  }
  await api(`/api/clients/${encodeURIComponent(name)}/regenerate`, {method: "POST", body: JSON.stringify(body)});
  configTextCache.delete(name);
  showToast("Config regenerated. Download or copy the new config.");
  await loadClients();
}

async function rotateServerProfile() {
  const ok = await confirmModal(
    "Rotate AWG profile",
    "This will rotate server AWG obfuscation parameters and regenerate all client configs. Existing client configs will stop working. Continue?",
    "Continue",
    false
  );
  if (!ok) return;
  const confirm = await promptModal("Type ROTATE", "ROTATE");
  if (confirm !== "ROTATE") {
    showToast("Rotation cancelled", "error");
    return;
  }
  const preset = await promptModal("Preset", "mobile or default", "mobile");
  if (!["mobile", "default"].includes(preset)) {
    showToast("Invalid preset", "error");
    return;
  }
  const client_i1 = {};
  try {
    if (typeof window.generateAwgI1 === "function" && typeof window.pickAwgI1Sni === "function" && window.crypto?.subtle) {
      for (const client of latestClients) {
        const sni = window.pickAwgI1Sni();
        client_i1[client.name] = await window.generateAwgI1(sni, 0);
      }
    }
  } catch {
    showToast("Browser I1 generation failed; using server fallback", "error");
  }
  await api("/api/server/rotate-profile", {
    method: "POST",
    body: JSON.stringify({preset, confirm: "ROTATE", client_i1}),
  });
  configTextCache.clear();
  showToast("Server profile rotated. Download or import new client configs.");
  await loadClients();
}

async function showConfig(name) {
  const text = await configText(name);
  showModal(name, `
    <div class="grid gap-3">
      <div class="flex flex-wrap justify-end gap-2">
        <button id="downloadConfigFromModal" class="${buttonClasses()}">${icon("download")}<span>Download .conf</span></button>
        <button id="copyConfigFromModal" class="${buttonClasses()}">${icon("copy")}<span>Copy config</span></button>
      </div>
      <pre class="max-h-[70vh] overflow-auto whitespace-pre-wrap break-words rounded-md bg-[var(--soft)] p-3 text-xs">${esc(text)}</pre>
    </div>
  `);
  document.querySelector("#downloadConfigFromModal").onclick = async () => downloadConfig(name);
  document.querySelector("#copyConfigFromModal").onclick = async () => copyConfig(name);
}

async function downloadConfig(name) {
  const blob = await api(`/api/clients/${encodeURIComponent(name)}/config/download`);
  saveBlob(blob, `${name}.conf`);
  showToast("Downloaded");
}

async function copyConfig(name) {
  const text = await configText(name);
  await copyText(text);
  showToast("Copied");
}

async function showQr(name) {
  const blob = await api(`/api/clients/${encodeURIComponent(name)}/qr`);
  const url = URL.createObjectURL(blob);
  showModal(name, `<img class="mx-auto max-h-[70vh] max-w-full rounded-md bg-white p-2" alt="QR" src="${url}">`);
}

async function showVpnUri(name) {
  const blob = await api(`/api/clients/${encodeURIComponent(name)}/vpnuri`);
  const uri = (await blob.text()).trim();
  showModal(name, `
    <div class="grid gap-3">
      <textarea readonly class="h-32 w-full resize-none rounded-md border border-[var(--line)] bg-[var(--soft)] p-3 font-mono text-xs text-[var(--text)] outline-none">${esc(uri)}</textarea>
      <div class="flex flex-wrap justify-end gap-2">
        <a href="${esc(uri)}" class="${buttonClasses()}">${icon("external")}<span>Open</span></a>
        <button id="copyVpnUri" class="${buttonClasses()}">${icon("copy")}<span>Copy</span></button>
      </div>
    </div>
  `);
  document.querySelector("#copyVpnUri").onclick = async () => {
    await copyText(uri);
    showToast("Copied");
  };
}

async function copyVpnUri(name) {
  const blob = await api(`/api/clients/${encodeURIComponent(name)}/vpnuri`);
  await copyText((await blob.text()).trim());
  showToast("Copied");
}

async function copyImportUrl(name) {
  const result = await api(`/api/clients/${encodeURIComponent(name)}/import-link`, {
    method: "POST",
    body: JSON.stringify({ttl: 3600, one_time: false}),
  });
  await copyText(result.url);
  showToast("Import URL copied");
}

async function loadTokens() {
  const data = await api("/api/tokens");
  latestTokens = data.users || [];
  renderTokenList();
}

function tokenTraffic(clients) {
  const allowed = new Set(clients || []);
  return latestClients.reduce((total, client) => {
    if (!allowed.has(client.name)) return total;
    const item = client.traffic_total || {};
    total.rx += Number(item.rx || 0);
    total.tx += Number(item.tx || 0);
    total.total += Number(item.total || Number(item.rx || 0) + Number(item.tx || 0));
    return total;
  }, {rx: 0, tx: 0, total: 0});
}

function renderTokenList() {
  const panel = document.querySelector("#tokenList");
  if (!panel) return;
  panel.innerHTML = latestTokens.length ? latestTokens.map(row => {
    const stats = tokenTraffic(row.clients);
    const label = row.name || "Unnamed token";
    return `
    <div class="flex flex-wrap items-center justify-between gap-3 rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 py-2">
      <div class="min-w-0">
        <p class="truncate text-sm font-semibold">${esc(label)}</p>
        <p class="truncate font-mono text-xs">${esc(row.hash)}</p>
        <p class="mt-1 text-xs text-[var(--muted)]">${esc((row.clients || []).join(", ") || "no clients")}</p>
        <p class="mt-1 text-xs text-[var(--muted)]">Traffic: ${esc(bytes(stats.total))} (${esc(trafficText(stats.rx, stats.tx))})</p>
      </div>
      <div class="flex flex-wrap gap-2">
        <button data-edit-name="${esc(row.hash)}" title="Edit Name" class="${buttonClasses("w-9 px-0")}">${icon("pencil")}</button>
        <button data-rotate="${esc(row.hash)}" title="Rotate user token" class="${buttonClasses()}">${icon("key")}<span>Rotate Token</span></button>
        <button data-revoke="${esc(row.hash)}" class="${buttonClasses("text-[var(--danger)]")}">${icon("trash")}<span>Revoke</span></button>
      </div>
    </div>
  `;
  }).join("") : `<p class="text-sm text-[var(--muted)]">No user tokens yet.</p>`;
  panel.querySelectorAll("[data-edit-name]").forEach(btn => {
    btn.onclick = async () => {
      const row = latestTokens.find(item => item.hash === btn.dataset.editName);
      const name = await promptModal("Edit Name", "Token name", row?.name || "");
      if (name === null) return;
      try {
        await api(`/api/tokens/${encodeURIComponent(btn.dataset.editName)}/name`, {
          method: "PUT",
          body: JSON.stringify({name}),
        });
        showToast("Token name updated");
        await loadTokens();
      } catch {
        showToast("Could not update token name", "error");
      }
    };
  });
  panel.querySelectorAll("[data-rotate]").forEach(btn => {
    btn.onclick = async () => {
      const result = await api(`/api/tokens/${encodeURIComponent(btn.dataset.rotate)}/rotate`, {method: "POST", body: "{}"});
      try {
        if (navigator.clipboard) await navigator.clipboard.writeText(result.token);
      } catch {
        // Clipboard access depends on browser policy; the token is still displayed.
      }
      showModal("Rotated Token", `
        <p class="mb-2 text-sm text-[var(--muted)]">Access list preserved: ${esc((result.clients || []).join(", ") || "no clients")}.</p>
        <div class="flex gap-2">
          <pre class="min-w-0 flex-1 overflow-auto rounded-md bg-[var(--soft)] p-3 text-xs">${esc(result.token)}</pre>
          <button id="copyRotatedToken" class="${buttonClasses("w-9 px-0")}">${icon("copy")}</button>
        </div>
      `);
      document.querySelector("#copyRotatedToken").onclick = async () => {
        await copyText(result.token);
        showToast("Token copied");
      };
      await loadTokens();
    };
  });
  panel.querySelectorAll("[data-revoke]").forEach(btn => {
    btn.onclick = async () => {
      await api(`/api/tokens/${encodeURIComponent(btn.dataset.revoke)}`, {method: "DELETE"});
      showToast("Token revoked");
      await loadTokens();
    };
  });
}

async function newToken() {
  const body = latestClients.map(client => `
    <label class="flex items-center gap-2 rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 py-2 text-sm">
      <input class="client-token-check" type="checkbox" value="${esc(client.name)}">
      <span>${esc(client.name)}</span>
    </label>
  `).join("") || `<p class="text-sm text-[var(--muted)]">Create clients first or issue an empty token.</p>`;
  const ok = await showModal("Generate Token", `
    <div class="grid gap-2">${body}</div>
    <div class="mt-4 flex justify-end">
      <button id="createTokenConfirm" class="${primaryButtonClasses()}">${icon("key")}<span>Create</span></button>
    </div>
  `, false);
  if (!ok) return;
}

async function createTokenFromModal(dialog) {
  const clients = Array.from(dialog.querySelectorAll(".client-token-check:checked")).map(input => input.value);
  const result = await api("/api/tokens", {method: "POST", body: JSON.stringify({clients})});
  try {
    if (navigator.clipboard) await navigator.clipboard.writeText(result.token);
  } catch {
    // Clipboard access depends on browser policy; the token is still displayed.
  }
  dialog.close();
  showModal("New Token", `
    <p class="mb-2 text-sm text-[var(--muted)]">Token copied when browser policy allowed it.</p>
    <div class="flex gap-2">
      <pre class="min-w-0 flex-1 overflow-auto rounded-md bg-[var(--soft)] p-3 text-xs">${esc(result.token)}</pre>
      <button id="copyToken" class="${buttonClasses("w-9 px-0")}">${icon("copy")}</button>
    </div>
  `);
  document.querySelector("#copyToken").onclick = async () => {
    await copyText(result.token);
    showToast("Token copied");
  };
  await loadTokens();
}

function confirmDialogOnEnter(dialog, onConfirm) {
  dialog.addEventListener("keydown", event => {
    if (event.key !== "Enter" || event.target instanceof HTMLTextAreaElement) return;
    if (event.target instanceof HTMLButtonElement || event.target instanceof HTMLAnchorElement) return;
    event.preventDefault();
    onConfirm();
  });
}

function showModal(title, body, closeOnButton = true) {
  return new Promise(resolve => {
    const dialog = document.createElement("dialog");
    dialog.className = "w-[min(680px,calc(100vw-32px))] rounded-lg border border-[var(--line)] bg-[var(--panel)] p-0 text-[var(--text)] shadow-xl backdrop:bg-black/55";
    dialog.innerHTML = `
      <form method="dialog" class="p-4">
        <div class="mb-4 flex items-center justify-between gap-3">
          <h2 class="text-base font-semibold">${esc(title)}</h2>
          <button value="cancel" class="${buttonClasses("w-9 px-0")}">x</button>
        </div>
        <div>${body}</div>
      </form>
    `;
    document.body.appendChild(dialog);
    dialog.addEventListener("close", () => {
      const accepted = dialog.returnValue === "ok";
      dialog.remove();
      resolve(accepted);
    }, {once: true});
    dialog.addEventListener("click", event => {
      if (event.target === dialog) dialog.close("cancel");
    });
    dialog.showModal();
    const create = dialog.querySelector("#createTokenConfirm");
    if (create) create.onclick = async event => {
      event.preventDefault();
      await createTokenFromModal(dialog);
    };
    confirmDialogOnEnter(dialog, () => {
      if (create) {
        create.click();
        return;
      }
      dialog.close("ok");
    });
    if (closeOnButton) resolve(true);
  });
}

function promptModal(title, placeholder, value = "") {
  return new Promise(resolve => {
    const dialog = document.createElement("dialog");
    dialog.className = "w-[min(420px,calc(100vw-32px))] rounded-lg border border-[var(--line)] bg-[var(--panel)] p-0 text-[var(--text)] shadow-xl backdrop:bg-black/55";
    dialog.innerHTML = `
      <form method="dialog" class="p-4">
        <h2 class="mb-4 text-base font-semibold">${esc(title)}</h2>
        <input id="promptValue" class="h-11 w-full rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 outline-none focus:border-[var(--accent)]" placeholder="${esc(placeholder)}" value="${esc(value)}">
        <div class="mt-4 flex justify-end gap-2">
          <button value="cancel" class="${buttonClasses()}">Cancel</button>
          <button value="ok" class="${primaryButtonClasses()}">OK</button>
        </div>
      </form>
    `;
    document.body.appendChild(dialog);
    dialog.addEventListener("close", () => {
      const value = dialog.returnValue === "ok" ? dialog.querySelector("#promptValue").value.trim() : null;
      dialog.remove();
      resolve(value);
    }, {once: true});
    dialog.showModal();
    const input = dialog.querySelector("#promptValue");
    input.addEventListener("keydown", event => {
      if (event.key !== "Enter") return;
      event.preventDefault();
      dialog.close("ok");
    });
    input.focus();
  });
}

function clientNameModal() {
  return new Promise(resolve => {
    const dialog = document.createElement("dialog");
    dialog.className = "w-[min(420px,calc(100vw-32px))] rounded-lg border border-[var(--line)] bg-[var(--panel)] p-0 text-[var(--text)] shadow-xl backdrop:bg-black/55";
    dialog.innerHTML = `
      <form method="dialog" class="p-4">
        <h2 class="mb-4 text-base font-semibold">Add Client</h2>
        <label class="sr-only" for="clientNameValue">Client name</label>
        <input id="clientNameValue" class="h-11 w-full rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 outline-none focus:border-[var(--accent)]" placeholder="my_phone" autocomplete="off">
        <p class="mt-2 text-xs text-[var(--muted)]">Examples: my_phone, iphone_15, laptop-home</p>
        <p id="clientNameHint" class="mt-2 hidden text-xs text-[var(--danger)]">${esc(CLIENT_NAME_HINT_RU)} / ${esc(CLIENT_NAME_HINT_EN)}</p>
        <div class="mt-4 flex justify-end gap-2">
          <button value="cancel" class="${buttonClasses()}">Cancel</button>
          <button id="createClientButton" value="ok" class="${primaryButtonClasses()}" disabled>Create</button>
        </div>
      </form>
    `;
    document.body.appendChild(dialog);
    const input = dialog.querySelector("#clientNameValue");
    const hint = dialog.querySelector("#clientNameHint");
    const create = dialog.querySelector("#createClientButton");
    const validate = () => {
      const value = input.value.trim();
      const ok = CLIENT_NAME_RE.test(value);
      create.disabled = !ok;
      input.classList.toggle("border-[var(--danger)]", value.length > 0 && !ok);
      hint.classList.toggle("hidden", value.length === 0 || ok);
    };
    input.addEventListener("input", validate);
    input.addEventListener("keydown", event => {
      if (event.key !== "Enter") return;
      event.preventDefault();
      validate();
      if (!create.disabled) dialog.close("ok");
    });
    dialog.addEventListener("close", () => {
      const value = dialog.returnValue === "ok" ? input.value.trim() : null;
      dialog.remove();
      resolve(value);
    }, {once: true});
    dialog.showModal();
    input.focus();
    validate();
  });
}

function confirmModal(title, message, confirmLabel = "Continue", danger = true) {
  return new Promise(resolve => {
    const dialog = document.createElement("dialog");
    dialog.className = "w-[min(420px,calc(100vw-32px))] rounded-lg border border-[var(--line)] bg-[var(--panel)] p-0 text-[var(--text)] shadow-xl backdrop:bg-black/55";
    dialog.innerHTML = `
      <form method="dialog" class="p-4">
        <h2 class="mb-2 text-base font-semibold">${esc(title)}</h2>
        <p class="text-sm text-[var(--muted)]">${esc(message)}</p>
        <div class="mt-4 flex justify-end gap-2">
          <button value="cancel" class="${buttonClasses()}">Cancel</button>
          <button value="ok" class="${buttonClasses(danger ? "border-[var(--danger)] bg-[var(--danger)] text-white" : "border-amber-600 bg-amber-500 text-white")}">${esc(confirmLabel)}</button>
        </div>
      </form>
    `;
    document.body.appendChild(dialog);
    dialog.addEventListener("close", () => {
      const ok = dialog.returnValue === "ok";
      dialog.remove();
      resolve(ok);
    }, {once: true});
    confirmDialogOnEnter(dialog, () => dialog.close("ok"));
    dialog.showModal();
  });
}

async function boot() {
  if (!token) {
    renderLogin();
    return;
  }
  try {
    statusState = await api("/api/status");
    await renderPanel();
  } catch {
    renderLogin();
  }
}

boot();
