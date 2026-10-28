# Stage-4 window runbook — CLI CRUD нативно (issues #30/#34)

**Скоуп окна:** только `/usr/bin/wanguard` (= `wand.uc`) обновляется до
версии со всеми 16 подкомандами нативно. `wanguard-sh` в пакете ОСТАЁТСЯ
(до этапа 5), keepalive/init.d/wan-watch/LuCI не меняются. Render-модель
(этап 3) не тронута — меняется только поверхность CLI.

**Таймбокс: 30 минут, жёсткий стоп.** Любой выход — L1 (rollback.sh из
savepoint, этап 1) за одну команду.

**Лестница отката:** как в stage-1 runbook (L0 freeze / L1 rollback.sh /
L2 +UCI / L3 apk-reinstall / L4 failsafe 192.168.1.1). Нюанс этапа 4:
savepoint снимается с фидового **1.0.7**, а там `/usr/bin/wanguard` уже
ucode (стадия 3) — **L1 возвращает байты 1.0.7** (apply нативный, CRUD
через passthrough в sh), «откат в sh» = L1 + L3 (офлайн-reinstall
сохранённого 1.0.6-apk невозможно — версии уходят из индекса; L3
переустанавливает сохранённый 1.0.7-apk из savepoint). Покомандного
отката нет и не нужно: passthrough удалён целиком, data plane не меняется. Отличие этапа 4:
L1 откатывает CLI целиком в sh —passthrough больше нет, покомандного
отката не требуется (риск ограничен поверхностью вывода, data plane
не меняется).

## Фаза 0 — артефакты, offline (до окна)

- собрать apk из этого коммита (apk/build.sh, версия 1.0.8) → манифест
  md5 под роутер-пути (stage1/make-manifest.sh);
- kit этапа 1 без изменений (make-savepoint.sh / drill.sh).

## Фаза A — baseline и savepoint (~5 мин)

1. На роутере: `wanguard list > /tmp/base.list`; `grouplist`, `devices`,
   `wanstatus > /tmp/base.*` (sh-эталон для сверки после апгрейда);
   батарея владельца 5/5.
2. savepoint (stage1/make-savepoint.sh) → /root/rollback/<ts>/.
3. Репетиция отката: rollback.sh туда-обратно, md5 7/7 оба направления.

## Фаза B — установка (~2 мин)

- `apk del wanguard-ucode 2>/dev/null; apk update && apk add wanguard=1.0.8-r1`
  (ЯВНАЯ версия — урок #32);
- md5-манифест 7/7 = байты фида.

## Фаза C — гейты (~6 мин)

```sh
# Гейт C4-нативность: sh-компаньон вне досягаемости на ВСЕХ путях:
WANGUARD_SH=/nonexistent wanguard list        # таблица + nft: in-sync
WANGUARD_SH=/nonexistent wanguard grouplist
WANGUARD_SH=/nonexistent wanguard wanstatus
WANGUARD_SH=/nonexistent wanguard devices
WANGUARD_SH=/nonexistent wanguard apply       # in-sync
# Гейт паритета живого состояния (те же конфиги и та же сеть):
#  вывод list/grouplist/wanstatus/devices == /tmp/base.* построчно
#  (допустимые расхождения: RTT/alive/SINCE в wanstatus — живые данные)
# Гейт LuCI: плата Network → WAN Guard рендерит грид/доску
#  (rpc file exec → list/devices), DRIFT-индикатор зелёный.
```

## Фаза D — репетиция отката (~4 мин, по желанию владельца)

- rollback.sh → sh-CLI вернулся, батарея 5/5;
- apk add wanguard=1.0.8-r1 снова → гейты C повторно зелёные.

## Фаза E — мутации на живом роутере (~5 мин)

Безопасная последовательность на тестовом MAC (или на согласованном
устройстве владельца):

```sh
wanguard add aa:bb:cc:dd:ee:f0 freedom window-test   # added ... + applied
wanguard move aa:bb:cc:dd:ee:f0 rostelecom           # moved ... + applied
wanguard remove aa:bb:cc:dd:ee:f0                    # removed ... + applied
wanguard backupset freedom rostelecom                # order-строка (если watched)
wanguard wanset rostelecom wan3 2>/dev/null || true  # только если есть смысл
wanguard wanauto rostelecom
```

- после каждого шага: `list` — строка на месте, `nft: in-sync`;
- LuCI: карточка появляется/переезжает/исчезает после F5.

## Фаза F — drill failover на реальном флипе (~10 мин)

- stage1/drill.sh freedom 3 (тот же кит, что в этапах 1–3):
  3 цикла, на каждом `applied`→`in-sync`, flush-события байт-формы
  `wand: flush:<g>><old>(<ip>)`;
- батарея владельца ×6 с клиента.

## Фаза G — завершение (~2 мин)

- лог keepalive тихий (кроме событий drill);
- `apk audit` чистый по файлам пакета;
- если всё зелёное — окно закрыто, soak по решению владельца
  (прецеденты этапов 1–3: сокращение допустимо).

## После soak — переход на фид (~10 мин)

merge `spike/ucode` → main → тег **v1.0.8** → CI → фид → на роутере
`apk update && apk upgrade` (или явный `apk add wanguard=1.0.8-r1`) →
манифест → батарея → протокол в #34, PLAN.md Этап 10 (этап 4 принят).

## Если что-то пошло не так

- Гейты C красные → L1: `rollback.sh` возвращает байты фида 1.0.7
  (ucode стадии 3: apply нативный, CRUD через passthrough), батарея,
  разбор офлайн. Прецедент: ни один этап не шёл вперёд с красными гейтами.
- L1 не трогает apk-DB: спайк остаётся установлен, владение файлами чинит
  L3 (`rollback.sh --apk`) или следующий фид-апгрейд.
- `apk add` той же версии = NO-OP (урок №1 этапа 1): re-spike и L3 требуют
  `apk del` перед `apk add`.
- `apk upgrade` пропустил пакет (урок #32) → явный
  `apk add wanguard=1.0.8-r1`.
- LuCI «unavailable» → `wanguard list` руками: DRIFT → rc 1 — это
  контракт; если DRIFT неожиданный — `wanguard apply`, затем LuCI F5.
