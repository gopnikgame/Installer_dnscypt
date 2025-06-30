#!/bin/bash
# lib/anonymized_dns.sh - Библиотека функций для анонимизации DNS

# Функция для правильного добавления маршрута в конфигурацию TOML
add_route_to_config() {
    local new_route="$1"
    
    log "INFO" "Добавление маршрута: $new_route"
    
    # Проверяем, есть ли уже маршруты и активна ли секция
    if grep -q "^\[anonymized_dns\]" "$DNSCRYPT_CONFIG"; then
        # Секция есть, проверяем маршруты
        if grep -A 20 "\[anonymized_dns\]" "$DNSCRYPT_CONFIG" | grep -q "routes\s*=\s*\[\s*\]"; then
            # Пустой массив маршрутов, заменяем его
            sed -i "/\[anonymized_dns\]/,/^\[/s/routes\s*=\s*\[\s*\]/routes = [\n    $new_route\n]/" "$DNSCRYPT_CONFIG"
        elif grep -A 20 "\[anonymized_dns\]" "$DNSCRYPT_CONFIG" | grep -q "routes\s*=\s*\["; then
            # Уже есть маршруты, добавляем новый перед закрывающей скобкой
            sed -i "/\[anonymized_dns\]/,/^\[/{/\]/i\    $new_route,
            }" "$DNSCRYPT_CONFIG"
        else
            # Нет маршрутов в секции, добавляем
            sed -i "/\[anonymized_dns\]/a routes = [\n    $new_route\n]" "$DNSCRYPT_CONFIG"
        fi
    else
        log "ERROR" "Секция [anonymized_dns] не найдена. Используйте enable_anonymized_dns_section сначала."
        return 1
    fi
    
    log "SUCCESS" "Маршрут успешно добавлен"
    return 0
}

# Обновление маршрутов (замена всех)
update_anonymized_routes() {
    local route="$1"
    
    log "INFO" "Обновление маршрутов в конфигурации"
    
    # Обновляем маршруты в конфигурации с правильным форматированием
    local new_routes="routes = [\n    $route\n]"
    
    # Находим секцию anonymized_dns и заменяем маршруты
    if grep -q "^\[anonymized_dns\]" "$DNSCRYPT_CONFIG"; then
        # Заменяем существующие маршруты
        sed -i "/\[anonymized_dns\]/,/^\[/{/routes\s*=/,/\]/c\\$new_routes
        }" "$DNSCRYPT_CONFIG"
    else
        log "ERROR" "Секция [anonymized_dns] не найдена"
        return 1
    fi
    
    log "SUCCESS" "Маршруты успешно обновлены"
    return 0
}

# Настройка Anonymized DNSCrypt
configure_anonymized_dns() {
    log "INFO" "Настройка Anonymized DNSCrypt..."
    
    # Проверка наличия DNSCrypt-серверов
    if ! grep -q "dnscrypt_servers = true" "$DNSCRYPT_CONFIG"; then
        safe_echo "\n${YELLOW}Внимание: DNSCrypt-серверы не включены в конфигурации.${NC}"
        echo "Anonymized DNS работает только с DNSCrypt-серверами."
        read -p "Хотите включить DNSCrypt-серверы? (y/n): " enable_dnscrypt
        
        if [[ "${enable_dnscrypt,,}" == "y" ]]; then
            add_config_option "$DNSCRYPT_CONFIG" "" "dnscrypt_servers" "true"
            log "INFO" "DNSCrypt-серверы включены"
        else
            log "WARN" "${YELLOW}Anonymized DNS не будет работать без DNSCrypt-серверов${NC}"
        fi
    fi
    
    # Добавление источника релеев, если отсутствует
    if ! grep -q "\[sources.relays\]" "$DNSCRYPT_CONFIG" && ! grep -q "\[sources.'relays'\]" "$DNSCRYPT_CONFIG"; then
        add_relays_source
    fi
    
    # Создание секции anonymized_dns, если отсутствует
    if ! grep -q "^\[anonymized_dns\]" "$DNSCRYPT_CONFIG"; then
        log "INFO" "Создание секции anonymized_dns..."
        
        # Добавляем секцию в конец файла
        cat >> "$DNSCRYPT_CONFIG" << 'EOL'

###############################################################################
#                          Anonymized DNS                                    #
###############################################################################

[anonymized_dns]

# Маршруты для анонимизации DNS-запросов
# Каждый маршрут указывает, как подключаться к DNSCrypt-серверу через релей
routes = [
    # Пример: { server_name='example-server-1', via=['anon-example-1', 'anon-example-2'] }
]

# Пропускать серверы, несовместимые с анонимизацией, вместо прямого подключения
skip_incompatible = true

# Если публичные сертификаты для несовместимого сервера нельзя получить через релей,
# попробовать получить их напрямую. Реальные запросы всё равно будут через релеи.
# direct_cert_fallback = false

EOL
        log "SUCCESS" "${GREEN}Секция anonymized_dns успешно создана${NC}"
    else
        # Если секция закомментирована, активируем её
        if grep -q "^#\[anonymized_dns\]" "$DNSCRYPT_CONFIG"; then
            sed -i 's/^#\[anonymized_dns\]/[anonymized_dns]/' "$DNSCRYPT_CONFIG"
            log "SUCCESS" "${GREEN}Секция anonymized_dns активирована${NC}"
        fi
    fi
    
    return 0
}

# Добавление источника релеев
add_relays_source() {
    log "INFO" "Добавление источника релеев для Anonymized DNSCrypt..."
    
    # Проверяем, есть ли уже источник релеев (в разных форматах)
    if grep -q "\[sources.relays\]" "$DNSCRYPT_CONFIG" || grep -q "\[sources.'relays'\]" "$DNSCRYPT_CONFIG"; then
        log "INFO" "Источник релеев уже настроен"
        return 0
    fi
    
    # Находим секцию [sources]
    local sources_line=$(grep -n "\[sources\]" "$DNSCRYPT_CONFIG" | cut -d':' -f1)
    
    if [ -n "$sources_line" ]; then
        # Добавляем после последней [sources.*] секции
        local last_sources_line=$(grep -n "\[sources\." "$DNSCRYPT_CONFIG" | tail -n1 | cut -d':' -f1)
        
        if [ -n "$last_sources_line" ]; then
            # Найдем конец последней секции sources
            local insert_line=$((last_sources_line + 8)) # После типичной секции sources
        else
            local insert_line=$((sources_line + 1))
        fi
        
        # Добавляем конфигурацию источника релеев
        sed -i "${insert_line}i\\
\\
### Anonymized DNS relays\\
\\
[sources.relays]\\
urls = [\\
  'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/relays.md',\\
  'https://download.dnscrypt.info/resolvers-list/v3/relays.md',\\
]\\
cache_file = 'relays.md'\\
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'\\
refresh_delay = 73\\
prefix = ''" "$DNSCRYPT_CONFIG"
        
        log "SUCCESS" "${GREEN}Источник релеев успешно добавлен${NC}"
    else
        log "ERROR" "${RED}Секция [sources] не найдена в конфигурационном файле${NC}"
        return 1
    fi
    
    return 0
}