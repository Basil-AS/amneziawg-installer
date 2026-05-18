@RTK.md

# Архитектурные правила проекта

Этот репозиторий — форк `bivlked/amneziawg-installer` с критичной fork-delta-логикой. При любых изменениях сохранять:

- web-panel на Python stdlib;
- HTTPS web-panel;
- bearer token / `tokens.json` / RBAC access tokens;
- IPv6 `routed|ndp|nat66|legacy` и aliases `native -> ndp`, `ula -> nat66`;
- P2P ports / DNAT / generated hooks `postup.sh`, `postdown.sh`, `p2p_rules.sh`;
- metadata comments для клиентов;
- `vpn://` URI;
- QR/config/web integration;
- AdGuard Home DNS integration;
- safe voice/calls UDP optimization;
- UDP conntrack tuning;
- `voice-check` / `udp-check` diagnostics.

Не удалять и не упрощать fork-delta без явной причины.

## Короткие локальные домены внутри VPN

Это архитектурный контракт для будущей реализации. Не описывать `awg.lan` / `dns.lan` в README как готовую функцию, пока не добавлены runtime-код, тесты и проверка на установленной системе.

Планируемая фича:

```text
http://awg.lan  -> web-panel AmneziaWG fork
http://dns.lan  -> AdGuard Home UI
```

Позже опционально:

```text
https://awg.lan
https://dns.lan
```

Цель UX: после подключения к VPN пользователь открывает локальные сервисы по коротким доменам без IP и без портов.

### Ключевой принцип

DNS не умеет указывать порт. Одного DNS rewrite недостаточно, чтобы убрать `:8443` или `:3000`.

Нужны две части:

1. DNS rewrites в AdGuard Home:

   ```yaml
   rewrites:
     - domain: awg.lan
       answer: 10.9.9.1
     - domain: dns.lan
       answer: 10.9.9.1
   ```

2. Reverse proxy на VPN gateway IP:

   ```text
   10.9.9.1:80
     Host: awg.lan -> backend web-panel:
       https://10.9.9.1:8443 по умолчанию
       или https://127.0.0.1:8443 только если web-panel явно привязана к localhost
     Host: dns.lan -> backend AdGuard Home, например http://127.0.0.1:3000
   ```

Reverse proxy должен слушать только VPN gateway IP, не `0.0.0.0`.

### DNS rewrites

Основной источник истины — `AdGuardHome.yaml` через ключ `rewrites` или официальный API AdGuard Home.

Managed entries проекта должны быть только:

- `awg.lan`;
- `dns.lan`.

YAML-пример:

```yaml
rewrites:
  - domain: awg.lan
    answer: 10.9.9.1
  - domain: dns.lan
    answer: 10.9.9.1
```

Не использовать `/etc/hosts` как основной механизм:

- `/etc/hosts` — локальный override только для самой машины;
- VPN-клиентам нужен ответ DNS-сервера;
- AdGuard Home поддерживает DNS Rewrites через config/API;
- hosts-style правила возможны в фильтрах, но для управляемых локальных сервисов чище использовать `rewrites`.

Требования к будущей реализации:

- определять VPN gateway IPv4 из существующих переменных проекта, если они уже есть (`AWG_SERVER_IPV4`, `AWG_IPV4_GATEWAY` или аналог);
- если подходящей переменной нет — использовать `10.9.9.1` как default;
- если в `AdGuardHome.yaml` уже есть `rewrites`, нельзя перетирать весь список;
- применять rewrites через аккуратный read-modify-write:
  - прочитать существующий YAML;
  - сохранить пользовательские rewrites;
  - удалить/заменить только managed entries `awg.lan` и `dns.lan`;
  - добавить актуальные managed entries;
  - записать YAML атомарно через tmp + `mv` / `os.replace`;
  - сохранить права файла, если возможно;
- после изменения `AdGuardHome.yaml` перезапускать `AdGuardHome.service`;
- повторный apply не должен создавать дубликаты;
- managed entries должны обновляться, если меняется VPN gateway IP;
- если AdGuard Home выключен или config не найден, aliases должны быть `disabled` или `pending`, а будущая команда должна показать понятное состояние, а не падать молча;
- домены работают только у клиентов, которые используют VPN DNS / AdGuard;
- не использовать `.local`, чтобы не конфликтовать с mDNS.
- если проект позже поддержит IPv6 gateway, можно добавить AAAA rewrites как optional, но IPv4 rewrites обязательны.

### Reverse proxy

Reverse proxy нужен, чтобы локальные домены работали без портов.

Допустимые варианты:

- `nginx` / `caddy`, если дополнительные зависимости действительно оправданы;
- либо лёгкий Python stdlib proxy, например `/root/awg/lan_proxy.py`, если проект хочет сохранить минимальный footprint.

Требования:

- bind только на VPN gateway IP:

  ```text
  10.9.9.1:80
  ```

- routing по `Host` header:

  ```text
  awg.lan -> https://127.0.0.1:8443
  dns.lan -> http://127.0.0.1:3000
  ```

  Для `awg.lan` backend должен соответствовать реальному bind web-panel:

  ```text
  https://10.9.9.1:8443 по умолчанию
  или https://127.0.0.1:8443 только если web-panel явно привязана к localhost
  ```

- unknown `Host` -> `404`;
- не слушать публичный интерфейс;
- systemd unit должен стартовать после:
  - `awg-quick@awg0.service`;
  - `awg-web.service`;
  - `AdGuardHome.service`, если AdGuard включён;
- `Restart=on-failure`.

### Будущие config variables

В будущей реализации использовать:

```bash
AWG_LAN_DOMAINS_ENABLED=1
AWG_LAN_DOMAIN_PANEL="awg.lan"
AWG_LAN_DOMAIN_DNS="dns.lan"
AWG_LAN_DOMAIN_IP="<VPN_GATEWAY_IP>"
AWG_LAN_PROXY_ENABLED=1
AWG_LAN_PROXY_BIND="<VPN_GATEWAY_IP>"
AWG_LAN_PROXY_HTTP_PORT=80
```

Опционально позже для HTTPS:

```bash
AWG_LAN_PROXY_HTTPS_ENABLED=0
AWG_LAN_PROXY_HTTPS_PORT=443
```

### HTTPS scope

Первый проход делать по HTTP внутри VPN:

```text
http://awg.lan
http://dns.lan
```

Причины:

- трафик уже идёт внутри VPN-туннеля;
- нет проблем с self-signed сертификатами;
- не нужно устанавливать локальный CA на клиентов.

Если позже добавлять HTTPS, fresh-install cert должен содержать SAN:

```text
DNS:awg.lan
DNS:dns.lan
IP:<VPN_GATEWAY_IP>
IP:127.0.0.1
```

### Будущая документация

При реализации фичи README должен объяснять:

```text
Короткие домены внутри VPN:
  http://awg.lan — web-panel
  http://dns.lan — AdGuard Home
```

И условия:

- работает только после подключения к VPN;
- клиент должен использовать DNS сервера VPN / AdGuard;
- это локальные DNS rewrites, не публичные домены;
- `.local` не используется из-за mDNS.

## Инженерные ограничения для будущей реализации

- Не ломать web-panel / RBAC / tokens.
- Не менять публичный API web-panel без backward compatibility.
- Не смешивать DNS rewrite и reverse proxy в один «магический» слой: это две разные обязанности.
- Не открывать proxy наружу по умолчанию.
- Не делать `/etc/hosts` источником истины для клиентских имён.
- Не трогать IPv6/P2P/AdGuard/vpn:///voice-UDP поведение без необходимости.
- Изменения runtime-логики зеркалить между RU/EN ветками.

## Acceptance criteria для будущей реализации

- VPN client resolves `awg.lan` and `dns.lan` to VPN gateway IP through AdGuard Home.
- `http://awg.lan` opens web-panel without port.
- `http://dns.lan` opens AdGuard Home UI without port.
- Reverse proxy listens only on VPN gateway IP, never `0.0.0.0` by default.
- Public `SERVER_IP:80/443` does not expose web-panel or AdGuard by default.
- Existing direct access remains available:
  - `https://10.9.9.1:8443` for web-panel.
  - `http://10.9.9.1:3000` for AdGuard Home UI, if AdGuard UI is bound there.
- DNS rewrites are idempotent:
  - no duplicates;
  - managed entries are updated if gateway IP changes;
  - user rewrites are preserved.
- README must not claim `awg.lan` / `dns.lan` is implemented until runtime code and tests exist.
