#!/bin/bash

# Enable strict error checking and prevent unset variable usage
set -euo pipefail
IFS=$'\n\t'

# Script metadata
VERSION="2.0.16"
SCRIPT_START_TIME="2025-02-14 15:45:58"
CURRENT_USER="gopnikgame"

# Colors for output with enhanced visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Enhanced logging setup with rotation
LOG_DIR="/var/log/dnscrypt"
LOG_FILE="${LOG_DIR}/dnscrypt_install_${SCRIPT_START_TIME//[: -]/_}.log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

# Rotate old logs (keep last 5)
find "$LOG_DIR" -name "dnscrypt_install_*.log" -mtime +5 -delete

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
)
MIN_DNSCRYPT_VERSION="2.1.0"
DNSCRYPT_LATEST_VERSION="2.1.7"

# Service configuration
DNSCRYPT_USER="dnscrypt-proxy"
DNSCRYPT_GROUP="dnscrypt-proxy"
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
DNSCRYPT_BIN_PATH="/usr/local/bin/dnscrypt-proxy"
DNSCRYPT_CACHE_DIR="/var/cache/dnscrypt-proxy"

# Enhanced logging function with timestamps and log levels
log() {
  local level=$1
  local msg=$2
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local color=""
  
  case "$level" in
    "ERROR") color="$RED";;
    "WARN")  color="$YELLOW";;
    "INFO")  color="$GREEN";;
    "DEBUG") color="$BLUE";;
  esac
  
  echo -e "${timestamp} ${color}[${level}]${NC} ${msg}" | tee -a "$LOG_FILE"
}

# Check for root privileges
check_root() {
  if [[ $EUID -ne 0 ]]; then
    log "ERROR" "This script must be run as root"
    exit 1
  fi
}

# Get SSH port safely
get_ssh_port() {
  local ssh_port=$(grep -E '^Port\s+' /etc/ssh/sshd_config | awk '{print $2}' || echo "22")
  echo "$ssh_port"
}

# System health check
check_system_health() {
  log "INFO" "=== Performing System Health Check ==="
  
  # Check available disk space
  local required_space=500000  # 500MB in KB
  local available_space=$(df -k /usr/local/bin | awk 'NR==2 {print $4}')
  
  if [[ $available_space -lt $required_space ]]; then
    log "ERROR" "Insufficient disk space. Required: 500MB, Available: $((available_space/1024))MB"
    exit 1
  fi
  
  # Check system memory
  local available_mem=$(free -m | awk 'NR==2 {print $7}')
  if [[ $available_mem -lt 512 ]]; then
    log "WARN" "Low memory available: ${available_mem}MB. Recommended: 512MB"
  fi
  
  # Check system load
  local load_average=$(uptime | awk -F'load average:' '{ print $2 }' | cut -d, -f1)
  if (( $(echo "$load_average > 2.0" | bc -l) )); then
    log "WARN" "High system load detected: $load_average"
  fi
}

# System compatibility checks
check_system() {
  log "INFO" "=== System Compatibility Check ==="
  
  if ! command -v systemctl &> /dev/null; then
    log "ERROR" "Systemd is required but not found"
    exit 1
  fi
  
  local required_commands=("dig" "ss" "ufw" "systemctl" "chattr")
  for cmd in "${required_commands[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
      log "ERROR" "Required command not found: $cmd"
      exit 1
    fi
  done
  
  if ! grep -qiE 'ubuntu|debian' /etc/os-release; then
    log "WARN" "This script is optimized for Debian/Ubuntu systems"
  fi
}

# Check port 53 availability
check_port_53() {
  log "INFO" "=== Checking Port 53 Availability ==="
  
  local port_53_process=$(ss -lptn 'sport = :53' 2>/dev/null)
  
  if [[ -n "$port_53_process" ]]; then
    log "WARN" "Port 53 is currently in use:"
    echo "$port_53_process"
    
    local dns_services=("systemd-resolved" "named" "bind9" "dnsmasq" "unbound")
    
    for service in "${dns_services[@]}"; do
      if systemctl is-active --quiet "$service"; then
        log "INFO" "Stopping and disabling $service..."
        systemctl stop "$service"
        systemctl disable "$service"
        log "INFO" "$service has been stopped and disabled"
      fi
    done
    
    if ss -lptn 'sport = :53' 2>/dev/null | grep -q ":53"; then
      log "ERROR" "Port 53 is still in use after stopping known DNS services. Current processes using port 53:"
      ss -lptn 'sport = :53'
      exit 1
    fi
  fi
  
  log "INFO" "Port 53 is available"
}

# Backup existing configuration
create_backup() {
  log "INFO" "=== Creating System Backup ==="
  mkdir -p "$BACKUP_DIR"
  
  local backup_files=(
    "/etc/dnscrypt-proxy"
    "/etc/systemd/resolved.conf"
    "/etc/ufw"
    "/etc/ssh/sshd_config"
  )
  
  for item in "${backup_files[@]}"; do
    if [[ -e "$item" ]]; then
      cp -a "$item" "$BACKUP_DIR/"
      log "INFO" "Backup created: $item"
    fi
  done
  
  ufw status verbose > "$BACKUP_DIR/ufw_status.before"
}

# Safe UFW configuration
configure_firewall() {
  log "INFO" "=== Configuring Firewall ==="
  local ssh_port=$(get_ssh_port)
  
  ufw status numbered > "$BACKUP_DIR/ufw_rules.original"
  ufw --force disable
  ufw --force reset
  
  ufw default deny incoming
  ufw default allow outgoing
  
  ufw allow "$ssh_port/tcp" comment 'SSH Access'
  ufw allow in on lo to any port 53 proto udp comment 'DNSCrypt UDP'
  ufw allow in on lo to any port 53 proto tcp comment 'DNSCrypt TCP'
  
  echo "y" | ufw enable
  ufw reload
  
  log "INFO" "Firewall configured. Current rules:"
  ufw status verbose | tee "$BACKUP_DIR/ufw_status.after"
}

# Stop and disable systemd-resolved
disable_systemd_resolved() {
  log "INFO" "Stopping and disabling systemd-resolved..."
  
  if systemctl is-active --quiet systemd-resolved; then
    log "INFO" "Systemd-resolved is running. Stopping it..."
    systemctl stop systemd-resolved
  fi
  
  if systemctl list-unit-files | grep -q systemd-resolved; then
    log "INFO" "Disabling systemd-resolved..."
    systemctl disable systemd-resolved
  fi
  
  log "INFO" "Removing systemd-resolved stub listener configuration..."
  if [[ -f "/etc/resolv.conf" ]]; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
    unlink /etc/resolv.conf || rm -f /etc/resolv.conf
  fi
  
  if [[ -f "/etc/systemd/resolved.conf" ]]; then
    log "INFO" "Backing up and modifying /etc/systemd/resolved.conf..."
    cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak
    sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
  fi
  
  log "INFO" "Restarting systemd to apply changes..."
  systemctl daemon-reload
  systemctl restart systemd-networkd || true
  
  log "INFO" "Systemd-resolved has been disabled."
}

# DNS resolver configuration
configure_resolver() {
  log "INFO" "=== Configuring DNS Resolver ==="
  
  disable_systemd_resolved
  
  log "INFO" "Creating static resolv.conf..."
  
  if chattr -i /etc/resolv.conf 2>/dev/null; then
    log "INFO" "Removed immutable attribute from /etc/resolv.conf"
  else
    log "DEBUG" "No immutable attribute found on /etc/resolv.conf"
  fi
  
  cat > /etc/resolv.conf << 'EOL'
nameserver 127.0.0.53
options edns0 trust-ad
search .
EOL
  
  if chattr +i /etc/resolv.conf 2>/dev/null; then
    log "INFO" "Set immutable attribute on /etc/resolv.conf"
  else
    log "WARN" "Failed to set immutable attribute on /etc/resolv.conf"
  fi
  
  log "INFO" "Static resolv.conf created."
}

# Installation verification
verify_installation() {
  log "INFO" "=== Verifying Installation ==="
  local success=0
  
  if ! systemctl is-active --quiet dnscrypt-proxy; then
    log "ERROR" "DNSCrypt-proxy service not running. Service status:"
    systemctl status dnscrypt-proxy --no-pager
    success=1
  fi
  
  if ! ss -tuln | grep -q '127.0.0.53:53'; then
    log "ERROR" "DNSCrypt-proxy not bound to port 53. Listening ports:"
    ss -tuln
    success=1
  fi
  
  local test_domains=(
    "google.com"
    "cloudflare.com"
    "example.com"
  )
  
  for domain in "${test_domains[@]}"; do
    if ! dig +short +timeout=3 "$domain" @127.0.0.53 >/dev/null; then
      log "ERROR" "Failed to resolve $domain. DNS query result:"
      dig +short "$domain" @127.0.0.53
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

# Rollback procedure
rollback_system() {
  log "ERROR" "=== INSTALLATION FAILED - INITIATING ROLLBACK ==="
  
  if [ -f "$BACKUP_DIR/ufw_rules.original" ]; then
    log "INFO" "Restoring UFW rules..."
    ufw --force reset
    ufw --force import "$BACKUP_DIR/ufw_rules.original"
    ufw --force enable
  fi
  
  log "INFO" "Restoring original resolver configuration..."
  chattr -i /etc/resolv.conf 2>/dev/null || true
  if [ -f "$BACKUP_DIR/etc/resolv.conf" ]; then
    cp -f "$BACKUP_DIR/etc/resolv.conf" /etc/resolv.conf
  fi
  
  log "INFO" "Restarting systemd-resolved..."
  systemctl restart systemd-resolved
  
  log "ERROR" "Rollback completed. System should be in original state."
  exit 1
}

# Main installation process
main() {
  trap rollback_system ERR
  
  log "INFO" "Starting DNSCrypt-proxy installation (Version: $VERSION)"
  log "INFO" "Current user: $CURRENT_USER"
  log "INFO" "Start time: $SCRIPT_START_TIME"
  
  check_root
  check_system
  check_system_health
  check_port_53
  
  create_backup
  configure_resolver
  configure_firewall
  
  install_dependencies
  configure_dnscrypt
  
  if verify_installation; then
    log "SUCCESS" "=== DNSCrypt-proxy Successfully Installed ==="
    log "INFO" "Backup Directory: $BACKUP_DIR"
    log "INFO" "Installation Log: $LOG_FILE"
    exit 0
  else
    rollback_system
  fi
}

# Entry point
main