#!/usr/bin/env bash
# Run the whole bats suite under the OLDEST supported bash.
#
# The project declares bash 4+ (README.md). On bash < 4.4 an empty array
# expands to an unbound variable under `set -u`, so code that is fine on
# ubuntu's bash 5.1 can die on a bash 4.3 host -- and the CI runner is bash
# 5.1, so the ordinary test run cannot see it.
#
# The bats image is alpine-based; `apk add bats` gives bats 1.12.
set -uo pipefail

REGISTRY="${BASH_COMPAT_REGISTRY:-docker.m.daocloud.io/library}"
BASH_IMAGE="${BASH_COMPAT_IMAGE:-${REGISTRY}/bash:4.3}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_REPO="${BASH_COMPAT_HOST_REPO:-$REPO_ROOT}"

command -v docker >/dev/null 2>&1 || {
    echo "docker not found" >&2
    exit 1
}

echo "=== bash compatibility check ==="
echo "image: $BASH_IMAGE"
echo

docker run --rm -v "${HOST_REPO}:/repo" -w /repo "$BASH_IMAGE" sh -c '
    set -e
    # Do NOT silence this: the alpine CDN that serves bats fails intermittently
    # (measured: 3 of 5 attempts failed with "SSL routines::unexpected eof while
    # reading" or "bats (no such package)"). With the error hidden, that failure
    # looks exactly like "the code is incompatible with bash 4.3" -- it is not.
    # A visible apk error tells the reader it is a network problem.
    apk add --no-cache bats
    echo "bash: $(bash --version | head -1)"
    echo "bats: $(bats --version)"
    echo
    find tests -name "*.bats" -print0 | xargs -0 bats
' 2>&1 | tee /tmp/bash-compat.log

rc="${PIPESTATUS[0]}"
echo
if [ "$rc" -eq 0 ]; then
    echo "BASH_COMPAT: PASS"
else
    # If the apk step failed, say so: the code may well be fine and the only
    # thing broken was the package download.
    if ! grep -q '^bash: GNU bash' /tmp/bash-compat.log; then
        echo "BASH_COMPAT: FAIL (exit $rc) -- the bats package could not be installed;"
        echo "               this is a network/CDN problem, NOT a bash 4.3 incompatibility."
        echo "               Re-run; if it keeps failing, install bats into a local image."
    else
        echo "BASH_COMPAT: FAIL (exit $rc)"
    fi
fi
exit "$rc"
