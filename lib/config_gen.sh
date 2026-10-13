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

    # Use | as sed delimiter (values must not contain |).
    # The prefix is passed through _sed_escape-equivalent handling: escape
    # characters that are special on the replacement side of sed.
    redis_prefix=$(printf '%s' "$redis_prefix" | sed -e 's/[&|\\]/\\&/g')

    sed -e "s|%PORT%|$port|g" \
        -e "s|%PASSWORD%|$password|g" \
        -e "s|%NODE_NAME%|$node_name|g" \
        -e "s|%BIND_ADDR%|$bind_addr|g" \
        -e "s|%REDIS_PREFIX%|$redis_prefix|g" \
        "$template"
}