#!/bin/bash
# modules/check_dns.sh - Модуль для проверки и исправления конфигурации DNS
# Создано: 2025-06-24
# Автор: gopnikgame

# Подгрузка общих функций и диагностической библиотеки
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/diagnostic.sh"

# Константы
RESOLV_CONF="/etc/resolv.conf"
RESOLVED_CONF="/etc/systemd/resolved.conf.d/dnscrypt.conf"

# Функция проверки текущего DNS сервера
check_current_dns() {
    log "INFO" "=== Проверка текущего DNS сервера ==="
    
    # Проверка системного резолвера (используем функцию из diagnostic.sh)
    check_system_resolver
    
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

# Функция полного исправления DNS резолвинга
fix_all_dns_issues() {
    log "INFO" "=== Полное исправление DNS-резолвинга ==="
    
    # 1. Проверяем и исправляем конфигурацию DNSCrypt
    log "INFO" "Проверка конфигурации DNSCrypt..."
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        # Получаем все строки с server_names
        local server_lines=$(grep -E "^[^#]*server_names" "$DNSCRYPT_CONFIG" || echo "")
        local disabled_lines=$(grep -E "^disabled_.*server_names" "$DNSCRYPT_CONFIG" || echo "")
        local commented_lines=$(grep -E "^#.*server_names" "$DNSCRYPT_CONFIG" || echo "")
        
        # Если есть отключенные (disabled_) серверы
        if [ -n "$disabled_lines" ]; then
            # Получаем список серверов из отключенных строк
            local disabled_servers=$(echo "$disabled_lines" | sed -E 's/disabled_.*server_names = \[(.*)\]/\1/' | tr -d "'" | tr -d '"')
            
            # Удаляем строку с disabled_ и добавляем правильную строку server_names
            local first_disabled=$(echo "$disabled_lines" | head -1)
            local line_num=$(grep -n "$first_disabled" "$DNSCRYPT_CONFIG" | cut -d':' -f1)
            
            if [ -n "$line_num" ]; then
                # Удаляем строку
                sed -i "${line_num}d" "$DNSCRYPT_CONFIG"
                
                # Добавляем новую строку server_names
                sed -i "${line_num}i server_names = [${disabled_servers}]" "$DNSCRYPT_CONFIG"
                
                log "SUCCESS" "Активированы ранее отключенные серверы: ${disabled_servers}"
            fi
        # Если нет активных server_names, но есть закомментированные
        elif [ -z "$server_lines" ] && [ -n "$commented_lines" ]; then
            # Получаем первую закомментированную строку
            local first_commented=$(echo "$commented_lines" | head -1)
            local servers_list=$(echo "$first_commented" | sed -E 's/#.*server_names = \[(.*)\]/\1/' | tr -d "'" | tr -d '"')
            
            # Добавляем раскомментированную строку
            local line_num=$(grep -n "$first_commented" "$DNSCRYPT_CONFIG" | cut -d':' -f1)
            
            if [ -n "$line_num" ]; then
                # Удаляем закомментированную строку
                sed -i "${line_num}d" "$DNSCRYPT_CONFIG"
                
                # Добавляем раскомментированную строку
                sed -i "${line_num}i server_names = [${servers_list}]" "$DNSCRYPT_CONFIG"
                
                log "SUCCESS" "Активированы ранее закомментированные серверы: ${servers_list}"
            fi
        # Если нет ни активных, ни отключенных, ни закомментированных server_names
        elif [ -z "$server_lines" ] && [ -z "$disabled_lines" ] && [ -z "$commented_lines" ]; then
            # Добавляем настройки по умолчанию
            sed -i "/\[sources\]/i server_names = ['cloudflare']" "$DNSCRYPT_CONFIG"
            log "SUCCESS" "Добавлен сервер Cloudflare по умолчанию"
        fi
        
        # Перезапускаем службу DNSCrypt
        log "INFO" "Перезапуск DNSCrypt-proxy..."
        if ! restart_service "dnscrypt-proxy"; then
            return 1
        fi
        
        # Даем время на запуск службы
        sleep 2
    else
        log "ERROR" "Не найден файл конфигурации DNSCrypt"
        return 1
    fi
    
    # 2. Настраиваем systemd-resolved
    if command -v resolvectl >/dev/null 2>&1; then
        log "INFO" "Настройка systemd-resolved..."
        
        # Создаем конфигурационный файл для systemd-resolved
        mkdir -p /etc/systemd/resolved.conf.d/
        cat > "$RESOLVED_CONF" << EOF
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
EOF
        
        # Перезапускаем systemd-resolved
        if ! restart_service "systemd-resolved"; then
            log "WARN" "Не удалось перезапустить systemd-resolved"
        fi
    fi
    
    # 3. Настраиваем resolv.conf
    log "INFO" "Настройка resolv.conf..."
    
    # Снимаем защиту от записи, если она есть
    if ! chattr -i "$RESOLV_CONF" 2>/dev/null; then
        log "INFO" "Снят атрибут immutable с resolv.conf"
    fi
    
    # Создаем резервную копию с помощью функции из common.sh
    if [ -f "$RESOLV_CONF" ]; then
        backup_config "$RESOLV_CONF" "resolv.conf"
    fi
    
    # Записываем новый resolv.conf
    cat > "$RESOLV_CONF" << EOF
# Сгенерировано DNSCrypt Manager
nameserver 127.0.0.1
options edns0
EOF
    
    # Защищаем от изменений
    chattr +i "$RESOLV_CONF" 2>/dev/null && log "INFO" "Установлен атрибут immutable на resolv.conf"
    
    # 4. Проверяем, что DNSCrypt работает правильно
    log "INFO" "Проверка работы DNSCrypt..."
    if dig @127.0.0.1 cloudflare.com +short +timeout=5 > /dev/null 2>&1; then
        local serve_time=$(dig @127.0.0.1 cloudflare.com +noall +stats 2>/dev/null | grep "Query time" | awk '{print $4}')
        log "SUCCESS" "DNSCrypt работает корректно! Время ответа: ${serve_time}ms"
        
        # Проверяем используемый сервер
        echo -e "${YELLOW}Проверка используемого DNS-сервера:${NC}"
        local dns_info=$(dig +short whoami.akamai.net TXT | sed 's/"//g')
        if [ -n "$dns_info" ]; then
            echo -e "  Текущий DNS-сервер: ${GREEN}$dns_info${NC}"
        else
            echo -e "  ${YELLOW}Не удалось определить используемый DNS-сервер${NC}"
        fi
        
        # Отображаем информацию об активном сервере из логов DNSCrypt
        local active_server=$(journalctl -u dnscrypt-proxy -n 20 | grep -E "Server with lowest|Using server" | tail -n 1)
        if [ -n "$active_server" ]; then
            echo -e "  ${GREEN}Активный DNSCrypt сервер: $active_server${NC}"
        fi
        
        return 0
    else
        log "ERROR" "DNSCrypt не работает корректно!"
        
        # Проверяем, запущена ли служба
        if ! check_service_status "dnscrypt-proxy"; then
            systemctl start dnscrypt-proxy
        fi
        
        # Проверяем порты
        echo -e "${YELLOW}Проверка прослушиваемых портов:${NC}"
        check_port_usage 53
        
        # Проверяем логи на ошибки
        echo -e "${YELLOW}Последние ошибки в логах DNSCrypt:${NC}"
        journalctl -u dnscrypt-proxy -n 20 --grep="error|failed|warning" --no-pager
        
        return 1
    fi
}

# Функция для определения протокола DNS
get_dns_protocol_info() {
    log "INFO" "=== Определение используемого DNS протокола ==="
    
    # Проверка конфигурации DNSCrypt
    local protocol_info=""
    local used_protocols=()
    
    echo -e "${YELLOW}Анализ протоколов из конфигурации:${NC}"
    
    # Проверяем, включены ли различные протоколы в конфигурации
    if grep -q "^[^#]*dnscrypt_servers = true" "$DNSCRYPT_CONFIG"; then
        used_protocols+=("DNSCrypt")
        echo -e "  ${GREEN}✓${NC} DNSCrypt протокол ${GREEN}включен${NC}"
    else
        echo -e "  ${RED}✗${NC} DNSCrypt протокол ${RED}отключен${NC}"
    fi
    
    if grep -q "^[^#]*doh_servers = true" "$DNSCRYPT_CONFIG"; then
        used_protocols+=("DoH")
        echo -e "  ${GREEN}✓${NC} DNS-over-HTTPS (DoH) ${GREEN}включен${NC}"
    else
        echo -e "  ${RED}✗${NC} DNS-over-HTTPS (DoH) ${RED}отключен${NC}"
    fi
    
    if grep -q "^[^#]*odoh_servers = true" "$DNSCRYPT_CONFIG"; then
        used_protocols+=("ODoH")
        echo -e "  ${GREEN}✓${NC} Oblivious DoH (ODoH) ${GREEN}включен${NC}"
    else
        echo -e "  ${RED}✗${NC} Oblivious DoH (ODoH) ${RED}отключен${NC}"
    fi
    
    if grep -q "^[^#]*dot_servers = true" "$DNSCRYPT_CONFIG"; then
        used_protocols+=("DoT")
        echo -e "  ${GREEN}✓${NC} DNS-over-TLS (DoT) ${GREEN}включен${NC}"
    else
        echo -e "  ${RED}✗${NC} DNS-over-TLS (DoT) ${RED}отключен${NC}"
    fi
    
    # HTTP/3 (QUIC) поддержка для DoH
    if grep -q "^[^#]*http3 = true" "$DNSCRYPT_CONFIG"; then
        echo -e "  ${GREEN}✓${NC} HTTP/3 (QUIC) для DoH ${GREEN}включен${NC}"
    else
        echo -e "  ${RED}✗${NC} HTTP/3 (QUIC) для DoH ${RED}отключен${NC}"
    fi
    
    # Проверка анонимизации
    echo -e "\n${YELLOW}Анализ настроек анонимизации:${NC}"
    if grep -q "\[anonymized_dns\]" "$DNSCRYPT_CONFIG" && grep -q "routes.*=.*\[" "$DNSCRYPT_CONFIG"; then
        used_protocols+=("Anonymized")
        echo -e "  ${GREEN}✓${NC} Anonymized DNSCrypt ${GREEN}включен${NC}"
        
        # Подсчет маршрутов анонимизации
        local route_count=$(grep -A 50 "\[anonymized_dns\]" "$DNSCRYPT_CONFIG" | grep -E "\[.*\].*\[.*\]" | wc -l)
        echo -e "  ${BLUE}ℹ${NC} Настроено маршрутов анонимизации: ${route_count}"
    else
        echo -e "  ${RED}✗${NC} Anonymized DNSCrypt ${RED}отключен${NC}"
    fi
    
    # Анализ логов для определения активного сервера и протокола
    echo -e "\n${YELLOW}Анализ активных соединений по логам:${NC}"
    local dns_log=$(journalctl -u dnscrypt-proxy -n 100 --no-pager 2>/dev/null)
    
    # Поиск информации о протоколе
    local protocol_line=$(echo "$dns_log" | grep -E "Connected to ([^(]*).*\(([^)]*)\)" | tail -n 1)
    
    if [ -n "$protocol_line" ]; then
        local server_name=$(echo "$protocol_line" | sed -E 's/.*Connected to ([^(]*).*/\1/' | xargs)
        local server_proto=$(echo "$protocol_line" | sed -E 's/.*\(([^)]*)\).*/\1/' | xargs)
        
        echo -e "  ${GREEN}Активное соединение:${NC} $server_name"
        echo -e "  ${GREEN}Используемый протокол:${NC} $server_proto"
    else
        # Альтернативный способ определения
        local stamp_line=$(echo "$dns_log" | grep -E "Server stamp:" | tail -n 1)
        
        if [ -n "$stamp_line" ]; then
            if echo "$stamp_line" | grep -q "sdns://A"; then
                echo -e "  ${GREEN}Используемый протокол:${NC} DNSCrypt"
            elif echo "$stamp_line" | grep -q "sdns://h"; then
                echo -e "  ${GREEN}Используемый протокол:${NC} DNS-over-HTTPS (DoH)"
            elif echo "$stamp_line" | grep -q "sdns://i"; then
                echo -e "  ${GREEN}Используемый протокол:${NC} DNS-over-TLS (DoT)"
            elif echo "$stamp_line" | grep -q "sdns://o"; then
                echo -e "  ${GREEN}Используемый протокол:${NC} Oblivious DoH (ODoH)"
            else
                echo -e "  ${YELLOW}Не удалось определить протокол из штампа сервера${NC}"
            fi
        else
            echo -e "  ${YELLOW}Не удалось определить используемый протокол из логов${NC}"
        fi
    fi
    
    # Проверка TCP/UDP
    echo -e "\n${YELLOW}Анализ транспортного протокола:${NC}"
    local force_tcp=$(grep "^[^#]*force_tcp" "$DNSCRYPT_CONFIG" | head -1 | grep -o "= ..*" | cut -d' ' -f2)
    
    if [ "$force_tcp" = "true" ]; then
        echo -e "  ${BLUE}ℹ${NC} Принудительное использование TCP ${GREEN}включено${NC}"
    else
        # Проверяем использование TCP/UDP по логам
        local udp_count=$(echo "$dns_log" | grep -i "udp" | grep -v "Failed\|Error" | wc -l)
        local tcp_count=$(echo "$dns_log" | grep -i "tcp" | grep -v "Failed\|Error" | wc -l)
        
        if [ "$udp_count" -gt 0 ] && [ "$tcp_count" -gt 0 ]; then
            echo -e "  ${BLUE}ℹ${NC} Используются оба транспорта: TCP и UDP"
            echo -e "  ${BLUE}ℹ${NC} UDP соединений: $udp_count, TCP соединений: $tcp_count"
        elif [ "$udp_count" -gt 0 ]; then
            echo -e "  ${BLUE}ℹ${NC} Преимущественно используется UDP"
        elif [ "$tcp_count" -gt 0 ]; then
            echo -e "  ${BLUE}ℹ${NC} Преимущественно используется TCP"
        else
            echo -e "  ${YELLOW}Не удалось определить транспортный протокол${NC}"
        fi
    fi
    
    # Сводная информация
    echo -e "\n${BLUE}Сводная информация о конфигурации DNS:${NC}"
    
    if [ ${#used_protocols[@]} -gt 0 ]; then
        echo -e "  ${GREEN}Включенные протоколы:${NC} ${used_protocols[*]}"
    else
        echo -e "  ${RED}Не найдены включенные DNS протоколы${NC}"
    fi
    
    # Выполняем проверку безопасности DNS из библиотеки diagnostic.sh
    check_dns_security
}

# Главная функция
main() {
    # Проверка подключения к интернету
    if ! check_internet; then
        log "ERROR" "Отсутствует подключение к интернету. Проверьте соединение и попробуйте снова."
        return 1
    fi

    # Проверка установки DNSCrypt
    if ! check_dnscrypt_installed; then
        log "ERROR" "DNSCrypt-proxy не установлен. Установите его перед использованием этого модуля."
        echo -e "${YELLOW}Используйте пункт меню 'Установить DNSCrypt'${NC}"
        return 1
    fi

    # Запуск проверки DNS
    check_current_dns
    
    # Проверяем, идет ли DNS-резолвинг через локальный DNSCrypt
    echo -e "\n${BLUE}Проверка маршрутизации DNS-запросов...${NC}"
    local is_local_dns=1
    
    # Проверка содержимого resolv.conf
    if ! grep -q "nameserver 127.0.0.1" "$RESOLV_CONF" && ! grep -q "nameserver ::1" "$RESOLV_CONF"; then
        is_local_dns=0
        echo -e "${RED}Проблема:${NC} В файле resolv.conf не настроен локальный DNS (127.0.0.1)"
    fi
    
    # Проверка работы DNSCrypt
    if ! check_service_status "dnscrypt-proxy"; then
        is_local_dns=0
        echo -e "${RED}Проблема:${NC} Служба DNSCrypt-proxy не запущена"
    fi
    
    # Проверка разрешения имен через DNSCrypt
    if ! dig @127.0.0.1 cloudflare.com +short +timeout=5 > /dev/null 2>&1; then
        is_local_dns=0
        echo -e "${RED}Проблема:${NC} DNSCrypt не отвечает на DNS-запросы"
    fi
    
    # Предлагаем пользователю исправить проблемы, если они есть
    if [ $is_local_dns -eq 0 ]; then
        echo -e "\n${YELLOW}Обнаружены проблемы с DNS-резолвингом.${NC}"
        echo -e "${RED}DNS-запросы не проходят через DNSCrypt, что снижает безопасность и приватность!${NC}"
        echo -e "${YELLOW}Хотите исправить проблему с DNS-резолвингом? (y/n)${NC}"
        read -p "> " fix_dns
        
        if [[ "${fix_dns,,}" == "y" ]]; then
            fix_all_dns_issues
        fi
    else
        echo -e "\n${GREEN}DNS-резолвинг работает через DNSCrypt корректно.${NC}"
        
        # Показываем информацию о протоколе DNS
        echo -e "${YELLOW}Показать подробную информацию о протоколах DNS? (y/n)${NC}"
        read -p "> " show_protocol
        
        if [[ "${show_protocol,,}" == "y" ]]; then
            get_dns_protocol_info
        fi
    fi
}

# Запуск главной функции
main