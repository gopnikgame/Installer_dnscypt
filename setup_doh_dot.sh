#!/bin/bash

# Enable strict error checking and prevent unset variable usage
set -euo pipefail
IFS=$'\n\t'

# Enable debug mode
set -x

# Script metadata
VERSION="2.0.17"
SCRIPT_START_TIME="2025-02-14 17:12:00"
CURRENT_USER="gopnikgame"

# Colors for output with enhanced visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Enhanced logging setup with rotation and debug
LOG_DIR="/var/log/dnscrypt"
DEBUG_DIR="${LOG_DIR}/debug"
LOG_FILE="${LOG_DIR}/dnscrypt_install_${SCRIPT_START_TIME//[: -]/_}.log"
DEBUG_FILE="${DEBUG_DIR}/dnscrypt_debug_${SCRIPT_START_TIME//[: -]/_}.log"

# Create log directories
mkdir -p "$LOG_DIR" "$DEBUG_DIR"
touch "$LOG_FILE" "$DEBUG_FILE"
chmod 640 "$LOG_FILE" "$DEBUG_FILE"

# Log all commands
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$DEBUG_FILE" >&2)

# Save original stderr
exec 3>&2

# Configuration with improved defaults
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

# Enhanced logging function with timestamps and debug info
log() {
    local level=$1
    local msg=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local line_no="${BASH_LINENO[0]}"
    local func="${FUNCNAME[1]:-main}"
    local color=""
    
    case "$level" in
        "ERROR") color="$RED";;
        "WARN")  color="$YELLOW";;
        "INFO")  color="$GREEN";;
        "DEBUG") color="$BLUE";;
    esac
    
    # Log to main log file
    echo -e "${timestamp} ${color}[${level}]${NC} (${func}:${line_no}) ${msg}" | tee -a "$LOG_FILE"
    
    # Additional debug information
    if [[ "$level" == "ERROR" || "$level" == "DEBUG" ]]; then
        echo -e "${timestamp} [${level}] (${func}:${line_no}) ${msg}\nStack trace:" >> "$DEBUG_FILE"
        local frame=0
        while caller $frame; do
            ((frame++))
        done >> "$DEBUG_FILE"
        echo -e "Current environment:" >> "$DEBUG_FILE"
        env >> "$DEBUG_FILE"
    fi
}

# Function for logging commands with full output capture
log_cmd() {
    local cmd="$*"
    local output
    local exit_status
    
    log "DEBUG" "Executing command: $cmd"
    
    output=$("$@" 2>&1)
    exit_status=$?
    
    if [ $exit_status -ne 0 ]; then
        log "ERROR" "Command failed with status $exit_status"
        log "ERROR" "Command output: $output"
        return $exit_status
    fi
    
    log "DEBUG" "Command output: $output"
    return 0
}

# System state check function
check_system_state() {
    log "INFO" "=== System State Check ==="
    
    {
        echo "Date: $(date)"
        echo "Hostname: $(hostname)"
        echo "User: $(whoami)"
        echo "Working directory: $(pwd)"
        echo "Process tree:"
        ps auxf
        echo "Network connections:"
        netstat -tulpn
        echo "Disk space:"
        df -h
        echo "Memory usage:"
        free -m
        echo "System load:"
        uptime
    } >> "$DEBUG_FILE"
    
    log "INFO" "System state saved to debug log"
}

# Diagnostic information collection
collect_diagnostics() {
    local diag_dir="${DEBUG_DIR}/diagnostics_$(date +%Y-%m-%d_%H%M%S)"
    mkdir -p "$diag_dir"
    
    log "INFO" "Collecting diagnostic information..."
    
    # Save system state
    check_system_state > "$diag_dir/system_state.log"
    
    # Save configurations
    cp -r /etc/dnscrypt-proxy "$diag_dir/" 2>/dev/null || true
    cp /etc/resolv.conf "$diag_dir/" 2>/dev/null || true
    
    # Save service logs
    journalctl -u dnscrypt-proxy > "$diag_dir/service_logs.log" 2>/dev/null || true
    
    # Save network information
    ip addr > "$diag_dir/ip_addr.log"
    ip route > "$diag_dir/ip_route.log"
    
    # Save script state
    if [[ -f "$STATE_FILE" ]]; then
        cp "$STATE_FILE" "$diag_dir/install_state.log"
    fi
    
    log "INFO" "Diagnostic information saved to $diag_dir"
}

# Error handler function
error_handler() {
    local line_no=$1
    local cmd=$2
    local exit_code=$3
    
    log "ERROR" "Script failed at line $line_no"
    log "ERROR" "Failed command: $cmd"
    log "ERROR" "Exit code: $exit_code"
    
    collect_diagnostics
    
    if type rollback_system >/dev/null 2>&1; then
        log "INFO" "Attempting system rollback..."
        rollback_system
    fi
    
    exit $exit_code
}

# Set error handler
trap 'error_handler ${LINENO} "$BASH_COMMAND" $?' ERR

# State management functions
save_state() {
    echo "$1" > "$STATE_FILE"
    log "DEBUG" "Saved state: $1"
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    fi
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
    
    # Check internet connectivity
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        log "ERROR" "No internet connection"
        return 1
    fi
    
    log "INFO" "All prerequisites met"
    return 0
}

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi
    log "INFO" "Root privileges confirmed"
}

# System compatibility check
check_system() {
    log "INFO" "=== System Compatibility Check ==="
    save_state "checking_system"
    
    check_prerequisites
    
    # Check systemd
    if ! command -v systemctl &> /dev/null; then
        log "ERROR" "Systemd is required but not found"
        exit 1
    fi
    
    # Check OS
    if ! grep -qiE 'ubuntu|debian' /etc/os-release; then
        log "WARN" "This script is optimized for Debian/Ubuntu systems"
    fi
    
    # Check system resources
    local available_mem=$(free -m | awk 'NR==2 {print $7}')
    local available_space=$(df -k /usr/local/bin | awk 'NR==2 {print $4}')
    
    if [[ $available_mem -lt 512 ]]; then
        log "WARN" "Low memory available: ${available_mem}MB"
    fi
    
    if [[ $available_space -lt 500000 ]]; then
        log "ERROR" "Insufficient disk space. Required: 500MB, Available: $((available_space/1024))MB"
        exit 1
    fi
    
    log "INFO" "System compatibility check passed"
}

# Port 53 check
check_port_53() {
    log "INFO" "=== Checking Port 53 Availability ==="
    save_state "port_check"
    
    local port_53_process=$(ss -lptn 'sport = :53' 2>/dev/null)
    
    if [[ -n "$port_53_process" ]]; then
        log "WARN" "Port 53 is currently in use:"
        echo "$port_53_process" | tee -a "$DEBUG_FILE"
        
        local dns_services=("systemd-resolved" "named" "bind9" "dnsmasq" "unbound")
        
        for service in "${dns_services[@]}"; do
            if systemctl is-active --quiet "$service"; then
                log "INFO" "Stopping and disabling $service..."
                systemctl stop "$service" || log "ERROR" "Failed to stop $service"
                systemctl disable "$service" || log "ERROR" "Failed to disable $service"
                log "INFO" "$service has been stopped and disabled"
            fi
        done
        
        if ss -lptn 'sport = :53' 2>/dev/null | grep -q ":53"; then
            log "ERROR" "Port 53 still in use after stopping known DNS services"
            ss -lptn 'sport = :53' >> "$DEBUG_FILE"
            exit 1
        fi
    fi
    
    log "INFO" "Port 53 is available"
}

# Backup creation
create_backup() {
    log "INFO" "=== Creating System Backup ==="
    save_state "backup"
    
    mkdir -p "$BACKUP_DIR"
    
    local backup_files=(
        "/etc/dnscrypt-proxy"
        "/etc/systemd/resolved.conf"
        "/etc/resolv.conf"
        "/etc/ufw"
        "/etc/ssh/sshd_config"
    )
    
    for item in "${backup_files[@]}"; do
        if [[ -e "$item" ]]; then
            cp -a "$item" "$BACKUP_DIR/" || log "WARN" "Failed to backup $item"
            log "INFO" "Backed up: $item"
        fi
    done
    
    ufw status verbose > "$BACKUP_DIR/ufw_status.before"
}

# System rollback
rollback_system() {
    log "INFO" "=== INITIATING SYSTEM ROLLBACK ==="
    
    # Restore UFW rules
    if [[ -f "$BACKUP_DIR/ufw_status.before" ]]; then
        log "INFO" "Restoring UFW rules..."
        ufw --force reset
        ufw --force import "$BACKUP_DIR/ufw_status.before"
        ufw --force enable
    fi
    
    # Restore resolver configuration
    log "INFO" "Restoring resolver configuration..."
    if [[ -f "$BACKUP_DIR/etc/resolv.conf" ]]; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
        cp -f "$BACKUP_DIR/etc/resolv.conf" /etc/resolv.conf
    fi
    
    # Restart systemd-resolved
    log "INFO" "Restarting systemd-resolved..."
    systemctl restart systemd-resolved || true
    
    # Remove DNSCrypt installation
    if [[ -f "$DNSCRYPT_BIN_PATH" ]]; then
        log "INFO" "Removing DNSCrypt binary..."
        rm -f "$DNSCRYPT_BIN_PATH"
    fi
    
    if [[ -d "/etc/dnscrypt-proxy" ]]; then
        log "INFO" "Removing DNSCrypt configuration..."
        rm -rf "/etc/dnscrypt-proxy"
    fi
    
    log "INFO" "System rollback completed"
}

# Installation verification
verify_installation() {
    log "INFO" "=== Verifying Installation ==="
    save_state "verification"
    
    local success=0
    
    # Check service status
    if ! systemctl is-active --quiet dnscrypt-proxy; then
        log "ERROR" "DNSCrypt-proxy service not running"
        systemctl status dnscrypt-proxy --no-pager >> "$DEBUG_FILE"
        success=1
    fi
    
    # Check port binding
    if ! ss -tuln | grep -q '127.0.0.53:53'; then
        log "ERROR" "DNSCrypt-proxy not bound to port 53"
        ss -tuln >> "$DEBUG_FILE"
        success=1
    fi
    
    # Test DNS resolution
    local test_domains=("google.com" "cloudflare.com" "example.com")
    
    for domain in "${test_domains[@]}"; do
        if ! dig +short +timeout=3 "$domain" @127.0.0.53 >/dev/null; then
            log "ERROR" "Failed to resolve $domain"
            dig "$domain" @127.0.0.53 >> "$DEBUG_FILE"
            success=1
        fi
    done
    
    if [[ $success -eq 0 ]]; then
        log "SUCCESS" "DNSCrypt-proxy installation verified successfully"
    else
        log "ERROR" "DNSCrypt-proxy installation verification failed"
    fi
    
    return $success
}

# Main installation process
main() {
    log "INFO" "Starting DNSCrypt-proxy installation (Version: $VERSION)"
    log "INFO" "Script start time: $SCRIPT_START_TIME"
    log "INFO" "Current user: $CURRENT_USER"
    
    # Initial system check
    check_root
    check_system
    check_system_health
    check_port_53
    
    # Backup and configure
    create_backup
    configure_resolver
    configure_firewall
    
    # Install and verify
    install_dependencies
    configure_dnscrypt
    
    if verify_installation; then
        log "SUCCESS" "=== DNSCrypt-proxy Successfully Installed ==="
        log "INFO" "Backup Directory: $BACKUP_DIR"
        log "INFO" "Installation Log: $LOG_FILE"
        log "INFO" "Debug Log: $DEBUG_FILE"
        exit 0
    else
        log "ERROR" "Installation failed, initiating rollback..."
        rollback_system
        exit 1
    fi
}

# Entry point
main