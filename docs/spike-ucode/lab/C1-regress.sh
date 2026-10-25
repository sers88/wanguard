#!/bin/sh
# C1-regress.sh — both test suites inside the lab (issue #29 acceptance).
# The suites are self-contained (own PATH stubs, own fixtures).
set -u
echo "== sh suite (67 checks):"
sh /repo/tests/mock/run-tests.sh 2>&1 | tail -1
echo "== ucode suite (20 checks):"
sh /repo/docs/spike-ucode/run-tests-ucode.sh 2>&1 | tail -1
echo "== differential scenarios (byte-parity):"
sh /repo/docs/spike-ucode/scenario.sh sh > /tmp/a1 2>&1
sh /repo/docs/spike-ucode/scenario.sh ucode > /tmp/a2 2>&1
sh /repo/docs/spike-ucode/scenario26.sh sh > /tmp/b1 2>&1
sh /repo/docs/spike-ucode/scenario26.sh ucode > /tmp/b2 2>&1
if cmp -s /tmp/a1 /tmp/a2 && cmp -s /tmp/b1 /tmp/b2; then
	echo "scenarios: BYTE-IDENTICAL"
else
	echo "scenarios: DIFFER"; ucode /repo/docs/spike-ucode/linediff.uc /tmp/a1 /tmp/a2; exit 1
fi
echo "C1-OK"
