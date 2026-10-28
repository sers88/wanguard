# Stage-4 handoff — dev готов, осталось живое окно (HITL)

Состояние на 2026-10-28. Dev- и лабовая части этапа 4 (#34) **готовы,
зелёные и запушены** на `spike/ucode`; до принятия — живое окно на
роутере (нужно присутствие владельца), затем тег/фид/протокол.

## Что готово

- `wand.uc`: **все 16 подкоманд нативно** — к wand-tick/wan-flush/
  probe-selftest (этапы 1–2) и apply (этап 3) добавлены list/add/move/
  remove/grouplist/devices/groupadd/groupset/groupdel/wanstatus/wanset/
  wanauto/backupset/help. Passthrough удалён: dispatch default = родной
  err «unknown command». `wanguard-sh` остаётся в пакете до этапа 5 как
  офлайн-машина отката, CLI его больше не вызывает.
- Паритет-гейт метода C4: `stage4/cli-parity.sh` — **638/638** (127
  дифференциальных пар fixtures: stdout/stderr/rc/UCI-байты/nft+ip-
  состояние байт-в-байт; референс-ассерты контракта; NAT-гейт
  `WANGUARD_SH=/nonexistent` на list/grouplist/apply). Харнесс поймал
  два реальных бага порта (stage4/NOTES.md §C): пробел после
  `backup order:` и хвостовой \n у SINCE-даты.
- Регресс не задет: sh 67/67, ucode F-сьют 55/55, apply-паритет 165/165.
- **Лаба C1–C6 под полностью нативным CLI — зелёная** (`stage4/LAB.md`):
  C4 теперь проверяет list/grouplist/wanstatus/devices как НАТИВНЫЙ код
  (в этапе 3 — passthrough, идентичность по построению); гейт
  нативности пройден по всем подкомандам; C6: тик 4.0 vs 54.0 спавнов.
  Находка лабы: dump() фикстурного netifd не включал имена вне
  фикстуры — почачен под реальную семантику netifd (`stage4/LAB.md`).
- Probe + уроки: `stage4/probe.sh` (v2), `stage4/NOTES.md` (A: ucode
  uci без add_list — set(conf,sid,opt,[array]); 2-арг get = тип секции;
  split = семантика awk; B: bind-mount над /proc/net/arp не работает —
  транспорт фикстуры = реальные neigh-записи ip-full, `nud stale` = 0x2).
- **Ранбук окна готов**: `stage4/window-runbook.md` (фазы 0/A–G, кит
  этапа 1 без изменений, таймбокс 30 мин; мутационная последовательность
  add/move/remove на согласованном MAC, drill freedom 3).

## Что дальше (только HITL)

1. **Окно на роутере** по `stage4/window-runbook.md`:
   savepoint 1.0.7 → установка 1.0.8 → гейты (нативность + паритет
   живого состояния + LuCI) → мутации → drill → soak по решению
   владельца.
2. После soak: merge `spike/ucode` → main → тег **v1.0.8** → CI → фид →
   на роутере явный `apk add wanguard=1.0.8-r1` (урок #32) → манифест →
   батарея → протокол в #34, PLAN.md Этап 10 (этап 4 принят).
3. Следующий этап — 5 (перенос 47 проверок + ретайр `wanguard-sh`).

## Команды (кратко)

Паритет-гейт:
`docker run --rm --cap-add=NET_ADMIN -v <repo>:/repo:ro
openwrt/rootfs:x86_64-25.12.5 sh /repo/docs/spike-ucode/stage4/cli-parity.sh`
(NET_ADMIN нужен для /proc/net/arp-фикстуры: dummy br-lan + neigh-записи
через ip-full; SYS_ADMIN не нужен — bind-mount над /proc/net/arp не
работает, см. NOTES §B1).

Лаба (PowerShell, WSL-интеграции docker нет — набор команд в
stage2/NEXT-SESSION.md; apk.static в
`C:\Users\sersb\AppData\Local\Temp\opencode\apk.static`), затем
`docker exec wanguard-lab sh /repo/docs/spike-ucode/lab/C?…sh`.
Гашение лабы:
`docker rm -f wanguard-lab wanguard-lab-net; docker network rm wanA wanB wanC`.

Регресс: run-tests-ucode.sh (55), stage3/apply-parity.sh (165),
tests/mock/run-tests.sh (67) — все в том же контейнере.
