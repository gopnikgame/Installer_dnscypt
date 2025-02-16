#!/bin/bash
# modules/change_dns.sh

# Константы
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"

# DNS серверы
declare -A DNS_SERVERS=(
    ["Cloudflare"]="cloudflare"
    ["Quad9"]="quad9"
    ["OpenDNS"]="opendns"
    ["AdGuard"]="adguard-dns"
    ["Anonymous Montreal"]="anon-montreal"
)

# Функция логирования
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$timestamp [$1] $2"
}

change_dns_server() {
    log "INFO" "=== Изменение DNS сервера ==="
    
    # Показываем доступные серверы
    local i=1
    declare -a server_keys
    for key in "${!DNS_SERVERS[@]}"; do
        echo "  $i) $key (${DNS_SERVERS[$key]})"
        server_keys[$i]=$key
        ((i++))
    done
    
    read -p "Выберите номер сервера (1-${#DNS_SERVERS[@]}): " choice
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#DNS_SERVERS[@]}" ]; then
        log "ERROR" "Неверный выбор"
        return 1
    fi
    
    local selected_key=${server_keys[$choice]}
    local selected_server=${DNS_SERVERS[$selected_key]}
    
    # Бэкап конфигурации
    cp "$DNSCRYPT_CONFIG" "${DNSCRYPT_CONFIG}.backup"
    
    # Обновление конфигурации
    sed -i "s/server_names = \['[^']*'\]/server_names = ['$selected_server']/" "$DNSCRYPT_CONFIG"
    
    # Перезапуск службы
    systemctl restart dnscrypt-proxy
    
    # Проверка
    sleep 2
    if dig @127.0.0.1 google.com +short +timeout=5 > /dev/null; then
        log "SUCCESS" "DNS сервер изменен на $selected_key"
        return 0
    else
        log "ERROR" "Ошибка при смене DNS сервера"
        mv "${DNSCRYPT_CONFIG}.backup" "$DNSCRYPT_CONFIG"
        systemctl restart dnscrypt-proxy
        return 1
    fi
}

# Запуск смены DNS
change_dns_server