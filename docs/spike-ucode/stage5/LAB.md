# Stage 5 lab evidence — C1–C6 under the retired-sh package (issue #35)

Дата: 2026-10-28. Лаба поднята начисто (сети wanA/wanB/wanC, якорь
uhttpd на 5 адресах, wanguard-lab с NET_ADMIN). В лабе установлен
СПАЙК-ПАКЕТ текущего коммита = шейп этапа 5: `/usr/bin/wanguard` = ucode
CLI, **/usr/bin/wanguard-sh ОТСУТСТВУЕТ**. Дифференциальные ноги C2/C3/
C4/C6 используют sh-референс по пути репо (/repo/router/wanguard).

Команды (хост Windows, грабля №9 — руками):

```powershell
docker network create --subnet 172.30.10.0/24 wanA   # + wanB .20/24, wanC .30/24
docker run -d --name wanguard-lab-net --cap-add=NET_ADMIN --network wanA --ip 172.30.10.10 `
  openwrt/rootfs:x86_64-25.12.5 sh -c 'mkdir -p /www; echo ok > /www/anchor; `
  ip addr add 172.30.10.11/24 dev eth0; ip addr add 172.30.10.12/24 dev eth0; `
  apk add --quiet uhttpd curl; uhttpd -p 0.0.0.0:80 -h /www; sleep infinity'
docker network connect --ip 172.30.20.10 wanB wanguard-lab-net
docker network connect --ip 172.30.30.10 wanC wanguard-lab-net
docker run -d --name wanguard-lab --cap-add=NET_ADMIN --network wanA --ip 172.30.10.2 `
  -v E:\Projects\wanguard-public:/repo:ro `
  -v <apk.static>:/tmp/apk.static:ro openwrt/rootfs:x86_64-25.12.5 sleep infinity
docker network connect --ip 172.30.20.2 wanB wanguard-lab
docker network connect --ip 172.30.30.2 wanC wanguard-lab
docker exec wanguard-lab sh /repo/docs/spike-ucode/lab/setup.sh
```

(Грабля: apk в якорном контейнере качается 1–3 минуты — uhttpd/curl
появляются не сразу; ждать завершения `apk add` перед проверкой якорей.)

## Результаты (одна сессия, все зелёные)

| Батарея | Результат |
|---|---|
| C1 regress | sh 67/67; **ucode 87/87**; сценарии scenario/scenario26 — BYTE-IDENTICAL |
| C2 failover drill | 5/5 живых циклов (table 400: eth0→eth1→eth0, rules=0 после failback) + sh-parity цикл; iptables-мусор снят trap'ом |
| C3 3-WAN re-failover (#26) | wan1→wan3 (list order) → RE-failover wan2 → failback wan1; table 400 eth0→eth2→eth1→eth0; flush-события байт-формы на КАЖДОМ хопе + sh-parity |
| C4 контракт | keepalive ×100 (1 applied / 99 in-sync, дальше тишина); list/grouplist/wanstatus/devices — байт-идентичны sh-референсу на установленном нативном CLI; wan-flush байт-паритет + тихий повтор |
| C5 края | чёрный якорь = честный таймаут 6 c/тик, wan1.fails=1; N-of-M 2/3: 1 мёртв → up, 2 мертвы → down x3; override держит; без conntrack — тишина rc=0, pending поглощён |
| C6 метрики | тик 4.0 vs 54.0 внешних спавнов (uci 0 vs 110); apply 14.0 vs 98.0; wall 16.10 vs 75.84 мс (4.7×); VmHWM 1280 vs 768 kB |

Метрики C6 совпали с этапом 4 (в пределах шума) — код тика/apply не
менялся, что согласуется с дельтой wand.uc (только комментарии).

Плюс вне лабы, в разовых контейнерах: contract-gate 28/28, release-пакет
1.0.9-r1 собран и проверен (файлы манифеста на месте, wanguard-sh
отсутствует, /usr/bin/wanguard байт-в-байт == wand.uc), install-test
спайк-пакета зелёный.
