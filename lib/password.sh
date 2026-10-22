#!/usr/bin/env bash
# lib/password.sh — random alphanumeric password generator.
#
# gen_password [LENGTH=32]
# Echo a random string of LENGTH characters from [A-Za-z0-9].
# Requires /dev/urandom, tr and head. Aborts on dependency missing.
gen_password() {
    local len="${1:-32}"
    [ "$len" -gt 0 ] 2>/dev/null || { echo "length must be positive integer" >&2; return 2; }
    command -v tr >/dev/null 2>&1 || { echo "tr is required" >&2; return 3; }
    command -v head >/dev/null 2>&1 || { echo "head is required" >&2; return 3; }
    # Read a BOUNDED amount of randomness FIRST, then filter it.
    #
    # The obvious form -- `tr -dc 'A-Za-z0-9' </dev/urandom | head -c N` --
    # reads an INFINITE stream and lets head close the pipe after N
    # characters. What happens to tr then depends on the build: it is either
    # killed by SIGPIPE (silent) or it reports "tr: write error: Broken pipe"
    # on stderr, and that message lands in whatever the caller captured. The
    # pipeline's status is 141 either way, so under `set -e` -- which every
    # production script here uses -- the caller is aborted before it can use
    # the password.
    #
    # Reading a bounded chunk first removes both problems: tr reads a file,
    # not a pipe that somebody else closes, so nothing is killed and nothing
    # is reported.
    #
    # LC_ALL=C makes tr byte-oriented. In a UTF-8 locale tr is multibyte
    # aware, and a byte that is not valid UTF-8 is not the character it
    # looks like; a password must not depend on the locale it was made in.
    local raw="" out="" tries=0
    while [ "${#out}" -lt "$len" ] && [ "$tries" -lt 10 ]; do
        tries=$((tries + 1))
        # 62 of 256 random bytes are [A-Za-z0-9], so 16x the wanted length
        # plus 256 gives roughly 4x more than enough. The loop is the
        # guarantee that a short read cannot produce a short password.
        raw="$(head -c $((len * 16 + 256)) /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
        [ -n "$raw" ] || continue
        out="$out$raw"
    done
    printf '%s\n' "${out:0:$len}"
}
