#!/bin/bash
set -euo pipefail

ROOT="${TMPDIR:-/tmp}/dnscrypt-system-test-$$-${RANDOM:-0}"
MOCK_BIN="$ROOT/bin"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$MOCK_BIN" "$ROOT/etc"

make_command() {
    printf '#!/bin/sh\nexit 0\n' > "$MOCK_BIN/$1"
    chmod +x "$MOCK_BIN/$1"
}

export DNSCRYPT_SYSTEM_ROOT="$ROOT"
ORIGINAL_PATH="$PATH"
PATH="$MOCK_BIN:/usr/bin:/bin"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/system.sh"

cat > "$ROOT/etc/os-release" <<'EOF'
ID=devuan
ID_LIKE=debian
EOF
[ "$(detect_distribution)" = devuan ]
[ "$(detect_distribution_family)" = debian ]

cat > "$ROOT/etc/os-release" <<'EOF'
ID=fedora
ID_LIKE="rhel centos"
EOF
[ "$(detect_distribution_family)" = redhat ]

cat > "$ROOT/etc/os-release" <<'EOF'
ID=alpine
EOF
[ "$(detect_distribution_family || true)" = unknown ]

mkdir -p "$ROOT/run/systemd/system"
make_command systemctl
[ "$(detect_init_system)" = systemd ]
rm -rf "$ROOT/run/systemd" "$MOCK_BIN/systemctl"

make_command rc-service
make_command rc-update
[ "$(detect_init_system)" = openrc ]
rm -f "$MOCK_BIN/rc-service" "$MOCK_BIN/rc-update"

make_command sv
[ "$(detect_init_system)" = runit ]
rm -f "$MOCK_BIN/sv"

make_command service
[ "$(detect_init_system)" = sysvinit ]
rm -f "$MOCK_BIN/service"

touch "$ROOT/etc/openwrt_release"
[ "$(detect_init_system)" = procd ]
rm -f "$ROOT/etc/openwrt_release"

PATH="$MOCK_BIN"
[ "$(detect_init_system || true)" = unknown ]
PATH="$ORIGINAL_PATH"

echo "system detection tests: OK"
