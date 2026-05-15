const app = document.querySelector("#app");
const toastHost = document.querySelector("#toastHost");
let token = localStorage.getItem("panelToken") || "";
let statusState = null;
let dnsState = null;
let trafficState = null;
let latestClients = [];
let pollTimer = null;
const previousRx = new Map();
const previousTx = new Map();
const previousSampleAt = new Map();
const speedHistory = new Map();
const charts = new Map();
let trafficChart = null;

const icons = {
  sun: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3v2.2M12 18.8V21M4.2 4.2l1.6 1.6M18.2 18.2l1.6 1.6M3 12h2.2M18.8 12H21M4.2 19.8l1.6-1.6M18.2 5.8l1.6-1.6"/><circle cx="12" cy="12" r="4"/></svg>',
  moon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M21 12.8A8.5 8.5 0 1 1 11.2 3 6.8 6.8 0 0 0 21 12.8Z"/></svg>',
  plus: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 5v14M5 12h14"/></svg>',
  logout: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M15 7V5a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h7a2 2 0 0 0 2-2v-2"/><path d="M10 12h11M18 9l3 3-3 3"/></svg>',
  power: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 2v10"/><path d="M18.4 6.6a9 9 0 1 1-12.8 0"/></svg>',
  file: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8Z"/><path d="M14 2v6h6"/></svg>',
  qr: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4z"/><path d="M14 14h2v2h-2zM18 14h2v6h-4v-2M14 18v2"/></svg>',
  trash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 6h18M8 6V4h8v2M6 6l1 15h10l1-15"/><path d="M10 11v6M14 11v6"/></svg>',
  search: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>',
  key: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="7.5" cy="14.5" r="4.5"/><path d="M11 11 21 1M16 6l2 2M14 8l2 2"/></svg>',
  copy: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="9" y="9" width="11" height="11" rx="2"/><rect x="4" y="4" width="11" height="11" rx="2"/></svg>',
  help: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="9"/><path d="M9.5 9a2.6 2.6 0 0 1 5 1c0 2-2.5 2.2-2.5 4"/><path d="M12 17h.01"/></svg>',
  external: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M14 3h7v7"/><path d="M10 14 21 3"/><path d="M21 14v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5"/></svg>',
  shield: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M9 12.75 11.25 15 15 9.75"/><path d="M12 3.75c2.1 1.95 4.95 3 7.88 3-.42 6.15-3.25 10.69-7.88 13.5-4.63-2.81-7.46-7.35-7.88-13.5 2.93 0 5.78-1.05 7.88-3Z"/></svg>',
  link: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M10.5 13.5 13.5 10.5"/><path d="M8.5 15.5 7 17a4 4 0 0 1-5.7-5.6l2.1-2.1A4 4 0 0 1 9 9"/><path d="M15.5 8.5 17 7a4 4 0 0 1 5.7 5.6l-2.1 2.1A4 4 0 0 1 15 15"/></svg>',
};

const theme = localStorage.getItem("panelTheme") || "light";
document.documentElement.dataset.theme = theme;

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
  return `h-9 inline-flex items-center justify-center gap-2 rounded-md border border-transparent bg-red-700 px-3 text-sm font-bold text-white transition hover:bg-red-800 ${extra}`;
}

function iconButton(title, name, extra = "") {
  return `<button title="${esc(title)}" aria-label="${esc(title)}" class="${buttonClasses(`w-9 px-0 ${extra}`)}">${icon(name)}</button>`;
}

function renderLogin() {
  app.innerHTML = `
    <section class="min-h-screen grid place-items-center">
      <form id="loginForm" class="w-full max-w-sm rounded-lg border border-[var(--line)] bg-[var(--panel)] p-5 shadow-sm">
        <div class="mb-5">
          <h1 class="text-xl font-semibold">AmneziaWG</h1>
          <p class="mt-1 text-sm text-[var(--muted)]">fork delta/patchset web panel</p>
        </div>
        <label class="block text-xs font-semibold uppercase tracking-wide text-[var(--muted)]" for="tokenInput">Token</label>
        <input id="tokenInput" class="mt-2 h-11 w-full rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 text-[var(--text)] outline-none focus:border-[var(--accent)]" type="password" value="${esc(token)}" autocomplete="current-password" autofocus>
        <button class="${primaryButtonClasses("mt-4 w-full")}" type="submit">Login</button>
      </form>
    </section>
  `;
  document.querySelector("#loginForm").onsubmit = async event => {
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

    <section id="clientsList" class="mt-4 overflow-hidden rounded-lg border border-[var(--line)] bg-[var(--panel)]"></section>
  `;
  document.querySelector("#themeToggle").onclick = () => setTheme(document.documentElement.dataset.theme === "dark" ? "light" : "dark");
  document.querySelector("#helpButton").onclick = showHelp;
  document.querySelector("#logout").onclick = logout;
  document.querySelector("#addClient").onclick = addClient;
  document.querySelector("#searchInput").oninput = applySearch;
  if (statusState.role === "super") document.querySelector("#newToken").onclick = newToken;
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
      totalBytes: rx + tx,
      traffic_30d: client.traffic_30d || {rx: 0, tx: 0, total: 0},
      p2p_ports: normalizeP2pPorts(client.p2p_ports),
      avatar: await avatarHtml(client.name),
    });
  }));
  renderClients();
  document.querySelector("#metricClients").textContent = latestClients.length;
  document.querySelector("#metricActive").textContent = latestClients.filter(isOnline).length;
  renderTraffic();
  applySearch();
}

function renderTraffic() {
  if (!trafficState) return;
  const total = trafficState.current || {};
  const last30 = trafficState.last_30d || {};
  const totalMetric = document.querySelector("#metricTrafficTotal");
  const totalSub = document.querySelector("#metricTrafficTotalSub");
  const last30Metric = document.querySelector("#metricTraffic30d");
  const last30Sub = document.querySelector("#metricTraffic30dSub");
  if (totalMetric) totalMetric.textContent = bytes(total.total || 0);
  if (totalSub) totalSub.textContent = `Down ${bytes(total.rx || 0)} · Up ${bytes(total.tx || 0)}`;
  if (last30Metric) last30Metric.textContent = bytes(last30.total || 0);
  if (last30Sub) last30Sub.textContent = `Down ${bytes(last30.rx || 0)} · Up ${bytes(last30.tx || 0)}`;

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

function renderClients() {
  charts.forEach(chart => chart.destroy());
  charts.clear();
  const host = document.querySelector("#clientsList");
  if (!latestClients.length) {
    host.innerHTML = `<div class="p-8 text-center text-sm text-[var(--muted)]">No clients yet</div>`;
    return;
  }
  host.innerHTML = latestClients.map(client => {
    const online = isOnline(client);
    const ip = [client.ipv4 || client.ip, client.ipv6].filter(Boolean).join(" / ") || "-";
    const endpoint = client.endpoint || "-";
    const client30d = client.traffic_30d || {};
    const p2pDisabled = (client.p2p_ports || []).length > 0 && client.p2p_enabled === false;
    const p2pBadgeClass = `inline-block px-2 py-0.5 text-[10px] font-medium bg-[var(--soft)] border border-[var(--line)] rounded-full${p2pDisabled ? " opacity-50" : ""}`;
    const shieldClass = p2pDisabled ? "w-9 px-0 opacity-50" : "w-9 px-0";
    const search = `${client.name} ${ip} ${endpoint} ${(client.p2p_ports || []).join(" ")}`.toLowerCase();
    return `
      <article class="client-card bg-[var(--panel)] border-b border-[var(--line)] p-4 flex flex-col gap-4 relative overflow-hidden last:border-b-0 sm:flex-row sm:items-center" data-name="${esc(client.name)}" data-search="${esc(search)}">
        <div id="chart-${esc(client.name)}" class="pointer-events-none absolute inset-x-0 bottom-0 z-0 h-full opacity-20"></div>
        <div class="relative z-10 shrink-0 self-start sm:self-auto">
          ${client.avatar}
          <span class="absolute -right-0.5 -bottom-0.5 grid h-3.5 w-3.5 place-items-center">
            ${online ? '<span class="absolute inline-flex h-full w-full rounded-full bg-green-500 opacity-75 animate-ping"></span><span class="relative inline-flex h-3 w-3 rounded-full bg-green-600 ring-2 ring-[var(--panel)]"></span>' : '<span class="relative inline-flex h-3 w-3 rounded-full bg-[var(--muted)] ring-2 ring-[var(--panel)]"></span>'}
          </span>
        </div>
        <div class="relative z-10 min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2">
            <h3 class="truncate text-sm font-semibold">${esc(client.name)}</h3>
            ${client.disabled ? '<span class="rounded-full border border-[var(--danger)] px-2 py-0.5 text-xs font-semibold text-[var(--danger)]">disabled</span>' : ""}
          </div>
          <p class="mt-1 truncate text-sm text-[var(--muted)]">${esc(ip)}</p>
          <p class="mt-1 text-xs text-[var(--muted)]">Last seen ${esc(timeAgo(client.latestHandshakeAt || client.last_handshake))}</p>
          <p class="mt-1 truncate text-xs text-[var(--muted)]">Endpoint: ${esc(endpoint)}</p>
          <div class="mt-2 flex flex-wrap gap-1">${(client.p2p_ports || []).map(p => `<span class="${p2pBadgeClass}">P2P: ${esc(p)}${p2pDisabled ? " (off)" : ""}</span>`).join('')}</div>
        </div>
        <div class="relative z-10 min-w-0 text-left sm:min-w-36 sm:text-right">
          <p class="flex flex-wrap gap-x-3 gap-y-1 text-sm font-semibold sm:justify-end"><span>↓ ${esc(speed(client.rxSpeedBps))}</span><span>↑ ${esc(speed(client.txSpeedBps))}</span></p>
          <p class="mt-1 text-xs text-[var(--muted)]">Total: Down ${esc(bytes(client.rx))} · Up ${esc(bytes(client.tx))}</p>
          <p class="mt-1 text-xs text-[var(--muted)]">30d: Down ${esc(bytes(client30d.rx || 0))} · Up ${esc(bytes(client30d.tx || 0))}</p>
        </div>
        <div class="relative z-10 flex w-full shrink-0 flex-wrap justify-end gap-1 sm:w-auto">
          <button data-action="toggle" title="${client.disabled ? "Enable Client" : "Disable Client"}" class="${buttonClasses("w-9 px-0")}">${icon("power")}</button>
          <button data-action="toggle-p2p" title="Toggle P2P Ports" class="${buttonClasses(shieldClass)}">${icon("shield")}</button>
          <button data-action="config" title="Config" class="${buttonClasses("w-9 px-0")}">${icon("file")}</button>
          <button data-action="vpnuri" title="vpn:// URI" class="${buttonClasses("w-9 px-0")}">${icon("link")}</button>
          <button data-action="qr" title="QR code" class="${buttonClasses("w-9 px-0")}">${icon("qr")}</button>
          <button data-action="delete" title="Delete" class="${buttonClasses("w-9 px-0 text-[var(--danger)]")}">${icon("trash")}</button>
        </div>
      </article>
    `;
  }).join("");
  host.querySelectorAll("[data-action]").forEach(btn => {
    const card = btn.closest(".client-card");
    btn.onclick = () => clientAction(card.dataset.name, btn.dataset.action);
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

function showHelp() {
  showModal("Help & Clients", `
    <div class="text-sm">
      <p class="mb-4 text-[var(--danger)] font-bold">⚠️ Standard WireGuard clients WILL NOT WORK.</p>
      <div class="overflow-x-auto rounded-lg border border-[var(--line)]">
        <table class="min-w-[720px] w-full border-collapse text-left text-xs">
          <thead class="bg-[var(--soft)] text-[var(--muted)]">
            <tr>
              <th class="px-3 py-2 font-semibold">Client</th>
              <th class="px-3 py-2 font-semibold">Platforms</th>
              <th class="px-3 py-2 font-semibold">AWG 1.x</th>
              <th class="px-3 py-2 font-semibold">AWG 2.0</th>
              <th class="px-3 py-2 font-semibold">Notes</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-[var(--line)]">
            <tr>
              <td class="px-3 py-2 font-semibold"><a class="text-[var(--accent)] underline" href="https://github.com/amnezia-vpn/amnezia-client/releases" target="_blank" rel="noopener">Amnezia VPN</a></td>
              <td class="px-3 py-2">Win/Mac/Lin/Android/iOS</td>
              <td class="px-3 py-2">✅</td>
              <td class="px-3 py-2">✅ (&gt;= 4.8.12.7)</td>
              <td class="px-3 py-2">Recommended. Supports vpn:// URI.</td>
            </tr>
            <tr>
              <td class="px-3 py-2 font-semibold">AmneziaWG</td>
              <td class="px-3 py-2">Android/Windows</td>
              <td class="px-3 py-2">✅</td>
              <td class="px-3 py-2">✅ (&gt;= 2.0.0)</td>
              <td class="px-3 py-2">Lightweight tunnel manager (.conf).</td>
            </tr>
            <tr>
              <td class="px-3 py-2 font-semibold">WG Tunnel</td>
              <td class="px-3 py-2">Android</td>
              <td class="px-3 py-2">✅</td>
              <td class="px-3 py-2">⚠️</td>
              <td class="px-3 py-2">FOSS, auto-tunneling.</td>
            </tr>
            <tr>
              <td class="px-3 py-2 font-semibold"><a class="text-[var(--accent)] underline" href="https://apps.apple.com/app/amnezia-vpn/id1600523087" target="_blank" rel="noopener">AmneziaWG</a></td>
              <td class="px-3 py-2">iOS</td>
              <td class="px-3 py-2">✅</td>
              <td class="px-3 py-2">✅</td>
              <td class="px-3 py-2">Native App Store client.</td>
            </tr>
            <tr>
              <td class="px-3 py-2 font-semibold">WireSock VPN Client</td>
              <td class="px-3 py-2">Windows</td>
              <td class="px-3 py-2">✅</td>
              <td class="px-3 py-2">✅</td>
              <td class="px-3 py-2">Commercial.</td>
            </tr>
            <tr>
              <td class="px-3 py-2 font-semibold">Standard WireGuard</td>
              <td class="px-3 py-2">All</td>
              <td class="px-3 py-2">❌</td>
              <td class="px-3 py-2">❌</td>
              <td class="px-3 py-2">Does not support AWG parameters.</td>
            </tr>
          </tbody>
        </table>
      </div>
      <blockquote class="mt-4 rounded-md border-l-4 border-[var(--danger)] bg-[var(--soft)] px-3 py-2 text-[var(--muted)]">
        Если клиент выдает ошибку про неизвестный параметр (S3, S4, I1, H1) — используйте клиент с полной поддержкой AWG 2.0.
      </blockquote>
    </div>
  `);
}

async function addClient() {
  const name = await promptModal("Add Client", "Client name");
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
      const ok = await confirmModal("Delete Client", `Delete ${name}?`);
      if (!ok) return;
      await api(`/api/clients/${encodeURIComponent(name)}`, {method: "DELETE"});
      showToast("Client deleted");
      await loadClients();
      if (statusState.role === "super") await loadTokens();
    }
  } catch {
    showToast("Action failed", "error");
  }
}

async function showConfig(name) {
  const blob = await api(`/api/clients/${encodeURIComponent(name)}/config`);
  showModal(name, `<pre class="max-h-[70vh] overflow-auto whitespace-pre-wrap break-words rounded-md bg-[var(--soft)] p-3 text-xs">${esc(await blob.text())}</pre>`);
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
    await navigator.clipboard.writeText(uri);
    showToast("vpn:// URI copied");
  };
}

async function loadTokens() {
  const panel = document.querySelector("#tokenList");
  if (!panel) return;
  const data = await api("/api/tokens");
  const rows = data.users || [];
  panel.innerHTML = rows.length ? rows.map(row => `
    <div class="flex flex-wrap items-center justify-between gap-3 rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 py-2">
      <div class="min-w-0">
        <p class="truncate font-mono text-xs">${esc(row.hash)}</p>
        <p class="mt-1 text-xs text-[var(--muted)]">${esc((row.clients || []).join(", ") || "no clients")}</p>
      </div>
      <button data-revoke="${esc(row.hash)}" class="${buttonClasses("text-[var(--danger)]")}">${icon("trash")}<span>Revoke</span></button>
    </div>
  `).join("") : `<p class="text-sm text-[var(--muted)]">No user tokens yet.</p>`;
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
    await navigator.clipboard.writeText(result.token);
    showToast("Token copied");
  };
  await loadTokens();
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
    if (closeOnButton) resolve(true);
  });
}

function promptModal(title, placeholder) {
  return new Promise(resolve => {
    const dialog = document.createElement("dialog");
    dialog.className = "w-[min(420px,calc(100vw-32px))] rounded-lg border border-[var(--line)] bg-[var(--panel)] p-0 text-[var(--text)] shadow-xl backdrop:bg-black/55";
    dialog.innerHTML = `
      <form method="dialog" class="p-4">
        <h2 class="mb-4 text-base font-semibold">${esc(title)}</h2>
        <input id="promptValue" class="h-11 w-full rounded-md border border-[var(--line)] bg-[var(--soft)] px-3 outline-none focus:border-[var(--accent)]" placeholder="${esc(placeholder)}">
        <div class="mt-4 flex justify-end gap-2">
          <button value="cancel" class="${buttonClasses()}">Cancel</button>
          <button value="ok" class="${primaryButtonClasses()}">OK</button>
        </div>
      </form>
    `;
    document.body.appendChild(dialog);
    dialog.addEventListener("close", () => {
      const value = dialog.returnValue === "ok" ? dialog.querySelector("#promptValue").value.trim() : "";
      dialog.remove();
      resolve(value);
    }, {once: true});
    dialog.showModal();
    dialog.querySelector("#promptValue").focus();
  });
}

function confirmModal(title, message) {
  return new Promise(resolve => {
    const dialog = document.createElement("dialog");
    dialog.className = "w-[min(420px,calc(100vw-32px))] rounded-lg border border-[var(--line)] bg-[var(--panel)] p-0 text-[var(--text)] shadow-xl backdrop:bg-black/55";
    dialog.innerHTML = `
      <form method="dialog" class="p-4">
        <h2 class="mb-2 text-base font-semibold">${esc(title)}</h2>
        <p class="text-sm text-[var(--muted)]">${esc(message)}</p>
        <div class="mt-4 flex justify-end gap-2">
          <button value="cancel" class="${buttonClasses()}">Cancel</button>
          <button value="ok" class="${buttonClasses("border-[var(--danger)] bg-[var(--danger)] text-white")}">Delete</button>
        </div>
      </form>
    `;
    document.body.appendChild(dialog);
    dialog.addEventListener("close", () => {
      const ok = dialog.returnValue === "ok";
      dialog.remove();
      resolve(ok);
    }, {once: true});
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
