# Промт для следующей сессии — приёмка ucode-спайка в Docker (issue #29)

Скопируй текст ниже в новую сессию.

---

## Контекст

Репо `E:\Projects\wanguard-public`, ветка **`spike/ucode`** (HEAD `6a1f64f`), `main` не трогать (65ddddf). Спайк по issue #29: миграция ядра `router/wanguard` (939 строк POSIX sh) на ucode. Результат — вердикт в issue #29. Ветку в фид не публиковать никогда (фид только из тегов main).

**Решение владельца: роутер не трогать вообще.** Вся приёмка — в Docker. HITL-окна из RUNBOOK.md отменены.

Docker Desktop поднят. Образ `openwrt/rootfs:x86_64-25.12.5` (ucode 2026.01.16 предустановлен). Сети `wanA` 172.30.10.0/24 и `wanB` 172.30.20.0/24 созданы. Контейнеры `wanguard-lab-net` (якоря uhttpd: 172.30.10.10:80 → /a/anchor, 172.30.20.10:80 → /b/anchor) и `wanguard-lab` (eth0=.10.2, eth1=.20.2, NET_ADMIN, спайк-пакет установлен, real ubusd + fake-netifd) могут быть живы — проверить `docker ps`, при отсутствии пересоздать.

## Что уже сделано (всё закоммичено)

- `docs/spike-ucode/00-CLI-CONTRACT.md` — замороженный контракт CLI (16 подкоманд, форматы, keepalive-строка `in-sync`)
- `wand.uc` — порт tick-пути (311 строк vs 939 sh): UCI через uci.so, ОДИН `network.interface dump`, проба через curl-ребёнка (uclient.so не умеет SO_BINDTODEVICE — честно задокументировано), wand_backups #26, state-машина. Дифференциальная паритетность с sh доказана побайтно (`scenario.sh`, `scenario26.sh`)
- `run-tests-ucode.sh` — 20/20 репрезентативных тестов; sh-сьют 67/67 в том же контейнере
- `build-spike.sh` + `install-test.sh` — пакет `wanguard-ucode` собирается/ставится, keepalive (sh без правок) гоняет ucode-CLI, passthrough byte-parity
- `VERDICT.md` — драфт матриц с числами: **58 → 4 fork'а/тик (14.5×)**, контейнерный wall-time ~110ms → ~13.5ms (~8×); рекомендация «нет, с триггерами пересмотра»; полная переписка 6–9 дней
- **Docker-лаборатория** (`docs/spike-ucode/lab/`): `lab-up.sh` (оркестратор: up/net/shell/C1..C6/all/down), `setup.sh` (bootstrap внутри), `netifd.uc` (fake-netifd: публикует РЕАЛЬНЫЕ network.interface-объекты в реальный ubusd, фикстуры `/tmp/netifd.json` hot-reload на каждый вызов, обязателен keepalive-таймер для uloop.run()), `C1-regress.sh`, `C2-failover.sh`
- Ядро WSL2 даёт **A-FULL**: nft/ip rule/conntrack работают в контейнере (NET_ADMIN)

## Что осталось (по порядку)

1. **C2 добить**: последняя ручная репродукция точной последовательности c1 — зелёная (blocked 1 → unblocked 0 → curl 200 → tick6 `up:wan1 failback:a>wan1` → a.iface=wan1). Скрипту нужен один чистый полный прогон `CYCLES=5`. Уже внесено: lastswitch=0 перед каждой failover-фазой (dwell 60с — это ВАЛИДНОЕ поведение watchdog, скрипт должен его обходить как T9 в sh-сьюте), trap-очистка iptables, `applied|in-sync` оба принимаются. Если цикл 2+ опять падает — см. «грабли» №7.
2. **C3** — 3-WAN re-failover (#26): третья сеть `wanC` 172.30.30.0/24 + якорь 172.30.30.10 + `wan3` в netifd-фикстурах (NAMES уже есть) + `list backup_iface` в конфиге группы a; живой re-failover wan1→wan3→(dead)→wan2.
3. **C4** — контракт: немодифицированный keepalive-цикл ×100 итераций (`wand-tick`+`apply`+`wan-flush`) через `/usr/bin/wanguard`; byte-parity `list/grouplist/wanstatus/devices` между `/usr/bin/wanguard` и `/usr/bin/wanguard-sh` на идентичном состоянии (для `devices` — фикстуры `/tmp/dhcp.leases` + `/proc/net/arp`).
4. **C5** — края: медленный/чёрный якорь (DROP вместо REJECT → честный 5с таймаут curl — один тик, задокументировать), N-of-M (reliability=2, один якорь из двух мёртв → up; оба мертвы → down после 3), override-группы не переключаются.
5. **C6** — метрики в лабе: форки (shim-счётчик на uci/awk/grep/jsonfilter/sort/cut/sed/date, ubus НАСТОЯЩИЙ не мокать), wall-time 40 тиков против живых якорей (ucode `clock()` → `[сек,нсек]`), VmHWM из `/proc/<pid>/status`.
6. **Коммит лабы + VERDICT.md**: строки ROUTER → DOCKER + оговорка «не железо: абсолютные ms нетранслируемы, userland ровно 25.12.5».
7. Отчёт владельцу → его вердикт (да/нет/гибрид) → ТОЛЬКО после решения: комментарий в issue #29 и §7 `ARCHITECTURE.md`.

## Грабли (собраны кровью — не наступать снова)

1. **Путь ubus-сокета**: эта сборка использует `/var/run/ubus/ubus.sock` (С подкаталогом). В wand.uc был хардкод-чек `/var/run/ubus.sock` — он молча обнулял всю iface-map. Чек УДАЛЁН полностью: `ubus.connect()` + try/catch сами деградируют. Не возвращать хардкоды путей.
2. **ubus API**: у соединения `conn.list()` (имена объектов), НЕ `objects()`; отключение — `conn.disconnect()`, НЕ `close()`.
3. **ucode 2026.01.16**: `export function` ЛОМАЕТ компиляцию модуля (работает хвостовой `export {}`); нет `for..of` (только `in`: по массиву — значения, по объекту — ключи; проверка членства `x in arr` ищет ИНДЕКС — использовать объект-множество); нельзя trailing commas в литералах; `clock()` возвращает `[сек,нсек]`; `popen().close()` возвращает чистый exit-code.
4. **busybox контейнера**: нет nohup/diff/od/install/timeout/pkill; `sleep` без дробей; `date +%N` не поддержан (возврат — ucode `clock()`); в `case`-паттернах кавычить `>` (`*"failover:a>wan2"*`).
5. **`/usr/bin/wanguard` в лабе — КОПИЯ wand.uc на момент сборки пакета.** После правки wand.uc: `build-spike.sh` + `apk add --force-overwrite`, либо тестировать напрямую `ucode /repo/docs/spike-ucode/wand.uc ...` (для passthrough нужен env `WANGUARD_SH=/usr/bin/wanguard-sh`... по умолчанию он и есть).
6. **Docker-изоляция мостов** даёт честную изоляцию якорей: `eth0→172.30.20.10` = 5с таймаут, `eth0→172.30.10.10` = мгновенно. Глобальный список якорей (2 URL) ⇒ каждый тик несёт один 5с таймаут ⇒ тики ~5с. Для скоростных C2/C4/C6 — оставить в UCI ОДИН якорь; N-of-M тестировать отдельно в C5.
7. **Гигиена**: `/tmp/.uci` (остаточные uci-дельты) чистить в каждом reset — иначе дельты применяются поверх heredoc-конфигов (флаки); iptables REJECT после fail-path снимать (trap уже в C2); PowerShell `Set-Content -Encoding UTF8` пишет BOM — busybox давится (писать ASCII/UTF8-no-BOM).
8. **apply** возвращает `applied` (есть изменения) или `in-sync` (нет) — после флипа ждать `applied` НЕ ошибка.
9. Windows-кавычки в `docker exec sh -c '...'` ломаются на вложенных — сложные скрипты класть в файлы в `lab/` и вызывать `docker exec wanguard-lab sh /repo/docs/spike-ucode/lab/<script>.sh`.

## Быстрый старт сессии

```powershell
docker ps  # лаба жива?
docker exec wanguard-lab sh -c 'ubus call network.interface dump | head -3'  # bus ok?
docker exec wanguard-lab sh -c 'sh /repo/docs/spike-ucode/lab/C2-failover.sh'
```
Если лаба мертва: `docker exec` недоступен → пересоздать по `lab/lab-up.sh` (скрипт для Linux-host; на Windows повторить его docker-команды руками: `docker network create`, якорный контейнер с `apk add uhttpd`, лаба с `-v E:\Projects\wanguard-public:/repo:ro -v C:\Users\sersb\AppData\Local\Temp\opencode\apk.static:/tmp/apk.static:ro --cap-add=NET_ADMIN`, затем `setup.sh`).

Definition of done: C1–C6 зелёные в одной сессии лабы, VERDICT.md обновлён (DOCKER-строки), всё закоммичено в `spike/ucode`, отчёт владельцу готов. Роутер, теги, фид — НЕ трогать.
