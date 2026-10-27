# Stage 4 LAB — батарея C1–C6 под полностью нативным CLI (2026-10-28)

Этап #34 в лабе (`lab-up.sh all`-эквивалент, контейнеры
`openwrt/rootfs:x86_64-25.12.5`, сети wanA/wanB/wanC, якорь uhttpd,
реальные ubusd + fake-netifd, реальные nft/ip-full под NET_ADMIN).

Контейнер собран на `spike/ucode` (этот коммит) — `/usr/bin/wanguard` =
wand.uc **со всеми 16 подкомандами нативно**, passthrough удалён;
`wanguard-sh` в контейнере больше никем не вызывается.

Гейт нативности (вход в батарею):

    $ WANGUARD_SH=/nonexistent wanguard list|grouplist|devices|wanstatus|apply|help|-h
    $ WANGUARD_SH=/nonexistent wanguard add|move|remove|groupadd|groupset|groupdel|wanset|wanauto|backupset ...
    # все rc=0 (кроме намеренных err-путей), sh-компаньон вне досягаемости

## Результаты

| Тест | Статус | Детали |
|---|---|---|
| C1 | **OK** | sh-сьют 67/67, ucode-сьют 55/55, дифференциальные сценарии байт-в-байт |
| C2 | **OK** | 5 живых циклов failover/failback (UCI-флипы a: wan1→wan2→wan1 через нативный apply); table 400 флипается `dev eth0 ↔ eth1`; metric-200 fallback на месте; sh-цикл byte-parity |
| C3 | **OK** | 3-WAN (#26): a по `list backup_iface` wan1→wan3→wan2→wan1, re-failover по списку, `flush:<g>><old>(<ip>)` байт-форма на каждом хопе |
| C4 | **OK** | keepalive ×100 (1 applied + 99 in-sync); **list/grouplist/wanstatus/devices/wan-flush — байт-в-байт vs sh, теперь как НАТИВНЫЙ код** (в этапе 3 они были passthrough — идентичность по построению) |
| C5 | **OK** | честный чёрный якорь (`curl -m 5` 5 с, fails=1), N-of-M 2/3, override держится, деградация flush молчит (rc=0) |
| C6 | **OK** | тик 4.0 vs 54.0 спавнов (13.5×), apply 14.0 vs 98.0 (7×), wall 17.16 vs 67.18 мс (3.9×), VmHWM 1280 vs 768 kB |

## Находка лабы (фикс мока)

`lab/netifd.uc`: dump() строился из записей фикстуры — имя, отсутствующее
в `/tmp/netifd.json`, выпадало из dump при живом ubus-объекте
`network.interface.<name>`. Реальный netifd включает в dump ВСЕ
сконфигурированные интерфейсы (up:false включительно). Этап 4 впервые
читает dump для existence-проверок (`wanset`/`backupset`: unknown netifd
iface) — мок починен: dump = NAMES (сконфигурированный набор) + имена
только из фикстуры. До фикса гейт `backupset a wan3` в лабе отвечал
«unknown netifd iface» при живом объекте — пробел достоверности мока,
не порта (паритет-харнесс этот путь не затрагивал: там ubus-мок читает
те же фикстуры обеими сторонами).

## Вывод

- Батарея C1–C6 **зелёная** под нативным CLI — dev-часть #34 готова.
- Осталось: живое окно на роутере (HITL, `stage4/window-runbook.md`),
  затем merge → тег v1.0.8 → фид → протокол в issue.
