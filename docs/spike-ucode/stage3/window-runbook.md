# Stage-3 window runbook — apply в ucode (issues #30/#33)

Короткое окно поверх отрепетированного кита этапа 1 (`docs/spike-ucode/stage1/`):
savepoint/drill/лестница — **без изменений**; здесь отличия и гейты #33.

**Что меняется на роутере:** только байты `/usr/bin/wanguard` (= `wand.uc`
с нативным `apply`; `wanguard-sh` и остальные файлы пакета — те же). Нога
apply цикла keepalive `tick→apply→flush` больше не спускается в sh —
минус ~84 внешних спавна на каждый тик (98→14, лаба C6); `nft`/`ip`
остаются внешними вызовами **по дизайну**. Контракт с keepalive не меняется:
`apply` печатает литерал `in-sync` / `applied` (строка 17–22 keepalive парсит
вывод как раньше). Байт-паритет доказан дважды: на моках (165/165,
`stage3/apply-parity.sh`) и в живой лабе (C1–C6 зелёные, `stage3/LAB.md` —
флипы таблицы 400, keepalive ×100 = 1 applied + 99 in-sync).

**Таймбокс: 30 минут, жёсткий стоп.** Любой красный гейт → L1 → постмортем
в issue #33.

**Лестница отката:** как в stage-1 runbook (L0 freeze / L1 rollback.sh /
L2 +UCI / L3 apk / L4 failsafe). Savepoint снимается с роутера на фидовом
**1.0.6** — L1 возвращает и apply-ногу в sh (откат этапа 3 = возврат на
1.0.6). Дифференциальность реализаций здесь безопасна: sh `apply`
реконцилирует nft/ip-состояние сам (идемпотентный diff), менять руками
ничего не нужно.

---

## Фаза 0 — агент, offline (до окна)

- [ ] Пересобрать манифест в лабе (ver метится временем — sha256 каждый раз
      новый; гейт B сверяет с **своей** строкой):

      ```sh
      docker run --rm -v <repo>:/repo:ro -v <apk.static>:/tmp/apk.static:ro \
        openwrt/rootfs:x86_64-25.12.5 \
        sh /repo/docs/spike-ucode/stage1/make-manifest.sh /repo /tmp/stage3
      ```

      Артефакты: `/tmp/stage3/wanguard-ucode-<ver>.apk` +
      `/tmp/stage3/stage1-manifest.txt` (имя файла — наследие кита).
      Перед сборкой убедиться: паритет-гейт зелёный —

      ```sh
      docker run --rm -v <repo>:/repo:ro openwrt/rootfs:x86_64-25.12.5 \
        sh /repo/docs/spike-ucode/stage3/apply-parity.sh   # PASS=165 FAIL=0
      ```
- [ ] Залить на роутер в `/tmp/`: apk, манифест, `stage1/make-savepoint.sh`,
      `stage1/drill.sh` (команды scp печатает make-manifest.sh).
- [ ] Владелец подтвердил группу дрели (`freedom`) и время окна.

## Фаза A — baseline и savepoint (~5 мин)

Как в stage-1 (фаза A): батарея 5/5, `wanstatus` ANCHORS 3/3,
`list | tail -1` in-sync, wand-лог тихий, `sh /tmp/make-savepoint.sh`,
записать команду `sh /root/rollback/<ts>/rollback.sh`. Гейт A тот же.

Этап-3 добавка (якорь паритета живого состояния): на stock 1.0.6
`/usr/bin/wanguard` = sh CLI —

```sh
wanguard apply   # in-sync — живое nft/ip-состояние есть неподвижная точка sh
```

Запомнить: после установки спайка ТА ЖЕ команда должна сказать то же самое
(гейт C4).

## Фаза B — окружение (~2 мин)

```sh
ucode -e 'import * as fs; print("ucode ok\n")'
sha256sum /tmp/wanguard-ucode-*.apk   # = sha256-строка СВОЕГО манифеста
```

## Фаза C — установка кандидата (~6 мин)

```sh
/etc/init.d/wanguard stop
apk add --allow-untrusted --force-overwrite /tmp/wanguard-ucode-*.apk
grep -E '^[0-9a-f]{32}  /' /tmp/stage3/stage1-manifest.txt | md5sum -c -  # ГЕЙТ C1: все OK
head -1 /usr/bin/wanguard        # #!/usr/bin/ucode
wanguard probe-selftest          # ubus map согласован с wanstatus
wanguard list | tail -1          # ГЕЙТ C2: in-sync (passthrough жив)
# ГЕЙТ C3 (#33): apply исполняется НАТИВНО — passthrough увидел бы
# /nonexistent и упал; нативный apply в sh не спускается:
WANGUARD_SH=/nonexistent wanguard apply; echo rc=$?   # in-sync, rc=0
# ГЕЙТ C4 (паритет живого состояния): ucode-взгляд на ТО ЖЕ живое
# nft/ip-состояние, что sh видел в фазе A, — ноль расхождений:
wanguard apply                   # in-sync (не applied!)
# ГЕЙТ C5: на устаканенном состоянии диффа нет — дебат-режим молчит:
WANGUARD_DEBUG=1 wanguard apply  # только in-sync, БЕЗ строк nft-батча
```

Если C4 сказал `applied` — СТОП, красный гейт (ucode увидел расхождение
там, где sh был неподвижной точкой): L1, постмортем.

## Фаза D — репетиция отката (~4 мин, НЕ ПРОПУСКАТЬ)

Как в stage-1 (фаза D): `rollback.sh` → `md5sum -c .../md5sums-before.txt`
все OK → батарея 5/5 → `wanguard apply` = in-sync (снова sh) → спайк заново
(`apk del wanguard-ucode` + `apk add --allow-untrusted --force-overwrite`)
→ манифест снова все OK → гейты C3–C5 ещё раз.

## Фаза E — первые тики через keepalive (~3 мин)

```sh
/usr/bin/wanguard wand-tick; echo rc=$?   # тишина, rc=0
/usr/bin/wanguard apply                   # in-sync
/usr/bin/wanguard wan-flush; echo rc=$?   # тишина, rc=0
/etc/init.d/wanguard start
sleep 30
logread | grep wanguard | tail -10        # ГЕЙТ E: тихо (keepalive гонит
                                          # ucode-цикл: tick→apply→flush)
```

## Фаза F — учения: нативный apply на реальном флипе (~10 мин)

```sh
sh /tmp/drill.sh freedom 3    # короткое окно; владелец может продлить до 5
```

Цикл тот же (дренаж/force, батарея после каждого переключения). Гейты #33
после каждого флипа:

```sh
wanguard apply   # ГЕЙТ F0: applied (маршрут/правила переехали — ucode
                 # честно видел diff), и сразу:
wanguard apply   # ...снова in-sync (идемпотентность на живом состоянии)
WANGUARD_DEBUG=1 wanguard apply   # тишина: дифф закрыт
logread | grep wanguard-wand | tail -3
#   ГЕЙТ F1: flush:freedom>rostelecom(<ip>) — байт-форма #24, ip = старый egress
ls /tmp/wanguard/*.flush 2>/dev/null
#   ГЕЙТ F2: пусто — запрос потреблён после apply (протокол #24 закрылся)
```

Контроль рендера (опционально, один раз на окно):

```sh
nft -a list chain inet wanguard marking | grep freedom
#   тег wg:freedom:mN на месте, handle живой; таблица 400: default dev <новый dev>
```

Живая проба деградации apply (безопасная, при ОСТАНОВЛЕННОМ сервисе —
та же дисциплина, что F4 в stage-2 runbook):

```sh
/etc/init.d/wanguard stop
PATH=/usr/bin:/bin wanguard apply; echo rc=$?
#   ГЕЙТ F3: 'cannot create nft table' (или отсутствие nft/ip в PATH),
#   rc=1, НИЧЕГО не применено — -c-гейт/ensure_table сработали ДО изменений
/etc/init.d/wanguard start
wanguard apply   # in-sync — сервис вернулся без швов
```

> **ОСТОРОЖНО:** урезанный PATH обязан исключать и `nft`, и `ip` (в merged-usr
> OpenWrt это /usr/sbin — в /usr/bin:/bin не попадают). Проба проверяет
> fail-safe-путь «внешний инструмент недоступен → отказ ДО любых изменений».
> Никогда не роняйте nft/ip на живом сервисе с помпой — keepalive залогирует
> ошибку каждый тик.

**ГЕЙТ F:** 3/3 цикла зелёные; после каждого флипа applied→in-sync;
flush-события байт-формы; `.flush` пуст после apply; деградация отказала
до изменений; финальный блок drill чистый.

## Фаза G — закрытие (~2 мин)

`wanstatus` ANCHORS 3/3; wand-лог тихий; `list | tail -1` in-sync.
Кандидат **остаётся жить** (soak ~24 ч): раз в полдня `wanstatus` + батарея
+ `wanguard apply` = in-sync. `apk del wanguard-ucode` НЕ делать.

---

## После soak — переход на фид (короткое окно, ~10 мин)

1. Агент: merge `spike/ucode` → main, тег `v1.0.7` → CI → фид
   (`apk/build.sh` собирает stage-3 форму: `/usr/bin/wanguard` = wand.uc
   с нативными wand-tick + wan-flush + apply, `wanguard-sh` рядом).
2. На роутере (уроки окон 2026-10-25/26):

   ```sh
   apk del wanguard-ucode        # общие файлы падают с диска на ~100 с —
                                 # keepalive логает not found и ретраится,
                                 # сеть живёт (UCI/nft не тронуты)
   apk update
   apk add wanguard=1.0.7-r1     # УРОК #32: только ЯВНАЯ версия из тега —
                                 # `apk upgrade` может пропустить пакет
   grep -E '^[0-9a-f]{32}  /' /tmp/stage3/stage1-manifest.txt | md5sum -c -
   #   байты из фида = байты приёмки (wand.uc в пакете = тот же коммит)
   wanguard apply && WANGUARD_SH=/nonexistent wanguard apply   # нативный
   ```
3. Батарея 5/5, ANCHORS 3/3. Откат с фида: `apk add wanguard=1.0.6-r1`
   невозможно (версии уходят из индекса фида) — только офлайн-apk из
   savepoint: `apk add --allow-untrusted --force-overwrite
   /root/rollback/<ts>/wanguard-1.0.6-r1.apk`.
4. Агент: комментарий-протокол в issue #33, закрытие; приватный репо —
   PLAN.md (Этап 10, этап 3 принят). Дальше — этап 4 (CLI CRUD).

## Что считать успехом окна

Нативный гейт (`WANGUARD_SH=/nonexistent wanguard apply` → in-sync) зелёный;
паритет живого состояния — sh в фазе A и ucode в фазе C оба in-sync на одном
и том же nft/ip-состоянии, ноль шевелений; 3/3 реальных цикла с applied→in-sync
после каждого флипа, `flush:freedom>rostelecom(<ip>)` в логе и пустым
`*.flush` после apply; деградация без nft/ip отказала до изменений; md5-манифест
зелёный; откат отрепетирован туда-обратно; ни одного красного гейта.
