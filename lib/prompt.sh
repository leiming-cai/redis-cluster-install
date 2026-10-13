#!/usr/bin/env bash
# lib/prompt.sh — interactive prompt helpers.
# Reads from /dev/tty when available; falls back to stdin when
# PROMPT_NO_TTY=1 is set (used by tests and non-interactive callers).
# Echoes the result on stdout. Never writes input to disk.

# _tty_check: ensure /dev/tty is readable (advisory; not fatal)
_tty_check() {
    [ -r /dev/tty ] && [ -w /dev/tty ]
}

# _read_from PROMPT_VAR REPLY_VAR [DEFAULT]
# Internal helper. Picks the input source based on PROMPT_NO_TTY env:
#   PROMPT_NO_TTY=1  -> read from stdin
#   /dev/tty usable  -> read from /dev/tty (interactive)
#   else             -> read from stdin (best-effort fallback)
# REPLY_VAR is the name of the variable to store the input.
# Returns 0 on successful read, 1 on EOF.
_read_from() {
    local prompt_var="$1"
    local reply_var="$2"
    local default="${3:-}"
    # Indirect assignment via nameref (bash 4.3+)
    declare -n _reply_ref="$reply_var"
    if [ "${PROMPT_NO_TTY:-0}" = "1" ] || ! _tty_check; then
        if ! read -r -p "${!prompt_var}" _reply_ref; then
            return 1
        fi
    else
        if ! read -r -p "${!prompt_var}" _reply_ref </dev/tty; then
            return 1
        fi
    fi
    if [ -n "$default" ] && [ -z "$_reply_ref" ]; then
        _reply_ref="$default"
    fi
    unset -n _reply_ref
    return 0
}

# read_default "PROMPT" "DEFAULT"
# Echoes user input or DEFAULT if empty.
read_default() {
    local prompt="$1"
    local default="$2"
    local prompt_str="$prompt [$default]: "
    local reply=""
    # NOTE: "$default" must be forwarded as _read_from's 3rd argument —
    # that is where the fallback is actually applied (see prompt.sh:34-36).
    # Omitting it made an empty reply (bare Enter) return an empty string,
    # which broke install.sh's SSH port/user defaults ("Bad port ''").
    #
    # On EOF (no input available at all) fall back to the default too, rather
    # than returning an empty string that later breaks command construction.
    if ! _read_from prompt_str reply "$default"; then
        reply="$default"
    fi
    printf '%s' "$reply"
}

# read_required "PROMPT"
# Loops until non-empty input. Echoes value.
read_required() {
    local prompt="$1"
    local prompt_str="$prompt: "
    local reply=""
    while :; do
        if ! _read_from prompt_str reply; then
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
    local prompt_str="$prompt: "
    local reply=""
    if ! _read_from prompt_str reply; then
        return 1
    fi
    echo >&2  # newline after silent read
    printf '%s' "$reply"
}

# read_confirm "PROMPT"
# Reads y/N. Echoes y or n.
read_confirm() {
    local prompt="$1"
    local prompt_str="$prompt [y/N]: "
    local reply=""
    if ! _read_from prompt_str reply; then
        return 1
    fi
    case "$reply" in
        y|Y|yes|YES) printf 'y' ;;
        *)           printf 'n' ;;
    esac
}
