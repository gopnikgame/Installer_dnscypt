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

# Подключение библиотеки диагностики
source "$SCRIPT_DIR/lib/diagnostic.sh" 2>/dev/null || {
    log "INFO" "Библиотека diagnostic.sh не загружена, некоторые функции могут быть недоступны"
}

# Проверка root-прав
check_root

# Проверка наличия DNSCrypt-proxy с улучшенной диагностикой
if ! check_dnscrypt_installed; then
    log "ERROR" "DNSCrypt-proxy не установлен или не найден!"
    safe_echo "\n${YELLOW}Для установки DNSCrypt-proxy используйте главное меню (пункт 1).${NC}"
    safe_echo "${BLUE}Поддерживаемые расположения:${NC}"
    echo "  - /opt/dnscrypt-proxy/dnscrypt-proxy"
    echo "  - /usr/local/bin/dnscrypt-proxy"
    echo "  - /usr/bin/dnscrypt-proxy"
    echo
    read -p "Нажмите Enter для выхода..."
    exit 1
fi

# Проверка конфигурационного файла
if [ ! -f "$DNSCRYPT_CONFIG" ]; then
    log "ERROR" "Файл конфигурации DNSCrypt не найден: $DNSCRYPT_CONFIG"
    safe_echo "\n${YELLOW}Возможные причины:${NC}"
    echo "  - DNSCrypt установлен, но не настроен"
    echo "  - Конфигурационный файл перемещен"
    echo "  - Установка повреждена"
    echo
    safe_echo "${BLUE}Рекомендуемые действия:${NC}"
    echo "  1. Запустите модуль проверки установки (пункт 2 главного меню)"
    echo "  2. При необходимости переустановите DNSCrypt (пункт 1 главного меню)"
    echo
    read -p "Нажмите Enter для выхода..."
    exit 1
fi

# Проверка дополнительных зависимостей (не критично для работы модуля)
missing_tools=()
for tool in "dig" "sed"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing_tools+=("$tool")
    fi
done

if [[ ${#missing_tools[@]} -gt 0 ]]; then
    log "WARN" "Отсутствующие инструменты: ${missing_tools[*]}"
    safe_echo "${YELLOW}Некоторые функции могут работать некорректно.${NC}"
    
    # Попытка установить недостающие инструменты
    if [[ -f /etc/debian_version ]]; then
        apt-get update && apt-get install -y "${missing_tools[@]}"
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y "${missing_tools[@]}"
    fi
fi

# Настройка маршрутов для Anonymized DNSCrypt
configure_anonymized_routes() {
    log "INFO" "Настройка маршрутов для Anonymized DNSCrypt..."
    
    safe_echo "\n${BLUE}Настройка маршрутов анонимизации:${NC}"
    echo "Маршруты определяют, через какие релеи будут проходить запросы к определенным серверам."
    echo "Это предотвращает прямую связь между вашим IP и запрашиваемыми доменами."
    safe_echo "${YELLOW}Важно:${NC} Выбирайте релеи и серверы, управляемые разными организациями!"
    echo
    echo "1) Использовать автоматическую маршрутизацию (через wildcard)"
    echo "2) Настроить маршруты вручную"
    echo "3) Просмотреть доступные серверы и релеи"
    echo "0) Отмена"
    
    read -p "Выберите опцию (0-3): " route_option
    
    case $route_option in
        1)
            # Автоматическая маршрутизация
            safe_echo "\n${BLUE}Настройка автоматической маршрутизации:${NC}"
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
                    safe_echo "\n${BLUE}Доступные релеи:${NC}"
                    list_available_relays
                    
                    safe_echo "\n${YELLOW}Введите имена релеев через запятую (например: anon-cs-fr,anon-bcn,anon-tiarap):${NC}"
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
            safe_echo "\n${BLUE}Доступные DNSCrypt-серверы:${NC}"
            list_available_servers
            
            safe_echo "\n${BLUE}Доступные релеи:${NC}"
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
    safe_echo "\n${BLUE}Ручная настройка маршрутов:${NC}"
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
    safe_echo "\n${BLUE}Доступные DNSCrypt-серверы:${NC}"
    list_available_servers
    
    safe_echo "\n${YELLOW}Введите имя DNSCrypt-сервера (или '*' для всех серверов):${NC}"
    read -p "Имя сервера: " server_name
    
    if [ -z "$server_name" ]; then
        log "ERROR" "Имя сервера не может быть пустым"
        return 1
    fi
    
    safe_echo "\n${BLUE}Доступные релеи:${NC}"
    list_available_relays
    
    safe_echo "\n${YELLOW}Введите имена релеев через запятую (например: anon-cs-fr,anon-bcn,anon-tiarap):${NC}"
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
    safe_echo "\n${BLUE}Существующие маршруты:${NC}"
    
    # Извлекаем и нумеруем маршруты
    local routes=$(grep -A 20 "routes = \[" "$DNSCRYPT_CONFIG" | grep -v "routes = \[" | grep -v "\]" | grep "server_name" | sed 's/^[ \t]*//' | nl)
    
    if [ -z "$routes" ]; then
        log "ERROR" "Маршруты не найдены"
        return 1
    fi
    
    echo "$routes"
    
    safe_echo "\n${YELLOW}Введите номер маршрута для удаления:${NC}"
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
    safe_echo "\n${BLUE}Замена всех маршрутов:${NC}"
    safe_echo "${YELLOW}Внимание: Эта операция заменит все существующие маршруты!${NC}"
    read -p "Продолжить? (y/n): " confirm
    
    if [[ "${confirm,,}" != "y" ]]; then
        log "INFO" "Операция отменена"
        return 0
    fi
    
    # Запрашиваем новые маршруты
    local routes="["
    local continue_adding="y"
    
    while [[ "${continue_adding,,}" == "y" ]]; do
        safe_echo "\n${BLUE}Доступные DNSCrypt-серверы:${NC}"
        list_available_servers
        
        safe_echo "\n${YELLOW}Введите имя DNSCrypt-сервера (или '*' для всех серверов):${NC}"
        read -p "Имя сервера: " server_name
        
        if [ -z "$server_name" ]; then
            log "ERROR" "Имя сервера не может быть пустым"
            continue
        fi
        
        safe_echo "\n${BLUE}Доступные релеи:${NC}"
        list_available_relays
        
        safe_echo "\n${YELLOW}Введите имена релеев через запятую (например: anon-cs-fr,anon-bcn,anon-tiarap):${NC}"
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
        
        safe_echo "\n${YELLOW}Добавить еще один маршрут? (y/n):${NC}"
        read -p "> " continue_adding
    done
    
    routes+="\n]"
    
    # Обновляем маршруты в конфигурации
    sed -i "/routes = \[/,/\]/c\\routes = $routes" "$DNSCRYPT_CONFIG"
    
    log "SUCCESS" "Все маршруты успешно заменены"
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

# Настройка маршрутов для ODoH
configure_odoh_routes() {
    log "INFO" "Настройка маршрутов для ODoH..."
    
    safe_echo "\n${YELLOW}Важное замечание:${NC}"
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
    
    safe_echo "\n${BLUE}Настройка маршрутов ODoH:${NC}"
    echo "1) Использовать автоматическую маршрутизацию (через wildcard)"
    echo "2) Добавить маршрут для конкретного ODoH-сервера"
    echo "3) Просмотреть доступные ODoH-серверы и релеи"
    echo "0) Отмена"
    
    read -p "Выберите опцию (0-3): " odoh_route_option
    
    case $odoh_route_option in
        1)
            # Автоматическая маршрутизация для ODoH
            safe_echo "\n${YELLOW}Введите имена ODoH-релеев через запятую или '*' для автоматического выбора:${NC}"
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
            safe_echo "\n${BLUE}Доступные ODoH-серверы:${NC}"
            list_available_odoh_servers
            
            safe_echo "\n${YELLOW}Введите имя ODoH-сервера:${NC}"
            read -p "ODoH-сервер: " odoh_server
            
            if [ -z "$odoh_server" ]; then
                log "ERROR" "Имя сервера не может быть пустым"
                return 1
            fi
            
            safe_echo "\n${BLUE}Доступные ODoH-релеи:${NC}"
            list_available_odoh_relays
            
            safe_echo "\n${YELLOW}Введите имена ODoH-релеев через запятую:${NC}"
            read -p "ODoH-релеи: " odoh_relays
            
            if [ -z "$odoh_relays" ]; then
                log "ERROR" "Список релеев не может быть пустым"
                return 1
            fi
            
            add_anonymized_route_for_odoh "$odoh_server" "$odoh_relays"
            ;;
        3)
            # Просмотр доступных ODoH-серверов и релеев
            safe_echo "\n${BLUE}Доступные ODoH-серверы:${NC}"
            list_available_odoh_servers
            
            safe_echo "\n${BLUE}Доступные ODoH-релеи:${NC}"
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
    
    # Создаем секцию anonymized_dns, если она отсутствует
    if ! grep -q "\[anonymized_dns\]" "$DNSCRYPT_CONFIG"; then
        log "INFO" "Создание секции anonymized_dns для ODoH..."
        configure_anonymized_dns
    fi
    
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
    safe_echo "\n${BLUE}Дополнительные настройки анонимного DNS:${NC}"
    echo "1) Настройка пропуска несовместимых серверов"
    echo "2) Настройка логирования и отладки"
    echo "0) Отмена"
    
    read -p "Выберите опцию (0-2): " additional_option
    
    case $additional_option in
        1)
            # Настройка пропуска несовместимых серверов
            safe_echo "\n${BLUE}Пропуск несовместимых серверов:${NC}"
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
            safe_echo "\n${BLUE}Настройка логирования и отладки:${NC}"
            echo "Увеличение уровня логирования помогает диагностировать проблемы с анонимизацией."
            
            echo "Текущий уровень логирования: $(grep "log_level = " "$DNSCRYPT_CONFIG" | sed 's/log_level = //' || echo "не настроен")"
            
            safe_echo "\nУровни логирования:"
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

# Запуск основного меню
log "INFO" "Запуск модуля управления анонимным DNS..."
main_menu