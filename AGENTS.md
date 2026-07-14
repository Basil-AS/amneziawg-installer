@RTK.md

# Инженерный workflow

## Обязательный цикл задачи

Каждая задача проходит полный цикл:

```text
UNDERSTAND → PLAN → BRANCH → EXECUTE → VERIFY → SELF-REVIEW → COMMIT → PUSH → PR → CHECKS → MERGE → CLEANUP → LOG
```

- `UNDERSTAND`: сформулировать результат и проверяемый DoD; при критичной неоднозначности задать один точный вопрос.
- `PLAN`: разбить работу на логически завершённые изменения и выбрать релевантные проверки.
- `BRANCH`: обновить default branch через `fetch --prune` и `pull --ff-only`, затем создать короткоживущую ветку строго от свежего default.
- `EXECUTE`: вносить минимальные изменения без постороннего рефакторинга.
- `VERIFY`: выполнить тесты, lint и дополнительные проверки, соответствующие риску изменения.
- `SELF-REVIEW`: до публикации прочитать полный diff относительно default branch, проверить scope, безопасность, обратную совместимость, тесты и документацию.
- `COMMIT`: добавить в индекс только файлы задачи и создать Conventional Commit с обязательным `Co-authored-by` трейлером агента.
- `PUSH`: отправить только feature-ветку.
- `PR`: создать PR по обязательному шаблону ниже.
- `CHECKS`: дождаться завершения GitHub checks, а не ограничиваться фактом их запуска.
- `MERGE`: мержить только зелёный PR и только если branch protection не требует независимого ревью.
- `CLEANUP`: удалить feature-ветку локально и remote, обновить refs с `--prune`.
- `LOG`: зафиксировать результат, проверки, PR/merge и следующий шаг в `PROGRESS.md`.

## Ветки и default branch

- Прямые feature/fix/docs-коммиты в `main`, `master` или другой default branch запрещены.
- Единственное допустимое изменение default branch агентом — merge проверенной feature-ветки в рамках описанного ниже PR-процесса или offline fallback.
- Формат ветки: `agent/<type>-<task>`, например:
  - `agent/feat-lan-domains`;
  - `agent/fix-p2p-snat`;
  - `agent/docs-agent-protocol`;
  - `agent/chore-bas-release`.
- `<type>` должен отражать Conventional Commit type: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`.
- `<task>` — короткий kebab-case идентификатор задачи без дат, имён людей и случайных суффиксов.
- Ветка всегда создаётся от свежего remote default branch и живёт только до merge/закрытия PR.
- Не переиспользовать старую ветку для новой задачи и не смешивать независимые задачи в одном PR.
- Force-push и переписывание опубликованной истории запрещены.

## Pull Request и удаление ветки

Перед созданием PR обязателен self-review полного diff относительно target branch:

```bash
git diff --check origin/main...HEAD
git diff --stat origin/main...HEAD
git diff origin/main...HEAD
```

Если default branch называется иначе, заменить `main` на фактическое имя. Найденные посторонние изменения нужно убрать из PR или явно вынести в отдельную задачу.

PR body всегда содержит четыре секции:

```markdown
## What

<что изменено>

## Why

<зачем это нужно; root cause для исправления>

## How to verify

<точные команды и/или ручные шаги проверки>

## Notes

<совместимость, миграция, риски, ограничения, rollback или "-">
```

После публикации ветки:

1. Создать draft PR, проверить заголовок, target branch, body и состав файлов.
2. Перевести PR в ready только после self-review и локальных проверок.
3. Выполнить `gh pr checks --watch` и дождаться зелёного результата всех обязательных checks.
4. Проверить branch protection, rulesets и required reviews.
5. Если требуется независимое ревью или protection запрещает self-merge — не обходить правило и не мержить самому. Установить `STATUS: blocked`, сохранить ссылку на PR и точно указать, чьё действие требуется.
6. Если независимое ревью не требуется и checks зелёные — выполнить `gh pr merge --merge --delete-branch` (или другой явно заданный проектом merge method).
7. После merge обязательно:
   - переключиться на default branch;
   - выполнить `git pull --ff-only`;
   - удалить оставшуюся локальную feature-ветку через `git branch -d`, если CLI не удалил её сам;
   - выполнить `git fetch --prune`;
   - убедиться, что feature-ветки нет ни локально, ни среди remote refs, а рабочее дерево чистое.

### Offline/local fallback

Отсутствие remote, сети, `gh` или GitHub API не делает локальную задачу невыполнимой:

1. Всё равно работать в ветке `agent/<type>-<task>` от свежего локального default branch.
2. Выполнить VERIFY и SELF-REVIEW в полном объёме.
3. Если remote/PR объективно недоступны, локально переключиться на default branch и выполнить `git merge --no-ff agent/<type>-<task>`.
4. Удалить локальную feature-ветку после успешного merge.
5. В `PROGRESS.md` явно отметить, почему PR/push невозможны, какой merge commit создан и что нужно синхронизировать после восстановления remote/сети.

Этот fallback не разрешает прямые feature-коммиты в default branch и не применяется, если GitHub доступен, но PR заблокирован обязательным ревью.

# Аудит технологий: best-in-class

При архитектурном или технологическом аудите нельзя ограничиваться проверкой «работает ли текущее решение». Для каждого значимого технического решения нужно отдельно задать вопрос:

> Это всё ещё лучший зрелый инструмент для наших требований, или индустрия уже предлагает доказуемо лучший вариант?

## Обязательный охват

Проверить все значимые категории, присутствующие в проекте, включая:

- хранение данных и state management;
- сетевые протоколы, транспорт, streaming и API-контракты;
- языки, runtime и стандартные библиотеки;
- package/dependency management;
- build system, bundling, CI/CD и release tooling;
- styling, UI framework и frontend tooling;
- базы данных, очереди, кеши и фоновые задачи;
- observability, security, secrets и deployment/runtime isolation;
- тестовые фреймворки и developer tooling.

Примеры направлений вроде `JSON → SQLite`, `Tailwind v3 → v4`, `HLS → LL-HLS`, `webpack → Vite`, `pip → uv` являются только ориентирами мышления, а не готовыми рекомендациями. Перед каждым аудитом необходимо сверять актуальное состояние индустрии, официальные release notes, поддержку используемых версий и production-практику на момент аудита. Нельзя переносить этот список в выводы автоматически или считать его актуальным через год без новой проверки.

Если сеть доступна, для меняющихся фактов использовать актуальные первичные источники: официальную документацию, release notes, спецификации, репозитории и публичные production case studies. Если сеть недоступна, не выдавать память модели за актуальный аудит: пометить соответствующий вывод как `pending verification` и указать, что именно нужно проверить позже.

## Критерии кандидата

Технология может быть рекомендована вместо текущей только при одновременном выполнении всех четырёх критериев:

1. **Измеримый выигрыш.** Есть baseline, целевая метрика и численный эффект: latency, throughput, размер bundle/image, CPU/RAM, время build/deploy, error rate, стоимость эксплуатации или developer lead time. Формулировки «современнее», «быстрее» и «удобнее» без цифр недостаточны.
2. **Зрелость.** Stable-релиз, активное сопровождение, понятная security/support policy и подтверждённое production-использование. Beta, experimental, abandonware и решения, поддерживаемые только хайпом, отсеиваются.
3. **Стоимость миграции.** Оценены трудозатраты, сложность преобразования данных/кода, обучение, dual-run, downtime, rollback и долгосрочная цена сопровождения. Выигрыш должен оправдывать migration cost.
4. **Совместимость с окружением.** Кандидат совместим с поддерживаемыми ОС/архитектурами, ресурсными лимитами, security model, лицензией, offline/air-gapped режимами, существующими клиентами, API и архитектурными ограничениями проекта.

Если хотя бы один критерий не доказан, кандидат не получает рекомендацию `adopt`; допустимы только `trial`, `watch` или `reject` с явным объяснением недостающих доказательств.

## Формат результата аудита

Для каждого решения фиксировать:

| Поле | Содержание |
|---|---|
| Current | Текущая технология, версия, роль и фактические ограничения |
| Candidate | Рассмотренная зрелая альтернатива |
| Industry status | Актуальный stable/status/support с датой проверки и источниками |
| Measurable gain | Baseline, метод измерения и ожидаемый численный эффект |
| Maturity | Stable-релиз, сопровождение и production evidence |
| Migration cost | Оценка работ, рисков, downtime и rollback |
| Compatibility | ОС, архитектуры, ресурсы, лицензия, API/клиенты, security constraints |
| Verdict | `keep`, `trial`, `adopt`, `watch` или `reject` |

Нельзя рекомендовать миграцию только ради новизны. `keep` является полноценным положительным результатом, если текущий инструмент лучше соответствует ограничениям проекта или выигрыш альтернативы не окупает миграцию.

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
