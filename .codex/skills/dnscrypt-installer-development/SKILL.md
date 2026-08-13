---
name: dnscrypt-installer-development
description: Develop, review, test, and maintain the Installer_dnscypt Bash project and DNSCrypt-proxy deployments across systemd, Devuan/SysVinit, OpenRC, runit, and OpenWrt/procd. Use for OS/init detection, service lifecycle, resolv.conf handling, port 53 conflicts, installation, upgrades, rollback, diagnostics, release verification, or repository documentation in this project.
---

# DNSCrypt Installer Development

## Work from evidence

1. Inspect `lib/common.sh`, `lib/system.sh`, the affected module, update/download lists, rollback paths, and tests before editing.
2. Read `references/platform-sources.md` for init or DNS behavior. Refresh links and conclusions from official upstream sources when behavior or versions may have changed.
3. Separate these facts:
   - distribution and `ID_LIKE` from `os-release`;
   - package-manager family;
   - active init/service manager;
   - resolver currently owning port 53.
4. Preserve OpenWrt/procd as a separate POSIX `sh` path.

## Detect safely

- Treat systemd as active only when `/run/systemd/system` exists and `systemctl` is callable.
- Detect OpenRC before generic SysV compatibility commands.
- Detect runit by its service tooling, not only by package presence.
- Treat Devuan as Debian-compatible for packages, never as proof of systemd.
- Stop before mutations when init is unknown.

## Manage services through one boundary

Use `service_is_active`, `service_start`, `service_stop`, `service_restart`, `service_enable`, `service_disable`, `service_status`, and `service_logs`. Do not add direct `systemctl`, `journalctl`, `rc-service`, `sv`, or `service` calls outside `lib/system.sh`, except operations inherently specific to `systemd-resolved` and guarded by `INIT_SYSTEM=systemd`.

Generate native service definitions:

- systemd: unit with least privileges and `CAP_NET_BIND_SERVICE`;
- SysVinit: LSB header plus `start-stop-daemon` and a root-controlled PID file;
- OpenRC: `#!/sbin/openrc-run`, declarative command fields, root-controlled PID file;
- runit: `/etc/sv/<name>/run`, foreground process, `chpst` privilege drop;
- OpenWrt: existing procd module.

## Protect DNS availability

- Validate configuration with `dnscrypt-proxy -check` before starting.
- Confirm port 53 ownership before changing resolver configuration.
- Back up `resolv.conf` and resolver settings before mutation.
- Start DNSCrypt and prove `dig @127.0.0.1` works before pointing the host resolver to it.
- Never use port 5353 as a transparent fallback for `/etc/resolv.conf`; it has no nameserver-port syntax.
- Do not manipulate `systemd-resolved` outside active systemd.
- Keep rollback init-aware and restore resolver state on failure.

## Verify

Run:

```bash
bash -n main.sh quick_install.sh lib/*.sh modules/*.sh tests/*.sh
bash tests/test_system_detection.sh
git diff --check
```

Test mocked detection for systemd, SysVinit, OpenRC, runit, OpenWrt, Devuan `os-release`, and unknown init. For installation changes, also test the generated service files in disposable systems or containers before claiming runtime compatibility.

## Report

State detected/supported platforms, resolver changes, rollback behavior, tests actually run, official sources refreshed, untested runtime combinations, branch, signed commit, and push destination.
