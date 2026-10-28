# Stage-4 window log — CLI CRUD нативно (issues #30/#34)

**2026-10-28, вечер (~35 мин, HITL, владелец за батареей).** Кандидат:
`wanguard-ucode-0.0.0-r10281628.apk` (sha256 `dd32c8d3…`), собран из
`spike/ucode` @ ab9288b. Savepoint `/root/rollback/20261028-192900/`
(внутри feed-apk 1.0.7-r1 — L3-машина отката).

## Результаты фаз

| Фаза | Гейты | Статус |
|---|---|---|
| A | baseline: ANCHORS 3/3 ×3 WAN, list in-sync, wand-лог тихий; baseline-выводы CLI в /tmp/stage4-baseline/ (md5 зафиксированы); savepoint + rollback-команда записана | OK |
| B | ucode ok; sha256 apk = манифесту | OK |
| C | md5-манифест **7/7 OK** (`/usr/bin/wanguard` = `869d9a81…` = stage-4 wand.uc); шебанг `#!/usr/bin/ucode`; **нативность: list/grouplist/devices/wanstatus/apply + wand-tick/wan-flush под `WANGUARD_SH=/nonexistent`**; `apply` = **in-sync** (не applied — ucode видит то же живое состояние); WANGUARD_DEBUG молчит; **list + grouplist BYTE-IDENTICAL** базлайну 1.0.7 (где list был passthrough→sh) | OK |
| D | rollback.sh → md5 = байты фида (`6595dbde…`) → сервис поднялся, sanity зелёный; **обратно: apk del-then-add (урок №1 этапа 1 — add той же версии NO-OP), md5 7/7, list BYTE-IDENTICAL** | OK |
| E | wand-tick/wan-flush rc=0; сервис стартован, keepalive тихий | OK |
| E2 | полный CRUD-цикл нативно: add/move(+already-in-group)/groupadd/groupset(flush-эхо `wand: flush:testgrp>wan(10.15.235.106)`)/wanset(flush `>rostelecom(100.102.56.184)`)/wanauto/remove/groupdel; err-путь backupset (собственный iface → rc=1); **UCI вернулась байт-в-байт** (`1c86de75…` = savepoint), сирот-сетов в nft: 0 | OK |
| F | drill `freedom 3` = **3/3** (2×nft-дренаж + 1×force); 6 флипов, батарея владельца после каждого; 18 flush-событий байт-формы `wand:flush:<g>><old>(<ip>)`; `.flush` пуст после apply; WANGUARD_DEBUG тихий; cleanup чистый | OK |
| G | ANCHORS 3/3; wand-лог тихий после drill; list in-sync; md5 на месте; `freedom.iface=freedom` | OK |

LuCI-дым (фаза C, владелец): плата Network → WAN Guard рендерится,
DRIFT-индикатор зелёный, карточки на местах — **rpc file exec парсит
нативные list/devices**.

## Живые находки окна

1. **L1 этапа 4 возвращает фидовый 1.0.7** — а это уже ucode (стадия 3):
   «rollback to sh» больше не означает sh-CLI. rollback.sh
   `restored: 6595dbde…` — точный md5 фидового `/usr/bin/wanguard`.
   L1 не трогает apk-DB (spike остаётся установлен) — файлы восстанавливаются
   поверх,Ownership чинит L3/следующий фид-апгрейд. Ожидаемая семантика кита,
   но в stage4/window-runbook.md была неверная формулировка («sh-CLI целиком»)
   — исправлена после окна.
2. **`apk add` той же версии = NO-OP** (урок №1 этапа 1, пойман снова):
   после L1-репетиции спайк был всё ещё в DB с фидовыми байтами на диске →
   re-spike требует **del-then-add** (заложено в кит, поймано первым
   прогоном фазы D).
3. `ucode -e 'import * as fs; print(...)'` — import без `from` падает
   (урок этапа 1, сформулирован в runbook этапа 3 неточно); для print
   import не нужен вовсе.

## Состояние после окна

Спайк (stage-4 CLI) **остаётся жить** — soak по решению владельца
(прецеденты этапов 1–3). Откат в любой момент:
`sh /root/rollback/20261028-192900/rollback.sh` (L1) — без интернета,
всё локально.
