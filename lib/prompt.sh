#!/usr/bin/env bash
# lib/prompt.sh — interactive prompt helpers.
# Reads only from /dev/tty. Echoes the result on stdout.
# Never writes input to disk.

# _tty_check: ensure /dev/tty is readable
_tty_check() {
    [ -r /dev/tty ] && [ -w /dev/tty ] || {
        echo "prompt.sh: no usable /dev/tty — run interactively" >&2
        return 1
    }
}

# read_default "PROMPT" "DEFAULT"
# Echoes user input or DEFAULT if empty.
read_default() {
    _tty_check || return 1
    local prompt="$1"
    local default="$2"
    local reply=""
    read -r -p "$prompt [$default]: " reply </dev/tty
    [ -z "$reply" ] && reply="$default"
    printf '%s' "$reply"
}

# read_required "PROMPT"
# Loops until non-empty input. Echoes value.
read_required() {
    _tty_check || return 1
    local prompt="$1"
    local reply=""
    while [ -z "$reply" ]; do
        read -r -p "$prompt: " reply </dev/tty
    done
    printf '%s' "$reply"
}

# read_secret "PROMPT"
# Reads a password silently from /dev/tty. Echoes value.
read_secret() {
    _tty_check || return 1
    local prompt="$1"
    local reply=""
    read -r -s -p "$prompt: " reply </dev/tty
    echo >&2  # newline after silent read
    printf '%s' "$reply"
}

# read_confirm "PROMPT"
# Reads y/N. Echoes y or n.
read_confirm() {
    _tty_check || return 1
    local prompt="$1"
    local reply=""
    read -r -p "$prompt [y/N]: " reply </dev/tty
    case "$reply" in
        y|Y|yes|YES) printf 'y' ;;
        *)           printf 'n' ;;
    esac
}