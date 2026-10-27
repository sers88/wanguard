# Stage 3 LAB — батарея C1–C6 под нативным ucode apply (2026-10-27)

Приёмка #33 в лабе (`lab-up.sh all`-эквивалент, контейнеры
`openwrt/rootfs:x86_64-25.12.5`, три изолированных моста wanA/wanB/wanC,
якорь uhttpd, реальный ubusd + fake-netifd, реальный nft/ip-full/iptables
под NET_ADMIN). Спайк-пакет собран из `spike/ucode` @ 5032704 —
`/usr/bin/wanguard` = wand.uc **с нативным apply**, `wanguard-sh` рядом.

Гейт нативности (вход в батарею):

    $ WANGUARD_SH=/nonexistent wanguard apply
    in-sync                       # rc=0 — passthrough умер бы, apply native

## Результаты

| Тест | Вердикт | Что доказано |
|---|---|---|
| C1 | **OK** | sh-сьют 67/67, ucode-сьют 55/55, дифференциальные сценарии (stage1/2) байт-в-байт в лабовом окружении |
| C2 | **OK** | 5 живых циклов failover/failback: UCI-флип a: wan1→wan2→wan1 ведёт **нативный apply**; table 400 реально флипает `dev eth0 → eth1 → eth0`; metric-200 fallback живёт рядом; sh-цикл паритетен |
| C3 | **OK** | 3-WAN (#26): a идёт по `list backup_iface` wan1→wan3→wan2→wan1 (eth0→eth2→eth1→eth0), re-failover по списку, `flush:<g>><old>(<ip>)` байт-в-байт vs sh **на каждом хопе**, override-группа c не мигает |
| C4 | **OK** | keepalive ×100 (тело цикла строк 17–22 keepalive без изменений): **1 applied + 99 in-sync**, тихие тики, `list/grouplist/wanstatus/devices` и wan-flush события байт-в-байт vs sh |
| C5 | **OK** | black-hole якорь: честный `curl -m 5` в одном тике, fails=1; N-of-M 2/3: 1 мёртв → жив, 2 мертвы → down после 3 фейлов; override держит; деградации flush молчат (rc=0, файл потреблён) |
| C6 | **OK** | метрики ниже (включая новый замер apply) |

## C6 метрики (5 устаканенных прогонов на идентичном состоянии)

| метрика | ucode | sh | выигрыш |
|---|---|---|---|
| внешние спавны / tick | **4.0** (только curl) | 54.0 (uci=22, curl=4, grep/sed/awk/ip=28) | 13.5× |
| внешние спавны / **apply** | **14.0** (nft+ip, по дизайну внешние) | 98.0 (uci+grep+sed+awk+nft+ip) | **7.0×** |
| wall-time / tick (40 живых тиков) | 14.41 ms | 63.91 ms | 4.4× |
| VmHWM главного процесса | 1280 kB | 768 kB | (база интерпретатора, известно с этапа 1) |

Вердикт этапа 3: нога apply keepalive-цикла (`tick→apply→flush`) больше не
спускается в sh — минус ~84 внешних спавна на каждый тик keepalive
(98−14), цикл целиком ucode: tick 4.0 + apply 14.0 + flush (1 conntrack)
против sh-цикла ~150+.

Наблюдение по state-рендеру: `nft list table` после нативного apply
байт-в-байт совпадает с sh-рендером той же конфигурации (C2/C3 проверяют
это на каждом флипе через grep поверхности `wg:`/table 400 dev).

## Статус

- Лаба C1–C6: **зелёная** под нативным apply — лабовая часть #33 закрыта.
- Осталось: живое окно на роутере (HITL, `stage3/window-runbook.md`),
  затем merge → тег v1.0.7 → фид → протокол.
