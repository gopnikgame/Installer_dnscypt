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
                
                log "SUCCESS" "${GREEN}Активированы ранее отключенные серверы: ${disabled_servers}${NC}"
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
                
                log "SUCCESS" "${GREEN}Активированы ранее закомментированные серверы: ${servers_list}${NC}"
            fi
        # Если нет ни активных, ни отключенных, ни закомментированных server_names
        elif [ -z "$server_lines" ] && [ -z "$disabled_lines" ] && [ -z "$commented_lines" ]; then
            # Добавляем настройки по умолчанию
            sed -i "/\[sources\]/i server_names = ['cloudflare']" "$DNSCRYPT_CONFIG"
            log "SUCCESS" "${GREEN}Добавлен сервер Cloudflare по умолчанию${NC}"
        fi
        
        # Перезапускаем службу DNSCrypt
        log "INFO" "Перезапуск DNSCrypt-proxy..."
        systemctl restart dnscrypt-proxy || {
            log "ERROR" "${RED}Не удалось перезапустить DNSCrypt-proxy${NC}"
            return 1
        }
        
        # Даем время на запуск службы
        sleep 2
    else
        log "ERROR" "${RED}Не найден файл конфигурации DNSCrypt${NC}"
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
        systemctl restart systemd-resolved || {
            log "WARN" "${YELLOW}Не удалось перезапустить systemd-resolved${NC}"
        }
    fi
    
    # 3. Настраиваем resolv.conf
    log "INFO" "Настройка resolv.conf..."
    
    # Снимаем защиту от записи, если она есть
    if ! chattr -i "$RESOLV_CONF" 2>/dev/null; then
        log "INFO" "Снят атрибут immutable с resolv.conf"
    fi
    
    # Сохраняем бэкап, если еще нет
    if [ ! -f "${RESOLV_CONF}.backup" ]; then
        cp "$RESOLV_CONF" "${RESOLV_CONF}.backup"
        log "INFO" "Создан бэкап resolv.conf"
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
        log "SUCCESS" "${GREEN}DNSCrypt работает корректно! Время ответа: ${serve_time}ms${NC}"
        
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
        log "ERROR" "${RED}DNSCrypt не работает корректно!${NC}"
        
        # Проверяем, запущена ли служба
        if ! systemctl is-active --quiet dnscrypt-proxy; then
            log "ERROR" "${RED}Служба DNSCrypt-proxy не запущена!${NC}"
            systemctl start dnscrypt-proxy
        fi
        
        # Проверяем порты
        echo -e "${YELLOW}Проверка прослушиваемых портов:${NC}"
        ss -tulpn | grep ':53' || echo "  ${RED}Не найдены процессы, слушающие порт 53${NC}"
        
        # Проверяем логи на ошибки
        echo -e "${YELLOW}Последние ошибки в логах DNSCrypt:${NC}"
        journalctl -u dnscrypt-proxy -n 20 --grep="error|failed|warning" --no-pager
        
        return 1
    fi
}

# Добавляем новый пункт в функцию main для вызова функции исправления
main() {
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
    if ! systemctl is-active --quiet dnscrypt-proxy; then
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
    fi
}

# Запуск главной функции
main