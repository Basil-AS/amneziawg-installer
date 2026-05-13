const $ = s => document.querySelector(s);
let token = localStorage.getItem("awgToken") || "";
$("#token").value = token;
$("#saveToken").onclick = () => { token = $("#token").value.trim(); localStorage.setItem("awgToken", token); load(); };
$("#refresh").onclick = () => load();
$("#addClient").onclick = async () => {
  const name = prompt("Имя клиента");
  if (!name) return;
  await api("/api/clients", {method:"POST", body:JSON.stringify({name})});
  load();
};
async function api(path, opt={}) {
  opt.headers = Object.assign({"Authorization":"Bearer "+token}, opt.headers||{});
  if (opt.body) opt.headers["Content-Type"] = "application/json";
  const r = await fetch(path, opt);
  if (!r.ok) throw new Error(await r.text());
  const ct = r.headers.get("content-type") || "";
  return ct.includes("application/json") ? r.json() : r.blob();
}
function bytes(n){n=Number(n||0);for(const u of ["B","KiB","MiB","GiB"]){if(n<1024)return n.toFixed(u==="B"?0:1)+" "+u;n/=1024}}
function show(title, body){$("#modalTitle").textContent=title;$("#modalBody").innerHTML=body;$("#modal").showModal()}
async function load(){
  try{
    const st = await api("/api/status"); $("#service").textContent=st.service||"?"; $("#count").textContent=st.clients;
    const rows = await api("/api/clients"); $("#clients").innerHTML = rows.map(c => `
      <tr><td>${c.name}</td><td>${c.ipv4||"-"}</td><td>${c.ipv6||"-"}</td>
      <td>${(c.p2p_ports||[]).map(p=>`<span class="pill">${p}</span>`).join("")||"-"}</td>
      <td>${bytes(c.rx)} / ${bytes(c.tx)}</td><td>${c.status||"-"}</td>
      <td><button onclick="cfg('${c.name}')">Conf</button> <button onclick="qr('${c.name}')">QR</button> <button class="danger" onclick="delc('${c.name}')">Удалить</button></td></tr>`).join("");
  }catch(e){show("Ошибка", `<pre>${e.message}</pre>`)}
}
async function cfg(n){const b=await api(`/api/clients/${n}/config`); show(n, `<pre>${await b.text()}</pre>`)}
async function qr(n){const b=await api(`/api/clients/${n}/qr`); const u=URL.createObjectURL(b); show(n, `<img alt="QR" style="max-width:100%" src="${u}">`)}
async function delc(n){if(confirm(`Удалить ${n}?`)){await api(`/api/clients/${n}`,{method:"DELETE"});load()}}
load();
