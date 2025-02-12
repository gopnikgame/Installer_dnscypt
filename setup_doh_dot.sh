#!/bin/bash

# Enable strict error checking
set -e

# Logging setup
LOG_FILE="/tmp/dnscrypt_setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Backup current settings
BACKUP_DIR="/etc/dnscrypt-proxy/backup_$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"

# Function to check and open port 53
manage_ufw() {
    echo -e "\n=== Checking UFW firewall ==="
    local ufw_status=$(ufw status verbose | grep "53/udp" || true)
    
    if [[ -z "$ufw_status" ]]; then
        echo "Opening port 53 for local DNS..."
        ufw allow in on lo to 127.0.0.53 port 53 proto udp
        ufw allow in on lo to 127.0.0.53 port 53 proto tcp
        ufw reload
        echo "Port 53 (TCP/UDP) opened for localhost"
    else
        echo "Port 53 already configured:"
        echo "$ufw_status"
    fi
}

# Function to show current DNS settings
show_current_settings() {
    echo -e "\n=== Current DNS Settings ==="
    resolvectl status | grep -E 'DNS Servers|DNS Over TLS|DNSSEC'
    echo -e "\n/etc/resolv.conf:"
    cat /etc/resolv.conf
}

# Check pre-installation settings
echo "=== Collecting initial system state ==="
show_current_settings > "$BACKUP_DIR/pre_install_settings.txt"
ufw status verbose > "$BACKUP_DIR/ufw_status.before"

# Install dnscrypt-proxy
echo -e "\n=== Installing dnscrypt-proxy ==="
apt update
apt install -y dnscrypt-proxy

# Backup original config
cp /etc/dnscrypt-proxy/dnscrypt-proxy.toml "$BACKUP_DIR/dnscrypt-proxy.toml.original"

# Configure dnscrypt-proxy
echo -e "\n=== Configuring dnscrypt-proxy ==="
cat > /etc/dnscrypt-proxy/dnscrypt-proxy.toml << 'EOL'
# Google DNS (primary)
server_names = ['google', 'google-ipv6', 'quad9-doh-ip4-filter-pri', 'cloudflare']

# Enable logging
log_level = 2
log_file = '/var/log/dnscrypt-proxy.log'

# Listen on local port
listen_addresses = ['127.0.0.53:53']

# Enable DNS cache
cache = true

# Fallback resolvers
[static]
  [static.'quad9-doh-ip4-filter-pri']
  stamp = 'sdns://AgMAAAAAAAAADjE0OS4xMTIuMTEyLjEziAcKBu6l-OXxb_8aw-qqiHnETeocKjUYkiQD5YN0YAhpL2Rucy5xdWFkOS5uZXQ6ODQ0MwovZG5zLXF1ZXJ5'

  [static.'cloudflare']
  stamp = 'sdns://AgcAAAAAAAAABzEuMC4wLjGgENkGmDNSOVe_Lp5I2e0dTH0qHK3uUIpWP6gx7WgPgs0VZG5zLmNsb3VkZmxhcmUuY29tCi9kbnMtcXVlcnk'

# Security settings
dnscrypt_ephemeral_keys = true
tls_disable_session_tickets = true

EOL

# Configure firewall
manage_ufw

# Configure systemd-resolved
echo -e "\n=== Configuring systemd-resolved ==="
cp /etc/systemd/resolved.conf "$BACKUP_DIR/resolved.conf.original"
cat > /etc/systemd/resolved.conf << 'EOL'
[Resolve]
DNS=127.0.0.53
DNSOverTLS=yes
DNSSEC=yes
FallbackDNS=1.1.1.1 9.9.9.9
# Disable DNS stub listener to avoid port conflict
DNSStubListener=no
EOL

# Restart services
echo -e "\n=== Restarting services ==="
systemctl restart dnscrypt-proxy
systemctl restart systemd-resolved

# Post-install verification
echo -e "\n=== Verifying installation ==="
echo "Service status:"
systemctl status dnscrypt-proxy --no-pager | grep "Active:"

echo -e "\n=== Checking port 53 ==="
ss -tulpn | grep ":53" || echo "Port 53 not listening!"

echo -e "\n=== New DNS Settings ==="
show_current_settings > "$BACKUP_DIR/post_install_settings.txt"
cat "$BACKUP_DIR/post_install_settings.txt"

# Final check
echo -e "\n=== Testing DNS resolution ==="
dig +short google.com @127.0.0.53 || echo "DNS resolution failed!"

# Show summary
echo -e "\n=== Setup Summary ==="
echo "DNSCrypt-Proxy configured with:"
echo "- Primary: Google DNS (DoH)"
echo "- Fallbacks: Quad9 and Cloudflare"
echo "- Logging enabled: /var/log/dnscrypt-proxy.log"
echo "- Backup files saved to: $BACKUP_DIR"
echo -e "\nFirewall changes:"
diff -u "$BACKUP_DIR/ufw_status.before" <(ufw status verbose) || true
echo -e "\nDNS settings changes:"
diff -u "$BACKUP_DIR/pre_install_settings.txt" "$BACKUP_DIR/post_install_settings.txt" || true

echo -e "\nSetup complete! Check $LOG_FILE for full details."
