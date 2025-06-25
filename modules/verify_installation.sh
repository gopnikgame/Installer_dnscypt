#!/bin/bash

# Подгрузка общих функций
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Подключение библиотеки диагностики
source "${SCRIPT_DIR}/lib/diagnostic.sh" 2>/dev/null || {
    log "ERROR" "Не удалось подключить библиотеку diagnostic.sh"
    log "INFO" "Продолжаем с ограниченным функционалом"
}

# Основная функция проверки
verify_installation() {
    print_header "ПРОВЕРКА УСТАНОВКИ DNSCRYPT"
    log "INFO" "Начало проверки установки DNSCrypt..."
    local errors=0

    # Проверка наличия DNSCrypt-proxy
    if check_dnscrypt_installed; then
        # Показать версию DNSCrypt
        local version
        version=$(dnscrypt-proxy --version 2>&1)
        log "INFO" "Версия DNSCrypt: $version"
    else
        log "INFO" "Для установки DNSCrypt используйте пункт 1 главного меню"
        ((errors++))
    fi

    # Проверка конфигурационного файла
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        log "SUCCESS" "Конфигурационный файл найден"
        
        # Проверка конфигурации
        echo -e "\n${BLUE}Проверка конфигурационного файла:${NC}"
        if cd "$(dirname "$DNSCRYPT_CONFIG")" && dnscrypt-proxy -check; then
            log "SUCCESS" "Конфигурация валидна"
        else
            log "ERROR" "Обнаружены ошибки в конфигурации"
            ((errors++))
        fi
    else
        log "ERROR" "Конфигурационный файл не найден"
        ((errors++))
    fi

    # Проверка службы и её состояния
    echo -e "\n${BLUE}Проверка состояния службы:${NC}"
    check_dnscrypt_status
    
    # Проверка использования порта 53
    echo -e "\n${BLUE}Проверка прослушивания порта 53:${NC}"
    check_port_usage 53
    if ! lsof -i :53 | grep -q "dnscrypt"; then
        log "ERROR" "DNSCrypt не слушает порт 53"
        ((errors++))
    fi

    # Проверка системного резолвера
    echo -e "\n${BLUE}Проверка системного резолвера:${NC}"
    check_system_resolver

    # Тестирование DNS резолвинга
    echo -e "\n${BLUE}Проверка DNS резолвинга:${NC}"
    if verify_settings ""; then
        log "SUCCESS" "DNS резолвинг работает корректно"
    else
        log "ERROR" "Проблемы с DNS резолвингом"
        ((errors++))
    fi

    # Дополнительное тестирование скорости DNS, если всё работает нормально
    if [ $errors -eq 0 ]; then
        echo -e "\n${BLUE}Тестирование скорости DNS:${NC}"
        test_dns_speed
    fi

    # Итоговый результат
    if [ $errors -eq 0 ]; then
        print_header "РЕЗУЛЬТАТЫ ПРОВЕРКИ"
        log "SUCCESS" "Проверка завершена успешно. Ошибок не найдено"
        return 0
    else
        print_header "РЕЗУЛЬТАТЫ ПРОВЕРКИ"
        log "ERROR" "Проверка завершена. Найдено ошибок: $errors"
        echo -e "\n${YELLOW}Для устранения ошибок:${NC}"
        echo "1. Установка DNSCrypt - пункт 1 главного меню"
        echo "2. Управление службой - пункт 6 главного меню"
        echo "3. Исправление DNS резолвинга - пункт 5 главного меню"
        echo "4. Изменение настроек DNS - пункт 3 главного меню"
        return 1
    fi
}

# Проверка root-прав
check_root

# Проверка зависимостей
check_dependencies "dig" "lsof" "column"

# Запуск проверки
verify_installation