#!/usr/bin/env bash
# lib/config_gen.sh — render redis.conf from a template.

# render_redis_conf TEMPLATE PORT PASSWORD NODE_NAME BIND_ADDR [REDIS_PREFIX]
# Echoes the rendered config to stdout.
# REDIS_PREFIX (default /opt/software/redis) is expanded into %REDIS_PREFIX%
# and must match the prefix used for the systemd unit and the install step,
# so that cluster-config-file / logfile / ExecStart all agree.
# Aborts (exit 1) if the template file is missing.
render_redis_conf() {
    local template="$1"
    local port="$2"
    local password="$3"
    local node_name="$4"
    local bind_addr="$5"
    local redis_prefix="${6:-/opt/software/redis}"

    [ -f "$template" ] || { echo "config_gen: template not found: $template" >&2; return 1; }

    # Every value interpolated into the sed REPLACEMENT side must have &, |
    # and \ escaped — otherwise a password containing them is silently
    # mangled (a&b -> a%PASSWORD%b, a\b -> ab) or aborts the whole render
    # (a|b -> "unknown option to `s'|"). cluster_password is arbitrary user
    # input, so unlike gen_password output it is not restricted to [A-Za-z0-9].
    # This mirrors _sed_escape in lib/systemd.sh so the two renderers agree.
    port="$(printf '%s'    "$port"        | sed -e 's/[&|\\]/\\&/g')"
    password="$(printf '%s' "$password"    | sed -e 's/[&|\\]/\\&/g')"
    node_name="$(printf '%s' "$node_name"  | sed -e 's/[&|\\]/\\&/g')"
    bind_addr="$(printf '%s' "$bind_addr"  | sed -e 's/[&|\\]/\\&/g')"
    redis_prefix="$(printf '%s' "$redis_prefix" | sed -e 's/[&|\\]/\\&/g')"

    sed -e "s|%PORT%|$port|g" \
        -e "s|%PASSWORD%|$password|g" \
        -e "s|%NODE_NAME%|$node_name|g" \
        -e "s|%BIND_ADDR%|$bind_addr|g" \
        -e "s|%REDIS_PREFIX%|$redis_prefix|g" \
        "$template"
}