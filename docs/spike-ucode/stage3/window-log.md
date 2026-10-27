# Stage-3 window log — 2026-10-27/28, нативный apply принят (soak)

Окно по `stage3/window-runbook.md`, кандидат
`wanguard-ucode-0.0.0-r10272012.apk` (sha256 `39b3aec6…`, wand.uc =
`spike/ucode` c92d5c1). Владелец за батареей; все гейты зелёные, красных
нет. Кандидат оставлен жить на роутере — **soak ~24 ч**.

## Гейты (все зелёные)

| Фаза | Гейт | Результат |
|---|---|---|
| 0 | паритет-гейт 165/165 на HEAD | ✓ |
| A | baseline: ANCHORS 3/3 ×3 WAN, `nft: in-sync`, apk-DB чистая, **savepoint** | ✓ `/root/rollback/20261027-231331` (+ офлайн-apk 1.0.6) |
| B | sha256 apk = манифест | ✓ `39b3aec6…` |
| C1 | md5-манифест после установки (7 файлов) | ✓ все OK |
| C2 | `list` tail in-sync, probe-selftest (ubus map, 3×3/3) | ✓ |
| C3 | `WANGUARD_SH=/nonexistent wanguard apply` | ✓ `in-sync` rc=0 — **нативен** |
| C4 | паритет живого состояния | ✓ `in-sync` (не applied — ucode видит ровно состояние sh) |
| C5 | `WANGUARD_DEBUG=1` на устаканенном состоянии | ✓ только `in-sync`, ноль строк батча |
| D | **репетиция отката**: rollback.sh → md5 7/7 OK vs before-state → sanity → спайк заново → C3–C5 повторно | ✓ обе стороны |
| E | keepalive-циклы через ucode: tick/apply/flush | ✓ тишина в логе, apply `in-sync` |
| F | **drill `freedom 3`**: циклы 1–2 nft-дренаж, цикл 3 .force; батарея 5/5 владельца после каждого из 6 переключений | ✓ 3/3 green |
| F1 | flush-события байт-формы на каждом хопе | ✓ 6/6: `wand:flush:freedom>freedom(217.25.226.49)` / `wand:flush:freedom>rostelecom(100.102.56.184)` — старый egress-IP верен в каждом направлении |
| F2 | `.flush` потреблён после apply | ✓ пусто |
| F0 | apply на живом флипе | ✓ keepalive сам залогировал `applied` на последнем failback (00:01:25) + `ip route get 1.1.1.1 mark 0x64 table 400` ушёл на backup dev на каждом флипе |
| F3 | fail-safe: nft/ip вне PATH при остановленном сервисе | ✓ `nft: not found` → `cannot create nft table`, **rc=1, отказ ДО изменений**; после старта — `in-sync` |
| G | закрытие: `nft: in-sync`, ANCHORS 3/3, лог тихий, drill_drain снесён, force-файлов нет | ✓ |

Примечания:
- «GATE-B FAIL» в транскрипте — битая зондирующая строка самого скрипта
  (`ucode -e` требует `import * as fs from "fs"`); сам ucode исправен
  (префлайт savepoint прошёл `ucode modules ok`).
- В `/tmp` роутера лежал apk окна этапа-2 — удалён, чтобы glob `apk add`
  не видел двух кандидатов.
- `up/forced` в wanstatus сразу после дрели — транзит маркера .force,
  сошёл на следующем тике (финальный G: чистое `up`).

## Откат (действует весь soak)

    sh /root/rollback/20261027-231331/rollback.sh        # L1: фид 1.0.6, ~10 с
    sh /root/rollback/20261027-231331/rollback.sh --uci  # L2: + UCI
    sh /root/rollback/20261027-231331/rollback.sh --apk  # L3: офлайн 1.0.6

## Soak (~24 ч, до 2026-10-28 вечера)

Раз в полдня: `wanstatus` (ANCHORS 3/3), `wanguard apply` (= in-sync),
`logread | grep wanguard | tail` (тихо, кроме честного предупреждения
`mihomo TUN Meta is down`, если mihomo погашен — поведение 1:1 с 1.0.6).

## После soak — фид

**Выполнено 2026-10-28, soak сокращён решением владельца** (прецедент
этапов 1–2):

- merge `spike/ucode` → main `57eae6c` → тег **v1.0.7** → CI зелёная
  (build → подпись индекса → ветка `feed` → install-тест `FEED-TEST-OK`);
- роутер: `apk del wanguard-ucode` → `apk update` → `apk add
  wanguard=1.0.7-r1` (явная версия, урок #32); md5-манифест окна 7/7 =
  **байты фида** (`/usr/bin/wanguard` md5 `6595dbde…`); гейты повторно:
  нативность (`WANGUARD_SH=/nonexistent` → in-sync rc=0), `in-sync`,
  ANCHORS 3/3, лог тихий; финальная батарея владельца 5/5;
- инцидент: gitlab.alpinelinux.org недоступен с GitHub-раннеров (curl 28,
  два прогона подряд) — apk.static выложен байт-идентичным зеркалом в
  `releases/ci-tools`, workflow получил фолбэк (sha256-пин гейтит оба
  источника); тег v1.0.7 несёт один ci-only коммит `61cb336` поверх
  мержа, содержимое пакетов идентично 57eae6c;
- протокол в #33, issue закрыта; приватный PLAN.md — Этап 10, этап 3
  принят. Откат с фида — офлайн-apk из savepoint (`rollback.sh --apk`).

Следующий этап #30 — **4: CLI CRUD**.
