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

Пока — деплой-скрипты (нужен ssh-доступ с ключом):

```powershell
powershell .\scripts\deploy-wanguard.ps1    # CLI + keepalive + init.d + nft-скелет
powershell .\scripts\deploy-luci.ps1        # LuCI-приложение
```

Подписанный apk-фид (установка/обновление штатным `apk`) — в работе.

## Состав репозитория

| Путь | Что это |
|---|---|
| `router/wanguard` | CLI: list/devices/add/move/remove/group*/apply |
| `router/wanguard-keepalive` | procd-демон: apply каждые 10с |
| `router/init.d/wanguard` | init-скрипт (apply при загрузке) |
| `router/wanguard.nft` | скелет nft-таблицы |
| `router/etc.config.wanguard.example` | шаблон UCI |
| `router/wanguard-testmark` | отладка: временная маркировка MAC |
| `luci-app-wanguard/` | view + menu.d + acl.d |
| `scripts/deploy-*.ps1` | деплой на роутер по scp/ssh |

## Требования

- OpenWrt с apk (24.10+/25.x), nftables (fw4), bash-free busybox sh
- Для proxy-группы: mihomo с `redir-port` + TUN (fw4-зона для TUN обязательна)

## License

[MIT](LICENSE)
