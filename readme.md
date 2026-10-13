# DVHOST WARP CLI

Version **2.0.0** — an English interactive manager for the official Cloudflare WARP Linux client.

## Install / update the menu

```bash
curl -fSL https://raw.githubusercontent.com/dev-ir/warp-cli/master/main.sh -o /tmp/dvhost-warp-menu.sh
sudo bash /tmp/dvhost-warp-menu.sh
```

The script installs the global command `warp-menu` and opens the menu. Select **Install / Update official client** to install or upgrade Cloudflare WARP. The menu does not install the client until you choose that action.

Existing shortcut:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dev-ir/warp-cli/master/main.sh)
```

Run the shortcut as root. File-based installation above is recommended because it checks download success before running.

## Supported systems

- Ubuntu 22.04 (jammy), 24.04 (noble), 26.04 (resolute)
- Debian 12 (bookworm), 13 (trixie)
- amd64 / arm64, Bash, coreutils and a running systemd system

Packages come from Cloudflare's signed stable APT repository. Actual package availability remains subject to the vendor. Unsupported codenames are rejected instead of silently installing packages for a different OS. Old signing keys are refreshed when installing/updating.

## Features

- Minimal blue/green/red English menu with server IP, optional country/ISP, version, daemon and connection status.
- Official client install/update; existing account and mode are preserved on update.
- Connect/disconnect without recreating the registration.
- Default local SOCKS5 proxy on `127.0.0.1:10808`; configurable validated port stored in `/etc/dvhost-warp.conf`.
- MASQUE or WireGuard protocol selection using current commands.
- Local proxy, full WARP + DoH, or DNS-only DoH mode.
- DNS Families: off, malware, malware + adult content.
- Apply an existing WARP+ Unlimited license with hidden input.
- Service start/stop/restart and boot enable/disable.
- Bounded SOCKS5 requests with proxy-side DNS and verification of `warp=on` / `warp=plus`.
- Quick reconnect and explicitly confirmed registration reset. Neither guarantees a different IP.
- Local journal logs and optional `warp-diag` archive; no automatic feedback submission.
- Atomic menu updates, explicit failures, guarded uninstall and no global `apt autoremove`.

New installations use **local proxy** so only applications explicitly using the proxy are routed through WARP. Full tunnel/DNS mode changes require confirmation because they can affect SSH and system networking. Families filtering is intended for WARP/DNS mode, not system DNS in local proxy mode.

Existing WARP installations keep their settings. On a migrated installation, check **Status / Settings**, then set the proxy port in the menu to synchronize the manager's port with the daemon.

## Usage

```bash
sudo warp-menu
curl --noproxy "" --proxy socks5h://127.0.0.1:10808 https://www.cloudflare.com/cdn-cgi/trace
systemctl status warp-svc
journalctl -u warp-svc -n 60 --no-pager
```

Account creation accepts Cloudflare's terms after confirmation. Registration reset removes the linked registration/license/enrollment; keep your WARP+ license available if you intend to reapply it. This manager targets consumer WARP; organization-managed Cloudflare One policy can override or restrict commands. Zero Trust enrollment is not automated.

Server country/ISP is an optional display-only lookup to `ipwho.is`, made once with a short timeout when Python 3 is available. In full tunnel mode, displayed egress metadata may describe the WARP route. Geolocation failure does not block the menu.

## Tests

```bash
bash -n main.sh
bash tests/test.sh
```

Tests mock WARP and package commands. They verify status parsing, port validation, safe configuration parsing, registration preservation, WARP trace checks and failed installation handling without changing the machine. Live client/package installation and tunnel connectivity must be verified on a supported server.

## Official references

- [Cloudflare Linux client and commands](https://developers.cloudflare.com/warp-client/get-started/linux/)
- [Official package repository and supported releases](https://pkg.cloudflareclient.com/)
- [Client modes](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/modes/)

## DVHOST CLOUD

[t.me/dvhost_cloud](https://t.me/dvhost_cloud)

A GitHub star is appreciated.

USDT (TRC20): `TVUqVMoCEe5DVUoxmPg8MwmgcHvZLqLjr4`
