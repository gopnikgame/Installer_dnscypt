#!/bin/bash

# Enable strict error checking and prevent unset variable usage
set -euo pipefail
IFS=$'\n\t'

# Script metadata
VERSION="2.0.15"
SCRIPT_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
CURRENT_USER=$(whoami)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logging setup
LOG_FILE="/var/log/dnscrypt_install_${SCRIPT_START_TIME//[: -]/_}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Configuration
BACKUP_DIR="/var/backups/dnscrypt-proxy/backup_${SCRIPT_START_TIME//[: -]/_}"
REQUIRED_PACKAGES=("ufw" "dnsutils" "iproute2")
MIN_DNSCRYPT_VERSION="2.1.0"

# Service configuration
DNSCRYPT_USER="dnscrypt-proxy"
DNSCRYPT_GROUP="dnscrypt-proxy"
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
DNSCRYPT_BIN_PATH="/usr/local/bin/dnscrypt-proxy"

# Function for logging
log() {
  local level=$1
  local msg=$2
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "${timestamp} [${level}] ${msg}"
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
  
  # Check if systemd-resolved is active
  if systemctl is-active --quiet systemd-resolved; then
    log "INFO" "Systemd-resolved is running. Stopping it..."
    systemctl stop systemd-resolved
  fi
  
  # Disable systemd-resolved
  if systemctl list-unit-files | grep -q systemd-resolved; then
    log "INFO" "Disabling systemd-resolved..."
    systemctl disable systemd-resolved
  fi
  
  # Remove the resolved stub listener
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
  
  # Remove immutable attribute if present
  if chattr -i /etc/resolv.conf 2>/dev/null; then
    log "INFO" "Removed immutable attribute from /etc/resolv.conf"
  else
    log "DEBUG" "No immutable attribute found on /etc/resolv.conf"
  fi
  
  # Create the new static resolv.conf
  cat > /etc/resolv.conf << 'EOL'
nameserver 127.0.0.53
options edns0 trust-ad
search .
EOL
  
  # Set immutable attribute to prevent accidental modification
  if chattr +i /etc/resolv.conf 2>/dev/null; then
    log "INFO" "Set immutable attribute on /etc/resolv.conf"
  else
    log "WARN" "Failed to set immutable attribute on /etc/resolv.conf"
  fi
  
  log "INFO" "Static resolv.conf created."
}

# Install required packages
install_dependencies() {
  log "INFO" "=== Installing Dependencies ==="
  
  apt-get update
  apt-get install -y "${REQUIRED_PACKAGES[@]}"
  
  # Direct download URL for the latest stable release (v2.1.7)
  local download_url="https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/2.1.7/dnscrypt-proxy-linux_x86_64-2.1.7.tar.gz"
  
  log "INFO" "Downloading dnscrypt-proxy from $download_url..."
  local temp_dir=$(mktemp -d)
  pushd "$temp_dir" >/dev/null
  curl -fsSL -o dnscrypt-proxy.tar.gz "$download_url"
  
  if [[ ! -f "dnscrypt-proxy.tar.gz" ]]; then
    log "ERROR" "Failed to download dnscrypt-proxy binary"
    exit 1
  fi
  
  log "INFO" "Extracting dnscrypt-proxy archive..."
  tar -xzf dnscrypt-proxy.tar.gz
  
  # Log the contents of the extracted directory for debugging
  log "DEBUG" "Contents of the extracted directory:"
  find . -type f | while read -r file; do
    log "DEBUG" "Found file: $file"
  done
  
  # Find the binary file using 'find'
  local binary_path=$(find . -type f -name "dnscrypt-proxy" -print -quit)
  
  if [[ -z "$binary_path" ]]; then
    log "ERROR" "Failed to locate the dnscrypt-proxy binary in the archive. Please check the archive structure."
    exit 1
  fi
  
  log "INFO" "Installing dnscrypt-proxy binary from path: $binary_path"
  
  # Ensure the full path is used when moving the binary
  mv "$binary_path" "$DNSCRYPT_BIN_PATH"
  chmod +x "$DNSCRYPT_BIN_PATH"
  
  # Clean up
  popd >/dev/null
  rm -rf "$temp_dir"
  
  # Check installed version
  if ! command -v "$DNSCRYPT_BIN_PATH" &> /dev/null; then
    log "ERROR" "Failed to install dnscrypt-proxy binary"
    exit 1
  fi
  
  # Get the installed version
  local installed_version_output=$("$DNSCRYPT_BIN_PATH" --version 2>&1)
  local installed_version=$(echo "$installed_version_output" | grep -oE '^([0-9]+\.[0-9]+\.[0-9]+)')
  
  if [[ -z "$installed_version" ]]; then
    log "ERROR" "Failed to determine the installed version of dnscrypt-proxy. Output: $installed_version_output"
    exit 1
  fi
  
  if dpkg --compare-versions "$installed_version" lt "$MIN_DNSCRYPT_VERSION"; then
    log "ERROR" "DNSCrypt-proxy version $MIN_DNSCRYPT_VERSION or higher required. Installed version: $installed_version"
    exit 1
  fi
  
  log "INFO" "Installed DNSCrypt-proxy version: $installed_version"
  
  # Set capabilities for binding to privileged ports
  set_capabilities
}

# Set capabilities for binding to privileged ports
set_capabilities() {
  if ! command -v setcap &> /dev/null; then
    apt-get install -y libcap2-bin
  fi
  
  log "INFO" "Setting capabilities for binding to port 53..."
  if setcap cap_net_bind_service=+ep "$DNSCRYPT_BIN_PATH"; then
    log "INFO" "Capabilities set successfully."
  else
    log "ERROR" "Failed to set capabilities for binding to port 53."
    exit 1
  fi
}

# Main DNSCrypt configuration
configure_dnscrypt() {
  log "INFO" "=== Configuring DNSCrypt-proxy ==="
  
  if ! id "$DNSCRYPT_USER" &> /dev/null; then
    log "INFO" "Creating DNSCrypt-proxy user..."
    useradd -r -d /var/empty -s /bin/false "$DNSCRYPT_USER"
  fi
  
  log "INFO" "Generating DNSCrypt-proxy configuration..."
  mkdir -p /etc/dnscrypt-proxy
  cat > "$DNSCRYPT_CONFIG" << 'EOL'
server_names = ['cloudflare', 'quad9-doh-ip4-filter-pri']
listen_addresses = ['127.0.0.53:53']
max_clients = 250
keepalive = 30
ipv4_servers = true
ipv6_servers = false
cache = true
cache_size = 4096
cache_min_ttl = 600
cache_max_ttl = 86400
log_level = 2
log_file = '/var/log/dnscrypt-proxy.log'
[sources]
  [sources.'public-resolvers']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md']
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
  refresh_delay = 72
EOL
  
  chown -R "$DNSCRYPT_USER":"$DNSCRYPT_GROUP" /etc/dnscrypt-proxy
  chmod 644 "$DNSCRYPT_CONFIG"
  
  log "INFO" "Enabling and starting DNSCrypt-proxy service..."
  systemctl enable dnscrypt-proxy
  systemctl restart dnscrypt-proxy
  
  # Wait for the service to start
  sleep 5
  
  # Log service status for debugging
  log "DEBUG" "dnscrypt-proxy service status:"
  systemctl status dnscrypt-proxy --no-pager
  
  # Log last few lines of the log file
  if [[ -f "/var/log/dnscrypt-proxy.log" ]]; then
    log "DEBUG" "Last 10 lines of /var/log/dnscrypt-proxy.log:"
    tail -n 10 /var/log/dnscrypt-proxy.log
  fi
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
  
  local test_domains=("google.com" "cloudflare.com" "example.com")
  for domain in "${test_domains[@]}"; do
    if ! dig +short +timeout=3 "$domain" @127.0.0.53 >/dev/null; then
      log "ERROR" "Failed to resolve $domain. DNS query result:"
      dig +short "$domain" @127.0.0.53
      success=1
    fi
  done
  
  if ! timeout 3 bash -c "echo > /dev/tcp/localhost/$(get_ssh_port)"; then
    log "ERROR" "SSH port not accessible"
    success=1
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
  check_root
  check_system
  install_dependencies
  create_backup
  configure_resolver
  configure_firewall
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
