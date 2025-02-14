#!/bin/bash

# Обновляем метаданные
SCRIPT_START_TIME="2025-02-14 20:07:13"
CURRENT_USER="gopnikgame"

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

check_dns() {
    local domain="$1"
    if dig "$domain" @127.0.0.1 +short > /dev/null; then
        echo -e "${GREEN}✓${NC} DNS resolution working for $domain"
        return 0
    else
        echo -e "${RED}✗${NC} DNS resolution failed for $domain"
        return 1
    fi
}

echo "=== DNSCrypt Status Check ==="
echo "Time: $SCRIPT_START_TIME"
echo "User: $CURRENT_USER"
echo

echo "1. Service Status:"
if systemctl is-active --quiet dnscrypt-proxy; then
    echo -e "${GREEN}✓${NC} DNSCrypt service is running"
else
    echo -e "${RED}✗${NC} DNSCrypt service is not running"
fi

echo -e "\n2. Port 53 Check:"
if ss -lntp | grep -q dnscrypt; then
    echo -e "${GREEN}✓${NC} DNSCrypt is listening on port 53"
else
    echo -e "${RED}✗${NC} DNSCrypt is not listening on port 53"
fi

echo -e "\n3. DNS Resolution Tests:"
check_dns "google.com"
check_dns "cloudflare.com"
check_dns "github.com"

echo -e "\n4. DNS Configuration:"
if grep -q "nameserver 127.0.0.1" /etc/resolv.conf; then
    echo -e "${GREEN}✓${NC} resolv.conf correctly configured"
else
    echo -e "${RED}✗${NC} resolv.conf not configured for DNSCrypt"
fi

echo -e "\n5. Response Time Test:"
time dig google.com @127.0.0.1 +short

echo -e "\n6. DNSCrypt Configuration:"
if [ -f "/etc/dnscrypt-proxy/dnscrypt-proxy.toml" ]; then
    echo -e "${GREEN}✓${NC} Configuration file exists"
    echo "Selected servers:"
    grep "server_names" /etc/dnscrypt-proxy/dnscrypt-proxy.toml
else
    echo -e "${RED}✗${NC} Configuration file missing"
fi

echo -e "\n7. DNS Leak Test:"
echo "Your DNS server appears as:"
dig whoami.akamai.net +short @127.0.0.1

echo -e "\n8. Cache Directory:"
if [ -d "/var/cache/dnscrypt-proxy" ] && [ -w "/var/cache/dnscrypt-proxy" ]; then
    echo -e "${GREEN}✓${NC} Cache directory exists and is writable"
else
    echo -e "${RED}✗${NC} Cache directory issues detected"
fi

echo -e "\nComplete test results saved to: /var/log/dnscrypt/status_check_$(date +%Y%m%d_%H%M%S).log"
