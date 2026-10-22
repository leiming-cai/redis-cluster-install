#!/usr/bin/env bash
set -u
ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

FAIL=0
TOTAL=0
TMP_ERR=$(mktemp)

echo "=== Script syntax check ==="
for f in install.sh status.sh uninstall.sh add-node.sh scripts/smoke-test.sh scripts/check-bash-compat.sh tests/validate_libs.sh; do
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
echo "=== Test support script syntax check ==="
for f in tests/setup.bash tests/helpers/*.sh; do
    [ -e "$f" ] || continue
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
echo "=== Bats test files (NOT checked with bash -n) ==="
# NOTE: .bats files use bats' `@test "name" { ... }` DSL, which is not valid
# bash. Running `bash -n` on them reports "syntax error near unexpected
# token '}'" for every file and drowns out real syntax failures.
# They are validated by executing them with bats instead.
for f in tests/*.bats tests/lib/*.bats; do
    [ -e "$f" ] || continue
    TOTAL=$((TOTAL+1))
    echo "SKIP (bats DSL, run 'bats' to validate): $f"
done

rm -f "$TMP_ERR"
echo
echo "============================="
echo "TOTAL=$TOTAL  FAIL=$FAIL"
echo "============================="
exit $FAIL