const root = document.createElement("main");
root.id = "app";
const panelCss = document.createElement("link");
panelCss.rel = "stylesheet";
panelCss.href = "/api/panel.css";
document.head.appendChild(panelCss);
document.body.appendChild(root);
root.innerHTML = '<dialog id="modal"><form method="dialog"><h2 id="modalTitle"></h2><div id="modalBody"></div><menu><button>Close</button></menu></form></dialog>';

const $ = s => document.querySelector(s);
const app = $("#app");
let state = null;

token = localStorage.getItem("panelToken") || token;

const theme = localStorage.getItem("panelTheme") || "dark";
document.documentElement.dataset.theme = theme;

function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, ch => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[ch]));
}

async function api(path, opt = {}) {
  opt.headers = Object.assign({"Authorization": "Bearer " + token}, opt.headers || {});
  if (opt.body) opt.headers["Content-Type"] = "application/json";
  const response = await fetch(path, opt);
  if (!response.ok) throw new Error(await response.text());
  const ctype = response.headers.get("content-type") || "";
  return ctype.includes("application/json") ? response.json() : response.blob();
}

function bytes(n) {
  n = Number(n || 0);
  for (const unit of ["B", "KiB", "MiB", "GiB", "TiB"]) {
    if (n < 1024) return n.toFixed(unit === "B" ? 0 : 1) + " " + unit;
    n /= 1024;
  }
  return n.toFixed(1) + " PiB";
}

function p2pPorts(value) {
  if (Array.isArray(value)) return value;
  return String(value || "").split(",").map(v => v.trim()).filter(Boolean);
}

function show(title, body) {
  $("#modalTitle").textContent = title;
  $("#modalBody").innerHTML = body;
  $("#modal").showModal();
}

function setTheme(next) {
  document.documentElement.dataset.theme = next;
  localStorage.setItem("panelTheme", next);
}

function logout() {
  localStorage.removeItem("panelToken");
  location.reload();
}

function renderShell() {
  app.innerHTML = `
    <dialog id="modal"><form method="dialog"><h2 id="modalTitle"></h2><div id="modalBody"></div><menu><button>Close</button></menu></form></dialog>
    <header class="topbar">
      <div>
        <h1>${esc(state.server_name || "MyVPN")}</h1>
        <span class="subline">v${esc(state.version)} · ${esc(state.role)}</span>
      </div>
      <div class="actions">
        <input id="sessionToken" type="password" autocomplete="current-password" value="${esc(token)}" title="Web token">
        <button id="logout">Logout</button>
        <button id="themeToggle">${document.documentElement.dataset.theme === "dark" ? "Light" : "Dark"}</button>
        <button id="addClient">Add</button>
        <button id="refresh">Refresh</button>
        <button id="restartServer">Restart</button>
      </div>
    </header>
    <section class="metrics">
      <div><span>Service</span><strong id="service">?</strong></div>
      <div><span>Clients</span><strong id="count">0</strong></div>
      <div><span>DNS</span><strong id="dnsMode">?</strong></div>
      <div><span>AdGuard</span><strong id="adguardState">?</strong></div>
    </section>
    <section class="server-panel">
      <form id="nameForm">
        <input id="serverName" value="${esc(state.server_name || "MyVPN")}" maxlength="128">
        <button>Save</button>
      </form>
      <div class="dns-actions">
        <button data-dns-mode="adguard">AdGuard</button>
        <button data-dns-mode="system">System</button>
        <button id="restartDns">Restart DNS</button>
      </div>
    </section>
    <section class="dns-panel">
      <div>
        <span id="dnsServers">?</span>
        <small id="dnsUi">?</small>
      </div>
    </section>
    <section class="table-wrap">
      <table>
        <thead><tr><th>Name</th><th>IPv4</th><th>IPv6</th><th>P2P</th><th>RX/TX</th><th>Status</th><th></th></tr></thead>
        <tbody id="clients"></tbody>
      </table>
    </section>
    <section id="tokensPanel" class="tokens-panel" ${state.role === "super" ? "" : "hidden"}></section>
  `;
  window.scrollTo({top: 0, left: 0});
  $("#sessionToken").onchange = async event => {
    token = event.target.value.trim();
    localStorage.setItem("panelToken", token);
    await boot();
  };
  $("#logout").onclick = logout;
  $("#themeToggle").onclick = () => { setTheme(document.documentElement.dataset.theme === "dark" ? "light" : "dark"); renderShell(); load(); };
  $("#refresh").onclick = () => load();
  $("#restartServer").onclick = async () => { await api("/api/server/restart", {method: "POST", body: "{}"}); await load(); };
  $("#restartDns").onclick = async () => { await api("/api/dns/restart", {method: "POST", body: "{}"}); await load(); };
  $("#addClient").onclick = addClient;
  $("#nameForm").onsubmit = saveServerName;
  document.querySelectorAll("[data-dns-mode]").forEach(btn => btn.onclick = async () => {
    await api("/api/dns/mode", {method: "POST", body: JSON.stringify({mode: btn.dataset.dnsMode})});
    await load();
  });
}

async function addClient() {
  const name = prompt("Client name");
  if (!name) return;
  await api("/api/clients", {method: "POST", body: JSON.stringify({name})});
  await load();
}

async function saveServerName(event) {
  event.preventDefault();
  const name = $("#serverName").value.trim();
  await api("/api/server/name", {method: "POST", body: JSON.stringify({name})});
  state.server_name = name;
  renderShell();
  await load();
}

async function loadTokens() {
  if (!state || state.role !== "super") return;
  const data = await api("/api/tokens");
  const panel = $("#tokensPanel");
  panel.innerHTML = `
    <div class="panel-head">
      <h2>Tokens</h2>
      <div class="actions">
        <button id="addToken">Add</button>
        <button class="danger" id="resetTokens">Reset All</button>
      </div>
    </div>
    <div class="token-list">
      ${(data.normal || []).map(name => `<div><span>${esc(name)}</span><button class="danger" data-revoke="${esc(name)}">Revoke</button></div>`).join("") || "<p>No normal tokens</p>"}
    </div>
  `;
  $("#addToken").onclick = async () => {
    const name = prompt("Token name");
    if (!name) return;
    const result = await api("/api/tokens", {method: "POST", body: JSON.stringify({name})});
    show("New token", `<pre>${esc(result.token)}</pre>`);
    await loadTokens();
  };
  $("#resetTokens").onclick = async () => {
    if (!confirm("Reset all tokens?")) return;
    const result = await api("/api/tokens/reset-all", {method: "POST", body: "{}"});
    token = result.super_token;
    localStorage.setItem("panelToken", token);
    show("Super token", `<pre>${esc(result.super_token)}</pre>`);
    await boot();
  };
  document.querySelectorAll("[data-revoke]").forEach(btn => btn.onclick = async () => {
    await api(`/api/tokens/${encodeURIComponent(btn.dataset.revoke)}`, {method: "DELETE"});
    await loadTokens();
  });
}

async function load() {
  const [dns, rows] = await Promise.all([api("/api/dns"), api("/api/clients")]);
  $("#service").textContent = state.service || "?";
  $("#count").textContent = rows.length;
  $("#dnsMode").textContent = dns.mode || "?";
  $("#adguardState").textContent = dns.adguard_service || "?";
  $("#dnsServers").textContent = `Clients use DNS: ${dns.client_dns || "?"}`;
  $("#dnsUi").textContent = `AdGuard UI: http://10.9.9.1:${dns.adguard_port || 3000}/`;
  $("#clients").innerHTML = rows.map(c => `
    <tr>
      <td>${esc(c.name)}</td>
      <td>${esc(c.ipv4 || c.ip || "-")}</td>
      <td>${esc(c.ipv6 || "-")}</td>
      <td>${p2pPorts(c.p2p_ports || c.p2p).map(p => `<span class="pill">${esc(p)}</span>`).join("") || "-"}</td>
      <td>${bytes(c.rx)} / ${bytes(c.tx)}</td>
      <td>${esc(c.status || "-")}</td>
      <td class="row-actions">
        <button data-config="${esc(c.name)}">Conf</button>
        <button data-qr="${esc(c.name)}">QR</button>
        <button data-link="${esc(c.name)}">Link</button>
        <button class="danger" data-delete="${esc(c.name)}">Delete</button>
      </td>
    </tr>`).join("");
  document.querySelectorAll("[data-config]").forEach(btn => btn.onclick = () => cfg(btn.dataset.config));
  document.querySelectorAll("[data-qr]").forEach(btn => btn.onclick = () => qr(btn.dataset.qr));
  document.querySelectorAll("[data-link]").forEach(btn => btn.onclick = () => vpnLink(btn.dataset.link));
  document.querySelectorAll("[data-delete]").forEach(btn => btn.onclick = () => delClient(btn.dataset.delete));
  await loadTokens();
}

async function cfg(name) {
  const blob = await api(`/api/clients/${encodeURIComponent(name)}/config`);
  show(name, `<pre>${esc(await blob.text())}</pre>`);
}

async function qr(name) {
  const blob = await api(`/api/clients/${encodeURIComponent(name)}/qr`);
  const url = URL.createObjectURL(blob);
  show(name, `<img alt="QR" src="${url}">`);
}

async function vpnLink(name) {
  const blob = await api(`/api/clients/${encodeURIComponent(name)}/vpnuri`);
  const link = (await blob.text()).trim();
  try {
    await navigator.clipboard.writeText(link);
  } catch {
    // Clipboard may be blocked by browser policy; the text remains visible.
  }
  show(`${name} vpn://`, `<div class="link-box"><pre>${esc(link)}</pre><button id="copyVpnLink">Copy</button></div>`);
  $("#copyVpnLink").onclick = async () => {
    await navigator.clipboard.writeText(link);
    $("#copyVpnLink").textContent = "Copied";
  };
}

async function delClient(name) {
  if (!confirm(`Delete ${name}?`)) return;
  await api(`/api/clients/${encodeURIComponent(name)}`, {method: "DELETE"});
  await load();
}

async function boot() {
  try {
    state = await api("/api/status");
    renderShell();
    await load();
  } catch {
    logout();
  }
}

boot();
