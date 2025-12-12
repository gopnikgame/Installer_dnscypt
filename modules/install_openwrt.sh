#!/bin/sh

###############################################################################
# DNSCrypt-Proxy Setup Script for OpenWRT with Rollback Support
# Version: 1.2.1
# This script installs and configures dnscrypt-proxy2 with automatic rollback
# Compatible with: OpenWRT 19.07+, 21.02+ (recommended)
# 
# Usage: 
#   wget -O /tmp/install_openwrt.sh https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/modules/install_openwrt.sh
#   sh /tmp/install_openwrt.sh
###############################################################################

set -e  # Exit on error

# Color codes for output (check terminal support)
if [ -t 1 ] && [ -n "${TERM}" ] && [ "${TERM}" != "dumb" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Script version
SCRIPT_VERSION="1.2.1"

# Backup directory
BACKUP_DIR="/tmp/dnscrypt_backup_$(date +%s)"
ROLLBACK_NEEDED=0

# Banner
print_banner() {
    printf "\n"
    printf "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${BLUE}║${NC}       DNSCrypt-Proxy Installer for OpenWRT v${SCRIPT_VERSION}      ${BLUE}║${NC}\n"
    printf "${BLUE}║${NC}              Automatic Setup with Rollback                 ${BLUE}║${NC}\n"
    printf "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"
}

# Logging functions
log_info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

log_step() {
    printf "\n${BLUE}➜${NC} %s\n" "$1"
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
    printf "\n${YELLOW}Backup location: %s${NC}\n" "$BACKUP_DIR"
    exit 1
}

# Trap errors and perform rollback
trap 'rollback_changes' ERR

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        printf "\n${YELLOW}Please run as root or use: su${NC}\n\n"
        exit 1
    fi
}

# Check OpenWRT version
check_openwrt_version() {
    log_step "Checking OpenWRT version..."
    
    if [ ! -f /etc/openwrt_release ]; then
        log_error "This script is designed for OpenWRT only"
        exit 1
    fi
    
    # Source the release file
    . /etc/openwrt_release
    
    log_info "OpenWRT Version: ${DISTRIB_RELEASE:-Unknown}"
    log_info "Description: ${DISTRIB_DESCRIPTION:-Unknown}"
    
    # Basic version check (19.07+)
    local major_version=$(echo "$DISTRIB_RELEASE" | cut -d. -f1)
    if [ "$major_version" -lt 19 ] 2>/dev/null; then
        log_warn "OpenWRT version may be too old. Recommended: 19.07+"
        printf "Continue anyway? [y/N]: "
        read -r response
        if [ "$response" != "y" ] && [ "$response" != "Y" ]; then
            exit 1
        fi
    fi
}

# Check available space
check_space() {
    log_step "Checking available disk space..."
    
    local available=$(df /overlay 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$available" ]; then
        available=$(df / | awk 'NR==2 {print $4}')
    fi
    
    log_info "Available space: ${available}KB"
    
    # Require at least 10MB free
    if [ "$available" -lt 10240 ]; then
        log_error "Insufficient disk space. Required: 10MB, Available: ${available}KB"
        log_warn "Please free up some space and try again"
        exit 1
    fi
}

# Check internet connectivity
check_connectivity() {
    log_step "Checking internet connectivity..."
    
    if ping -c 1 -W 5 8.8.8.8 > /dev/null 2>&1; then
        log_info "Internet connectivity OK"
    elif ping -c 1 -W 5 1.1.1.1 > /dev/null 2>&1; then
        log_info "Internet connectivity OK"
    else
        log_error "No internet connectivity. Please check your connection."
        exit 1
    fi
}

# Install dnscrypt-proxy2
install_dnscrypt() {
    log_step "Installing DNSCrypt-Proxy2..."
    
    log_info "Updating package lists..."
    opkg update || {
        log_error "Failed to update package lists"
        return 1
    }
    
    # Check if already installed
    if opkg list-installed | grep -q "dnscrypt-proxy2"; then
        log_warn "dnscrypt-proxy2 is already installed"
        printf "Reinstall? [y/N]: "
        read -r response
        if [ "$response" = "y" ] || [ "$response" = "Y" ]; then
            opkg remove dnscrypt-proxy2 --force-depends
        else
            return 0
        fi
    fi
    
    log_info "Installing dnscrypt-proxy2..."
    if opkg install dnscrypt-proxy2; then
        touch "$BACKUP_DIR/package_installed.flag"
        log_info "dnscrypt-proxy2 installed successfully"
    else
        log_error "Failed to install dnscrypt-proxy2"
        log_warn "Try: opkg update && opkg install dnscrypt-proxy2"
        return 1
    fi
}

# Configure DNSCrypt
configure_dnscrypt() {
    log_step "Configuring DNSCrypt-Proxy..."
    
    backup_file "/etc/dnscrypt-proxy2/dnscrypt-proxy.toml"
    
    cat > /etc/dnscrypt-proxy2/dnscrypt-proxy.toml << 'EOF'
# DNSCrypt-Proxy Configuration for OpenWRT
# Optimized for router environment

# DNS Servers
server_names = ['cloudflare', 'google', 'quad9-dnscrypt-ip4-filter-pri']

# Load balancing strategy
# 'p2' - pick random from 2 fastest (recommended)
# 'ph' - pick random from fastest half
# 'first' - always use fastest
lb_strategy = 'p2'

# Listen address - must be different from dnsmasq
listen_addresses = ['127.0.0.53:53']

# Connection limits
max_clients = 250

# Protocol support
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = true
doh_servers = true

# Security requirements
require_dnssec = true
require_nolog = true
require_nofilter = false

disabled_server_names = []

force_tcp = false
http3 = false
timeout = 2500
keepalive = 30

# Bootstrap resolvers (by IP to avoid DNS loop)
bootstrap_resolvers = ['9.9.9.11:53', '8.8.8.8:53']
ignore_system_dns = true

# Network probe settings
netprobe_timeout = 2500
netprobe_address = '9.9.9.9:53'

# Block settings
block_ipv6 = true
block_unqualified = true
block_undelegated = true
reject_ttl = 10

# Caching (important for router performance)
cache = true
cache_size = 4096
cache_min_ttl = 2400
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600

# Sources for server lists
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
urls = ['https://quad9.net/dnscrypt/quad9-resolvers.md',
        'https://raw.githubusercontent.com/Quad9DNS/dnscrypt-settings/main/dnscrypt/quad9-resolvers.md']
minisign_key = 'RWQBphd2+f6eiAqBsvDZEBXBGHQBJfeG6G+wJPPKxCZMoEQYpmoysKUN'
cache_file = 'quad9-resolvers.md'
prefix = 'quad9-'

# Fragmented UDP packets workaround
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
    log_step "Configuring dnsmasq..."
    
    backup_uci_config "dhcp"
    
    # Remove any existing dnscrypt server entries
    while uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null; do :; done
    
    # Add DNS forwarding to dnscrypt-proxy
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.53'
    
    # Prevent DNS leaks and disable dnsmasq cache (dnscrypt has its own)
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci set dhcp.@dnsmasq[0].localuse='1'
    uci set dhcp.@dnsmasq[0].cachesize='0'
    
    # Optional: Enable query logging (commented out by default)
    # uci set dhcp.@dnsmasq[0].logqueries='1'
    # uci set dhcp.@dnsmasq[0].logfacility='/tmp/dnsmasq_queries.log'
    
    uci commit dhcp
    
    log_info "dnsmasq configured successfully"
}

# Configure NTP with IP addresses
configure_ntp() {
    log_step "Configuring NTP servers (by IP to avoid DNS loop)..."
    
    backup_uci_config "system"
    
    # Remove existing NTP servers
    while uci -q delete system.ntp.server 2>/dev/null; do :; done
    
    # Add Google and Cloudflare NTP servers by IP
    uci add_list system.ntp.server='216.239.35.0'    # time1.google.com
    uci add_list system.ntp.server='216.239.35.4'    # time2.google.com
    uci add_list system.ntp.server='216.239.35.8'    # time3.google.com
    uci add_list system.ntp.server='162.159.200.123' # time.cloudflare.com
    
    uci commit system
    
    log_info "NTP servers configured"
}

# Disable ISP DNS
configure_network() {
    log_step "Disabling ISP DNS (prevent DNS leaks)..."
    
    backup_uci_config "network"
    
    # Disable peer DNS for wan interface
    uci set network.wan.peerdns='0'
    
    # Also for wan6 if it exists
    if uci -q get network.wan6 >/dev/null 2>&1; then
        uci set network.wan6.peerdns='0'
    fi
    
    # Set custom DNS (will use our dnscrypt-proxy)
    uci -q delete network.wan.dns 2>/dev/null || true
    uci add_list network.wan.dns='127.0.0.1'
    
    uci commit network
    
    log_info "ISP DNS disabled"
}

# Configure firewall rules
configure_firewall() {
    log_step "Configuring firewall rules..."
    
    backup_uci_config "firewall"
    
    # Remove existing rules if they exist
    uci -q delete firewall.dns_redirect 2>/dev/null || true
    uci -q delete firewall.dot_block 2>/dev/null || true
    uci -q delete firewall.dns_alt_redirect 2>/dev/null || true
    
    # Redirect DNS queries to dnscrypt-proxy
    uci set firewall.dns_redirect=redirect
    uci set firewall.dns_redirect.name='Divert-DNS-to-DNSCrypt'
    uci set firewall.dns_redirect.src='lan'
    uci set firewall.dns_redirect.dest='lan'
    uci set firewall.dns_redirect.src_dport='53'
    uci set firewall.dns_redirect.dest_port='53'
    uci set firewall.dns_redirect.proto='tcp udp'
    uci set firewall.dns_redirect.target='DNAT'
    
    # Block DNS-over-TLS (port 853) to prevent bypass
    uci set firewall.dot_block=rule
    uci set firewall.dot_block.name='Block-DoT-Bypass'
    uci set firewall.dot_block.src='lan'
    uci set firewall.dot_block.dest='wan'
    uci set firewall.dot_block.dest_port='853'
    uci set firewall.dot_block.proto='tcp'
    uci set firewall.dot_block.target='REJECT'
    
    uci commit firewall
    
    log_info "Firewall rules configured"
}

# Add to sysupgrade backup
add_to_backup() {
    log_step "Adding DNSCrypt config to sysupgrade backup..."
    
    if [ ! -f /etc/sysupgrade.conf ]; then
        touch /etc/sysupgrade.conf
    fi
    
    if ! grep -q "/etc/dnscrypt-proxy2/" /etc/sysupgrade.conf 2>/dev/null; then
        echo "/etc/dnscrypt-proxy2/" >> /etc/sysupgrade.conf
        log_info "Added to sysupgrade.conf"
    else
        log_info "Already in sysupgrade.conf"
    fi
}

# Start services
start_services() {
    log_step "Starting services..."
    
    # Enable and start dnscrypt-proxy
    /etc/init.d/dnscrypt-proxy enable
    if /etc/init.d/dnscrypt-proxy start; then
        log_info "DNSCrypt-Proxy started"
    else
        log_error "Failed to start dnscrypt-proxy"
        return 1
    fi
    
    sleep 3
    
    # Restart dnsmasq
    if /etc/init.d/dnsmasq restart; then
        log_info "dnsmasq restarted"
    else
        log_error "Failed to restart dnsmasq"
        return 1
    fi
    
    # Restart firewall
    if /etc/init.d/firewall restart; then
        log_info "Firewall restarted"
    else
        log_warn "Failed to restart firewall (non-critical)"
    fi
    
    # Restart NTP
    /etc/init.d/sysntpd restart 2>/dev/null || log_warn "NTP restart skipped"
    
    log_info "All services started successfully"
}

# Verify configuration
verify_configuration() {
    log_step "Verifying installation..."
    
    # Check if dnscrypt-proxy is running
    if ! pgrep -f dnscrypt-proxy >/dev/null; then
        log_error "dnscrypt-proxy process is not running"
        return 1
    fi
    log_info "✓ DNSCrypt-Proxy process is running"
    
    # Check if listening on correct port
    if netstat -ln 2>/dev/null | grep -q "127.0.0.53:53"; then
        log_info "✓ Listening on 127.0.0.53:53"
    else
        log_warn "May not be listening on expected port"
    fi
    
    # Test DNS resolution
    log_info "Testing DNS resolution..."
    if nslookup google.com 127.0.0.53 >/dev/null 2>&1; then
        log_info "✓ DNS resolution test PASSED"
    else
        log_warn "DNS resolution test failed (may need time to initialize)"
    fi
    
    # Check dnsmasq config
    if uci get dhcp.@dnsmasq[0].server 2>/dev/null | grep -q "127.0.0.53"; then
        log_info "✓ dnsmasq configured correctly"
    fi
    
    log_info "Verification completed"
}

# Show status and recommendations
show_status() {
    printf "\n"
    printf "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║${NC}          DNSCrypt Setup Completed Successfully!            ${GREEN}║${NC}\n"
    printf "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"
    
    printf "${BLUE}📋 Configuration Summary:${NC}\n"
    printf "  ├─ DNSCrypt listening: ${GREEN}127.0.0.53:53${NC}\n"
    printf "  ├─ Dnsmasq forwarding: ${GREEN}127.0.0.53${NC}\n"
    printf "  ├─ ISP DNS: ${YELLOW}Disabled${NC}\n"
    printf "  ├─ DNS Cache: ${GREEN}DNSCrypt (4096 entries)${NC}\n"
    printf "  ├─ Firewall: ${GREEN}Active (DNS redirect + DoT block)${NC}\n"
    printf "  └─ Backup saved: ${BLUE}%s${NC}\n" "$BACKUP_DIR"
    printf "\n"
    
    printf "${BLUE}🔧 Useful Commands:${NC}\n"
    printf "  Check status:    ${YELLOW}/etc/init.d/dnscrypt-proxy status${NC}\n"
    printf "  View logs:       ${YELLOW}logread | grep dnscrypt${NC}\n"
    printf "  Test DNS:        ${YELLOW}nslookup google.com 127.0.0.53${NC}\n"
    printf "  Test from LAN:   ${YELLOW}nslookup google.com$(NC}\n"
    printf "\n"
    
    printf "${BLUE}🌐 Next Steps:${NC}\n"
    printf "  1. Test DNS leak: ${YELLOW}https://dnsleaktest.com${NC}\n"
    printf "  2. Verify DNSSEC: ${YELLOW}https://dnssec.vs.uni-due.de${NC}\n"
    printf "  3. Check your IP is hidden from DNS provider\n"
    printf "\n"
    
    printf "${BLUE}⚠️  Manual Rollback (if needed):${NC}\n"
    printf "  1. Stop services: ${YELLOW}/etc/init.d/dnscrypt-proxy stop${NC}\n"
    printf "  2. Restore from:  ${YELLOW}%s${NC}\n" "$BACKUP_DIR"
    printf "  3. Restart:       ${YELLOW}/etc/init.d/dnsmasq restart${NC}\n"
    printf "\n"
    
    printf "${GREEN}✅ Installation successful! Enjoy encrypted DNS!${NC}\n\n"
}

# Main execution
main() {
    print_banner
    
    log_info "Starting DNSCrypt installation v${SCRIPT_VERSION}..."
    printf "\n"
    
    check_root
    check_openwrt_version
    check_space
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
main "$@"
