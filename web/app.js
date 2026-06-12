const app = document.querySelector("#app");
const toastHost = document.querySelector("#toastHost");
localStorage.removeItem("panelToken");
let token = sessionStorage.getItem("panelToken") || "";
let statusState = null;
let resolverState = null;
let trafficState = null;
let webAccessPolicyState = null;
let geoipProvidersState = null;
let geoipDatabasesState = null;
let serverHealthState = null;
let serverHealthHistoryState = null;
let clientLatencyState = null;
let clientPathState = {results: {}, running: {}, batchRunning: false, batchSummary: null};
let readinessState = null;
let readinessLoadedAt = 0;
let serverInfoState = null;
let nettestContextState = null;
let nettestReportsState = [];
let latestClients = [];
let latestTokens = [];
let ownerFilter = {mode: "all", tokens: []};
let helpClientGroups = null;
let pollTimer = null;
let healthTimer = null;
let latencyTimer = null;
let pollInFlight = false;
let healthInFlight = false;
let latencyInFlight = false;
let nettestRunning = false;
let activeNettestController = null;
let currentNettestRun = null;
let topTrafficMode = localStorage.getItem("topTrafficMode") || "30d";
let nettestNetworkType = localStorage.getItem("nettestNetworkType") || "mobile";
let nettestDuration = Number(localStorage.getItem("nettestDuration") || 180);
let serverHealthRange = localStorage.getItem("serverHealthRange") || "1h";
const ACTIVE_CLIENT_POLL_MS = 5000;
const HIDDEN_CLIENT_POLL_MS = 30000;
const SERVER_HEALTH_POLL_MS = 10000;
const CLIENT_LATENCY_POLL_MS = 60000;
const SERVER_HEALTH_RANGES = ["10m", "1h", "6h", "12h", "24h", "3d", "7d", "30d"];
const NETTEST_DURATIONS = {30: "Quick 30 s", 180: "Standard 3 min", 600: "Long 10 min"};
const NETTEST_PROBE_INTERVAL_MS = 1000;
const NETTEST_PING_TIMEOUT_MS = 2000;
const NETTEST_STALL_THRESHOLD = 3;
const NETTEST_PING_SAMPLES = 30;
const NETTEST_PING_INTERVAL_MS = 250;
const NETTEST_TIMEOUT_MS = 1800;
const WEBRTC_LEAK_TIMEOUT_MS = 2500;
const previousRx = new Map();
const previousTx = new Map();
const previousSampleAt = new Map();
const speedHistory = new Map();
const clientCharts = new Map();
const configTextCache = new Map();
let trafficChart = null;
let openClientMenu = null;
const CLIENT_ACTION_MENU_PORTAL_ID = "clientActionMenuPortal";
const CLIENT_NAME_RE = /^[A-Za-z0-9_-]+$/;
const CLIENT_NAME_HINT_RU = "Используйте только латиницу, цифры, дефис и подчёркивание: A-Z, a-z, 0-9, _ и -";
const CLIENT_NAME_HINT_EN = "Use only Latin letters, digits, underscore and hyphen: A-Z, a-z, 0-9, _ and -";

// --- Idle-aware polling ---------------------------------------------------
// After PANEL_IDLE_AFTER_MS without user activity (or while the tab is
// hidden), heavy polling (clients/geoip, server health, charts, nettest
// reports/context) is paused to a rare heartbeat, and an in-progress
// Network Tester run is stopped so it doesn't leave a stale active-test lock.
const PANEL_IDLE_AFTER_MS = 10 * 60 * 1000;
const PANEL_IDLE_HEARTBEAT_MS = 5 * 60 * 1000;
let panelLastActivityAt = Date.now();
let panelIdle = false;

function markPanelActivity() {
  panelLastActivityAt = Date.now();
  if (panelIdle && !document.hidden) onPanelResume();
}

function isPanelIdle() {
  if (document.hidden) return true;
  return Date.now() - panelLastActivityAt > PANEL_IDLE_AFTER_MS;
}

function shouldPollHeavy() {
  return Boolean(token) && !isNetworkTesterPage() && !isPanelIdle();
}

function updatePanelIdleNote() {
  const note = document.querySelector("#panelIdleNote");
  if (note) note.classList.toggle("hidden", !panelIdle);
  updateConnectionPill();
}

// One-shot refresh + restart polling when the panel comes back from idle.
function onPanelResume() {
  const wasIdle = panelIdle;
  panelIdle = false;
  updatePanelIdleNote();
  if (!wasIdle || isNetworkTesterPage() || !token || !statusState) return;
  loadClients();
  startClientPolling();
  if (statusState.role === "super") {
    loadServerHealth();
    loadClientLatency();
    loadNettestReports();
    startServerHealthPolling();
    startClientLatencyPolling();
  }
}

// Re-evaluate idle state; called from poll ticks and the Network Tester loop.
function checkPanelIdle() {
  const idleNow = isPanelIdle();
  if (idleNow === panelIdle) return panelIdle;
  panelIdle = idleNow;
  updatePanelIdleNote();
  if (!idleNow) onPanelResume();
  return panelIdle;
}

["mousemove", "mousedown", "keydown", "scroll", "touchstart", "focus"].forEach(evt => {
  document.addEventListener(evt, markPanelActivity, {passive: true});
});

// ---------------------------------------------------------------------------
// Header connection status pill: Online / Updating... / Paused / Offline /
// Reconnecting..., derived from in-flight api() calls, fetch-level
// connectivity (apiConnectivityOk), the browser's online/offline events, and
// the existing idle/paused state above.
// ---------------------------------------------------------------------------
const CONNECTION_PILL_BASE = "connection-status-pill inline-flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-xs font-medium";
const CONNECTION_STATE_INFO = {
  online: {label: "Online", className: "border-green-600/30 bg-green-500/10 text-green-700 dark:text-green-400"},
  updating: {label: "Updating...", className: "border-[var(--accent)]/30 bg-[var(--accent)]/10 text-[var(--accent)] animate-pulse"},
  paused: {label: "Paused", className: "border-[var(--line)] bg-[var(--soft)] text-[var(--muted)]"},
  offline: {label: "Offline", className: "border-[var(--danger)]/30 bg-[var(--danger)]/10 text-[var(--danger)]"},
  reconnecting: {label: "Reconnecting...", className: "border-amber-500/30 bg-amber-500/10 text-amber-600 animate-pulse"},
};

let apiInFlightCount = 0;
let apiConnectivityOk = true;
let connectionState = "online";

function computeConnectionState() {
  if (!navigator.onLine) return "offline";
  if (!apiConnectivityOk) return "reconnecting";
  if (apiInFlightCount > 0) return "updating";
  if (panelIdle) return "paused";
  return "online";
}

function updateConnectionPill() {
  connectionState = computeConnectionState();
  const pill = document.querySelector("#connectionStatusPill");
  if (!pill) return;
  const info = CONNECTION_STATE_INFO[connectionState] || CONNECTION_STATE_INFO.online;
  pill.textContent = info.label;
  pill.className = `${CONNECTION_PILL_BASE} ${info.className}`;
  pill.title = `Connection: ${info.label}`;
}

window.addEventListener("online", updateConnectionPill);
window.addEventListener("offline", updateConnectionPill);

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
  save: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2Z"/><path d="M17 21v-8H7v8M7 3v5h8"/></svg>',
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
document.addEventListener("scroll", () => {
  if (openClientMenu) closeClientMenus();
}, true);
window.addEventListener("resize", () => {
  if (openClientMenu) closeClientMenus();
});
window.addEventListener("beforeunload", () => {
  stopNettest({reason: "unload"});
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
  apiInFlightCount += 1;
  updateConnectionPill();
  try {
    const response = await fetch(path, Object.assign({}, opt, {headers}));
    apiConnectivityOk = true;
    if (!response.ok) {
      const text = await response.text();
      throw new Error(text || response.statusText);
    }
    const ctype = response.headers.get("content-type") || "";
    return ctype.includes("application/json") ? response.json() : response.blob();
  } catch (error) {
    if (error instanceof TypeError) apiConnectivityOk = false;
    throw error;
  } finally {
    apiInFlightCount = Math.max(0, apiInFlightCount - 1);
    updateConnectionPill();
  }
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
  const bytesPerSecond = Number(n) || 0;
  const mbps = bytesPerSecond * 8 / 1000 / 1000;
  return `${mbps.toFixed(mbps >= 10 ? 1 : 2)} Mbps`;
}

function isNetworkTesterPage() {
  return window.location.pathname.replace(/\/+$/, "") === "/nettest";
}

function isDirectNettestMode() {
  return window.location.port === "8088" ||
    (window.location.protocol === "http:" && window.location.hostname === "10.9.9.1");
}

function nettestApiBase() {
  return isDirectNettestMode() ? "/api/nettest-public" : "/api/nettest";
}

async function fetchNettestProbe(path, options = {}, timeoutMs = NETTEST_TIMEOUT_MS) {
  if (isDirectNettestMode()) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    const detach = attachNettestAbort(controller);
    try {
      const response = await fetch(path, Object.assign({}, options, {signal: controller.signal}));
      if (!response.ok) throw new Error(response.statusText || "request failed");
      return response;
    } finally {
      clearTimeout(timer);
      detach();
    }
  }
  return fetchWithTimeout(path, options, timeoutMs);
}

async function apiNettest(path, opt = {}) {
  if (isDirectNettestMode()) {
    const headers = Object.assign({}, opt.headers || {});
    if (opt.body && !(opt.body instanceof FormData)) headers["Content-Type"] = "application/json";
    apiInFlightCount += 1;
    updateConnectionPill();
    try {
      const response = await fetch(path, Object.assign({}, opt, {headers}));
      apiConnectivityOk = true;
      if (!response.ok) {
        const text = await response.text();
        throw new Error(text || response.statusText);
      }
      const ctype = response.headers.get("content-type") || "";
      return ctype.includes("application/json") ? response.json() : response.blob();
    } catch (error) {
      if (error instanceof TypeError) apiConnectivityOk = false;
      throw error;
    } finally {
      apiInFlightCount = Math.max(0, apiInFlightCount - 1);
      updateConnectionPill();
    }
  }
  return api(path, opt);
}

function shortValue(value, fallback = "-") {
  return value === null || value === undefined || value === "" ? fallback : String(value);
}

function clientTraffic(data = {}) {
  const serverRx = Number(data.server_rx ?? data.rx ?? 0);
  const serverTx = Number(data.server_tx ?? data.tx ?? 0);
  const download = Number(data.client_download ?? serverTx);
  const upload = Number(data.client_upload ?? serverRx);
  return {download, upload, total: Number(data.total ?? download + upload), serverRx, serverTx};
}

function clientTrafficFromSpeeds(client) {
  return {
    download: Number(client.clientDownloadSpeedBps ?? client.txSpeedBps ?? 0),
    upload: Number(client.clientUploadSpeedBps ?? client.rxSpeedBps ?? 0),
  };
}

function trafficText(data = {}, mode = "traffic") {
  const stats = data.download === undefined || data.upload === undefined ? clientTraffic(data) : data;
  return mode === "now"
    ? `↓ ${speed(stats.download)} · ↑ ${speed(stats.upload)}`
    : `Download ${bytes(stats.download)} · Upload ${bytes(stats.upload)}`;
}

function trafficMetricRow(label, data = {}) {
  const stats = clientTraffic(data);
  return `
    <div class="traffic-metric-row" title="Download: traffic sent to this client. Upload: traffic received from this client.">
      <span class="traffic-metric-label">${esc(label)}</span>
      <span><span class="traffic-metric-name">Download</span> ${esc(bytes(stats.download))}</span>
      <span><span class="traffic-metric-name">Upload</span> ${esc(bytes(stats.upload))}</span>
    </div>
  `;
}

function normalizePortList(value) {
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
  sessionStorage.removeItem("panelToken");
  token = "";
  stopClientPolling();
  stopServerHealthPolling();
  document.title = "Control";
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
  const portal = document.getElementById(CLIENT_ACTION_MENU_PORTAL_ID);
  if (!except && portal) {
    portal.classList.add("hidden");
    portal.innerHTML = "";
    portal.removeAttribute("data-client-name");
    portal.removeAttribute("data-source-menu");
  }
  document.querySelectorAll(".client-menu").forEach(menu => {
    if (menu.id === CLIENT_ACTION_MENU_PORTAL_ID) return;
    if (except && menu.id === except) return;
    menu.classList.add("hidden");
    const btn = document.querySelector(`[aria-controls="${menu.id}"]`);
    if (btn) btn.setAttribute("aria-expanded", "false");
    menu.closest(".client-card")?.classList.remove("client-card-menu-open");
  });
  if (!except) openClientMenu = null;
}

function clientActionMenuPortal() {
  let portal = document.getElementById(CLIENT_ACTION_MENU_PORTAL_ID);
  if (portal) return portal;
  portal = document.createElement("div");
  portal.id = CLIENT_ACTION_MENU_PORTAL_ID;
  portal.className = "client-menu client-menu-portal hidden";
  portal.setAttribute("role", "menu");
  portal.addEventListener("click", event => {
    const item = event.target.closest("[data-action]");
    if (!item) return;
    const name = portal.dataset.clientName;
    closeClientMenus();
    if (name) clientAction(name, item.dataset.action);
  });
  document.body.appendChild(portal);
  return portal;
}

function positionClientActionMenu(button, menu) {
  const margin = 8;
  const gap = 6;
  const rect = button.getBoundingClientRect();
  menu.classList.remove("hidden");
  menu.style.visibility = "hidden";
  menu.style.width = "";
  const menuRect = menu.getBoundingClientRect();
  const width = Math.min(menuRect.width || 208, window.innerWidth - margin * 2);
  const height = menuRect.height || 0;
  const spaceBelow = window.innerHeight - rect.bottom - margin;
  const spaceAbove = rect.top - margin;
  const openUp = spaceBelow < height + gap && spaceAbove > spaceBelow;
  let top = openUp ? rect.top - height - gap : rect.bottom + gap;
  top = Math.max(margin, Math.min(top, window.innerHeight - height - margin));
  let left = rect.right - width;
  if (left < margin) left = rect.left;
  left = Math.max(margin, Math.min(left, window.innerWidth - width - margin));
  menu.style.top = `${top}px`;
  menu.style.left = `${left}px`;
  menu.style.width = `${width}px`;
  menu.dataset.placement = openUp ? "top" : "bottom";
  menu.style.visibility = "";
}

function openClientActionMenu(button) {
  const id = button.dataset.menuToggle;
  const template = document.getElementById(id);
  const card = button.closest(".client-card");
  if (!template || !card) return;
  closeClientMenus(id);
  const portal = clientActionMenuPortal();
  portal.innerHTML = template.innerHTML;
  portal.dataset.clientName = card.dataset.name;
  portal.dataset.sourceMenu = id;
  positionClientActionMenu(button, portal);
  button.setAttribute("aria-expanded", "true");
  card.classList.add("client-card-menu-open");
  openClientMenu = id;
}

function renderPortSummary(ports, disabled) {
  if (!ports.length) return "";
  const chips = ports.map(port => `<span class="port-chip">${esc(port)}</span>`);
  return `<div class="port-summary ${disabled ? "is-off" : ""}" title="${esc(ports.join(", "))}"><span class="port-label">Ports</span>${chips.join("")}${disabled ? '<span class="port-state">off</span>' : ""}</div>`;
}

function clientKey(client) {
  return client.config_name || client.id || client.name;
}

function clientDisplayLabel(client) {
  const display = client.display_name || client.name;
  const config = clientKey(client);
  if (client.is_duplicate_display_name && display !== config) return `${display} · ${config}`;
  return display;
}

function renderAssignedTokenBadges(client) {
  if (!canManageClientAssignments()) return "";
  const assigned = Array.isArray(client.assigned_tokens) ? client.assigned_tokens : [];
  if (!assigned.length) {
    return `<span class="rounded-full border border-[var(--line)] bg-[var(--soft)] px-2 py-0.5 text-[11px] font-medium text-[var(--muted)]">unassigned</span>`;
  }
  const visible = assigned.slice(0, 3);
  const extra = Math.max(0, assigned.length - visible.length);
  return visible.map(item => `
    <span class="rounded-full border border-[var(--accent)]/30 bg-[var(--accent)]/10 px-2 py-0.5 text-[11px] font-medium text-[var(--accent)]">${esc(item.alias || ("token: " + (item.fingerprint || "")))}</span>
  `).join("") + (extra ? `<span class="rounded-full border border-[var(--line)] bg-[var(--soft)] px-2 py-0.5 text-[11px] font-medium text-[var(--muted)]">+${extra}</span>` : "");
}

const _GEO_SOURCE_LABELS = {
  "2ip": "2IP", "dbip": "DB-IP", "dbip_mmdb": "DB-IP MMDB",
  "maxmind": "MaxMind", "ipinfo": "ipinfo", "ip-api": "ip-api", "cache": "cache",
  "ip2location": "IP2Location", "2ip_whois": "WHOIS", "rdap": "RDAP", "ptr": "PTR",
};
function geoSourceLabel(name) {
  return _GEO_SOURCE_LABELS[name] || name;
}

// Order in which a single "best" source is picked for the compact card line
const _GEO_SOURCE_PRIORITY = ["2ip", "ipinfo", "ip-api", "ip2location", "dbip", "maxmind", "dbip_mmdb", "cache"];

function preferredGeoSource(info) {
  if (!info) return null;
  const details = (info.source_details && typeof info.source_details === "object") ? info.source_details : {};
  for (const src of _GEO_SOURCE_PRIORITY) {
    const detail = details[src];
    if (!detail || detail.status === "error") continue;
    if (detail.city || detail.country_code || detail.provider || detail.provider_display || detail.org) {
      return { source: src, label: geoSourceLabel(src), detail };
    }
  }
  return null;
}

function formatGeoCompact(info) {
  if (!info) return "";
  const preferred = preferredGeoSource(info);
  const detail = preferred ? preferred.detail : {};
  const city = detail.city || info.city || "";
  const cc = detail.country_code || info.country_code || "";
  const prov = detail.provider_display || detail.provider || detail.org ||
    info.provider_display || info.provider || info.org || "";
  const location = [city, cc].filter(Boolean).join(", ");
  const parts = [location, prov, preferred ? preferred.label : ""].filter(Boolean);
  if (!parts.length) return "";
  const flag = info.flag || "";
  return (flag ? flag + " " : "") + parts.join(" · ");
}

function formatGeoSourceLine(source, detail) {
  if (!detail) return "";
  if (detail.status === "error") return `${geoSourceLabel(source)}: error: ${detail.error || "error"}`;
  if (source === "ptr") {
    const domain = detail.domain || detail.ptr || detail.hostname || "";
    return domain ? `${geoSourceLabel(source)}: ${domain}` : "";
  }
  const display = detail.provider_display || detail.provider || detail.org || "";
  const raw = detail.provider || detail.org || "";
  const prov = (display && raw && display !== raw) ? `${display} (${raw})` : display;
  if (source === "2ip_whois" || source === "rdap") {
    const netRoute = detail.route || detail.network || "";
    const parts = source === "rdap"
      ? [prov, detail.org, netRoute].filter(Boolean)
      : [prov, detail.org, detail.asn, netRoute].filter(Boolean);
    if (!parts.length) return "";
    return `${geoSourceLabel(source)}: ${parts.join(" · ")}`;
  }
  const city = detail.city || "";
  const cc = detail.country_code || "";
  const location = [city, cc].filter(Boolean).join(", ");
  const asn = detail.asn || "";
  const parts = [location, prov, asn].filter(Boolean);
  if (!parts.length) return "";
  return `${geoSourceLabel(source)}: ${parts.join(" · ")}`;
}

// Order in which per-source lines are shown in the hover tooltip
const _GEO_TOOLTIP_ORDER = ["2ip", "ipinfo", "ip-api", "ip2location", "dbip", "maxmind", "dbip_mmdb", "2ip_whois", "rdap", "ptr"];

function formatGeoTooltip(info) {
  if (!info) return "";
  const lines = [];
  const details = (info.source_details && typeof info.source_details === "object") ? info.source_details : {};
  const extra = Object.keys(details).filter((src) => !_GEO_TOOLTIP_ORDER.includes(src) && src !== "cache");
  const order = _GEO_TOOLTIP_ORDER.concat(extra);
  for (const src of order) {
    const detail = details[src];
    if (!detail) continue;
    const line = formatGeoSourceLine(src, detail);
    if (line) lines.push(line);
  }
  if (info.updated_at) lines.push(`Updated: ${info.updated_at}`);
  return lines.join("\n");
}

// Keep geoTooltip as alias so existing callers and tests continue to work
function geoTooltip(info) {
  return formatGeoTooltip(info);
}

function renderEndpointInfo(client) {
  const endpoint = client.endpoint || "";
  if (!endpoint || endpoint === "-") return "";
  const info = client.endpoint_info || {};
  const compact = formatGeoCompact(info);
  if (!compact) {
    return '<div class="endpoint-info text-xs text-[var(--muted)]">IP info: unknown</div>';
  }
  const tooltip = formatGeoTooltip(info);
  const conf = info.confidence || "";
  const confClass = conf ? `geo-confidence-${conf}` : "";
  return `<div class="endpoint-geo${confClass ? " " + confClass : ""}" title="${esc(tooltip)}">` +
    `<span class="endpoint-geo-main">${esc(compact)}</span>` +
    `</div>`;
}

function canManageClientAssignments() {
  return statusState && ["super", "admin"].includes(statusState.role);
}

function assignedUserTokens(client) {
  return (Array.isArray(client.assigned_tokens) ? client.assigned_tokens : []).filter(item => item.role === "user");
}

function ownerTokenKey(item) {
  return String(item?.fingerprint || item?.alias || "").trim();
}

function ownerTokenLabel(item) {
  return item?.alias || (item?.fingerprint ? `token: ${item.fingerprint}` : "token");
}

function clientMatchesOwnerFilter(client, filter = ownerFilter) {
  const assigned = assignedUserTokens(client);
  if (!filter || filter.mode === "all") return true;
  if (filter.mode === "network") return clientHasNetworkIssue(client);
  if (filter.mode === "unassigned") return assigned.length === 0;
  if (filter.mode === "assigned") return assigned.length > 0;
  if (filter.mode === "token") {
    const selected = new Set(filter.tokens || []);
    return assigned.some(item => selected.has(ownerTokenKey(item)));
  }
  return true;
}

function ownerFilterOptions() {
  const tokens = new Map();
  let assigned = 0;
  let unassigned = 0;
  let network = 0;
  latestClients.forEach(client => {
    if (clientHasNetworkIssue(client)) network += 1;
    const items = assignedUserTokens(client);
    if (items.length) assigned += 1;
    else unassigned += 1;
    items.forEach(item => {
      const key = ownerTokenKey(item);
      if (!key) return;
      const existing = tokens.get(key) || {
        key,
        label: ownerTokenLabel(item),
        fingerprint: item.fingerprint || "",
        count: 0,
      };
      existing.count += 1;
      tokens.set(key, existing);
    });
  });
  return {
    all: latestClients.length,
    assigned,
    unassigned,
    network,
    tokens: Array.from(tokens.values()).sort((a, b) => a.label.localeCompare(b.label)),
  };
}

function normalizeOwnerFilter(options) {
  if (!ownerFilter || !["all", "unassigned", "assigned", "token", "network"].includes(ownerFilter.mode)) {
    ownerFilter = {mode: "all", tokens: []};
  }
  if (ownerFilter.mode !== "token") return;
  const available = new Set(options.tokens.map(item => item.key));
  const selected = (ownerFilter.tokens || []).filter(key => available.has(key));
  ownerFilter = selected.length ? {mode: "token", tokens: selected} : {mode: "all", tokens: []};
}

function renderOwnerFilter() {
  const host = document.querySelector("#ownerFilter");
  if (!host || !canManageClientAssignments()) return;
  const options = ownerFilterOptions();
  normalizeOwnerFilter(options);
  const active = (mode, tokenKey = "") => ownerFilter.mode === mode && (mode !== "token" || (ownerFilter.tokens || []).includes(tokenKey));
  const filterButton = (mode, label, count, tokenKey = "") => {
    const isActive = active(mode, tokenKey);
    return `<button type="button" data-owner-filter="${esc(mode)}" ${tokenKey ? `data-owner-token="${esc(tokenKey)}"` : ""} class="h-8 rounded-md border px-2.5 text-xs font-semibold transition ${isActive ? "border-[var(--accent)] bg-[var(--accent)] text-white" : "border-[var(--line)] bg-[var(--soft)] text-[var(--muted)] hover:border-[var(--accent)] hover:text-[var(--text)]"}">${esc(label)} <span class="${isActive ? "text-white/80" : "text-[var(--muted)]"}">(${count})</span></button>`;
  };
  host.innerHTML = `
    <div class="flex flex-wrap items-center gap-2">
      <span class="text-xs font-semibold uppercase text-[var(--muted)]">Owner filter</span>
      ${filterButton("all", "All", options.all)}
      ${filterButton("unassigned", "Unassigned", options.unassigned)}
      ${filterButton("assigned", "Assigned", options.assigned)}
      ${filterButton("network", "Network issues", options.network)}
      ${options.tokens.map(item => filterButton("token", item.label, item.count, item.key)).join("")}
    </div>
  `;
  host.querySelectorAll("[data-owner-filter]").forEach(btn => {
    btn.onclick = () => {
      const mode = btn.dataset.ownerFilter;
      ownerFilter = mode === "token"
        ? {mode: "token", tokens: [btn.dataset.ownerToken]}
        : {mode, tokens: []};
      closeClientMenus();
      renderClients();
    };
  });
}

function formatPercent(value, digits = 0) {
  if (value === null || value === undefined || Number.isNaN(Number(value))) return "-";
  return `${Number(value).toFixed(digits)}%`;
}

function healthBadge(status = "unknown") {
  return `<span class="health-badge is-${esc(status)}">${esc(status || "unknown")}</span>`;
}

function renderHealthCard(label, value, sub, status) {
  return `
    <div class="health-card">
      <div class="health-card-head">
        <span>${esc(label)}</span>
        ${healthBadge(status)}
      </div>
      <strong>${esc(value)}</strong>
      <p>${esc(sub || "")}</p>
    </div>
  `;
}

function latencyClass(entry) {
  if (!entry || ["stale", "offline", "unknown", "skipped"].includes(entry.status) || ["stale", "offline"].includes(entry.connectivity)) return "is-offline";
  if (["icmp_blocked_possible", "idle"].includes(entry.status)) return "is-noping";
  if (entry.status === "timeout") return "is-timeout";
  const rtt = Number(entry.rtt_ms);
  if (!Number.isFinite(rtt)) return "is-offline";
  if (rtt < 80) return "is-good";
  if (rtt <= 200) return "is-warn";
  return "is-poor";
}

function clientLatencyEntry(client) {
  return clientLatencyState?.clients?.[clientKey(client)] || null;
}

function clientSharedProfile(client) {
  const entry = clientLatencyEntry(client);
  return entry?.shared_profile || client.shared_profile || {};
}

function clientPathEntry(client) {
  const key = clientKey(client);
  return clientPathState.results[key] || clientLatencyEntry(client)?.path_check || client.path_check || null;
}

function clientHasNetworkIssue(client) {
  const entry = clientLatencyEntry(client);
  const shared = clientSharedProfile(client);
  return Boolean(
    ["timeout", "icmp_blocked_possible", "high", "stale", "offline"].includes(entry?.status) ||
    ["stale", "offline", "unknown"].includes(entry?.connectivity) ||
    Number(entry?.rtt_ms) > 200 ||
    ["watch", "suspected", "high"].includes(shared?.severity)
  );
}

function renderLatencyChip(client) {
  const key = clientKey(client);
  const entry = clientLatencyEntry(client);
  const peerIp = entry?.["vp" + "n_ip"] || client.ipv4 || client.ip || "";
  const label = entry?.label || "unknown";
  const loss = entry?.loss_pct === null || entry?.loss_pct === undefined ? "n/a" : `${Number(entry.loss_pct).toFixed(0)}%`;
  const handshake = entry?.handshake_age_sec === null || entry?.handshake_age_sec === undefined
    ? "never"
    : `${timeAgo(Math.floor(Date.now() / 1000) - Number(entry.handshake_age_sec))}`;
  const endpoint = entry?.endpoint || client.endpoint || "-";
  const notes = Array.isArray(entry?.notes) ? entry.notes.join(" ") : "";
  const source = entry?.latency_method === "nettest"
    ? `Last browser Network Tester result from this client${entry?.nettest_latency?.age_sec !== undefined ? `, ${timeAgo(Math.floor(Date.now() / 1000) - Number(entry.nettest_latency.age_sec))}` : ""}.\nICMP did not answer, so this is not direct server-to-client ping.`
    : "";
  const title = `${"VP" + "N"} latency check to ${peerIp || "-"} from server.\nICMP timeout does not necessarily mean offline: device may sleep or block ping.\nConnectivity is inferred from handshake and traffic.\nLatest handshake: ${handshake}.\nLoss: ${loss}.\nEndpoint: ${endpoint}.\n${source}\n${notes}`.trim();
  return `<span class="latency-chip ${latencyClass(entry)}" title="${esc(title)}">${esc(label)}</span>`;
}

function renderSharedProfileChip(client) {
  const shared = clientSharedProfile(client);
  if (!["watch", "suspected", "high"].includes(shared?.severity)) return "";
  const label = shared.severity === "watch" ? "endpoint flip" : "shared?";
  const title = `This profile may be used on multiple devices.\n${"Wire" + "Guard"} keeps only one active endpoint per peer, so devices can steal the session from each other.\nObserved ${shared.endpoint_changes_10m || 0} endpoint changes between ${shared.distinct_endpoint_ips_10m || 0} public IPs in 10 minutes.\n${shared.summary || ""}`;
  return `<span class="shared-profile-chip is-${esc(shared.severity)}" title="${esc(title)}">${esc(label)}</span>`;
}

function pathChipClass(entry) {
  if (!entry) return "is-unsupported";
  if (entry.status === "ok") return "is-ok";
  if (entry.status === "timeout") return "is-timeout";
  if (entry.status === "blocked" || entry.status === "rate_limited") return "is-blocked";
  return "is-unsupported";
}

function renderPathChip(client) {
  const entry = clientPathEntry(client);
  if (!entry || entry.target_type === ("tun" + "nel")) return "";
  const count = entry.hop_count ?? entry.hops;
  const label = entry.status === "ok" && count
    ? `${count} hop${Number(count) === 1 ? "" : "s"}`
    : (entry.status === "timeout" ? "endpoint timeout" : (entry.status === "no_endpoint" ? "no endpoint" : (entry.status === "blocked" || entry.status === "rate_limited" ? "try later" : "path n/a")));
  const targetIp = entry.target_ip || "";
  const checkedAt = entry.timestamp ? new Date(entry.timestamp).toLocaleString() : "unknown";
  const stale = entry.endpoint_stale ? "\nEndpoint may be stale: latest handshake is old." : "";
  const title = `Public endpoint path from server to ${targetIp || "-"}.\nThis is the route to the client's current NAT/carrier/Wi-Fi endpoint, not necessarily directly to the device.\nEndpoint path timeout does not mean the client is offline. Some networks block tracepath/traceroute probes.${stale}\nLast check: ${checkedAt}.\nMethod: ${entry.method || "none"}.\n${entry.note || ""}`.trim();
  return `<span class="path-chip ${pathChipClass(entry)}" title="${esc(title)}">${esc(label)}</span>`;
}

function renderClientNetworkDiagnostics() {
  const host = document.querySelector("#clientNetworkDiagnostics");
  if (!host || statusState?.role !== "super") return;
  const diag = clientLatencyState?.overview || clientLatencyState?.diagnostics || {};
  const avg = diag.avg_rtt_ms ?? diag.average_rtt_ms;
  const p95 = diag.p95_rtt_ms;
  const avgHops = diag.avg_hops ?? diag.average_hops;
  const avgLabel = avg === null || avg === undefined ? "n/a" : `${Math.round(Number(avg))} ms`;
  const p95Label = p95 === null || p95 === undefined ? "n/a" : `${Math.round(Number(p95))} ms`;
  const hopsLabel = avgHops === null || avgHops === undefined ? "n/a" : `${Number(avgHops).toFixed(Number(avgHops) % 1 ? 1 : 0)}`;
  const issues = Array.isArray(diag.top_issues) ? diag.top_issues.slice(0, 5) : [];
  const batch = clientPathState.batchSummary;
  const batchText = clientPathState.batchRunning
    ? "Checking endpoint paths..."
    : (batch ? `Endpoint paths checked ${batch.checked || 0}/${batch.total_candidates || 0}` : "");
  host.innerHTML = `
    <div class="client-network-diagnostics">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <p class="text-xs font-semibold uppercase text-[var(--muted)]">Client Network Overview</p>
        <div class="flex flex-wrap items-center justify-end gap-2">
          ${batchText ? `<span class="text-xs text-[var(--muted)]">${esc(batchText)}</span>` : ""}
          <button type="button" id="checkEndpointPaths" class="${buttonClasses("h-8 px-2 text-xs")}" ${clientPathState.batchRunning ? "disabled" : ""}>${icon("search")}<span>${clientPathState.batchRunning ? "Checking..." : "Check endpoint paths"}</span></button>
          <button type="button" id="refreshLatency" class="${buttonClasses("h-8 px-2 text-xs")}">${icon("refresh")}<span>Refresh latency</span></button>
        </div>
      </div>
      <div class="nettest-metrics">
        <div>Active: <strong>${esc(diag.active ?? diag.active_peers ?? "-")}</strong></div>
        <div>Reachable: <strong>${esc(diag.reachable ?? diag.reachable_clients ?? "-")}</strong></div>
        <div>No ping: <strong>${esc(diag.no_ping ?? diag.no_ping_clients ?? "-")}</strong></div>
        <div>High latency: <strong>${esc(diag.high_latency ?? diag.high_latency_clients ?? "-")}</strong></div>
        <div>Stale: <strong>${esc(diag.stale ?? diag.stale_peers ?? "-")}</strong></div>
        <div>Shared suspected: <strong>${esc(diag.shared_profile_suspected ?? "-")}</strong></div>
        <div>Endpoint flapping: <strong>${esc(diag.endpoint_flapping ?? diag.endpoint_flapping_clients ?? "-")}</strong></div>
        <div>Endpoint paths checked: <strong>${esc(diag.path_checked ?? diag.path_checked_clients ?? 0)}</strong></div>
        <div>Avg endpoint hops: <strong>${esc(hopsLabel)}</strong></div>
        <div>Endpoint path timeout: <strong>${esc(diag.path_timeout ?? diag.path_timeout_clients ?? 0)}</strong></div>
        <div>Endpoint path unsupported: <strong>${esc((diag.path_unsupported ?? false) ? "yes" : "no")}</strong></div>
        <div>Avg RTT: <strong>${esc(avgLabel)}</strong></div>
        <div>P95 RTT: <strong>${esc(p95Label)}</strong></div>
      </div>
      ${issues.length ? `<div class="mt-2 text-xs text-[var(--muted)]"><span class="font-medium text-[var(--text)]">Top issues</span><ol class="mt-1 grid gap-1">${issues.map((item, idx) => `<li>${idx + 1}. ${esc(item.client || "-")} — ${esc(item.summary || item.type || "issue")}</li>`).join("")}</ol></div>` : ""}
    </div>
  `;
  const btn = document.querySelector("#refreshLatency");
  if (btn) btn.onclick = () => loadClientLatency(true);
  const pathBtn = document.querySelector("#checkEndpointPaths");
  if (pathBtn) pathBtn.onclick = () => checkEndpointPaths();
}

function renderServerInfo() {
  const linksHost = document.querySelector("#metricLinks");
  const addressHost = document.querySelector("#metricAddresses");
  if (!linksHost && !addressHost) return;
  const info = serverInfoState || {};
  const links = [];
  if (info["ad" + "guard_enabled"] && info["ad" + "guard_url"]) links.push({label: "Ad" + "Guard", href: info["ad" + "guard_url"]});
  if (info["nettest_vp" + "n_url"]) links.push({label: "Network Tester", href: info["nettest_vp" + "n_url"]});
  if (linksHost) {
    linksHost.innerHTML = links
      .map(item => `<a href="${esc(item.href)}" class="summary-link-chip" ${item.href.startsWith("http") ? 'target="_blank" rel="noopener"' : ""}>${esc(item.label)}</a>`)
      .join("");
  }
  if (addressHost) {
    const resolverVal = info["d" + "ns_resolver"] ? shortValue(info["d" + "ns_resolver"]) : "";
    const rows = [
      ["Public IPv4", shortValue(info.public_ipv4)],
      ["Public IPv6", shortValue(info.public_ipv6)],
      ["V" + "P" + "N IPv4", shortValue(info["vp" + "n_ipv4"])],
      ["V" + "P" + "N IPv6", shortValue(info["vp" + "n_ipv6"], "IPv6 disabled")],
    ];
    if (resolverVal) rows.push(["D" + "NS / Resolver", resolverVal]);
    addressHost.innerHTML = rows.map(([label, value]) => `
      <div class="summary-address-row"><span>${esc(label)}</span><strong>${esc(value)}</strong></div>
    `).join("");
  }
}

async function loadServerInfo() {
  try {
    serverInfoState = await api("/api/server-info");
    renderServerInfo();
  } catch {
    serverInfoState = null;
  }
}

function renderHealthHistory() {
  const host = document.querySelector("#serverHealthHistory");
  if (!host || statusState?.role !== "super") return;
  const ranges = SERVER_HEALTH_RANGES.map(range => {
    const active = range === serverHealthRange;
    return `<button type="button" data-health-range="${esc(range)}" class="health-range-chip ${active ? "is-active" : ""}">${esc(range)}</button>`;
  }).join("");
  const clearButton = `<button type="button" id="clearHealthHistory" class="${buttonClasses("h-8 px-2 text-xs ml-auto")}">${icon("trash")}<span>Clear load statistics</span></button>`;
  if (!serverHealthHistoryState) {
    host.innerHTML = `<div class="health-range-row items-center">${ranges}${clearButton}</div><p class="mt-2 text-sm text-[var(--muted)]">History is warming up.</p>`;
    bindHealthRangeButtons();
    return;
  }
  const summary = serverHealthHistoryState.summary || {};
  const cpu = summary.cpu || {};
  const memory = summary.memory || {};
  const disk = summary.disk || {};
  const conntrack = summary.conntrack || {};
  const network = summary.network || {};
  const rates = network.rates || {};
  const process = summary.process || {};
  const counts = summary.counts || {};
  const notes = Array.isArray(summary.notes) ? summary.notes : [];
  host.innerHTML = `
    <div class="health-range-row items-center">${ranges}${clearButton}</div>
    <div class="health-history-summary">
      <div><span>CPU</span><strong>avg ${formatPercent(cpu.avg, 1)} · peak ${formatPercent(cpu.max, 1)}</strong></div>
      <div><span>RAM</span><strong>avg ${formatPercent(memory.avg_used_percent, 0)} · peak ${formatPercent(memory.max_used_percent, 0)}</strong><em>min avail ${bytes(memory.min_available_bytes || 0)}</em></div>
      <div><span>Disk</span><strong>${formatPercent(disk.current_used_percent, 0)}</strong><em>min free ${bytes(disk.min_free_bytes || 0)}</em></div>
      <div><span>Conntrack</span><strong>peak ${formatPercent(conntrack.max_used_percent, 1)}</strong></div>
      <div><span>Drops</span><strong>WAN +${Number(network.wan_rx_dropped_delta || 0) + Number(network.wan_tx_dropped_delta || 0)} · ${"VP" + "N"} +${Number(network["vp" + "n_rx_dropped_delta"] || 0) + Number(network["vp" + "n_tx_dropped_delta"] || 0)}</strong><em>errors +${Number(network.errors_delta || 0)}</em></div>
      <div><span>WAN speed</span><strong>avg ↓ ${speed(rates.wan_rx?.avg_bps || 0)} · ↑ ${speed(rates.wan_tx?.avg_bps || 0)}</strong><em>peak ↓ ${speed(rates.wan_rx?.peak_bps || 0)} · ↑ ${speed(rates.wan_tx?.peak_bps || 0)}</em></div>
      <div><span>${"VP" + "N"} speed</span><strong>avg ↓ ${speed(rates["vp" + "n_rx"]?.avg_bps || 0)} · ↑ ${speed(rates["vp" + "n_tx"]?.avg_bps || 0)}</strong><em>peak ↓ ${speed(rates["vp" + "n_rx"]?.peak_bps || 0)} · ↑ ${speed(rates["vp" + "n_tx"]?.peak_bps || 0)}</em></div>
      <div><span>Python</span><strong>RSS peak ${bytes(process.max_rss_bytes || 0)}</strong><em>FD peak ${Math.round(Number(process.max_fd_count || 0))}</em></div>
    </div>
    <p class="mt-2 text-xs text-[var(--muted)]">Samples ${counts.samples || 0} · warnings ${counts.warn || 0} · critical ${counts.critical || 0} · bucket ${serverHealthHistoryState.bucket_seconds || 0}s</p>
    ${notes.length ? `<div class="mt-2 grid gap-1">${notes.map(note => `<p class="text-xs text-amber-700">${esc(note)}</p>`).join("")}</div>` : ""}
  `;
  bindHealthRangeButtons();
}

function bindHealthRangeButtons() {
  document.querySelectorAll("[data-health-range]").forEach(btn => {
    btn.onclick = async () => {
      serverHealthRange = btn.dataset.healthRange || "1h";
      localStorage.setItem("serverHealthRange", serverHealthRange);
      renderHealthHistory();
      await loadServerHealthHistory();
    };
  });
  const clearButton = document.querySelector("#clearHealthHistory");
  if (clearButton) clearButton.onclick = clearLoadStatistics;
}

async function clearLoadStatistics() {
  const ok = await confirmTypedModal(
    "Clear load statistics",
    "This permanently deletes all stored server load/health history samples. Live monitoring continues afterward, starting from a clean history.",
    "CLEAR LOAD STATISTICS",
    "Clear statistics"
  );
  if (!ok) return;
  try {
    await api("/api/server-health/history", {method: "DELETE", body: JSON.stringify({confirm: "CLEAR LOAD STATISTICS"})});
    serverHealthHistoryState = null;
    renderHealthHistory();
    await loadServerHealthHistory();
    showToast("Load statistics cleared");
  } catch {
    showToast("Failed to clear load statistics", "error");
  }
}

function renderServerHealth() {
  const host = document.querySelector("#serverHealthGrid");
  if (!host || statusState?.role !== "super") return;
  if (!serverHealthState) {
    host.innerHTML = `<p class="text-sm text-[var(--muted)]">Health unavailable</p>`;
    return;
  }
  const h = serverHealthState;
  const load = h.load || {};
  const cpu = h.cpu || {};
  const memory = h.memory || {};
  const disk = h.disk || {};
  const network = h.network || {};
  const conntrack = h.conntrack || {};
  const process = h.process || {};
  const services = h.services || {};
  const cpuValue = cpu.usage_percent === null || cpu.usage_percent === undefined
    ? `Load ${Number(load.one || 0).toFixed(2)}`
    : formatPercent(cpu.usage_percent, 1);
  const memoryUsed = bytes(Math.max(0, Number(memory.total_bytes || 0) - Number(memory.available_bytes || 0)));
  const nginx = services.nginx_edge || {};
  const overlay = services["vp" + "n_interface"] || {};
  const overlayIface = network["vp" + "n_iface"] || "link";
  const overlayDrops = network["vp" + "n_drops_delta"] || 0;
  host.innerHTML = `
    ${renderHealthCard("CPU", cpuValue, `load ${Number(load.one || 0).toFixed(2)} / ${load.cpu_count || 1} core`, cpu.status || load.status || "ok")}
    ${renderHealthCard("RAM", formatPercent(memory.used_percent, 0), `${memoryUsed} used · ${bytes(memory.available_bytes || 0)} available`, memory.status || "unknown")}
    ${renderHealthCard("Disk", formatPercent(disk.used_percent, 0), `${bytes(disk.free_bytes || 0)} free on ${disk.path || "/"}`, disk.status || "unknown")}
    ${renderHealthCard("Conntrack", conntrack.available === false ? "n/a" : formatPercent(conntrack.used_percent, 1), conntrack.available === false ? "not exposed" : `${conntrack.count || 0}/${conntrack.max || 0}`, conntrack.status || "unknown")}
    ${renderHealthCard("Network", `${network.drops_delta || 0} drops`, `${network.wan_iface || "wan"} / ${overlayIface} · errors ${network.errors_delta || 0}`, network.status || "unknown")}
    ${renderHealthCard("Web/Link", `${nginx.status || "unknown"} / ${overlay.status || "unknown"}`, `python RSS ${bytes(process.rss_bytes || 0)} · FD ${process.fd_count || 0} · link drops ${overlayDrops}`, h.status || "unknown")}
  `;
  const stamp = document.querySelector("#serverHealthUpdated");
  if (stamp) stamp.textContent = h.timestamp ? `Updated ${h.timestamp}` : "";
  renderHealthHistory();
  renderClientNetworkDiagnostics();
  renderNetworkExplain();
}

async function loadClientLatency(force = false) {
  if (statusState?.role !== "super" || latencyInFlight || isNetworkTesterPage() || isPanelIdle()) return;
  latencyInFlight = true;
  try {
    clientLatencyState = await api(`/api/clients/latency${force ? "?refresh=1" : ""}`);
    renderClientNetworkDiagnostics();
    renderClients();
  } catch {
    clientLatencyState = null;
    renderClientNetworkDiagnostics();
  } finally {
    latencyInFlight = false;
  }
}

function stopClientLatencyPolling() {
  if (latencyTimer) clearTimeout(latencyTimer);
  latencyTimer = null;
}

function startClientLatencyPolling() {
  stopClientLatencyPolling();
  if (!token || statusState?.role !== "super") return;
  const tick = async () => {
    checkPanelIdle();
    if (shouldPollHeavy()) await loadClientLatency();
    latencyTimer = setTimeout(tick, panelIdle ? PANEL_IDLE_HEARTBEAT_MS : CLIENT_LATENCY_POLL_MS);
  };
  latencyTimer = setTimeout(tick, CLIENT_LATENCY_POLL_MS);
}

// Format "X / Y (Z%)" for a delta over its total (delta + remaining), or
// just "X" if the percentage cannot be computed.
function formatDropScale(label, deltaValue, pctValue, totalValue) {
  const delta = Number(deltaValue || 0);
  if (pctValue === null || pctValue === undefined || totalValue === null || totalValue === undefined) {
    return `${label}: +${delta}`;
  }
  const total = Number(totalValue || 0);
  return `${label}: ${delta} / ${total} (${formatPercent(pctValue, 2)})`;
}

// Explain WARN/critical "Network" status: split observed drop/error counters
// into likely vs. not-likely causes (WAN link, overlay link, real TCP loss,
// IPv6 routing), the scale of each as "X / Y (Z%)", and follow-up actions.
function renderNetworkExplain() {
  const host = document.querySelector("#networkExplain");
  if (!host || statusState?.role !== "super") return;
  if (!serverHealthState) {
    host.innerHTML = "";
    return;
  }
  const network = serverHealthState.network || {};
  const wanIface = network.wan_iface || "wan";
  const overlayIface = network["vp" + "n_iface"] || "link";
  const wanDrops = Number(network.wan_drops_delta || 0);
  const overlayDrops = Number(network["vp" + "n_drops_delta"] || 0);
  const qdiscDrops = Number(network.qdisc_drop_delta || 0);
  const tcpRetrans = Number(network.tcp_retrans_delta || 0);
  const tcpTimeouts = Number(network.tcp_timeout_delta || 0);
  const ip6NoRoute = Number(network.ip6_no_route_delta || 0);
  const errors = Number(network.errors_delta || 0);

  const likely = [];
  const notLikely = [];
  const scale = [];
  const action = [];
  const overlayLabel = "VP" + "N";

  const wanPackets = Number(network.wan_packets_delta || 0);
  const overlayPackets = Number(network["vp" + "n_packets_delta"] || 0);
  scale.push(formatDropScale(`WAN (${wanIface}) drops`, wanDrops, network.wan_drop_pct, wanDrops + wanPackets));
  scale.push(formatDropScale(`${overlayLabel} (${overlayIface}) drops`, overlayDrops, network["vp" + "n_drop_pct"], overlayDrops + overlayPackets));
  scale.push(formatDropScale(`Qdisc (${wanIface}) drops`, qdiscDrops, network.qdisc_drop_pct, qdiscDrops + Number(network.qdisc_sent_delta || 0)));
  scale.push(formatDropScale("TCP retransmits", tcpRetrans, network.tcp_retrans_pct, network.tcp_segs_out_delta));
  scale.push(formatDropScale("TCP timeouts", tcpTimeouts, network.tcp_timeout_pct, network.tcp_segs_out_delta));
  scale.push(formatDropScale("IPv6 no-route", ip6NoRoute, network.ip6_no_route_pct, ip6NoRoute + Number(network.ip6_out_requests_delta || 0)));

  if (wanDrops > 0 || qdiscDrops > 0) {
    likely.push(`WAN link (${wanIface}) drops: interface +${wanDrops}, qdisc +${qdiscDrops} - often queue/driver limits or upstream congestion.`);
    action.push(`tc -s qdisc show dev ${wanIface}`);
  } else {
    notLikely.push(`WAN interface (${wanIface}) drops: none observed.`);
  }

  if (overlayDrops > 0) {
    likely.push(`${overlayLabel} link (${overlayIface}) drops +${overlayDrops} - check the overlay MTU and client-side buffers.`);
    action.push(`ip -s link show ${overlayIface}`);
  } else {
    notLikely.push(`${overlayLabel} link (${overlayIface}) drops: none observed.`);
  }

  if (tcpRetrans > 0 || tcpTimeouts > 0) {
    likely.push(`Real packet loss: TCP retransmits +${tcpRetrans}, TCP timeouts +${tcpTimeouts}.`);
    action.push("grep -i tcpext /proc/net/netstat");
  } else {
    notLikely.push("TCP retransmits/timeouts: none observed.");
  }

  if (ip6NoRoute > 0) {
    likely.push(`IPv6 packets with no route +${ip6NoRoute} - expected if IPv6/AAAA is disabled, otherwise check the IPv6 default route.`);
    action.push("ip -6 route show default");
  } else {
    notLikely.push("IPv6 'no route' drops: none observed.");
  }

  if (errors > 0) {
    likely.push(`Interface errors +${errors} (CRC/frame, etc.) - check cabling/driver on ${wanIface}.`);
    action.push(`ethtool -S ${wanIface} | grep -i err`);
  }

  action.push("Run a 60-second before/after sample for a clean delta.");

  const status = network.status || "unknown";
  host.innerHTML = `
    <details class="mt-3 rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 py-2 text-xs text-[var(--muted)]"${status !== "ok" ? " open" : ""}>
      <summary class="cursor-pointer font-medium text-[var(--text)]">Network drops &amp; errors explained ${healthBadge(status)}</summary>
      <div class="mt-2 grid gap-1.5">
        ${likely.length ? `<p class="font-semibold text-[var(--text)]">Likely</p><ul class="nettest-notes">${likely.map(t => `<li>${esc(t)}</li>`).join("")}</ul>` : ""}
        ${notLikely.length ? `<p class="mt-1 font-semibold text-[var(--text)]">Not likely</p><ul class="nettest-notes">${notLikely.map(t => `<li>${esc(t)}</li>`).join("")}</ul>` : ""}
        ${scale.length ? `<p class="mt-1 font-semibold text-[var(--text)]">Scale</p><ul class="nettest-notes">${scale.map(t => `<li>${esc(t)}</li>`).join("")}</ul>` : ""}
        ${action.length ? `<p class="mt-1 font-semibold text-[var(--text)]">Action</p><ul class="nettest-notes">${action.map(t => `<li><code>${esc(t)}</code></li>`).join("")}</ul>` : ""}
      </div>
      <div class="mt-2">
        <button type="button" id="dropsSampleBtn" class="btn-secondary h-8 rounded px-3 text-xs font-semibold">${icon("refresh")} 60s before/after sample</button>
        <div id="dropsSampleResult" class="mt-2"></div>
      </div>
    </details>
  `;
  const sampleBtn = document.querySelector("#dropsSampleBtn");
  if (sampleBtn) {
    sampleBtn.onclick = async () => {
      const resultEl = document.querySelector("#dropsSampleResult");
      sampleBtn.disabled = true;
      const original = sampleBtn.innerHTML;
      sampleBtn.innerHTML = "Sampling for 60s...";
      if (resultEl) resultEl.innerHTML = "";
      try {
        const report = await api("/api/server-health/drops-sample", {method: "POST", body: JSON.stringify({duration_seconds: 60})});
        if (resultEl) {
          const lines = [
            formatDropScale(`WAN drops`, report.wan.drops_delta, report.wan.drop_pct, report.wan.drops_delta + report.wan.packets_delta),
            formatDropScale(`${overlayLabel} drops`, report["vp" + "n"].drops_delta, report["vp" + "n"].drop_pct, report["vp" + "n"].drops_delta + report["vp" + "n"].packets_delta),
            formatDropScale("Qdisc drops", report.qdisc.drop_delta, report.qdisc.drop_pct, report.qdisc.drop_delta + report.qdisc.sent_delta),
            formatDropScale("TCP retransmits", report.tcp.retrans_delta, report.tcp.retrans_pct, report.tcp.out_segs_delta),
            formatDropScale("TCP timeouts", report.tcp.timeout_delta, report.tcp.timeout_pct, report.tcp.out_segs_delta),
            formatDropScale("IPv6 no-route", report.ipv6.no_route_delta, report.ipv6.no_route_pct, report.ipv6.no_route_delta + report.ipv6.out_requests_delta),
          ];
          resultEl.innerHTML = `<p class="font-semibold text-[var(--text)]">Sample over ${report.duration_seconds}s</p><ul class="nettest-notes">${lines.map(t => `<li>${esc(t)}</li>`).join("")}</ul>`;
        }
      } catch (err) {
        if (resultEl) resultEl.innerHTML = `<p class="text-[var(--danger)]">${esc(err.message || String(err))}</p>`;
      } finally {
        sampleBtn.disabled = false;
        sampleBtn.innerHTML = original;
      }
    };
  }
}

function renderReadinessRow(label, status, detail) {
  return `
    <div class="readiness-row">
      <div class="readiness-row-head">
        <span>${esc(label)}</span>
        ${healthBadge(status || "unknown")}
      </div>
      ${detail ? `<p>${esc(detail)}</p>` : ""}
    </div>
  `;
}

// Readiness: kernel/crypto/virtualization/forwarding/buffers/offloads/
// IPv6 routing/NDP proxy checks (server-cached for several minutes, so this
// is refreshed on a slower cadence than health).
function renderReadiness() {
  const host = document.querySelector("#readinessGrid");
  if (!host || statusState?.role !== "super") return;
  if (!readinessState) {
    host.innerHTML = `<p class="text-sm text-[var(--muted)]">${"VP" + "N"} readiness unavailable</p>`;
    return;
  }
  const r = readinessState;
  const kernel = r.kernel || {};
  const crypto = r.crypto || {};
  const virt = r.virtualization || {};
  const ipFwd = r.ip_forwarding || {};
  const udpBuf = r.udp_buffers || {};
  const offloads = r.wan_offloads || {};
  const ipv6Routing = r.ipv6_routing || {};
  const ndp = r.ndp_proxy || {};
  const cryptoFlags = (crypto.accelerated_flags || []).join(", ") || "none detected";
  const offloadsList = Object.entries(offloads.offloads || {}).map(([k, v]) => `${k}=${v}`).join(", ") || "n/a";

  host.innerHTML = `
    ${renderReadinessRow("Kernel modules", kernel.status, `${kernel.detail || ""}${kernel.release ? ` (${kernel.release})` : ""}`)}
    ${renderReadinessRow("Crypto features", crypto.status, `${crypto.detail || ""} - ${crypto.arch || "unknown"}: ${cryptoFlags}`)}
    ${renderReadinessRow("Virtualization", virt.status, virt.type || "unknown")}
    ${renderReadinessRow("IP forwarding", ipFwd.status, `IPv4 ${ipFwd.ipv4_forwarding ? "on" : "off"} · IPv6 ${ipFwd.ipv6_forwarding ? "on" : "off"}`)}
    ${renderReadinessRow("UDP buffers", udpBuf.status, `rmem_max ${bytes(udpBuf.rmem_max || 0)} · wmem_max ${bytes(udpBuf.wmem_max || 0)} (recommended ≥ ${bytes(udpBuf.recommended_min || 0)})`)}
    ${renderReadinessRow("WAN offloads", offloads.status, offloads.iface ? `${offloads.iface}: ${offloadsList}` : "n/a")}
    ${renderReadinessRow("IPv6 routing", ipv6Routing.status, `${ipv6Routing.mode || "unknown"}${ipv6Routing.global_address ? " · global address present" : ""}`)}
    ${renderReadinessRow("NDP proxy / ndppd", ndp.status, ndp.detail || "")}
  `;
  const stamp = document.querySelector("#readinessUpdated");
  if (stamp) stamp.textContent = r.timestamp ? `Updated ${r.timestamp}` : "";
}

const NDP_MODE_LABELS = {
  ipv6_disabled: "IPv6 is disabled on this host - NDP proxy is not applicable.",
  ipv6_public_single_address_only: `A single public IPv6 address is present; no ${"VP" + "N"} prefix is configured for NDP proxy.`,
  ipv6_prefix_routed_to_server: "An IPv6 prefix is routed to this server - NDP proxy is not needed.",
  ipv6_prefix_onlink_needs_ndp_proxy: `The IPv6 prefix is on-link on the WAN interface - clients behind the ${"VP" + "N"} need an NDP proxy.`,
  ipv6_unknown_manual_review: "IPv6 routing mode could not be classified automatically - manual review required.",
};

function ndpProxyStatus(ndp) {
  const mode = ndp.mode || "ipv6_unknown_manual_review";
  if (mode === "ipv6_prefix_onlink_needs_ndp_proxy") {
    if (ndp.ndppd_active && ndp.configured) return {text: "Enabled", status: "ok"};
    if ((ndp.installed || ndp.configured) && !ndp.ndppd_active) return {text: "Misconfigured", status: "warn"};
    return {text: "Needed", status: "warn"};
  }
  if (mode === "ipv6_unknown_manual_review") return {text: "Manual review required", status: "warn"};
  return {text: "Not needed", status: "info"};
}

// IPv6 / NDP proxy (ndppd) admin panel. Super-only. Diagnostics always
// rendered; management buttons are hidden when IPv6 is disabled on the host.
function renderNdpProxyPanel() {
  const host = document.querySelector("#ndpProxyPanel");
  if (!host || statusState?.role !== "super") return;
  const r = readinessState;
  if (!r) {
    host.innerHTML = "";
    return;
  }
  const ndp = r.ndp_proxy || {};
  const mode = ndp.mode || "ipv6_unknown_manual_review";
  const summary = ndpProxyStatus(ndp);
  const needsPrefixInput = !ndp.prefix && mode !== "ipv6_disabled";
  const canManage = mode !== "ipv6_disabled";

  host.innerHTML = `
    <div class="rounded-md border border-[var(--line)] bg-[var(--soft)] p-3">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <p class="text-xs font-semibold uppercase text-[var(--muted)]">IPv6 / NDP Proxy</p>
        ${healthBadge(summary.status)}<span class="text-sm font-medium">${esc(summary.text)}</span>
      </div>
      <p class="mt-1 text-xs text-[var(--muted)]">${esc(NDP_MODE_LABELS[mode] || "")}</p>
      <div class="mt-2 grid gap-1 text-xs text-[var(--muted)] sm:grid-cols-2">
        <div>WAN iface: <span class="text-[var(--text)]">${esc(ndp.wan_iface || "-")}</span></div>
        <div>${"VP" + "N"} iface: <span class="text-[var(--text)]">${esc(ndp["vp" + "n_iface"] || "-")}</span></div>
        <div>Prefix: <span class="text-[var(--text)]">${esc(ndp.prefix || "(not configured)")}</span></div>
        <div>proxy_ndp sysctl: <span class="text-[var(--text)]">${esc(ndp.proxy_ndp_sysctl ?? "-")}</span></div>
        <div>ndppd installed: <span class="text-[var(--text)]">${ndp.installed ? "yes" : "no"}</span></div>
        <div>ndppd active: <span class="text-[var(--text)]">${ndp.ndppd_active ? "yes" : "no"}</span></div>
      </div>
      ${canManage ? `
        ${needsPrefixInput ? `
          <p class="mt-3 rounded-md border border-amber-500/50 bg-amber-500/10 p-2 text-xs text-[var(--text)]">Manual IPv6 prefix required - enter the provider's IPv6 prefix (e.g. 2001:db8:abcd::/64) before generating an ndppd config.</p>
          <input id="ndpPrefixInput" type="text" placeholder="2001:db8:abcd::/64" class="mt-2 w-full rounded-md border border-[var(--line)] bg-[var(--panel)] px-2 py-1 text-sm">
        ` : ""}
        <div class="mt-3 flex flex-wrap gap-2">
          <button id="ndpGenerate" class="${buttonClasses()}">${icon("refresh")}<span>Generate ndppd config</span></button>
          <button id="ndpEnable" class="${buttonClasses("border-amber-600 text-amber-700")}">${icon("power")}<span>Enable ndppd</span></button>
          <button id="ndpRestart" class="${buttonClasses()}">${icon("refresh")}<span>Restart ndppd</span></button>
          <button id="ndpDisable" class="${buttonClasses("border-[var(--danger)] text-[var(--danger)]")}">${icon("trash")}<span>Disable ndppd</span></button>
        </div>
      ` : ""}
    </div>
  `;

  if (!canManage) return;

  document.querySelector("#ndpGenerate").onclick = async () => {
    const prefixInput = document.querySelector("#ndpPrefixInput");
    const prefix = prefixInput ? prefixInput.value.trim() : (ndp.prefix || "");
    if (!prefix) {
      showToast("IPv6 prefix is required", "error");
      return;
    }
    const ok = await confirmModal(
      "Generate ndppd config",
      `Generate /etc/ndppd.conf for prefix ${prefix} on ${ndp.wan_iface || "WAN"} -> ${ndp["vp" + "n_iface"] || ("VP" + "N")}? Any existing config is backed up first.`,
      "Generate",
      false
    );
    if (!ok) return;
    try {
      await api("/api/ipv6/ndp/generate", {method: "POST", body: JSON.stringify({prefix})});
      showToast("ndppd config generated");
      await loadReadiness(true);
      renderNdpProxyPanel();
    } catch {
      showToast("Failed to generate ndppd config", "error");
    }
  };

  document.querySelector("#ndpEnable").onclick = async () => {
    const ok = await confirmModal(
      "Enable ndppd",
      "DANGER: this installs (if missing) and starts the ndppd NDP proxy service using /etc/ndppd.conf. Make sure the config matches your IPv6 prefix.",
      "Enable",
      true
    );
    if (!ok) return;
    try {
      await api("/api/ipv6/ndp/enable", {method: "POST", body: "{}"});
      showToast("ndppd enabled");
      await loadReadiness(true);
      renderNdpProxyPanel();
    } catch {
      showToast("Failed to enable ndppd", "error");
    }
  };

  document.querySelector("#ndpRestart").onclick = async () => {
    const ok = await confirmModal("Restart ndppd", "Restart the ndppd service?", "Restart", false);
    if (!ok) return;
    try {
      await api("/api/ipv6/ndp/restart", {method: "POST", body: "{}"});
      showToast("ndppd restarted");
      await loadReadiness(true);
      renderNdpProxyPanel();
    } catch {
      showToast("Failed to restart ndppd", "error");
    }
  };

  document.querySelector("#ndpDisable").onclick = async () => {
    const ok = await confirmModal(
      "Disable ndppd",
      "DANGER: this stops and disables the ndppd service. IPv6 clients relying on the NDP proxy will lose IPv6 connectivity.",
      "Disable",
      true
    );
    if (!ok) return;
    try {
      await api("/api/ipv6/ndp/disable", {method: "POST", body: "{}"});
      showToast("ndppd disabled");
      await loadReadiness(true);
      renderNdpProxyPanel();
    } catch {
      showToast("Failed to disable ndppd", "error");
    }
  };
}

// Server-cached for cache_ttl_seconds (5-10 min); avoid re-fetching on every
// 10s health poll by gating on a client-side minimum interval too.
async function loadReadiness(force = false) {
  if (statusState?.role !== "super") return;
  if (!force && readinessState && Date.now() - readinessLoadedAt < 4 * 60 * 1000) return;
  try {
    readinessState = await api("/api/" + "vp" + "n-readiness");
    readinessLoadedAt = Date.now();
    renderReadiness();
    renderNdpProxyPanel();
  } catch {
    const host = document.querySelector("#readinessGrid");
    if (host) host.innerHTML = `<p class="text-sm text-[var(--muted)]">${"VP" + "N"} readiness unavailable</p>`;
  }
}

async function loadServerHealth() {
  if (statusState?.role !== "super" || healthInFlight) return;
  healthInFlight = true;
  try {
    serverHealthState = await api("/api/server-health");
    renderServerHealth();
    await loadServerHealthHistory();
    await loadReadiness();
  } catch {
    const host = document.querySelector("#serverHealthGrid");
    if (host) host.innerHTML = `<p class="text-sm text-[var(--muted)]">Health unavailable</p>`;
  } finally {
    healthInFlight = false;
  }
}

async function loadServerHealthHistory() {
  if (statusState?.role !== "super") return;
  try {
    serverHealthHistoryState = await api(`/api/server-health/history?range=${encodeURIComponent(serverHealthRange)}`);
    renderHealthHistory();
  } catch {
    serverHealthHistoryState = null;
    renderHealthHistory();
  }
}

function stopServerHealthPolling() {
  if (healthTimer) clearTimeout(healthTimer);
  healthTimer = null;
}

function startServerHealthPolling() {
  stopServerHealthPolling();
  if (!token || statusState?.role !== "super") return;
  const tick = async () => {
    checkPanelIdle();
    if (shouldPollHeavy()) await loadServerHealth();
    healthTimer = setTimeout(tick, panelIdle ? PANEL_IDLE_HEARTBEAT_MS : SERVER_HEALTH_POLL_MS);
  };
  healthTimer = setTimeout(tick, SERVER_HEALTH_POLL_MS);
}

function renderNettestReports() {
  const host = document.querySelector("#nettestReports");
  if (!host || statusState?.role !== "super") return;
  if (!nettestReportsState.length) {
    host.innerHTML = `<p class="text-xs text-[var(--muted)]">No saved reports yet.</p>`;
    return;
  }
  host.innerHTML = nettestReportsState.slice(0, 5).map(row => {
    const assessment = row.assessment || {};
    const latency = row.latency || {};
    const timeline = row.timeline_summary || {};
    const geo = row.geo || {};
    const geoLine = formatGeoCompact(geo) || [geo.city, geo.region, geo.country_code || geo.country].filter(Boolean).join(", ") || "-";
    const geoTip = formatGeoTooltip(geo);
    const findings = Array.isArray(assessment.findings) ? assessment.findings.slice(0, 3) : [];
    const internalIp = row["vp" + "n_client_ip"] || row.client_ip || "-";
    const publicIp = row.public_ip || "-";
    const leak = row.leak_checks || {};
    const longestStall = Number(timeline.longest_stall_ms || 0);
    return `
      <div class="nettest-report-row" data-report-filename="${esc(row.filename || "")}">
        <div>
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-semibold">${esc(row.network_type || "-")}</span>
            <span class="text-[var(--muted)]">${esc(row.created_at || "")}</span>
            ${healthBadge(assessment.quality || "unknown")}
            <button type="button" class="delete-nettest-report ml-auto ${buttonClasses("h-7 px-2 text-xs")}">${icon("trash")}<span>Delete</span></button>
          </div>
          <div class="nettest-report-meta">
            <span>${"VP" + "N"} IP ${esc(internalIp)}</span>
            <span>Public ${esc(publicIp)}</span>
            <span>IPv6 leak ${leak.ipv6_leak_suspected ? "yes" : (leak.browser_public_ipv6 ? "no" : "unknown")}</span>
            <span>WebRTC ${leak.webrtc_ipv6_risk ? "risk" : "ok/unknown"}</span>
            <span title="${esc(geoTip)}">Geo: ${esc(geoLine)}</span>
          </div>
        </div>
        <div class="nettest-report-stats">
          <strong>loss ${formatPercent(latency.loss_percent, 1)}</strong>
          <span>avg ${Math.round(Number(latency.avg_ms || 0))} ms · jitter ${Math.round(Number(latency.jitter_ms || 0))} ms</span>
          <span>longest stall ${(longestStall / 1000).toFixed(1)} s · bursts ${timeline.timeout_bursts || latency.stall_events || 0}</span>
          ${assessment.summary ? `<span>${esc(assessment.summary)}</span>` : ""}
          ${findings.length ? `<span>${findings.map(esc).join(" · ")}</span>` : ""}
        </div>
      </div>
    `;
  }).join("");

  host.querySelectorAll("[data-report-filename]").forEach(row => {
    const filename = row.dataset.reportFilename;
    if (!filename) return;
    row.querySelector(".delete-nettest-report").onclick = () => deleteNettestReport(filename);
  });
}

async function deleteNettestReport(filename) {
  const ok = await confirmModal(
    "Delete report",
    `Permanently delete this saved network test report (${filename})?`,
    "Delete",
    true
  );
  if (!ok) return;
  try {
    await api(`/api/nettest/reports/${encodeURIComponent(filename)}`, {method: "DELETE"});
    nettestReportsState = nettestReportsState.filter(row => row.filename !== filename);
    renderNettestReports();
    showToast("Report deleted");
  } catch {
    showToast("Failed to delete report", "error");
  }
}

async function clearAllNettestReports() {
  const ok = await confirmTypedModal(
    "Clear all reports",
    "This permanently deletes every saved network test report. This cannot be undone.",
    "DELETE ALL NETTEST REPORTS",
    "Delete all"
  );
  if (!ok) return;
  try {
    const res = await api("/api/nettest/reports", {method: "DELETE", body: JSON.stringify({confirm: "DELETE ALL NETTEST REPORTS"})});
    nettestReportsState = [];
    renderNettestReports();
    showToast(`Deleted ${res.deleted ?? 0} report(s)`);
  } catch {
    showToast("Failed to clear reports", "error");
  }
}

function renderNettestContext() {
  const host = document.querySelector("#nettestContext");
  if (!host) return;
  if (!nettestContextState) {
    host.innerHTML = `<p class="text-xs text-[var(--muted)]">Config context unavailable.</p>`;
    return;
  }
  const awg = nettestContextState.awg || nettestContextState;
  const assessment = (nettestContextState.assessment || {})[nettestNetworkType] || {};
  const notes = Array.isArray(assessment.notes) ? assessment.notes : [];
  host.innerHTML = `
    <div class="nettest-context-card">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <p class="text-xs font-semibold uppercase text-[var(--muted)]">Connection parameters</p>
        ${healthBadge(assessment.status || "unknown")}
      </div>
      <div class="nettest-metrics">
        <span>Preset ${esc(shortValue(awg.preset))}</span>
        <span>MTU ${esc(shortValue(awg.mtu))}</span>
        <span>Keepalive ${esc(shortValue(awg.persistent_keepalive))}</span>
        <span>Route ${esc(shortValue(awg.route_mode))}</span>
        <span>IPv6 ${esc(shortValue(awg.ipv6_mode))}</span>
        <span>${"P2" + "P"} ports ${esc(shortValue(awg["p2" + "p_ports_per_client"]))}</span>
      </div>
      ${notes.length ? `<ul class="nettest-notes">${notes.map(note => `<li>${esc(note)}</li>`).join("")}</ul>` : ""}
    </div>
  `;
}

async function loadNettestReports() {
  if (statusState?.role !== "super") return;
  try {
    const payload = await api("/api/nettest/reports");
    nettestReportsState = Array.isArray(payload.reports) ? payload.reports : [];
    renderNettestReports();
  } catch {
    nettestReportsState = [];
  }
}

function browserConnectionInfo() {
  const conn = navigator.connection || navigator.mozConnection || navigator.webkitConnection || {};
  return {
    effectiveType: conn.effectiveType || "",
    type: conn.type || "",
    downlink: conn.downlink || null,
    rtt: conn.rtt || null,
    saveData: Boolean(conn.saveData),
    platform: navigator.platform || "",
    timezone_offset_minutes: new Date().getTimezoneOffset(),
    viewport: `${window.innerWidth}x${window.innerHeight}`,
  };
}

async function fetchJsonMaybe(url, timeoutMs = 3500) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {cache: "no-store", signal: controller.signal});
    if (!response.ok) throw new Error("probe failed");
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

function candidateAddresses(candidate) {
  const out = [];
  const re = /(?:^|\s)((?:[0-9]{1,3}\.){3}[0-9]{1,3}|[a-f0-9:]{2,})\s+\d+\s+typ\s+host/ig;
  let match;
  while ((match = re.exec(candidate || ""))) out.push(match[1]);
  return out;
}

function isPrivateCandidate(ip) {
  return /^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^127\.|^169\.254\.|^fe80:/i.test(ip || "");
}

async function collectWebrtcCandidates() {
  const RTCPeer = window.RTCPeerConnection || window.webkitRTCPeerConnection || window.mozRTCPeerConnection;
  if (!RTCPeer) return {webrtc_available: false, webrtc_ipv6_candidates: [], webrtc_private_candidates: []};
  const ipv6 = new Set();
  const priv = new Set();
  const pc = new RTCPeer({iceServers: []});
  try {
    pc.createDataChannel("nettest");
    pc.onicecandidate = event => {
      const cand = event.candidate?.candidate || "";
      for (const addr of candidateAddresses(cand)) {
        if (addr.includes(":")) ipv6.add(addr);
        if (isPrivateCandidate(addr)) priv.add(addr);
      }
    };
    // Bound the whole gathering step so a stuck createOffer/setLocalDescription
    // can't leave the RTCPeerConnection (and this probe) running indefinitely.
    const gather = (async () => {
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await sleep(1200);
    })();
    await Promise.race([gather, sleep(WEBRTC_LEAK_TIMEOUT_MS)]);
  } catch {
    // Browsers may hide host candidates; keep this check best-effort.
  } finally {
    try { pc.close(); } catch {}
  }
  return {
    webrtc_available: true,
    webrtc_ipv6_candidates: [...ipv6].slice(0, 20),
    webrtc_private_candidates: [...priv].slice(0, 20),
  };
}

async function runLeakChecks(context) {
  const notes = [];
  const secureV6Key = "v" + "pn_ipv6";
  if (isPanelIdle()) {
    return {
      browser_public_ipv4: "",
      browser_public_ipv6: "",
      server_public_ipv4: context?.server_public_ipv4 || "",
      server_public_ipv6: context?.server_public_ipv6 || "",
      [secureV6Key]: context?.[secureV6Key] || "",
      ipv6_leak_suspected: false,
      webrtc_available: false,
      webrtc_ipv6_candidates: [],
      webrtc_private_candidates: [],
      notes: ["Skipped: tab inactive or idle"],
    };
  }
  let browser4 = "", browser6 = "";
  try {
    const data4 = await fetchJsonMaybe("https://api.ipify.org?format=json");
    browser4 = data4.ip || "";
  } catch {
    notes.push("IPv4 external probe failed");
  }
  try {
    const data6 = await fetchJsonMaybe("https://api6.ipify.org?format=json");
    browser6 = data6.ip || "";
  } catch {
    notes.push("IPv6 external probe failed or no browser IPv6 path");
  }
  const rtc = await collectWebrtcCandidates();
  const expected6 = [context?.server_public_ipv6, context?.[secureV6Key]].filter(Boolean);
  const ipv6Leak = Boolean(browser6 && (!expected6.length || !expected6.includes(browser6)));
  if (ipv6Leak) notes.push("Browser public IPv6 differs from secure path/server IPv6 context");
  if (rtc.webrtc_ipv6_candidates?.length) notes.push("WebRTC IPv6 host candidates observed");
  return {
    browser_public_ipv4: browser4,
    browser_public_ipv6: browser6,
    server_public_ipv4: context?.server_public_ipv4 || "",
    server_public_ipv6: context?.server_public_ipv6 || "",
    [secureV6Key]: context?.[secureV6Key] || "",
    ipv6_leak_suspected: ipv6Leak,
    webrtc_available: Boolean(rtc.webrtc_available),
    webrtc_ipv6_candidates: rtc.webrtc_ipv6_candidates || [],
    webrtc_private_candidates: rtc.webrtc_private_candidates || [],
    notes,
  };
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// Link a request-local AbortController to the current nettest run, so
// stopNettest()/page unload can cancel in-flight probes immediately.
function attachNettestAbort(controller) {
  if (!activeNettestController) return () => {};
  if (activeNettestController.signal.aborted) {
    controller.abort();
    return () => {};
  }
  const onAbort = () => controller.abort();
  activeNettestController.signal.addEventListener("abort", onAbort);
  return () => activeNettestController?.signal.removeEventListener("abort", onAbort);
}

function cancelNettest(testId) {
  if (!testId) return;
  const url = `${nettestApiBase()}/cancel`;
  const payload = JSON.stringify({test_id: testId});
  if (isDirectNettestMode()) {
    try { navigator.sendBeacon(url, payload); } catch { /* best effort */ }
    return;
  }
  try {
    fetch(url, {
      method: "POST",
      headers: {"Authorization": "Bearer " + token, "Content-Type": "application/json"},
      body: payload,
      keepalive: true,
    }).catch(() => {});
  } catch { /* best effort */ }
}

// Stop any in-progress network test: abort in-flight probes, best-effort
// notify the server so the active-test lock is released, and reset state.
function stopNettest(opts = {}) {
  const reason = opts.reason || "stop";
  if (activeNettestController) {
    activeNettestController.abort();
    activeNettestController = null;
  }
  if (currentNettestRun?.testId && reason !== "report") {
    cancelNettest(currentNettestRun.testId);
  }
  currentNettestRun = null;
  nettestRunning = false;
}

async function fetchWithTimeout(path, options = {}, timeoutMs = NETTEST_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const detach = attachNettestAbort(controller);
  try {
    const headers = Object.assign({"Authorization": "Bearer " + token}, options.headers || {});
    const response = await fetch(path, Object.assign({}, options, {headers, signal: controller.signal}));
    if (!response.ok) throw new Error(response.statusText || "request failed");
    return response;
  } finally {
    clearTimeout(timer);
    detach();
  }
}

function createNettestId() {
  const randomPart = Math.random().toString(36).slice(2, 12);
  return `${Date.now().toString(36)}-${randomPart}`;
}

function nettestProbeEpochs(durationSec) {
  if (durationSec <= 60) return [0];
  if (durationSec <= 300) return [5, durationSec - 12];
  return [5, Math.floor(durationSec / 2) - 5, durationSec - 12];
}

function nettestControlsHTML() {
  const durButtons = Object.entries(NETTEST_DURATIONS).map(([sec, label]) => {
    const active = Number(sec) === nettestDuration;
    return `<button type="button" data-nettest-dur="${esc(sec)}" class="h-8 rounded px-3 text-xs font-semibold transition ${active ? "bg-[var(--accent)] text-white" : "text-[var(--muted)] hover:text-[var(--text)]"}">${esc(label)}</button>`;
  }).join("");
  return `
    <div class="nettest-grid mt-3">
      <div>
        <p class="text-xs font-semibold uppercase text-[var(--muted)]">Network type</p>
        <div class="mt-2 inline-flex rounded-md border border-[var(--line)] bg-[var(--soft)] p-1">
          <button type="button" data-nettest-type="mobile" class="h-8 rounded px-3 text-xs font-semibold transition">Mobile</button>
          <button type="button" data-nettest-type="home" class="h-8 rounded px-3 text-xs font-semibold transition">Home</button>
        </div>
      </div>
      <div>
        <p class="text-xs font-semibold uppercase text-[var(--muted)]">Test duration</p>
        <div class="mt-2 inline-flex rounded-md border border-[var(--line)] bg-[var(--soft)] p-1">
          ${durButtons}
        </div>
      </div>
      <label class="block sm:col-span-2">
        <span class="text-xs font-semibold uppercase text-[var(--muted)]">Optional comment</span>
        <input id="nettestComment" class="mt-2 h-10 w-full rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 text-sm text-[var(--text)] outline-none focus:border-[var(--accent)]" placeholder="home Wi-Fi, mobile LTE..." autocomplete="off">
      </label>
    </div>`;
}

function nettestAssessment(latency, downloadProbe, uploadProbe, stallEvents, longestStallMs) {
  const loss = Number(latency.loss_percent || 0);
  const jitter = Number(latency.jitter_ms || 0);
  const stalls = Number(latency.stall_events || 0);
  const longestSec = (longestStallMs || 0) / 1000;
  let quality = "good";
  let summary = "Connection looks stable";
  if (loss > 5 || stalls >= 3 || longestSec >= 5) {
    quality = "critical";
    summary = "Severe packet loss or repeated stalls";
  } else if (loss > 2 || stalls >= 2 || longestSec >= 3) {
    quality = "poor";
    summary = "Significant packet loss or stalls detected";
  } else if (loss >= 1 || jitter >= 30 || stalls > 0) {
    quality = "warning";
    summary = "Minor packet loss or jitter detected";
  }
  if (!downloadProbe.ok && uploadProbe.ok) summary = "Download probe failed";
  if (!uploadProbe.ok && downloadProbe.ok) summary = "Upload probe failed";
  return {quality, summary};
}

async function runDownloadProbe(testId) {
  const started = performance.now();
  try {
    const response = await fetchNettestProbe(`${nettestApiBase()}/download?size=262144&test_id=${encodeURIComponent(testId)}`, {}, 6000);
    const blob = await response.blob();
    const duration = Math.max(1, performance.now() - started);
    return {ok: true, bytes: blob.size, duration_ms: duration, mbps: (blob.size * 8 / duration / 1000)};
  } catch {
    return {ok: false, bytes: 0, duration_ms: 0, mbps: 0};
  }
}

async function runUploadProbe(testId) {
  const payload = new Uint8Array(128 * 1024);
  for (let i = 0; i < payload.length; i++) payload[i] = i % 251;
  const started = performance.now();
  try {
    const response = await fetchNettestProbe(`${nettestApiBase()}/upload`, {
      method: "POST",
      headers: {"Content-Type": "application/octet-stream", "X-Nettest-Id": testId},
      body: payload,
    }, 6000);
    const data = await response.json();
    const duration = Math.max(1, performance.now() - started);
    const sent = Number(data.bytes || payload.length);
    return {ok: true, bytes: sent, duration_ms: duration, mbps: (sent * 8 / duration / 1000)};
  } catch {
    return {ok: false, bytes: 0, duration_ms: 0, mbps: 0};
  }
}

function renderNettestResult(result) {
  const host = document.querySelector("#nettestResult");
  if (!host || !result) return;
  const stallEvents = Array.isArray(result.stall_events) ? result.stall_events : [];
  const longestStall = (result.timeline_summary || {}).longest_stall_ms || stallEvents.reduce((m, e) => Math.max(m, e.duration_ms || 0), 0);
  const assessment = result.assessment || nettestAssessment(result.latency || {}, result.download_probe || {}, result.upload_probe || {}, stallEvents, longestStall);
  const latency = result.latency || {};
  const downloadProbe = result.download_probe || {};
  const uploadProbe = result.upload_probe || {};
  const leak = result.leak_checks || {};
  const durSec = Number(result.duration_seconds || 0);
  const durLabel = durSec >= 60 ? `${Math.floor(durSec / 60)} min ${durSec % 60} s` : durSec ? `${durSec} s` : "";
  const stallLines = stallEvents.map(e => {
    const t = (e.started_at || "").substr(11, 8);
    const d = e.duration_ms ? `${(e.duration_ms / 1000).toFixed(1)} s` : "open";
    return `<li>${t}: ${d}, ${e.lost_probes || 0} lost</li>`;
  }).join("");
  host.innerHTML = `
    <div class="nettest-result">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <strong>Quality: ${esc(assessment.quality || "unknown")}</strong>
        ${healthBadge(assessment.quality || "unknown")}
        ${durLabel ? `<span class="text-xs text-[var(--muted)]">${esc(durLabel)}</span>` : ""}
      </div>
      <p class="mt-1 text-sm text-[var(--muted)]">${esc(assessment.summary || "")}</p>
      ${(result["vp" + "n_client_ip"] || result.public_ip || result.geo) ? `
        <div class="nettest-metrics">
          <span>${"VP" + "N"} IP ${esc(shortValue(result["vp" + "n_client_ip"] || result.client_ip))}</span>
          <span>Public ${esc(shortValue(result.public_ip))}</span>
          <span title="${esc(formatGeoTooltip(result.geo))}">Geo ${esc(formatGeoCompact(result.geo || {}) || "-")}</span>
        </div>
      ` : ""}
      <div class="nettest-metrics">
        <span>Latency avg ${Math.round(Number(latency.avg_ms || 0))} ms</span>
        <span>Jitter ${Math.round(Number(latency.jitter_ms || 0))} ms</span>
        <span>Loss ${formatPercent(latency.loss_percent, 1)}</span>
        <span>Stalls ${stallEvents.length}</span>
        <span>Download ${Number(downloadProbe.mbps || 0).toFixed(2)} Mbps</span>
        <span>Upload ${Number(uploadProbe.mbps || 0).toFixed(2)} Mbps</span>
      </div>
      <div class="nettest-context-card">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <p class="text-xs font-semibold uppercase text-[var(--muted)]">WebRTC / IPv6 leak checks</p>
          ${healthBadge(leak.ipv6_leak_suspected || leak.webrtc_ipv6_risk ? "critical" : (leak.browser_public_ipv6 ? "ok" : "unknown"))}
        </div>
        <div class="nettest-metrics">
          <span>Browser IPv4 ${esc(shortValue(leak.browser_public_ipv4))}</span>
          <span>Browser IPv6 ${esc(shortValue(leak.browser_public_ipv6))}</span>
          <span>Expected IPv6 ${esc(shortValue(leak.server_public_ipv6 || leak["v" + "pn_ipv6"] || "blocked/none"))}</span>
          <span>WebRTC ${leak.webrtc_available ? "available" : "unavailable"}</span>
        </div>
        ${Array.isArray(leak.notes) && leak.notes.length ? `<ul class="nettest-notes">${leak.notes.map(note => `<li>${esc(note)}</li>`).join("")}</ul>` : ""}
        <p class="mt-2 text-xs text-[var(--muted)]">Android: use Always-on ${"V" + "PN"} and Block connections without ${"V" + "PN"} when the server has no routed IPv6. Browsers may need WebRTC host-candidate limits.</p>
      </div>
      ${stallEvents.length ? `<ul class="nettest-notes">${stallLines}</ul>` : ""}
    </div>
  `;
}

async function runNetworkTest() {
  // Ensure a clean slate even if a previous run left stale state behind
  // (reload mid-test, repeated clicks, abandoned tab, etc.).
  stopNettest({reason: "restart"});
  nettestRunning = true;
  activeNettestController = new AbortController();
  let stopReason = "error";
  const durationSec = nettestDuration;
  const startBtn = document.querySelector("#startNettest");
  const statusEl = document.querySelector("#nettestStatus");
  if (startBtn) startBtn.disabled = true;

  const showLive = (elapsedSec, successPings, totalPings, stallEvents) => {
    if (!statusEl) return;
    const mm = String(Math.floor(elapsedSec / 60)).padStart(2, "0");
    const ss = String(elapsedSec % 60).padStart(2, "0");
    const totMm = String(Math.floor(durationSec / 60)).padStart(2, "0");
    const totSs = String(durationSec % 60).padStart(2, "0");
    const loss = totalPings > 0 ? ((totalPings - successPings) / totalPings * 100).toFixed(1) : "0.0";
    let msg = `Running ${mm}:${ss} / ${totMm}:${totSs}  ·  Loss ${loss}%  ·  Stalls: ${stallEvents.length}`;
    const last = stallEvents[stallEvents.length - 1];
    if (last) {
      const t = (last.started_at || "").substr(11, 8);
      msg += `  ·  Last stall: ${t}`;
      if (last.duration_ms > 0) msg += `, ${(last.duration_ms / 1000).toFixed(1)} s`;
    }
    statusEl.textContent = msg;
  };

  try {
    nettestContextState = nettestContextState || await apiNettest(`${nettestApiBase()}/context`);
    const testId = createNettestId();
    currentNettestRun = {testId};
    const startedAt = new Date().toISOString();
    const deadline = Date.now() + durationSec * 1000;
    let totalProbes = 0, successProbes = 0;
    let consecutiveTimeout = 0;
    let inStall = false, stallStartTime = 0;
    const stallEvents = [];
    const rtts = [];
    const downloadProbes = [], uploadProbes = [];
    const probeEpochs = nettestProbeEpochs(durationSec);
    let nextEpochIdx = 0;
    let stoppedIdle = false;

    while (Date.now() < deadline) {
      if (checkPanelIdle()) {
        stoppedIdle = true;
        stopReason = "idle";
        if (statusEl) statusEl.textContent = "Test stopped due to inactive tab.";
        break;
      }
      const elapsedSec = Math.floor((durationSec * 1000 - Math.max(0, deadline - Date.now())) / 1000);
      showLive(elapsedSec, successProbes, totalProbes, stallEvents);

      if (nextEpochIdx < probeEpochs.length && elapsedSec >= probeEpochs[nextEpochIdx]) {
        nextEpochIdx++;
        if (statusEl) statusEl.textContent = "Probing download / upload...";
        downloadProbes.push(await runDownloadProbe(testId));
        uploadProbes.push(await runUploadProbe(testId));
        if (Date.now() >= deadline) break;
      }

      const t0 = performance.now();
      try {
        // force=1 on the first probe reclaims a stale active-test lock left
        // behind by a reloaded/abandoned previous run for this client.
        const force = totalProbes === 0 ? "1" : "0";
        await fetchNettestProbe(
          `${nettestApiBase()}/ping?n=${encodeURIComponent(Date.now() + "")}&test_id=${encodeURIComponent(testId)}&force=${force}`,
          {}, NETTEST_PING_TIMEOUT_MS
        );
        const rtt = performance.now() - t0;
        rtts.push(rtt);
        successProbes++;
        consecutiveTimeout = 0;
        if (inStall) {
          const last = stallEvents[stallEvents.length - 1];
          last.ended_at = new Date().toISOString();
          last.duration_ms = Math.round(performance.now() - stallStartTime);
          inStall = false;
        }
      } catch {
        consecutiveTimeout++;
        if (!inStall && consecutiveTimeout >= NETTEST_STALL_THRESHOLD) {
          inStall = true;
          stallStartTime = performance.now();
          stallEvents.push({started_at: new Date().toISOString(), ended_at: null, duration_ms: 0, lost_probes: 0});
        }
        if (inStall) stallEvents[stallEvents.length - 1].lost_probes++;
      }
      totalProbes++;
      await sleep(NETTEST_PROBE_INTERVAL_MS);
    }

    if (stoppedIdle) {
      showToast("Network test stopped due to inactive tab", "error");
      return;
    }

    if (inStall && stallEvents.length > 0) {
      const last = stallEvents[stallEvents.length - 1];
      last.ended_at = new Date().toISOString();
      last.duration_ms = Math.round(performance.now() - stallStartTime);
    }

    const finishedAt = new Date().toISOString();
    const lostProbes = totalProbes - successProbes;
    const lossPercent = totalProbes > 0 ? (lostProbes / totalProbes) * 100 : 0;
    const avgRtt = rtts.length ? rtts.reduce((a, b) => a + b, 0) / rtts.length : 0;
    const jitter = rtts.length > 1
      ? rtts.slice(1).reduce((sum, v, i) => sum + Math.abs(v - rtts[i]), 0) / (rtts.length - 1)
      : 0;
    const longestStall = stallEvents.reduce((m, e) => Math.max(m, e.duration_ms || 0), 0);
    const maxConsecutive = stallEvents.reduce((m, e) => Math.max(m, e.lost_probes || 0), 0);

    const latency = {
      samples: totalProbes, ok: successProbes, lost: lostProbes,
      loss_percent: lossPercent,
      min_ms: rtts.length ? Math.min(...rtts) : 0,
      avg_ms: avgRtt,
      max_ms: rtts.length ? Math.max(...rtts) : 0,
      jitter_ms: jitter,
      stall_events: stallEvents.length,
    };
    const bestDownload = downloadProbes.length ? [...downloadProbes].sort((a, b) => (b.mbps || 0) - (a.mbps || 0))[0] : {ok: false, bytes: 0, duration_ms: 0, mbps: 0};
    const bestUpload = uploadProbes.length ? [...uploadProbes].sort((a, b) => (b.mbps || 0) - (a.mbps || 0))[0] : {ok: false, bytes: 0, duration_ms: 0, mbps: 0};
    const timelineSummary = {longest_stall_ms: longestStall, timeout_bursts: stallEvents.length, max_consecutive_timeouts: maxConsecutive};
    if (statusEl) statusEl.textContent = "Checking IPv6 / WebRTC leaks...";
    const leakChecks = await runLeakChecks(nettestContextState || {});
    const assessment = nettestAssessment(latency, bestDownload, bestUpload, stallEvents, longestStall);

    if (statusEl) statusEl.textContent = "Saving report...";
    const report = {
      network_type: nettestNetworkType,
      test_id: testId,
      comment: document.querySelector("#nettestComment")?.value || "",
      user_agent: navigator.userAgent || "",
      browser_connection: browserConnectionInfo(),
      duration_seconds: durationSec,
      probe_interval_ms: NETTEST_PROBE_INTERVAL_MS,
      started_at: startedAt,
      finished_at: finishedAt,
      latency,
      download_probe: bestDownload,
      upload_probe: bestUpload,
      stall_events: stallEvents,
      timeline_summary: timelineSummary,
      leak_checks: leakChecks,
      assessment,
      context: nettestContextState,
    };
    const saved = await apiNettest(`${nettestApiBase()}/report`, {method: "POST", body: JSON.stringify(report)});
    stopReason = "report";
    renderNettestResult(saved.report || report);
    if (statusEl) statusEl.textContent = "Report saved.";
    if (statusState?.role === "super") await loadNettestReports();
  } catch (error) {
    if (statusEl) statusEl.textContent = "Network test failed.";
    showToast(error.message || "Network test failed", "error");
  } finally {
    // On success the server already cleared the active-test lock via
    // /report; otherwise (including an idle-triggered stop) best-effort
    // cancel so a retry isn't blocked by a stale active-test lock.
    stopNettest({reason: stopReason});
    if (startBtn) startBtn.disabled = false;
  }
}

function bindNetworkTester() {
  renderNettestContext();
  document.querySelectorAll("[data-nettest-type]").forEach(btn => {
    const active = btn.dataset.nettestType === nettestNetworkType;
    btn.className = `h-8 rounded px-3 text-xs font-semibold transition ${active ? "bg-[var(--accent)] text-white" : "text-[var(--muted)] hover:text-[var(--text)]"}`;
    btn.onclick = () => {
      nettestNetworkType = btn.dataset.nettestType;
      localStorage.setItem("nettestNetworkType", nettestNetworkType);
      bindNetworkTester();
    };
  });
  document.querySelectorAll("[data-nettest-dur]").forEach(btn => {
    const active = Number(btn.dataset.nettestDur) === nettestDuration;
    btn.className = `h-8 rounded px-3 text-xs font-semibold transition ${active ? "bg-[var(--accent)] text-white" : "text-[var(--muted)] hover:text-[var(--text)]"}`;
    btn.onclick = () => {
      nettestDuration = Number(btn.dataset.nettestDur);
      localStorage.setItem("nettestDuration", nettestDuration);
      bindNetworkTester();
    };
  });
  const start = document.querySelector("#startNettest");
  if (start) start.onclick = runNetworkTest;
}

function renderMenuItem(action, iconName, label, extra = "") {
  return `<button type="button" data-action="${esc(action)}" class="client-menu-item ${extra}">${icon(iconName)}<span>${esc(label)}</span></button>`;
}

function renderLogin() {
  document.title = "Control";
  app.innerHTML = `
    <section class="min-h-screen grid place-items-center">
      <form id="loginForm" class="w-full max-w-sm rounded-lg border border-[var(--line)] bg-[var(--panel)] p-5 shadow-sm">
        <h1 class="text-xl font-semibold">Control</h1>
        <p class="mt-1 text-sm text-[var(--muted)]">Access required</p>
        <label class="sr-only" for="tokenInput">Access token</label>
        <input id="tokenInput" class="mt-4 h-11 w-full rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 text-[var(--text)] outline-none focus:border-[var(--accent)]" type="password" value="${esc(token)}" placeholder="Access token" autocomplete="current-password" autofocus>
        <button class="${primaryButtonClasses("mt-4 w-full")}" type="submit">Continue</button>
      </form>
    </section>
  `;
  const loginForm = document.querySelector("#loginForm");
  loginForm.onsubmit = async event => {
    event.preventDefault();
    token = document.querySelector("#tokenInput").value.trim();
    try {
      statusState = await api("/api/status");
      sessionStorage.setItem("panelToken", token);
      await renderPanel();
    } catch {
      sessionStorage.removeItem("panelToken");
      showToast("Access denied", "error");
    }
  };
  document.querySelector("#tokenInput").addEventListener("keydown", event => {
    if (event.key !== "Enter") return;
    event.preventDefault();
    loginForm.requestSubmit();
  });
}

async function renderPanel() {
  stopClientPolling();
  stopServerHealthPolling();
  const nettestPage = isNetworkTesterPage();
  document.title = statusState.title || "Control";
  if (trafficChart) {
    trafficChart.destroy();
    trafficChart = null;
  }
  app.innerHTML = `
    <header class="flex flex-col gap-4 py-4 sm:flex-row sm:items-center sm:justify-between">
      <div class="flex items-center gap-3">
        <div class="grid h-11 w-11 place-items-center rounded-lg bg-[var(--accent)] text-lg font-black text-white">${esc(statusState.short_label || "C")}</div>
        <div>
          <h1 class="text-xl font-semibold leading-tight">${esc(statusState.display_name || statusState.server_name || "Control")}</h1>
          <p class="flex flex-wrap items-center gap-2 text-sm text-[var(--muted)]">
            <span>v${esc(statusState.version)} · ${esc(statusState.fork)} · ${esc(statusState.role)}</span>
            <span id="connectionStatusPill" class="${CONNECTION_PILL_BASE} ${CONNECTION_STATE_INFO.online.className}">${CONNECTION_STATE_INFO.online.label}</span>
          </p>
        </div>
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <button id="themeToggle" class="${buttonClasses("w-9 px-0")}" title="Theme">${icon(document.documentElement.dataset.theme === "dark" ? "sun" : "moon")}</button>
        <button id="helpButton" class="${buttonClasses("w-9 px-0")}" title="Help & Clients" aria-label="Help & Clients">${icon("help")}</button>
        ${statusState.repository_url ? `<a href="${esc(statusState.repository_url)}" target="_blank" rel="noopener" class="${buttonClasses("w-9 px-0")}" title="Repository" aria-label="Repository">${icon("github")}</a>` : ""}
        ${nettestPage ? `<a href="/" class="${buttonClasses()}">${icon("router")}<span>Web Panel</span></a>` : ""}
        <button id="addClient" class="${primaryButtonClasses()}">${icon("plus")}<span>Add Client</span></button>
        <button id="logout" class="${buttonClasses()}">${icon("logout")}<span>Logout</span></button>
      </div>
    </header>
    <p id="panelIdleNote" class="hidden text-xs text-[var(--muted)]">Paused background refresh after 10 min idle</p>

    <section class="summary-cards mt-3">
      <div class="summary-card summary-card-narrow">
        <p class="text-xs font-semibold uppercase text-[var(--muted)]">Active</p>
        <strong id="metricActive" class="mt-1 block text-2xl">0</strong>
      </div>
      <div class="summary-card summary-card-narrow">
        <p class="text-xs font-semibold uppercase text-[var(--muted)]">Clients</p>
        <strong id="metricClients" class="mt-1 block text-2xl">0</strong>
      </div>
      <div class="summary-card summary-card-traffic">
        <p class="text-xs font-semibold uppercase text-[var(--muted)]">Traffic Total</p>
        <strong id="metricTrafficTotal" class="mt-1 block text-2xl">-</strong>
        <p id="metricTrafficTotalSub" class="mt-1 text-xs text-[var(--muted)]">-</p>
      </div>
      <div class="summary-card summary-card-traffic">
        <p class="text-xs font-semibold uppercase text-[var(--muted)]">30 Days</p>
        <strong id="metricTraffic30d" class="mt-1 block text-2xl">-</strong>
        <p id="metricTraffic30dSub" class="mt-1 text-xs text-[var(--muted)]">-</p>
      </div>
      <div class="summary-card summary-card-links">
        <p class="text-xs font-semibold uppercase text-[var(--muted)]">Links</p>
        <div id="metricLinks" class="summary-link-row mt-2"></div>
      </div>
      <div class="summary-card summary-card-addresses">
        <p class="text-xs font-semibold uppercase text-[var(--muted)]">IP / Addresses</p>
        <div id="metricAddresses" class="summary-address-list mt-2"></div>
      </div>
    </section>

    <section id="trafficPanel" class="mt-3 rounded-lg border border-[var(--line)] bg-[var(--panel)] p-4">
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

    <section id="serverHealthPanel" class="mt-3 rounded-lg border border-[var(--line)] bg-[var(--panel)] p-4 ${statusState.role === "super" ? "" : "hidden"}">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold">Server Health</h2>
          <p class="text-sm text-[var(--muted)]">Cached CPU, memory, disk, network and process checks.</p>
        </div>
        <p id="serverHealthUpdated" class="text-xs text-[var(--muted)]"></p>
      </div>
      <div id="serverHealthGrid" class="server-health-grid mt-3"></div>
      <div id="clientNetworkDiagnostics" class="mt-3"></div>
      <div id="networkExplain"></div>
      <div id="serverHealthHistory" class="mt-3"></div>
      <div class="mt-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <p class="text-xs font-semibold uppercase text-[var(--muted)]">${"VP" + "N"} readiness</p>
          <p id="readinessUpdated" class="text-xs text-[var(--muted)]"></p>
        </div>
        <div id="readinessGrid" class="readiness-grid mt-2"></div>
      </div>
      <div id="ndpProxyPanel" class="mt-4"></div>
    </section>

    <section id="networkTesterPanel" class="mt-3 rounded-lg border border-[var(--line)] bg-[var(--panel)] p-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold">Network Tester</h2>
          <p class="text-sm text-[var(--muted)]">Run a browser-side quality test.</p>
        </div>
        <button id="startNettest" class="${primaryButtonClasses()}">${icon("refresh")}<span>Start test</span></button>
      </div>
      ${nettestControlsHTML()}
      <div id="nettestContext" class="mt-3"></div>
      <p id="nettestStatus" class="mt-3 text-sm text-[var(--muted)]">Ready.</p>
      <div id="nettestResult" class="mt-3"></div>
      <div class="mt-3 ${statusState.role === "super" ? "" : "hidden"}">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <p class="text-xs font-semibold uppercase text-[var(--muted)]">Saved reports</p>
          <button id="clearNettestReports" class="${buttonClasses("h-8 px-2 text-xs")}">${icon("trash")}<span>Clear all reports</span></button>
        </div>
        <div id="nettestReports" class="mt-2"></div>
      </div>
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

    <section id="webAccessPanel" class="mt-3 rounded-lg border border-[var(--line)] bg-[var(--panel)] p-4 ${statusState.role === "super" ? "" : "hidden"}">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold">Web Access</h2>
          <p class="text-sm text-[var(--muted)]">Host and source policy for this panel.</p>
        </div>
        <div class="flex flex-wrap gap-2">
          <button id="testWebAccessPolicy" class="${buttonClasses()}">${icon("shield")}<span>Test policy</span></button>
          <button id="saveWebAccessPolicy" class="${primaryButtonClasses()}">${icon("save")}<span>Save</span></button>
          <button id="saveRestartWebAccessPolicy" class="${buttonClasses("border-amber-600 text-amber-700")}">${icon("refresh")}<span>Save and restart</span></button>
        </div>
      </div>
      <div id="webAccessPolicyForm" class="mt-4"></div>
    </section>

    <section id="geoipPanel" class="mt-3 rounded-lg border border-[var(--line)] bg-[var(--panel)] p-4 ${statusState.role === "super" ? "" : "hidden"}">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold">GeoIP Sources</h2>
          <p class="text-sm text-[var(--muted)]">Lookup providers, tokens, and local MMDB databases.</p>
        </div>
        <button id="saveGeoipProviders" class="${primaryButtonClasses()}">${icon("save")}<span>Save</span></button>
      </div>
      <div id="geoipProvidersForm" class="mt-4"></div>
      <div id="geoipDatabasesPanel" class="mt-4"></div>
    </section>

    <section id="advancedPanel" class="mt-3 rounded-lg border border-[var(--line)] bg-[var(--panel)] p-4 ${statusState.role === "super" ? "" : "hidden"}">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold">Advanced</h2>
        <p class="text-sm text-[var(--muted)]">Disruptive system operations.</p>
        </div>
        <button id="rotateProfile" class="${buttonClasses("border-amber-600 text-amber-700")}">${icon("refresh")}<span>Rotate profile</span></button>
      </div>
    </section>

    <section id="clientFiltersPanel" class="mt-3 rounded-lg border border-[var(--line)] bg-[var(--panel)] p-3">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h2 class="text-sm font-semibold">Client filters</h2>
        <p class="text-xs text-[var(--muted)]">Search and owner filters combine.</p>
      </div>
      <div class="client-filter-grid">
        <div class="client-search-wrap">
          <span class="client-search-icon">${icon("search")}</span>
          <input id="searchInput" class="client-search-input" placeholder="Search clients..." autocomplete="off">
        </div>
        <div id="ownerFilter" class="${canManageClientAssignments() ? "" : "hidden"}"></div>
      </div>
    </section>

    <section id="clientsList" class="mt-4 overflow-hidden rounded-lg border border-[var(--line)] bg-[var(--panel)]"></section>
  `;
  document.querySelector("#themeToggle").onclick = () => setTheme(document.documentElement.dataset.theme === "dark" ? "light" : "dark");
  document.querySelector("#helpButton").onclick = showHelp;
  document.querySelector("#logout").onclick = logout;
  document.querySelector("#addClient").onclick = addClient;
  document.querySelector("#searchInput").oninput = applySearch;
  bindNetworkTester();
  if (statusState.role === "super") document.querySelector("#newToken").onclick = newToken;
  if (statusState.role === "super") document.querySelector("#rotateProfile").onclick = rotateProfile;
  if (statusState.role === "super") {
    document.querySelector("#testWebAccessPolicy").onclick = () => submitWebAccessPolicy("test");
    document.querySelector("#saveWebAccessPolicy").onclick = () => submitWebAccessPolicy("save");
    document.querySelector("#saveRestartWebAccessPolicy").onclick = () => submitWebAccessPolicy("save-restart");
    document.querySelector("#saveGeoipProviders").onclick = saveGeoipProviders;
    document.querySelector("#clearNettestReports").onclick = clearAllNettestReports;
  }
  if (nettestPage) {
    for (const selector of [
      ".summary-cards",
      "#trafficPanel",
      "#topTrafficPanel",
      "#serverHealthPanel",
      "#accessPanel",
      "#webAccessPanel",
      "#advancedPanel",
      "#clientFiltersPanel",
      "#clientsList",
    ]) {
      const el = document.querySelector(selector);
      if (el) el.classList.add("hidden");
    }
    document.querySelector("#addClient")?.classList.add("hidden");
  }
  updateConnectionPill();
  await loadAll();
  if (!nettestPage) {
    startClientPolling();
    startServerHealthPolling();
    startClientLatencyPolling();
  }
}

async function loadAll() {
  if (isNetworkTesterPage()) {
    await loadServerInfo();
    try {
      nettestContextState = await apiNettest(`${nettestApiBase()}/context`);
    } catch {
      nettestContextState = null;
    }
    renderNettestContext();
    if (statusState?.role === "super") await loadNettestReports();
    return;
  }
  await Promise.all([loadClients(), loadServerInfo()]);
  try {
    nettestContextState = await api("/api/nettest/context");
  } catch {
    nettestContextState = null;
  }
  renderNettestContext();
  if (statusState.role === "super") {
    await Promise.all([loadTokens(), loadWebAccessPolicy(), loadServerHealth(), loadClientLatency(), loadNettestReports(), loadGeoipAdmin()]);
  }
}

function renderResolverMetric() {
  const metric = document.querySelector("#metricResolver");
  if (!metric || !resolverState) return;
  const label = resolverState.client_resolver || resolverState.mode || "-";
  if (resolverState.managed_enabled) {
    const url = `http://10.9.9.1:${resolverState.managed_port || 3000}`;
    metric.innerHTML = `
      <span class="min-w-0 flex-1 truncate">${esc(label)}</span>
      <a class="ml-2 inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-[var(--line)] bg-[var(--soft)] text-[var(--accent)] transition hover:border-[var(--accent)]" href="${esc(url)}" target="_blank" rel="noopener" title="Open resolver" aria-label="Open resolver">${icon("external")}</a>
    `;
    metric.classList.add("flex", "items-center");
  } else {
    metric.textContent = label;
    metric.classList.remove("flex", "items-center");
  }
}

async function loadClients() {
  if (!token || pollInFlight) return;
  pollInFlight = true;
  const now = Date.now();
  try {
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
        clientUploadSpeedBps: rxSpeed,
        clientDownloadSpeedBps: txSpeed,
        speedBps,
        traffic_total: client.traffic_total || {rx: 0, tx: 0, total: 0},
        totalBytes: Number(client.traffic_total?.total || 0),
        traffic_30d: client.traffic_30d || {rx: 0, tx: 0, total: 0},
        open_ports: normalizePortList(client.open_ports),
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
  } finally {
    pollInFlight = false;
  }
}

function nextClientPollDelay() {
  if (panelIdle) return PANEL_IDLE_HEARTBEAT_MS;
  return document.hidden ? HIDDEN_CLIENT_POLL_MS : ACTIVE_CLIENT_POLL_MS;
}

function stopClientPolling() {
  if (pollTimer) clearTimeout(pollTimer);
  pollTimer = null;
}

function startClientPolling() {
  stopClientPolling();
  if (!token) return;
  const tick = async () => {
    checkPanelIdle();
    if (shouldPollHeavy()) await loadClients();
    pollTimer = setTimeout(tick, nextClientPollDelay());
  };
  pollTimer = setTimeout(tick, nextClientPollDelay());
}

document.addEventListener("visibilitychange", () => {
  markPanelActivity();
  if (isNetworkTesterPage()) return;
  if (token && statusState) startClientPolling();
  if (token && statusState?.role === "super") {
    startServerHealthPolling();
    startClientLatencyPolling();
  }
});

function renderTraffic() {
  if (!trafficState) return;
  const total = trafficState.total || trafficState.current || {};
  const last30 = trafficState.last_30d || {};
  const totalMetric = document.querySelector("#metricTrafficTotal");
  const totalSub = document.querySelector("#metricTrafficTotalSub");
  const last30Metric = document.querySelector("#metricTraffic30d");
  const last30Sub = document.querySelector("#metricTraffic30dSub");
  if (totalMetric) totalMetric.textContent = bytes(total.total || 0);
  if (totalSub) totalSub.textContent = trafficText(total);
  if (last30Metric) last30Metric.textContent = bytes(last30.total || 0);
  if (last30Sub) last30Sub.textContent = trafficText(last30);

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
    const stats = clientTrafficFromSpeeds(client);
    return {...stats, total: stats.download + stats.upload};
  }
  const data = mode === "total" ? (client.traffic_total || {}) : (client.traffic_30d || {});
  return clientTraffic(data);
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
    const downloadPct = stats.total > 0 ? Math.max(0, Math.min(100, (stats.download / stats.total) * 100)) : 0;
    const uploadPct = Math.max(0, 100 - downloadPct);
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
            <span class="h-full bg-[var(--accent)]" style="width:${downloadPct}%"></span>
            <span class="h-full bg-[var(--muted)]" style="width:${uploadPct}%"></span>
          </div>
        </div>
        <p class="mt-1 text-xs text-[var(--muted)]">${esc(trafficText(stats, topTrafficMode))}</p>
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
  clientCharts.forEach(chart => chart.destroy());
  clientCharts.clear();
  const preservedMenu = openClientMenu;
  const host = document.querySelector("#clientsList");
  renderOwnerFilter();
  if (!latestClients.length) {
    openClientMenu = null;
    host.innerHTML = `<div class="p-8 text-center text-sm text-[var(--muted)]">No clients yet</div>`;
    return;
  }
  const visibleClients = latestClients.filter(client => clientMatchesOwnerFilter(client));
  if (!visibleClients.length) {
    openClientMenu = null;
    host.innerHTML = `<div class="p-8 text-center text-sm text-[var(--muted)]">No clients match this owner filter</div>`;
    return;
  }
  host.innerHTML = visibleClients.map(client => {
    const key = clientKey(client);
    const label = clientDisplayLabel(client);
    const online = isOnline(client);
    const active = recentlyActive(client);
    const ipv4 = client.ipv4 || client.ip || "-";
    const ipv6 = client.ipv6 || "";
    const ip = [client.ipv4 || client.ip, client.ipv6].filter(Boolean).join(" / ") || "-";
    const endpoint = client.endpoint || "-";
    const client30d = client.traffic_30d || {};
    const clientTotal = client.traffic_total || {};
    const portsDisabled = (client.open_ports || []).length > 0 && client.ports_enabled === false;
    const portMarkup = renderPortSummary(client.open_ports || [], portsDisabled);
    const menuId = `client-menu-${String(key).replace(/[^A-Za-z0-9_-]/g, "_")}`;
    const shieldClass = portsDisabled ? "opacity-60" : "";
    const search = `${label} ${key} ${ip} ${endpoint} ${(client.open_ports || []).join(" ")}`.toLowerCase();
    const isAdmin = statusState.role === "super";
    const removeAccessItem = !isAdmin && client.can_remove_from_my_access
      ? renderMenuItem("remove-access", "trash", "Remove from my access", "text-[var(--danger)]")
      : "";
    const deleteOwnedItem = !isAdmin && client.can_delete_self_created
      ? '<div class="border-t border-[var(--line)]"></div>' + renderMenuItem("delete-owned", "trash", "Delete my config", "text-[var(--danger)]")
      : "";
    const adminDeleteItem = isAdmin ? renderMenuItem("delete", "trash", "Delete client", "text-[var(--danger)]") : "";
    return `
      <article class="client-card bg-[var(--panel)] border-b border-[var(--line)] p-4 relative last:border-b-0" data-name="${esc(key)}" data-search="${esc(search)}">
        <div id="chart-${esc(key)}" class="client-card-chart-bg"></div>
        <div class="client-card-content">
          <div class="client-header-row">
            <div class="client-avatar relative z-10 shrink-0 self-start sm:self-auto">
              ${client.avatar}
              <span class="absolute -right-0.5 -bottom-0.5 grid h-3.5 w-3.5 place-items-center">
                ${online ? '<span class="absolute inline-flex h-full w-full rounded-full bg-green-500 opacity-75 animate-ping"></span><span class="relative inline-flex h-3 w-3 rounded-full bg-green-600 ring-2 ring-[var(--panel)]"></span>' : '<span class="relative inline-flex h-3 w-3 rounded-full bg-[var(--muted)] ring-2 ring-[var(--panel)]"></span>'}
              </span>
            </div>
            <div class="client-main relative z-10 min-w-0 flex-1">
              <div class="flex min-w-0 flex-wrap items-center gap-2">
                <h3 class="min-w-0 truncate text-base font-semibold" title="${esc(label)}">${esc(label)}</h3>
                ${client.disabled ? '<span class="rounded-full border border-[var(--danger)] px-2 py-0.5 text-xs font-semibold text-[var(--danger)]">disabled</span>' : ""}
              </div>
              <div class="mt-1 flex flex-wrap gap-1.5">${renderAssignedTokenBadges(client)}</div>
              <div class="mt-1 flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 text-sm text-[var(--muted)]">
                <span class="shrink-0 font-mono text-xs text-[var(--text)]" title="${esc(ipv4)}">${esc(ipv4)}</span>
                ${ipv6 ? `<span class="min-w-0 max-w-full truncate font-mono text-xs" title="${esc(ipv6)}">${esc(ipv6)}</span>` : ""}
              </div>
              <p class="mt-1 text-xs text-[var(--muted)]">${active ? "Active recently" : "No recent traffic"} · Last seen ${esc(timeAgo(client.latestHandshakeAt || client.last_handshake))}</p>
              <p class="mt-1 flex min-w-0 flex-wrap items-center gap-2 text-xs text-[var(--muted)]"><span class="truncate">Endpoint: ${esc(endpoint)}</span>${statusState.role === "super" ? renderLatencyChip(client) + renderSharedProfileChip(client) + renderPathChip(client) : ""}</p>
              ${renderEndpointInfo(client)}
              ${portMarkup ? `<div class="mt-2">${portMarkup}</div>` : ""}
            </div>
          </div>
          <div class="client-traffic relative z-10 min-w-0 text-left sm:min-w-36 sm:text-right">
            <div class="traffic-speed-row">
              <span class="traffic-metric-label">Speed</span>
              <span>↓ ${esc(speed(client.clientDownloadSpeedBps))}</span>
              <span>↑ ${esc(speed(client.clientUploadSpeedBps))}</span>
            </div>
            <div class="traffic-metric-table mt-2">
              ${trafficMetricRow("Total", clientTotal)}
              ${trafficMetricRow("30 days", client30d)}
            </div>
          </div>
          <div class="client-actions relative z-20 flex w-full shrink-0 flex-wrap justify-end gap-1 sm:w-auto">
            <button data-action="download-config" title="Download .conf" aria-label="Download .conf" class="${buttonClasses("client-action client-action-primary")}">${icon("download")}<span class="client-action-label">Download</span></button>
            ${actionButton("qr", "Show QR", "qr", "QR", "client-action-primary")}
            <button data-action="copy-config" title="Copy profile" aria-label="Copy profile" class="${buttonClasses("client-action client-action-primary")}">${icon("copy")}<span class="client-action-label">Copy</span></button>
            <button type="button" data-menu-toggle="${esc(menuId)}" aria-expanded="false" aria-controls="${esc(menuId)}" title="More actions" aria-label="More actions for ${esc(label)}" class="${buttonClasses("client-action w-9 px-0")}">${icon("more")}</button>
            <div id="${esc(menuId)}" class="client-menu hidden" role="menu">
              ${renderMenuItem("copy-config", "copy", "Copy profile")}
              ${renderMenuItem("copy-uri", "link", "Copy URI")}
              ${renderMenuItem("copy-access-link", "link", "Copy access link")}
              <button type="button" data-action="regenerate-config" class="client-menu-item text-amber-700">${icon("refresh")}<span>Regenerate</span></button>
              ${renderMenuItem("toggle", "power", client.disabled ? "Enable client" : "Disable client")}
              ${renderMenuItem("toggle-ports", "shield", "Port details / toggle", shieldClass)}
              ${adminDeleteItem}
              ${removeAccessItem}
              ${deleteOwnedItem}
            </div>
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
      if (expanded) return;
      openClientActionMenu(btn);
    };
  });
  if (preservedMenu) {
    const btn = document.querySelector(`[aria-controls="${preservedMenu}"]`);
    if (btn) {
      openClientActionMenu(btn);
    } else {
      openClientMenu = null;
    }
  }
  drawCharts();
}

function drawCharts() {
  if (!window.ApexCharts) return;
  latestClients.filter(client => clientMatchesOwnerFilter(client)).forEach(client => {
    const key = clientKey(client);
    const el = document.getElementById(`chart-${key}`);
    if (!el) return;
    const chart = new ApexCharts(el, {
      chart: {type: "area", height: "100%", sparkline: {enabled: true}, animations: {enabled: false}, toolbar: {show: false}, background: "transparent"},
      series: [{data: speedHistory.get(key) || []}],
      stroke: {curve: "smooth", width: 2, colors: ["var(--accent)"]},
      fill: {type: "gradient", colors: ["var(--accent)"], gradient: {shadeIntensity: 0.2, opacityFrom: 0.5, opacityTo: 0.05, stops: [0, 90, 100]}},
      tooltip: {enabled: false},
      grid: {show: false},
      dataLabels: {enabled: false},
      xaxis: {labels: {show: false}, axisBorder: {show: false}, axisTicks: {show: false}},
      yaxis: {show: false},
    });
    chart.render();
    clientCharts.set(key, chart);
  });
}

function applySearch() {
  const q = (document.querySelector("#searchInput")?.value || "").trim().toLowerCase();
  document.querySelectorAll(".client-card").forEach(card => {
    card.classList.toggle("hidden", q && !card.dataset.search.includes(q));
  });
}

async function loadHelpClientGroups() {
  if (helpClientGroups) return helpClientGroups;
  try {
    const payload = await api("/api/help/clients");
    helpClientGroups = Array.isArray(payload.groups) ? payload.groups : [];
  } catch {
    helpClientGroups = [];
    showToast("Could not load help", "error");
  }
  return helpClientGroups;
}

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
    ? `<span class="inline-flex items-center rounded-full border border-violet-700/30 bg-violet-500/10 px-2 py-1 text-[11px] font-medium text-violet-700">◇ ${esc(client.supportSummary)}</span>`
    : `${renderHelpSupportBadge("Profile 1.x", client.support[0])}${renderHelpSupportBadge("Profile 1.5", client.support[1])}${renderHelpSupportBadge("Profile 2.0", client.support[2])}`;
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
          <p><span class="font-semibold text-[var(--text)]">Setup:</span> ${esc(client.setupMethod)}</p>
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

async function showHelp() {
  const groups = await loadHelpClientGroups();
  showModal("Help & Clients", `
    <div class="grid gap-4 text-sm">
      <div class="rounded-lg border border-[var(--danger)] bg-[var(--soft)] px-3 py-3">
        <p class="font-bold text-[var(--danger)]">Compatible clients are required for generated profiles.</p>
        <p class="mt-1 text-xs text-[var(--muted)]">If an app rejects advanced parameters, use one of the compatible options below.</p>
      </div>
      <div class="rounded-lg border border-[var(--line)] bg-[var(--soft)] px-3 py-3 text-xs text-[var(--muted)]">
        <p class="font-semibold text-[var(--text)]">Voice / Calls optimization</p>
        <p class="mt-1">MTU 1280 · PersistentKeepalive 25 · UDP conntrack timeout tuning · Full Cone NAT: not enabled by default.</p>
      </div>
      <div class="rounded-lg border border-[var(--line)] bg-[var(--soft)] px-3 py-3 text-xs text-[var(--muted)]">
        <p class="font-semibold text-[var(--text)]">Access links</p>
        <p class="mt-1">Copy access link creates a token-protected HTTPS link that returns raw profile text. Links expire quickly by default. Use a trusted domain/certificate for best results.</p>
      </div>
      <div class="grid gap-4">
        ${groups.map(renderHelpGroup).join("")}
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
    if (action === "uri") return showUri(name);
    if (action === "download-config") return downloadConfig(name);
    if (action === "copy-config") return copyConfig(name);
    if (action === "copy-uri") return copyUri(name);
    if (action === "copy-access-link") return copyAccessLink(name);
    if (action === "regenerate-config") return regenerateConfig(name);
    if (action === "toggle") {
      await api(`/api/clients/${encodeURIComponent(name)}/toggle`, {method: "POST", body: "{}"});
      showToast("Client toggled");
      return loadClients();
    }
    if (action === "toggle-ports") {
      await api(`/api/clients/${encodeURIComponent(name)}/ports/toggle`, {method: "POST", body: "{}"});
      showToast("Ports toggled");
      return loadClients();
    }
    if (action === "delete" || action === "remove-access" || action === "delete-owned") {
      const isAdminDelete = action === "delete" && statusState.role === "super";
      const isOwnedDelete = action === "delete-owned";
      const title = isAdminDelete ? "Delete Client" : (isOwnedDelete ? "Delete My Config" : "Remove Access");
      const message = isAdminDelete
        ? `Delete ${name}?`
        : (isOwnedDelete
          ? `Delete ${name}? The peer/config will be removed from the server.`
          : `Remove ${name} from your access list? The config will remain on the server.`);
      const label = isAdminDelete || isOwnedDelete ? "Delete" : "Remove";
      const ok = await confirmModal(
        title,
        message,
        label,
        true
      );
      if (!ok) return;
      const suffix = isOwnedDelete ? "?action=delete_owned" : (action === "remove-access" ? "?action=remove_access" : "");
      const result = await api(`/api/clients/${encodeURIComponent(name)}${suffix}`, {method: "DELETE"});
      showToast(result.deleted ? "Client deleted" : "Access removed");
      await loadClients();
      if (statusState.role === "super") await loadTokens();
    }
  } catch (error) {
    showToast("Failed", "error");
  }
}

async function checkEndpointPaths() {
  if (clientPathState.batchRunning) return;
  clientPathState.batchRunning = true;
  clientPathState.batchSummary = null;
  renderClientNetworkDiagnostics();
  try {
    const result = await api("/api/clients/path-check", {method: "POST", body: JSON.stringify({target: "endpoint", scope: "active"})});
    clientPathState.batchSummary = result;
    const results = result.results || {};
    Object.keys(results).forEach(name => {
      if (results[name]?.target_type !== ("tun" + "nel")) clientPathState.results[name] = results[name];
    });
    if (result.retry_after) showToast(`Endpoint path scan is rate-limited; try again in ${result.retry_after}s`, "error");
    else showToast(`Endpoint paths checked ${result.checked || 0}/${result.total_candidates || 0}`);
    await loadClientLatency(true);
    renderClients();
  } catch (error) {
    showToast("Endpoint path scan failed", "error");
  } finally {
    clientPathState.batchRunning = false;
    renderClientNetworkDiagnostics();
  }
}

async function checkClientPath(name, target = "endpoint") {
  const runKey = `${name}:${target}`;
  if (clientPathState.running[runKey]) return;
  clientPathState.running[runKey] = true;
  renderClients();
  try {
    const result = await api(`/api/clients/${encodeURIComponent(name)}/path-check`, {method: "POST", body: JSON.stringify({target})});
    if (result.target_type !== ("tun" + "nel")) clientPathState.results[name] = result;
    const path = Array.isArray(result.path) ? result.path : [];
    const count = result.hop_count ?? result.hops;
    const lines = path.map(row => `Hop ${row.hop}: ${row.address || "*"}${row.rtt_ms === null || row.rtt_ms === undefined ? "" : ` · ${row.rtt_ms} ms`}${row.raw ? `\n  ${row.raw}` : ""}`);
    const retry = result.retry_after ? `<p class="text-xs text-[var(--muted)]">Rate limited. Try again in ${esc(result.retry_after)}s.</p>` : "";
    if (result.retry_after) showToast("Path check is rate-limited; try later", "error");
    const kind = result.target_type === ("tun" + "nel") ? `${"Tun" + "nel"} path` : "Endpoint path";
    showModal(`${kind}: ${name}`, `
      <div class="grid gap-3 text-sm">
        <p class="text-[var(--muted)]">${esc(result.note || "Public endpoint path shows route to the client NAT/carrier endpoint, not necessarily the device itself.")}</p>
        <p><strong>Status:</strong> ${esc(result.status || "unknown")}${count ? ` · Path: ${esc(count)} hop${Number(count) === 1 ? "" : "s"}` : ""}${result.method ? ` · Method: ${esc(result.method)}` : ""}</p>
        <p class="text-xs text-[var(--muted)]">Target: ${esc(result.target_ip || result["vp" + "n_ip"] || "-")}${result.endpoint ? ` · Endpoint: ${esc(result.endpoint)}` : ""}</p>
        ${result.summary ? `<p><strong>Summary:</strong> ${esc(result.summary)}</p>` : ""}
        ${lines.length ? `<pre class="rounded-md bg-[var(--soft)] p-3 text-xs">${esc(lines.join("\n"))}</pre>` : ""}
        ${retry}
      </div>
    `);
  } finally {
    delete clientPathState.running[runKey];
    renderClients();
  }
}

async function regenerateConfig(name) {
  const ok = await confirmModal(
    "Regenerate profile",
    `Regenerate profile for "${name}"?\nThe old profile will stop working. Traffic history and client name will be preserved.`,
    "Regenerate",
    false
  );
  if (!ok) return;
  const body = {};
  try {
    if (typeof window.generateI1 === "function" && typeof window.pickI1Sni === "function" && window.crypto?.subtle) {
      const sni = window.pickI1Sni();
      body.i1 = await window.generateI1(sni, 0);
      body.i1_sni = sni;
    }
  } catch (error) {
    const fallback = await confirmModal(
      "Regenerate with fallback?",
      "Browser-side profile generation failed. Continue with system fallback?",
      "Continue",
      false
    );
    if (!fallback) return;
  }
  await api(`/api/clients/${encodeURIComponent(name)}/regenerate`, {method: "POST", body: JSON.stringify(body)});
  configTextCache.delete(name);
  showToast("Profile regenerated. Download or copy the new profile.");
  await loadClients();
}

async function rotateProfile() {
  const preset = await rotateProfileModal();
  if (!preset) return;
  const client_i1 = {};
  try {
    if (typeof window.generateI1 === "function" && typeof window.pickI1Sni === "function" && window.crypto?.subtle) {
      for (const client of latestClients) {
        const sni = window.pickI1Sni();
        client_i1[client.name] = await window.generateI1(sni, 0);
      }
    }
  } catch {
    showToast("Browser generation failed; using system fallback", "error");
  }
  await api("/api/profile/rotate", {
    method: "POST",
    body: JSON.stringify({preset, confirm: "ROTATE", client_i1}),
  });
  configTextCache.clear();
  showToast("Profile rotated. Download or copy new profiles.");
  await loadClients();
}

async function showConfig(name) {
  const text = await configText(name);
  showModal(name, `
    <div class="grid gap-3">
      <div class="flex flex-wrap justify-end gap-2">
        <button id="downloadConfigFromModal" class="${buttonClasses()}">${icon("download")}<span>Download .conf</span></button>
        <button id="copyConfigFromModal" class="${buttonClasses()}">${icon("copy")}<span>Copy profile</span></button>
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

async function showUri(name) {
  const blob = await api(`/api/clients/${encodeURIComponent(name)}/uri`);
  const uri = (await blob.text()).trim();
  showModal(name, `
    <div class="grid gap-3">
      <textarea readonly class="h-32 w-full resize-none rounded-md border border-[var(--line)] bg-[var(--soft)] p-3 font-mono text-xs text-[var(--text)] outline-none">${esc(uri)}</textarea>
      <div class="flex flex-wrap justify-end gap-2">
        <a href="${esc(uri)}" class="${buttonClasses()}">${icon("external")}<span>Open</span></a>
        <button id="copyUri" class="${buttonClasses()}">${icon("copy")}<span>Copy</span></button>
      </div>
    </div>
  `);
  document.querySelector("#copyUri").onclick = async () => {
    await copyText(uri);
    showToast("Copied");
  };
}

async function copyUri(name) {
  const blob = await api(`/api/clients/${encodeURIComponent(name)}/uri`);
  await copyText((await blob.text()).trim());
  showToast("Copied");
}

async function copyAccessLink(name) {
  const result = await api(`/api/clients/${encodeURIComponent(name)}/access-link`, {
    method: "POST",
    body: JSON.stringify({ttl: 300, one_time: true}),
  });
  await copyText(result.url);
  showToast("Access link copied");
}

async function loadTokens() {
  const data = await api("/api/tokens");
  latestTokens = data.users || [];
  renderTokenList();
}

function tokenTraffic(clients) {
  const allowed = new Set(clients || []);
  return latestClients.reduce((total, client) => {
    if (!allowed.has(clientKey(client))) return total;
    const item = clientTraffic(client.traffic_total || {});
    total.rx += item.serverRx;
    total.tx += item.serverTx;
    total.client_download += item.download;
    total.client_upload += item.upload;
    total.total += item.total;
    return total;
  }, {rx: 0, tx: 0, client_download: 0, client_upload: 0, total: 0});
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
        <p class="mt-1 text-xs text-[var(--muted)]">Traffic: ${esc(bytes(stats.total))} (${esc(trafficText(stats))})</p>
      </div>
      <div class="flex flex-wrap gap-2">
        <button data-edit-name="${esc(row.hash)}" title="Edit Name" class="${buttonClasses("w-9 px-0")}">${icon("pencil")}</button>
        <button data-edit-clients="${esc(row.hash)}" class="${buttonClasses()}">${icon("shield")}<span>Clients</span></button>
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
  panel.querySelectorAll("[data-edit-clients]").forEach(btn => {
    btn.onclick = async () => editTokenClients(btn.dataset.editClients);
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

function tokenClientCheckboxes(selectedClients) {
  const selected = new Set(selectedClients || []);
  return latestClients.map(client => `
    <label class="flex items-center gap-2 rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 py-2 text-sm">
      <input class="client-token-check accent-[var(--accent)]" type="checkbox" value="${esc(clientKey(client))}" ${selected.has(clientKey(client)) ? "checked" : ""}>
      <span class="min-w-0 flex-1 truncate">${esc(clientDisplayLabel(client))}</span>
    </label>
  `).join("") || `<p class="text-sm text-[var(--muted)]">No clients exist yet.</p>`;
}

function editTokenClients(hash) {
  const row = latestTokens.find(item => item.hash === hash);
  if (!row) return;
  const label = row.name || "Unnamed token";
  const dialog = document.createElement("dialog");
  dialog.className = "w-[min(680px,calc(100vw-32px))] rounded-lg border border-[var(--line)] bg-[var(--panel)] p-0 text-[var(--text)] shadow-xl backdrop:bg-black/55";
  dialog.innerHTML = `
    <form method="dialog" class="p-4">
      <div class="mb-4 flex items-center justify-between gap-3">
        <div class="min-w-0">
          <h2 class="truncate text-base font-semibold">Client Access</h2>
          <p class="mt-1 truncate text-xs text-[var(--muted)]">${esc(label)}</p>
        </div>
        <button value="cancel" class="${buttonClasses("w-9 px-0")}">x</button>
      </div>
      <div class="grid max-h-[60vh] gap-2 overflow-auto">${tokenClientCheckboxes(row.clients)}</div>
      <div class="mt-4 flex flex-wrap justify-end gap-2">
        <button value="cancel" class="${buttonClasses()}">Cancel</button>
        <button id="saveTokenClients" value="ok" class="${primaryButtonClasses()}">${icon("shield")}<span>Save</span></button>
      </div>
    </form>
  `;
  document.body.appendChild(dialog);
  dialog.addEventListener("click", event => {
    if (event.target === dialog) dialog.close("cancel");
  });
  dialog.querySelector("#saveTokenClients").onclick = async event => {
    event.preventDefault();
    const clients = Array.from(dialog.querySelectorAll(".client-token-check:checked")).map(input => input.value);
    try {
      await api(`/api/tokens/${encodeURIComponent(hash)}/clients`, {
        method: "PUT",
        body: JSON.stringify({clients}),
      });
      dialog.close("ok");
      showToast("Client access updated");
      await loadTokens();
    } catch {
      showToast("Could not update client access", "error");
    }
  };
  dialog.addEventListener("close", () => dialog.remove(), {once: true});
  confirmDialogOnEnter(dialog, () => dialog.querySelector("#saveTokenClients").click());
  dialog.showModal();
}

async function newToken() {
  const body = tokenClientCheckboxes([]);
  const ok = await showModal("Generate Token", `
    <label class="mb-3 block text-sm">
      <span class="mb-1 block text-[var(--muted)]">Token name / alias (optional)</span>
      <input id="newTokenName" class="h-10 w-full rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 text-[var(--text)] outline-none focus:border-[var(--accent)]" maxlength="64" autocomplete="off">
    </label>
    <div class="grid gap-2">${body}</div>
    <div class="mt-4 flex justify-end">
      <button id="createTokenConfirm" class="${primaryButtonClasses()}">${icon("key")}<span>Create</span></button>
    </div>
  `, false);
  if (!ok) return;
}

async function createTokenFromModal(dialog) {
  const clients = Array.from(dialog.querySelectorAll(".client-token-check:checked")).map(input => input.value);
  const name = (dialog.querySelector("#newTokenName")?.value || "").trim();
  const result = await api("/api/tokens", {method: "POST", body: JSON.stringify({clients, name})});
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

async function loadWebAccessPolicy() {
  try {
    webAccessPolicyState = await api("/api/web-access-policy");
    renderWebAccessPolicy();
  } catch {
    showToast("Could not load web access policy", "error");
  }
}

function renderWebAccessPolicy() {
  const host = document.querySelector("#webAccessPolicyForm");
  if (!host || !webAccessPolicyState) return;
  const policy = webAccessPolicyState.policy || {};
  const current = webAccessPolicyState.current || {};
  const edge = webAccessPolicyState.edge || {};
  const rejected = webAccessPolicyState.recent_rejected_hosts || [];
  const mode = webAccessDisplayMode(policy, edge);
  host.innerHTML = `
    <div class="rounded-md border border-[var(--line)] bg-[var(--soft)] p-3 text-xs text-[var(--muted)]">
      <div class="grid gap-2 sm:grid-cols-2">
        <p><span class="font-semibold text-[var(--text)]">Edge mode:</span> ${esc(edge.label || "legacy direct Python listener")}</p>
        <p><span class="font-semibold text-[var(--text)]">Public listener:</span> ${esc(edge.public_listener || "-")}</p>
        <p><span class="font-semibold text-[var(--text)]">Backend app:</span> ${esc(edge.backend_listener || `${policy.bind_host || "-"}:8443`)}</p>
        <p><span class="font-semibold text-[var(--text)]">Backend protocol:</span> ${esc(edge.backend_protocol || "HTTPS")}</p>
      </div>
    </div>
    <div class="grid gap-3 lg:grid-cols-2">
      <label class="block text-sm">
        <span class="mb-1 block text-[var(--muted)]">Preset</span>
        <select id="webAccessBindMode" class="h-10 w-full rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 text-[var(--text)] outline-none focus:border-[var(--accent)]">
          ${[
            ["public_nginx", "Public via nginx"],
            ["restricted_nginx", "Restricted clients via nginx"],
            ["v" + "pn_only_nginx", "V" + "P" + "N-only panel via nginx"],
            ["localhost_maintenance", "Localhost maintenance"],
            ["custom", "Custom / legacy direct"],
          ].map(([value, label]) => `<option value="${value}" ${mode === value ? "selected" : ""}>${label}</option>`).join("")}
        </select>
      </label>
      <label class="block text-sm">
        <span class="mb-1 block text-[var(--muted)]">Backend bind host</span>
        <input id="webAccessBindHost" class="h-10 w-full rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 font-mono text-xs text-[var(--text)] outline-none focus:border-[var(--accent)]" value="${esc(policy.bind_host || "")}" ${mode === "custom" ? "" : "readonly"}>
      </label>
    </div>
    <p id="webAccessDraftStatus" class="mt-2 hidden rounded-md border border-amber-500/50 bg-amber-500/10 px-3 py-2 text-xs text-[var(--text)]"></p>
    <div class="mt-3 grid gap-3 lg:grid-cols-2">
      <label class="flex items-center gap-2 rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 py-2 text-sm">
        <input id="webAccessHostCheck" type="checkbox" class="accent-[var(--accent)]" ${policy.host_check_enabled ? "checked" : ""}>
        <span>Enable Host header check</span>
      </label>
      <label class="flex items-center gap-2 rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 py-2 text-sm">
        <input id="webAccessSourceCheck" type="checkbox" class="accent-[var(--accent)]" ${policy.source_check_enabled ? "checked" : ""}>
        <span>Enable source IP check</span>
      </label>
    </div>
    <div class="mt-3 grid gap-3 lg:grid-cols-3">
      <label class="block text-sm">
        <span class="mb-1 block text-[var(--muted)]">Allowed hosts</span>
        <textarea id="webAccessHosts" class="h-36 w-full resize-y rounded-md border border-[var(--line)] bg-[var(--soft)] p-3 font-mono text-xs text-[var(--text)] outline-none focus:border-[var(--accent)]">${esc((policy.allowed_hosts || []).join("\n"))}</textarea>
      </label>
      <label class="block text-sm">
        <span class="mb-1 block text-[var(--muted)]">Allowed source CIDRs</span>
        <textarea id="webAccessCidrs" class="h-36 w-full resize-y rounded-md border border-[var(--line)] bg-[var(--soft)] p-3 font-mono text-xs text-[var(--text)] outline-none focus:border-[var(--accent)]">${esc((policy.allowed_source_cidrs || []).join("\n"))}</textarea>
      </label>
      <label class="block text-sm">
        <span class="mb-1 block text-[var(--muted)]">Trusted proxy CIDRs</span>
        <textarea id="webAccessTrustedProxies" class="h-36 w-full resize-y rounded-md border border-[var(--line)] bg-[var(--soft)] p-3 font-mono text-xs text-[var(--text)] outline-none focus:border-[var(--accent)]">${esc((policy.trusted_proxy_cidrs || []).join("\n"))}</textarea>
      </label>
    </div>
    <div class="mt-3 rounded-md border border-[var(--line)] bg-[var(--soft)] p-3 text-xs text-[var(--muted)]">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <p><span class="font-semibold text-[var(--text)]">Current Host:</span> ${esc(current.host || "-")}</p>
        <button id="allowCurrentHost" class="${buttonClasses("h-8 px-2 text-xs")}">${icon("plus")}<span>Allow current host</span></button>
      </div>
      <p class="mt-1"><span class="font-semibold text-[var(--text)]">Client IP:</span> ${esc(current.client_ip || current.remote_ip || "-")}</p>
      <p class="mt-1"><span class="font-semibold text-[var(--text)]">Proxy:</span> ${current.proxy_ip ? `${esc(current.proxy_ip)} ${current.trusted_proxy_used ? "trusted" : "untrusted"}` : "none"}</p>
      <p class="mt-1"><span class="font-semibold text-[var(--text)]">nginx:</span> ${edge.nginx_active ? "active reverse proxy mode" : "not detected by this request"}</p>
      <p class="mt-1"><span class="font-semibold text-[var(--text)]">nginx public listener:</span> ${esc(edge.public_listener || "-")}</p>
      <p class="mt-1"><span class="font-semibold text-[var(--text)]">Python backend:</span> ${esc(edge.backend_listener || "-")}</p>
      <p class="mt-1"><span class="font-semibold text-[var(--text)]">Current request:</span> ${current.allowed ? "allowed" : "blocked"}</p>
      <p class="mt-1"><span class="font-semibold text-[var(--text)]">Restart:</span> ${webAccessPolicyState.requires_restart ? "required for bind changes" : "not required for current bind"}</p>
      <p class="mt-1 text-amber-700">If source check is enabled, it checks Client IP from trusted proxy headers, not the 127.0.0.1 proxy peer.</p>
      <p id="webAccessModeHint" class="mt-1 text-amber-700"></p>
    </div>
    <details class="mt-3 rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 py-2 text-xs text-[var(--muted)]">
      <summary class="cursor-pointer font-medium text-[var(--text)]">Recent rejected hosts</summary>
      <div class="mt-2 grid gap-1">
        ${rejected.length ? rejected.map(item => `<p class="truncate font-mono">${esc(item.host || "-")} · ${esc(item.remote || "-")} · ${esc(item.path || "-")}</p>`).join("") : `<p>No recent rejected hosts in this process.</p>`}
      </div>
    </details>
  `;
  host.querySelector("#allowCurrentHost").onclick = () => {
    const currentHost = current.normalized_host || current.host || "";
    const textarea = host.querySelector("#webAccessHosts");
    const rows = textarea.value.split(/\r?\n/).map(row => row.trim()).filter(Boolean);
    if (currentHost && !rows.includes(currentHost)) rows.push(currentHost);
    textarea.value = rows.join("\n");
    markWebAccessChanged();
  };
  host.querySelector("#webAccessBindMode").onchange = () => applyWebAccessModeProfile(true);
  ["#webAccessBindHost", "#webAccessHostCheck", "#webAccessSourceCheck", "#webAccessHosts", "#webAccessCidrs", "#webAccessTrustedProxies"].forEach(selector => {
    const field = host.querySelector(selector);
    if (field) field.oninput = markWebAccessChanged;
    if (field) field.onchange = markWebAccessChanged;
  });
  applyWebAccessModeProfile(false);
}

function webAccessRequiredHosts() {
  return ["194-180-189-244.sslip.io", "194.180.189.244", "localhost", "127.0.0.1"];
}

function webAccessTrustedProxyDefaults() {
  return ["127.0.0.0/8", "::1/128"];
}

function webAccessDisplayMode(policy, edge) {
  const mode = policy.bind_mode || "public_nginx";
  if (mode === "custom" && edge?.mode === "nginx_reverse_proxy") {
    return policy.source_check_enabled ? "restricted_nginx" : "public_nginx";
  }
  if (mode === "public" && edge?.mode === "nginx_reverse_proxy") return "public_nginx";
  if (mode === "v" + "pn_" + "only" && edge?.mode === "nginx_reverse_proxy") return "v" + "pn_only_nginx";
  if (mode === "localhost_only" && edge?.mode === "nginx_reverse_proxy") return "localhost_maintenance";
  return mode;
}

function currentClientCidr() {
  const ip = webAccessPolicyState?.current?.client_ip || "";
  if (!ip || ip === "127.0.0.1" || ip === "::1") return "";
  return ip.includes(":") ? `${ip}/128` : `${ip}/32`;
}

function textareaRows(selector) {
  return (document.querySelector(selector)?.value || "").split(/\r?\n/).map(row => row.trim()).filter(Boolean);
}

function setTextareaRows(selector, rows) {
  const node = document.querySelector(selector);
  if (!node) return;
  const out = [];
  const seen = new Set();
  rows.forEach(row => {
    if (!row || seen.has(row)) return;
    out.push(row);
    seen.add(row);
  });
  node.value = out.join("\n");
}

function ensureTextareaRows(selector, rows) {
  setTextareaRows(selector, textareaRows(selector).concat(rows));
}

function markWebAccessChanged(message = "Unsaved changes") {
  const status = document.querySelector("#webAccessDraftStatus");
  if (!status) return;
  status.textContent = message;
  status.classList.remove("hidden");
}

function applyWebAccessModeProfile(changed) {
  const mode = document.querySelector("#webAccessBindMode")?.value || "public_nginx";
  const bindHost = document.querySelector("#webAccessBindHost");
  const sourceCheck = document.querySelector("#webAccessSourceCheck");
  const hint = document.querySelector("#webAccessModeHint");
  if (!bindHost || !sourceCheck) return;
  ensureTextareaRows("#webAccessTrustedProxies", webAccessTrustedProxyDefaults());
  bindHost.readOnly = mode !== "custom";
  hint.textContent = "";
  if (mode === "public_nginx") {
    bindHost.value = "127.0.0.1";
    sourceCheck.checked = false;
    ensureTextareaRows("#webAccessHosts", webAccessRequiredHosts());
    setTextareaRows("#webAccessCidrs", ["0.0.0.0/0", "::/0"]);
    hint.textContent = "nginx remains the public 443 edge; Python stays on localhost.";
  } else if (mode === "restricted_nginx") {
    bindHost.value = "127.0.0.1";
    sourceCheck.checked = true;
    ensureTextareaRows("#webAccessHosts", webAccessRequiredHosts());
    const cidrs = textareaRows("#webAccessCidrs").filter(row => row !== "0.0.0.0/0" && row !== "::/0");
    const current = currentClientCidr();
    setTextareaRows("#webAccessCidrs", current ? cidrs.concat([current]) : cidrs);
    hint.textContent = "nginx stays public; source check is evaluated against real Client IP.";
  } else if (mode === "v" + "pn_only_nginx") {
    bindHost.value = "127.0.0.1";
    sourceCheck.checked = true;
    ensureTextareaRows("#webAccessHosts", webAccessRequiredHosts());
    const current = currentClientCidr();
    setTextareaRows("#webAccessCidrs", ["10.9.9.0/24", "127.0.0.0/8", "::1/128"].concat(current ? [current] : []));
    hint.textContent = "nginx keeps listening on 443; policy allows selected network CIDR and the current Client IP.";
  } else if (mode === "localhost_maintenance") {
    bindHost.value = "127.0.0.1";
    sourceCheck.checked = true;
    ensureTextareaRows("#webAccessHosts", ["localhost", "127.0.0.1"]);
    setTextareaRows("#webAccessCidrs", ["127.0.0.0/8", "::1/128"]);
    hint.textContent = "Maintenance mode is local/proxy only; test prevents saving if it would block this request.";
  }
  if (changed) markWebAccessChanged(`${document.querySelector("#webAccessBindMode").selectedOptions[0]?.textContent || "Mode"} profile selected; test before saving.`);
}

function readWebAccessPolicyForm() {
  const host = document.querySelector("#webAccessPolicyForm");
  const mode = host.querySelector("#webAccessBindMode").value;
  let bindHost = host.querySelector("#webAccessBindHost").value.trim();
  if (["public_nginx", "restricted_nginx", "v" + "pn_only_nginx", "localhost_maintenance"].includes(mode)) bindHost = "127.0.0.1";
  return {
    bind_mode: mode,
    bind_host: bindHost,
    host_check_enabled: host.querySelector("#webAccessHostCheck").checked,
    source_check_enabled: host.querySelector("#webAccessSourceCheck").checked,
    allowed_hosts: host.querySelector("#webAccessHosts").value.split(/\r?\n/).map(row => row.trim()).filter(Boolean),
    allowed_source_cidrs: host.querySelector("#webAccessCidrs").value.split(/\r?\n/).map(row => row.trim()).filter(Boolean),
    trusted_proxy_cidrs: host.querySelector("#webAccessTrustedProxies").value.split(/\r?\n/).map(row => row.trim()).filter(Boolean),
  };
}

async function submitWebAccessPolicy(action) {
  const policy = readWebAccessPolicyForm();
  try {
    if (action === "test") {
      webAccessPolicyState = await api("/api/web-access-policy/test", {method: "POST", body: JSON.stringify({policy})});
      renderWebAccessPolicy();
      showToast("Policy allows current request");
      return;
    }
    webAccessPolicyState = await api("/api/web-access-policy", {method: "PUT", body: JSON.stringify({policy})});
    renderWebAccessPolicy();
    showToast("Web access policy saved");
    if (action === "save-restart") {
      await api("/api/web-access-policy/restart", {method: "POST", body: "{}"});
      showToast("Web panel restart scheduled");
    }
  } catch (error) {
    showToast("Policy rejected: it may lock out current access", "error");
  }
}

// ---------------------------------------------------------------------------
// GeoIP sources admin: providers/tokens (PUT /api/geoip/providers), live
// "Test" lookups, and local MMDB database status/update/auto-update.
// ---------------------------------------------------------------------------

const GEOIP_PROVIDER_INFO = [
  {name: "maxmind", label: "MaxMind GeoLite2 (local MMDB)", kind: "mmdb"},
  {name: "dbip_mmdb", label: "DB-IP City Lite (local MMDB)", kind: "mmdb"},
  {name: "2ip", label: "2ip.io", kind: "token"},
  {name: "2ip_whois", label: "2ip.io WHOIS (refresh only)", kind: "token-refresh"},
  {name: "ipinfo", label: "ipinfo.io", kind: "token"},
  {name: "dbip", label: "DB-IP API", kind: "token-allowfree"},
  {name: "ip-api", label: "ip-api.com (free, no token)", kind: "free"},
];

async function loadGeoipAdmin() {
  try {
    [geoipProvidersState, geoipDatabasesState] = await Promise.all([
      api("/api/geoip/providers"),
      api("/api/geoip/databases/status"),
    ]);
    renderGeoipProviders();
    renderGeoipDatabases();
  } catch {
    showToast("Could not load GeoIP configuration", "error");
  }
}

const GEOIP_TOKEN_MASK = "********";

function renderGeoipProviders() {
  const host = document.querySelector("#geoipProvidersForm");
  if (!host || !geoipProvidersState) return;
  const providers = geoipProvidersState.providers || {};
  host.innerHTML = `
    <div class="grid gap-2">
      ${GEOIP_PROVIDER_INFO.map(info => {
        const cfg = providers[info.name] || {};
        const tokenValue = cfg.has_token ? GEOIP_TOKEN_MASK : "";
        return `
        <div class="rounded-md border border-[var(--line)] bg-[var(--soft)] p-3" data-geoip-provider="${info.name}">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <label class="flex items-center gap-2 text-sm font-medium">
              <input type="checkbox" class="geoip-enabled accent-[var(--accent)]" ${cfg.enabled ? "checked" : ""}>
              <span>${esc(info.label)}</span>
            </label>
            <div class="flex items-center gap-2">
              <span class="geoip-test-result text-xs text-[var(--muted)]"></span>
              <button type="button" class="geoip-test ${buttonClasses("h-8 px-2 text-xs")}">${icon("shield")}<span>Test</span></button>
            </div>
          </div>
          ${info.kind === "token" || info.kind === "token-refresh" || info.kind === "token-allowfree" ? `
            <label class="mt-2 block text-xs">
              <span class="mb-1 block text-[var(--muted)]">API token${cfg.has_token ? " (set - leave as-is to keep)" : ""}</span>
              <input type="password" class="geoip-token h-9 w-full rounded-md border border-[var(--line)] bg-[var(--panel)] px-2 font-mono text-xs text-[var(--text)] outline-none focus:border-[var(--accent)]" placeholder="${cfg.has_token ? "" : "no token configured"}" value="${esc(tokenValue)}">
            </label>
          ` : ""}
          ${info.kind === "token-allowfree" ? `
            <label class="mt-2 flex items-center gap-2 text-xs">
              <input type="checkbox" class="geoip-allow-free accent-[var(--accent)]" ${cfg.allow_free ? "checked" : ""}>
              <span>Allow free (no-token) DB-IP API endpoint</span>
            </label>
          ` : ""}
          ${info.kind === "token-refresh" ? `
            <label class="mt-2 flex items-center gap-2 text-xs">
              <input type="checkbox" class="geoip-only-refresh accent-[var(--accent)]" ${cfg.only_on_refresh !== false ? "checked" : ""}>
              <span>Only run on manual "Refresh" (avoid rate limits)</span>
            </label>
          ` : ""}
          ${info.kind === "mmdb" ? `<p class="mt-1 text-xs text-[var(--muted)]">Database file managed below.</p>` : ""}
        </div>`;
      }).join("")}
    </div>
  `;

  host.querySelectorAll("[data-geoip-provider]").forEach(row => {
    const name = row.dataset.geoipProvider;
    row.querySelector(".geoip-test").onclick = async () => {
      const resultEl = row.querySelector(".geoip-test-result");
      resultEl.textContent = "Testing...";
      try {
        const res = await api("/api/geoip/providers/test", {method: "POST", body: JSON.stringify({provider: name})});
        if (res.ok) {
          const r = res.result || {};
          resultEl.textContent = `OK: ${[r.country, r.city, r.asn].filter(Boolean).join(", ") || "(no data)"}`;
          resultEl.className = "geoip-test-result text-xs text-green-700";
        } else {
          resultEl.textContent = `Failed: ${res.error || "unknown error"}`;
          resultEl.className = "geoip-test-result text-xs text-[var(--danger)]";
        }
      } catch {
        resultEl.textContent = "Test request failed";
        resultEl.className = "geoip-test-result text-xs text-[var(--danger)]";
      }
    };
  });
}

function readGeoipProvidersForm() {
  const host = document.querySelector("#geoipProvidersForm");
  const providers = {};
  host.querySelectorAll("[data-geoip-provider]").forEach(row => {
    const name = row.dataset.geoipProvider;
    const entry = {enabled: row.querySelector(".geoip-enabled").checked};
    const tokenInput = row.querySelector(".geoip-token");
    if (tokenInput) entry.token = tokenInput.value;
    const allowFree = row.querySelector(".geoip-allow-free");
    if (allowFree) entry.allow_free = allowFree.checked;
    const onlyRefresh = row.querySelector(".geoip-only-refresh");
    if (onlyRefresh) entry.only_on_refresh = onlyRefresh.checked;
    providers[name] = entry;
  });
  return providers;
}

async function saveGeoipProviders() {
  const providers = readGeoipProvidersForm();
  try {
    geoipProvidersState = await api("/api/geoip/providers", {method: "PUT", body: JSON.stringify({providers})});
    renderGeoipProviders();
    showToast("GeoIP providers saved");
  } catch {
    showToast("Failed to save GeoIP providers", "error");
  }
}

function formatBytes(bytes) {
  const n = Number(bytes || 0);
  if (n <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  let i = 0, v = n;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
  return `${v.toFixed(v >= 10 || i === 0 ? 0 : 1)} ${units[i]}`;
}

const GEOIP_DB_LABELS = {
  maxmind_asn: "MaxMind GeoLite2 ASN",
  maxmind_city: "MaxMind GeoLite2 City",
  maxmind_country: "MaxMind GeoLite2 Country",
  dbip_city_lite: "DB-IP City Lite",
};

function renderGeoipDatabases() {
  const host = document.querySelector("#geoipDatabasesPanel");
  if (!host || !geoipDatabasesState) return;
  const databases = geoipDatabasesState.databases || {};
  const auto = geoipDatabasesState.auto_update || {};
  host.innerHTML = `
    <div class="flex flex-wrap items-center justify-between gap-2">
      <p class="text-xs font-semibold uppercase text-[var(--muted)]">MMDB databases</p>
      <div class="flex flex-wrap gap-2">
        <button id="geoipUpdateDbs" class="${buttonClasses("h-8 px-3 text-xs")}">${icon("refresh")}<span>Update now</span></button>
        <button id="geoipAutoUpdateToggle" class="${buttonClasses("h-8 px-3 text-xs")}">${icon("power")}<span>${auto.enabled ? "Disable" : "Enable"} weekly auto-update</span></button>
      </div>
    </div>
    <div class="mt-2 grid gap-2 sm:grid-cols-2">
      ${Object.entries(GEOIP_DB_LABELS).map(([name, label]) => {
        const db = databases[name] || {};
        return `
        <div class="rounded-md border border-[var(--line)] bg-[var(--soft)] p-2 text-xs text-[var(--muted)]">
          <p class="font-medium text-[var(--text)]">${esc(label)}</p>
          ${db.present ? `
            <p>Size: ${formatBytes(db.size_bytes)} - Updated: ${esc(db.downloaded_at || db.mtime || "-")}</p>
            <p class="break-all">sha256: ${esc((db.sha256 || "").slice(0, 16))}...</p>
          ` : `<p>${db.last_error ? `Error: ${esc(db.last_error)}` : "Not downloaded yet"}</p>`}
        </div>`;
      }).join("")}
    </div>
    <p class="mt-2 text-xs text-[var(--muted)]">Weekly auto-update timer: <span class="font-medium text-[var(--text)]">${auto.enabled ? "enabled" : "disabled"}</span> (${esc(auto.active_state || "unknown")})</p>
  `;

  document.querySelector("#geoipUpdateDbs").onclick = async () => {
    const btn = document.querySelector("#geoipUpdateDbs");
    btn.disabled = true;
    btn.innerHTML = `${icon("refresh")}<span>Updating...</span>`;
    try {
      const res = await api("/api/geoip/databases/update", {method: "POST", body: "{}"});
      geoipDatabasesState = {databases: res.databases, auto_update: res.auto_update};
      renderGeoipDatabases();
      showToast(res.ok ? "GeoIP databases updated" : "GeoIP database update finished with errors", res.ok ? "success" : "error");
    } catch {
      showToast("Failed to update GeoIP databases", "error");
      btn.disabled = false;
      btn.innerHTML = `${icon("refresh")}<span>Update now</span>`;
    }
  };

  document.querySelector("#geoipAutoUpdateToggle").onclick = async () => {
    const enable = !auto.enabled;
    const ok = await confirmModal(
      enable ? "Enable weekly GeoIP auto-update" : "Disable weekly GeoIP auto-update",
      enable
        ? "Install and enable a weekly systemd timer that downloads fresh GeoIP MMDB databases."
        : "Disable and stop the weekly GeoIP database auto-update timer.",
      enable ? "Enable" : "Disable",
      false
    );
    if (!ok) return;
    try {
      const res = await api("/api/geoip/auto-update", {method: "POST", body: JSON.stringify({enabled: enable})});
      geoipDatabasesState.auto_update = res.auto_update;
      renderGeoipDatabases();
      showToast(`GeoIP auto-update ${enable ? "enabled" : "disabled"}`);
    } catch {
      showToast("Failed to change GeoIP auto-update", "error");
    }
  };
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

function rotateProfileModal() {
  return new Promise(resolve => {
    const dialog = document.createElement("dialog");
    dialog.className = "w-[min(520px,calc(100vw-32px))] rounded-lg border border-[var(--line)] bg-[var(--panel)] p-0 text-[var(--text)] shadow-xl backdrop:bg-black/55";
    dialog.innerHTML = `
      <form method="dialog" class="p-4">
        <h2 class="mb-2 text-base font-semibold">Rotate profile</h2>
        <p class="text-sm text-[var(--muted)]">Refresh system parameters and regenerate all client profiles. Existing access links stop working until clients download or copy fresh profiles.</p>
        <fieldset class="mt-4 grid gap-2" aria-label="Profile preset">
          <label class="flex cursor-pointer gap-3 rounded-md border border-[var(--line)] bg-[var(--soft)] p-3">
            <input type="radio" name="rotatePreset" value="mobile" checked class="mt-1 accent-[var(--accent)]">
            <span>
              <span class="block text-sm font-semibold">Mobile</span>
              <span class="block text-xs text-[var(--muted)]">Conservative jitter and small S3/S4 values for mobile networks and calls.</span>
            </span>
          </label>
          <label class="flex cursor-pointer gap-3 rounded-md border border-[var(--line)] bg-[var(--soft)] p-3">
            <input type="radio" name="rotatePreset" value="default" class="mt-1 accent-[var(--accent)]">
            <span>
              <span class="block text-sm font-semibold">Default</span>
              <span class="block text-xs text-[var(--muted)]">Balanced general-purpose profile for stable networks.</span>
            </span>
          </label>
        </fieldset>
        <p class="mt-3 rounded-md border border-amber-500/50 bg-amber-500/10 p-3 text-xs text-[var(--text)]">This does not rotate keys, IPs, port rules, RBAC, expiry, or traffic history.</p>
        <label class="mt-3 flex cursor-pointer items-start gap-2 text-xs text-[var(--text)]">
          <input type="checkbox" id="rotateProfileAck" class="mt-0.5 accent-[var(--accent)]">
          <span>I understand this regenerates the profile for <strong>all clients</strong> and existing access links will stop working until reimported.</span>
        </label>
        <label class="mt-2 block text-xs">
          <span class="mb-1 block text-[var(--muted)]">Type <span class="font-mono font-semibold text-[var(--text)]">ROTATE</span> to confirm</span>
          <input type="text" id="rotateProfileConfirmText" class="h-9 w-full rounded-md border border-[var(--line)] bg-[var(--soft)] px-2 font-mono text-sm text-[var(--text)] outline-none focus:border-[var(--accent)]" autocomplete="off" spellcheck="false">
        </label>
        <div class="mt-4 flex flex-wrap justify-end gap-2">
          <button type="button" value="cancel" class="${buttonClasses()}">Cancel</button>
          <button type="button" value="ok" id="rotateProfileConfirmButton" class="${buttonClasses("border-amber-600 bg-amber-500 text-white")} disabled:opacity-50" disabled>Rotate profile</button>
        </div>
      </form>
    `;
    document.body.appendChild(dialog);
    const ack = dialog.querySelector("#rotateProfileAck");
    const confirmText = dialog.querySelector("#rotateProfileConfirmText");
    const confirmButton = dialog.querySelector("#rotateProfileConfirmButton");
    const cancelButton = dialog.querySelector('button[value="cancel"]');
    const updateEnabled = () => {
      confirmButton.disabled = !(ack.checked && confirmText.value === "ROTATE");
    };
    ack.addEventListener("change", updateEnabled);
    confirmText.addEventListener("input", updateEnabled);
    confirmText.addEventListener("keydown", evt => {
      if (evt.key === "Enter" && !confirmButton.disabled) dialog.close("ok");
    });
    let resolved = false;
    const finish = preset => {
      if (resolved) return;
      resolved = true;
      dialog.close();
      resolve(preset);
    };
    cancelButton.onclick = () => finish(null);
    confirmButton.onclick = () => {
      if (confirmButton.disabled) return;
      const preset = dialog.querySelector("input[name='rotatePreset']:checked")?.value;
      finish(["mobile", "default"].includes(preset) ? preset : null);
    };
    dialog.addEventListener("close", () => {
      dialog.remove();
      finish(null);
    }, {once: true});
    dialog.showModal();
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

function confirmTypedModal(title, message, requiredText, confirmLabel = "Confirm") {
  return new Promise(resolve => {
    const dialog = document.createElement("dialog");
    dialog.className = "w-[min(420px,calc(100vw-32px))] rounded-lg border border-[var(--line)] bg-[var(--panel)] p-0 text-[var(--text)] shadow-xl backdrop:bg-black/55";
    dialog.innerHTML = `
      <form method="dialog" class="p-4">
        <h2 class="mb-2 text-base font-semibold">${esc(title)}</h2>
        <p class="text-sm text-[var(--muted)]">${esc(message)}</p>
        <p class="mt-2 text-xs text-[var(--muted)]">Type <span class="font-mono font-semibold text-[var(--text)]">${esc(requiredText)}</span> to confirm.</p>
        <input type="text" class="confirm-typed-input mt-2 h-9 w-full rounded-md border border-[var(--line)] bg-[var(--soft)] px-2 font-mono text-sm text-[var(--text)] outline-none focus:border-[var(--accent)]" autocomplete="off" spellcheck="false">
        <div class="mt-4 flex justify-end gap-2">
          <button type="button" value="cancel" class="${buttonClasses()}">Cancel</button>
          <button type="button" value="ok" class="confirm-typed-ok ${buttonClasses("border-[var(--danger)] bg-[var(--danger)] text-white")} disabled:opacity-50" disabled>${esc(confirmLabel)}</button>
        </div>
      </form>
    `;
    document.body.appendChild(dialog);
    const input = dialog.querySelector(".confirm-typed-input");
    const okBtn = dialog.querySelector(".confirm-typed-ok");
    const cancelBtn = dialog.querySelector('button[value="cancel"]');
    let resolved = false;
    const finish = ok => {
      if (resolved) return;
      resolved = true;
      dialog.close();
      resolve(ok);
    };
    input.oninput = () => {
      okBtn.disabled = input.value !== requiredText;
    };
    input.addEventListener("keydown", evt => {
      if (evt.key === "Enter" && !okBtn.disabled) finish(true);
    });
    cancelBtn.onclick = () => finish(false);
    okBtn.onclick = () => { if (!okBtn.disabled) finish(true); };
    dialog.addEventListener("close", () => {
      dialog.remove();
      finish(false);
    }, {once: true});
    dialog.showModal();
    setTimeout(() => input.focus(), 0);
  });
}

async function renderDirectNettest() {
  app.innerHTML = `
    <header class="flex flex-col gap-4 py-4 sm:flex-row sm:items-center sm:justify-between">
      <div class="flex items-center gap-3">
        <div class="grid h-11 w-11 place-items-center rounded-lg bg-[var(--accent)] text-lg font-black text-white">NT</div>
        <div>
          <h1 class="text-xl font-semibold leading-tight">Network Tester</h1>
          <p class="flex flex-wrap items-center gap-2 text-sm text-[var(--muted)]">
            <span>Quality check — no login required</span>
            <span id="connectionStatusPill" class="${CONNECTION_PILL_BASE} ${CONNECTION_STATE_INFO.online.className}">${CONNECTION_STATE_INFO.online.label}</span>
          </p>
        </div>
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <button id="themeToggle" class="${buttonClasses("w-9 px-0")}" title="Theme">${icon(document.documentElement.dataset.theme === "dark" ? "sun" : "moon")}</button>
      </div>
    </header>
    <section class="mt-3 rounded-lg border border-[var(--line)] bg-[var(--panel)] p-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold">Network Tester</h2>
          <p class="text-sm text-[var(--muted)]">Run a lightweight browser-side quality test on this connection.</p>
        </div>
        <button id="startNettest" class="${primaryButtonClasses()}">${icon("refresh")}<span>Start test</span></button>
      </div>
      ${nettestControlsHTML()}
      <div id="nettestContext" class="mt-3"></div>
      <p id="nettestStatus" class="mt-3 text-sm text-[var(--muted)]">Ready.</p>
      <div id="nettestResult" class="mt-3"></div>
    </section>
  `;
  document.querySelector("#themeToggle").onclick = () => setTheme(document.documentElement.dataset.theme === "dark" ? "light" : "dark");
  updateConnectionPill();
  try {
    nettestContextState = await apiNettest(`${nettestApiBase()}/context`);
  } catch {
    nettestContextState = null;
  }
  renderNettestContext();
  bindNetworkTester();
}

async function boot() {
  if (isDirectNettestMode()) {
    await renderDirectNettest();
    return;
  }
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
