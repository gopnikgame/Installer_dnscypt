#!/bin/bash
# modules/fix_dns.sh

# Константы
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
RESOLV_CONF="/etc/resolv.conf"
RESOLVED_CONF="/etc/systemd/resolved.conf.d/dnscrypt.conf"

# Функция логирования
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$timestamp [$1] $2"
}

fix_dns_resolution() {
    log "INFO" "=== Исправление DNS резолвинга ==="
    
    # Проверка работы DNSCrypt
    if ! dig @127.0.0.1 google.com +short +timeout=5 > /dev/null; then
        log "ERROR" "DNSCrypt не отвечает на запросы"
        return 1
    fi
    
    # Создание бэкапа
    if [ ! -f "${RESOLV_CONF}.backup" ]; then
        cp "$RESOLV_CONF" "${RESOLV_CONF}.backup"
        log "INFO" "Создан бэкап resolv.conf"
    fi
    
    # Настройка systemd-resolved
    if systemctl is-active --quiet systemd-resolved; then
        log "INFO" "Настройка systemd-resolved..."
        mkdir -p /etc/systemd/resolved.conf.d/
        cat > "$RESOLVED_CONF" << EOF
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
EOF
        systemctl restart systemd-resolved
    fi
    
    # Настройка resolv.conf
    log "INFO" "Настройка resolv.conf..."
    if ! chattr -i "$RESOLV_CONF" 2>/dev/null; then
        log "INFO" "Снят атрибут immutable"
    fi
    
    echo "nameserver 127.0.0.1" > "$RESOLV_CONF"
    chattr +i "$RESOLV_CONF"
    
    # Проверка
    if dig google.com +short > /dev/null; then
        log "SUCCESS" "DNS резолвинг настроен корректно"
        return 0
    else
        log "ERROR" "Проблема с DNS резолвингом"
        if [ -f "${RESOLV_CONF}.backup" ]; then
            log "INFO" "Восстановление из бэкапа..."
            chattr -i "$RESOLV_CONF"
            cp "${RESOLV_CONF}.backup" "$RESOLV_CONF"
        fi
        return 1
    fi
}

# Запуск исправления DNS
fix_dns_resolution