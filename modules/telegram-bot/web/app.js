(() => {
  const tg = window.Telegram?.WebApp;
  tg?.ready(); tg?.expand(); tg?.enableClosingConfirmation?.();
  tg?.BackButton?.show();
  tg?.BackButton?.onClick?.(() => window.history.length > 1 ? window.history.back() : tg.close());
  tg?.onEvent?.('themeChanged', () => document.documentElement.dataset.theme = tg.colorScheme || 'light');
  tg?.HapticFeedback?.impactOccurred?.('light');
  const app = document.querySelector('#app');
  const esc = value => String(value ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  async function load() {
    const initData = tg?.initData || '';
    const response = await fetch('/api/session', {headers:{'X-Telegram-Init-Data':initData}});
    const data = await response.json(); if (!response.ok) throw new Error(data.error || 'Ошибка авторизации');
    app.innerHTML = `<header><h2>GaulleBot</h2><span class="badge">${esc(data.role)}</span></header><div class="grid">${Object.values(data.panels).map(panel => `<div class="card"><div class="label">${esc(panel.display_name || panel.panel)}</div><div class="value">${esc(panel.summary?.online || 0)}/${esc(panel.summary?.total || 0)}</div><div class="label">онлайн · ${esc(panel.version || '')}</div></div>`).join('')}</div><button id="refresh">Обновить данные</button>${Object.values(data.panels).map(panel => `<section class="server"><h3>${esc(panel.display_name || panel.panel)}</h3>${(panel.clients || []).slice(0,50).map(client => `<div class="client"><span>${client.online ? '🟢' : '⚪'} ${esc(client.display_name || client.name)}</span><code>${esc(client.ipv4)}</code></div>`).join('')}</section>`).join('')}`;
    document.querySelector('#refresh').onclick = () => load().catch(showError);
    tg?.MainButton?.setText('Обновить'); tg?.MainButton?.show(); tg?.MainButton?.offClick?.(load); tg?.MainButton?.onClick?.(() => load().catch(showError));
  }
  function showError(error){app.innerHTML=`<div class="error">${esc(error.message)}<br><br><button onclick="location.reload()">Повторить</button></div>`;}
  load().catch(showError);
})();
