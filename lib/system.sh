#!/bin/bash

# Distribution detection and init/service abstraction.
# Keep distribution and init detection separate: Devuan is Debian-compatible
# but normally runs SysVinit, and can also run OpenRC or runit.

SYSTEM_ROOT="${DNSCRYPT_SYSTEM_ROOT:-}"

system_path() {
    printf '%s%s\n' "$SYSTEM_ROOT" "$1"
}

read_os_release_value() {
    local key="$1" file value
    for file in "$(system_path /etc/os-release)" "$(system_path /usr/lib/os-release)"; do
        [ -r "$file" ] || continue
        value=$(sed -n "s/^${key}=//p" "$file" | head -n 1)
        value=${value#\"}; value=${value%\"}
        value=${value#\'}; value=${value%\'}
        printf '%s\n' "$value"
        return 0
    done
    return 1
}

detect_distribution() {
    local id
    id=$(read_os_release_value ID 2>/dev/null || true)
    [ -n "$id" ] && { printf '%s\n' "$id"; return 0; }
    [ -f "$(system_path /etc/openwrt_release)" ] && { echo openwrt; return 0; }
    [ -f "$(system_path /etc/debian_version)" ] && { echo debian; return 0; }
    [ -f "$(system_path /etc/redhat-release)" ] && { echo rhel; return 0; }
    [ -f "$(system_path /etc/arch-release)" ] && { echo arch; return 0; }
    echo unknown
    return 1
}

detect_distribution_family() {
    local id like
    id=$(detect_distribution 2>/dev/null || true)
    like=$(read_os_release_value ID_LIKE 2>/dev/null || true)
    case " $id $like " in
        *" openwrt "*) echo openwrt ;;
        *" debian "*|*" ubuntu "*|*" devuan "*) echo debian ;;
        *" rhel "*|*" fedora "*|*" centos "*) echo redhat ;;
        *" arch "*) echo arch ;;
        *) echo unknown; return 1 ;;
    esac
}

detect_init_system() {
    [ -f "$(system_path /etc/openwrt_release)" ] && { echo procd; return 0; }
    [ -d "$(system_path /run/systemd/system)" ] && command -v systemctl >/dev/null 2>&1 && { echo systemd; return 0; }
    command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 && { echo openrc; return 0; }
    command -v sv >/dev/null 2>&1 && { echo runit; return 0; }
    command -v service >/dev/null 2>&1 && { echo sysvinit; return 0; }
    [ -d "$(system_path /etc/init.d)" ] && { echo sysvinit; return 0; }
    echo unknown
    return 1
}

INIT_SYSTEM="${DNSCRYPT_INIT_SYSTEM:-$(detect_init_system 2>/dev/null || echo unknown)}"

service_is_active() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet "$name" ;;
        openrc) rc-service "$name" status >/dev/null 2>&1 ;;
        runit) sv status "$name" 2>/dev/null | grep -q '^run:' ;;
        sysvinit) service "$name" status >/dev/null 2>&1 ;;
        procd) /etc/init.d/"$name" running >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

service_start() {
    case "$INIT_SYSTEM" in
        systemd) systemctl start "$1" ;;
        openrc) rc-service "$1" start ;;
        runit) sv up "$1" ;;
        sysvinit) service "$1" start ;;
        procd) /etc/init.d/"$1" start ;;
        *) return 1 ;;
    esac
}

service_stop() {
    case "$INIT_SYSTEM" in
        systemd) systemctl stop "$1" ;;
        openrc) rc-service "$1" stop ;;
        runit) sv down "$1" ;;
        sysvinit) service "$1" stop ;;
        procd) /etc/init.d/"$1" stop ;;
        *) return 1 ;;
    esac
}

service_restart() {
    case "$INIT_SYSTEM" in
        systemd) systemctl restart "$1" ;;
        openrc) rc-service "$1" restart ;;
        runit) sv restart "$1" ;;
        sysvinit) service "$1" restart ;;
        procd) /etc/init.d/"$1" restart ;;
        *) return 1 ;;
    esac
}

service_enable() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd) systemctl enable "$name" ;;
        openrc) rc-update add "$name" default ;;
        runit) mkdir -p /etc/service; ln -sfn "/etc/sv/$name" "/etc/service/$name" ;;
        sysvinit) update-rc.d "$name" defaults ;;
        procd) /etc/init.d/"$name" enable ;;
        *) return 1 ;;
    esac
}

service_disable() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd) systemctl disable "$name" ;;
        openrc) rc-update del "$name" default ;;
        runit) rm -f "/etc/service/$name" ;;
        sysvinit) update-rc.d -f "$name" remove ;;
        procd) /etc/init.d/"$name" disable ;;
        *) return 1 ;;
    esac
}

service_status() {
    case "$INIT_SYSTEM" in
        systemd) systemctl status "$1" --no-pager ;;
        openrc) rc-service "$1" status ;;
        runit) sv status "$1" ;;
        sysvinit) service "$1" status ;;
        procd) /etc/init.d/"$1" status ;;
        *) return 1 ;;
    esac
}

service_logs() {
    local name="$1" lines="${2:-50}"
    case "$INIT_SYSTEM" in
        systemd) journalctl -u "$name" -n "$lines" --no-pager ;;
        procd) logread | grep -i "$name" | tail -n "$lines" ;;
        *)
            if [ -r "/var/log/$name.log" ]; then tail -n "$lines" "/var/log/$name.log"
            elif [ -r /var/log/daemon.log ]; then grep -i "$name" /var/log/daemon.log | tail -n "$lines"
            elif [ -r /var/log/syslog ]; then grep -i "$name" /var/log/syslog | tail -n "$lines"
            else service_status "$name"; fi
            ;;
    esac
}

service_reload_manager() {
    [ "$INIT_SYSTEM" = systemd ] && systemctl daemon-reload || true
}

systemd_unit_exists() {
    [ "$INIT_SYSTEM" = systemd ] && systemctl list-unit-files "$1.service" --no-legend 2>/dev/null | grep -q "^$1.service"
}

install_dnscrypt_service() {
    local binary="$1" config="$2" user="$3" group="$4" name="${5:-dnscrypt-proxy}"
    case "$INIT_SYSTEM" in
        systemd)
            cat > "/etc/systemd/system/$name.service" <<EOF
[Unit]
Description=DNSCrypt client proxy
Documentation=https://github.com/DNSCrypt/dnscrypt-proxy
After=network.target
Before=nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$binary -config $config
User=$user
Group=$group
Restart=on-failure
RestartSec=10
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$(dirname "$config") -/var/cache/dnscrypt-proxy -/var/log/dnscrypt

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            ;;
        sysvinit)
            command -v start-stop-daemon >/dev/null 2>&1 || return 1
            cat > "/etc/init.d/$name" <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          $name
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: DNSCrypt client proxy
### END INIT INFO
DAEMON='$binary'
CONFIG='$config'
NAME='$name'
PIDFILE='/run/$name.pid'
USER='$user'
case "\$1" in
  start)
    "\$DAEMON" -check -config "\$CONFIG" || exit 1
    start-stop-daemon --start --quiet --background --make-pidfile \
      --pidfile "\$PIDFILE" --chuid "\$USER" --exec "\$DAEMON" -- -config "\$CONFIG"
    ;;
  stop)
    start-stop-daemon --stop --quiet --retry TERM/10/KILL/5 --pidfile "\$PIDFILE"
    rm -f "\$PIDFILE"
    ;;
  restart|force-reload) "\$0" stop; "\$0" start ;;
  status) start-stop-daemon --status --pidfile "\$PIDFILE" ;;
  *) echo "Usage: \$0 {start|stop|restart|status}"; exit 2 ;;
esac
EOF
            chmod 0755 "/etc/init.d/$name"
            ;;
        openrc)
            cat > "/etc/init.d/$name" <<EOF
#!/sbin/openrc-run
description="DNSCrypt client proxy"
command="$binary"
command_args="-config $config"
command_user="$user:$group"
command_background="yes"
pidfile="/run/$name.pid"
start_pre() { "\$command" -check -config "$config"; }
depend() { need localmount; use net logger; }
EOF
            chmod 0755 "/etc/init.d/$name"
            ;;
        runit)
            command -v chpst >/dev/null 2>&1 || return 1
            mkdir -p "/etc/sv/$name"
            cat > "/etc/sv/$name/run" <<EOF
#!/bin/sh
exec 2>&1
exec chpst -u '$user:$group' '$binary' -config '$config'
EOF
            chmod 0755 "/etc/sv/$name/run"
            ;;
        *) return 1 ;;
    esac
}

remove_dnscrypt_service() {
    local name="${1:-dnscrypt-proxy}"
    service_stop "$name" 2>/dev/null || true
    service_disable "$name" 2>/dev/null || true
    case "$INIT_SYSTEM" in
        systemd) rm -f "/etc/systemd/system/$name.service"; systemctl daemon-reload ;;
        sysvinit|openrc) rm -f "/etc/init.d/$name" ;;
        runit) rm -rf "/etc/sv/$name" ;;
    esac
}
