#!/usr/bin/env bash
# Shared helpers for multi-SNI failover (server inbounds + client urltest).
set -euo pipefail

failover_repo_dir() {
    local d i
    for i in 1 2 3; do
        d="$(cd "$(dirname "${BASH_SOURCE[$i]:-${BASH_SOURCE[0]}}")" 2>/dev/null && pwd)" || continue
        while [[ "$d" != "/" ]]; do
            if [[ -f "${d}/config/failover-endpoints.json" ]]; then
                echo "$d"
                return 0
            fi
            d="$(dirname "$d")"
        done
    done
    echo "/opt/vpn_proxy_aeza"
}

failover_endpoints_file() {
    echo "${FAILOVER_ENDPOINTS_FILE:-$(failover_repo_dir)/config/failover-endpoints.json}"
}

failover_enabled() {
    [[ "${ENABLE_FAILOVER:-1}" == "1" ]]
}

failover_config_has_multi_inbound() {
    local config="${1:-/etc/sing-box/config.json}"
    [[ -f "$config" ]] || return 1
    [[ "$(jq '[.inbounds[] | select(.type == "vless")] | length' "$config")" -gt 1 ]]
}

failover_vless_link() {
    local uuid="$1" server_ip="$2" port="$3" server_name="$4" public_key="$5" short_id="$6" username="$7"
    echo "vless://${uuid}@${server_ip}:${port}?security=reality&sni=${server_name}&fp=chrome&pbk=${public_key}&sid=${short_id}&flow=xtls-rprx-vision&type=tcp#VPN-${username}-${server_name#www.}"
}

failover_build_vless_inbounds() {
    local users_json="$1" private_key="$2" short_ids_json="$3" endpoints_file="$4"
    jq -n \
        --argjson users "$users_json" \
        --arg private_key "$private_key" \
        --argjson short_ids "$short_ids_json" \
        --slurpfile ep "$endpoints_file" \
        '$ep[0].endpoints | map({
            type: "vless",
            tag: .tag,
            listen: "::",
            listen_port: .port,
            users: $users,
            tls: {
                enabled: true,
                server_name: .server_name,
                reality: {
                    enabled: true,
                    handshake: {
                        server: .server_name,
                        server_port: 443
                    },
                    private_key: $private_key,
                    short_id: $short_ids
                }
            }
        })'
}

failover_build_socks_inbound() {
    local socks_port="${1:-1080}"
    jq -n --argjson port "$socks_port" '{
        type: "socks",
        tag: "socks-bot",
        listen: "127.0.0.1",
        listen_port: $port
    }'
}

failover_merge_server_config() {
    local users_json="$1" private_key="$2" short_ids_json="$3" endpoints_file="$4" socks_port="${5:-1080}"
    local vless_inbounds socks_inbound
    vless_inbounds=$(failover_build_vless_inbounds "$users_json" "$private_key" "$short_ids_json" "$endpoints_file")
    socks_inbound=$(failover_build_socks_inbound "$socks_port")
    jq -n \
        --argjson vless "$vless_inbounds" \
        --argjson socks "$socks_inbound" \
        '{
            log: {
                level: "warn",
                timestamp: true,
                output: "/var/log/sing-box/sing-box.log"
            },
            inbounds: ($vless + [$socks]),
            outbounds: [
                {type: "direct", tag: "direct"},
                {type: "block", tag: "block"}
            ],
            route: {
                rules: [{ip_is_private: true, outbound: "block"}],
                final: "direct"
            }
        }'
}

failover_open_ufw_ports() {
    local endpoints_file="$1"
    jq -r '.endpoints[].port' "$endpoints_file" | sort -nu | while read -r port; do
        [[ "$port" == "443" ]] && continue
        ufw allow "${port}/tcp" comment "VLESS+Reality failover" >/dev/null 2>&1 || true
    done
}

failover_endpoint_ports() {
    local endpoints_file="$1"
    jq -r '.endpoints[].port' "$endpoints_file" | sort -nu | tr '\n' ' '
}

failover_add_user_all_vless() {
    local config="$1" username="$2" uuid="$3"
    local tmp
    tmp=$(mktemp)
    jq --arg name "$username" --arg uuid "$uuid" --arg flow "xtls-rprx-vision" '
        .inbounds |= map(
            if .type == "vless" then
                .users += [{name: $name, uuid: $uuid, flow: $flow}]
            else . end
        )
    ' "$config" > "$tmp"
    mv "$tmp" "$config"
}

failover_rotate_short_ids_all_vless() {
    local config="$1" short_ids_json="$2"
    local tmp
    tmp=$(mktemp)
    jq --argjson ids "$short_ids_json" '
        .inbounds |= map(
            if .type == "vless" then
                .tls.reality.short_id = $ids
            else . end
        )
    ' "$config" > "$tmp"
    mv "$tmp" "$config"
}

failover_build_creds_failover_json() {
    local endpoints_file="$1"
    jq -c '{enabled: true, urltest: .urltest, endpoints: .endpoints}' "$endpoints_file"
}

failover_regenerate_user_links() {
    local creds="$1"
    local server_ip public_key short_id
    server_ip=$(jq -r '.server_ip' "$creds")
    public_key=$(jq -r '.public_key' "$creds")
    short_id=$(jq -r '.short_ids.primary' "$creds")

    local tmp
    tmp=$(mktemp)
    jq --arg server_ip "$server_ip" --arg public_key "$public_key" --arg short_id "$short_id" '
        . as $root
        | .users |= map(
            . as $user
            | .link = (
                "vless://" + $user.uuid + "@" + $server_ip + ":" +
                (($root.failover.endpoints[0].port | tostring)) +
                "?security=reality&sni=" + $root.server_name +
                "&fp=chrome&pbk=" + $public_key + "&sid=" + $short_id +
                "&flow=xtls-rprx-vision&type=tcp#VPN-" + $user.name
            )
            | .failover_links = [
                $root.failover.endpoints[] as $ep |
                "vless://" + $user.uuid + "@" + $server_ip + ":" + ($ep.port | tostring) +
                "?security=reality&sni=" + $ep.server_name +
                "&fp=chrome&pbk=" + $public_key + "&sid=" + $short_id +
                "&flow=xtls-rprx-vision&type=tcp#VPN-" + $user.name + "-" + ($ep.server_name | sub("^www\\."; ""))
            ]
        )
    ' "$creds" > "$tmp"
    mv "$tmp" "$creds"
}

failover_write_vless_links_file() {
    local creds="$1" links_file="$2"
    {
        echo "# VLESS links — generated $(date -u)"
        echo "# Public key: $(jq -r '.public_key' "$creds")"
        echo "# Short ID: $(jq -r '.short_ids.primary' "$creds")"
        echo "# Failover: import client JSON from /root/vpn-backup/clients/<user>-singbox.json for auto-switch"
        echo ""
        jq -r '.users[] | "# " + .name, .link, (.failover_links[]? // empty), ""' "$creds"
    } > "$links_file"
}

failover_generate_client_config() {
    local creds="$1" username="$2" output="$3"
    local uuid server_ip public_key short_id
    uuid=$(jq -r --arg u "$username" '.users[] | select(.name == $u) | .uuid' "$creds")
    [[ -n "$uuid" && "$uuid" != "null" ]] || return 1

    server_ip=$(jq -r '.server_ip' "$creds")
    public_key=$(jq -r '.public_key' "$creds")
    short_id=$(jq -r '.short_ids.primary' "$creds")

    jq -n \
        --arg uuid "$uuid" \
        --arg server_ip "$server_ip" \
        --arg public_key "$public_key" \
        --arg short_id "$short_id" \
        --arg username "$username" \
        --argjson failover "$(jq '.failover' "$creds")" \
        --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '
        ($failover.endpoints | map(.tag)) as $tags
        | {
            log: {level: "warn", timestamp: true},
            dns: {
                servers: [{tag: "google", address: "https://dns.google/dns-query", detour: "auto"}],
                strategy: "prefer_ipv4"
            },
            inbounds: [{
                type: "mixed",
                tag: "mixed-in",
                listen: "127.0.0.1",
                listen_port: 2080,
                sniff: true
            }],
            outbounds: (
                [$failover.endpoints[] | {
                    type: "vless",
                    tag: .tag,
                    server: $server_ip,
                    server_port: .port,
                    uuid: $uuid,
                    flow: "xtls-rprx-vision",
                    network: "tcp",
                    tls: {
                        enabled: true,
                        server_name: .server_name,
                        utls: {enabled: true, fingerprint: "chrome"},
                        reality: {
                            enabled: true,
                            public_key: $public_key,
                            short_id: $short_id
                        }
                    }
                }]
                + [{
                    type: "urltest",
                    tag: "auto",
                    outbounds: $tags,
                    url: $failover.urltest.url,
                    interval: $failover.urltest.interval,
                    tolerance: $failover.urltest.tolerance,
                    idle_timeout: $failover.urltest.idle_timeout,
                    interrupt_exist_connections: $failover.urltest.interrupt_exist_connections
                }]
                + [
                    {type: "direct", tag: "direct"},
                    {type: "block", tag: "block"}
                ]
            ),
            route: {
                rules: [
                    {protocol: "dns", outbound: "auto"},
                    {ip_is_private: true, outbound: "direct"}
                ],
                final: "auto",
                auto_detect_interface: true
            },
            meta: {
                username: $username,
                generated_at: $generated_at,
                note: "Import into sing-box / Hiddify. Proxy: socks5://127.0.0.1:2080 — auto-switches SNI on timeout."
            }
        }
        ' > "$output"
}

failover_generate_all_client_configs() {
    local creds="$1" clients_dir="$2"
    mkdir -p "$clients_dir"
    chmod 700 "$clients_dir"
    jq -r '.users[].name' "$creds" | while read -r name; do
        failover_generate_client_config "$creds" "$name" "${clients_dir}/${name}-singbox.json"
        chmod 600 "${clients_dir}/${name}-singbox.json"
    done
}

# Rebuild server config + credentials from failover-endpoints.json (idempotent).
failover_apply_to_server() {
    local config="${1:-/etc/sing-box/config.json}"
    local creds="${2:-/root/vpn-backup/credentials.json}"
    local endpoints_file="${3:-$(failover_endpoints_file)}"
    local script_dir="${4:-}"

    [[ -f "$config" ]] || return 1
    [[ -f "$creds" ]] || return 1
    [[ -f "$endpoints_file" ]] || return 1

    local users_json private_key short_ids_json socks_port primary_sn
    users_json=$(jq '[.inbounds[] | select(.type == "vless") | .users[]] | unique_by(.uuid)' "$config")
    private_key=$(jq -r '.inbounds[] | select(.type == "vless") | .tls.reality.private_key' "$config" | head -1)
    short_ids_json=$(jq '[.inbounds[] | select(.type == "vless") | .tls.reality.short_id] | .[0]' "$config")
    socks_port=$(jq -r '.inbounds[] | select(.type == "socks") | .listen_port' "$config" 2>/dev/null || echo "1080")
    [[ "$socks_port" == "null" || -z "$socks_port" ]] && socks_port=1080
    primary_sn=$(jq -r '.endpoints[0].server_name' "$endpoints_file")

    failover_merge_server_config "$users_json" "$private_key" "$short_ids_json" "$endpoints_file" "$socks_port" \
        > "$config"
    chmod 600 "$config"
    sing-box check -c "$config" || return 1

    failover_open_ufw_ports "$endpoints_file"

    jq \
        --argjson fo "$(failover_build_creds_failover_json "$endpoints_file")" \
        --arg sn "$primary_sn" \
        '.failover = $fo | .server_name = $sn' \
        "$creds" > "${creds}.tmp" && mv "${creds}.tmp" "$creds"
    failover_regenerate_user_links "$creds"
    failover_write_vless_links_file "$creds" "/root/vpn-backup/vless-links.txt"
    chmod 600 "$creds" "/root/vpn-backup/vless-links.txt"

    systemctl reload singbox 2>/dev/null || systemctl restart singbox
    sleep 1
    systemctl is-active singbox &>/dev/null || return 1

    [[ -n "$script_dir" ]] && bash "${script_dir}/generate-client-config.sh"
    return 0
}
