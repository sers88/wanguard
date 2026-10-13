# Архитектура wanguard

## 1. Компоненты

| Компонент | Роль |
|---|---|
| netifd / `ip rule` | policy routing: выбор таблицы по fwmark |
| nftables (`table inet wanguard`) | маркировка пакетов по source-MAC |
| mihomo | перехват группы C (TUN), whitelist → Hysteria2, остальное → DIRECT |
| dnsmasq | DHCP всех клиентов (+ статические lease для удобства имён) |
| wanguard (CLI) | управление членством в группах (`/etc/config/wanguard` → nft) |
| luci-app-wanguard | веб-морда над тем же UCI (этап 5) |
| Mesh-точки доступа | L2-мост, без NAT/DHCP |

## 2. Маршрутизация: именованные группы × произвольные интерфейсы (issue #13)

Отбор по source-MAC делает nftables. `/usr/share/wanguard/wanguard.nft` —
только **скелет**: таблица, статические наборы и пустые цепочки. Всё
остальное — наборы `mac_<группа>`, правила маркировки/redirect, ip rules,
таблицы маршрутизации и запасные маршруты — генерирует **`wanguard apply`**
из `/etc/config/wanguard` (идемпотентный дифф, без flush-окон).

```
table inet wanguard {                       # скелет (wanguard.nft)
    set local_v4 { … }    # локальные/мультикаст/броадкаст — ИМЕНОВАННЫЙ набор
    set no_mark  { … }    # админ-исключения (из UCI globals.no_mark)
    chain marking  { type filter hook prerouting priority -150; … }   # пустая
    chain redirect { type filter hook prerouting priority -100; … }   # пустая
}
```

**Почему именованный set вместо `define`**: `define` раскрывается только
внутри `nft -f`-файла; динамически добавляемые правила (`nft add rule`)
его не видят. Семантика та же, генератор пишет `ip daddr != @local_v4`.

Каждое сгенерированное правило несёт тег-комментарий
`wg:<группа>:m<mark>` (marking) / `wg:<группа>:r<порт>` (redirect) — тег
полностью определяет тело правила, поэтому дифф сверяет только теги и
не зависит от нормализации вывода nft (метки как 0x… и т.п.).

**Аллокация mark/table/prio** — детерминирована сортировкой имён групп
(UBI: `config group '<имя>'`, тип direct|proxy):

| Тип | fwmark | table | ip rule prio |
|---|---|---|---|
| `proxy` (макс. 1 — redir-port и TUN mihomo синглтоны) | **300** | **500** | 8000 |
| `direct`, по алфавиту: 1-я, 2-я, 3-я… | 100, 200, 400, 500… (300 пропущен) | 400, 401, 402… (≤99 групп) | 8100, 8101, 8102… |

Миграция с прежней схемы (a=100/400, b=200/401, c=300/500) — нулевая:
сегодняшние метки воспроизводятся генератором как частный случай.

**Исключение LOCAL_V4 обязательно** (теперь набор `@local_v4` в скелете).
Без него маркированному клиенту ломается трафик к самому роутеру (dnsmasq
DNS, DHCP-продления, SSH, LuCI): пакеты уходят в TUN вместо локальной
доставки → «полностью пропал интернет». Постмортем — комментарии в issue #5.
`no_mark` — оперативные исключения по IP (напр., служебный хост на время
экспериментов), наполняется из UCI `globals.no_mark`.

**fw4-зона для TUN обязательна.** Интерфейс `Meta` не входит ни в одну зону
OpenWrt firewall: базовая цепочка `forward` fw4 имеет `policy drop`, а
`forward_lan` знает только `accept_to_wan`/`accept_to_lan`. Без зоны ВЕСЬ
форвардный UDP группы C (br-lan→Meta) режется с ICMP port-unreachable:
LoL виснет на загрузке матча (UDP 5000-5500/7100-7300 к Riot),
tailscale живёт на DERP-relay вместо direct, QUIC мёртв. TCP это не
затрагивало — он DNAT'ится в `redir-port :7892` и идёт через INPUT, поэтому
дефект не проявлялся на приёмке (все тесты были TCP-only). Постмортем
LoL-инцидента 2026-10-07: ноль пакетов на Meta при живом TCP + ICMP-шторм
на br-lan. Фикс: fw4-зона `proxy` (device Meta, input ACCEPT, forward
REJECT) + forwarding `lan→proxy`; зона ссылается на устройство по имени —
переживает пересоздание `Meta` при рестартах mihomo. Бэкап конфига firewall
до фикса на роутере: `/etc/config/firewall.bak-lol-20261007`.

Развязка меток на таблицы и запасные маршруты — тоже генерируются
(`wanguard apply`), UCI `/etc/config/network` больше не нужен для этого
(legacy-секции `config rule`/`route` удаляются вручную после приёмки #13 —
до тех пор сосуществуют безвредно: apply ставит идентичные правила):

```
ip rule: prio 8000: fwmark 300 lookup 500     # proxy-группа → mihomo
         prio 8100+: fwmark 100/200/… lookup 400/401/…   # direct-группы
```

Таблицы (по одной на группу, генерируются):

```
table 500: default dev Meta scope link        # proxy → mihomo (UDP), когда TUN жив
table 400+: default dev <l3_device группы>    # direct → свой интерфейс
каждая:    default <main-default> metric 200  # запас: цель недоступна → напрямую
main:      default …                          # все «немаркированные» + сам роутер
```

**Data plane proxy-группы (итоговый, рабочий):**
- **TCP** → nft redirect → mihomo `redir-port: 7892` (тот же класс входа, что и
  mixed-port — доказанно рабочий). Сниффер достаёт SNI, доменные правила и
  IP-CIDR Telegram работают как обычно. TCP НЕ маркируется (см. правило
  `meta l4proto != tcp` в marking): после DNAT-to-local маркированный пакет
  ушёл бы policy-route в TUN (постмортем issue #5).
- **UDP/прочее** → fwmark 300 → table 500 → TUN `Meta` (форвард br-lan→Meta
  разрешает fw4-зона `proxy` — обязательна, см. выше; без неё UDP группы
  режется в `handle_reject`).
- TCP-в-TUN на этой коробке НЕ работает: SYN проходит forward с oif Meta, но
  до TUN fd не доезжает, ядро отвечает клиенту RST. Диагностировано двойным
  tcpdump + nft trace (постмортем issue #5). Поэтому TCP — через redirect.

**Отказобезопасность по построению:**
- MAC не в наборах → main → интернет есть.
- nft-таблица снесена → ни меток, ни redirect → main → интернет есть
  (keepalive пересоздаёт из скелета ≤10с).
- Интерфейс direct-группы упал → маршрут не встаёт/пропадает → пакеты группы
  падают на `metric 200` (main-default) → интернет есть; при возврате
  интерфейса keepalive доустановит маршрут.
- mihomo остановлен → redirect теряет слушателя: TCP proxy-группы получает RST
  (fail-close, быстро заметно); UDP падает на `metric 200` → напрямую.
  TODO: при желании fail-open для TCP — отдельное решение (см. issue #5).

## 3. mihomo: ручной перехват (внедрено)

Раньше (этап 0): `tun.auto-route: true`, `tun.auto-redirect: true` — mihomo сам
ставил ip rules 9000–9002 и забирал ВЕСЬ форвардный трафик. Для multi-WAN это
не годилось: группы A/B не выпустить мимо прокси.

Текущее состояние (ключевой фрагмент конфига mihomo):

```yaml
mixed-port: 7890      # ручной HTTP/SOCKS-прокси (отладка, явные случаи)
redir-port: 7892      # сюда nft-redirect proxy-группы заворачивает TCP
tun:
  enable: true
  stack: gvisor
  auto-route: false        # маршрутизацию делает ip rule fwmark 300 (wanguard)
  auto-redirect: false     # глобальный перехват запрещён
  auto-detect-interface: true   # исходящие самого mihomo — в default WAN
```

Нюансы:
- DIRECT-трафик mihomo ре-ориджинит от себя — исходный IP клиента на выходе
  не сохранить ⇒ выбор WAN «по клиенту» возможен только в ядре ДО mihomo.
  Это и есть причина всей fwmark-схемы.
- `Meta` пересоздаётся при каждом рестарте mihomo ⇒ маршрут `default dev Meta`
  в таблице 500 перевставляет цикл **`wanguard-keepalive`** (procd-сервис
  `wanguard`, START=99): раз в 10с вызывает `wanguard apply`, который
  восстанавливает всё — nft-таблицу из скелета, наборы, правила, ip rules и
  маршруты. Проверено: после `/etc/init.d/mihomo restart` маршрут возвращается сам.
- После рестарта mihomo Hysteria2-туннель поднимается не мгновенно. Первые
  ~1–2 минуты соединения через прокси отбрасываются: в logread сыпется
  `dial ... error: authentication failed, status code: 404`, клиенты видят
  обрывы TLS. Само восстанавливается. **Прежде чем тестировать или
  диагностировать — выждать пару минут**, иначе легко принять прогрев за поломку.
- DNS: клиенты ходят в dnsmasq роутера (исключён LOCAL_V4) и получают
  **реальные IP** — это by design: домен достаёт сниффер из TLS SNI/QUIC,
  Telegram ловится по IP-CIDR. Минус: возможен DNS-poisoning провайдера для
  блокируемых доменов — тогда спасают только доменные правила по SNI
  (для HTTPS достаточно). Клиент с жёстко прописанным внешним DNS (8.8.8.8)
  попадает в TUN → `dns-hijack any:53` перехватит.
- mihomo API (`:9090`) живёт без секрета; конфиг применять **рестартом**
  (`/etc/init.d/mihomo restart`), не PUT /configs (даёт 400).

## 4. Порядок загрузки

0. `firewall` (fw4) — зона `proxy` по имени устройства `Meta` + forwarding
   `lan→proxy`. Порядок относительно mihomo не важен: пока `Meta` не
   существует, правила зоны просто не матчатся. Интерфейсы direct-групп
   должны состоять в fw4-зонах (wan/lan/…) — wanguard предупреждает, но
   зоны НЕ настраивает.
1. `network` — интерфейсы, main-default. (Legacy `config rule`/`route`
   до чистки после приёмки #13 — безвредный дубликат.)
2. `mihomo` (procd, поздний старт) — поднимает TUN `Meta`, слушает 7890/7892.
3. `wanguard` (procd, START=99, демон `wanguard-keepalive`) — при старте
   ставит скелет nft-таблицы (если нет), выполняет `wanguard apply`
   (наборы + правила + ip rules + таблицы всех групп из UCI) и далее
   повторяет apply циклом каждые 10с: самолечение после рестартов mihomo,
   чисток nft и полного reboot.

Отладочный инструмент: `/usr/bin/wanguard-testmark MAC [сек] [набор]` —
временная маркировка с самоснятием; игнорирует SIGHUP, запускать отсоединённо:
`setsid wanguard-testmark aa:bb:.. 60 </dev/null >/tmp/tm.log 2>&1 &`
(nohup на BusyBox отсутствует). После окна всегда проверять
`nft list set inet wanguard mac_c`.

## 5. Конфиг: /etc/config/wanguard

Единственный источник правды о группах и членстве. Читают/пишут одинаково
`wanguard` (CLI) и luci-app; рендер всего data plane — `wanguard apply`
(идемпотентный дифф: nft-наборы и правила по тегам, ip rules, таблицы).

```
config globals 'globals'
        option redir_port '7892'      # TCP-redirect mihomo (proxy-группа)
        list no_mark '203.0.113.10'   # никогда не маркировать/не редиректить

config group 'a'                      # имя = [A-Za-z0-9_], им ссылаются члены
        option type 'direct'          # direct → netifd-интерфейс
        option iface 'vpn'

config group 'c'
        option type 'proxy'           # proxy → mihomo (макс. 1 группа)

config member 'm_001122334455'        # секция = m_<mac-без-двоеточий>
        option name 'laptop'
        option mac '00:11:22:33:44:55'
        option group 'c'
```

CLI (`/usr/bin/wanguard`, шаблон: `router/etc.config.wanguard.example`):

```
wanguard list                       члены + статус дрейфа UCI↔nft
wanguard grouplist                  группы: тип/iface/mark/table/устройство/члены
wanguard devices                    клиенты LAN: mac/ip/имя/онлайн (данные доски)
wanguard add <mac> <группа> [имя]   регистрация + применение
wanguard move <mac> <группа>        смена группы + применение
wanguard remove <mac>               удаление + применение
wanguard apply                      полная сверка UCI -> nft + ip rules + таблицы
wanguard groupadd <имя> <iface|proxy>   создать группу + apply
wanguard groupset <имя> <iface|proxy>   сменить цель группы + apply
wanguard groupdel <имя>                 удалить пустую группу + apply
```

Свойства и ограничения:
- Аллокация mark/table/prio детерминирована (см. §2); добавление группы,
  алфавитно предшествующей существующим, сдвигает их метки — переход
  fail-safe: пакет со старой меткой без правила уходит в main, keepalive
  доводит правила/маршруты ≤10с.
- Имя группы переименованию не поддаётся (имя = id UCI-секции): groupadd →
  move → groupdel.
- Одна proxy-группа (валидация в CLI и LuCI; вторая в UCI игнорируется
  с warning).
- Интерфейс вне fw4-зон: apply предупреждает, но зоны не настраивает
  (форвард будет резаться — класс LoL-инцидента).
- Члены с несуществующей группой игнорируются рендером; `list` предупреждает
  (fail-safe: main-таблица).
- MAC нормализуется (двоеточия, lowercase) — принимает дефисы/точки/голый hex.
- Любая мутация сразу применяет дифф (без flush-окон); перед применением
  пакет команд проходит `nft -c`.
- Дрейф самоисцеляется: keepalive-демон раз в 10с вызывает `wanguard apply`,
  init-скрипт делает то же при загрузке → членство переживает рестарты
  mihomo, чистки nft-таблицы и полный reboot.
- `wanguard list` показывает DRIFT, если UCI и nft разошлись (exit 1).
- Гонки CLI↔keepalive безопасны: обе стороны делают идемпотентный дифф.
- **luci-app-wanguard** (issue #8/#13/#14) — третий клиент того же UCI:
  JS-вьюха (Network → WAN Guard), два режима за переключателем «Доска /
  Таблица». **Доска** (#14): колонки = direct-группы по алфавиту, proxy,
  Unclassified; карточки = клиенты (имя/MAC/IP/онлайн). Дроп карточки
  применяет перенос молча (uci.save → uci.apply; эта версия LuCI сама
  подтверждает rollback-окно ~через 1с — модалка не нужна), при ошибке —
  тост и пересборка доски из перечитанного UCI (карточка «отскакивает»).
  Тап по карточке = меню «Move to» (тач/клавиатура-фолбэк; HTML5 DnD на
  iOS не работает принципиально). DRIFT делает доску read-only. Полл 15с
  перечитывает UCI + `wanguard devices` — правки из CLI видны сами.
  **Таблица** (#8): грид групп, грид устройств, добавление из
  `/tmp/dhcp.leases`, индикатор in-sync/DRIFT; Save & Apply коммитит UCI и
  выполняет `wanguard apply` через rpcd file-exec (ACL в acl.d). Браузер
  никогда не трогает nft напрямую — только UCI + CLI-apply. Online-статус
  и Unclassified берутся из `wanguard devices` (leases + ARP: видны
  статические IP; ACL не расширялся — роутер-сайд данных нет). Файлы:
  `luci-app-wanguard/` (view + menu.d + acl.d), установка —
  `scripts/deploy-luci.ps1` (чистит кэши LuCI, рестартует rpcd).
- Откат любого изменения: снапшот до деплоя `deploy-wanguard.ps1` кладёт в
  `/root/rollback/<дата>/` (файлы + ruleset + ip rule + маршруты) —
  восстановление = возврат файлов из снапшота + рестарт сервиса.

## 6. MTU/MSS

| Путь | MTU | MSS clamp |
|---|---|---|
| PPTP (nomppe) | ~1436 | да |
| PPPoE | 1492 | да |
| TUN Meta | 9000 (внутренний) | n/a |

## 7. Что сознательно НЕ делаем

- mwan3 — не нужен: группы жёсткие, переключение ручное.
- Балансировка/склейка каналов — потоки не ускоряются, сложности много.
- Авто-failover — по требованию владельца; запасной маршрут (`metric 200`)
  генерируется у каждой группы.
- Настройка fw4-зон для новых интерфейсов — вручную владельцем
  (wanguard только предупреждает).
