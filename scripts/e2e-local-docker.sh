#!/usr/bin/env bash
# e2e-local-docker.sh — run the Docker E2E against the LOCAL Docker engine.
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# The E2E is a bash script that orchestrates containers. On a Windows host the
# daemon may live in one of two places:
#
#   * the LOCAL Docker Desktop engine (npipe:////./pipe/dockerDesktopLinuxEngine)
#   * a Docker Engine installed INSIDE WSL2 (unix socket under /var/run)
#
# They are DIFFERENT engines with DIFFERENT container inventories. Running the
# E2E against the WSL engine creates its containers there, where the host's
# docker CLI (and the host PowerShell) cannot see them, and where leftovers
# accumulate unnoticed. This project pins the E2E to the LOCAL engine.
#
# This script enforces that by asking the daemon it is about to use which
# engine it is, and comparing the answer against a set of known engine
# fingerprints. A mismatch is a hard failure BEFORE any container is created --
# not a warning that scrolls past in a 200-line log.
#
# THE PATH PROBLEM (the reason a wrapper is needed at all)
# -------------------------------------------------------
# Two different processes resolve the two kinds of paths in the E2E, and they
# need DIFFERENT syntaxes on a Windows host:
#
#   * `docker build <context>`  -- the CONTEXT is read by the CLI. When the CLI
#     is a Windows binary, it needs a Windows path ("D:/work/..."), and MSYS
#     path translation must be ON so that "/d/work/..." becomes "D:\work\...".
#   * `docker run -v <src>:<dst>` -- the SOURCE is resolved by the DAEMON. MSYS
#     path translation must be OFF, because it would rewrite the ":container"
#     half into a Windows path and produce "D:/Program Files/Git/repo" -- a
#     directory that does not exist, so the mount silently comes up empty.
#
# Running the E2E from Git Bash therefore needs MSYS_NO_PATHCONV=1 (or
# MSYS2_ARG_CONV_EXCL) for the mount to work, and that in turn breaks the
# build context. The two settings are mutually exclusive.
#
# THE FIX: run the E2E inside a Linux container that has the docker CLI, and
# give it the repo twice -- once under a Linux path for the CLI to read as a
# build context, and once under a Windows path for the daemon to resolve as a
# mount source. The repo already models this split:
#
#   * REPO_ROOT      -- Linux path inside the runner; used for `docker build`.
#   * E2E_HOST_REPO  -- daemon-visible path; used for `docker run -v`.
#
# Usage (from PowerShell, in the repo root):
#   bash scripts/e2e-local-docker.sh
#
# Env:
#   E2E_LOCAL_DOCKER_HOST_REPO  daemon-visible repo path. Default: the current
#                                directory converted to a Windows path when the
#                                host looks like Windows, else the path as-is.
#   E2E_LOCAL_DOCKER_ENGINE     expected engine fingerprint. Default:
#                                "Docker Desktop". A mismatch is fatal.
#   E2E_LOCAL_DOCKER_RUNNER     runner image (must have the docker CLI).
#                                Default: rc-e2e-runner:local.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RUNNER_IMAGE="${E2E_LOCAL_DOCKER_RUNNER:-rc-e2e-runner:local}"
EXPECTED_ENGINE="${E2E_LOCAL_DOCKER_ENGINE:-Docker Desktop}"

# The daemon-visible path. On a Windows host the daemon is Docker Desktop,
# which resolves Windows paths ("D:/work/repo"); on a Linux host the repo
# path is already what the daemon wants.
host_repo() {
    if [ -n "${E2E_LOCAL_DOCKER_HOST_REPO:-}" ]; then
        printf '%s\n' "$E2E_LOCAL_DOCKER_HOST_REPO"
        return 0
    fi
    case "$(uname -s 2>/dev/null || echo Windows)" in
        MINGW*|MSYS*|CYGWIN*|Windows*)
            # cygpath lives in Git Bash; fall back to the raw path elsewhere.
            if command -v cygpath >/dev/null 2>&1; then
                cygpath -m "$REPO_ROOT"
            else
                printf '%s\n' "$REPO_ROOT"
            fi
            ;;
        *)
            printf '%s\n' "$REPO_ROOT"
            ;;
    esac
}

HOST_REPO="$(host_repo)"

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"

# --- engine check ---------------------------------------------------------
#
# `docker info --format '{{.OperatingSystem}}'` names the ENGINE, not the
# client, which is exactly the question: which daemon are the E2E's
# containers about to be created in?
#
# The runner container's docker CLI talks to the daemon over the mounted
# socket, so the engine reported from inside the container is the one that
# will actually create the containers. That is the check that matters.
engine_os="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null)" \
    || die "could not reach a docker daemon (docker info failed)"
printf 'engine: %s\n' "$engine_os"

case "$engine_os" in
    *"$EXPECTED_ENGINE"*) : ;;
    *) die "the local daemon is '$engine_os', expected '$EXPECTED_ENGINE'.
       This project runs its containers in the LOCAL Docker Desktop engine.
       If you intended the WSL-side engine, that is a different daemon with a
       different container inventory -- do not mix them." ;;
esac

# --- preflight: the runner image must carry the docker CLI ----------------
if ! docker image inspect "$RUNNER_IMAGE" >/dev/null 2>&1; then
    die "runner image '$RUNNER_IMAGE' not found (see docs/HANDOFF.md '环境约束' for how to rebuild it)"
fi
docker run --rm --entrypoint sh "$RUNNER_IMAGE" -c 'command -v docker >/dev/null' \
    || die "runner image '$RUNNER_IMAGE' has no docker CLI"

printf 'repo (daemon-visible): %s\n' "$HOST_REPO"
printf 'runner image:          %s\n' "$RUNNER_IMAGE"
printf '\n'

# --- run ------------------------------------------------------------------
#
# The socket mount gives the runner the daemon; the repo mount gives it a
# Linux path to use as the build context; E2E_HOST_REPO gives the daemon the
# path it needs for `docker run -v`.
#
# --network is deliberately NOT set: the E2E creates its own network and
# joins containers to it by name.
exec docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${HOST_REPO}:/repo" \
    -e E2E_HOST_REPO="${HOST_REPO}" \
    -w /repo \
    "$RUNNER_IMAGE" \
    bash /repo/scripts/e2e-cluster-config.sh "$@"
