#!/bin/bash

# Enable strict error checking and prevent unset variable usage
set -euo pipefail
IFS=$'\n\t'

# Script metadata
VERSION="2.0.17"
SCRIPT_START_TIME="2025-02-14 19:20:07"
CURRENT_USER="gopnikgame"

# Colors for output with enhanced visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Debug mode flag (disabled by default)
DEBUG_MODE=0

# Enhanced logging setup with rotation and debug
LOG_DIR="/var/log/dnscrypt"
DEBUG_DIR="${LOG_DIR}/debug"
LOG_FILE="${LOG_DIR}/dnscrypt_install_${SCRIPT_START_TIME//[: -]/_}.log"
DEBUG_FILE="${DEBUG_DIR}/dnscrypt_debug_${SCRIPT_START_TIME//[: -]/_}.log"

# Create log directories
mkdir -p "$LOG_DIR" "$DEBUG_DIR"
touch "$LOG_FILE" "$DEBUG_FILE"
chmod 640 "$LOG_FILE" "$DEBUG_FILE"

# Configuration
BACKUP_DIR="/var/backups/dnscrypt-proxy/backup_${SCRIPT_START_TIME//[: -]/_}"
REQUIRED_PACKAGES=(
    "ufw"
    "dnsutils"
    "iproute2"
    "curl"
    "libcap2-bin"
    "tar"
    "wget"
    "bc"
)
MIN_DNSCRYPT_VERSION="2.1.0"
DNSCRYPT_LATEST_VERSION="2.1.7"

# Service configuration
DNSCRYPT_USER="dnscrypt-proxy"
DNSCRYPT_GROUP="dnscrypt-proxy"
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
DNSCRYPT_BIN_PATH="/usr/local/bin/dnscrypt-proxy"
DNSCRYPT_CACHE_DIR="/var/cache/dnscrypt-proxy"
STATE_FILE="/tmp/dnscrypt_install_state_$(date +%Y%m%d_%H%M%S)"

# Basic functions
log() {
    local level="$1"
    local msg="$2"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local line_no="${BASH_LINENO[0]}"
    local func="${FUNCNAME[1]:-main}"
    local log_msg="${timestamp} [${level}] (${func}:${line_no}) ${msg}"
    
    case "$level" in
        "ERROR") echo -e "${RED}${log_msg}${NC}" ;;
        "WARN")  echo -e "${YELLOW}${log_msg}${NC}" ;;
        "INFO")  echo -e "${GREEN}${log_msg}${NC}" ;;
        "DEBUG") echo -e "${BLUE}${log_msg}${NC}" ;;
        *)       echo "$log_msg" ;;
    esac | tee -a "$LOG_FILE"
}

run_cmd() {
    local cmd="$*"
    local output
    local status
    
    log "DEBUG" "Executing: $cmd"
    output=$(eval "$cmd" 2>&1)
    status=$?
    
    if [[ $status -ne 0 ]]; then
        log "ERROR" "Command failed (status=$status): $cmd"
        log "ERROR" "Output: $output"
        return $status
    fi
    
    log "DEBUG" "Command succeeded: $output"
    return 0
}

# State management
save_state() {
    echo "$1" > "$STATE_FILE"
    log "DEBUG" "Saved state: $1"
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    fi
}

# System state check
check_system_state() {
    log "INFO" "=== System State Check ==="
    local diag_file="${DEBUG_DIR}/system_state_$(date +%Y%m%d_%H%M%S).log"
    {
        echo "=== System State Details ==="
        echo "Date: $(date)"
        echo "Hostname: $(hostname)"
        echo "User: $(whoami)"
        ps aux | grep -i dns
        netstat -tulpn | grep :53
        echo "=== End System State Details ==="
    } > "$diag_file"
    return 0
}

# Prerequisites check
check_prerequisites() {
    log "INFO" "Checking prerequisites..."
    local missing_deps=()
    
    for cmd in systemctl dig ss ufw chattr curl tar wget; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
            log "WARN" "Missing required command: $cmd"
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log "ERROR" "Missing required commands: ${missing_deps[*]}"
        return 1
    fi
    
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        log "ERROR" "No internet connection"
        return 1
    fi
    
    log "INFO" "All prerequisites met"
    return 0
}

# Check for root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi
    log "INFO" "Root privileges confirmed"
}

# Port 53 check and cleanup
check_port_53() {
    log "INFO" "=== Checking Port 53 Availability ==="
    save_state "port_check"
    
    local port_53_process=$(ss -lptn 'sport = :53' 2>/dev/null)
    
    if [[ -n "$port_53_process" ]]; then
        log "WARN" "Port 53 is in use"
        
        local dns_services=("systemd-resolved" "named" "bind9" "dnsmasq" "unbound")
        
        for service in "${dns_services[@]}"; do
            if systemctl is-active --quiet "$service"; then
                log "INFO" "Stopping and disabling $service..."
                systemctl stop "$service" || log "ERROR" "Failed to stop $service"
                systemctl disable "$service" || log "ERROR" "Failed to disable $service"
            fi
        done
        
        sleep 2
        if ss -lptn 'sport = :53' 2>/dev/null | grep -q ":53"; then
            log "ERROR" "Port 53 still in use after stopping known services"
            return 1
        fi
    fi
    
    log "INFO" "Port 53 is available"
    return 0
}

# Create system backup
create_backup() {
    log "INFO" "=== Creating System Backup ==="
    save_state "backup"
    
    mkdir -p "$BACKUP_DIR"
    
    local backup_files=(
        "/etc/dnscrypt-proxy"
        "/etc/systemd/resolved.conf"
        "/etc/resolv.conf"
        "/etc/ufw"
    )
    
    for item in "${backup_files[@]}"; do
        if [[ -e "$item" ]]; then
            cp -a "$item" "$BACKUP_DIR/" || log "WARN" "Failed to backup $item"
        fi
    done
    
    ufw status verbose > "$BACKUP_DIR/ufw_status.before"
    log "INFO" "Backup created in $BACKUP_DIR"
}

# Rollback system changes
rollback_system() {
    log "INFO" "=== Starting System Rollback ==="
    local state=$(load_state)
    
    case "$state" in
        "installation")
            log "INFO" "Rolling back DNSCrypt-proxy installation..."
            systemctl stop dnscrypt-proxy 2>/dev/null || true
            systemctl disable dnscrypt-proxy 2>/dev/null || true
            rm -f /etc/systemd/system/dnscrypt-proxy.service
            systemctl daemon-reload
            
            rm -f "$DNSCRYPT_BIN_PATH"
            rm -rf "/etc/dnscrypt-proxy"
            rm -rf "$DNSCRYPT_CACHE_DIR"
            
            chattr -i /etc/resolv.conf 2>/dev/null || true
            if [[ -f "$BACKUP_DIR/resolv.conf" ]]; then
                cp "$BACKUP_DIR/resolv.conf" /etc/resolv.conf
            fi
            
            systemctl enable systemd-resolved 2>/dev/null || true
            systemctl start systemd-resolved 2>/dev/null || true
            ;&
        "backup")
            log "INFO" "Restoring system configuration..."
            if [[ -d "$BACKUP_DIR" ]]; then
                for file in "$BACKUP_DIR"/*; do
                    if [[ -f "$file" ]]; then
                        cp -f "$file" "/${file##*/}" 2>/dev/null || true
                    fi
                done
            fi
            ;&
        "port_check")
            log "INFO" "Restoring DNS services..."
            for service in systemd-resolved named bind9 dnsmasq unbound; do
                if systemctl is-enabled "$service" &>/dev/null; then
                    systemctl start "$service" 2>/dev/null || true
                fi
            done
            ;;
        *)
            log "WARN" "No state found, performing full rollback..."
            ;;
    esac
    
    log "INFO" "System rollback completed"
}

# Install DNSCrypt
install_dnscrypt() {
    log "INFO" "=== Installing DNSCrypt-proxy ==="
    save_state "installation"

    # Create user and group
    log "INFO" "Creating DNSCrypt user and group..."
    groupadd -f "$DNSCRYPT_GROUP"
    useradd -r -M -N -g "$DNSCRYPT_GROUP" -s /bin/false "$DNSCRYPT_USER" 2>/dev/null || true

    # Download and install binary
    log "INFO" "Downloading DNSCrypt-proxy..."
    cd /tmp
    rm -f dnscrypt.tar.gz # Clean previous downloads
    
    DOWNLOAD_URL="https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/v2.1.7/dnscrypt-proxy-linux_x86_64-2.1.7.tar.gz"
    
    log "INFO" "Using download URL: ${DOWNLOAD_URL}"
    
    # Try download with curl
    log "INFO" "Attempting download with curl..."
    if curl -L -v -o dnscrypt.tar.gz "$DOWNLOAD_URL" 2>&1; then
        log "INFO" "Curl download successful"
    else
        log "WARN" "Curl download failed, trying wget..."
        if ! wget --no-check-certificate -v -O dnscrypt.tar.gz "$DOWNLOAD_URL" 2>&1; then
            DOWNLOAD_URL="https://download.dnscrypt.info/dnscrypt-proxy/v2.1/dnscrypt-proxy-linux_x86_64-2.1.7.tar.gz"
            log "INFO" "Trying alternative URL: ${DOWNLOAD_URL}"
            
            if ! curl -L -v -o dnscrypt.tar.gz "$DOWNLOAD_URL" 2>&1; then
                log "ERROR" "All download attempts failed"
                return 1
            fi
        fi
    fi

    # Verify download
    if [ ! -s dnscrypt.tar.gz ]; then
        log "ERROR" "Downloaded file is empty"
        return 1
    fi

    # Check if file is actually a gzip archive
    if ! file dnscrypt.tar.gz | grep -q "gzip compressed data"; then
        log "ERROR" "Downloaded file is not a valid gzip archive"
        return 1
    fi

    log "INFO" "Download successful, verifying archive..."
    
    # Extract with verbose output
    if ! tar xvzf dnscrypt.tar.gz; then
        log "ERROR" "Failed to extract archive"
        return 1
    fi

    # Verify extracted contents
    if [ ! -f "linux-x86_64/dnscrypt-proxy" ]; then
        log "ERROR" "Expected binary not found in extracted archive"
        return 1
    fi

    cp "linux-x86_64/dnscrypt-proxy" "$DNSCRYPT_BIN_PATH" || {
        log "ERROR" "Failed to copy binary"
        return 1
    }

    chmod 755 "$DNSCRYPT_BIN_PATH"
    
    # Create directories and set permissions
    mkdir -p /etc/dnscrypt-proxy
    mkdir -p "$DNSCRYPT_CACHE_DIR"
    chown -R "$DNSCRYPT_USER:$DNSCRYPT_GROUP" "$DNSCRYPT_CACHE_DIR"

    # Configure DNSCrypt
    log "INFO" "Configuring DNSCrypt-proxy..."
    cat > "$DNSCRYPT_CONFIG" << 'EOL'
server_names = ['cloudflare']
listen_addresses = ['127.0.0.1:53']
max_clients = 250
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = true
doh_servers = true
require_dnssec = true
require_nolog = true
require_nofilter = true
force_tcp = false
timeout = 2500
keepalive = 30
cert_refresh_delay = 240
bootstrap_resolvers = ['1.1.1.1:53', '8.8.8.8:53']
ignore_system_dns = true
netprobe_timeout = 30
cache = true
cache_size = 4096
cache_min_ttl = 600
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600
[static]
[sources]
  [sources.'public-resolvers']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
  cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 72
  prefix = ''
EOL

    # Create systemd service
    log "INFO" "Creating systemd service..."
    cat > /etc/systemd/system/dnscrypt-proxy.service << EOL
[Unit]
Description=DNSCrypt-proxy client
Documentation=https://github.com/DNSCrypt/dnscrypt-proxy/wiki
After=network.target
Before=nss-lookup.target
Wants=network.target nss-lookup.target

[Service]
Type=simple
NonBlocking=true
User=$DNSCRYPT_USER
Group=$DNSCRYPT_GROUP
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETGID CAP_SETUID
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_SETGID CAP_SETUID
ExecStart=$DNSCRYPT_BIN_PATH -config $DNSCRYPT_CONFIG
Restart=always
RestartSec=30
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOL

    # Configure system resolver
    log "INFO" "Configuring system resolver..."
    systemctl disable systemd-resolved || true
    systemctl stop systemd-resolved || true
    
    sleep 2
    if ss -lptn 'sport = :53' 2>/dev/null | grep -q ":53"; then
        log "ERROR" "Port 53 is still in use"
        return 1
    fi
    
    rm -f /etc/resolv.conf
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    chattr +i /etc/resolv.conf

    # Start service with additional checks
    log "INFO" "Starting DNSCrypt-proxy service..."
    systemctl daemon-reload
    systemctl enable dnscrypt-proxy
    
    if ! systemctl start dnscrypt-proxy; then
        log "ERROR" "Failed to start DNSCrypt-proxy service"
        journalctl -u dnscrypt-proxy --no-pager -n 50 >> "$LOG_FILE"
        return 1
    fi
    
    # Wait and verify service is running
    local max_attempts=10
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if systemctl is-active --quiet dnscrypt-proxy; then
            log "INFO" "DNSCrypt-proxy service is running"
            sleep 2
            return 0
        fi
        log "INFO" "Waiting for service to start (attempt $attempt/$max_attempts)..."
        sleep 2
        attempt=$((attempt + 1))
    done

    log "ERROR" "DNSCrypt-proxy service failed to start within timeout"
    return 1
}

# Installation verification
verify_installation() {
    log "INFO" "Verifying DNSCrypt-proxy installation..."
    
    if ! systemctl is-active --quiet dnscrypt-proxy; then
        log "ERROR" "DNSCrypt-proxy service is not running"
        return 1
    fi
    
    if ! dig +short +timeout=3 google.com @127.0.0.1 >/dev/null; then
        log "ERROR" "DNS resolution test failed"
        return 1
    fi
    
    log "INFO" "DNSCrypt-proxy verification successful"
    return 0
}

# Error handler
error_handler() {
    local line_no="$1"
    local command="$2"
    local exit_code="$3"
    
    log "ERROR" "Script failed at line ${line_no}"
    log "ERROR" "Failed command: ${command}"
    log "ERROR" "Exit code: ${exit_code}"
    
    rollback_system
}

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Script failed with exit code ${exit_code}"
        rollback_system
    fi
}

# Main installation process
main() {
    log "INFO" "Starting DNSCrypt-proxy installation (Version: $VERSION)"
    log "INFO" "Script start time: $SCRIPT_START_TIME"
    log "INFO" "Current user: $CURRENT_USER"
    
    check_root || exit 1
    check_prerequisites || exit 1
    check_system_state || exit 1
    check_port_53 || exit 1
    create_backup || exit 1
    
    log "INFO" "Beginning DNSCrypt installation..."
    if ! install_dnscrypt; then
        log "ERROR" "Installation failed"
        rollback_system
        exit 1
    fi
    
    log "INFO" "Verifying installation..."
    if ! verify_installation; then
        log "ERROR" "Installation verification failed"
        rollback_system
        exit 1
    fi
    
    log "SUCCESS" "=== DNSCrypt-proxy Successfully Installed ==="
    log "INFO" "Backup Directory: $BACKUP_DIR"
    log "INFO" "Installation Log: $LOG_FILE"
    return 0
}

# Set error handler
trap 'error_handler ${LINENO} "${BASH_COMMAND}" $?' ERR

# Set cleanup handler
trap cleanup EXIT

# Start installation
main