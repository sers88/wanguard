# Stage-5 window log — ретайр wanguard-sh (issues #30/#35)

**2026-10-28, 22:14–22:45 МСК (~30 мин, HITL, владелец за батареей; окно
агент-ведомое — батареи через WAND_BATTERY_FILE).** Кандидат:
`wanguard-1.1.0-r1.apk` (sha256 `cad8c2d6…`), собран из `spike/ucode` @
51d3f81. Версия 1.1.0 — решение владельца: изменения этапа 5 не минорные
в целом (завершение миграции ядра), минорный бамп вместо очередного
патча; контракт заморожен, мажор не нужен. Savepoint
`/root/rollback/20261028-221548/` (внутри feed-apk **1.0.8-r1** — L3-машина
отката). Baseline: wanguard 1.0.8-r1, md5 `/usr/bin/wanguard` =
`869d9a81…` (байты приёмки этапа 4), ANCHORS 3/3, все группы дома,
wand-лог тихий 2ч14м (попутно: сегодня в 19:57–20:00 был РЕАЛЬНЫЙ
failover/failback freedom под 1.0.8 — неявный соак; к окну отношения не
имеет). Батарея владельца 5/5 на входе (канонический редирект теперь
**t.me → 302** — telegram.org отдаёт 200, внешнее изменение мира).

## Результаты фаз

| Фаза | Гейты | Статус |
|---|---|---|
| A | baseline зафиксирован (в savepoint: state/md5/nft/ip-routes/лог); **репетиция отката**: rollback.sh → `restored: 869d9a81…` ТОЧНО, сервис поднялся, батарея 5/5 | OK |
| B | `apk add --allow-untrusted /tmp/wanguard-1.1.0-r1.apk` → Upgrading 1.0.8-r1 → 1.1.0-r1; **ГЕЙТ ФОРМЫ ПАКЕТА: `/usr/bin/wanguard-sh` ОТСУТСТВУЕТ — apk снёс файл старой версии**; md5-манифест **6/6** = байтам приёмки (`35bc422f/a9dd359d/039561bc/81e712b8/2c04f9d4/fd33a072`); шебанг `#!/usr/bin/ucode` | OK |
| C | **list + grouplist BYTE-IDENTICAL** базлайну из savepoint (снятым до апгрейда); devices — 4-колоночный таб-формат LuCI-контракта; `apply` = ровно `in-sync` rc=0; wand-tick/wan-flush тихие rc=0; **LuCI-путь**: `ubus call file exec` (rpc, ACL) парсит нативный list | OK |
| E | полный CRUD на тестовом MAC: add/move/remove (added+moved+removed, `applied` на каждом); backupset freedom rostelecom → order-строка + BACKUP-колонка в wanstatus; UCI после мутаций и чистки **байт-в-байт** savepoint (`1c86de75…`); наборы: 4 `mac_*` = 4 группы, сирот нет | OK |
| F | drill `freedom 3` = **3/3** (2×nft честный curl-путь + 1×force); 6 флипов, table 400 pptp-freedom ↔ pppoe-rosteleco живьём (`ip route get mark 0x64`); **батарея владельца 5/5 после КАЖДОГО переключения** (6 подтверждений); 6 flush-событий байт-формы с правильными старыми egress (`217.25.226.49` / `100.102.56.184`); cleanup чистый | OK |
| F2 | **ре-failover на тест-группе zz** (решение владельца — см. находку 1): zz(500/403, wg_moscow, 0 членов) → дренаж wg → `failover:zz>freedom` (table 403 → pptp-freedom) → дренаж freedom → **`failover:zz>rostelecom` +30с** (table 403 → pppoe-rosteleco) — ре-failover #26 на железе; батарея 5/5; снятие дренажей → все 3 группы дома за 60с; `groupdel zz` → **сирот-чистка живьём**: set mac_zz flush+delete, table 403 вытерта, ip rule 8103 снят; UCI **байт-в-байт** `1c86de75…` | OK |
| G | leftovers нет (force/drill_drain/drill_rf); все группы дома; list in-sync; манифест 6/6; `apk audit` чистый (/usr/bin, /etc/init.d, /usr/share/wanguard → rc=0); ANCHORS 3/3 | OK |

Событийный след F2 (полный #26+#24 протокол, байт-форма):

```
22:36:41 seed:zz>wg_moscow
22:37:14 down:wg_moscow failover:wg_moscow>freedom failover:zz>freedom
         flush:…>wg_moscow(192.168.6.3)          ← старый egress = адрес wg-туннеля
22:40:00 down:freedom failover:freedom>rostelecom failover:wg_moscow>rostelecom
         failover:zz>rostelecom                   ← РЕ-FAILOVER (backup умер, home мёртв)
         flush:…>freedom(217.25.226.49)
22:41:17 up:freedom up:wg_moscow failback:… (все три) flush:…>rostelecom(100.102.56.184)
```

## Живые находки окна

1. **ре-failover сверлился на тест-группе zz, не на проде** (решение
   владельца в окне): прод-клиентов freedom нельзя гнать на wg_moscow —
   это WireGuard-туннель, НЕ провайдер, вне failover-схемы (заметки
   2026-10-22/24). zz без членов = ноль клиентского трафика, полный
   state-machine/UCI/apply/flush путь на железе; бонус — живая
   сирот-чистка при groupdel. Первая попытка (ре-failover прод-группы
   freedom на wg_moscow) остановлена владельцем на этапе подготовки
   второго дренажа — правило не успело примениться (nft-цитирование
   съело пробелы комментария), возврат чистый.
2. **Кандидат ставится как `wanguard` 1.1.0-r1 локально
   (`--allow-untrusted`)** — в фиде 1.1.0 появится только после тега.
   Пост-соак нормализация: `apk update && apk fix wanguard` —
   пере-извлечение установленной версии ИЗ фида (урок №3 этапа 1), md5
   сверяется с байтами приёмки. Никакого спайк-пакета (wanguard-ucode)
   в apk-DB этап 5 не оставляет — форма пакета финальная уже в окне.
3. `apk audit` принимает ДИРЕКТОРИИ, не имя пакета: `apk audit wanguard`
   → «relative path skipped»; правильные вызовы — `apk audit /usr/bin`,
   `/etc/init.d`, `/usr/share/wanguard` (rc=0).
4. `wanauto` пишет явный `option wanmode 'auto'` (байт-эффект no-op,
   поведение и в 1.0.8 такое же) — после теста опция удалена, UCI
   возвращена байт-в-байт.
5. Батарея: канонический редирект telegram — `t.me → 302`
   (telegram.org теперь 200 — изменение мира, не роутера).

## Состояние после окна

Пакет **wanguard 1.1.0-r1** (локальный кандидат) остаётся жить — soak по
решению владельца (прецеденты этапов 1–4). Откат в любой момент:
`sh /root/rollback/20261028-221548/rollback.sh` (L1 = байты 1.0.8) или
`… rollback.sh --apk` (L3 = полный офлайн-reinstall 1.0.8-r1 из
savepoint). После соака: merge `spike/ucode` → main → тег **v1.1.0** →
CI → фид → `apk update && apk fix wanguard` → манифест/батарея →
протокол в #35.
