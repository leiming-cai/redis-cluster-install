#!/usr/bin/env bash
# lib/password.sh — random alphanumeric password generator.

# gen_password [LENGTH=32]
# Echo a random string of LENGTH characters from [A-Za-z0-9].
# Requires /dev/urandom and tr. Aborts on dependency missing.
gen_password() {
    local len="${1:-32}"
    [ "$len" -gt 0 ] 2>/dev/null || { echo "length must be positive integer" >&2; return 2; }
    command -v tr >/dev/null 2>&1 || { echo "tr is required" >&2; return 3; }
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
    echo
}
