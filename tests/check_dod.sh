#!/usr/bin/env bash
set -u
ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

echo "============================================================"
echo "DoD #6: status.sh calls 'cluster nodes' and 'cluster slots'"
echo "============================================================"
grep -n 'cluster nodes' status.sh && echo "  PASS: 'cluster nodes' present" || echo "  FAIL: 'cluster nodes' missing"
grep -n 'cluster slots' status.sh && echo "  PASS: 'cluster slots' present" || echo "  FAIL: 'cluster slots' missing"

echo
echo "============================================================"
echo "DoD #7: uninstall.sh stops services and removes configs"
echo "============================================================"
grep -nE 'systemctl (stop|disable)' uninstall.sh && echo "  PASS: 'systemctl stop/disable' present" || echo "  FAIL: 'systemctl stop/disable' missing"
grep -nE 'rm -rf? [\"\x27]?/' uninstall.sh | head -20 && echo "  PASS: 'rm' commands present" || echo "  FAIL: 'rm' missing"

echo
echo "============================================================"
echo "Bonus: status.sh also calls 'cluster info' (DoD #3)"
echo "============================================================"
grep -n 'cluster info' status.sh && echo "  PASS: 'cluster info' present" || echo "  INFO: 'cluster info' not present (manual DoD check anyway)"

echo
echo "============================================================"
echo "Bonus: install.sh references redis-cluster create"
echo "============================================================"
grep -n 'cluster create\|--cluster create\|--cluster-replicas' install.sh

echo
echo "============================================================"
echo "Bonus: uninstall.sh supports --force flag"
echo "============================================================"
grep -n '\-\-force\|FORCE' uninstall.sh | head -5