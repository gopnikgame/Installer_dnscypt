#!/bin/sh

###############################################################################
# DNSCrypt-Proxy Setup Script for OpenWRT with Rollback Support
# Version: 1.3.0 - Added Passwall2/Xray compatibility
# This script installs and configures dnscrypt-proxy2 with automatic rollback
# Compatible with: OpenWRT 19.07+, 21.02+ (recommended)
# Supports integration with Passwall2/Xray
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
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    NC=''
fi

# Script version
SCRIPT_VERSION="1.3.0"

# Backup directory
BACKUP_DIR="/tmp/dnscrypt_backup_$(date +%s)"
ROLLBACK_NEEDED=0

# Detection flags
HAS_PASSWALL2=0
HAS_XRAY=0
PASSWALL2_DNS_MODE=""

# Banner
print_banner() {
    printf "\n"
    printf "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${BLUE}║${NC}       DNSCrypt-Proxy Installer for OpenWRT v${SCRIPT_VERSION}      ${BLUE}║${NC}\n"
    printf "${BLUE}║${NC}              Automatic Setup with Rollback                 ${BLUE}║${NC}\n"
    printf "${BLUE}║${NC}          🆕 Passwall2/Xray Compatible Mode 🆕              ${BLUE}║${NC}\n"
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

log_detect() {
    printf "${CYAN}[DETECT]${NC} %s\n" "$1"
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
    
    # Restart Passwall2 if it was running
    if [ "$HAS_PASSWALL2" -eq 1 ]; then
        /etc/init.d/passwall2 restart 2>/dev/null || true
    fi
    
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

# Detect Passwall2 and Xray
detect_proxy_systems() {
    log_step "Detecting existing proxy systems..."
    
    # Check for Passwall2
    if [ -f "/etc/init.d/passwall2" ] || opkg list-installed | grep -q "luci-app-passwall2"; then
        HAS_PASSWALL2=1
        log_detect "Found Passwall2 installation"
        
        # Check Passwall2 status
        if /etc/init.d/passwall2 status 2>/dev/null | grep -q "running"; then
            log_detect "Passwall2 is currently running"
        fi
        
        # Detect DNS mode
        if [ -f "/tmp/etc/passwall2/acl/default/global.json" ]; then
            log_detect "Found Passwall2 Xray configuration"
            PASSWALL2_DNS_MODE="xray"
        fi
    fi
    
    # Check for Xray
    if pgrep -f "xray" >/dev/null 2>&1; then
        HAS_XRAY=1
        log_detect "Found Xray process running"
    fi
    
    # Show detection summary
    if [ "$HAS_PASSWALL2" -eq 1 ] || [ "$HAS_XRAY" -eq 1 ]; then
        printf "\n${CYAN}╔════════════════════════════════════════════════════════════╗${NC}\n"
        printf "${CYAN}║${NC}              Proxy System Detection Summary                ${CYAN}║${NC}\n"
        printf "${CYAN}╠════════════════════════════════════════════════════════════╣${NC}\n"
        
        if [ "$HAS_PASSWALL2" -eq 1 ]; then
            printf "${CYAN}║${NC} Passwall2: ${GREEN}DETECTED${NC}                                        ${CYAN}║${NC}\n"
        else
            printf "${CYAN}║${NC} Passwall2: Not found                                       ${CYAN}║${NC}\n"
        fi
        
        if [ "$HAS_XRAY" -eq 1 ]; then
            printf "${CYAN}║${NC} Xray:      ${GREEN}RUNNING${NC}                                         ${CYAN}║${NC}\n"
        else
            printf "${CYAN}║${NC} Xray:      Not running                                     ${CYAN}║${NC}\n"
        fi
        
        printf "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n\n"
        
        log_warn "Compatible mode will be used for integration"
        printf "\n${YELLOW}DNSCrypt will integrate with existing proxy system${NC}\n"
        printf "${YELLOW}Configuration will be adapted automatically${NC}\n\n"
        
        # Ask user for integration mode
        printf "${CYAN}Choose integration mode:${NC}\n"
        printf "  ${GREEN}1${NC}) DNSCrypt as upstream DNS for Passwall2 (Recommended)\n"
        printf "  ${GREEN}2${NC}) Disable Passwall2 DNS, use only DNSCrypt\n"
        printf "  ${GREEN}3${NC}) Cancel installation\n"
        printf "\nYour choice [1]: "
        read -r integration_mode
        integration_mode=${integration_mode:-1}
        
        case "$integration_mode" in
            1)
                log_info "Selected: DNSCrypt as upstream for Passwall2"
                ;;
            2)
                log_info "Selected: Disable Passwall2 DNS"
                ;;
            3)
                log_info "Installation cancelled by user"
                exit 0
                ;;
            *)
                log_warn "Invalid choice, using default (1)"
                integration_mode=1
                ;;
        esac
        
        # Save integration mode
        echo "$integration_mode" > "$BACKUP_DIR/integration_mode.txt"
    else
        log_info "No proxy systems detected, proceeding with standard installation"
        echo "0" > "$BACKUP_DIR/integration_mode.txt"
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
    if opkg list-installed | grep -q "^dnscrypt-proxy2 "; then
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

# Configure DNSCrypt (adapted for Passwall2)
configure_dnscrypt() {
    log_step "Configuring DNSCrypt-Proxy..."
    
    backup_file "/etc/dnscrypt-proxy2/dnscrypt-proxy.toml"
    
    # Read integration mode
    local integration_mode=$(cat "$BACKUP_DIR/integration_mode.txt" 2>/dev/null || echo "0")
    
    # Choose listen address based on integration
    local listen_addr="127.0.0.53:53"
    if [ "$integration_mode" = "1" ] && [ "$HAS_PASSWALL2" -eq 1 ]; then
        # Use different port to avoid conflict with Xray
        listen_addr="127.0.0.54:53"
        log_info "Using port 127.0.0.54 for Passwall2 integration"
    fi
    
    cat > /etc/dnscrypt-proxy2/dnscrypt-proxy.toml << EOF
# DNSCrypt-Proxy Configuration for OpenWRT
# Optimized for router environment

server_names = ['dnscry.pt-moscow-ipv4', 'quad9-dnscrypt-ip4-filter-pri', 'cloudflare', 'google']
lb_strategy = 'ph'
listen_addresses = ['$listen_addr']
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

[sources.dnscry-pt-resolvers]
urls = ["https://www.dnscry.pt/resolvers.md"]
minisign_key = "RWQM31Nwkqh01x88SvrBL8djp1NH56Rb4mKLHz16K7qsXgEomnDv6ziQ"
cache_file = "dnscry.pt-resolvers.md"
refresh_delay = 73
prefix = "dnscry.pt-"

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
    
    log_info "DNSCrypt configuration created (listen: $listen_addr)"
}

# Configure dnsmasq (adapted for Passwall2)
configure_dnsmasq() {
    log_step "Configuring dnsmasq..."
    
    local integration_mode=$(cat "$BACKUP_DIR/integration_mode.txt" 2>/dev/null || echo "0")
    
    backup_uci_config "dhcp"
    
    if [ "$integration_mode" = "1" ] && [ "$HAS_PASSWALL2" -eq 1 ]; then
        # Integration mode: Don't change dnsmasq, Passwall2 will use DNSCrypt
        log_info "Skipping dnsmasq configuration (Passwall2 integration mode)"
        log_info "You'll need to manually configure Passwall2 to use 127.0.0.54"
    else
        # Standard mode
        while uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null; do :; done
        uci add_list dhcp.@dnsmasq[0].server='127.0.0.53'
        uci set dhcp.@dnsmasq[0].noresolv='1'
        uci set dhcp.@dnsmasq[0].localuse='1'
        uci set dhcp.@dnsmasq[0].cachesize='0'
        uci commit dhcp
        log_info "dnsmasq configured successfully"
    fi
}

# Configure NTP with IP addresses
configure_ntp() {
    log_step "Configuring NTP servers (by IP to avoid DNS loop)..."
    
    backup_uci_config "system"
    
    while uci -q delete system.ntp.server 2>/dev/null; do :; done
    
    uci add_list system.ntp.server='216.239.35.0'
    uci add_list system.ntp.server='216.239.35.4'
    uci add_list system.ntp.server='216.239.35.8'
    uci add_list system.ntp.server='162.159.200.123'
    
    uci commit system
    
    log_info "NTP servers configured"
}

# Disable ISP DNS (adapted for Passwall2)
configure_network() {
    log_step "Disabling ISP DNS (prevent DNS leaks)..."
    
    local integration_mode=$(cat "$BACKUP_DIR/integration_mode.txt" 2>/dev/null || echo "0")
    
    backup_uci_config "network"
    
    uci set network.wan.peerdns='0'
    
    if uci -q get network.wan6 >/dev/null 2>&1; then
        uci set network.wan6.peerdns='0'
    fi
    
    if [ "$integration_mode" != "1" ] || [ "$HAS_PASSWALL2" -eq 0 ]; then
        uci -q delete network.wan.dns 2>/dev/null || true
        uci add_list network.wan.dns='127.0.0.1'
    fi
    
    uci commit network
    
    log_info "ISP DNS disabled"
}

# Configure firewall rules (adapted for Passwall2)
configure_firewall() {
    log_step "Configuring firewall rules..."
    
    local integration_mode=$(cat "$BACKUP_DIR/integration_mode.txt" 2>/dev/null || echo "0")
    
    backup_uci_config "firewall"
    
    uci -q delete firewall.dns_redirect 2>/dev/null || true
    uci -q delete firewall.dot_block 2>/dev/null || true
    
    if [ "$integration_mode" != "1" ] || [ "$HAS_PASSWALL2" -eq 0 ]; then
        # Standard firewall rules
        uci set firewall.dns_redirect=redirect
        uci set firewall.dns_redirect.name='Divert-DNS-to-DNSCrypt'
        uci set firewall.dns_redirect.src='lan'
        uci set firewall.dns_redirect.dest='lan'
        uci set firewall.dns_redirect.src_dport='53'
        uci set firewall.dns_redirect.dest_port='53'
        uci set firewall.dns_redirect.proto='tcp udp'
        uci set firewall.dns_redirect.target='DNAT'
        
        uci set firewall.dot_block=rule
        uci set firewall.dot_block.name='Block-DoT-Bypass'
        uci set firewall.dot_block.src='lan'
        uci set firewall.dot_block.dest='wan'
        uci set firewall.dot_block.dest_port='853'
        uci set firewall.dot_block.proto='tcp'
        uci set firewall.dot_block.target='REJECT'
        
        log_info "Firewall rules configured"
    else
        log_info "Skipping firewall configuration (Passwall2 manages firewall)"
    fi
    
    uci commit firewall
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

# Start services (adapted for Passwall2)
start_services() {
    log_step "Starting services..."
    
    local integration_mode=$(cat "$BACKUP_DIR/integration_mode.txt" 2>/dev/null || echo "0")
    
    /etc/init.d/dnscrypt-proxy enable
    if /etc/init.d/dnscrypt-proxy start; then
        log_info "DNSCrypt-Proxy started"
    else
        log_error "Failed to start dnscrypt-proxy"
        return 1
    fi
    
    sleep 3
    
    if [ "$integration_mode" != "1" ] || [ "$HAS_PASSWALL2" -eq 0 ]; then
        if /etc/init.d/dnsmasq restart; then
            log_info "dnsmasq restarted"
        else
            log_error "Failed to restart dnsmasq"
            return 1
        fi
        
        if /etc/init.d/firewall restart; then
            log_info "Firewall restarted"
        else
            log_warn "Failed to restart firewall (non-critical)"
        fi
    else
        log_info "Skipping dnsmasq/firewall restart (Passwall2 integration)"
    fi
    
    /etc/init.d/sysntpd restart 2>/dev/null || log_warn "NTP restart skipped"
    
    if [ "$HAS_PASSWALL2" -eq 1 ]; then
        log_info "Restarting Passwall2..."
        /etc/init.d/passwall2 restart 2>/dev/null || log_warn "Passwall2 restart failed"
    fi
    
    log_info "All services started successfully"
}

# Verify configuration (adapted for Passwall2)
verify_configuration() {
    log_step "Verifying installation..."
    
    local integration_mode=$(cat "$BACKUP_DIR/integration_mode.txt" 2>/dev/null || echo "0")
    local dns_addr="127.0.0.53"
    
    if [ "$integration_mode" = "1" ] && [ "$HAS_PASSWALL2" -eq 1 ]; then
        dns_addr="127.0.0.54"
    fi
    
    if ! pgrep -f dnscrypt-proxy >/dev/null; then
        log_error "dnscrypt-proxy process is not running"
        return 1
    fi
    log_info "✓ DNSCrypt-Proxy process is running"
    
    if netstat -ln 2>/dev/null | grep -q "$dns_addr:53"; then
        log_info "✓ Listening on $dns_addr:53"
    else
        log_warn "May not be listening on expected port"
    fi
    
    log_info "Testing DNS resolution..."
    if nslookup google.com $dns_addr >/dev/null 2>&1; then
        log_info "✓ DNS resolution test PASSED"
    else
        log_warn "DNS resolution test failed (may need time to initialize)"
    fi
    
    log_info "Verification completed"
}

# Show status and recommendations (adapted for Passwall2)
show_status() {
    local integration_mode=$(cat "$BACKUP_DIR/integration_mode.txt" 2>/dev/null || echo "0")
    local dns_addr="127.0.0.53"
    
    if [ "$integration_mode" = "1" ] && [ "$HAS_PASSWALL2" -eq 1 ]; then
        dns_addr="127.0.0.54"
    fi
    
    printf "\n"
    printf "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║${NC}          DNSCrypt Setup Completed Successfully!            ${GREEN}║${NC}\n"
    printf "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"
    
    printf "${BLUE}📋 Configuration Summary:${NC}\n"
    printf "  ├─ DNSCrypt listening: ${GREEN}$dns_addr:53${NC}\n"
    
    if [ "$integration_mode" = "1" ] && [ "$HAS_PASSWALL2" -eq 1 ]; then
        printf "  ├─ Integration: ${CYAN}Passwall2 Mode${NC}\n"
        printf "  ├─ Passwall2: ${GREEN}Active${NC}\n"
        printf "  ├─ dnsmasq: ${YELLOW}Managed by Passwall2${NC}\n"
    else
        printf "  ├─ Dnsmasq forwarding: ${GREEN}$dns_addr${NC}\n"
        printf "  ├─ Firewall: ${GREEN}Active (DNS redirect + DoT block)${NC}\n"
    fi
    
    printf "  ├─ ISP DNS: ${YELLOW}Disabled${NC}\n"
    printf "  ├─ DNS Cache: ${GREEN}DNSCrypt (4096 entries)${NC}\n"
    printf "  └─ Backup saved: ${BLUE}%s${NC}\n" "$BACKUP_DIR"
    printf "\n"
    
    printf "${BLUE}🔧 Useful Commands:${NC}\n"
    printf "  Check status:    ${YELLOW}/etc/init.d/dnscrypt-proxy status${NC}\n"
    printf "  View logs:       ${YELLOW}logread | grep dnscrypt${NC}\n"
    printf "  Test DNS:        ${YELLOW}nslookup google.com $dns_addr${NC}\n"
    printf "\n"
    
    if [ "$integration_mode" = "1" ] && [ "$HAS_PASSWALL2" -eq 1 ]; then
        printf "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}\n"
        printf "${CYAN}║${NC}            Passwall2 Integration Instructions              ${CYAN}║${NC}\n"
        printf "${CYAN}╠════════════════════════════════════════════════════════════╣${NC}\n"
        printf "${CYAN}║${NC} 1. Open Passwall2 web interface                           ${CYAN}║${NC}\n"
        printf "${CYAN}║${NC} 2. Go to: Basic Settings → DNS Settings                   ${CYAN}║${NC}\n"
        printf "${CYAN}║${NC} 3. Set Remote DNS to: ${GREEN}127.0.0.54${NC}                            ${CYAN}║${NC}\n"
        printf "${CYAN}║${NC} 4. Set Direct DNS to: ${GREEN}127.0.0.54${NC}                            ${CYAN}║${NC}\n"
        printf "${CYAN}║${NC} 5. Disable DoH in Xray (use DNSCrypt instead)             ${CYAN}║${NC}\n"
        printf "${CYAN}║${NC} 6. Save and restart Passwall2                              ${CYAN}║${NC}\n"
        printf "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n"
        printf "\n"
        printf "${YELLOW}Alternative: Edit Xray config directly${NC}\n"
        printf "  File: ${BLUE}/tmp/etc/passwall2/acl/default/global.json${NC}\n"
        printf "  Change DNS servers to: ${GREEN}\"127.0.0.54\"${NC}\n"
        printf "\n"
    fi
    
    printf "${BLUE}🌐 Next Steps:${NC}\n"
    printf "  1. Test DNS leak: ${YELLOW}https://dnsleaktest.com${NC}\n"
    printf "  2. Verify DNSSEC: ${YELLOW}https://dnssec.vs.uni-due.de${NC}\n"
    printf "  3. Check DNS resolution speed\n"
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
    detect_proxy_systems
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
