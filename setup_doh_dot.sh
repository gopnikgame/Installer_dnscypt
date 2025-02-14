#!/bin/bash

# Enable strict error checking and prevent unset variable usage
set -euo pipefail
IFS=$'\n\t'

# Script version
VERSION="1.2.0"

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
REQUIRED_PACKAGES="dnscrypt-proxy ufw"

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
        log_message "INFO" "UFW is not installed. Installing..."
        apt install -y ufw
    fi
    
    # Enable UFW if not active
    if ! systemctl is-active --quiet ufw; then
        log_message "INFO" "Enabling UFW..."
        ufw enable --force
    fi
    
    # Backup current UFW rules
    ufw status verbose > "${BACKUP_DIR}/ufw_status.before"
    
    # Configure UFW rules for DNSCrypt
    ufw allow in on lo to 127.0.0.53 port 53 proto udp
    ufw allow in on lo to 127.0.0.53 port 53 proto tcp
    
    ufw reload
    log_message "INFO" "UFW configuration completed"
}

# Function to show DNS settings
show_dns_settings() {
    log_message "INFO" "=== DNS Settings ==="
    {
        echo "DNS Servers:"
        resolvectl status | grep -E 'DNS Servers|DNS Over TLS|DNSSEC'
        echo -e "\nResolv Configuration:"
        cat /etc/resolv.conf
    } | tee "$1"
}

# Function to reset system DNS resolver to default
reset_dns_resolver() {
    log_message "INFO" "=== Resetting DNS resolver to default ==="
    cat > /etc/systemd/resolved.conf << 'EOL'
[Resolve]
DNS=
FallbackDNS=
DNSStubListener=yes
Cache=no
EOL
    systemctl restart systemd-resolved
}

# Function to install required packages
install_packages() {
    log_message "INFO" "=== Installing required packages ==="
    
    # Update package lists
    apt update
    
    # Install required packages
    for package in $REQUIRED_PACKAGES; do
        if ! dpkg -l | grep -q "^ii  $package"; then
            log_message "INFO" "Installing $package..."
            apt install -y "$package"
        else
            log_message "INFO" "$package is already installed"
        fi
    done
}

# Function to configure DNSCrypt
configure_dnscrypt() {
    log_message "INFO" "=== Configuring DNSCrypt-Proxy ==="
    
    # Create main configuration
    cat > /etc/dnscrypt-proxy/dnscrypt-proxy.toml << 'EOL'
# DNSCrypt-proxy configuration
server_names = ['google', 'google-ipv6', 'quad9-doh-ip4-filter-pri', 'cloudflare']

# Logging configuration
log_level = 2
log_file = '/var/log/dnscrypt-proxy.log'

# Network configuration
listen_addresses = ['127.0.0.53:53']
max_clients = 250
keepalive = 30

# Performance settings
cache = true
cache_size = 4096
cache_min_ttl = 600
cache_max_ttl = 86400

# Security settings
tls_disable_session_tickets = true
refuse_any = true

# IPv6 configuration
ipv6_servers = true

# Fallback resolvers
[static]
  [static.'quad9-doh-ip4-filter-pri']
  stamp = 'sdns://AgMAAAAAAAAADjE0OS4xMTIuMTEyLjEziAcKBu6l-OXxb_8aw-qqiHnETeocKjUYkiQD5YN0YAhpL2Rucy5xdWFkOS5uZXQ6ODQ0MwovZG5zLXF1ZXJ5'

  [static.'cloudflare']
  stamp = 'sdns://AgcAAAAAAAAABzEuMC4wLjGgENkGmDNSOVe_Lp5I2e0dTH0qHK3uUIpWP6gx7WgPgs0VZG5zLmNsb3VkZmxhcmUuY29tCi9kbnMtcXVlcnk'
EOL

    # Configure systemd-resolved
    cat > /etc/systemd/resolved.conf << 'EOL'
[Resolve]
DNS=127.0.0.53
DNSOverTLS=yes
DNSSEC=yes
FallbackDNS=1.1.1.1 9.9.9.9
DNSStubListener=no
Cache=yes
EOL
}

# Function to verify installation
verify_installation() {
    log_message "INFO" "=== Verifying Installation ==="
    local verification_failed=0
    
    # Check service status
    if ! systemctl is-active --quiet dnscrypt-proxy; then
        log_message "ERROR" "DNSCrypt-proxy service is not running"
        verification_failed=1
    fi
    
    # Check port 53 binding
    if ! ss -tulpn | grep -q ":53"; then
        log_message "ERROR" "Port 53 is not properly bound"
        verification_failed=1
    fi
    
    # Test DNS resolution
    for i in {1..3}; do
        if dig +short +timeout=5 google.com @127.0.0.53 >/dev/null; then
            return 0
        fi
        sleep 1
    done
    log_message "ERROR" "DNS resolution test failed"
    return 1
}

# Main installation process
main() {
    log_message "INFO" "Starting DNSCrypt installation script v${VERSION}"
    
    # Execute installation steps
    check_system
    create_backups
    show_dns_settings "${BACKUP_DIR}/pre_install_settings.txt"
    
    # Check if DNSCrypt-proxy is already installed
    if systemctl is-active --quiet dnscrypt-proxy; then
        log_message "INFO" "DNSCrypt-proxy is already installed. Reinstalling..."
        systemctl stop dnscrypt-proxy
        apt remove --purge -y dnscrypt-proxy
    fi
    
    # Check and reset DNS resolver if needed
    if ! resolvectl status | grep -q 'DNS Servers'; then
        reset_dns_resolver
        if ! resolvectl status | grep -q 'DNS Servers'; then
            log_message "ERROR" "Failed to reset DNS resolver"
            exit 1
        fi
    fi
    
    install_packages
    configure_dnscrypt
    manage_ufw
    
    # Restart services
    log_message "INFO" "=== Restarting services ==="
    systemctl restart dnscrypt-proxy
    systemctl restart systemd-resolved
    
    # Verify installation
    if verify_installation; then
        log_message "INFO" "Verification succeeded"
    else
        log_message "ERROR" "Installation verification failed"
        log_message "INFO" "Check ${LOG_FILE} for details"
        exit 1
    fi
    
    # Show new settings
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
}

# Execute main function
main
