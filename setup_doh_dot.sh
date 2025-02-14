#!/bin/bash

# Enable strict error checking and prevent unset variable usage
set -euo pipefail
IFS=$'\n\t'

# Script metadata
VERSION="2.0.17"
SCRIPT_START_TIME="2025-02-14 18:05:31"
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

# Enhanced logging function
log() {
    local level=$1
    local msg=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
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

# Command execution with logging
run_cmd() {
    local cmd="$*"
    local output
    local status
    
    output=$(eval "$cmd" 2>&1)
    status=$?
    
    if [[ $status -ne 0 ]]; then
        log "ERROR" "Command failed (status=$status): $cmd"
        log "ERROR" "Output: $output"
        return $status
    fi
    
    return 0
}

# Error handler
error_handler() {
    local line_no=$1
    local command=$2
    local exit_code=$3
    
    log "ERROR" "Script failed at line $line_no"
    log "ERROR" "Failed command: $command"
    log "ERROR" "Exit code: $exit_code"
    
    collect_diagnostics
    
    if type rollback_system >/dev/null 2>&1; then
        log "INFO" "Initiating rollback..."
        rollback_system
    fi
}

# Set error handler
trap 'error_handler ${LINENO} "$BASH_COMMAND" $?' ERR

# State management
save_state() {
    echo "$1" > "$STATE_FILE"
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
}

# Diagnostic information collection
collect_diagnostics() {
    local diag_dir="${DEBUG_DIR}/diagnostics_$(date +%Y-%m-%d_%H%M%S)"
    mkdir -p "$diag_dir"
    
    log "INFO" "Collecting diagnostic information..."
    
    {
        cp -r /etc/dnscrypt-proxy "$diag_dir/" 2>/dev/null || true
        cp /etc/resolv.conf "$diag_dir/" 2>/dev/null || true
        systemctl status dnscrypt-proxy > "$diag_dir/service_status.log" 2>/dev/null || true
        journalctl -u dnscrypt-proxy -n 50 > "$diag_dir/service_journal.log" 2>/dev/null || true
        ip addr > "$diag_dir/ip_addr.log"
        netstat -tulpn > "$diag_dir/netstat.log"
        ps aux | grep -i dns > "$diag_dir/dns_processes.log"
    }
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

# Main installation process
main() {
    log "INFO" "Starting DNSCrypt-proxy installation (Version: $VERSION)"
    log "INFO" "Script start time: $SCRIPT_START_TIME"
    log "INFO" "Current user: $CURRENT_USER"
    
    check_root
    check_prerequisites || exit 1
    check_system_state
    check_port_53 || exit 1
    create_backup
    
    if verify_installation; then
        log "SUCCESS" "=== DNSCrypt-proxy Successfully Installed ==="
        log "INFO" "Backup Directory: $BACKUP_DIR"
        log "INFO" "Installation Log: $LOG_FILE"
        exit 0
    else
        log "ERROR" "Installation failed, initiating rollback..."
        rollback_system
        exit 1
    fi
}

# Start installation
main