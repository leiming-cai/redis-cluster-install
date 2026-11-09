load 'setup'

# Tests for scripts/e2e-local-docker.sh -- the wrapper that pins the Docker
# E2E to the LOCAL Docker engine.
#
# WHAT THESE TESTS ARE FOR
# ------------------------
# The wrapper exists to stop the E2E from running against the WSL-side Docker
# engine (a DIFFERENT daemon with a DIFFERENT container inventory) and to work
# around the MSYS path-translation conflict between `docker build` (context
# read by the CLI) and `docker run -v` (source resolved by the daemon).
#
# Both of those are invisible to a source-grep test: "the script mentions
# E2E_HOST_REPO" says nothing about whether it was passed to the right
# container. So every test here drives the wrapper with a docker STUB that
# records the argv it was handed, and asserts on THAT.
#
# The stub never creates a container; it only records. A test that greps the
# script's source for a string would pass even if the variable were assigned
# to the wrong argument -- and this is exactly the shape of bug that the
# 2026-11-05 round found in a different place (a test that grepped the
# script's text instead of asserting what it printed).

setup() {
    export REPO_ROOT
    set -u

    # bats 1.2.1 (the version in rc-control:bats) has no BATS_TEST_TMPDIR --
    # that variable arrived in a later release. Use a directory next to the
    # test file instead, and clean it up ourselves.
    STUB_DIR="$BATS_TEST_DIRNAME/.tmp-e2e-local-docker"
    rm -rf "$STUB_DIR"
    mkdir -p "$STUB_DIR/bin"
    CALLS="$STUB_DIR/calls.log"

    # A docker stub that records its argv and answers the two questions the
    # wrapper asks before it starts the E2E.
    #
    # The heredoc is QUOTED on purpose. Unquoted, bash expands $(...) and
    # backticks inside it -- and the comment mentioning `docker image
    # inspect` would then be executed as a command substitution, printing a
    # syntax error into the generated stub. CALLS travels through the
    # environment instead of being interpolated.
    cat > "$STUB_DIR/bin/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$1" in
  info)
    echo "${DOCKER_STUB_ENGINE_OS:-Docker Desktop}"
    exit 0
    ;;
  image)
    # image inspect <img>
    exit "${DOCKER_STUB_IMAGE_RC:-0}"
    ;;
  run)
    # The preflight probe: the wrapper runs a container to check for the
    # docker CLI inside the runner image.
    if [ "${DOCKER_STUB_CLI_MISSING:-0}" = "1" ]; then
      exit 1
    fi
    exit 0
    ;;
esac
exit 0
SHIM
    chmod +x "$STUB_DIR/bin/docker"

    PATH="$STUB_DIR/bin:$PATH"
    export PATH
    export CALLS
}

teardown() {
    rm -rf "$BATS_TEST_DIRNAME/.tmp-e2e-local-docker"
}

# Run the wrapper and capture the recorded docker argv.
run_wrapper() {
    run env \
        E2E_LOCAL_DOCKER_HOST_REPO="D:/work/rediscluterproject" \
        E2E_LOCAL_DOCKER_RUNNER="rc-e2e-runner:local" \
        DOCKER_STUB_ENGINE_OS="${DOCKER_STUB_ENGINE_OS:-Docker Desktop}" \
        DOCKER_STUB_IMAGE_RC="${DOCKER_STUB_IMAGE_RC:-0}" \
        DOCKER_STUB_CLI_MISSING="${DOCKER_STUB_CLI_MISSING:-0}" \
        bash "$REPO_ROOT/scripts/e2e-local-docker.sh"
}

@test "e2e-local-docker passes the daemon-visible repo path to the runner" {
    run_wrapper
    [ "$status" -eq 0 ]
    # The mount source and E2E_HOST_REPO must be the daemon-visible path --
    # the daemon is what resolves them. A Linux path here mounts nothing.
    grep -q 'D:/work/rediscluterproject:/repo' "$CALLS" \
        || { echo "calls:"; cat "$CALLS"; false; }
    grep -q 'E2E_HOST_REPO=D:/work/rediscluterproject' "$CALLS" \
        || { echo "calls:"; cat "$CALLS"; false; }
}

@test "e2e-local-docker mounts the docker socket so the runner reaches the daemon" {
    run_wrapper
    [ "$status" -eq 0 ]
    grep -q -- '-v /var/run/docker.sock:/var/run/docker.sock' "$CALLS" \
        || { echo "calls:"; cat "$CALLS"; false; }
}

@test "e2e-local-docker runs the E2E script itself inside the runner" {
    run_wrapper
    [ "$status" -eq 0 ]
    grep -q 'bash /repo/scripts/e2e-cluster-config.sh' "$CALLS" \
        || { echo "calls:"; cat "$CALLS"; false; }
}

@test "e2e-local-docker refuses to run against a non-local engine" {
    # The whole point of the wrapper: the WSL-side engine reports a different
    # OperatingSystem, and running there creates containers the host cannot
    # see. This must be a HARD failure before any container is created.
    DOCKER_STUB_ENGINE_OS="Docker Engine - Community" run_wrapper
    [ "$status" -ne 0 ]
    [[ "$output" == *"expected"* ]] || {
        echo "output: $output"
        false
    }
    # And nothing may have been started.
    ! grep -q 'e2e-cluster-config.sh' "$CALLS" || {
        echo "calls:"; cat "$CALLS"
        false
    }
}

@test "e2e-local-docker fails when no docker daemon is reachable" {
    run env \
        E2E_LOCAL_DOCKER_HOST_REPO="D:/work/rediscluterproject" \
        PATH="/nonexistent-for-sure" \
        bash "$REPO_ROOT/scripts/e2e-local-docker.sh"
    [ "$status" -ne 0 ]
}

@test "e2e-local-docker fails when the runner image has no docker CLI" {
    # A runner image without the docker CLI would run the E2E, which would
    # then fail with "docker not found" from inside the container -- far from
    # the actual cause. The wrapper checks it up front.
    DOCKER_STUB_CLI_MISSING=1 run_wrapper
    [ "$status" -ne 0 ]
    [[ "$output" == *"docker CLI"* ]] || {
        echo "output: $output"
        false
    }
}

@test "e2e-local-docker honours an explicit expected-engine override" {
    # An operator on a differently-branded local engine must be able to say so
    # rather than being locked to one string.
    DOCKER_STUB_ENGINE_OS="Docker Engine - Community" run env \
        E2E_LOCAL_DOCKER_HOST_REPO="D:/work/rediscluterproject" \
        E2E_LOCAL_DOCKER_ENGINE="Docker Engine - Community" \
        DOCKER_STUB_ENGINE_OS="Docker Engine - Community" \
        DOCKER_STUB_IMAGE_RC="0" \
        DOCKER_STUB_CLI_MISSING="0" \
        PATH="$PATH" \
        bash "$REPO_ROOT/scripts/e2e-local-docker.sh"
    [ "$status" -eq 0 ]
}
