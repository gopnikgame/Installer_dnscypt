#!/bin/bash
# lib/diagnostic.sh - Библиотека для диагностики системы и DNSCrypt
# Создано: 2025-06-24
# Автор: gopnikgame

# Проверка наличия DNSCrypt-proxy
check_dnscrypt_installed() {
    # Проверяем основной путь установки
    if [ -x "/opt/dnscrypt-proxy/dnscrypt-proxy" ]; then
        log "SUCCESS" "DNSCrypt-proxy установлен в /opt/dnscrypt-proxy"
        return 0
    fi
    
    # Проверяем альтернативные пути
    if [ -x "/usr/local/bin/dnscrypt-proxy" ]; then
        log "SUCCESS" "DNSCrypt-proxy установлен в /usr/local/bin"
        return 0
    fi
    
    if [ -x "/usr/bin/dnscrypt-proxy" ]; then
        log "SUCCESS" "DNSCrypt-proxy установлен в /usr/bin"
        return 0
    fi
    
    # Проверяем в PATH
    if command -v dnscrypt-proxy &>/dev/null; then
        log "SUCCESS" "DNSCrypt-proxy найден в PATH: $(which dnscrypt-proxy)"
        return 0
    fi
    
    log "ERROR" "DNSCrypt-proxy не установлен или не найден"
    return 1
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
    if systemctl is-active --quiet "$DNSCRYPT_SERVICE"; then
        echo -e "${GREEN}Служба активна${NC}"
        systemctl status "$DNSCRYPT_SERVICE" --no-pager --lines=5
    else
        echo -e "${RED}Служба неактивна${NC}"
        echo -e "${YELLOW}Попытка запуска службы...${NC}"
        if systemctl start "$DNSCRYPT_SERVICE"; then
            echo -e "${GREEN}Служба успешно запущена${NC}"
        else
            echo -e "${RED}Не удалось запустить службу${NC}"
            echo -e "\n${BLUE}Статус службы:${NC}"
            systemctl status "$DNSCRYPT_SERVICE" --no-pager --lines=10
        fi
    fi
    
    echo -e "\n${BLUE}Проверка занятости порта DNS (53):${NC}"
    check_port_usage 53
    
    echo -e "\n${BLUE}Проверка resolv.conf:${NC}"
    cat "$RESOLV_CONF" | grep -v "^#"
    
    echo -e "\n${BLUE}Проверка настройки слушателя в DNSCrypt:${NC}"
    grep "listen_addresses" "$DNSCRYPT_CONFIG" | sed 's/listen_addresses = //'
    
    echo -e "\n${BLUE}Последние записи журнала службы:${NC}"
    journalctl -u "$DNSCRYPT_SERVICE" -n 20 --no-pager
    
    echo -e "\n${BLUE}Тестирование DNS-запросов:${NC}"
    # Проверяем, работает ли служба перед тестированием
    if systemctl is-active --quiet "$DNSCRYPT_SERVICE"; then
        echo "Тестирование резолвинга через DNSCrypt..."
        if timeout 10 dig @127.0.0.1 example.com +short > /dev/null 2>&1; then
            echo -e "${GREEN}DNS резолвинг работает${NC}"
            dig @127.0.0.1 example.com | grep -E "^;; (Query time|SERVER)|^example.com"
        else
            echo -e "${RED}DNS резолвинг не работает${NC}"
            echo "Тестирование альтернативного DNS..."
            dig @8.8.8.8 example.com | grep -E "^;; (Query time|SERVER)|^example.com"
        fi
    else
        echo -e "${RED}Служба DNSCrypt не запущена, тестирование невозможно${NC}"
    fi
    
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
                local time=$(timeout 5 dig @"$dns" "$domain" +noall +stats 2>/dev/null | grep "Query time:" | awk '{print $4}')
                
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
    
    echo -e "\nТекущий системный резолвер:"
    cat "$RESOLV_CONF"
    
    # Проверка статуса systemd-resolved
    if systemctl is-active --quiet systemd-resolved; then
        echo -e "\nsystemd-resolved активен"
        
        # Проверка наличия команды systemd-resolve
        if command -v systemd-resolve &>/dev/null; then
            systemd-resolve --status
        elif command -v resolvectl &>/dev/null; then
            # В некоторых системах команда называется resolvectl
            resolvectl status
        else
            echo -e "${YELLOW}Команда systemd-resolve не найдена, но служба systemd-resolved активна${NC}"
            echo -e "Статус DNS можно проверить с помощью: ${GREEN}sudo systemctl status systemd-resolved${NC}"
        fi
    else
        echo -e "\nsystemd-resolved ${RED}неактивен${NC}"
    fi
    
    echo -e "\nПроверка работающего DNS-сервера:"
    dig +short resolver.dnscrypt.info TXT
}

# Проверка состояния DNSCrypt
check_dnscrypt_status() {
    log "INFO" "Проверка статуса DNSCrypt..."
    
    # Сначала проверяем установку
    if ! check_dnscrypt_installed; then
        return 1
    fi
    
    echo -e "\n${BLUE}Статус службы:${NC}"
    if systemctl is-active --quiet "$DNSCRYPT_SERVICE"; then
        echo -e "${GREEN}Активна${NC}"
    else
        echo -e "${RED}Неактивна${NC}"
        # Попытка запуска
        echo -e "${YELLOW}Попытка запуска службы...${NC}"
        if systemctl start "$DNSCRYPT_SERVICE" 2>/dev/null; then
            sleep 2
            if systemctl is-active --quiet "$DNSCRYPT_SERVICE"; then
                echo -e "${GREEN}Служба успешно запущена${NC}"
            else
                echo -e "${RED}Служба не запустилась${NC}"
            fi
        else
            echo -e "${RED}Не удалось запустить службу${NC}"
        fi
    fi
    
    echo -e "\n${BLUE}Автозапуск службы:${NC}"
    systemctl is-enabled --quiet "$DNSCRYPT_SERVICE" && echo -e "${GREEN}Включен${NC}" || echo -e "${RED}Отключен${NC}"
    
    echo -e "\n${BLUE}Занятые порты:${NC}"
    if lsof -i :53 2>/dev/null | grep LISTEN; then
        echo "Порт 53 занят"
    else
        echo "Порт 53 свободен"
    fi
    
    echo -e "\n${BLUE}Проверка файла конфигурации:${NC}"
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        # Определяем путь к исполняемому файлу
        local dnscrypt_bin="/opt/dnscrypt-proxy/dnscrypt-proxy"
        if [ ! -x "$dnscrypt_bin" ]; then
            dnscrypt_bin=$(which dnscrypt-proxy 2>/dev/null)
        fi
        
        if [ -x "$dnscrypt_bin" ]; then
            check_output=$("$dnscrypt_bin" -config "$DNSCRYPT_CONFIG" -check 2>&1)
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}Конфигурационный файл корректен${NC}"
            else
                echo -e "${RED}Ошибки в конфигурационном файле${NC}"
                echo "$check_output" | grep -i error
            fi
        else
            echo -e "${RED}Исполняемый файл DNSCrypt не найден${NC}"
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
    if systemctl is-active --quiet "$DNSCRYPT_SERVICE"; then
        timeout 10 dig @127.0.0.1 +dnssec dnssec-tools.org | grep -E "flags:|RRSIG"
    else
        echo -e "${RED}Служба DNSCrypt не запущена${NC}"
    fi
    
    echo -e "\n${BLUE}Тест утечки DNS:${NC}"
    echo "Проверьте, какие DNS запросы видны вашему провайдеру, с помощью сайта:"
    echo -e "${YELLOW}https://www.dnsleaktest.com/${NC}"
    
    echo -e "\n${BLUE}Настройки приватности в DNSCrypt:${NC}"
    if [ -f "$DNSCRYPT_CONFIG" ]; then
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
    else
        echo -e "${RED}Конфигурационный файл не найден${NC}"
    fi
    
    return 0
}