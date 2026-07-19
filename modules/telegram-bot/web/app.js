(() => {
  const tg = window.Telegram?.WebApp;
  const app = document.querySelector('#app');
  const esc = value => String(value ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  const bytes = value => {
    let n = Number(value || 0), unit = 'B';
    for (const next of ['KiB','MiB','GiB','TiB']) { if (Math.abs(n) < 1024) break; n /= 1024; unit = next; }
    return `${n < 10 && unit !== 'B' ? n.toFixed(1) : Math.round(n)} ${unit}`;
  };
  const initHeaders = () => ({'X-Telegram-Init-Data': tg?.initData || ''});
  const api = async (path, options = {}) => {
    const headers = {...initHeaders(), ...(options.headers || {})};
    if (options.body && !headers['Content-Type']) headers['Content-Type'] = 'application/json';
    const response = await fetch(path, {...options, headers, cache:'no-store'});
    const type = response.headers.get('content-type') || '';
    const data = type.includes('application/json') ? await response.json() : await response.text();
    if (!response.ok) throw new Error(data?.error || 'Операция не выполнена');
    return data;
  };
  tg?.ready(); tg?.expand(); tg?.enableClosingConfirmation?.();
  tg?.BackButton?.show();
  tg?.BackButton?.onClick?.(() => tg.close());
  tg?.onEvent?.('themeChanged', () => document.documentElement.dataset.theme = tg.colorScheme || 'light');

  async function load() {
    app.innerHTML = '<div class="loading"><span class="spinner"></span><p>Загрузка защищённой панели…</p></div>';
    try { render(await api('/api/session')); }
    catch (error) { app.innerHTML = `<div class="error"><div class="error-icon">!</div><h3>Панель недоступна</h3><p>${esc(error.message)}</p><button data-retry>Повторить</button></div>`; }
  }

  function statusBadge(value) { const v = String(value || '').toLowerCase(); const ok = ['ok','active','healthy','ready','up'].includes(v); return `<span class="status ${ok ? 'ok' : 'warn'}"><i></i>${esc(value || 'unknown')}</span>`; }
  function traffic(client) {
    const total = client.traffic_total || client.traffic || {};
    return `<span class="traffic">↓ ${esc(bytes(total.rx || total.download))} · ↑ ${esc(bytes(total.tx || total.upload))}</span>`;
  }
  function panelCard(key, panel, isAdmin) {
    const clients = Array.isArray(panel.clients) ? panel.clients : [];
    const online = Number(panel.summary?.online || clients.filter(x => x.online).length || 0);
    const total = Number(panel.summary?.total || clients.length || 0);
    return `<section class="panel-card" data-panel="${esc(key)}">
      <div class="panel-head"><div><span class="eyebrow">VPN SERVER</span><h2>${esc(panel.display_name || panel.panel || key)}</h2></div><div class="server-dot ${panel.service === 'active' ? 'active' : ''}"></div></div>
      <div class="metrics"><div><strong>${online}<small>/${total}</small></strong><span>онлайн</span></div><div><strong>${esc(panel.version || '—')}</strong><span>версия</span></div><div><strong>${statusBadge(panel.service || 'unknown')}</strong><span>сервис</span></div></div>
      ${isAdmin ? `<div class="admin-tools"><button data-panel-action="health" data-server="${esc(key)}">🩺 Проверка</button><button data-panel-action="health-history" data-server="${esc(key)}">📉 Нагрузка</button><button data-panel-action="latency" data-server="${esc(key)}">📶 Latency</button><button data-panel-action="web-policy-test" data-server="${esc(key)}">🛡 Policy</button><button data-panel-action="update-check" data-server="${esc(key)}">🔄 Обновления</button><button data-panel-action="restart" data-server="${esc(key)}">♻️ Перезапуск</button></div>` : ''}
      <div class="section-title"><span>Устройства</span><span class="count">${clients.length}</span></div>
      <div class="clients">${clients.length ? clients.slice(0, 60).map(client => clientRow(key, client, isAdmin)).join('') : '<div class="empty">Нет доступных устройств</div>'}</div>
    </section>`;
  }
  function clientRow(server, client, isAdmin) {
    const name = client.display_name || client.name || client.id || 'client';
    const encoded = encodeURIComponent(client.name || client.id || name);
    return `<article class="client-row"><div class="client-main"><span class="presence ${client.online ? 'online' : ''}"></span><div><strong>${esc(name)}</strong><small>${esc(client.ipv4 || 'IP не назначен')} · ${client.online ? 'активен' : 'не в сети'}</small></div></div><div class="client-side">${traffic(client)}<div class="actions"><button data-artifact="qr" data-server="${esc(server)}" data-name="${esc(encoded)}" title="QR">QR</button><button data-artifact="config" data-server="${esc(server)}" data-name="${esc(encoded)}" title="Конфиг">CFG</button><button data-artifact="uri" data-server="${esc(server)}" data-name="${esc(encoded)}" title="VPN URI">URI</button><button data-client-action="access-link" data-server="${esc(server)}" data-name="${esc(client.name || client.id || name)}" title="Одноразовая ссылка">🔗</button><button data-regenerate data-server="${esc(server)}" data-name="${esc(client.name || client.id || name)}" title="Перегенерировать">↻</button><button data-client-action="client-toggle" data-server="${esc(server)}" data-name="${esc(client.name || client.id || name)}" title="VPN">⏻</button><button data-client-action="p2p-toggle" data-server="${esc(server)}" data-name="${esc(client.name || client.id || name)}" title="P2P">P2P</button><button data-client-action="p2p-add" data-server="${esc(server)}" data-name="${esc(client.name || client.id || name)}" title="Порт P2P">🔧</button>${isAdmin ? `<button data-client-action="path-check" data-server="${esc(server)}" data-name="${esc(client.name || client.id || name)}" title="Проверить маршрут">🧭</button>` : ''}<button data-client-action="remove" data-server="${esc(server)}" data-name="${esc(client.name || client.id || name)}" title="Удалить">×</button></div></div></article>`;
  }
  function render(data) {
    if (data.access_pending) {
      app.innerHTML = `<header class="topbar"><div class="brand"><div class="brand-mark">G</div><div><h1>GaulleBot</h1><span>VPN control center</span></div></div><span class="role">PENDING</span></header><section class="pending-card"><div class="pending-icon">🔐</div><h2>Доступ ещё не выдан</h2><p>Отправьте заявку администратору. После одобрения здесь появятся серверы и устройства.</p><button data-access-request>Запросить доступ</button></section>`;
      return;
    }
    const panels = Object.entries(data.panels || {});
    const isAdmin = data.role === 'super';
    app.innerHTML = `<header class="topbar"><div class="brand"><div class="brand-mark">G</div><div><h1>GaulleBot</h1><span>VPN control center</span></div></div><span class="role">${esc(isAdmin ? 'ADMIN' : 'USER')}</span></header>
      <div class="hero"><span class="eyebrow">SECURE SESSION</span><h2>Ваши серверы</h2><p>Управление через защищённый API-поток Telegram.</p></div>
      <div class="summary-strip"><span><b>${panels.length}</b> сервера</span><span><b>${panels.reduce((n, [,p]) => n + (p.clients?.length || 0), 0)}</b> устройства</span><button data-refresh>Обновить</button></div>
      <div class="panels">${panels.map(([key,panel]) => panelCard(key,panel,isAdmin)).join('') || '<div class="empty">Серверы недоступны</div>'}</div>`;
  }
  async function artifact(button) {
    const server = button.dataset.server, name = decodeURIComponent(button.dataset.name), kind = button.dataset.artifact;
    button.disabled = true;
    try {
      const response = await fetch(`/api/artifact?server=${encodeURIComponent(server)}&name=${encodeURIComponent(name)}&kind=${kind}`, {headers:initHeaders(), cache:'no-store'});
      if (!response.ok) throw new Error('Файл недоступен');
      const blob = await response.blob(), url = URL.createObjectURL(blob);
      if (kind === 'qr') {
        const dialog = document.createElement('dialog'); dialog.className = 'qr-dialog';
        dialog.innerHTML = `<button class="dialog-close">×</button><img src="${url}" alt="QR-код"><strong>${esc(name)}</strong>`;
        document.body.append(dialog); dialog.showModal(); dialog.querySelector('.dialog-close').onclick = () => { dialog.close(); dialog.remove(); URL.revokeObjectURL(url); };
      } else { const link = document.createElement('a'); link.href = url; link.download = `${name}.${kind === 'config' ? 'conf' : 'vpnuri'}`; link.click(); setTimeout(() => URL.revokeObjectURL(url), 5000); }
      tg?.HapticFeedback?.notificationOccurred?.('success');
    } catch (error) { toast(error.message); } finally { button.disabled = false; }
  }
  async function regenerate(button) {
    const name = button.dataset.name, server = button.dataset.server;
    if (!confirm(`Перегенерировать конфиг «${name}»? Старый профиль перестанет работать.`)) return;
    button.disabled = true;
    try { await api('/api/action', {method:'POST', body:JSON.stringify({server, action:'regenerate', name})}); toast('Конфиг обновлён'); await load(); }
    catch (error) { toast(error.message); } finally { button.disabled = false; }
  }
  async function clientAction(button) {
    const action = button.dataset.clientAction, name = button.dataset.name, server = button.dataset.server;
    if (action === 'remove' && !confirm(`Удалить устройство «${name}»?`)) return;
    let port = null;
    if (action === 'p2p-add') { port = Number(window.prompt('Порт P2P (1–65535):', '20045')); if (!Number.isInteger(port) || port < 1 || port > 65535) { toast('Введите порт от 1 до 65535'); return; } }
    button.disabled = true;
    try { const result = await api('/api/action', {method:'POST', body:JSON.stringify({server, action, name, ...(port === null ? {} : {port})})}); if (action === 'access-link' && result.url) { tg?.openLink?.(result.url); toast('Одноразовая ссылка открыта'); } else if (action === 'path-check') { const dialog = document.createElement('dialog'); dialog.className = 'result-dialog'; dialog.innerHTML = `<button class="dialog-close">×</button><div>${diagnosticHtml(action,result)}</div>`; document.body.append(dialog); dialog.showModal(); dialog.querySelector('.dialog-close').onclick = () => { dialog.close(); dialog.remove(); }; } else { toast(action === 'remove' ? 'Устройство удалено' : 'Настройка обновлена'); await load(); } }
    catch (error) { toast(error.message); } finally { button.disabled = false; }
  }
  function diagnosticHtml(action, payload) {
    const panel = esc(payload.panel || payload.display_name || 'Сервер');
    if (action === 'health') return `<h3>🩺 ${panel}</h3><p class="result-state">${esc(payload.status || 'unknown')}</p><div class="result-grid"><span>CPU <b>${esc(payload.cpu?.usage_percent ?? '—')}%</b></span><span>RAM <b>${esc(payload.memory?.used_percent ?? '—')}%</b></span><span>Диск <b>${esc(payload.disk?.used_percent ?? '—')}%</b></span><span>Load <b>${esc(payload.load?.one ?? '—')}</b></span></div>`;
    if (action === 'latency') { const overview = payload.overview || payload.diagnostics || {}; return `<h3>📶 ${panel}</h3><p>Активных: <b>${esc(overview.active ?? overview.active_peers ?? '—')}</b> · reachable: <b>${esc(overview.reachable ?? overview.reachable_clients ?? '—')}</b></p><p>Средний RTT: <b>${esc(overview.avg_rtt_ms ?? '—')} ms</b> · P95: <b>${esc(overview.p95_rtt_ms ?? '—')} ms</b></p>`; }
    if (action === 'health-history') { const summary = payload.summary || {}; return `<h3>📉 ${panel}</h3><p>Период: <b>${esc(payload.range || '1h')}</b> · samples: <b>${esc(summary.counts?.samples ?? 0)}</b></p><p>CPU: <b>${esc(summary.cpu?.avg ?? '—')}%</b> avg / <b>${esc(summary.cpu?.max ?? '—')}%</b> max</p><p>RAM: <b>${esc(summary.memory?.avg_used_percent ?? '—')}%</b> avg / <b>${esc(summary.memory?.max_used_percent ?? '—')}%</b> max</p>`; }
    if (action === 'update-check' || action === 'update') return `<h3>🔄 ${panel}</h3><p>Текущая версия: <b>${esc(payload.current_version || payload.version || '—')}</b></p><p>Доступная версия: <b>${esc(payload.latest_version || payload.latest || '—')}</b></p>`;
    if (action === 'path-check') { const status = payload.status || payload.result || (payload.ok ? 'ok' : 'unknown'); return `<h3>🧭 ${panel}</h3><p class="result-state">${esc(status)}</p><p>${esc(payload.detail || payload.message || payload.target || 'Проверка маршрута выполнена')}</p><p>RTT: <b>${esc(payload.rtt_ms ?? payload.latency_ms ?? '—')} ms</b></p>`; }
    if (action === 'web-policy-test') return `<h3>🛡 ${panel}</h3><p class="result-state">${esc(payload.ok ? 'допустимо' : 'отклонено')}</p><p>Режим: <b>${esc(payload.mode || '—')}</b></p><p>Listener: <b>${esc(payload.bind_host || payload.public_listener || '—')}</b></p><p>${esc(payload.message || (payload.requires_restart ? 'Требуется перезапуск' : 'Текущий запрос проходит проверку'))}</p>`;
    return `<h3>${esc(action)} · ${panel}</h3><p>${esc(payload.message || payload.status || (payload.ok ? 'Готово' : 'Ответ получен'))}</p>`;
  }
  async function panelAction(button) {
    const action = button.dataset.panelAction, server = button.dataset.server;
    if (action === 'restart' && !confirm(`Перезапустить ${server}? VPN-сессии временно прервутся.`)) return;
    button.disabled = true;
    try { const payload = await api('/api/action', {method:'POST', body:JSON.stringify({server, action})}); const dialog = document.createElement('dialog'); dialog.className = 'result-dialog'; dialog.innerHTML = `<button class="dialog-close">×</button><div>${diagnosticHtml(action,payload)}</div>`; document.body.append(dialog); dialog.showModal(); dialog.querySelector('.dialog-close').onclick = () => { dialog.close(); dialog.remove(); }; if (['restart','update-check','update-apply'].includes(action)) await load(); } catch (error) { toast(error.message); } finally { button.disabled = false; }
  }
  async function requestAccess(button) {
    button.disabled = true;
    try { const result = await api('/api/access-request', {method:'POST', body:'{}'}); toast(result.status === 'approved' ? 'Доступ уже выдан' : (result.created ? 'Заявка отправлена' : 'Заявка уже ожидает решения')); button.textContent = 'Заявка отправлена'; } catch (error) { toast(error.message); } finally { button.disabled = false; }
  }
  function toast(message) { const node = document.createElement('div'); node.className = 'toast'; node.textContent = message; document.body.append(node); setTimeout(() => node.remove(), 2600); }
  app.addEventListener('click', event => {
    const artifactButton = event.target.closest('[data-artifact]'); if (artifactButton) return artifact(artifactButton);
    const regenerateButton = event.target.closest('[data-regenerate]'); if (regenerateButton) return regenerate(regenerateButton);
    const clientActionButton = event.target.closest('[data-client-action]'); if (clientActionButton) return clientAction(clientActionButton);
    const panelActionButton = event.target.closest('[data-panel-action]'); if (panelActionButton) return panelAction(panelActionButton);
    const accessButton = event.target.closest('[data-access-request]'); if (accessButton) return requestAccess(accessButton);
    if (event.target.closest('[data-refresh]')) return load();
    if (event.target.closest('[data-retry]')) return load();
  });
  tg?.MainButton?.setText('Обновить'); tg?.MainButton?.show(); tg?.MainButton?.onClick?.(() => load());
  load();
})();
