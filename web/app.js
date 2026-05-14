const tokenInput = document.querySelector("#token");
const loginForm = document.querySelector("#loginForm");
let token = localStorage.getItem("panelToken") || "";
let loading = false;

tokenInput.value = token;

async function request(path, options = {}) {
  options.headers = Object.assign({"Authorization": "Bearer " + token}, options.headers || {});
  const response = await fetch(path, options);
  if (!response.ok) throw new Error("auth failed");
  return response;
}

async function loadPanel() {
  if (loading) return;
  loading = true;
  tokenInput.disabled = true;
  try {
    await request("/api/status");
    localStorage.setItem("panelToken", token);
    const response = await request("/api/panel.js");
    const script = document.createElement("script");
    script.textContent = await response.text();
    document.body.textContent = "";
    document.body.appendChild(script);
  } catch {
    localStorage.removeItem("panelToken");
    tokenInput.disabled = false;
    tokenInput.focus();
    if (tokenInput.value) tokenInput.select();
  } finally {
    loading = false;
  }
}

loginForm.addEventListener("submit", event => {
  event.preventDefault();
  token = tokenInput.value.trim();
  loadPanel();
});

if (token) loadPanel();
