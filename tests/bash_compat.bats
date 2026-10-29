load 'setup'
. "$REPO_ROOT/tests/helpers/docker_stub.sh"

# Regression guard for scripts/check-bash-compat.sh.
#
# The script installs bats into a throwaway `bash:4.3` container with
# `apk add --no-cache bats`. That step depends on the alpine CDN, and it
# fails intermittently (measured 2026-10-29: 3 of 5 attempts failed with
# "SSL routines::unexpected eof while reading" / "bats (no such package)").
#
# The original script silenced that step with `>/dev/null 2>&1`, so the
# failure surfaced as a bare "BASH_COMPAT: FAIL (exit 1)" -- indistinguishable
# from "the code is incompatible with bash 4.3". It is not: the same bats
# suite passes 199/199 on bash 4.3. A diagnostic that lies about the cause
# costs more than no diagnostic at all.
#
# The docker stub runs the inner `sh -c` program for real, with a fake `apk`
# that fails on demand, so the failure path is observed rather than inferred.

COMPAT="$REPO_ROOT/scripts/check-bash-compat.sh"
STUB_DIR=""

teardown() {
    [ -n "$STUB_DIR" ] && rm -rf "$STUB_DIR"
    STUB_DIR=""
}

# Run the compat script with the fake apk failing, and echo its output.
_run_compat_with_failing_apk() {
    STUB_DIR="$(mktemp -d)"
    install_docker_stub "$STUB_DIR"
    DOCKER_STUB_APK_MODE=fail \
        BASH_COMPAT_HOST_REPO="$REPO_ROOT" \
        bash "$COMPAT" 2>&1
}

@test "check-bash-compat.sh lets the apk step's error output through" {
    out="$(_run_compat_with_failing_apk || true)"

    # The package failure must leave a trace. If it does not, the reader has
    # nothing to go on and goes looking for a compatibility bug that is not
    # there.
    [[ "$out" == *"unable to select packages"* ]]
}

@test "check-bash-compat.sh names the cause instead of implying a bash 4.3 bug" {
    out="$(_run_compat_with_failing_apk || true)"

    [[ "$out" == *"BASH_COMPAT: FAIL"* ]]
    # It must not be the bare "FAIL (exit N)" the old script printed.
    run grep -E 'BASH_COMPAT: FAIL \(exit [0-9]+\)$' <<<"$out"
    [ "$status" -ne 0 ]
    # And it must not imply the code is at fault.
    [[ "$out" == *"NOT a bash 4.3 incompatibility"* ]]
}

@test "check-bash-compat.sh still reports PASS when the package installs" {
    STUB_DIR="$(mktemp -d)"
    install_docker_stub "$STUB_DIR"
    out="$(DOCKER_STUB_APK_MODE=succeed \
        BASH_COMPAT_HOST_REPO="$REPO_ROOT" \
        bash "$COMPAT" 2>&1 || true)"

    [[ "$out" == *"BASH_COMPAT: PASS"* ]]
    # The success path must not carry the failure advice.
    [[ "$out" != *"network/CDN problem"* ]]
}

@test "check-bash-compat.sh passes its own host repo through to the container" {
    # The container-side mount path comes from BASH_COMPAT_HOST_REPO; without
    # it the script would mount the container's own /repo and the bats suite
    # would not be found at all.
    grep -q 'BASH_COMPAT_HOST_REPO' "$COMPAT"
    grep -q 'HOST_REPO}:/repo' "$COMPAT"
}
