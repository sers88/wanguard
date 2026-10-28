# Stage-5 handoff — dev готов, осталось живое окно (HITL)

Состояние на 2026-10-28. Dev- и лабовая часть этапа 5 (#35) **готовы,
зелёные и закоммичены** на `spike/ucode`; до принятия — живое окно на
роутере (нужно присутствие владельца), затем тег/фид/протокол.

## Что готово

- **Полный порт проверок**: run-tests-ucode.sh = **87/87** — все 67
  sh-эквивалента (T1–T24, включая T14 wanset-flush, T19–T24 #26:
  conflict-checks, re-failover, backupset validation, wanstatus-порядок)
  + 20 ucode-нативных экстра (B1/B2, F1–F11). Интеграционный слой —
  по плану в лабе (сценарии + живые C2/C3/C4).
- **Ретайр sh**: `wanguard-sh` удалён из пакета (apk/build.sh) и из
  спайк-пакета (build-spike.sh); install-test.sh проверяет ОТСУТСТВИЕ
  файла и байты `/usr/bin/wanguard` == wand.uc; release-build переведён
  на cp+chmod (смок в контейнере, busybox без install(1)). Лаба держит
  дифференциальный метод через sh-референс по пути репо
  (`SHG=/repo/router/wanguard`) — сценарии и так его использовали.
- **Контракт-гейт без sh**: stage5/contract-gate.sh — 28/28, golden-байты
  list/grouplist/wanstatus/devices/apply/wan-flush/help против
  замороженного контракта (сняты с sh-паритетной реализации этапа 4;
  детерминизм: stateful-моки + real-neigh ARP, NET_ADMIN).
- **Регресс**: sh 67/67, apply-паритет 165/165, cli-паритет 639/639.
- **Лаба C1–C6 под пакетом без sh — зелёная** (stage5/LAB.md): C2 5/5,
  C3 re-failover с flush байт-формы на каждом хопе, C4 ×100 + байт-паритет
  четырёх выводов, C5 края, C6 4.0 vs 54.0 спавнов/тик (как в этапе 4).
- wand.uc vs v1.0.8: только комментарии — код CLI байт-в-байт принятого
  этапа 4. Находки этапа — stage5/NOTES.md (A1: нативному wanset нужен
  nft/ip на PATH в раннере — легаси-моки).
- **Ранбук окна готов**: stage5/window-runbook.md (фазы 0/A–G, кит
  этапа 1, таймбокс 30 мин; специфика: гейт формы пакета — apk обязан
  удалить wanguard-sh при апгрейде; манифест 6/6; откат = L1 байты 1.0.8
  / L3 офлайн-apk из savepoint).

## Что дальше (только HITL)

1. **Окно на роутере** по `stage5/window-runbook.md`: savepoint 1.0.8 →
   установка 1.1.0 → гейты (форма пакета: wanguard-sh ОТСУТСТВУЕТ +
   байт-паритет выводов против baseline 1.0.8 + LuCI) → мутации →
   drill → полная батарея 5/5 → soak по решению владельца.
2. После soak: merge `spike/ucode` → main → тег **v1.1.0** (решение
   владельца: изменения этапа 5 не минорные в целом — минорный бамп
   1.0.x → 1.1.0 вместо очередного патча; контракт заморожен, мажор
   не нужен) → CI → фид →
   на роутере явный `apk add wanguard=1.1.0-r1` (урок #32) → манифест →
   батарея → протокол в #35, PLAN.md Этап 10 (этап 5 принят, миграция
   завершена), финализировать пометку в VERDICT.md.
3. Docs: финал ARCHITECTURE.md §7, README, удаление
   NEXT-SESSION-PROMPT.md, пометка VERDICT.md — **сделаны в этом же
   коммите** (описывают конечное состояние; при красном окне — откат
   правок документов вместе с веткой).

## Команды (кратко)

Контракт-гейт:
`docker run --rm --cap-add=NET_ADMIN -v <repo>:/repo:ro
openwrt/rootfs:x86_64-25.12.5 sh /repo/docs/spike-ucode/stage5/contract-gate.sh`

Регресс (тот же контейнер): run-tests-ucode.sh (87),
tests/mock/run-tests.sh (67), stage3/apply-parity.sh (165),
stage4/cli-parity.sh (639).

Лаба: подъём командами из stage5/LAB.md (PowerShell; apk.static в
`C:\Users\sersb\AppData\Local\Temp\opencode\apk.static`), затем
`docker exec wanguard-lab sh /repo/docs/spike-ucode/lab/C?…sh`.
Гашение:
`docker rm -f wanguard-lab wanguard-lab-net; docker network rm wanA wanB wanC`.
