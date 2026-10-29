#!/usr/bin/env bash
# Helpers for exercising scripts/check-bash-compat.sh without docker.
#
# The script's real work happens inside a throwaway `bash:4.3` container:
#
#     docker run --rm -v "$HOST_REPO:/repo" -w /repo "$IMAGE" sh -c '<inner>'
#
# and the inner script installs bats with `apk add --no-cache bats`. That
# download hits the alpine CDN, which fails intermittently -- measured 2026-10-29:
# 3 of 5 attempts failed with "SSL routines::unexpected eof while reading" or
# "bats (no such package)".
#
# The original script silenced that step with `>/dev/null 2>&1`, so a CDN
# failure surfaced as a bare "BASH_COMPAT: FAIL (exit 1)" -- indistinguishable
# from "the code is incompatible with bash 4.3". It is not: the same suite
# passes 199/199 on bash 4.3.
#
# To test the diagnostic without the flaky network, this helper installs a
# `docker` stub that:
#   * extracts the inner `sh -c` program from the arguments,
#   * runs it locally with a fake `apk` on PATH,
#   * and lets the fake `apk` fail (or succeed) on demand.
#
# The inner program -- the part under test -- really executes.

# Create a docker stub in $1 and export a PATH that prefers it.
# The stub reads $DOCKER_STUB_APK_MODE:
#   "fail"    -> the fake apk prints an apk-style error and exits 1
#   "succeed" -> the fake apk prints nothing and exits 0
install_docker_stub() {
    local dir="$1"
    mkdir -p "$dir/bin"

    cat > "$dir/bin/docker" <<'SHIM'
#!/usr/bin/env bash
# Stand-in for docker. Runs the inner `sh -c` program locally, with a fake
# `apk` in front of it, so the real script logic is exercised without the
# network and without a container runtime.
set -u
if [ "${1:-}" != "run" ]; then
    echo "docker stub: only 'run' is supported" >&2
    exit 64
fi

# The inner program is the last argument.
inner=""
for a in "$@"; do inner="$a"; done

stubbin="$(mktemp -d)"
cat > "$stubbin/apk" <<APKSHIM
#!/usr/bin/env bash
case "\${DOCKER_STUB_APK_MODE:-fail}" in
  succeed) exit 0 ;;
  *)
    echo "fetch https://dl-cdn.alpinelinux.org/alpine/v3.22/main/APKINDEX.tar.gz"
    echo "ERROR: unable to select packages:"
    echo "  bats (no such package):"
    exit 1
    ;;
esac
APKSHIM
chmod +x "$stubbin/apk"

PATH="$stubbin:$PATH" DOCKER_STUB_APK_MODE="${DOCKER_STUB_APK_MODE:-fail}" \
    sh -c "$inner"
rc=$?
rm -rf "$stubbin"
exit $rc
SHIM

    # A fake `bats`, so the inner script's "bats --version" works.
    cat > "$dir/bin/bats" <<'BATSSHIM'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
    echo "Bats 1.12.0"
    exit 0
fi
exit 0
BATSSHIM

    chmod +x "$dir/bin/docker" "$dir/bin/bats"
    PATH="$dir/bin:$PATH"
    export PATH
}
