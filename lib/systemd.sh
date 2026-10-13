#!/usr/bin/env bash
# lib/systemd.sh — render and control systemd units.

# _sed_escape STRING
# Echo STRING with sed metacharacters (`&`, `|`, `\`) escaped for use in
# the replacement side of a sed `s|...|REPLACEMENT|g` expression.
# Defensive: gen_password emits only [A-Za-z0-9] so password is currently safe,
# but bind_addr / node_name / future fields may not be.
_sed_escape() {
    printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

# render_systemd_unit TEMPLATE PORT NODE_NAME [PASSWORD] [REDIS_PREFIX]
# Echoes rendered unit to stdout. Password optional (template may or may not
# reference it). REDIS_PREFIX defaults to /opt/software/redis and is expanded
# into %REDIS_PREFIX%; it must match the prefix install.sh used, otherwise the
# unit would point ExecStart/ReadWritePaths at the wrong directories.
render_systemd_unit() {
    local template="$1"
    local port="$2"
    local node_name="$3"
    local password="${4:-}"
    local redis_prefix="${5:-/opt/software/redis}"
    [ -f "$template" ] || { echo "systemd: template not found: $template" >&2; return 1; }
    local port_e node_e pass_e prefix_e
    port_e=$(_sed_escape "$port")
    node_e=$(_sed_escape "$node_name")
    pass_e=$(_sed_escape "$password")
    prefix_e=$(_sed_escape "$redis_prefix")
    sed -e "s|%PORT%|$port_e|g" \
        -e "s|%NODE_NAME%|$node_e|g" \
        -e "s|%PASSWORD%|$pass_e|g" \
        -e "s|%REDIS_PREFIX%|$prefix_e|g" \
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