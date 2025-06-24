#!/bin/bash
# modules/manage_anonymized_dns.sh - Модуль управления анонимным DNS через DNSCrypt и ODoH
# Создано: 2025-06-24
# Автор: gopnikgame

# Подключение общей библиотеки
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Подключение библиотеки для анонимного DNS
source "$SCRIPT_DIR/lib/anonymized_dns.sh" 2>/dev/null || {
    log "ERROR" "Не удалось подключить библиотеку anonymized_dns.sh"
    exit 1
}

# Настройка маршрутов для Anonymized DNSCrypt
configure_anonymized_routes() {
    log "INFO" "Настройка маршрутов для Anonymized DNSCrypt..."
    
    echo -e "\n${BLUE}Настройка маршрутов анонимизации:${NC}"
    echo "Маршруты определяют, через какие релеи будут проходить запросы к определенным серверам."
    echo "Это предотвращает прямую связь между вашим IP и запрашиваемыми доменами."
    echo -e "${YELLOW}Важно:${NC} Выбирайте релеи и серверы, управляемые разными организациями!"
    echo
    echo "1) Использовать автоматическую маршрутизацию (через wildcard)"
    echo "2) Настроить маршруты вручную"
    echo "3) Просмотреть доступные серверы и релеи"
    echo "0) Отмена"
    
    read -p "Выберите опцию (0-3): " route_option
    
    case $route_option in
        1)
            # Автоматическая маршрутизация
            echo -e "\n${BLUE}Настройка автоматической маршрутизации:${NC}"
            echo "1) Автоматический выбор релеев для всех серверов"
            echo "2) Указать конкретные релеи для всех серверов"
            echo "0) Назад"
            
            read -p "Выберите опцию (0-2): " auto_option
            
            case $auto_option in
                1)
                    # Полностью автоматический режим
                    update_anonymized_routes "{ server_name='*', via=['*'] }"
                    log "SUCCESS" "Настроена автоматическая маршрутизация через случайные релеи"
                    ;;
                2)
                    # Выбрать релеи для всех серверов
                    echo -e "\n${BLUE}Доступные релеи:${NC}"
                    list_available_relays
                    
                    echo -e "\n${YELLOW}Введите имена релеев через запятую (например: anon-cs-fr,anon-bcn,anon-tiarap):${NC}"
                    read -p "Релеи: " relay_list
                    
                    if [ -z "$relay_list" ]; then
                        log "ERROR" "Список релеев не может быть пустым"
                        return 1
                    fi
                    
                    # Преобразуем список в формат для маршрута
                    local relays=$(echo "$relay_list" | tr ',' ' ' | sed "s/\([a-zA-Z0-9_-]*\)/'\1'/g" | tr ' ' ',')
                    update_anonymized_routes "{ server_name='*', via=[$relays] }"
                    
                    log "SUCCESS" "Настроена автоматическая маршрутизация через выбранные релеи"
                    ;;
                0)
                    return 0
                    ;;
                *)
                    log "ERROR" "Неверный выбор"
                    return 1
                    ;;
            esac
            ;;
        2)
            # Ручная настройка маршрутов
            configure_manual_routes
            ;;
        3)
            # Просмотр доступных серверов и релеев
            echo -e "\n${BLUE}Доступные DNSCrypt-серверы:${NC}"
            list_available_servers
            
            echo -e "\n${BLUE}Доступные релеи:${NC}"
            list_available_relays
            
            read -p "Нажмите Enter для продолжения..."
            configure_anonymized_routes
            ;;
        0)
            return 0
            ;;
        *)
            log "ERROR" "Неверный выбор"
            return 1
            ;;
    esac
}

# Ручная настройка маршрутов
configure_manual_routes() {
    echo -e "\n${BLUE}Ручная настройка маршрутов:${NC}"
    echo "1) Добавить новый маршрут"
    echo "2) Удалить существующий маршрут"
    echo "3) Заменить все маршруты"
    echo "0) Назад"
    
    read -p "Выберите опцию (0-3): " manual_option
    
    case $manual_option in
        1)
            add_anonymized_route
            ;;
        2)
            remove_anonymized_route
            ;;
        3)
            replace_anonymized_routes
            ;;
        0)
            return 0
            ;;
        *)
            log "ERROR" "Неверный выбор"
            return 1
            ;;
    esac
}

# Добавление нового маршрута
add_anonymized_route() {
    echo -e "\n${BLUE}Доступные DNSCrypt-серверы:${NC}"
    list_available_servers
    
    echo -e "\n${YELLOW}Введите имя DNSCrypt-сервера (или '*' для всех серверов):${NC}"
    read -p "Имя сервера: " server_name
    
    if [ -z "$server_name" ]; then
        log "ERROR" "Имя сервера не может быть пустым"
        return 1
    fi
    
    echo -e "\n${BLUE}Доступные релеи:${NC}"
    list_available_relays
    
    echo -e "\n${YELLOW}Введите имена релеев через запятую (например: anon-cs-fr,anon-bcn,anon-tiarap):${NC}"
    read -p "Релеи: " relay_list
    
    if [ -z "$relay_list" ]; then
        log "ERROR" "Список релеев не может быть пустым"
        return 1
    fi
    
    # Преобразуем список в формат для маршрута
    local relays=$(echo "$relay_list" | tr ',' ' ' | sed "s/\([a-zA-Z0-9_*-]*\)/'\1'/g" | tr ' ' ',')
    local new_route="{ server_name='$server_name', via=[$relays] }"
    
    # Добавляем новый маршрут
    add_route_to_config "$new_route"
    
    log "SUCCESS" "Маршрут успешно добавлен"
}

# Удаление существующего маршрута
remove_anonymized_route() {
    echo -e "\n${BLUE}Существующие маршруты:${NC}"
    
    # Извлекаем и нумеруем маршруты
    local routes=$(grep -A 20 "routes = \[" "$DNSCRYPT_CONFIG" | grep -v "routes = \[" | grep -v "\]" | grep "server_name" | sed 's/^[ \t]*//' | nl)
    
    if [ -z "$routes" ]; then
        log "ERROR" "Маршруты не найдены"
        return 1
    fi
    
    echo "$routes"
    
    echo -e "\n${YELLOW}Введите номер маршрута для удаления:${NC}"
    read -p "Номер маршрута: " route_number
    
    if ! [[ "$route_number" =~ ^[0-9]+$ ]]; then
        log "ERROR" "Неверный номер маршрута"
        return 1
    fi
    
    # Получаем маршрут по номеру
    local route_to_remove=$(echo "$routes" | grep "^ *$route_number" | sed 's/^ *[0-9]\+\t//')
    
    if [ -z "$route_to_remove" ]; then
        log "ERROR" "Маршрут с номером $route_number не найден"
        return 1
    fi
    
    # Удаляем маршрут из конфигурации
    sed -i "/$(echo "$route_to_remove" | sed 's/[\/&]/\\&/g')/d" "$DNSCRYPT_CONFIG"
    
    log "SUCCESS" "Маршрут успешно удален"
}

# Замена всех маршрутов
replace_anonymized_routes() {
    echo -e "\n${BLUE}Замена всех маршрутов:${NC}"
    echo -e "${YELLOW}Внимание: Эта операция заменит все существующие маршруты!${NC}"
    read -p "Продолжить? (y/n): " confirm
    
    if [[ "${confirm,,}" != "y" ]]; then
        log "INFO" "Операция отменена"
        return 0
    fi
    
    # Запрашиваем новые маршруты
    local routes="["
    local continue_adding="y"
    
    while [[ "${continue_adding,,}" == "y" ]]; do
        echo -e "\n${BLUE}Доступные DNSCrypt-серверы:${NC}"
        list_available_servers
        
        echo -e "\n${YELLOW}Введите имя DNSCrypt-сервера (или '*' для всех серверов):${NC}"
        read -p "Имя сервера: " server_name
        
        if [ -z "$server_name" ]; then
            log "ERROR" "Имя сервера не может быть пустым"
            continue
        fi
        
        echo -e "\n${BLUE}Доступные релеи:${NC}"
        list_available_relays
        
        echo -e "\n${YELLOW}Введите имена релеев через запятую (например: anon-cs-fr,anon-bcn,anon-tiarap):${NC}"
        read -p "Релеи: " relay_list
        
        if [ -z "$relay_list" ]; then
            log "ERROR" "Список релеев не может быть пустым"
            continue
        fi
        
        # Преобразуем список в формат для маршрута
        local relays=$(echo "$relay_list" | tr ',' ' ' | sed "s/\([a-zA-Z0-9_*-]*\)/'\1'/g" | tr ' ' ',')
        
        if [ "$routes" != "[" ]; then
            routes+=", "
        fi
        
        routes+="\n    { server_name='$server_name', via=[$relays] }"
        
        echo -e "\n${YELLOW}Добавить еще один маршрут? (y/n):${NC}"
        read -p "> " continue_adding
    done
    
    routes+="\n]"
    
    # Обновляем маршруты в конфигурации
    sed -i "/routes = \[/,/\]/c\\routes = $routes" "$DNSCRYPT_CONFIG"
    
    log "SUCCESS" "Все маршруты успешно заменены"
}

# Настройка маршрутов для ODoH
configure_odoh_routes() {
    log "INFO" "Настройка маршрутов для ODoH..."
    
    echo -e "\n${YELLOW}Важное замечание:${NC}"
    echo "Для корректной работы ODoH необходимо включить источники odoh-servers и odoh-relays,"
    echo "а также добавить маршруты для серверов ODoH через релеи ODoH."
    
    # Проверяем, включены ли источники ODoH
    if ! grep -q "\[sources.odoh-servers\]" "$DNSCRYPT_CONFIG" || ! grep -q "\[sources.odoh-relays\]" "$DNSCRYPT_CONFIG"; then
        log "WARN" "Источники ODoH не настроены. Настраиваем..."
        add_odoh_sources
    fi
    
    # Проверяем, включены ли ODoH серверы
    if ! grep -q "odoh_servers = true" "$DNSCRYPT_CONFIG"; then
        log "WARN" "Поддержка ODoH не включена. Включаем..."
        sed -i "s/odoh_servers = .*/odoh_servers = true/" "$DNSCRYPT_CONFIG" 2>/dev/null || \
        sed -i "/doh_servers = /a odoh_servers = true" "$DNSCRYPT_CONFIG" 2>/dev/null
    fi
    
    echo -e "\n${BLUE}Настройка маршрутов ODoH:${NC}"
    echo "1) Использовать автоматическую маршрутизацию (через wildcard)"
    echo "2) Добавить маршрут для конкретного ODoH-сервера"
    echo "3) Просмотреть доступные ODoH-серверы и релеи"
    echo "0) Отмена"
    
    read -p "Выберите опцию (0-3): " odoh_route_option
    
    case $odoh_route_option in
        1)
            # Автоматическая маршрутизация для ODoH
            echo -e "\n${YELLOW}Введите имена ODoH-релеев через запятую или '*' для автоматического выбора:${NC}"
            read -p "ODoH-релеи: " odoh_relays
            
            if [ -z "$odoh_relays" ]; then
                odoh_relays="*"
            fi
            
            if [ "$odoh_relays" = "*" ]; then
                # Автоматический выбор релеев
                add_anonymized_route_for_odoh "*" "*"
            else
                # Выбор указанных релеев для всех ODoH-серверов
                add_anonymized_route_for_odoh "*" "$odoh_relays"
            fi
            ;;
        2)
            # Маршрут для конкретного ODoH-сервера
            echo -e "\n${BLUE}Доступные ODoH-серверы:${NC}"
            list_available_odoh_servers
            
            echo -e "\n${YELLOW}Введите имя ODoH-сервера:${NC}"
            read -p "ODoH-сервер: " odoh_server
            
            if [ -z "$odoh_server" ]; then
                log "ERROR" "Имя сервера не может быть пустым"
                return 1
            fi
            
            echo -e "\n${BLUE}Доступные ODoH-релеи:${NC}"
            list_available_odoh_relays
            
            echo -e "\n${YELLOW}Введите имена ODoH-релеев через запятую:${NC}"
            read -p "ODoH-релеи: " odoh_relays
            
            if [ -z "$odoh_relays" ]; then
                log "ERROR" "Список релеев не может быть пустым"
                return 1
            fi
            
            add_anonymized_route_for_odoh "$odoh_server" "$odoh_relays"
            ;;
        3)
            # Просмотр доступных ODoH-серверов и релеев
            echo -e "\n${BLUE}Доступные ODoH-серверы:${NC}"
            list_available_odoh_servers
            
            echo -e "\n${BLUE}Доступные ODoH-релеи:${NC}"
            list_available_odoh_relays
            
            read -p "Нажмите Enter для продолжения..."
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
}

# Добавление маршрута для ODoH
add_anonymized_route_for_odoh() {
    local server_name="$1"
    local relays="$2"
    
    # Преобразуем список релеев в формат для маршрута
    local relays_formatted=$(echo "$relays" | tr ',' ' ' | sed "s/\([a-zA-Z0-9_*-]*\)/'\1'/g" | tr ' ' ',')
    local new_route="{ server_name='$server_name', via=[$relays_formatted] }"
    
    # Добавляем новый маршрут в секцию anonymized_dns
    add_route_to_config "$new_route"
    
    log "SUCCESS" "Маршрут для ODoH успешно добавлен"
    
    # Перезапуск службы для применения изменений
    restart_service "$DNSCRYPT_SERVICE"
}

# Настройка дополнительной конфигурации анонимного DNS
configure_additional_anon_settings() {
    echo -e "\n${BLUE}Дополнительные настройки анонимного DNS:${NC}"
    echo "1) Настройка пропуска несовместимых серверов"
    echo "2) Настройка логирования и отладки"
    echo "0) Отмена"
    
    read -p "Выберите опцию (0-2): " additional_option
    
    case $additional_option in
        1)
            # Настройка пропуска несовместимых серверов
            echo -e "\n${BLUE}Пропуск несовместимых серверов:${NC}"
            echo "Если включено, серверы несовместимые с анонимизацией будут пропускаться"
            echo "вместо использования прямого подключения к ним."
            
            read -p "Включить пропуск несовместимых серверов? (y/n): " skip_incompatible
            
            if [[ "${skip_incompatible,,}" == "y" ]]; then
                if grep -q "skip_incompatible" "$DNSCRYPT_CONFIG"; then
                    sed -i "s/skip_incompatible = .*/skip_incompatible = true/" "$DNSCRYPT_CONFIG"
                else
                    sed -i "/\[anonymized_dns\]/a skip_incompatible = true" "$DNSCRYPT_CONFIG"
                fi
                
                log "SUCCESS" "Пропуск несовместимых серверов включен"
            else
                if grep -q "skip_incompatible" "$DNSCRYPT_CONFIG"; then
                    sed -i "s/skip_incompatible = .*/skip_incompatible = false/" "$DNSCRYPT_CONFIG"
                else
                    sed -i "/\[anonymized_dns\]/a skip_incompatible = false" "$DNSCRYPT_CONFIG"
                fi
                
                log "SUCCESS" "Пропуск несовместимых серверов отключен"
            fi
            ;;
        2)
            # Настройка логирования и отладки
            echo -e "\n${BLUE}Настройка логирования и отладки:${NC}"
            echo "Увеличение уровня логирования помогает диагностировать проблемы с анонимизацией."
            
            echo "Текущий уровень логирования: $(grep "log_level = " "$DNSCRYPT_CONFIG" | sed 's/log_level = //' || echo "не настроен")"
            
            echo -e "\nУровни логирования:"
            echo "0: Только важные сообщения (по умолчанию)"
            echo "1: Добавить предупреждения"
            echo "2: Добавить информационные сообщения"
            echo "3: Добавить отладочные сообщения"
            echo "4: Добавить подробные отладочные сообщения"
            echo "5: Добавить очень подробные отладочные сообщения"
            
            read -p "Укажите уровень логирования (0-5): " log_level
            
            if [[ "$log_level" =~ ^[0-5]$ ]]; then
                add_config_option "$DNSCRYPT_CONFIG" "" "log_level" "$log_level"
                log "SUCCESS" "Уровень логирования изменен на $log_level"
            else
                log "ERROR" "Неверный уровень логирования"
            fi
            ;;
        0)
            return 0
            ;;
        *)
            log "ERROR" "Неверный выбор"
            return 1
            ;;
    esac
    
    # Перезапуск службы для применения изменений
    restart_service "$DNSCRYPT_SERVICE"
    
    return 0
}

# Основное меню управления анонимным DNS
main_menu() {
    while true; do
        print_header "УПРАВЛЕНИЕ АНОНИМНЫМ DNS"
        echo "1) Проверить текущую конфигурацию анонимного DNS"
        echo "2) Настроить Anonymized DNSCrypt"
        echo "3) Настроить Oblivious DoH (ODoH)"
        echo "4) Настроить маршруты для анонимизации"
        echo "5) Тестировать время отклика серверов"
        echo "6) Дополнительные настройки анонимизации"
        echo "7) Перезапустить DNSCrypt-proxy"
        echo "0) Выход"
        
        read -p "Выберите опцию (0-7): " option
        
        case $option in
            1)
                check_anonymized_dns
                ;;
            2)
                backup_config "$DNSCRYPT_CONFIG" "dnscrypt-config"
                configure_anonymized_dns
                ;;
            3)
                backup_config "$DNSCRYPT_CONFIG" "dnscrypt-config"
                configure_odoh
                ;;
            4)
                backup_config "$DNSCRYPT_CONFIG" "dnscrypt-config"
                configure_anonymized_routes
                ;;
            5)
                test_server_latency
                ;;
            6)
                backup_config "$DNSCRYPT_CONFIG" "dnscrypt-config"
                configure_additional_anon_settings
                ;;
            7)
                restart_service "$DNSCRYPT_SERVICE"
                ;;
            0)
                log "INFO" "Выход из модуля управления анонимным DNS"
                exit 0
                ;;
            *)
                log "ERROR" "Неверный выбор"
                ;;
        esac
        
        echo
        read -p "Нажмите Enter для продолжения..."
    done
}

# Проверка root-прав
check_root

# Проверка наличия DNSCrypt-proxy
check_dependencies "dnscrypt-proxy" "dig" "sed"

# Запуск основного меню
log "INFO" "Запуск модуля управления анонимным DNS..."
main_menu