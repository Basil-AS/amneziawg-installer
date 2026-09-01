# AmneziaWG Installer

![Version](https://img.shields.io/badge/Installer_Version-5.29.0--bas.2-blue)

Установщик и набор инструментов для развёртывания AmneziaWG-сервера на Ubuntu и Debian. Проект создаёт серверный туннель, клиентские конфигурации, QR-коды и VPN URI, а также поддерживает IPv6, split/full-tunnel, изоляцию клиентов, P2P/DNAT, AdGuard Home, веб-панель и Telegram-бот.

Это форк [`bivlked/amneziawg-installer`](https://github.com/bivlked/amneziawg-installer). Форк сохраняет совместимость исходного проекта и добавляет исправления безопасности, сетевые режимы, операторские пресеты, domain-first endpoint, WireSock hints, опциональный WireSock-derived UDP proxy и интеграцию с профилями AmneziaWG 3.1.

## Быстрая установка

Поддерживаются Ubuntu 24.04, 25.10 и 26.04, Debian 12 и Debian 13 на x86_64, ARM64 и ARMv7.

```bash
curl -fsSL https://raw.githubusercontent.com/Basil-AS/amneziawg-installer/main/install_amneziawg.sh -o install_amneziawg.sh
sudo bash install_amneziawg.sh
sudo bash ./install_amneziawg.sh --yes --route-all --server-name="my-vpn"
```

Для английского интерфейса используйте `install_amneziawg_en.sh`.

```bash
sudo bash ./install_amneziawg.sh --yes --route-all --server-name="my-vpn"
sudo bash ./install_amneziawg.sh --preset=mobile
sudo bash ./install_amneziawg.sh --awg-version=3.1
```

Опциональный слой имитации протокола WireSock устанавливается отдельно и не
включается обычной установкой:

```bash
sudo bash ./amneziawg-proxy.sh
```

Он помещает AWG за loopback и может имитировать QUIC, DNS, STUN или SIP.
Изменение топологии перезапускает `awg-quick`, поэтому перед включением
сохраните текущий конфиг и убедитесь, что запасной SSH-доступ доступен.

Установщик проверяет ОС, архитектуру, сеть и свободное место, скачивает SHA256-проверенные файлы и сохраняет состояние установки для безопасного resume. Для AWG 3.1 он сначала проверяет фактическую возможность модуля применить конфиг на временном интерфейсе и прочитать его обратно через `awg show`. При провале проверок новые конфиги не записываются.

## Как это работает

1. Определяются ОС, сеть, внешний интерфейс и доступные пакеты.
2. Устанавливаются модуль и userspace-инструменты AmneziaWG; ключи создаются с ограниченными правами.
3. Генерируются параметры обфускации и конфигурации сервера/клиентов.
4. Включаются `awg-quick`, firewall/NAT, DNS-маршруты и выбранные дополнительные сервисы.
5. Создаются клиентский `.conf`, QR-код и VPN URI.

После установки основные файлы находятся в `/root/awg` и `/etc/amnezia/amneziawg`. Приватные ключи и `HeaderProtectionKey` не логируются; файл профиля с ключом имеет режим `0600`.

## Версии протокола

| Версия | Назначение | Параметр |
|---|---|---|
| 1.5 | Старые клиенты | `--awg-version=1.5` |
| 2.0 | Проверенный legacy-режим | `--awg-version=2.0` |
| 3.0 | AWG 3.x без полей 3.1 | `--awg-version=3.0` |
| 3.1 | Рекомендуемый режим с capability probe | `--awg-version=3.1` |

По умолчанию выбирается 3.1. Версия не определяется по номеру ядра: для 3.1 авторитетна только фактическая проверка `setconf` + read-back. Серверный и клиентский профили должны использовать одну версию.

## Мобильные сети

Профиль генератора выбирается через `--preset`:

- `balanced` (по умолчанию) - универсальный баланс совместимости и вариативности;
- `mobile` - консервативные размеры junk/padding для LTE/5G, CGNAT и роуминга;
- `stealth` - более широкий диапазон junk/padding для сетей с агрессивной фильтрацией;
- `compatibility` - консервативный профиль для старых клиентов.

Во всех профилях H-диапазоны генерируются заново, не пересекаются и ограничены значениями, совместимыми с Windows-клиентами. Для AWG 3.0/3.1 соблюдаются нижняя граница `S1-S4 >= 12` и уникальность размеров handshake; параметры остаются согласованными между сервером и клиентами.

Рекомендуется оставить `PersistentKeepalive = 25`, использовать домен с коротким TTL при меняющемся IP и начинать подбор MTU со значения 1280. После смены параметров нужно заново скачать клиентский конфиг или QR-код. Пресет не обходится блокировку UDP сам по себе.

## Возможности

- IPv4 full-tunnel, split-tunnel и собственные `AllowedIPs`;
- IPv6 через туннель, NDP proxy, NAT66 и leak-block;
- DNS-маршруты, изоляция клиентов, P2P и DNAT;
- AdGuard Home, веб-панель и Telegram-бот;
- WireSock compatibility hints, операторские пресеты и domain-first endpoint.
- Опциональный `amneziawg-proxy` для protocol imitation и ответов на probes;
  он не активируется автоматически и требует отдельной настройки.

Для IPv6 доступны режимы `auto` | Автовыбор, routed через отдельный routed IPv6 prefix, а также NDP proxy, NAT66 и leak-block. В режиме routed используется отдельный routed IPv6 prefix; при NDP учитывается текущая публичная `/64` на `eth0`/внешнем интерфейсе.

Для дополнительного PresharedKey используйте `--psk`; совместимость с клиентами вроде Shadowrocket описана в [ADVANCED.md#manage-cli-adv](ADVANCED.md#manage-cli-adv).

<details>
<summary>Пример: клиент my_iphone с PresharedKey</summary>

```bash
sudo /root/awg/manage_amneziawg.sh add my_iphone --psk
```
</details>

Нажатие Enter на шаге доступа к Web Panel оставляет безопасный VPN-only URL на шлюзе выбранной подсети. Итоговый URL для port `443` пишется без `:443`; свой домен + Let’s Encrypt работает best-effort из-за общих rate limits Let’s Encrypt, а TCP/80 открыт во внешнем firewall/security group. Для IP-домена установщик может использовать `sslip.io`.

Если домен не настроен, панель использует self-signed сертификат и безопасный VPN-only доступ.

При reverse proxy задайте `client_header_timeout` и `client_body_timeout` с запасом для медленных мобильных клиентов. Для явного fallback PPA используйте `AWG_ALLOW_PPA_CODENAME_FALLBACK=1` или `--allow-ppa-codename-fallback`.

Управление установленным сервером:

```bash
sudo /root/awg/manage_amneziawg.sh --help
```

## Скриншоты

![Дашборд веб-панели](docs/screenshots/web-panel-dashboard.png)

![Состояние сервиса](docs/screenshots/web-panel-health.png)

## Безопасность

Прочитайте [SECURITY.md](SECURITY.md). Не публикуйте `.conf`, QR-коды, VPN URI, приватные ключи, токены панели или `HeaderProtectionKey`. Уязвимости отправляйте по процедуре из `SECURITY.md`, а не в публичный issue.

## Документация

- [Установка на VPS](INSTALL_VPS.ru.md)
- [Расширенная настройка](ADVANCED.md)
- [История изменений](CHANGELOG.md)
- [Участие в разработке](CONTRIBUTING.md)
- [Английская версия](README.en.md)

## Лицензия и происхождение

Лицензия - MIT. Проект является форком `bivlked/amneziawg-installer`; изменения форка перечислены в [FORK_PATCHSET.md](FORK_PATCHSET.md).
