#!/bin/bash
# modules/check_dns.sh

# Константы
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
RESOLV_CONF="/etc/resolv.conf"
RESOLVED_CONF="/etc/systemd/resolved.conf.d/dnscrypt.conf"

# Цветовые коды
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

# Функция логирования
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "${timestamp} [$1] $2"
}

# Функция исправления DNS резолвинга
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

# Функция проверки текущего DNS сервера
check_current_dns() {
    log "INFO" "=== Проверка текущего DNS сервера ==="
    
    # Проверка resolv.conf
    log "INFO" "Проверка /etc/resolv.conf:"
    if [ -f "/etc/resolv.conf" ]; then
        echo -e "${YELLOW}Текущие DNS серверы:${NC}"
        grep "nameserver" /etc/resolv.conf | sed 's/^/  /'
        
        # Проверка симлинка
        if [ -L "/etc/resolv.conf" ]; then
            echo -e "\nresolf.conf является симлинком на:"
            ls -l /etc/resolv.conf | sed 's/^/  /'
        fi
    else
        log "WARN" "Файл /etc/resolv.conf не найден"
    fi
    
    # Проверка systemd-resolved
    if command -v resolvectl >/dev/null 2>&1; then
        echo ""
        log "INFO" "Статус systemd-resolved:"
        resolvectl status | grep -E "DNS Server|Current DNS|DNSOverTLS|DNSSEC" | sed 's/^/  /'
    fi
    
    # Проверка DNSCrypt
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        echo ""
        log "INFO" "Конфигурация DNSCrypt:"
        
        # Получаем настроенные серверы
        echo -e "${YELLOW}Настроенные серверы:${NC}"
        grep "server_names" "$DNSCRYPT_CONFIG" | sed 's/server_names = /  /'
        
        # Проверяем прослушиваемые адреса
        echo -e "\n${YELLOW}Прослушиваемые адреса:${NC}"
        grep "listen_addresses" "$DNSCRYPT_CONFIG" | sed 's/listen_addresses = /  /'
        
        # Проверяем активные протоколы
        echo -e "\n${YELLOW}Активные протоколы и настройки:${NC}"
        grep -E "^[^#]*(require_dnssec|require_nolog|require_nofilter)" "$DNSCRYPT_CONFIG" | sed 's/^/  /'
        
        # Проверка активного сервера из логов
        echo -e "\n${YELLOW}Информация о текущем сервере:${NC}"
        local active_server=$(journalctl -u dnscrypt-proxy -n 50 | grep "Server with lowest initial latency" | tail -n 1)
        if [ -n "$active_server" ]; then
            echo "  $active_server"
        fi
    fi
    
    # Тест резолвинга
    echo ""
    log "INFO" "Тестирование DNS резолвинга..."
    
    # Массив тестовых доменов с описанием
    declare -A test_domains=(
        ["whoami.akamai.net"]="Определение DNS сервера"
        ["dns.google.com"]="Google DNS"
        ["resolver.dnscrypt.info"]="DNSCrypt resolver"
        ["cloudflare.com"]="Cloudflare"
    )
    
    for domain in "${!test_domains[@]}"; do
        echo -n "  Тест ${test_domains[$domain]} ($domain): "
        if dig @127.0.0.1 "$domain" +short +timeout=5 > /dev/null 2>&1; then
            local resolve_time=$(dig @127.0.0.1 "$domain" +noall +stats 2>/dev/null | grep "Query time" | awk '{print $4}')
            echo -e "${GREEN}OK${NC} (${resolve_time}ms)"
            
            # Дополнительная информация для whoami.akamai.net
            if [ "$domain" == "whoami.akamai.net" ]; then
                echo -n "    Используемый DNS сервер: "
                dig +short "$domain" TXT | sed 's/"//g'
            fi
        else
            echo -e "${RED}ОШИБКА${NC}"
        fi
    done
    
    # Определение провайдера DNS
    echo ""
    log "INFO" "Определение DNS провайдера"
    local dns_ip=$(dig +short resolver.dnscrypt.info)
    if [ -n "$dns_ip" ]; then
        echo "  IP текущего DNS сервера: $dns_ip"
        if command -v whois >/dev/null 2>&1; then
            echo "  Информация о провайдере:"
            whois "$dns_ip" | grep -i "orgname\|organization\|netname" | head -n 3 | sed 's/^/    /'
        fi
    fi
}

# Основная логика скрипта
main() {
    # Запуск проверки DNS
    check_current_dns
    
    # Если нужно исправить DNS, раскомментируйте следующую строку
    # fix_dns_resolution
}

# Запуск главной функции
main