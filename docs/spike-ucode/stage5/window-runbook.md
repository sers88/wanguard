# Stage-5 window runbook — ретайр wanguard-sh (issues #30/#35)

**Версия: 1.1.0-r1, тег v1.1.0** (решение владельца, 2026-10-28): изменения
этапа 5 **не минорные в целом** — завершение миграции ядра (тесты + ретайр
sh), поэтому версия поднимается другим порядком: минорный бамп 1.0.x →
1.1.0, а не очередным патчем. Мажор не нужен: контракт заморожен байт-в-байт
(keepalive/init.d/LuCI/операторские привычки не меняются, data plane тот же).

**Скоуп окна:** финал миграции — на роутер ставится пакет, в котором
`/usr/bin/wanguard` = чистый ucode-CLI, а `/usr/bin/wanguard-sh`
**удалён из пакета**. Код CLI байт-в-байт равен принятому на этапе 4
(v1.0.8) — дельта wand.uc только в комментариях; реальное изменение —
НАБОР ФАЙЛОВ ПАКЕТА и переезд apk-владения wanguard-sh. keepalive/
init.d/wan-watch/LuCI не меняются (замороженный контракт).

**Таймбокс: 30 минут, жёсткий стоп.** Любой выход — L1 (rollback.sh из
savepoint) за одну команду.

**Лестница отката:** L0 freeze / L1 rollback.sh / L2 +UCI / L3
apk-reinstall / L4 failsafe 192.168.1.1 (кит этапа 1 без изменений).
Нюансы этапа 5:

- savepoint снимается с фидового **1.0.8** — там CLI уже ucode (все 16
  подкоманд нативно), рядом живёт wanguard-sh. **L1 возвращает байты
  1.0.8** (уже принятая конфигурация этапа 4) — это и есть «откат на
  предыдущий тег» в файловой форме.
- «Откат в sh» больше не существует как отдельный режим: sh-CLI выведен
  из пакета. Если понадобится ГОЛОС sh — это L3: офлайн-reinstall
  сохранённого 1.0.8-apk (`rollback.sh --apk`) и далее вниз по тегам
  (1.0.5–1.0.8 = ucode, ≤1.0.4 = sh-пакет целиком; старые версии из
  индекса фида уходят — apk берём только из savepoint).
- L1 не трогает apk-DB (урок этапа 1): после L1 на диске лежит
  wanguard-sh, которого в 1.1.0 нет — владение чинит L3 или следующий
  фид-апгрейд. Это то же документированное расхождение, что и в
  этапах 1–4.

## Фаза 0 — артефакты, offline (до окна)

- apk из этого коммита: `apk/build.sh <repo> <apk.static> 1.1.0-r1 <out>`
  (сборка смокана в контейнере: файлы манифеста + отсутствие
  wanguard-sh + байты /usr/bin/wanguard == wand.uc);
- манифест md5 под роутер-пути (6 файлов пакета 1.1.0):

```sh
for f in docs/spike-ucode/wand.uc:/usr/bin/wanguard \
         router/wanguard-keepalive:/usr/bin/wanguard-keepalive \
         router/wan-watch:/usr/bin/wan-watch \
         router/init.d/wanguard:/etc/init.d/wanguard \
         router/init.d/wan-watch:/etc/init.d/wan-watch \
         router/wanguard.nft:/usr/share/wanguard/wanguard.nft; do
  printf '%s  %s\n' "$(md5sum "/repo/${f%%:*}" | cut -d' ' -f1)" "${f##*:}"
done
```

- kit этапа 1 без изменений (make-savepoint.sh / drill.sh).

## Фаза A — baseline и savepoint (~5 мин)

1. На роутере (эталон замороженного контракта на живом состоянии):
   `wanguard list > /tmp/base.list`; `grouplist`, `devices`,
   `wanstatus > /tmp/base.*`; md5 текущего /usr/bin/wanguard (должен
   равняться байтам приёмки этапа 4: 869d9a81…);
   батарея владельца 5/5.
2. savepoint (stage1/make-savepoint.sh) → /root/rollback/<ts>/.
3. Репетиция отката: rollback.sh туда-обратно, md5 7/7 оба направления.

## Фаза B — установка (~2 мин)

- кандидат собран из этого коммита и залит на роутер (/tmp);
  `apk add --allow-untrusted /tmp/wanguard-1.1.0-r1.apk` — в фиде 1.1.0
  появится только после тега, поэтому окно ставит локальный кандидат
  КАК `wanguard` 1.1.0-r1 (без спайк-имени: форма пакета финальная уже
  в окне, apk-DB чистится обычным путём);
- **гейт формы пакета**: `test ! -e /usr/bin/wanguard-sh && echo RETIRED-OK`
  (apk обязан удалить файл старой версии при апгрейде — если файл
  остался, СТОП, разбор до продолжения);
- md5-манифест **6/6** = байтам приёмки; шебанг `#!/usr/bin/ucode`.

## Фаза C — гейты (~6 мин)

```sh
# CLI без изменений (код == 1.0.8): выводы байт-в-байт против baseline
wanguard list      | cmp - /tmp/base.list       # построчно, expect identical
wanguard grouplist | cmp - /tmp/base.grouplist
wanguard devices   | cmp - /tmp/base.devices
wanguard wanstatus                           # живые данные: сравнить глазами
#   (допустимые расхождения: RTT/alive/SINCE/ANCHORS — живое состояние)
wanguard apply                               # ровно in-sync
# contract-байты против ЗАМОРОЖЕННОГО контракта: на живом состоянии
# baseline 1.0.8 и есть эталон — совпадение с ним = совпадение с
# контрактом (в лабе то же самое доказано golden-файлами
# stage5/contract-gate.sh 28/28 против байт, снятых с sh-паритетной
# реализации этапа 4).
# LuCI: плата Network → WAN Guard рендерится, DRIFT зелёный.
```

## Фаза D — репетиция отката (~4 мин, по желанию владельца)

- rollback.sh → байты 1.0.8 (7/7, wanguard-sh вернулся), батарея 5/5;
- `apk add wanguard=1.1.0-r1` снова → гейт формы пакета + гейты C
  повторно зелёные (перед повторным add убедиться, что версия сменилась:
  `apk add` той же установленной версии = NO-OP, урок №1 этапа 1 —
  после rollback.sh стоит `apk del wanguard` … нет: НЕ делать
  `apk del` (сносит общие файлы, урок этапа 1 №2); путь: rollback.sh
  возвращает файлы 1.0.8 при apk-DB 1.1.0 → повторный переход вперёд
  делаем `apk add wanguard=1.1.0-r1` после `apk fix wanguard` (урок
  этапа 1 №3: fix пере-извлекает установленный пакет из фида).

## Фаза E — мутации на живом роутере (~5 мин)

Безопасная последовательность на тестовом MAC (или согласованном
устройстве владельца) — приёмка CLI-выводов LuCI-поверхности:

```sh
wanguard add aa:bb:cc:dd:ee:f0 freedom window-test   # added ... + applied
wanguard move aa:bb:cc:dd:ee:f0 rostelecom           # moved ... + applied
wanguard remove aa:bb:cc:dd:ee:f0                    # removed ... + applied
wanguard backupset freedom rostelecom                # order-строка
wanguard wanauto freedom
```

- после каждого шага: `list` — строка на месте, `nft: in-sync`;
- LuCI: карточка появляется/переезжает/исчезает после F5.

## Фаза F — финальный drill (~10 мин)

- stage1/drill.sh freedom 3: failover → failback циклы; на каждом
  `applied`→`in-sync`, flush-события байт-формы
  `wand: flush:<g>><old>(<ip>)`;
- **ре-failover — на тест-группе zz без членов** (`groupadd zz <iface>`;
  имя ПОСЛЕ всех по алфавиту → сдвига меток нет): дренаж home →
  failover zz к первому в списке; дренаж того → РЕ-failover к
  следующему; батарея (ноль клиентского трафика); `groupdel zz` —
  живая сирот-чистка (set/table/ip-rule). НЕ сверлить ре-failover
  прод-группой на wg_moscow — это туннель, не провайдер (вне
  failover-схемы, заметки 2026-10-22/24);
- **полная батарея владельца 5/5** после каждого переключения:
  failover/failback/re-failover/flush/CLI-выводы LuCI.

## Фаза G — завершение (~2 мин)

- лог keepalive тихий (кроме событий drill);
- `apk audit` чистый (аудит принимает ДИРЕКТОРИИ: `apk audit /usr/bin
  /etc/init.d /usr/share/wanguard` → rc=0);
- `wanguard wanstatus`: ANCHORS 3/3;
- окно закрыто, soak по решению владельца (прецеденты этапов 1–4).

## После soak — переход на фид (~10 мин)

merge `spike/ucode` → main → тег **v1.1.0** → CI → фид → на роутере
`apk update && apk fix wanguard` (окно ставило локального кандидата
той же версии: `add` той же версии = NO-OP, урок №1 этапа 1; `fix`
пере-извлекает установленную версию из фида — урок №3 этапа 1) →
манифест → батарея → протокол в #35, PLAN.md Этап 10 (этап 5 принят,
миграция завершена), VERDICT.md-пометку финализировать.

## Если что-то пошло не так

- Гейт формы пакета красный (wanguard-sh остался) → apk-владение не
  переехало: L1 + разбор офлайн (воспроизводится в контейнере: upgrade
  1.0.8→1.1.0 на установленном 1.0.8).
- Гейты C красные → L1 (байты 1.0.8, принятая конфигурация этапа 4).
- `apk upgrade` пропустил пакет (урок #32) → явный
  `apk add wanguard=1.1.0-r1`.
- Полная потеря CLI (урок #32: ~100 c без /usr/bin/wanguard) — сеть
  живёт, keepalive отработает контракт; не прерывать окно.
