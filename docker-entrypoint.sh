#!/bin/sh
set -eu

state_dir=${STATE_DIR:-/var/lib/opencode2api}
config_path=${CONFIG_PATH:-$state_dir/config.json}
config_seed_path=${CONFIG_SEED_PATH:-}
# Empty means "defer to config.json". Only an explicitly provided value becomes
# a command-line override, so the file stays authoritative as documented.
listen_address=${LISTEN_ADDRESS:-}
webui_listen_address=${WEBUI_LISTEN_ADDRESS:-}
# UNIFIED defaults to 1: a single-port host such as blitz.cloud only exposes
# one port, so the API (/v1/*, /healthz) and the WebUI (/api/*, /) share the
# listener bound by LISTEN_ADDRESS (or cfg.Listen when that is empty). Set
# UNIFIED=0 to restore the legacy two-listener behaviour (API on cfg.Listen and
# WebUI on cfg.WebUI.Listen).
unified=${UNIFIED:-1}

if [ "$(id -u)" = "0" ]; then
    mkdir -p "$state_dir"
    chown opencode2api:opencode2api "$state_dir"
    exec su-exec opencode2api:opencode2api "$0" "$@"
fi

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

# The example config binds the API to loopback, which is unreachable from
# outside a container through published ports. In unified mode that default
# becomes the single :80 listener; in legacy mode it becomes the :8080 API
# listener. Only the loopback default is rewritten, so any other address the
# operator wrote is left exactly as-is.
seed_container_listen() {
    case "$unified" in
        0)
            if grep -q '"listen"[[:space:]]*:[[:space:]]*"127.0.0.1:8080"' "$1"; then
                sed -i 's|"listen"[[:space:]]*:[[:space:]]*"127.0.0.1:8080"|"listen": "0.0.0.0:8080"|' "$1"
                printf '%s\n' "Seeded $1 with listen 0.0.0.0:8080 so it is reachable through published ports."
            fi
            ;;
        *)
            if grep -q '"listen"[[:space:]]*:[[:space:]]*"127.0.0.1:8080"' "$1"; then
                sed -i 's|"listen"[[:space:]]*:[[:space:]]*"127.0.0.1:8080"|"listen": "0.0.0.0:80"|' "$1"
                printf '%s\n' "Seeded $1 with unified listen 0.0.0.0:80 so the API and WebUI share a single published port."
            fi
            ;;
    esac
}

if [ ! -f "$config_path" ]; then
    mkdir -p "$(dirname "$config_path")"
    if [ -n "$config_seed_path" ] && [ -f "$config_seed_path" ]; then
        cp "$config_seed_path" "$config_path"
        seed_container_listen "$config_path"
        printf '%s\n' "Initialized $config_path from $config_seed_path."
    else
        cp /app/config.example.json "$config_path"
        seed_container_listen "$config_path"
        printf '%s\n' \
            "config.json not found; created $config_path. Set API keys or enable anonymous mode, and change the WebUI password before use."
    fi
fi

set -- /usr/local/bin/opencode2api -config "$config_path"
case "$unified" in
    0) ;;
    *) set -- "$@" -unified ;;
esac
if [ -n "$listen_address" ]; then
    set -- "$@" -listen "$listen_address"
fi
if [ -n "$webui_listen_address" ] && [ "$unified" = "0" ]; then
    set -- "$@" -web-listen "$webui_listen_address"
fi
exec "$@"
