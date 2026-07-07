#!/usr/bin/env bash
# lib/config_gen.sh — render redis.conf from a template.

# render_redis_conf TEMPLATE PORT PASSWORD NODE_NAME BIND_ADDR
# Echoes the rendered config to stdout.
# Aborts (exit 1) if the template file is missing.
render_redis_conf() {
    local template="$1"
    local port="$2"
    local password="$3"
    local node_name="$4"
    local bind_addr="$5"

    [ -f "$template" ] || { echo "config_gen: template not found: $template" >&2; return 1; }

    # Use | as sed delimiter (values must not contain |).
    # Currently safe: gen_password emits [A-Za-z0-9], bind_addr is IP, node_name is hardcoded.
    sed -e "s|%PORT%|$port|g" \
        -e "s|%PASSWORD%|$password|g" \
        -e "s|%NODE_NAME%|$node_name|g" \
        -e "s|%BIND_ADDR%|$bind_addr|g" \
        "$template"
}