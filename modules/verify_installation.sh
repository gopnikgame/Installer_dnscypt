#!/bin/bash

# Подгрузка общих функций
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Константы
DNSCRYPT_BINARY="/usr/local/bin/dnscrypt-proxy"
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
SERVICE_NAME="dnscrypt-proxy.service"

# Основная функция проверки
verify_installation() {
    log "INFO" "Начало проверки установки DNSCrypt..."
    local errors=0

    # Проверка бинарного файла
    if [ -f "$DNSCRYPT_BINARY" ]; then
        log "SUCCESS" "DNSCrypt бинарный файл найден"
        if [ -x "$DNSCRYPT_BINARY" ]; then
            log "SUCCESS" "DNSCrypt бинарный файл имеет права на выполнение"
            # Показать версию DNSCrypt
            local version
            version=$("$DNSCRYPT_BINARY" --version 2>&1)
            log "INFO" "Версия DNSCrypt: $version"
        else
            log "ERROR" "DNSCrypt бинарный файл не имеет прав на выполнение"
            ((errors++))
        fi
    else
        log "ERROR" "DNSCrypt бинарный файл не найден"
        log "INFO" "Для установки DNSCrypt используйте пункт 1 главного меню"
        ((errors++))
    fi

    # Проверка конфигурационного файла
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        log "SUCCESS" "Конфигурационный файл найден"
    else
        log "ERROR" "Конфигурационный файл не найден"
        ((errors++))
    fi

    # Проверка службы
    if check_service_status "$SERVICE_NAME"; then
        # Функция уже выводит сообщение об успехе
        :
    else
        log "INFO" "Для управления службой используйте пункт 6 главного меню"
        ((errors++))
    fi

    # Проверка порта 53
    if lsof -i :53 | grep -q "dnscrypt"; then
        log "SUCCESS" "DNSCrypt слушает порт 53"
    else
        log "ERROR" "DNSCrypt не слушает порт 53"
        ((errors++))
    fi

    # Проверка DNS резолвинга
    if dig @127.0.0.1 google.com +short +timeout=5 >/dev/null 2>&1; then
        log "SUCCESS" "DNS резолвинг работает"
        
        print_header "Информация о DNS резолвинге"
        echo "Текущий DNS сервер:"
        dig +short resolver.dnscrypt.info TXT | sed 's/"//g'
        
        echo -e "\nВремя отклика для популярных доменов:"
        for domain in google.com cloudflare.com github.com; do
            local resolve_time=$(dig @127.0.0.1 "$domain" +noall +stats 2>/dev/null | grep "Query time" | awk '{print $4}')
            echo "$domain: ${resolve_time}ms"
        done
    else
        log "ERROR" "DNS резолвинг не работает"
        ((errors++))
    fi

    # Итоговый результат
    if [ $errors -eq 0 ]; then
        log "SUCCESS" "Проверка завершена успешно. Ошибок не найдено"
        return 0
    else
        log "ERROR" "Проверка завершена. Найдено ошибок: $errors"
        echo -e "\n${YELLOW}Для устранения ошибок:${NC}"
        echo "1. Установка DNSCrypt - пункт 1 главного меню"
        echo "2. Управление службой - пункт 6 главного меню"
        echo "3. Изменение настроек DNS - пункт 3 главного меню"
        return 1
    fi
}

# Запуск проверки
verify_installation