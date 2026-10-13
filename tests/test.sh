#!/usr/bin/env bash
set -euo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -f "$BASE/main.sh" ]]; then
    source "$BASE/main.sh"
else
    source "$(dirname -- "${BASH_SOURCE[0]}")/main.sh"
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
CONFIG_PATH="$tmp/port.conf"
calls="$tmp/calls"
installed() { return 0; }
timeout() { shift; "$@"; }
warp-cli() {
    if [[ "${1:-}" == --accept-tos ]]; then shift; fi
    [[ "$*" == status ]] && { printf '%s\n' "$mock_status"; return 0; }
    printf '%s\n' "$*" >> "$calls"
    if [[ "$*" == "registration show" ]]; then return "$registration_result"; fi
    return 0
}
mock_status="Status update: Disconnected"
registration_result=0
if connected; then echo "FAIL: Disconnected recognized as Connected"; exit 1; fi
mock_status="Status update: Connected"
connected
mock_status="Connected"
connected
mock_status="Connecting"
if connected; then exit 1; fi
for port in 1 10808 65535 00080; do valid_port "$port"; done
for port in 0 65536 abc '12;echo bad' 99999999999 -1; do
    if valid_port "$port"; then echo "FAIL: invalid port accepted"; exit 1; fi
done
printf 'PROXY_PORT=12345\nEVIL=$(touch /tmp/warp-test-should-not-exist)\n' > "$CONFIG_PATH"
load_config
[[ "$PROXY_PORT" == 12345 ]]
printf 'PROXY_PORT=bad\n' > "$CONFIG_PATH"
load_config
[[ "$PROXY_PORT" == 12345 ]]
save_config
[[ "$(cat "$CONFIG_PATH")" == PROXY_PORT=12345 ]]
ensure_registration
[[ "$(cat "$calls")" == "registration show" ]]
service_ready() { return 0; }
wait_connected() { return 0; }
: > "$calls"
connect_client
[[ "$(cat "$calls")" == $'registration show\nconnect' ]]
registration_result=1
confirm() { return 1; }
: > "$calls"
if connect_client; then echo "FAIL: declined registration connected"; exit 1; fi
[[ "$(cat "$calls")" == "registration show" ]]
confirm() { return 0; }
: > "$calls"
ensure_registration
[[ "$(cat "$calls")" == $'registration show\nregistration new' ]]
proxy_trace() { printf 'ip=1.2.3.4\nwarp=off\n'; }
if test_proxy; then echo "FAIL: non-WARP connection passed"; exit 1; fi
proxy_trace() { printf 'ip=1.2.3.4\nwarp=on\n'; }
test_proxy
setup_repository() { return 1; }
apt-get() { echo "APT SHOULD NOT RUN" >> "$calls"; return 0; }
: > "$calls"
if install_client; then echo "FAIL: failed repository installation succeeded"; exit 1; fi
[[ ! -s "$calls" ]]
echo "PASS: status, ports, config, registration preservation, proxy verification and install failure."
