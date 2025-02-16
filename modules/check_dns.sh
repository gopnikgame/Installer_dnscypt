#!/bin/bash
# modules/check_dns.sh

# Константы
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"

# Функция логирования
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$timestamp [$1] $2"
}

check_current_dns() {
    log "INFO" "=== Проверка текущего DNS сервера ==="
    
    # Проверка resolv.conf
    log "INFO" "Проверка /etc/resolv.conf:"
    if [ -f "/etc/resolv.conf" ]; then
        echo "Текущие DNS серверы:"
        grep "nameserver" /etc/resolv.conf | sed 's/^/  /'
    else
        log "WARN" "Файл /etc/resolv.conf не найден"
    fi
    
    # Проверка systemd-resolved
    if command -v resolvectl >/dev/null 2>&1; then
        log "INFO" "Статус systemd-resolved:"
        resolvectl status | grep -E "DNS Server|Current DNS" | sed 's/^/  /'
    fi
    
    # Проверка DNSCrypt
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        log "INFO" "Конфигурация DNSCrypt:"
        local current_server=$(grep "server_names" "$DNSCRYPT_CONFIG" | cut -d"'" -f2)
        echo "  Настроенный сервер: $current_server"
        
        # Проверка активного сервера
        local active_server=$(journalctl -u dnscrypt-proxy -n 50 | grep "Server with lowest initial latency" | tail -n 1)
        if [ -n "$active_server" ]; then
            echo "  Активный сервер: $active_server"
        fi
    fi
    
    # Тест резолвинга
    log "INFO" "Тестирование DNS резолвинга..."
    local test_domains=("google.com" "cloudflare.com" "github.com")
    
    for domain in "${test_domains[@]}"; do
        echo -n "  Тест $domain: "
        if dig @127.0.0.1 "$domain" +short +timeout=5 > /dev/null 2>&1; then
            local resolve_time=$(dig @127.0.0.1 "$domain" +noall +stats 2>/dev/null | grep "Query time" | awk '{print $4}')
            echo "OK (${resolve_time}ms)"
        else
            echo "ОШИБКА"
        fi
    done
}

# Запуск проверки DNS
check_current_dns