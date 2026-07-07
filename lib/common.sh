#!/usr/bin/env bash
# lib/common.sh — logging, errors, color codes
# Source from another script. Do not execute.

# Color codes (disabled when not on a TTY)
if [ -t 1 ]; then
    C_RED=$'\e[31m'
    C_YEL=$'\e[33m'
    C_GRN=$'\e[32m'
    C_BLU=$'\e[34m'
    C_RST=$'\e[0m'
else
    C_RED='' C_YEL='' C_GRN='' C_BLU='' C_RST=''
fi

# Timestamp for log lines
_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log_info()  { printf '%s %s[INFO]%s  %s\n'  "$(_ts)" "$C_BLU" "$C_RST" "$*"; }
log_warn()  { printf '%s %s[WARN]%s  %s\n'  "$(_ts)" "$C_YEL" "$C_RST" "$*" >&2; }
log_error() { printf '%s %s[ERROR]%s %s\n'  "$(_ts)" "$C_RED" "$C_RST" "$*" >&2; }
log_ok()    { printf '%s %s[OK]%s    %s\n'  "$(_ts)" "$C_GRN" "$C_RST" "$*"; }

# die MESSAGE [EXIT_CODE]
# Default exit code 1.
die() {
    local msg="$1"
    local code="${2:-1}"
    log_error "$msg"
    exit "$code"
}

# ensure_dirs PATH...
# mkdir -p each path; abort on failure.
ensure_dirs() {
    for d in "$@"; do
        [ -d "$d" ] || mkdir -p "$d" || die "cannot create directory: $d"
    done
}

# require_cmd CMD...
# Abort if any command is missing.
require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
    done
}
