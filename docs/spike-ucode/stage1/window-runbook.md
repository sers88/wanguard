# Stage-1 window runbook — wand-tick в ucode на роутере (issue #30)

**Железное правило окна:** ни одного действия на роутере до фазы D включительно
не считается «безопасным», пока откат не **отрепетирован живьём** (гейт D).
Все артефакты отката лежат на самом роутере — лестница работает при
**полностью мёртвом интернете**.

Роли: **владелец** — у терминала роутера, батарея 5/5 с клиента;
**агент** — готовит артефакты, читает вывод, предлагает команды;
все изменения — по явному «ок» владельца (правило 2 из PLAN.md).

Таймбокс: **45 минут, жёсткий стоп.** Любой красный гейт → откат →
постмортем в issue #30, окно переносится.

---

## Лестница отката (записать до начала)

| Уровень | Команда | Что делает | Время |
|---|---|---|---|
| L0 | `/etc/init.d/wanguard stop` | заморозка: тик больше не переключает | мгновенно |
| L1 | `sh /root/rollback/<ts>/rollback.sh` | sh-CLI назад, рестарт, sanity-блок | ~10 с |
| L2 | `sh /root/rollback/<ts>/rollback.sh --uci` | + UCI из снапшота | ~30 с |
| L3 | `sh /root/rollback/<ts>/rollback.sh --apk` | полный офлайн-reinstall stock 1.0.4 (del-then-add: `apk add` той же версии — **no-op**, файлы не перезаливает; поймано живьём в окне 2026-10-25) | ~1 мин |
| L4 | failsafe `192.168.1.1` (кабель напрямую, статика 192.168.1.2) | крайний случай | — |

`<ts>` = метка времени сгенерированного снейпшота (фаза A печатает команду
целиком — записать её). L1 достаточно в ~всех случаях: остальные файлы
спайка байт-в-байт равны stock (доказано в гейте C), следующий тик (≤10 с)
снова sh.

Почему «умер весь интернет» маловероятен, но предусмотрен: тик не трогает
main-default, LAN, dnsmasq, SSH; неmarked-клиенты остаются в main при любом
исходе; SSH владельца идёт по LAN и от дрели не зависит.

---

## До окна (Фаза 0 — агент, offline)

- [x] Кит в репо `docs/spike-ucode/stage1/` (savepoint/drill/manifest/runbook)
- [x] **Кит отшейкдаунен в лабе** (2026-10-25): savepoint собирается, `rollback.sh`
      возвращает sh (rc=0, md5sum -c все OK), nft-цикл зелёный (down 33с →
      egress eth0→eth1 → route-lookup table 400 → up 90с → failback),
      force-цикл зелёный, abort по красной батарее → cleanup → вотчдог
      возвращает группу сам (~80 с), префлайт отказывает при мёртвом backup-WAN
- [x] **Байт-паритет sh-файлов доказан**: установка фидового
      `wanguard-1.0.4-r1.apk` в лабе кладёт в `/usr/bin/wanguard` файл с md5
      `8dcc4a423861fdedcad034820c6860ca` = md5 `router/wanguard` из манифеста
      (=`wanguard-sh` спайка); все 6 sh-файлов пакета = манифесту —
      passthrough-цель спайка байт-в-байт равна установленному 1.0.4
- [x] Лаба C1–C6 зелёная на HEAD `spike/ucode` (приёмка #29, воспроизведена;
      после рестарта контейнеров лаба поднимается `lab/resume.sh`)
- [ ] Спайк-апк + манифест собраны заново и закинуты на роутер в `/tmp/`
      (команды печатает make-manifest.sh; скрипты — LF, проверено);
      **перед окном пересобрать**, если репо менялся с последней сборки
- [ ] Владелец подтвердил группу дрели (**`freedom`**, не rostelecom: у
      rostelecom-группы ~15 членов) и время окна: члены freedom-группы
      ~2 мин/цикл живут на rostelecom (CGNAT), #24-flush делает переезд чистым

## Фаза A — baseline и savepoint (~5 мин)

```sh
ssh root@192.168.88.1
# батарея 5/5 с клиента: telegram 302 / example.com 200 /
# nslookup 192.168.88.1 / SSH / nslookup ya.ru 8.8.8.8
wanguard wanstatus                 # ГЕЙТ A1: ANCHORS 3/3, группы на home
wanguard list | tail -1            # ГЕЙТ A2: nft: in-sync
logread | grep wanguard-wand | tail -5    # тишина (нет событий)
uci -q get wanguard.freedom.iface         # = wan_home (steady state)
sh /tmp/make-savepoint.sh          # снейпшот + rollback.sh + apk с фида
ls -la /root/rollback/<ts>/        # usr-bin-wanguard, config.wanguard,
                                   # wanguard-1.0.4-*.apk, rollback.sh — всё на месте
```

**ГЕЙТ A:** всё зелёное, savepoint полный. Записать команду
`sh /root/rollback/<ts>/rollback.sh`. Нет — стоп, окно не продолжается.

## Фаза B — окружение (~2 мин)

```sh
ucode -e 'import * as uci; import * as ubus; import * as fs; print("ucode ok\n")'
ls /tmp/.uci 2>/dev/null | grep wanguard   # ГЕЙТ B2: пусто (нет хвостов)
sha256sum /tmp/wanguard-ucode-*.apk        # ГЕЙТ B3: = строка sha256 из манифеста
```

**ГЕЙТ B:** ucode жив, хвостов нет, apk подлинный.

## Фаза C — установка спайка (~5 мин)

```sh
/etc/init.d/wanguard stop                                # заморозка на время swap
apk add --allow-untrusted --force-overwrite /tmp/wanguard-ucode-*.apk
md5sum -c /tmp/stage1-manifest.txt                       # ГЕЙТ C1: все 7 строк OK
head -1 /usr/bin/wanguard                                # #!/usr/bin/ucode
wanguard probe-selftest                                  # ubus map + якоря
wanguard wanstatus | head -8                             # сверить dev/addr/anchors с selftest
wanguard list | tail -1                                  # ГЕЙТ C4: nft: in-sync (passthrough жив)
```

**ГЕЙТ C:** md5-манифест зелёный (теперь `/usr/bin/wanguard` = ucode-байты),
`probe-selftest` согласован с `wanstatus` (устройства/адреса/якоря),
passthrough-команды работают. Несовместимо → L1.

## Фаза D — репетиция отката (~4 мин, НЕ ПРОПУСКАТЬ)

```sh
sh /root/rollback/<ts>/rollback.sh
md5sum -c /root/rollback/<ts>/md5sums-before.txt         # ГЕЙТ D1: все OK — байт-в-байт как до окна
# батарея 5/5 — ГЕЙТ D2 зелёная
# спайк заново: apk add той же версии — NO-OP (файлы не перезаливает!), нужен del+add:
apk del wanguard-ucode
apk add --allow-untrusted --force-overwrite /tmp/wanguard-ucode-*.apk
grep -E '^[0-9a-f]{32}  /' /tmp/stage1-manifest.txt | md5sum -c -   # снова все OK
```

Примечание: busybox `md5sum -c` не умеет пропускать комментарии — фильтруй
манифест грепом выше (строки с путями), иначе получишь шумные FAILED на
строках `#`.

**ГЕЙТ D:** откат доказан делом. Дальше всё остальное — уже «при страховке».

## Фаза E — первые тики через keepalive (~5 мин)

```sh
/usr/bin/wanguard wand-tick; echo rc=$?    # ожидаем тишину и rc=0
/usr/bin/wanguard apply                    # in-sync
/usr/bin/wanguard wan-flush                # тишина
/etc/init.d/wanguard start
sleep 30
logread | grep wanguard | tail -10         # ГЕЙТ E: тихо, без ошибок
wanguard wanstatus | head -8               # ANCHORS 3/3
```

**ГЕЙТ E:** keepalive крутит ucode-тик молча. Красное → L1, стоп.

## Фаза F — учения failover/failback ×5 (~20 мин)

```sh
sh /tmp/drill.sh freedom 5
```

Смешанный режим (решение владельца): циклы 1–2 — **nft-дренаж** (отдельная
таблица `drill_drain` режет ТОЛЬКО собственные curl-пробы роутера к IP якорей
через pptp-freedom — клиентский трафик через output-hook не ходит вообще),
циклы 3–5 — **force-крючок #6**. После каждого переключения скрипт спрашивает
батарею 5/5. Ctrl-C в любой момент = cleanup + само-возврат вотчдогом (~2 мин).

Ожидаемая картина цикла: `down:freedom` (~30 с) → `failover:freedom>rostelecom`
(UCI + applied + flush-событие в логе) → батарея → `up:freedom` (~60 с) →
`failback:freedom>freedom` → батарея.

**ГЕЙТ F:** 5/5 зелёных, финальный блок скрипта чистый (state=up, iface=home,
device как до дрели, нет force-файлов и drill_drain).

## Фаза G — закрытие окна (~3 мин)

```sh
wanguard wanstatus                # ANCHORS 3/3
logread | grep wanguard-wand | tail -5    # тишина
wanguard list | tail -1           # in-sync
```

Спайк **остаётся жить** (soak 24–48 ч, решение владельца): раз в полдня —
`wanguard wanstatus` (ANCHORS 3/3) + батарея; wand-лог должен молчать вне
реальных происшествий. **НЕ делать** `apk del wanguard-ucode`.

---

## После soak — переход на фид (отдельное короткое окно, ~10 мин)

1. Агент: адаптирует `apk/build.sh` под stage-1 форму (ucode-вход +
   `wanguard-sh` внутри, depends += ucode-модули), merge `spike/ucode` → main,
   тег `v1.0.5` → CI → фид.
2. На роутере:
   ```sh
   apk update && apk upgrade
   md5sum -c /tmp/stage1-manifest.txt   # байты из фида = байты приёмки
   # батарея 5/5, ANCHORS 3/3
   ```
3. Откат с фида: `apk add --force-overwrite wanguard=1.0.4-r1` или офлайн-апк
   из savepoint. Спайк-пакет в БД не трогаем (безвреден, файлы перекрыты).

## Приложения

**Feed (fallback, если `apk fetch` в фазе A не сработал):**
`https://raw.githubusercontent.com/sers88/wanguard/feed/packages/x86_64/wanguard-1.0.4-r1.apk`
(ключ фида: `.../feed/keys/wanguard.pem`) — скачать на ПК, scp в savepoint.

**Если SSH к роутеру умер в окне:** SSH идёт по LAN — смерть SSH означает
проблему самой коробки, не дрели: кабель напрямую, failsafe `192.168.1.1`.

**Что считать успехом окна:** 5/5 циклов зелёные при молчащем wand-логе,
ANCHORS 3/3, md5-манифест зелёный, ни одного красного гейта, откат
отрепетирован дважды (туда-обратно).
