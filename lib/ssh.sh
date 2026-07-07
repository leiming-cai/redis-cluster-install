#!/usr/bin/env bash
# lib/ssh.sh — sshpass-based SSH helpers.
# All commands run with: SSHPASS="$pass" sshpass -e ssh ...
# This avoids leaking the password to argv / process table.

# sship_host TARGET   → host part of "ip" or "ip:port"
sship_host() {
    local t="$1"
    echo "${t%%:*}"
}

# sship_port TARGET   → port part of "ip" or "ip:port", default 22
sship_port() {
    local t="$1"
    if [[ "$t" == *:* ]]; then
        echo "${t##*:}"
    else
        echo "22"
    fi
}

# sship_target USER HOST PORT   → "user@host" or "user@host:port" (omits :22)
sship_target() {
    local user="$1" host="$2" port="$3"
    if [ "$port" = "22" ]; then
        echo "${user}@${host}"
    else
        echo "${user}@${host}:${port}"
    fi
}

# ssh_check USER PASS HOST PORT
# Returns 0 if SSH connects and runs `true` on remote.
ssh_check() {
    local user="$1" pass="$2" host="$3" port="$4"
    SSHPASS="$pass" sshpass -e \
        ssh -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=5 \
            -p "$port" \
            "${user}@${host}" true
}

# ssh_run USER PASS HOST PORT CMD...
# Echoes remote stdout. Returns remote exit code.
ssh_run() {
    local user="$1" pass="$2" host="$3" port="$4"
    shift 4
    SSHPASS="$pass" sshpass -e \
        ssh -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 \
            -p "$port" \
            "${user}@${host}" "$@"
}

# ssh_copy USER PASS HOST PORT LOCAL_PATH REMOTE_PATH
# Single-file scp via sshpass.
ssh_copy() {
    local user="$1" pass="$2" host="$3" port="$4"
    local local_path="$5" remote_path="$6"
    SSHPASS="$pass" sshpass -e \
        scp -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 \
            -P "$port" \
            "$local_path" "${user}@${host}:${remote_path}"
}
