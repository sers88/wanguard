# Stage 5 dev notes — test-suite port + sh retirement (issues #30/#35)

Дата: 2026-10-28. Dev- и лабовая часть этапа 5. Всё офлайн: контейнеры
openwrt/rootfs:x86_64-25.12.5 + docker-лаба. Роутер не тронут — финальное
живое окно отдельно (window-runbook.md).

## A. Перенос проверок: sh-сьют 67 → ucode-раннер (run-tests-ucode.sh)

Состояние до этапа: 55 проверок (репрезентативный порт T1,T2,T4–T10,
B1/B2, F1–F11). Не хватало **32 эквивалентов** sh-проверок; после этапа —
**87 проверок = все 67 sh-эквивалента + 20 ucode-нативных экстра**.

Порт-карта (sh → ucode, всё в run-tests-ucode.sh):

| sh | ucode | примечание |
|---|---|---|
| T1.3 wanstatus alive/total | `cli wanstatus` case-match | нативный wanstatus (этап 4) |
| T3 legacy anchors | 1:1 | |
| T4.3–5 down x3 / 5 oks / 6 oks | 1:1 + `remap_anchor` | восстановление независимо от переключений |
| T5.2 optimistic-up | 1:1 | |
| T6.2 reliability=0 | 1:1 | |
| T14 wanset-flush ×3 | W1 через `cli wanset` | см. находку A1 |
| T19 dead head skipped | 1:1 + `cli backupset` | |
| T20 conflict-checks ×5 | 1:1, raw add_list — РЕАЛЬНЫЙ `uci add_list` | |
| T21 default alphabetical | 1:1 | |
| T22 re-failover ×5 | 1:1 + lastswitch-байпасы | трюк T9 (ucode: реальный time()) |
| T23 backupset validation ×7 | 1:1 через `cli backupset` | |
| T24 wanstatus backup order ×2 | 1:1 (awk $5/$6) | |

Интеграционный слой НЕ переносится в раннер — он и есть лаба: сценарии
(`scenario.sh`/`scenario26.sh`, байт-паритет) + живые C2/C3/C4. Это
соответствует плану #30 («интеграционные → в лабу»).

### Находки

- **A1 (поймано гейтом, не на живой ветке):** нативный `wanset` (этап 4)
  тянет хвостовой `apply()` — в раннере на PATH не было nft/ip, и
  `ensure_table` падал в `fail()` ДО conntrack-flush (симптом: пустой
  CONNTRACKLOG при зелёном «pinned»). Лечение: моки nft/ip добавлены в
  шим раннера — их **легаси-нооп режим** (NFT_STATE/IP_STATE unset) ровно
  для этого и спроектирован; render-паритет остаётся за stage3/stage4
  харнессами. Комментарий в шапке раннера.
- Двухфазность T22: байпас dwell нужен ПЕРЕД re-failover (после
  failover-флипа lastswitch=now) и ещё раз перед восстановлением —
  sh-сьют этого не требует (мок-date шагает +60/вызов), ucode живёт по
  реальным time(). Задокументировано в комментариях теста.

## B. Ретайр sh

- `apk/build.sh`: `/usr/bin/wanguard-sh` удалён из пакета; шейп этапа 5
  задокументирован; откат = переустановка apk предыдущего тега (единый
  механизм; UCI/state общие). Попутно `install(1)` → `cp+chmod` (в
  контейнерном busybox нет install(1), грабля №4 спайка — теперь release
  скрипт смокается в контейнере; на CI без разницы).
- `build-spike.sh`: то же для спайк-пакета (лаба = зеркало шейпа пакета).
- `install-test.sh`: устаревшая passthrough-паритетность (этап 1)
  заменена проверкой ФОРМЫ пакета: `/usr/bin/wanguard-sh` отсутствует,
  `/usr/bin/wanguard` = ucode, байты == wand.uc.
- Лаба: `setup.sh` рендерит нативным CLI; C2/C3/C4/C6 держат
  дифференциальный метод — sh-референс по пути **репо**
  (`SHG=/repo/router/wanguard`), которого в пакете больше нет. Контракт
  же гейтится без sh (см. C).
- Сценарии `scenario.sh`/`scenario26.sh` уже ссылались на репо-путь —
  не менялись.
- sh-исходник `router/wanguard` в репо ОСТАЁТСЯ (дифференциальный
  референс лабы; в git-истории — навсегда). Из пакета он уходит.

## C. Контракт-гейт (stage5/contract-gate.sh + golden/)

После ретайра принимать `list/grouplist/wanstatus/devices` «против sh»
невозможно — его нет. Гейт этапа 5: **golden-байты против замороженного
контракта**. Метод:

1. Байты сняты (CAPTURE=1) с реализации этапа 4 — той самой, чья
   байт-идентичность sh доказана кли-паритетом (127 диф-пар,
   stdout/stderr/rc/UCI/nft+ip). Заморозка этих байт = заморозка
   контракта; любой будущий дифф — ревьюируемое изменение контракта.
2. Кейсы: L-in (list заполненный in-sync), L-drift (DRIFT + rc 1),
   GL (grouplist: proxy Meta / direct up / direct down), D (devices:
   leases+ARP merge, real-neigh фикстура), WS (wanstatus: rtt/alive/
   since/forced + backup-порядок), APL (apply на синхроне = ровно
   `in-sync`), FLE (flush-событие байт-формы + conntrack -D -q по старому
   egress), FLI (тихий повтор), H (help). 10 кейсов × {out,err,rc}.
3. Субъект — `ucode -L mock wand.uc`, та же инвокация, что ставится
   пакетом в /usr/bin/wanguard (шебанг-путь отдельно смоукан
   install-test.sh и лабовой C4 на установленном CLI).
4. Детерминизм: stateful-моки nft/ip (stage-3 харнесс), date-стаб
   (фиксированная строка для `-d @N`), real-neigh ARP через ip-full
   (NET_ADMIN). Повтор в свежем контейнере = 28/28.

## D. Регресс и батарея (всё зелёное, 2026-10-28)

| Гейт | Результат |
|---|---|
| sh-сьют tests/mock/run-tests.sh | 67/67 |
| ucode-сьют run-tests-ucode.sh | **87/87** (67 эквивалентов + экстра) |
| stage3/apply-parity.sh | 165/165 |
| stage4/cli-parity.sh | 639/639 |
| stage5/contract-gate.sh | 28/28 (свежий контейнер) |
| install-test.sh (спайк-пакет) | OK, wanguard-sh absent |
| release build.sh + шейп-чек | OK, /usr/bin/wanguard == wand.uc байт-в-байт |
| лаба C1–C6 (пакет без sh) | зелёная — см. LAB.md |

## E. Дельта wand.uc vs v1.0.8

Только комментарии (шапка + блок dispatch): код CLI байт-в-байт равен
принятому на этапе 4. Реальные изменения этапа 5 — НАБОР ФАЙЛОВ ПАКЕТА
(минус wanguard-sh) и тестовая обвязка. Живой риск окна — переезд
apk-владения /usr/bin/wanguard-sh (удаление файла при upgrade), см.
window-runbook.md.
