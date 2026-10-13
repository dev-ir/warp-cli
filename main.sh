#!/usr/bin/env bash
# DVHOST WARP CLI: official Cloudflare client manager.
set -u

VERSION="2.0.0"
SCRIPT_PATH="/usr/local/bin/warp-menu"
CONFIG_PATH="/etc/dvhost-warp.conf"
REPO_FILE="/etc/apt/sources.list.d/cloudflare-client.list"
KEY_FILE="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
SOURCE_URL="https://raw.githubusercontent.com/dev-ir/warp-cli/master/main.sh"
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"
PROXY_PORT=10808
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
BLUE=$'\033[34m'; CYAN=$'\033[36m'; NC=$'\033[0m'

info() { printf '%s%s%s\n' "$CYAN" "$*" "$NC"; }
ok() { printf '%s%s%s\n' "$GREEN" "$*" "$NC"; }
fail() { printf '%s%s%s\n' "$RED" "$*" "$NC" >&2; return 1; }
confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]]
}
installed() { command -v warp-cli >/dev/null 2>&1; }
cli() { timeout 20 warp-cli --accept-tos "$@"; }
require_client() { installed || { fail "WARP is not installed. Select Install first."; return 1; }; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
load_config() {
    local key value
    [[ -f "$CONFIG_PATH" ]] || return 0
    while IFS='=' read -r key value; do
        if [[ "$key" == "PROXY_PORT" ]] && valid_port "$value"; then
            PROXY_PORT=$((10#$value))
        fi
    done < "$CONFIG_PATH"
}
save_config() {
    local temp
    temp=$(mktemp "${CONFIG_PATH}.XXXXXX") || return 1
    printf 'PROXY_PORT=%s\n' "$PROXY_PORT" > "$temp"
    chmod 600 "$temp" && mv -f "$temp" "$CONFIG_PATH"
}
connected() {
    local output
    output=$(cli status 2>/dev/null) || return 1
    printf '%s\n' "$output" | grep -Eq '^[[:space:]]*(Status update:[[:space:]]*)?Connected[[:space:]]*$'
}
service_ready() {
    systemctl start warp-svc || return 1
    local attempt
    for attempt in {1..10}; do
        cli status >/dev/null 2>&1 && return 0
        sleep 1
    done
    fail "WARP daemon is not ready. Check journalctl -u warp-svc."
}
ensure_registration() {
    local output
    output=$(cli registration show 2>&1) && return 0
    printf '%s\n' "$output"
    confirm "Registration unavailable. Create a registration (accept Cloudflare terms)?" || return 1
    cli registration new
}
wait_connected() {
    local attempt
    for attempt in {1..15}; do
        connected && { ok "WARP connected."; return 0; }
        sleep 1
    done
    cli status
    fail "Connection not ready after 15 checks. Run diagnostics."
}
connect_client() {
    require_client && service_ready && ensure_registration || return 1
    cli connect && wait_connected
}
disconnect_client() { require_client && cli disconnect; }
proxy_trace() {
    curl --fail --silent --show-error --connect-timeout 5 --max-time 12 \
        --noproxy "" --proxy "socks5h://127.0.0.1:$PROXY_PORT" "$TRACE_URL"
}
test_proxy() {
    require_client || return 1
    info "Testing SOCKS5: 127.0.0.1:$PROXY_PORT"
    local trace address warp
    trace=$(proxy_trace) || { fail "Proxy request failed. Check mode, port and connection."; return 1; }
    address=$(awk -F= '$1=="ip" {print $2}' <<< "$trace")
    warp=$(awk -F= '$1=="warp" {print $2}' <<< "$trace")
    printf 'Egress IP : %s\nWARP      : %s\n' "${address:-N/A}" "${warp:-N/A}"
    [[ -n "$address" && "$warp" =~ ^(on|plus)$ ]] || { fail "WARP egress was not verified."; return 1; }
    ok "WARP proxy verified."
}
detect_platform() {
    [[ -r /etc/os-release ]] || { fail "Missing /etc/os-release."; return 1; }
    # Standard distribution-owned metadata.
    . /etc/os-release
    case "${ID:-}:${VERSION_CODENAME:-}" in
        ubuntu:jammy|ubuntu:noble|ubuntu:resolute|debian:bookworm|debian:trixie)
            CODENAME="$VERSION_CODENAME" ;;
        *) fail "Supported: Ubuntu 22.04/24.04/26.04, Debian 12/13. No codename substitution."; return 1 ;;
    esac
    case "$(dpkg --print-architecture)" in
        amd64|arm64) ;;
        *) fail "Only amd64 and arm64 package architectures are supported."; return 1 ;;
    esac
    [[ -d /run/systemd/system ]] || { fail "A running systemd system is required."; return 1; }
}
setup_repository() {
    detect_platform || return 1
    if ! command -v curl >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1 ||
        ! command -v ip >/dev/null 2>&1 || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
        # Temporarily exclude our old repository so an expired WARP key
        # cannot block installation of the tools needed to refresh that key.
        local previous="" result=0
        if [[ -f "$REPO_FILE" ]]; then
            previous=$(mktemp) || return 1
            cp "$REPO_FILE" "$previous" && rm -f "$REPO_FILE" || return 1
        fi
        apt-get update && apt-get install -y ca-certificates curl gnupg iproute2 || result=$?
        if [[ -n "$previous" ]]; then
            install -m 644 "$previous" "$REPO_FILE" || result=1
            rm -f "$previous"
        fi
        [[ "$result" -eq 0 ]] || return "$result"
    fi
    local temp
    temp=$(mktemp -d) || return 1
    if ! curl -fSL --connect-timeout 10 --max-time 60 --retry 2 \
        https://pkg.cloudflareclient.com/pubkey.gpg -o "$temp/pubkey.gpg" ||
        ! gpg --batch --yes --dearmor -o "$temp/keyring.gpg" "$temp/pubkey.gpg"; then
        rm -rf "$temp"
        fail "Could not refresh the official repository signing key."
        return 1
    fi
    install -m 644 "$temp/keyring.gpg" "$KEY_FILE" || { rm -rf "$temp"; return 1; }
    rm -rf "$temp"
    printf 'deb [arch=%s signed-by=%s] https://pkg.cloudflareclient.com/ %s main\n' \
        "$(dpkg --print-architecture)" "$KEY_FILE" "$CODENAME" > "$REPO_FILE"
    apt-get update
}
install_client() {
    local existing=false
    installed && existing=true
    setup_repository && apt-get install -y cloudflare-warp || return 1
    systemctl enable --now warp-svc && service_ready || return 1
    if [[ "$existing" == true ]]; then
        ok "Client updated. Existing registration and mode preserved."
        return 0
    fi
    ensure_registration && cli mode proxy && cli proxy port "$PROXY_PORT" || return 1
    save_config || return 1
    cli connect && wait_connected
}
change_port() {
    require_client || return 1
    local port
    read -r -p "Local proxy port [$PROXY_PORT]: " port || return 1
    port=${port:-$PROXY_PORT}
    valid_port "$port" || { fail "Enter a port from 1 to 65535."; return 1; }
    port=$((10#$port))
    if [[ "$port" != "$PROXY_PORT" ]] && ss -H -lnt "sport = :$port" | grep -q .; then
        fail "Port is already in use."; return 1
    fi
    cli proxy port "$port" || return 1
    PROXY_PORT="$port"
    save_config && ok "Proxy port saved: $PROXY_PORT. Run Test Proxy to verify."
}
change_protocol() {
    require_client || return 1
    local choice protocol was_connected=false
    printf '[ 1 ] MASQUE (Cloudflare default)\n[ 2 ] WireGuard\n[ 0 ] Back\n'
    read -r -p "Protocol: " choice || return 1
    case "$choice" in 1) protocol=MASQUE;; 2) protocol=WireGuard;; 0) return 0;; *) fail "Invalid choice."; return 1;; esac
    cli tunnel protocol --help >/dev/null 2>&1 || { fail "Protocol selection unavailable. Update WARP first."; return 1; }
    connected && was_connected=true
    cli disconnect && cli tunnel protocol set "$protocol" || return 1
    [[ "$was_connected" == false ]] || { cli connect && wait_connected; }
}
change_mode() {
    require_client || return 1
    local choice mode was_connected=false
    printf '[ 1 ] Local proxy (recommended for servers)\n[ 2 ] Full tunnel + DoH\n[ 3 ] DNS only (DoH)\n[ 0 ] Back\n'
    read -r -p "Mode: " choice || return 1
    case "$choice" in 1) mode=proxy;; 2) mode=warp+doh;; 3) mode=doh;; 0) return 0;; *) fail "Invalid choice."; return 1;; esac
    if [[ "$mode" != proxy ]]; then
        confirm "This changes system routing/DNS and may interrupt SSH. Continue?" || return 0
    fi
    connected && was_connected=true
    cli disconnect && cli mode "$mode" || return 1
    if [[ "$mode" == proxy ]]; then cli proxy port "$PROXY_PORT" || return 1; fi
    [[ "$was_connected" == false ]] || { cli connect && wait_connected; }
}
families() {
    require_client || return 1
    local choice mode
    printf '[ 1 ] Off\n[ 2 ] Block malware\n[ 3 ] Block malware and adult content\n[ 0 ] Back\n'
    read -r -p "DNS filter: " choice || return 1
    case "$choice" in 1) mode=off;; 2) mode=malware;; 3) mode=full;; 0) return 0;; *) fail "Invalid choice."; return 1;; esac
    info "Families filtering applies to WARP/DNS modes; local proxy does not filter system DNS."
    cli dns families "$mode"
}
license() {
    require_client || return 1
    local key
    read -r -s -p "Existing WARP+ Unlimited license key (empty to cancel): " key || return 1
    printf '\n'
    [[ -n "$key" ]] || return 0
    cli registration license "$key"
    local result=$?
    unset key
    return "$result"
}
new_identity() {
    require_client && service_ready || return 1
    confirm "Delete registration and linked license/enrollment? IP change is not guaranteed." || return 0
    cli disconnect && cli registration delete && cli registration new || return 1
    info "New registration created. Check Status / Settings after reconnection."
    cli connect && wait_connected
}
quick_reconnect() {
    require_client || return 1
    local old new
    old=$(proxy_trace 2>/dev/null | awk -F= '$1=="ip" {print $2}')
    cli disconnect && cli connect && wait_connected || return 1
    new=$(proxy_trace 2>/dev/null | awk -F= '$1=="ip" {print $2}')
    printf 'Previous proxy IP : %s\nCurrent proxy IP  : %s\n' "${old:-N/A}" "${new:-N/A}"
    info "Reconnection does not guarantee a different egress IP."
}
status() {
    require_client || return 1
    cli --version
    systemctl --no-pager status warp-svc || true
    cli status
    cli settings
    info "Manager proxy port: $PROXY_PORT (verify actual port in settings above)."
}
service_menu() {
    require_client || return 1
    local choice
    printf '[ 1 ] Start\n[ 2 ] Stop\n[ 3 ] Restart\n[ 4 ] Enable at boot\n[ 5 ] Disable at boot\n[ 0 ] Back\n'
    read -r -p "Service: " choice || return 1
    case "$choice" in
        1) systemctl start warp-svc;; 2) systemctl stop warp-svc;;
        3) systemctl restart warp-svc;; 4) systemctl enable warp-svc;;
        5) systemctl disable warp-svc;; 0) return 0;;
        *) fail "Invalid choice.";;
    esac
}
diagnostics() {
    require_client || return 1
    journalctl -u warp-svc -n 60 --no-pager
    if command -v warp-diag >/dev/null 2>&1 && confirm "Create a local diagnostic archive in /root?"; then
        (cd /root && warp-diag)
    fi
}
install_menu_file() {
    local source="$1" temp
    temp=$(mktemp "${SCRIPT_PATH}.XXXXXX") || return 1
    if install -m 755 "$source" "$temp" && mv -f "$temp" "$SCRIPT_PATH"; then
        return 0
    fi
    rm -f "$temp"
    return 1
}
update_menu() {
    local temp
    temp=$(mktemp) || return 1
    if curl -fSL --connect-timeout 10 --max-time 60 "$SOURCE_URL" -o "$temp" &&
        bash -n "$temp" && grep -q '^# DVHOST WARP CLI:' "$temp" &&
        install_menu_file "$temp"; then
        rm -f "$temp"
        ok "Menu updated. Run warp-menu again to load the new version."
    else
        rm -f "$temp"
        fail "Menu update failed; current menu retained."
    fi
}
remove_client() {
    confirm "Purge the Cloudflare WARP package and repository?" || return 0
    apt-get purge -y cloudflare-warp || return 1
    rm -f "$REPO_FILE" "$KEY_FILE"
    ok "Package removed. Registration data is not manually deleted."
    if confirm "Also remove warp-menu and its port configuration?"; then
        rm -f "$SCRIPT_PATH" "$CONFIG_PATH"
    fi
}
server_info() {
    SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')
    SERVER_COUNTRY="N/A"; SERVER_ISP="N/A"
    # Optional display-only lookup; bounded and performed once, never on each redraw.
    local geo
    if command -v python3 >/dev/null 2>&1; then
        geo=$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 3 https://ipwho.is/ 2>/dev/null) || return 0
        SERVER_COUNTRY=$(printf '%s' "$geo" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("country","N/A"))' 2>/dev/null) || SERVER_COUNTRY="N/A"
        SERVER_ISP=$(printf '%s' "$geo" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("connection",{}).get("isp","N/A"))' 2>/dev/null) || SERVER_ISP="N/A"
    fi
}
draw_menu() {
    [[ -t 1 ]] && clear
    local state="Not installed" daemon="Not installed" core="N/A"
    if installed; then
        state=$(cli status 2>/dev/null) || state="Daemon unavailable"
        daemon=$(systemctl is-active warp-svc 2>/dev/null) || true
        core=$(warp-cli --version 2>/dev/null) || core="N/A"
    fi
    printf '%s+----------------------------------------------------------+\n' "$BLUE"
    printf '|                 DVHOST WARP CLI  v%-22s|\n' "$VERSION"
    printf '+----------------------------------------------------------+%s\n' "$NC"
    printf '  Server    %s / %s / %s\n' "${SERVER_IP:-N/A}" "${SERVER_COUNTRY:-N/A}" "${SERVER_ISP:-N/A}"
    printf '  Core      %s\n  Service   %s\n  Status    %s\n  Proxy     127.0.0.1:%s\n' "$core" "$daemon" "$state" "$PROXY_PORT"
    printf '%s------------------------------------------------------------%s\n' "$BLUE" "$NC"
    printf '%s  [ 1 ] Install / Update official client\n  [ 2 ] Connect                 [ 3 ] Disconnect\n  [ 4 ] Status / Settings       [ 5 ] Test SOCKS5 proxy\n  [ 6 ] Proxy port              [ 7 ] Tunnel protocol\n  [ 8 ] Connection mode         [ 9 ] DNS Families\n  [10 ] WARP+ license            [11 ] Service manager\n  [12 ] Quick reconnect          [13 ] New registration\n  [14 ] Diagnostics              [15 ] Update menu%s\n' "$GREEN" "$NC"
    printf '%s  [16 ] Uninstall%s\n  [ 0 ] Exit\n' "$RED" "$NC"
    printf '%s------------------------------------------------------------%s\n  t.me/dvhost_cloud\n\n' "$BLUE" "$NC"
}
main() {
    [[ "$EUID" -eq 0 ]] || { fail "Run as root: sudo bash main.sh"; return 1; }
    export LC_ALL=C
    command -v timeout >/dev/null 2>&1 || { fail "Install coreutils first."; return 1; }
    if [[ "${BASH_SOURCE[0]}" != "$SCRIPT_PATH" ]]; then
        if [[ "${BASH_SOURCE[0]}" == /dev/fd/* || "${BASH_SOURCE[0]}" == /proc/*/fd/* ]]; then
            # A process-substitution pipe cannot be copied after Bash consumes it.
            update_menu || return 1
        else
            install_menu_file "${BASH_SOURCE[0]}" || return 1
        fi
        ok "Installed global command: warp-menu"
    fi
    load_config
    server_info
    local choice
    while true; do
        draw_menu
        read -r -p "Select: " choice || break
        case "$choice" in
            1) install_client;; 2) connect_client;; 3) disconnect_client;;
            4) status;; 5) test_proxy;; 6) change_port;; 7) change_protocol;;
            8) change_mode;; 9) families;; 10) license;; 11) service_menu;;
            12) quick_reconnect;; 13) new_identity;; 14) diagnostics;;
            15) update_menu;; 16) remove_client;; 0) break;;
            *) fail "Invalid choice.";;
        esac
        read -r -p "Press Enter to return..." choice || break
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
