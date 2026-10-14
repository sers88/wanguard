# wanguard

**Per-device WAN routing for OpenWrt** — named groups of LAN clients (by MAC),
each group pinned to any WAN interface (direct) or to a mihomo proxy, with a
LuCI kanban board and an idempotent generator that renders the whole data plane
from a single UCI config.

Перевод клиентских устройств домашней сети между WAN-каналами: именованные
группы по MAC-адресам, каждая группа — на свой netifd-интерфейс (direct) или
через mihomo (proxy, одна). Всё управляется из `/etc/config/wanguard`.

## Как это работает

```
/etc/config/wanguard  (UCI — единственный источник правды)
        │  wanguard apply   ← идемпотентный дифф, без flush-окон
        ▼
nft sets mac_<group> + marking/redirect rules (теги wg:<группа>:…)
ip rules (fwmark → таблица)
per-group routing tables: default dev <iface> + запасной default metric 200
```

- **Аллокация детерминирована**: proxy → fwmark 300/table 500; direct-группы
  по алфавиту → 100, 200, 400… / таблицы 400+ (300 пропущен под mihomo).
- **Самолечение**: keepalive перезапускает `apply` раз в 10с — членство
  переживает рестарты mihomo, чистки nft и полный reboot.
- **Fail-safe по построению**: клиент вне наборов → main-таблица; упавший
  интерфейс группы → запасной маршрут; ничего не блокирует интернет целиком.
- **Браузер не трогает nft**: LuCI правит UCI и вызывает `wanguard apply`.

Подробно — [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (аллокация, теги,
постмортемы инцидентов, порядок загрузки).

## LuCI: канбан-доска

**Сеть → WAN Guard** — колонки = группы + Unclassified, карточки = клиенты
(имя/MAC/IP/онлайн). Перенос устройства — drag & drop, применение мгновенное;
тап по карточке = меню «Move to» (тач-фолбэк). DRIFT переводит доску в
read-only, пока keepalive не синхронизирует состояние. Табличный вид остаётся
для массовых правок.

## Установка

### Через подписанный apk-фид (штатный путь)

Фид публикуется CI в ветку [`feed`](https://github.com/sers88/wanguard/tree/feed)
при пуше тега `vX.Y.Z` (пакеты получают версию `X.Y.Z-r1`). Индекс
`packages.adb` подписан EC-ключом; публичный ключ — [`keys/wanguard.pem`](keys/wanguard.pem).

На роутере (OpenWrt 24.10+/25.x, apk 3.0.x):

```sh
# 1. доверие ключу фида
curl -o /etc/apk/keys/wanguard.pem \
  https://raw.githubusercontent.com/sers88/wanguard/feed/keys/wanguard.pem

# 2. подключить фид
echo "https://raw.githubusercontent.com/sers88/wanguard/feed/packages/x86_64/packages.adb" \
  >> /etc/apk/repositories.d/customfeeds.list

# 3. установить
apk update
apk add wanguard luci-app-wanguard

# 4. конфиг (только если ещё нет — apk никогда не трогает живой UCI)
cp /usr/share/wanguard/etc.config.wanguard.example /etc/config/wanguard

# 5. сервисы
/etc/init.d/wanguard enable && /etc/init.d/wanguard start
/etc/init.d/wan-watch enable && /etc/init.d/wan-watch start   # опционально
```

Обновление: `apk update && apk upgrade`. Файлы, переживающие sysupgrade,
добавить в `/etc/sysupgrade.conf` (`/usr/bin/wanguard*`, `/usr/share/wanguard/`,
`/etc/init.d/wanguard`, `/etc/init.d/wan-watch`).

### Деплой-скрипты (разработка)

Нужен ssh-доступ с ключом:

```powershell
powershell .\scripts\deploy-wanguard.ps1    # CLI + keepalive + init.d + nft-скелет
powershell .\scripts\deploy-luci.ps1        # LuCI-приложение
```

## Состав репозитория

| Путь | Что это |
|---|---|
| `router/wanguard` | CLI: list/devices/add/move/remove/group*/apply |
| `router/wanguard-keepalive` | procd-демон: apply каждые 10с |
| `router/wan-watch` | health-check main-пути (pptp), `ifup vpn` при смерти (#18) |
| `router/init.d/wanguard` | init-скрипт (apply при загрузке) |
| `router/init.d/wan-watch` | init-скрипт health-check'а |
| `router/wanguard.nft` | скелет nft-таблицы |
| `router/etc.config.wanguard.example` | шаблон UCI |
| `router/wanguard-testmark` | отладка: временная маркировка MAC |
| `luci-app-wanguard/` | view + menu.d + acl.d |
| `apk/build.sh` | сборка apk-пакетов (wanguard + luci-app-wanguard) |
| `keys/wanguard.pem` | публичный ключ подписи фида |
| `scripts/deploy-*.ps1` | деплой на роутер по scp/ssh (разработка) |

## Требования

- OpenWrt с apk (24.10+/25.x), nftables (fw4), bash-free busybox sh
- Для proxy-группы: mihomo с `redir-port` + TUN (fw4-зона для TUN обязательна)

## License

[MIT](LICENSE)
