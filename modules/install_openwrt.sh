#!/bin/sh

###############################################################################
# DNSCrypt-Proxy Setup Script for OpenWRT with Rollback Support
# This script installs and configures dnscrypt-proxy2 with automatic rollback
###############################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Backup directory
BACKUP_DIR="/tmp/dnscrypt_backup_$(date +%s)"
ROLLBACK_NEEDED=0

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Create backup directory
create_backup_dir() {
    log_info "Creating backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
}

# Backup file if it exists
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        log_info "Backing up $file"
        cp "$file" "$BACKUP_DIR/$(basename $file).bak"
    fi
}

# Backup UCI configuration
backup_uci_config() {
    local config="$1"
    log_info "Backing up UCI config: $config"
    uci export "$config" > "$BACKUP_DIR/$config.uci.bak" 2>/dev/null || true
}

# Restore file from backup
restore_file() {
    local file="$1"
    local backup="$BACKUP_DIR/$(basename $file).bak"
    if [ -f "$backup" ]; then
        log_info "Restoring $file from backup"
        cp "$backup" "$file"
    fi
}

# Restore UCI configuration
restore_uci_config() {
    local config="$1"
    local backup="$BACKUP_DIR/$config.uci.bak"
    if [ -f "$backup" ]; then
        log_info "Restoring UCI config: $config"
        uci import "$config" < "$backup"
        uci commit "$config"
    fi
}

# Rollback all changes
rollback_changes() {
    log_error "Error detected! Rolling back changes..."
    ROLLBACK_NEEDED=1
    
    # Stop dnscrypt-proxy if it was started
    /etc/init.d/dnscrypt-proxy stop 2>/dev/null || true
    
    # Restore UCI configurations
    restore_uci_config "dhcp"
    restore_uci_config "system"
    restore_uci_config "network"
    restore_uci_config "firewall"
    
    # Restore dnscrypt-proxy config
    restore_file "/etc/dnscrypt-proxy2/dnscrypt-proxy.toml"
    
    # Restart services
    /etc/init.d/dnsmasq restart 2>/dev/null || true
    /etc/init.d/firewall restart 2>/dev/null || true
    /etc/init.d/sysntpd restart 2>/dev/null || true
    
    # Remove dnscrypt-proxy package if it was just installed
    if [ -f "$BACKUP_DIR/package_installed.flag" ]; then
        log_info "Removing dnscrypt-proxy2 package"
        opkg remove dnscrypt-proxy2 --force-depends 2>/dev/null || true
    fi
    
    log_error "Rollback completed. System restored to previous state."
    exit 1
}

# Trap errors and perform rollback
trap 'rollback_changes' ERR

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Check internet connectivity
check_connectivity() {
    log_info "Checking internet connectivity..."
    if ! ping -c 1 -W 5 8.8.8.8 > /dev/null 2>&1; then
        log_error "No internet connectivity. Please check your connection."
        exit 1
    fi
    log_info "Internet connectivity OK"
}

# Install dnscrypt-proxy2
install_dnscrypt() {
    log_info "Updating package lists..."
    opkg update || {
        log_error "Failed to update package lists"
        return 1
    }
    
    # Check if already installed
    if opkg list-installed | grep -q "dnscrypt-proxy2"; then
        log_warn "dnscrypt-proxy2 is already installed"
    else
        log_info "Installing dnscrypt-proxy2..."
        opkg install dnscrypt-proxy2 || {
            log_error "Failed to install dnscrypt-proxy2"
            return 1
        }
        touch "$BACKUP_DIR/package_installed.flag"
    fi
    
    log_info "dnscrypt-proxy2 installed successfully"
}

# Configure DNSCrypt
configure_dnscrypt() {
    log_info "Configuring DNSCrypt..."
    
    backup_file "/etc/dnscrypt-proxy2/dnscrypt-proxy.toml"
    
    cat > /etc/dnscrypt-proxy2/dnscrypt-proxy.toml << 'EOF'
server_names = ['dnscry.pt-moscow-ipv4', 'quad9-dnscrypt-ip4-filter-pri', 'cloudflare', 'google']
lb_strategy = 'ph'
listen_addresses = ['127.0.0.53:53']
max_clients = 250

ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = true
doh_servers = true

require_dnssec = true
require_nolog = true
require_nofilter = false

disabled_server_names = []

force_tcp = false
http3 = false
timeout = 2500
keepalive = 30

bootstrap_resolvers = ['9.9.9.11:53', '8.8.8.8:53']
ignore_system_dns = true
netprobe_timeout = 2500
netprobe_address = '9.9.9.9:53'

block_ipv6 = true
block_unqualified = true
block_undelegated = true

reject_ttl = 10

cache = true
cache_size = 4096
cache_min_ttl = 2400
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600

[sources]

[sources.public-resolvers]
urls = [
  'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md',
  'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md',
]
cache_file = 'public-resolvers.md'
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
refresh_delay = 73
prefix = ''

[sources.relays]
urls = [
  'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/relays.md',
  'https://download.dnscrypt.info/resolvers-list/v3/relays.md',
]
cache_file = 'relays.md'
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
refresh_delay = 73
prefix = ''

[sources.quad9-resolvers]
urls = ['https://quad9.net/dnscrypt/quad9-resolvers.md', 'https://raw.githubusercontent.com/Quad9DNS/dnscrypt-settings/main/dnscrypt/quad9-resolvers.md']
minisign_key = 'RWQBphd2+f6eiAqBsvDZEBXBGHQBJfeG6G+wJPPKxCZMoEQYpmoysKUN'
cache_file = 'quad9-resolvers.md'
prefix = 'quad9-'

[broken_implementations]
fragments_blocked = [
  'cisco',
  'cisco-ipv6',
  'cisco-familyshield',
  'cisco-familyshield-ipv6',
  'cisco-sandbox',
  'cleanbrowsing-adult',
  'cleanbrowsing-adult-ipv6',
  'cleanbrowsing-family',
  'cleanbrowsing-family-ipv6',
  'cleanbrowsing-security',
  'cleanbrowsing-security-ipv6',
]
EOF
    
    log_info "DNSCrypt configuration created"
}

# Configure dnsmasq
configure_dnsmasq() {
    log_info "Configuring dnsmasq..."
    
    backup_uci_config "dhcp"
    
    # Add DNS forwarding to dnscrypt-proxy
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.53'
    
    # Prevent DNS leaks and disable cache
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci set dhcp.@dnsmasq[0].localuse='1'
    uci set dhcp.@dnsmasq[0].cachesize='0'
    
    # Optional: Enable query logging
    # uci set dhcp.@dnsmasq[0].logqueries='1'
    # uci set dhcp.@dnsmasq[0].logfacility='/tmp/dnsmasq_queries.log'
    
    uci commit dhcp
    
    log_info "dnsmasq configured successfully"
}

# Configure NTP with IP addresses
configure_ntp() {
    log_info "Configuring NTP servers..."
    
    backup_uci_config "system"
    
    # Remove existing NTP servers
    while uci -q delete system.ntp.server 2>/dev/null; do :; done
    
    # Add Google and Cloudflare NTP servers by IP
    uci add_list system.ntp.server='216.239.35.0'
    uci add_list system.ntp.server='216.239.35.4'
    uci add_list system.ntp.server='216.239.35.8'
    uci add_list system.ntp.server='216.239.35.12'
    uci add_list system.ntp.server='162.159.200.123'
    uci add_list system.ntp.server='162.159.200.1'
    
    uci commit system
    
    log_info "NTP servers configured"
}

# Disable ISP DNS
configure_network() {
    log_info "Disabling ISP DNS..."
    
    backup_uci_config "network"
    
    # Disable peer DNS for wan interface
    uci set network.wan.peerdns='0'
    
    # Also for wan6 if it exists
    if uci -q get network.wan6 > /dev/null 2>&1; then
        uci set network.wan6.peerdns='0'
    fi
    
    uci commit network
    
    log_info "ISP DNS disabled"
}

# Configure firewall rules
configure_firewall() {
    log_info "Configuring firewall rules..."
    
    backup_uci_config "firewall"
    
    # Remove existing rules if they exist
    uci -q delete firewall.dns_redirect 2>/dev/null || true
    uci -q delete firewall.dot_block 2>/dev/null || true
    uci -q delete firewall.dns_alt_redirect 2>/dev/null || true
    
    # Redirect DNS queries to dnscrypt-proxy
    uci set firewall.dns_redirect=redirect
    uci set firewall.dns_redirect.name='Divert-DNS, port 53'
    uci set firewall.dns_redirect.src='lan'
    uci set firewall.dns_redirect.dest='lan'
    uci set firewall.dns_redirect.src_dport='53'
    uci set firewall.dns_redirect.dest_port='53'
    uci set firewall.dns_redirect.proto='tcp udp'
    uci set firewall.dns_redirect.target='DNAT'
    
    # Block DNS-over-TLS
    uci set firewall.dot_block=rule
    uci set firewall.dot_block.name='Reject-DoT, port 853'
    uci set firewall.dot_block.src='lan'
    uci set firewall.dot_block.dest='wan'
    uci set firewall.dot_block.dest_port='853'
    uci set firewall.dot_block.proto='tcp'
    uci set firewall.dot_block.target='REJECT'
    
    # Optional: Redirect alternative DNS ports
    uci set firewall.dns_alt_redirect=redirect
    uci set firewall.dns_alt_redirect.name='Divert-DNS, port 5353'
    uci set firewall.dns_alt_redirect.src='lan'
    uci set firewall.dns_alt_redirect.dest='lan'
    uci set firewall.dns_alt_redirect.src_dport='5353'
    uci set firewall.dns_alt_redirect.dest_port='53'
    uci set firewall.dns_alt_redirect.proto='tcp udp'
    uci set firewall.dns_alt_redirect.target='DNAT'
    
    uci commit firewall
    
    log_info "Firewall rules configured"
}

# Add to sysupgrade backup
add_to_backup() {
    log_info "Adding DNSCrypt config to backup list..."
    
    if ! grep -q "/etc/dnscrypt-proxy2/" /etc/sysupgrade.conf 2>/dev/null; then
        echo "/etc/dnscrypt-proxy2/" >> /etc/sysupgrade.conf
        log_info "Added to sysupgrade.conf"
    else
        log_info "Already in sysupgrade.conf"
    fi
}

# Start services
start_services() {
    log_info "Starting services..."
    
    # Enable and start dnscrypt-proxy
    /etc/init.d/dnscrypt-proxy enable
    /etc/init.d/dnscrypt-proxy start || {
        log_error "Failed to start dnscrypt-proxy"
        return 1
    }
    
    sleep 3
    
    # Restart dnsmasq
    /etc/init.d/dnsmasq restart || {
        log_error "Failed to restart dnsmasq"
        return 1
    }
    
    # Restart firewall
    /etc/init.d/firewall restart || {
        log_error "Failed to restart firewall"
        return 1
    }
    
    # Restart NTP
    /etc/init.d/sysntpd restart || {
        log_warn "Failed to restart sysntpd (non-critical)"
    }
    
    log_info "All services started successfully"
}

# Verify configuration
verify_configuration() {
    log_info "Verifying configuration..."
    
    # Check if dnscrypt-proxy is running
    if ! /etc/init.d/dnscrypt-proxy status | grep -q "running"; then
        log_error "dnscrypt-proxy is not running"
        return 1
    fi
    
    # Check if listening on correct port
    if ! netstat -ln | grep -q "127.0.0.53:53"; then
        log_error "dnscrypt-proxy is not listening on 127.0.0.53:53"
        return 1
    fi
    
    # Test DNS resolution
    log_info "Testing DNS resolution..."
    if ! nslookup google.com 127.0.0.53 > /dev/null 2>&1; then
        log_error "DNS resolution test failed"
        return 1
    fi
    
    log_info "DNS resolution test passed"
    
    # Check resolv.conf
    if ! grep -q "nameserver 127.0.0.1" /etc/resolv.conf; then
        log_warn "resolv.conf may not be configured correctly"
    fi
    
    log_info "Verification completed successfully"
}

# Show status and recommendations
show_status() {
    echo ""
    log_info "=================================="
    log_info "DNSCrypt Setup Complete!"
    log_info "=================================="
    echo ""
    log_info "Configuration details:"
    echo "  - DNSCrypt listening on: 127.0.0.53:53"
    echo "  - Dnsmasq forwarding to: 127.0.0.53"
    echo "  - ISP DNS: Disabled"
    echo "  - DNS cache: DNSCrypt (dnsmasq cache disabled)"
    echo "  - Firewall rules: Active (DNS redirect + DoT block)"
    echo ""
    log_info "Backup location: $BACKUP_DIR"
    echo ""
    log_info "Verification commands:"
    echo "  - Check status: /etc/init.d/dnscrypt-proxy status"
    echo "  - View logs: logread | grep dnscrypt"
    echo "  - Test DNS: dnscrypt-proxy -resolve google.com"
    echo "  - Test leak: https://dnsleaktest.com"
    echo ""
    log_info "To manually rollback:"
    echo "  1. Stop services: /etc/init.d/dnscrypt-proxy stop"
    echo "  2. Restore from: $BACKUP_DIR"
    echo "  3. Restart: /etc/init.d/dnsmasq restart"
    echo ""
}

# Main execution
main() {
    log_info "Starting DNSCrypt installation and configuration..."
    echo ""
    
    check_root
    create_backup_dir
    check_connectivity
    
    install_dnscrypt
    configure_dnscrypt
    configure_dnsmasq
    configure_ntp
    configure_network
    configure_firewall
    add_to_backup
    start_services
    
    sleep 5
    
    verify_configuration
    
    # Disable error trap after successful completion
    trap - ERR
    
    show_status
    
    log_info "Setup completed successfully!"
}

# Run main function
main
