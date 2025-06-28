#!/bin/bash

# Подгрузка общих функций
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Подключение библиотеки диагностики
source "${SCRIPT_DIR}/lib/diagnostic.sh" 2>/dev/null || {
    log "ERROR" "Не удалось подключить библиотеку diagnostic.sh"
    log "INFO" "Продолжаем с ограниченным функционалом"
}

# Функция для определения пути к исполняемому файлу DNSCrypt
get_dnscrypt_binary() {
    # Проверяем основной путь установки
    if [ -x "/opt/dnscrypt-proxy/dnscrypt-proxy" ]; then
        echo "/opt/dnscrypt-proxy/dnscrypt-proxy"
        return 0
    fi
    
    # Проверяем альтернативные пути
    if [ -x "/usr/local/bin/dnscrypt-proxy" ]; then
        echo "/usr/local/bin/dnscrypt-proxy"
        return 0
    fi
    
    if [ -x "/usr/bin/dnscrypt-proxy" ]; then
        echo "/usr/bin/dnscrypt-proxy"
        return 0
    fi
    
    # Проверяем в PATH
    if command -v dnscrypt-proxy &>/dev/null; then
        echo "$(which dnscrypt-proxy)"
        return 0
    fi
    
    return 1
}

# Основная функция проверки
verify_installation() {
    print_header "ПРОВЕРКА УСТАНОВКИ DNSCRYPT"
    log "INFO" "Начало проверки установки DNSCrypt..."
    local errors=0

    # Проверка наличия DNSCrypt-proxy
    if check_dnscrypt_installed; then
        # Определяем путь к исполняемому файлу
        local dnscrypt_bin=$(get_dnscrypt_binary)
        if [ $? -eq 0 ] && [ -n "$dnscrypt_bin" ]; then
            # Показать версию DNSCrypt
            local version=$("$dnscrypt_bin" -version 2>/dev/null | head -1)
            if [ -n "$version" ]; then
                log "INFO" "Версия DNSCrypt: $version"
            else
                log "WARN" "Не удалось получить версию DNSCrypt"
            fi
        else
            log "ERROR" "Не удалось найти исполняемый файл DNSCrypt"
            ((errors++))
        fi
    else
        log "INFO" "Для установки DNSCrypt используйте пункт 1 главного меню"
        ((errors++))
    fi

    # Проверка конфигурационного файла
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        log "SUCCESS" "Конфигурационный файл найден"
        
        # Проверка конфигурации
        echo -e "\n${BLUE}Проверка конфигурационного файла:${NC}"
        
        # Определяем путь к исполняемому файлу для проверки конфигурации
        local dnscrypt_bin=$(get_dnscrypt_binary)
        if [ $? -eq 0 ] && [ -n "$dnscrypt_bin" ]; then
            # Переходим в директорию конфигурации для правильной работы проверки
            if cd "$(dirname "$DNSCRYPT_CONFIG")" && "$dnscrypt_bin" -check -config="$DNSCRYPT_CONFIG" 2>/dev/null; then
                log "SUCCESS" "Конфигурация валидна"
            else
                log "ERROR" "Обнаружены ошибки в конфигурации"
                echo -e "${YELLOW}Попытка диагностики проблем с конфигурацией:${NC}"
                "$dnscrypt_bin" -check -config="$DNSCRYPT_CONFIG" 2>&1 | head -10
                ((errors++))
            fi
        else
            log "ERROR" "Не удалось найти исполняемый файл для проверки конфигурации"
            ((errors++))
        fi
    else
        log "ERROR" "Конфигурационный файл не найден: $DNSCRYPT_CONFIG"
        ((errors++))
    fi

    # Проверка службы и её состояния
    echo -e "\n${BLUE}Проверка состояния службы:${NC}"
    check_dnscrypt_status
    
    # Проверка использования порта 53
    echo -e "\n${BLUE}Проверка прослушивания порта 53:${NC}"
    check_port_usage 53
    
    # Дополнительная проверка портов DNSCrypt
    if command -v lsof &>/dev/null; then
        local dnscrypt_ports=$(lsof -i -P -n | grep dnscrypt-proxy 2>/dev/null)
        if [ -n "$dnscrypt_ports" ]; then
            echo -e "${GREEN}DNSCrypt прослушивает следующие порты:${NC}"
            echo "$dnscrypt_ports" | while read line; do
                echo "  $line"
            done
        else
            log "ERROR" "DNSCrypt не прослушивает ни одного порта"
            ((errors++))
        fi
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

    # Дополнительные проверки
    echo -e "\n${BLUE}Дополнительные проверки:${NC}"
    
    # Проверка прав доступа к файлам
    echo -n "Права доступа к конфигурации: "
    if [ -r "$DNSCRYPT_CONFIG" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}Нет доступа для чтения${NC}"
        ((errors++))
    fi
    
    # Проверка службы автозапуска
    echo -n "Автозапуск службы: "
    if systemctl is-enabled --quiet dnscrypt-proxy; then
        echo -e "${GREEN}Включен${NC}"
    else
        echo -e "${YELLOW}Отключен${NC}"
        log "WARN" "Автозапуск службы отключен"
    fi
    
    # Проверка наличия кэш-файлов
    echo -n "Кэш-файлы серверов: "
    if [ -f "/etc/dnscrypt-proxy/public-resolvers.md" ]; then
        echo -e "${GREEN}Найдены${NC}"
    else
        echo -e "${YELLOW}Отсутствуют${NC}"
        log "WARN" "Кэш-файлы серверов не найдены, будут загружены при запуске"
    fi

    # Дополнительное тестирование скорости DNS, если всё работает нормально
    if [ $errors -le 1 ]; then
        echo -e "\n${BLUE}Тестирование скорости DNS:${NC}"
        test_dns_speed
    fi

    # Итоговый результат
    if [ $errors -eq 0 ]; then
        print_header "РЕЗУЛЬТАТЫ ПРОВЕРКИ"
        log "SUCCESS" "Проверка завершена успешно. Ошибок не найдено"
        echo -e "\n${GREEN}✓ DNSCrypt-proxy корректно установлен и настроен${NC}"
        echo -e "${GREEN}✓ Служба работает и прослушивает порты${NC}"
        echo -e "${GREEN}✓ DNS резолвинг функционирует${NC}"
        echo -e "${GREEN}✓ Конфигурация валидна${NC}"
        return 0
    elif [ $errors -eq 1 ]; then
        print_header "РЕЗУЛЬТАТЫ ПРОВЕРКИ"
        log "WARN" "Проверка завершена с минорными предупреждениями: $errors"
        echo -e "\n${YELLOW}⚠ Обнаружены незначительные проблемы${NC}"
        echo -e "${YELLOW}  DNSCrypt в основном работает корректно${NC}"
        return 0
    else
        print_header "РЕЗУЛЬТАТЫ ПРОВЕРКИ"
        log "ERROR" "Проверка завершена. Найдено критических ошибок: $errors"
        echo -e "\n${RED}✗ Обнаружены серьезные проблемы с установкой${NC}"
        echo -e "\n${YELLOW}Рекомендации по устранению проблем:${NC}"
        echo "1. ${CYAN}Переустановка DNSCrypt${NC} - пункт 1 главного меню"
        echo "2. ${CYAN}Управление службой${NC} - пункт 6 главного меню"
        echo "3. ${CYAN}Исправление DNS резолвинга${NC} - пункт 5 главного меню"
        echo "4. ${CYAN}Изменение настроек DNS${NC} - пункт 3 главного меню"
        echo "5. ${CYAN}Восстановление из резервной копии${NC} - пункт 9 главного меню"
        
        echo -e "\n${YELLOW}Для подробной диагностики выполните:${NC}"
        echo "sudo journalctl -u dnscrypt-proxy -n 50"
        
        return 1
    fi
}

# Проверка root-прав
check_root

# Проверка зависимостей
check_dependencies "dig" "lsof" "column"

# Запуск проверки
verify_installation