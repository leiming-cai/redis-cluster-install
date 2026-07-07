#!/usr/bin/env bash
# lib/prompt.sh — interactive prompt helpers.
# Reads from /dev/tty when available; falls back to stdin when
# PROMPT_NO_TTY=1 is set (used by tests and non-interactive callers).
# Echoes the result on stdout. Never writes input to disk.

# _tty_check: ensure /dev/tty is readable (advisory; not fatal)
_tty_check() {
    [ -r /dev/tty ] && [ -w /dev/tty ]
}

# _prompt_fd: echo the FD number to read from
#   1) PROMPT_NO_TTY=1 -> 0 (stdin)
#   2) /dev/tty usable -> opens /dev/tty on FD 9, echoes 9
#   3) else -> 0 (stdin fallback)
_prompt_fd() {
    if [ "${PROMPT_NO_TTY:-0}" = "1" ]; then
        echo 0
        return
    fi
    if _tty_check; then
        # Open /dev/tty on FD 9 if not already open there
        if ! { : <&9; } 2>/dev/null; then
            exec 9</dev/tty
        fi
        echo 9
    else
        echo 0
    fi
}

# read_default "PROMPT" "DEFAULT"
# Echoes user input or DEFAULT if empty.
read_default() {
    local prompt="$1"
    local default="$2"
    local fd reply=""
    fd=$(_prompt_fd)
    if ! read -r -u "$fd" -p "$prompt [$default]: " reply; then
        return 1
    fi
    [ -z "$reply" ] && reply="$default"
    printf '%s' "$reply"
}

# read_required "PROMPT"
# Loops until non-empty input. Echoes value.
read_required() {
    local prompt="$1"
    local fd reply=""
    fd=$(_prompt_fd)
    while :; do
        if ! read -r -u "$fd" -p "$prompt: " reply; then
            return 1
        fi
        [ -n "$reply" ] && break
    done
    printf '%s' "$reply"
}

# read_secret "PROMPT"
# Reads a password silently. Echoes value.
read_secret() {
    local prompt="$1"
    local fd reply=""
    fd=$(_prompt_fd)
    if ! read -r -s -u "$fd" -p "$prompt: " reply; then
        return 1
    fi
    echo >&2  # newline after silent read (only when /dev/tty is a real tty)
    printf '%s' "$reply"
}

# read_confirm "PROMPT"
# Reads y/N. Echoes y or n.
read_confirm() {
    local prompt="$1"
    local fd reply=""
    fd=$(_prompt_fd)
    if ! read -r -u "$fd" -p "$prompt [y/N]: " reply; then
        return 1
    fi
    case "$reply" in
        y|Y|yes|YES) printf 'y' ;;
        *)           printf 'n' ;;
    esac
}
