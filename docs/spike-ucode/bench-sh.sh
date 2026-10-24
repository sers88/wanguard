#!/bin/sh
# bench-sh.sh — wanguard tick wall-time baseline (issue #29 spike, Phase 0.3)
#
# Measures wall-time of `wand-tick`, `apply`, `wan-flush` separately, plus a
# VmHWM (peak RSS) sample of the interpreter process, so the ucode version
# (Phase 1.5) can be compared against the sh baseline with the same method.
#
# Usage (on the router, as root):
#   sh /tmp/bench-sh.sh              # 100 iterations per command
#   ITER=300 sh /tmp/bench-sh.sh     # more samples
#   WG=/tmp/wanguard.ucode sh /tmp/bench-sh.sh   # later: bench the ucode port
#
# Safety:
# - runs a COPY of the wanguard script ($WG -> /tmp/wanguard.bench); the
#   installed package is never touched
# - all three commands are the keepalive's own steady-state cycle: tick
#   probes real anchors (up-WANs -> no state transitions), apply is
#   idempotent (prints in-sync), wan-flush has no pending files
# - NB: the real keepalive keeps running in parallel; shared oks/fails
#   counters may double-count — benign in steady state (documented)
# - raw samples are kept in /tmp/bench.$$.* for the issue comment

ITER=${ITER:-100}
CMDS=${CMDS:-"wand-tick apply wan-flush"} # window 2 (ucode): CMDS="wand-tick"
WG=${WG:-/usr/bin/wanguard}
RUNNER=${RUNNER:-sh}                      # window 2 (ucode): RUNNER=ucode
BENCH=/tmp/wanguard.bench
OUT=/tmp/bench.$$

[ -x "$WG" ] || { echo "bench: $WG not found" >&2; exit 1; }
cp "$WG" "$BENCH" || exit 1

# --- context (goes into the issue comment) ---
{
	echo "# context"
	echo "# date: $(date)"
	echo "# uname: $(uname -a)"
	echo "# release: $(cat /etc/openwrt_release 2>/dev/null | tr '\n' ' ')"
	echo "# load: $(cat /proc/loadavg)"
	echo "# wanguard bin: $WG"
	echo "# iter: $ITER"
} | tee "$OUT.context"

# --- timer resolution check: busybox date may lack %N ---
T0=$(date +%s%N 2>/dev/null)
case "$T0" in
	''|*N*) NS=0 ;; # no nanoseconds -> batch mode only
	*) NS=1 ;;
esac
echo "# nanosecond timer: $NS"

ms() { # seconds.nanos -> milliseconds (integer)
	echo $(( ($1) / 1000000 ))
}

run_once() { # $1=cmd -> prints ms (or empty in batch mode)
	: > "$OUT.t0"; : > "$OUT.t1"
	s=$(date +%s%N); "$RUNNER" "$BENCH" "$1" >/dev/null 2>&1; e=$(date +%s%N)
	ms $(( e - s ))
}

summarize() { # $1=label $2=samples-file (one ms value per line)
	n=$(grep -c . "$2")
	[ "$n" -gt 0 ] || { echo "$1: NO SAMPLES"; return; }
	med=$(sort -n "$2" | awk -v n="$n" 'NR==int((n+1)/2){print; exit}')
	p95=$(sort -n "$2" | awk -v n="$n" 'NR==int(n*0.95+0.5){print; exit}')
	mn=$(sort -n "$2" | head -1)
	mx=$(sort -n "$2" | tail -1)
	echo "$1: n=$n median=${med}ms p95=${p95}ms min=${mn}ms max=${mx}ms"
}

# --- warmup (creates state files, settles drift if any) ---
for c in $CMDS; do "$RUNNER" "$BENCH" $c >/dev/null 2>&1; done

for c in $CMDS; do
	S="$OUT.$c"
	: > "$S"
	i=0
	while [ $i -lt $ITER ]; do
		if [ "$NS" = 1 ]; then
			run_once "$c" >> "$S"
		else
			s=$(date +%s); "$RUNNER" "$BENCH" "$c" >/dev/null 2>&1; e=$(date +%s)
			echo $(( e - s )) >> "$S" # seconds only (coarse)
		fi
		i=$(( i + 1 ))
	done
	if [ "$NS" = 1 ]; then
		summarize "$c" "$S"
	else
		awk -v L="$c" '{s+=$1} END {printf "%s: n=%d batch-total=%ds mean=%.2fs (coarse 1s timer)\n", L, NR, s, s/NR}' "$S"
	fi
done

# --- peak RSS of the interpreter process (main process only; transient
#     children like curl/uci excluded — same method will be used for ucode,
#     so the comparison is runtime-vs-runtime) ---
for c in $CMDS; do
	"$RUNNER" "$BENCH" $c >/dev/null 2>&1 &
	pid=$!
	hwm=0
	while kill -0 "$pid" 2>/dev/null; do
		v=$(grep VmHWM "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
		case "$v" in ''|*[!0-9]*) ;; *) [ "$v" -gt "$hwm" ] && hwm=$v ;; esac
	done
	wait "$pid"
	echo "rss-$c: VmHWM=${hwm}kB"
done

echo "# raw samples: $OUT.* (keep for the issue comment)"
