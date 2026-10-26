# Stage-3 handoff — лаба C1–C6 + окно #33 на следующей сессии

Состояние на 2026-10-27. Dev-часть этапа 3 (#33) **готова и закоммичена**
на `spike/ucode` (4 коммита: 65b9e14 моки → eac7fbd пробы/NOTES →
7701e92 харнесс → 7a1d1ba нативный apply).

## Что готово

- `wand.uc`: `apply` нативно (migrate/ensure_table/alloc/render/diff/
  reconcile — полный порт cmd_apply); dispatch: `apply` нативный,
  остальные 14 подкоманд — passthrough. Keepalive-цикл
  tick→apply→flush теперь ucode end-to-end.
- **Гейт паритета**: `docs/spike-ucode/stage3/apply-parity.sh` —
  **165/165 с нативным apply** (16 фикстур #33: stdout/rc/батч/полное
  nft+ip-состояние байт-в-байт sh vs ucode + идемпотентность).
- Stateful-моки nft/ip (`$NFT_STATE`/`$IP_STATE`), легаси-режим не
  тронут: sh 67/67, ucode 55/55, smoke-nft 32/32, smoke-ip 25/25.
- Пробы реального nft 1.1.6 / ip-full 25.12.5 + все уроки: NOTES.md
  §A–F (байт-форматы, load-bearing порядок батча, busybox-квирки) и
  §G (восемь ucode-квирков порта: join(sep,arr), warn без \n,
  replace first-only, index=-1, set 3-арг для именованных секций,
  cursor-снапшот, $PPID-трюк, printf C-style).
- Спайк-пакет с нативным apply собирается и ставится:
  `wanguard-ucode-0.0.0-r99.apk` (md5 1cf710fa…), install-smoke
  `APPLY-SMOKE-OK` (applied → in-sync из установленного
  /usr/bin/wanguard; в голом контейнере без ubusd честный
  iface-down warn — лаба публикует fake-netifd).

## Что дальше (по порядку)

1. **Лаба C1–C6 под ucode-apply** (подъём из stage2/NEXT-SESSION.md,
   те же wanA/wanB/wanC + anchor; setup.sh ставит спайк-пакет — теперь
   с нативным apply):
   - C1 регресс: sh 67/67 + ucode 55/55 + сценарии байт-в-байт;
   - C2/C3: флипы таблицы 400 ведёт **ucode-apply**, паритет каждого
     хопа против sh (метод F9) + flush-протокол #24 байт-в-байт;
   - C4: keepalive ×100 через ucode CLI → 1 applied + 99 in-sync;
   - C5 края, C6 метрики (форк/тик должен упасть ниже этапа 2:
     apply больше не спавнит sh-ребёнка).
2. `stage3/window-runbook.md` — написать по образцу stage1/stage2
   (фазы A–G, гейт нативности `WANGUARD_SH=/nonexistent wanguard apply`,
   репетиция отката, drill `freedom N`, жёсткий стоп 45–60 мин).
   Кит этапа 1 (make-savepoint/drill/лестница L0–L4) без изменений.
3. **Окно на роутере (HITL)**: savepoint → спайк → in-sync-паритет на
   живом состоянии → drill → батарея владельца 5/5 → soak → merge →
   тег v1.0.7 → CI → фид → `apk add wanguard=<вер>` (урок #32 — явно).
   Откат в любой момент: sh-пакет (идемпотентный diff реконцилирует
   nft/ip-состояние сам).
4. Протокол: #33 чек-лист, приватный PLAN.md Этап 10 (этап 3 принят),
   update этого файла → этап 4 (CLI CRUD).

## Команды (кратко)

Подъём лабы — блок PowerShell в stage2/NEXT-SESSION.md (без изменений);
сборка пакета: `build-spike.sh /repo /tmp/apk.static 0.0.0-r99 /tmp/out`
(версия БЕЗ суффиксов — mkpkg строг). Паритет-гейт:
`docker run --rm -v <repo>:/repo:ro openwrt/rootfs:x86_64-25.12.5
sh /repo/docs/spike-ucode/stage3/apply-parity.sh`.
