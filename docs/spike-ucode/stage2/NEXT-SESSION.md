# Stage-2 handoff — окно #32 на следующей сессии

Состояние на конец 2026-10-26. Dev-часть этапа 2 (#32) **полностью готова
и запушена**; осталось только живое окно (HITL) и фид.

## Где мы

- Ветка `spike/ucode` @ **c7f873f** (в origin; родословная: e269f50 = merge
  этапа 1 → c48f40b = wan-flush нативно + F-сьют + лаба → c7f873f = runbook).
- Тесты (последний полный прогон в этот день): sh-сьют **67/67** (WSL),
  ucode-сьют **55/55** (контейнер), лаба **C1–C6 зелёные** (C3 расширен:
  `flush:<g>><old>(<ip>)` байт-в-байт + sh-паритет на каждом хопе; C4 —
  parity + keepalive ×100; C5 — деградации; C6 — 4.0 форка/тик без деградации).
- Кандидат окна = спайк-пакет `wanguard-ucode` из `build-spike.sh` (тот же
  механизм, что в этапе 1): в пакете только байты `/usr/bin/wanguard`
  меняются (wand.uc с нативным wan-flush). md5 кандидата из последней
  сборки: `45a7af97790b50083dd9a8920e2caec4` (вер. метится временем —
  перед окном пересобрать, sha256 сверять со СВОИМ манифестом).
- Ранбук окна: `docs/spike-ucode/stage2/window-runbook.md` (кит этапа 1
  переиспользуется: make-savepoint.sh, drill.sh, лестница L0–L4 без изменений).
- Лаба погашена (контейнеры + сети wanA/wanB/wanC удалены).

## Подъём лабы на Windows (если понадобится перегнать батарею)

WSL-интеграции docker нет — команды руками из PowerShell (apk.static уже
лежит в `C:\Users\sersb\AppData\Local\Temp\opencode\apk.static`):

```powershell
docker network create --subnet 172.30.10.0/24 wanA
docker network create --subnet 172.30.20.0/24 wanB
docker network create --subnet 172.30.30.0/24 wanC
# якорь:
docker run -d --name wanguard-lab-net --cap-add=NET_ADMIN --network wanA --ip 172.30.10.10 `
  openwrt/rootfs:x86_64-25.12.5 sh -c 'mkdir -p /www; echo ok > /www/anchor; ip addr add 172.30.10.11/24 dev eth0; ip addr add 172.30.10.12/24 dev eth0; apk add --quiet uhttpd curl >/dev/null 2>&1; uhttpd -p 0.0.0.0:80 -h /www; sleep infinity'
docker network connect --ip 172.30.20.10 wanB wanguard-lab-net
docker network connect --ip 172.30.30.10 wanC wanguard-lab-net
# лаба:
docker run -d --name wanguard-lab --cap-add=NET_ADMIN --network wanA --ip 172.30.10.2 `
  -v "E:\Projects\wanguard-public:/repo:ro" `
  -v "C:\Users\sersb\AppData\Local\Temp\opencode\apk.static:/tmp/apk.static:ro" `
  openwrt/rootfs:x86_64-25.12.5 sleep infinity
docker network connect --ip 172.30.20.2 wanB wanguard-lab
docker network connect --ip 172.30.30.2 wanC wanguard-lab
docker exec wanguard-lab sh /repo/docs/spike-ucode/lab/setup.sh
docker exec wanguard-lab sh /repo/docs/spike-ucode/lab/C1-regress.sh   # и C2..C6
```

Гашение: `docker rm -f wanguard-lab wanguard-lab-net; docker network rm wanA wanB wanC`.

## Следующая сессия — что делать

1. Фаза 0: пересобрать манифест в лабе (команда в ранбуке), залить на роутер
   apk + манифест + `stage1/make-savepoint.sh` + `stage1/drill.sh`.
2. Окно по фазам A–G (~30 мин): гейты C1–C3 (включая пробу нативности
   `WANGUARD_SH=/nonexistent wanguard wan-flush`), репетиция отката,
   drill `freedom 3` с F1–F2 на каждом флипе, безопасные пробы деградации
   F3–F4 (предупреждение о сеянии реального `<iface>.flush` — в ранбуке).
3. После soak: merge `spike/ucode` → main → тег `v1.0.6` → CI → на роутере
   `apk del wanguard-ucode && apk update && apk upgrade && apk fix wanguard`
   → md5-манифест = байты фида → батарея → протокол в #32, закрытие;
   приватный репо: PLAN.md Этап 10 (этап 2 принят).
