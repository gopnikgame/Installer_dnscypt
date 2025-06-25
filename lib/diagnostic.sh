#!/bin/bash
# lib/diagnostic.sh - Библиотека для диагностики системы и DNSCrypt
# Создано: 2025-06-24
# Автор: gopnikgame

# Проверка наличия DNSCrypt-proxy
check_dnscrypt_installed() {
    if ! command -v dnscrypt-proxy &>/dev/null; then
        log "ERROR" "DNSCrypt-proxy не установлен"
        return 1
    fi
    
    log "SUCCESS" "DNSCrypt-proxy установлен"
    return 0
}

# Диагностика DNS проблем
diagnose_dns_issues() {
    print_header "ДИАГНОСТИКА DNS-ПРОБЛЕМ"
    log "INFO" "Проверка DNS-конфигурации..."
    
    # Проверка наличия DNSCrypt
    if ! check_dnscrypt_installed; then
        echo -e "${YELLOW}Сначала нужно установить DNSCrypt-proxy.${NC}"
        echo -e "Используйте пункт меню 'Установить DNSCrypt'"
        return 1
    fi
    
    # Проверка конфигурационного файла
    if [ ! -f "$DNSCRYPT_CONFIG" ]; then
        log "ERROR" "Файл конфигурации DNSCrypt не найден: $DNSCRYPT_CONFIG"
        echo -e "${YELLOW}Возможно, DNSCrypt установлен с нестандартным путем конфигурации.${NC}"
        return 1
    fi
    
    echo -e "\n${BLUE}Проверка состояния службы DNSCrypt-proxy:${NC}"
    systemctl status "$DNSCRYPT_SERVICE" --no-pager
    
    echo -e "\n${BLUE}Проверка занятости порта DNS (53):${NC}"
    check_port_usage 53
    
    echo -e "\n${BLUE}Проверка resolv.conf:${NC}"
    cat "$RESOLV_CONF" | grep -v "^#"
    
    echo -e "\n${BLUE}Проверка настройки слушателя в DNSCrypt:${NC}"
    grep "listen_addresses" "$DNSCRYPT_CONFIG" | sed 's/listen_addresses = //'
    
    echo -e "\n${BLUE}Последние записи журнала службы:${NC}"
    journalctl -u "$DNSCRYPT_SERVICE" -n 10 --no-pager
    
    echo -e "\n${BLUE}Тестирование DNS-запросов:${NC}"
    dig @127.0.0.1 example.com | grep -E "^;; (Query time|SERVER)|^example.com"
    
    return 0
}

# Тестирование скорости DNS-серверов
test_dns_speed() {
    log "INFO" "Тестирование скорости DNS серверов..."
    local domains=("google.com" "cloudflare.com" "example.com" "microsoft.com" "github.com")
    local dns_servers=("127.0.0.1" "8.8.8.8" "1.1.1.1" "9.9.9.9")
    local results_file=$(mktemp)
    
    echo "| DNS Сервер | Среднее время (мс) | Мин. время (мс) | Макс. время (мс) |" > "$results_file"
    echo "|------------|-------------------|----------------|-----------------|" >> "$results_file"
    
    for dns in "${dns_servers[@]}"; do
        local total_time=0
        local count=0
        local min_time=9999
        local max_time=0
        
        echo -n "Тестирование $dns... "
        
        for domain in "${domains[@]}"; do
            for i in {1..3}; do
                local time=$(dig @"$dns" "$domain" +noall +stats | grep "Query time:" | awk '{print $4}')
                
                if [[ -n "$time" && "$time" -lt 3000 ]]; then
                    total_time=$((total_time + time))
                    count=$((count + 1))
                    
                    # Обновляем минимум и максимум
                    if [[ "$time" -lt "$min_time" ]]; then min_time=$time; fi
                    if [[ "$time" -gt "$max_time" ]]; then max_time=$time; fi
                fi
            done
        done
        
        if [[ "$count" -gt 0 ]]; then
            local avg_time=$((total_time / count))
            echo -e "${GREEN}$avg_time мс${NC}"
            echo "| $dns | $avg_time | $min_time | $max_time |" >> "$results_file"
        else
            echo -e "${RED}Ошибка${NC}"
            echo "| $dns | Ошибка | - | - |" >> "$results_file"
        fi
    done
    
    echo -e "\n${BLUE}Результаты тестирования:${NC}"
    column -t -s '|' "$results_file"
    
    rm -f "$results_file"
    return 0
}

# Проверка системного резолвера
check_system_resolver() {
    log "INFO" "Проверка системного резолвера..."
    
    echo -e "\n${BLUE}Текущий системный резолвер:${NC}"
    cat /etc/resolv.conf | grep -v "^#"
    
    # Проверка systemd-resolved
    if systemctl is-active --quiet systemd-resolved; then
        echo -e "\n${YELLOW}systemd-resolved активен${NC}"
        systemd-resolve --status
    fi
    
    # Проверка, куда указывает резолвер
    echo -e "\n${BLUE}Проверка работающего DNS-сервера:${NC}"
    dig +short resolver.dnscrypt.info TXT
    
    return 0
}

# Проверка состояния DNSCrypt
check_dnscrypt_status() {
    log "INFO" "Проверка статуса DNSCrypt..."
    
    echo -e "\n${BLUE}Статус службы:${NC}"
    systemctl is-active --quiet dnscrypt-proxy && echo -e "${GREEN}Активна${NC}" || echo -e "${RED}Неактивна${NC}"
    
    echo -e "\n${BLUE}Автозапуск службы:${NC}"
    systemctl is-enabled --quiet dnscrypt-proxy && echo -e "${GREEN}Включен${NC}" || echo -e "${RED}Отключен${NC}"
    
    echo -e "\n${BLUE}Занятые порты:${NC}"
    lsof -i :53 | grep LISTEN || echo "Порт 53 свободен"
    
    echo -e "\n${BLUE}Проверка файла конфигурации:${NC}"
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        check_output=$(dnscrypt-proxy -config "$DNSCRYPT_CONFIG" -check 2>&1)
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Конфигурационный файл корректен${NC}"
        else
            echo -e "${RED}Ошибки в конфигурационном файле${NC}"
            echo "$check_output" | grep -i error
        fi
    else
        echo -e "${RED}Конфигурационный файл не найден${NC}"
    fi
    
    return 0
}

# Получение параметров системы и окружения
get_system_info() {
    print_header "ИНФОРМАЦИЯ О СИСТЕМЕ"
    
    echo -e "${BLUE}Операционная система:${NC}"
    cat /etc/os-release | grep "PRETTY_NAME" | cut -d= -f2 | tr -d '"'
    
    echo -e "\n${BLUE}Версия ядра:${NC}"
    uname -r
    
    echo -e "\n${BLUE}Архитектура:${NC}"
    uname -m
    
    echo -e "\n${BLUE}DNS настройки:${NC}"
    echo "Сервер в resolv.conf: $(grep "nameserver" /etc/resolv.conf | head -1 | awk '{print $2}')"
    
    echo -e "\n${BLUE}Сетевые интерфейсы:${NC}"
    ip -br address
    
    echo -e "\n${BLUE}Сетевые порты:${NC}"
    ss -tuln | grep -E ":53 |:443 |:853 |:8053 "
    
    echo -e "\n${BLUE}Оценка сетевого соединения:${NC}"
    ping -c 1 -W 2 google.com >/dev/null 2>&1 && echo -e "${GREEN}Интернет доступен${NC}" || echo -e "${RED}Проблемы с интернет-соединением${NC}"
    
    return 0
}

# Проверка безопасности DNS
check_dns_security() {
    log "INFO" "Проверка безопасности DNS..."
    
    echo -e "\n${BLUE}Проверка поддержки DNSSEC:${NC}"
    dig @127.0.0.1 +dnssec dnssec-tools.org | grep -E "flags:|RRSIG"
    
    echo -e "\n${BLUE}Тест утечки DNS:${NC}"
    echo "Проверьте, какие DNS запросы видны вашему провайдеру, с помощью сайта:"
    echo -e "${YELLOW}https://www.dnsleaktest.com/${NC}"
    
    echo -e "\n${BLUE}Настройки приватности в DNSCrypt:${NC}"
    if grep -q "require_nolog = true" "$DNSCRYPT_CONFIG"; then
        echo -e "Требование NoLog: ${GREEN}Включено${NC}"
    else
        echo -e "Требование NoLog: ${RED}Отключено${NC}"
    fi
    
    if grep -q "require_nofilter = true" "$DNSCRYPT_CONFIG"; then
        echo -e "Требование NoFilter: ${GREEN}Включено${NC}"
    else
        echo -e "Требование NoFilter: ${RED}Отключено${NC}"
    fi
    
    return 0
}