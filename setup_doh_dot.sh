#!/bin/bash

# Metadata
VERSION="2.0.18"
SCRIPT_START_TIME="2025-02-15 20:12:14"
CURRENT_USER="gopnikgame"

# Constants
DNSCRYPT_USER="dnscrypt"
DNSCRYPT_GROUP="dnscrypt"
DNSCRYPT_BIN_PATH="/usr/local/bin/dnscrypt-proxy"
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
DNSCRYPT_CACHE_DIR="/var/cache/dnscrypt-proxy"
BACKUP_DIR="/var/backup/dns_$(date +%Y%m%d_%H%M%S)"
DEBUG_DIR="/var/log/dnscrypt"
LOG_FILE="${DEBUG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
STATE_FILE="/tmp/dnscrypt_install_state"

# Create debug directory
mkdir -p "$DEBUG_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local caller_info=""
    
    # Get caller information
    if [ "$level" = "DEBUG" ] || [ "$level" = "ERROR" ]; then
        local caller_function="${FUNCNAME[1]}"
        local caller_line="${BASH_LINENO[0]}"
        caller_info="($caller_function:$caller_line)"
    fi
    
    # Format log message
    local log_message="$timestamp [$level] $caller_info $message"
    
    # Write to log file
    echo "$log_message" >> "$LOG_FILE"
    
    # Display to console based on level
    case "$level" in
        "ERROR")
            echo -e "\e[31m$log_message\e[0m" >&2
            ;;
        "WARN")
            echo -e "\e[33m$log_message\e[0m"
            ;;
        "SUCCESS")
            echo -e "\e[32m$log_message\e[0m"
            ;;
        "INFO")
            echo "$log_message"
            ;;
        "DEBUG")
            if [ "${DEBUG:-false}" = "true" ]; then
                echo -e "\e[34m$log_message\e[0m"
            fi
            ;;
    esac
}

# Error handling
set -o errexit
set -o pipefail
set -o nounset

# Check for root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi
    log "INFO" "Root privileges confirmed"
}

# Installation status checks
check_dnscrypt_installed() {
    log "INFO" "Checking DNSCrypt installation..."
    if [ -f "$DNSCRYPT_BIN_PATH" ] && systemctl is-active --quiet dnscrypt-proxy; then
        log "INFO" "DNSCrypt is installed and running"
        return 0
    else
        log "INFO" "DNSCrypt is not installed"
        return 1
    fi
}

check_3xui_installed() {
    log "INFO" "Checking 3x-ui installation..."
    if [ -f "/usr/local/x-ui/x-ui" ] && systemctl is-active --quiet x-ui; then
        log "INFO" "3x-ui is installed and running"
        return 0
    else
        log "INFO" "3x-ui is not installed"
        return 1
    fi
}

# Save installation state
save_state() {
    echo "$1" > "$STATE_FILE"
}

# Check system prerequisites
check_prerequisites() {
    log "INFO" "Checking prerequisites..."
    
    # Check required commands
    local required_commands=("curl" "wget" "tar" "systemctl" "dig" "ss")
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [ ${#missing_commands[@]} -ne 0 ]; then
        log "ERROR" "Missing required commands: ${missing_commands[*]}"
        log "INFO" "Please install: ${missing_commands[*]}"
        return 1
    fi
    
    log "INFO" "All prerequisites met"
    return 0
}

# Check system state
check_system_state() {
    log "INFO" "Checking system state..."
    
    # Check systemd
    if ! pidof systemd >/dev/null; then
        log "ERROR" "systemd is not running"
        return 1
    fi
    
    # Check system load
    local load=$(uptime | awk -F'load average:' '{ print $2 }' | cut -d, -f1)
    if (( $(echo "$load > 5.0" | bc -l) )); then
        log "WARN" "High system load detected: $load"
    fi
    
    # Check available memory
    local mem_available=$(free | awk '/^Mem:/ {print $7}')
    if [ "$mem_available" -lt 102400 ]; then
        log "WARN" "Low memory available: $mem_available KB"
    fi
    
    # Check disk space
    local disk_space=$(df -k /usr/local/bin | awk 'NR==2 {print $4}')
    if [ "$disk_space" -lt 102400 ]; then
        log "ERROR" "Insufficient disk space: $disk_space KB"
        return 1
    fi
    
    log "INFO" "System state check passed"
    return 0
}

# Check port 53 availability
check_port_53() {
    log "INFO" "Checking port 53..."
    
    if ss -lntu | grep -q ':53 '; then
        log "WARN" "Port 53 is in use"
        
        # Check if systemd-resolved is using port 53
        if systemctl is-active --quiet systemd-resolved; then
            log "INFO" "Stopping systemd-resolved..."
            systemctl stop systemd-resolved
            systemctl disable systemd-resolved
        fi
        
        # Recheck port after stopping services
        if ss -lntu | grep -q ':53 '; then
            log "ERROR" "Port 53 is still in use by another service"
            return 1
        fi
    fi
    
    log "INFO" "Port 53 is available"
    return 0
}

# Create backup
create_backup() {
    log "INFO" "Creating backup..."
    
    mkdir -p "$BACKUP_DIR"
    
    # Backup DNS configuration
    if [ -f "/etc/resolv.conf" ]; then
        cp -p "/etc/resolv.conf" "${BACKUP_DIR}/resolv.conf.backup"
    fi
    
    # Backup systemd-resolved configuration if exists
    if [ -f "/etc/systemd/resolved.conf" ]; then
        cp -p "/etc/systemd/resolved.conf" "${BACKUP_DIR}/resolved.conf.backup"
    fi
    
    # Backup existing DNSCrypt configuration if exists
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        cp -p "$DNSCRYPT_CONFIG" "${BACKUP_DIR}/dnscrypt-proxy.toml.backup"
    fi
    
    # Backup 3x-ui configuration if exists
    if [ -f "/usr/local/x-ui/config.json" ]; then
        cp -p "/usr/local/x-ui/config.json" "${BACKUP_DIR}/x-ui-config.json.backup"
    fi
    
    log "INFO" "Backup created in $BACKUP_DIR"
    return 0
}

# System rollback function
rollback_system() {
    log "INFO" "=== Starting System Rollback ==="
    
    # Stop services
    log "INFO" "Rolling back DNSCrypt-proxy installation..."
    systemctl stop dnscrypt-proxy 2>/dev/null || true
    systemctl disable dnscrypt-proxy 2>/dev/null || true
    
    # Remove files
    rm -f "$DNSCRYPT_BIN_PATH" 2>/dev/null || true
    rm -rf "/etc/dnscrypt-proxy" 2>/dev/null || true
    rm -rf "$DNSCRYPT_CACHE_DIR" 2>/dev/null || true
    
    # Restore system configuration
    log "INFO" "Restoring system configuration..."
    if [ -f "${BACKUP_DIR}/resolv.conf.backup" ]; then
        cp -f "${BACKUP_DIR}/resolv.conf.backup" "/etc/resolv.conf"
    fi
    
    # Restore DNS services
    log "INFO" "Restoring DNS services..."
    if systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
        systemctl start systemd-resolved
        systemctl enable systemd-resolved
    fi
    
    # Remove state file
    rm -f "$STATE_FILE" 2>/dev/null || true
    
    log "INFO" "System rollback completed"
}

# Configure 3x-ui DNS
configure_3xui_dns() {
    log "INFO" "=== Configuring 3x-ui DNS settings ==="
    
    local xui_config="/usr/local/x-ui/config.json"
    
    # Verify config exists
    if [ ! -f "$xui_config" ]; then
        log "ERROR" "3x-ui configuration file not found"
        return 1
    fi
    
    # Backup config
    cp "$xui_config" "${xui_config}.backup"
    
    # Get current DNS settings
    local current_dns=$(grep -o '"dns_server":"[^"]*"' "$xui_config" | cut -d'"' -f4)
    log "INFO" "Current DNS server in 3x-ui: $current_dns"
    
    # Update DNS server to DNSCrypt
    sed -i 's/"dns_server":"[^"]*"/"dns_server":"127.0.0.1"/' "$xui_config"
    
    # Restart 3x-ui
    systemctl restart x-ui
    
    # Verify service status
    if systemctl is-active --quiet x-ui; then
        log "INFO" "3x-ui DNS configuration updated successfully"
        return 0
    else
        log "ERROR" "Failed to restart 3x-ui after DNS configuration"
        mv "${xui_config}.backup" "$xui_config"
        systemctl restart x-ui
        return 1
    fi
}

# Installation verification
verify_installation() {
    log "INFO" "=== Verifying DNSCrypt Installation ==="
    local issues=0

    # Check binary
    if [ ! -x "$DNSCRYPT_BIN_PATH" ]; then
        log "ERROR" "DNSCrypt binary missing or not executable"
        issues=$((issues + 1))
    else
        local version_output
        version_output=$("$DNSCRYPT_BIN_PATH" --version 2>&1)
        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to get DNSCrypt version"
            issues=$((issues + 1))
        else
            log "INFO" "DNSCrypt version: $version_output"
        fi
    fi

    # Check service status
    if ! systemctl is-active --quiet dnscrypt-proxy; then
        log "ERROR" "DNSCrypt service is not running"
        systemctl status dnscrypt-proxy >> "$LOG_FILE"
        issues=$((issues + 1))
    fi

    # Check DNS resolution
    if ! dig @127.0.0.1 google.com +short +timeout=5 > /dev/null 2>&1; then
        log "ERROR" "DNS resolution test failed"
        issues=$((issues + 1))
    fi

    # Final verdict
    if [ $issues -eq 0 ]; then
        log "INFO" "All verification checks passed"
        return 0
    else
        log "ERROR" "Verification failed with $issues issue(s)"
        return 1
    fi
}

# Main installation function
main() {
    log "INFO" "Starting script execution (Version: $VERSION)"
    log "INFO" "Script start time: $SCRIPT_START_TIME"
    log "INFO" "Current user: $CURRENT_USER"
    
    check_root || exit 1
    
    # Check DNSCrypt installation
    if ! check_dnscrypt_installed; then
        log "INFO" "DNSCrypt not found, starting installation..."
        check_prerequisites || exit 1
        check_system_state || exit 1
        check_port_53 || exit 1
        create_backup || exit 1
        
        if ! install_dnscrypt; then
            log "ERROR" "Installation failed"
            rollback_system
            exit 1
        fi
        
        if ! verify_installation; then
            log "ERROR" "Installation verification failed"
            rollback_system
            exit 1
        fi
        
        log "SUCCESS" "DNSCrypt installation completed successfully"
        log "INFO" "Please restart the script to configure 3x-ui integration"
        exit 0
    fi
    
    # Check 3x-ui installation
    if ! check_3xui_installed; then
        log "ERROR" "3x-ui is not installed. Please install 3x-ui first"
        log "INFO" "You can install 3x-ui using: bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)"
        exit 1
    fi
    
    # Configure 3x-ui DNS integration
    echo
    echo "DNSCrypt and 3x-ui are both installed."
    echo "Would you like to configure 3x-ui to use DNSCrypt for DNS resolution?"
    echo "This will:"
    echo "1. Update 3x-ui DNS settings to use localhost (127.0.0.1)"
    echo "2. Restart 3x-ui service to apply changes"
    echo "3. Create a backup of current settings"
    echo
    read -p "Continue? (y/n): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if configure_3xui_dns; then
            log "SUCCESS" "3x-ui successfully configured to use DNSCrypt"
            log "INFO" "Configuration complete!"
        else
            log "ERROR" "Failed to configure 3x-ui DNS settings"
            exit 1
        fi
    else
        log "INFO" "DNS configuration cancelled by user"
        exit 0
    fi
}

# Cleanup function
cleanup() {
    local exit_code=$?
    log "INFO" "Script execution completed with exit code: $exit_code"
    if [ $exit_code -ne 0 ]; then
        log "ERROR" "Script failed with exit code $exit_code"
        rollback_system
    fi
    exit $exit_code
}

# Set cleanup trap
trap cleanup EXIT

# Start execution
main