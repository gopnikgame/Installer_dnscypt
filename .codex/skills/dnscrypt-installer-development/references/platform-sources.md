# Primary platform sources

Refresh these sources before changing version-sensitive behavior.

- DNSCrypt-proxy upstream and releases: https://github.com/DNSCrypt/dnscrypt-proxy and https://github.com/DNSCrypt/dnscrypt-proxy/releases
- DNSCrypt example configuration (`listen_addresses`, privilege drop, logging): https://github.com/DNSCrypt/dnscrypt-proxy/blob/master/dnscrypt-proxy/example-dnscrypt-proxy.toml
- Devuan init policy (SysVinit default; OpenRC and runit available): https://www.devuan.org/os/init-freedom
- Debian SysV init helper: https://manpages.debian.org/init-d-script
- Debian runlevel registration: https://manpages.debian.org/testing/init-system-helpers/update-rc.d.8.en.html
- OpenRC service script guide: https://github.com/OpenRC/openrc/blob/master/service-script-guide.md
- OpenRC user guide (`rc-service`, `rc-update`): https://github.com/OpenRC/openrc/blob/master/user-guide.md
- systemd unit documentation: https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- OpenWrt procd init scripts: https://openwrt.org/docs/guide-developer/procd-init-scripts

Key invariants:

- Distribution family does not identify PID 1.
- `/etc/resolv.conf` accepts nameserver addresses, not arbitrary DNS ports.
- PID files used by a privileged service manager must be kept in a root-controlled runtime path.
- DNSCrypt should run in the foreground under service supervision and be validated with `-check` before activation.
