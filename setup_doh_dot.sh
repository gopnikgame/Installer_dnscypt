#!/bin/bash

# Enable strict error checking and prevent unset variable usage
set -euo pipefail
IFS=$'\n\t'

# Script version and metadata
VERSION="1.2.7"
SCRIPT_START_TIME="2025-02-14 09:05:15"
CURRENT_USER="gopnikgame"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging setup
LOG_FILE="/tmp/dnscrypt_setup_${SCRIPT_START_TIME//[ :]/-}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Backup directory setup
BACKUP_DIR="/etc/dnscrypt-proxy/backup_${SCRIPT_START_TIME//[ :]/-}"
REQUIRED_PACKAGES=("dnscrypt-proxy" "ufw")

# Function for logging messages
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf "%s [%s] %s\n" "$timestamp" "$level" "$message"
}

# Safety check function for SSH
check_ssh() {
    local ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | cut -d':' -f2)
    if [ -z "$ssh_port" ]; then
        ssh_port="22"  # Default SSH port if not found
    fi
    echo "$ssh_port"
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

    # Log system information
    log_message "INFO" "Script started by user: $CURRENT_USER"
    log_message "INFO" "System: $(uname -a)"
    log_message "INFO" "Distribution: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
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
        "/etc/ufw/before.rules"
        "/etc/ufw/after.rules"
    )
    
    for file in "${files_to_backup[@]}"; do
        if [[ -f "$file" ]]; then
            cp "$file" "${BACKUP_DIR}/$(basename "$file").original"
            log_message "INFO" "Backed up $file"
        fi
    done

    # Backup current UFW rules and DNS settings
    ufw status numbered > "${BACKUP_DIR}/ufw_rules.backup"
    resolvectl status > "${BACKUP_DIR}/dns_settings.original" 2>/dev/null || true
}

# Enhanced UFW management function with SSH protection
manage_ufw() {
    log_message "INFO" "=== Configuring UFW firewall ==="
    
    local ssh_port=$(check_ssh)
    log_message "INFO" "Detected SSH port: $ssh_port"
    
    # Backup current UFW status
    ufw status > "${BACKUP_DIR}/ufw_status.before"
    
    # Reset UFW to default
    ufw --force reset
    
    # Set default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH first!
    log_message "INFO" "Ensuring SSH access is preserved on port $ssh_port"
    ufw allow in "$ssh_port"/tcp comment 'SSH access'
    
    # Configure DNSCrypt rules
    ufw allow in on lo to any port 53 proto udp comment 'DNSCrypt UDP'
    ufw allow in on lo to any port 53 proto tcp comment 'DNSCrypt TCP'
    
    # Enable UFW if not active
    if ! ufw status | grep -q "Status: active"; then
        log_message "INFO" "Enabling UFW..."
        echo "y" | ufw enable
    else
        ufw reload
    fi
    
    log_message "INFO" "UFW configuration completed"
    ufw status verbose | tee "${BACKUP_DIR}/ufw_status.after"
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
    
    # Backup original resolv.conf if it exists
    if [ -f "/etc/resolv.conf" ]; then
        cp /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.original"
    fi
    
    # Remove immutable attribute if set
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    # Reset resolved configuration
    cat > /etc/systemd/resolved.conf << 'EOL'
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9 149.112.112.112
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
    
    # First, check if port 53 is in use
    if ss -tulpn | grep ':53 '; then
        log_message "INFO" "Port 53 is currently in use. Stopping conflicting services..."
        # Stop all potentially conflicting services
        systemctl stop systemd-resolved || true
        systemctl stop named || true
        systemctl stop bind9 || true
        sleep 2
    fi

    # Stop all related services
    systemctl stop dnscrypt-proxy.socket || true
    systemctl stop dnscrypt-proxy.service || true
    
    # Disable socket activation
    systemctl disable dnscrypt-proxy.socket || true
    systemctl disable dnscrypt-proxy.service || true
    
    # Get correct user and group for dnscrypt-proxy
    DNSCRYPT_USER="dnscrypt-proxy"
    DNSCRYPT_GROUP="dnscrypt-proxy"
    
    # Create group if it doesn't exist
    if ! getent group "$DNSCRYPT_GROUP" >/dev/null; then
        groupadd -r "$DNSCRYPT_GROUP"
    fi
    
    # Create user if it doesn't exist
    if ! id "$DNSCRYPT_USER" >/dev/null 2>&1; then
        useradd -r -g "$DNSCRYPT_GROUP" -s /bin/false -d /var/cache/dnscrypt-proxy "$DNSCRYPT_USER"
    fi

    log_message "INFO" "Using user:group = $DNSCRYPT_USER:$DNSCRYPT_GROUP"

    # Create required directories
    mkdir -p /var/log/dnscrypt-proxy
    mkdir -p /var/cache/dnscrypt-proxy
    mkdir -p /etc/dnscrypt-proxy
    
    # Set correct ownership and permissions
    chown -R "$DNSCRYPT_USER:$DNSCRYPT_GROUP" /var/log/dnscrypt-proxy
    chown -R "$DNSCRYPT_USER:$DNSCRYPT_GROUP" /var/cache/dnscrypt-proxy
    chmod 755 /var/log/dnscrypt-proxy
    chmod 755 /var/cache/dnscrypt-proxy

    # Configure systemd-resolved first
    cat > /etc/systemd/resolved.conf << 'EOL'
[Resolve]
DNS=127.0.0.53
FallbackDNS=1.1.1.1 8.8.8.8
DNSStubListener=no
Cache=yes
DNSOverTLS=no
DNSSEC=false
EOL

    # Create dnscrypt-proxy configuration
    cat > /etc/dnscrypt-proxy/dnscrypt-proxy.toml << 'EOL'
listen_addresses = ['127.0.0.53:53']
server_names = ['cloudflare', 'google']
fallback_resolvers = ['1.1.1.1:53', '8.8.8.8:53']
max_clients = 250
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = true
doh_servers = true
require_dnssec = false
require_nolog = true
require_nofilter = true
force_tcp = false
timeout = 2500
keepalive = 30
log_level = 2
use_syslog = true
cache = true
cache_size = 4096
cache_min_ttl = 600
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600

[sources]
  [sources.'public-resolvers']
    urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
    cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
    minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
    refresh_delay = 72
    prefix = ''
EOL

    # Ensure correct permissions for configuration files
    chown -R root:root /etc/dnscrypt-proxy
    chmod 644 /etc/dnscrypt-proxy/dnscrypt-proxy.toml

    # Create and configure systemd service override
    mkdir -p /etc/systemd/system/dnscrypt-proxy.service.d
    cat > /etc/systemd/system/dnscrypt-proxy.service.d/override.conf << EOL
[Service]
User=$DNSCRYPT_USER
Group=$DNSCRYPT_GROUP
RuntimeDirectory=dnscrypt-proxy
RuntimeDirectoryMode=0755
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
EOL

    # Create correct resolv.conf
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf << 'EOL'
nameserver 127.0.0.53
options edns0
EOL

    # Lock resolv.conf to prevent changes
    chattr +i /etc/resolv.conf

    # Reload systemd and restart services
    systemctl daemon-reload
    
    # Start services in correct order
    systemctl restart systemd-resolved
    sleep 2
    
    # Enable and start dnscrypt-proxy
    systemctl enable dnscrypt-proxy
    systemctl start dnscrypt-proxy
    sleep 2

    # Verify service status
    if ! systemctl is-active --quiet dnscrypt-proxy; then
        log_message "ERROR" "DNSCrypt-proxy failed to start"
        systemctl status dnscrypt-proxy
        return 1
    fi

    # Double check port binding
    if ! ss -tulpn | grep '127.0.0.53:53'; then
        log_message "ERROR" "DNSCrypt-proxy is not bound to port 53"
        return 1
    fi

    log_message "INFO" "DNSCrypt-proxy configuration completed successfully"
}

# Function to verify installation with timeout
verify_installation() {
    log_message "INFO" "=== Verifying Installation ==="
    local verification_failed=0
    local timeout=45
    local start_time=$(date +%s)
    
    # Wait for services to be fully started
    sleep 10
    
    # Check service status
    if ! systemctl is-active --quiet dnscrypt-proxy; then
        log_message "ERROR" "DNSCrypt-proxy service is not running"
        systemctl status dnscrypt-proxy
        verification_failed=1
    fi
    
    # Check port 53 binding
    if ! ss -tulpn | grep '127.0.0.53:53'; then
        log_message "ERROR" "Port 53 is not properly bound to 127.0.0.53"
        ss -tulpn | grep ":53" || true
        verification_failed=1
    fi
    
    # Test DNS resolution with timeout
    local dns_test_passed=0
    while [ $(($(date +%s) - start_time)) -lt $timeout ]; do
        if dig +short +timeout=2 google.com @127.0.0.53 >/dev/null; then
            dns_test_passed=1
            log_message "INFO" "DNS resolution test successful"
            break
        fi
        log_message "INFO" "Waiting for DNS resolution to become available..."
        sleep 2
    done
    
    if [ $dns_test_passed -eq 0 ]; then
        log_message "ERROR" "DNS resolution test failed after ${timeout} seconds"
        verification_failed=1
    fi
    
    # Additional DNS tests
    if [ $verification_failed -eq 0 ]; then
        log_message "INFO" "Testing additional DNS queries..."
        for domain in cloudflare.com microsoft.com amazon.com; do
            if ! dig +short +timeout=2 "$domain" @127.0.0.53 >/dev/null; then
                log_message "ERROR" "Failed to resolve $domain"
                verification_failed=1
                break
            fi
        done
    fi

    # Verify SSH access is still working
    local ssh_port=$(check_ssh)
    if ! ss -tulpn | grep -q ":${ssh_port}"; then
        log_message "ERROR" "SSH port ${ssh_port} is not accessible!"
        verification_failed=1
    fi
    
    return $verification_failed
}

# Rollback function in case of failure
rollback() {
    log_message "ERROR" "Installation failed, initiating rollback..."
    
    # Remove immutable attribute from resolv.conf
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    # Restore original resolv.conf
    if [ -f "${BACKUP_DIR}/resolv.conf.original" ]; then
        cp "${BACKUP_DIR}/resolv.conf.original" /etc/resolv.conf
    fi
    
    # Restore original UFW rules
    if [ -f "${BACKUP_DIR}/ufw_rules.backup" ]; then
        ufw --force reset
        while read -r rule; do
            if [[ $rule =~ \[.*\].*ALLOW.* ]]; then
                port=$(echo "$rule" | grep -oP '(?<=\[)[0-9]+(?=\])')
                ufw allow "$port"
            fi
        done < "${BACKUP_DIR}/ufw_rules.backup"
    fi
    
    # Stop DNSCrypt-proxy
    systemctl stop dnscrypt-proxy 2>/dev/null || true
    
    # Reset DNS resolver
    cat > /etc/systemd/resolved.conf << 'EOL'
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9 149.112.112.112
DNSStubListener=yes
Cache=yes
EOL

    systemctl restart systemd-resolved
    
    log_message "INFO" "Rollback completed. Original configuration restored."
    exit 1
}

# Main installation process
main() {
    log_message "INFO" "Starting DNSCrypt installation script v${VERSION}"
    log_message "INFO" "Started by user: ${CURRENT_USER} at ${SCRIPT_START_TIME}"
    
    # Create trap for cleanup on script failure
    trap rollback ERR
    
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
    
    # Configure UFW (with SSH protection)
    manage_ufw
    
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
        echo -e "- SSH access is preserved"
        echo -e "\nTo monitor the service: ${YELLOW}systemctl status dnscrypt-proxy${NC}"
        echo -e "To view logs: ${YELLOW}journalctl -u dnscrypt-proxy${NC}"
    else
        log_message "ERROR" "Installation verification failed"
        rollback
    fi
}

# Execute main function
main