# Stage-3 handoff — осталось только живое окно (HITL)

Состояние на 2026-10-27 (вечер). Dev- И лабовая части этапа 3 (#33)
**готовы, зелёные и запушены**; до принятия — живое окно на роутере
(нужно присутствие владельца), затем фид/протокол.

## Что готово

- `wand.uc`: `apply` нативно (полный порт cmd_apply); dispatch: `apply`
  нативный, остальные 14 подкоманд — passthrough. Keepalive-цикл
  tick→apply→flush — ucode end-to-end.
- Паритет-гейт на моках: `stage3/apply-parity.sh` — **165/165** с нативным
  apply (16 фикстур #33; stdout/rc/батч/nft+ip-состояние байт-в-байт).
- **Лаба C1–C6 под нативным apply — зелёная** (`stage3/LAB.md`): C2 5/5
  флипов table 400 eth0↔eth1, C3 wan1→wan3→wan2→wan1 с flush-событиями
  байт-в-байт, C4 keepalive ×100 = **1 applied + 99 in-sync**, C5 края,
  C6: apply **14.0 vs 98.0** спавнов (7×), tick 4.0 vs 54.0 (13.5×),
  wall 4.4×. Вход в батарею — гейт нативности
  `WANGUARD_SH=/nonexistent wanguard apply` → in-sync.
- Регресс не задет: sh 67/67, ucode 55/55, smoke-nft 32/32, smoke-ip 25/25.
- Уроки порта: `stage3/NOTES.md` §F (моки/харнесс) и §G (восемь ucode-квирков);
  пробы реального nft/ip — §A–E.
- **Ранбук окна готов**: `stage3/window-runbook.md` (фазы A–G, гейты C3/C4 —
  нативность и паритет живого состояния, F0 applied→in-sync на каждом флипе,
  F3 fail-safe без nft/ip; кит этапа 1 без изменений; таймбокс 30 мин).
- Коммиты: 65b9e14 моки → eac7fbd пробы → 7701e92 харнесс → 7a1d1ba
  нативный apply → 5032704 handoff v1 → лаба/runbook (этот коммит).

## Что дальше (только HITL)

1. **Окно на роутере** по `stage3/window-runbook.md`:
   фаза 0 (манифест + apk + кит на роутер) → A savepoint на 1.0.6 →
   B sha256 → C установка + гейты C1–C5 → D репетиция отката →
   E тихие тики → F drill `freedom 3` с applied→in-sync на каждом флипе →
   G soak ~24 ч.
2. После soak: merge `spike/ucode` → main → тег **v1.0.7** → CI → фид →
   на роутере `apk del wanguard-ucode && apk update && apk add
   wanguard=1.0.7-r1` (ЯВНАЯ версия — урок #32) → манифест → батарея →
   протокол в #33, PLAN.md Этап 10 (этап 3 принят).
3. Следующий этап — 4 (CLI CRUD).

## Команды (кратко)

Паритет-гейт: `docker run --rm -v <repo>:/repo:ro openwrt/rootfs:x86_64-25.12.5
sh /repo/docs/spike-ucode/stage3/apply-parity.sh`. Лаба: сети wanA/wanB/wanC +
якорь + `lab/setup.sh` (блок PowerShell в stage2/NEXT-SESSION.md; apk.static в
`C:\Users\sersb\AppData\Local\Temp\opencode\apk.static`), затем C1..C6 через
`docker exec wanguard-lab sh /repo/docs/spike-ucode/lab/C?….sh`. Сборка
спайк-пакета: `build-spike.sh /repo /tmp/apk.static 0.0.0-r99 /tmp/out`
(версия БЕЗ суффиксов — mkpkg строг). Гашение лабы:
`docker rm -f wanguard-lab wanguard-lab-net; docker network rm wanA wanB wanC`.
