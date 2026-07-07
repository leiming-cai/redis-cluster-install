#!/usr/bin/env bash
# lib/systemd.sh — render and control systemd units.

# render_systemd_unit TEMPLATE PORT NODE_NAME [PASSWORD]
# Echoes rendered unit to stdout. Password optional (template may or may not reference it).
render_systemd_unit() {
    local template="$1"
    local port="$2"
    local node_name="$3"
    local password="${4:-}"
    [ -f "$template" ] || { echo "systemd: template not found: $template" >&2; return 1; }
    # Use | as sed delimiter (values must not contain |).
    sed -e "s|%PORT%|$port|g" \
        -e "s|%NODE_NAME%|$node_name|g" \
        -e "s|%PASSWORD%|$password|g" \
        "$template"
}

# systemd_unit_name PORT → redis-<port>.service
systemd_unit_name() {
    echo "redis-$1.service"
}

# systemd_unit_path PORT → /etc/systemd/system/redis-<port>.service
systemd_unit_path() {
    echo "/etc/systemd/system/$(systemd_unit_name "$1")"
}