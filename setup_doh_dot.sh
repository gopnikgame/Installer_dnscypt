#!/bin/bash

# Enable strict error checking and prevent unset variable usage
set -euo pipefail
IFS=$'\n\t'

# Script version
VERSION="1.2.2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging setup
LOG_FILE="/tmp/dnscrypt_setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Backup directory setup
BACKUP_DIR="/etc/dnscrypt-proxy/backup_$(date +%Y%m%d%H%M%S)"
REQUIRED_PACKAGES=("dnscrypt-proxy" "ufw")

# Function for logging messages
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf "%s [%s] %s\n" "$timestamp" "$level" "$message"
}

# Function to check system compatibility
check_system() {
    log_message "INFO" "=== Checking system compatibility ==="
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_message "ERROR" "This script must be run as root"
        exit 1
    fi

    # Check if systemd is present
    if ! command -v systemctl >/dev/null 2>&1; then
        log_message "ERROR" "This script requires systemd"
        exit 1
    fi

    # Check for required commands
    for cmd in dig ss ufw systemctl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_message "ERROR" "Required command '$cmd' not found"
            exit 1
        fi
    done
}

# Function to create backup directory and backup files
create_backups() {
    log_message "INFO" "=== Creating backups ==="
    mkdir -p "$BACKUP_DIR"
    
    # Backup existing configuration files if they exist
    local files_to_backup=(
        "/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
        "/etc/systemd/resolved.conf"
        "/etc/resolv.conf"
    )
    
    for file in "${files_to_backup[@]}"; do
        if [[ -f "$file" ]]; then
            cp "$file" "${BACKUP_DIR}/$(basename "$file").original"
            log_message "INFO" "Backed up $file"
        fi
    done
}

# Enhanced UFW management function
manage_ufw() {
    log_message "INFO" "=== Configuring UFW firewall ==="
    
    # Ensure UFW is installed
    if ! command -v ufw >/dev/null 2>&1; then
        log_message "INFO" "Installing UFW..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
    fi
    
    # Configure UFW rules for DNSCrypt
    ufw allow in on lo to any port 53 proto udp comment 'DNSCrypt UDP'
    ufw allow in on lo to any port 53 proto tcp comment 'DNSCrypt TCP'
    
    # Enable UFW if not active
    if ! ufw status | grep -q "Status: active"; then
        log_message "INFO" "Enabling UFW..."
        echo "y" | ufw enable
    fi
    
    ufw reload
    log_message "INFO" "UFW configuration completed"
}

# Function to show DNS settings
show_dns_settings() {
    log_message "INFO" "=== DNS Settings ==="
    {
        echo "DNS Servers:"
        resolvectl status | grep -E 'DNS Servers|DNS Over TLS|DNSSEC' || true
        echo -e "\nResolv Configuration:"
        cat /etc/resolv.conf
    } | tee "$1"
}

# Function to reset system DNS resolver to default
reset_dns_resolver() {
    log_message "INFO" "=== Resetting DNS resolver to default ==="
    
    # Stop DNSCrypt if running
    systemctl stop dnscrypt-proxy 2>/dev/null || true
    
    # Reset resolved configuration
    cat > /etc/systemd/resolved.conf << 'EOL'
[Resolve]
DNS=1.1.1.1
FallbackDNS=8.8.8.8
DNSStubListener=yes
Cache=yes
EOL

    systemctl restart systemd-resolved
    sleep 2
}

# Function to install required packages
install_packages() {
    log_message "INFO" "=== Installing required packages ==="
    
    # Update package lists
    apt-get update
    
    # Install packages one by one
    for package in "${REQUIRED_PACKAGES[@]}"; do
        log_message "INFO" "Installing ${package}..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
    done
}

# Function to configure DNSCrypt
configure_dnscrypt() {
    log_message "INFO" "=== Configuring DNSCrypt-Proxy ==="
    
    # Stop services before configuration
    systemctl stop dnscrypt-proxy 2>/dev/null || true
    systemctl stop systemd-resolved 2>/dev/null || true
    
    # Create main configuration
    cat > /etc/dnscrypt-proxy/dnscrypt-proxy.toml << 'EOL'
listen_addresses = ['127.0.0.53:53']
server_names = ['cloudflare', 'google']
max_clients = 250
ipv4_servers = true
ipv6_servers = true
dnscrypt_servers = true
doh_servers = true
require_dnssec = true
require_nolog = true
require_nofilter = true
force_tcp = false
timeout = 5000
keepalive = 30
log_level = 2
use_syslog = true
cache = true
cache_size = 4096
cache_min_ttl = 600
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600
[static]
EOL

    # Configure systemd-resolved
    cat > /etc/systemd/resolved.conf << 'EOL'
[Resolve]
DNS=127.0.0.53
FallbackDNS=1.1.1.1 8.8.8.8
DNSStubListener=no
Cache=yes
DNSOverTLS=yes
DNSSEC=allow-downgrade
EOL

    # Create resolv.conf
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    
    # Ensure correct permissions
    chown -R root:root /etc/dnscrypt-proxy
    chmod 644 /etc/dnscrypt-proxy/dnscrypt-proxy.toml
    
    # Enable services
    systemctl enable dnscrypt-proxy
    systemctl enable systemd-resolved
}

# Function to verify installation
verify_installation() {
    log_message "INFO" "=== Verifying Installation ==="
    local verification_failed=0
    
    # Wait for services to be fully started
    sleep 5
    
    # Check service status
    if ! systemctl is-active --quiet dnscrypt-proxy; then
        log_message "ERROR" "DNSCrypt-proxy service is not running"
        systemctl status dnscrypt-proxy
        verification_failed=1
    fi
    
    # Check port 53 binding
    if ! ss -tulpn | grep -q ":53"; then
        log_message "ERROR" "Port 53 is not properly bound"
        ss -tulpn | grep ":53" || true
        verification_failed=1
    fi
    
    # Test DNS resolution with multiple attempts
    local dns_test_passed=0
    for i in {1..5}; do
        if dig +short +timeout=5 google.com @127.0.0.53 >/dev/null; then
            dns_test_passed=1
            break
        fi
        log_message "INFO" "DNS test attempt $i failed, retrying..."
        sleep 2
    done
    
    if [ $dns_test_passed -eq 0 ]; then
        log_message "ERROR" "DNS resolution test failed"
        verification_failed=1
    fi
    
    return $verification_failed
}

# Main installation process
main() {
    log_message "INFO" "Starting DNSCrypt installation script v${VERSION}"
    
    # Execute installation steps
    check_system
    create_backups
    show_dns_settings "${BACKUP_DIR}/pre_install_settings.txt"
    
    # Reset DNS resolver
    reset_dns_resolver
    
    # Install packages
    install_packages
    
    # Configure services
    configure_dnscrypt
    manage_ufw
    
    # Restart services in correct order
    log_message "INFO" "=== Restarting services ==="
    systemctl daemon-reload
    systemctl restart systemd-resolved
    sleep 2
    systemctl restart dnscrypt-proxy
    sleep 2
    
    # Verify installation
    if verify_installation; then
        log_message "INFO" "Verification succeeded"
        show_dns_settings "${BACKUP_DIR}/post_install_settings.txt"
        
        # Final summary
        log_message "INFO" "=== Installation Summary ==="
        echo -e "${GREEN}Installation completed successfully!${NC}"
        echo -e "- Configuration files backed up to: ${BACKUP_DIR}"
        echo -e "- Log file location: ${LOG_FILE}"
        echo -e "- DNSCrypt-proxy service is running"
        echo -e "- DNS resolution is working"
        echo -e "\nTo monitor the service: ${YELLOW}systemctl status dnscrypt-proxy${NC}"
        echo -e "To view logs: ${YELLOW}journalctl -u dnscrypt-proxy${NC}"
    else
        log_message "ERROR" "Installation verification failed"
        log_message "INFO" "Check ${LOG_FILE} for details"
        exit 1
    fi
}

# Execute main function
main
