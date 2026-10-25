# Stage-2 window runbook — wan-flush + conntrack в ucode (issues #30/#32)

Короткое окно поверх отрепетированного кита этапа 1 (`docs/spike-ucode/stage1/`):
savepoint/drill/лестница — **без изменений**; здесь только отличия и гейты #32.

**Что меняется на роутере:** только байты `/usr/bin/wanguard` (= `wand.uc`
с нативным `wan-flush`; `wanguard-sh` и остальные файлы пакета — те же).
Нога flush цикла keepalive `tick->apply->flush` больше не спускается в sh;
`conntrack -D -q` остаётся внешним вызовом. Байт-паритет доказан в лабе
(C3: `flush:<g>><old>(<ip>)` байт-в-байт vs sh на каждом хопе; F9: дифференциал
на идентичном состоянии; C1–C6 зелёные на `spike/ucode` c48f40b).

**Таймбокс: 30 минут, жёсткий стоп.** Любой красный гейт → L1 → постмортем
в issue #32.

**Лестница отката:** как в stage-1 runbook (L0 freeze / L1 rollback.sh /
L2 +UCI / L3 apk / L4 failsafe). Отличие: savepoint снимается с роутера на
фидовом **1.0.5**, значит L1 возвращает и flush-ногу в sh — откат этапа 2
это и есть возврат на 1.0.5, отдельного sh-пакета ставить не нужно.

---

## Фаза 0 — агент, offline (до окна)

- [ ] Пересобрать манифест в лабе (ver метится временем — sha256 каждый раз
      новый; гейт B сверяет с **своей** строкой):

      ```sh
      docker run --rm -v <repo>:/repo:ro -v <apk.static>:/tmp/apk.static:ro \
        openwrt/rootfs:x86_64-25.12.5 \
        sh /repo/docs/spike-ucode/stage1/make-manifest.sh /repo /tmp/stage2
      ```

      Артефакты: `/tmp/stage2/wanguard-ucode-<ver>.apk` +
      `/tmp/stage2/stage1-manifest.txt` (имя файла — наследие кита).
- [ ] Залить на роутер в `/tmp/`: apk, манифест, `stage1/make-savepoint.sh`,
      `stage1/drill.sh` (команды scp печатает make-manifest.sh).
- [ ] Владелец подтвердил группу дрели (`freedom`) и время окна.

## Фаза A — baseline и savepoint (~5 мин)

Как в stage-1 (фаза A): батарея 5/5, `wanstatus` ANCHORS 3/3,
`list | tail -1` in-sync, wand-лог тихий, `sh /tmp/make-savepoint.sh`,
записать команду `sh /root/rollback/<ts>/rollback.sh`. Гейт A тот же.

## Фаза B — окружение (~2 мин)

```sh
ucode -e 'import * as fs; print("ucode ok\n")'
sha256sum /tmp/wanguard-ucode-*.apk   # = sha256-строка СВОЕГО манифеста
```

## Фаза C — установка кандидата (~5 мин)

```sh
/etc/init.d/wanguard stop
apk add --allow-untrusted --force-overwrite /tmp/wanguard-ucode-*.apk
grep -E '^[0-9a-f]{32}  /' /tmp/stage2/stage1-manifest.txt | md5sum -c -  # ГЕЙТ C1: все OK
head -1 /usr/bin/wanguard        # #!/usr/bin/ucode
wanguard probe-selftest          # ubus map согласован с wanstatus
wanguard list | tail -1          # ГЕЙТ C2: in-sync (passthrough жив)
# ГЕЙТ C3 (#32): wan-flush исполняется НАТИВНО — passthrough увидел бы
# /nonexistent и упал; нативный путь в шишку не стреляет:
WANGUARD_SH=/nonexistent wanguard wan-flush; echo rc=$?   # тишина, rc=0
```

## Фаза D — репетиция отката (~4 мин, НЕ ПРОПУСКАТЬ)

Как в stage-1 (фаза D): `rollback.sh` → `md5sum -c .../md5sums-before.txt`
все OK → батарея 5/5 → спайк заново (`apk del wanguard-ucode` +
`apk add --allow-untrusted --force-overwrite`) → манифест снова все OK.

## Фаза E — первые тики через keepalive (~3 мин)

```sh
/usr/bin/wanguard wand-tick; echo rc=$?   # тишина, rc=0
/usr/bin/wanguard apply                   # in-sync
/usr/bin/wanguard wan-flush; echo rc=$?   # тишина, rc=0
/etc/init.d/wanguard start
sleep 30
logread | grep wanguard | tail -10        # ГЕЙТ E: тихо
```

## Фаза F — учения: apply+flush на реальном флипе (~15 мин)

```sh
sh /tmp/drill.sh freedom 3    # короткое окно; владелец может продлить до 5
```

Цикл тот же (дренаж/force, батарея после каждого переключения). Гейты #32
после каждого флипа:

```sh
logread | grep wanguard-wand | tail -3
#   ГЕЙТ F1: flush:freedom>rostelecom(<ip>) — байт-форма #24, ip = старый egress
ls /tmp/wanguard/*.flush 2>/dev/null
#   ГЕЙТ F2: пусто — запрос потреблён после apply (протокол #24 закрылся)
```

Живые пробы деградации (обе безопасные, порядок именно такой):

```sh
echo nosuchiface > /tmp/wanguard/x.flush
wanguard wan-flush; echo rc=$?
#   ГЕЙТ F3: тишина, rc=0 — нет ни адреса, ни события; файл потреблён
PATH=/usr/bin:/bin wanguard wan-flush   # (сначала положи запрос:)
echo freedom > /tmp/wanguard/freedom.flush
PATH=/usr/bin:/bin wanguard wan-flush; echo rc=$?
#   ГЕЙТ F4: без conntrack в PATH — тишина, rc=0, файл потреблён
ls /tmp/wanguard/*.flush 2>/dev/null    # пусто
```

> **ОСТОРОЖНО:** никогда не клади руками `<реальный iface>.flush` с conntrack
> в PATH — `wan-flush` честно выполнит `conntrack -D` по живому egress и
> снесёт NAT-биндинги реальных сессий. Проба F3 безопасна всегда (имя не
> резолвится), проба F4 — потому и с урезанным PATH (до conntrack дело не
> доходит).

**ГЕЙТ F:** 3/3 цикла зелёные, flush-события байт-формы на каждом хопе,
`.flush` пуст после apply, деградации молчат, финальный блок drill чистый.

## Фаза G — закрытие (~2 мин)

`wanstatus` ANCHORS 3/3; wand-лог тихий; `list | tail -1` in-sync.
Кандидат **остаётся жить** (soak ~24 ч): раз в полдня `wanstatus` + батарея.
`apk del wanguard-ucode` НЕ делать.

---

## После soak — переход на фид (короткое окно, ~10 мин)

1. Агент: merge `spike/ucode` → main, тег `v1.0.6` → CI → фид
   (`apk/build.sh` уже собирает stage-2 форму: `/usr/bin/wanguard` = wand.uc
   с нативным wan-flush + `wanguard-sh` рядом).
2. На роутере (уроки окна 2026-10-25: спайк из БД вычищать ДО апгрейда,
   после del файлы на диске отсутствуют секунды — keepalive переживает):

   ```sh
   apk del wanguard-ucode
   apk update && apk upgrade      # wanguard 1.0.5-r1 -> 1.0.6-r1 из фида
   apk fix wanguard               # страховка пере-извлечения (урок NO-OP add)
   grep -E '^[0-9a-f]{32}  /' /tmp/stage2/stage1-manifest.txt | md5sum -c -
   #   байты из фида = байты приёмки (wand.uc в пакете = тот же коммит)
   ```
3. Батарея 5/5, ANCHORS 3/3. Откат с фида: `apk add --force-overwrite
   wanguard=1.0.5-r1` или офлайн-apk из savepoint.
4. Агент: комментарий-протокол в issue #32, закрытие; приватный репо —
   PLAN.md (Этап 10, этап 2 принят).

## Что считать успехом окна

3/3 реальных цикла с `flush:freedom>rostelecom(<ip>)` в логе и пустым
`*.flush` после apply; деградации (нет адреса / нет conntrack) молчат и
потребляют файл; md5-манифест зелёный; откат отрепетирован туда-обратно;
ни одного красного гейта.
