#!/usr/bin/env bash
set -u
ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

FAIL=0
TOTAL=0
TMP_ERR=$(mktemp)

echo "=== Script syntax check ==="
for f in install.sh status.sh uninstall.sh add-node.sh scripts/smoke-test.sh tests/validate_libs.sh; do
    TOTAL=$((TOTAL+1))
    if bash -n "$f" 2>"$TMP_ERR"; then
        echo "OK: $f"
    else
        echo "FAIL: $f"
        sed 's/^/    /' "$TMP_ERR"
        FAIL=$((FAIL+1))
    fi
done

echo
echo "=== Lib syntax check ==="
for f in lib/*.sh; do
    TOTAL=$((TOTAL+1))
    if bash -n "$f" 2>"$TMP_ERR"; then
        echo "OK: $f"
    else
        echo "FAIL: $f"
        sed 's/^/    /' "$TMP_ERR"
        FAIL=$((FAIL+1))
    fi
done

echo
echo "=== Test script syntax check ==="
for f in tests/setup.bash tests/*.bats tests/lib/*.bats; do
    TOTAL=$((TOTAL+1))
    if bash -n "$f" 2>"$TMP_ERR"; then
        echo "OK: $f"
    else
        echo "FAIL: $f"
        sed 's/^/    /' "$TMP_ERR"
        FAIL=$((FAIL+1))
    fi
done

rm -f "$TMP_ERR"
echo
echo "============================="
echo "TOTAL=$TOTAL  FAIL=$FAIL"
echo "============================="
exit $FAIL