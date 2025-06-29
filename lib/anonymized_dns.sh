#!/bin/bash
# lib/anonymized_dns.sh - Библиотека функций для анонимизации DNS

# Добавление маршрута в конфигурацию
add_route_to_config() {
    local new_route="$1"
    
    # Проверяем, есть ли уже маршруты
    if grep -q "routes = \[\s*\]" "$DNSCRYPT_CONFIG"; then
        # Пустой массив маршрутов, заменяем его
        sed -i "s/routes = \[\s*\]/routes = [\n    $new_route\n]/" "$DNSCRYPT_CONFIG"
    elif grep -q "routes = \[" "$DNSCRYPT_CONFIG"; then
        # Уже есть маршруты, добавляем новый
        sed -i "/routes = \[/a \    $new_route," "$DNSCRYPT_CONFIG"
    else
        # Нет секции с маршрутами, создаем ее
        sed -i "/\[anonymized_dns\]/a routes = [\n    $new_route\n]" "$DNSCRYPT_CONFIG"
    fi
}

# Обновление маршрутов
update_anonymized_routes() {
    local route="$1"
    
    # Обновляем маршруты в конфигурации
    sed -i "/routes = \[/,/\]/c\\routes = [\n    $route\n]" "$DNSCRYPT_CONFIG"
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
            sed -i "s/dnscrypt_servers = .*/dnscrypt_servers = true/" "$DNSCRYPT_CONFIG"
            log "INFO" "DNSCrypt-серверы включены"
        else
            log "WARN" "${YELLOW}Anonymized DNS не будет работать без DNSCrypt-серверов${NC}"
        fi
    fi
    
    # Добавление источника релеев, если отсутствует
    if ! grep -q "\[sources.'relays'\]" "$DNSCRYPT_CONFIG"; then
        add_relays_source
    fi
    
    # Создание секции anonymized_dns, если отсутствует
    if ! grep -q "\[anonymized_dns\]" "$DNSCRYPT_CONFIG"; then
        log "INFO" "Создание секции anonymized_dns..."
        
        # Добавляем секцию в конец файла
        cat >> "$DNSCRYPT_CONFIG" << 'EOL'

# Секция для настройки анонимного DNS
# ------------------------------------
[anonymized_dns]

# Маршруты для анонимизации DNS-запросов
# Каждый маршрут указывает, как подключаться к DNSCrypt-серверу через релей
routes = [
    # Пример: { server_name='example-server-1', via=['anon-example-1', 'anon-example-2'] }
]

# Пропускать серверы, несовместимые с анонимизацией, вместо прямого подключения
skip_incompatible = true
EOL
        log "SUCCESS" "${GREEN}Секция anonymized_dns успешно создана${NC}"
    fi
    
    return 0
}

# Добавление источника релеев
add_relays_source() {
    log "INFO" "Добавление источника релеев для Anonymized DNSCrypt..."
    
    # Находим секцию [sources]
    local sources_line=$(grep -n "\[sources\]" "$DNSCRYPT_CONFIG" | cut -d':' -f1)
    
    if [ -n "$sources_line" ]; then
        # Добавляем после последней [sources.*] секции
        local last_sources_line=$(grep -n "\[sources." "$DNSCRYPT_CONFIG" | tail -n1 | cut -d':' -f1)
        
        if [ -n "$last_sources_line" ]; then
            local insert_line=$((last_sources_line + 10)) # Примерно после конца последней [sources.*] секции
        else
            local insert_line=$((sources_line + 1))
        fi
        
        # Добавляем конфигурацию источника релеев
        sed -i "${insert_line}i\\
\\
  [sources.'relays']\\
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/relays.md', 'https://download.dnscrypt.info/resolvers-list/v3/relays.md']\\
  cache_file = 'relays.md'\\
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'\\
  refresh_delay = 72\\
  prefix = ''" "$DNSCRYPT_CONFIG"
        
        log "SUCCESS" "${GREEN}Источник релеев успешно добавлен${NC}"
    else
        log "ERROR" "${RED}Секция [sources] не найдена в конфигурационном файле${NC}"
        return 1
    fi
    
    return 0
}

# Настройка ODoH (Oblivious DoH)
configure_odoh() {
    log "INFO" "Настройка Oblivious DoH (ODoH)..."
    
    safe_echo "\n${BLUE}Oblivious DoH (ODoH):${NC}"
    echo "ODoH - это протокол, который помогает скрыть ваш IP-адрес от DNS-сервера,"
    echo "отправляя зашифрованные запросы через промежуточный релей."
    echo "В отличие от Anonymized DNSCrypt, ODoH работает с серверами DNS-over-HTTPS (DoH)."
    echo
    echo "1) Включить поддержку ODoH"
    echo "2) Отключить поддержку ODoH"
    echo "3) Настроить маршруты ODoH"
    echo "0) Отмена"
    
    read -p "Выберите опцию (0-3): " odoh_option
    
    case $odoh_option in
        1)
            # Включение поддержки ODoH
            enable_odoh_support
            ;;
        2)
            # Отключение поддержки ODoH
            disable_odoh_support
            ;;
        3)
            # Настройка маршрутов ODoH
            configure_odoh_routes
            ;;
        0)
            return 0
            ;;
        *)
            log "ERROR" "Неверный выбор"
            return 1
            ;;
    esac
    
    return 0
}

# Включение поддержки ODoH
enable_odoh_support() {
    log "INFO" "Включение поддержки Oblivious DoH..."
    
    # Включение ODoH серверов
    if grep -q "odoh_servers = " "$DNSCRYPT_CONFIG"; then
        sed -i "s/odoh_servers = .*/odoh_servers = true/" "$DNSCRYPT_CONFIG"
    else
        # Добавляем после строки doh_servers
        if grep -q "doh_servers = " "$DNSCRYPT_CONFIG"; then
            sed -i "/doh_servers = /a odoh_servers = true" "$DNSCRYPT_CONFIG"
        else
            log "ERROR" "Не найдена строка doh_servers в конфигурации"
            return 1
        fi
    fi
    
    # Добавление источников ODoH серверов и релеев
    add_odoh_sources
    
    log "SUCCESS" "Поддержка ODoH включена"
    
    return 0
}

# Отключение поддержки ODoH
disable_odoh_support() {
    log "INFO" "Отключение поддержки Oblivious DoH..."
    
    # Отключение ODoH серверов
    if grep -q "odoh_servers = " "$DNSCRYPT_CONFIG"; then
        sed -i "s/odoh_servers = .*/odoh_servers = false/" "$DNSCRYPT_CONFIG"
    else
        # Добавляем после строки doh_servers
        if grep -q "doh_servers = " "$DNSCRYPT_CONFIG"; then
            sed -i "/doh_servers = /a odoh_servers = false" "$DNSCRYPT_CONFIG"
        fi
    fi
    
    log "SUCCESS" "Поддержка ODoH отключена"
    
    return 0
}

# Добавление источников ODoH
add_odoh_sources() {
    log "INFO" "Добавление источников для ODoH..."
    
    # Проверяем наличие секции [sources]
    if ! grep -q "\[sources\]" "$DNSCRYPT_CONFIG"; then
        log "ERROR" "Секция [sources] не найдена в конфигурации"
        return 1
    fi
    
    # Находим последнюю секцию sources для вставки
    local last_sources_line=$(grep -n "\[sources." "$DNSCRYPT_CONFIG" | tail -n1 | cut -d':' -f1)
    
    if [ -z "$last_sources_line" ]; then
        # Если нет других секций sources, вставляем после основной [sources]
        local sources_line=$(grep -n "\[sources\]" "$DNSCRYPT_CONFIG" | cut -d':' -f1)
        last_sources_line=$sources_line
    fi
    
    # Добавляем источники ODoH серверов, если их нет
    if ! grep -q "\[sources.odoh-servers\]" "$DNSCRYPT_CONFIG"; then
        local insert_line=$((last_sources_line + 10))
        sed -i "${insert_line}i\\
\\
  [sources.odoh-servers]\\
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/odoh-servers.md', 'https://download.dnscrypt.info/resolvers-list/v3/odoh-servers.md']\\
  cache_file = 'odoh-servers.md'\\
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'\\
  refresh_delay = 72" "$DNSCRYPT_CONFIG"
        
        log "SUCCESS" "Добавлен источник ODoH-серверов"
        
        # Обновляем последнюю секцию sources
        last_sources_line=$(grep -n "\[sources." "$DNSCRYPT_CONFIG" | tail -n1 | cut -d':' -f1)
    fi
    
    # Добавляем источники ODoH релеев, если их нет
    if ! grep -q "\[sources.odoh-relays\]" "$DNSCRYPT_CONFIG"; then
        local insert_line=$((last_sources_line + 10))
        sed -i "${insert_line}i\\
\\
  [sources.odoh-relays]\\
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/odoh-relays.md', 'https://download.dnscrypt.info/resolvers-list/v3/odoh-relays.md']\\
  cache_file = 'odoh-relays.md'\\
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'\\
  refresh_delay = 72" "$DNSCRYPT_CONFIG"
        
        log "SUCCESS" "Добавлен источник ODoH-релеев"
    fi
    
    return 0
}

# Настройка маршрутов для ODoH (объявляем функцию для избежания ошибок)
configure_odoh_routes() {
    log "INFO" "Функция настройки маршрутов ODoH вызывается из модуля manage_anonymized_dns"
    return 0
}