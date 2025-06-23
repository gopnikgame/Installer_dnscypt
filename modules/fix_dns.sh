#!/bin/bash
# modules/fix_dns.sh - Модуль настройки анонимного DNS через DNSCrypt и ODoH

# Константы
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
BACKUP_DIR="/var/backup/dnscrypt"
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")

# Цветовые коды
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Функция логирования
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "${timestamp} [$1] $2"
}

# Создание резервной копии конфигурации
backup_config() {
    mkdir -p "$BACKUP_DIR"
    cp "$DNSCRYPT_CONFIG" "${BACKUP_DIR}/dnscrypt-proxy_${TIMESTAMP}.toml"
    log "INFO" "Создана резервная копия конфигурации: ${BACKUP_DIR}/dnscrypt-proxy_${TIMESTAMP}.toml"
}

# Проверка текущей конфигурации анонимного DNS
check_anonymized_dns() {
    log "INFO" "Проверка текущей конфигурации анонимного DNS..."
    
    if [ ! -f "$DNSCRYPT_CONFIG" ]; then
        log "ERROR" "${RED}Файл конфигурации DNSCrypt не найден: $DNSCRYPT_CONFIG${NC}"
        return 1
    fi
    
    echo -e "\n${BLUE}Текущие настройки анонимизации DNS:${NC}"
    
    # Проверка секции anonymized_dns
    if grep -q "\[anonymized_dns\]" "$DNSCRYPT_CONFIG"; then
        echo "Секция anonymized_dns: ${GREEN}найдена${NC}"
        
        # Проверка маршрутов
        if grep -A 10 "\[anonymized_dns\]" "$DNSCRYPT_CONFIG" | grep -q "routes"; then
            echo -e "Настроенные маршруты:"
            grep -A 20 "routes = \[" "$DNSCRYPT_CONFIG" | grep -v "^\[" | grep -v "^$" | sed 's/^/    /'
        else
            echo "Маршруты: ${RED}не настроены${NC}"
        fi
        
        # Проверка skip_incompatible
        local skip_incompatible=$(grep -A 5 "\[anonymized_dns\]" "$DNSCRYPT_CONFIG" | grep "skip_incompatible" | cut -d'=' -f2 | tr -d ' ')
        if [ -n "$skip_incompatible" ]; then
            if [ "$skip_incompatible" = "true" ]; then
                echo "Пропуск несовместимых: ${GREEN}включен${NC}"
            else
                echo "Пропуск несовместимых: ${RED}выключен${NC}"
            fi
        else
            echo "Пропуск несовместимых: ${YELLOW}не настроен (по умолчанию выключен)${NC}"
        fi
    else
        echo "Секция anonymized_dns: ${RED}не найдена${NC}"
    fi
    
    # Проверка настроек ODoH
    echo -e "\n${BLUE}Настройки Oblivious DoH (ODoH):${NC}"
    
    # Проверка поддержки ODoH
    if grep -q "odoh_servers = true" "$DNSCRYPT_CONFIG"; then
        echo "Поддержка ODoH: ${GREEN}включена${NC}"
    else
        echo "Поддержка ODoH: ${RED}выключена${NC}"
    fi
    
    # Проверка источников ODoH
    if grep -q "\[sources.odoh-servers\]" "$DNSCRYPT_CONFIG"; then
        echo "Источник ODoH-серверов: ${GREEN}настроен${NC}"
    else
        echo "Источник ODoH-серверов: ${RED}не настроен${NC}"
    fi
    
    if grep -q "\[sources.odoh-relays\]" "$DNSCRYPT_CONFIG"; then
        echo "Источник ODoH-релеев: ${GREEN}настроен${NC}"
    else
        echo "Источник ODoH-релеев: ${RED}не настроен${NC}"
    fi
    
    # Проверка списков серверов и релеев
    echo -e "\n${BLUE}Настройки источников списков:${NC}"
    if grep -q "\[sources.'relays'\]" "$DNSCRYPT_CONFIG"; then
        echo "Источник релеев для Anonymized DNSCrypt: ${GREEN}настроен${NC}"
    else
        echo "Источник релеев для Anonymized DNSCrypt: ${RED}не настроен${NC}"
    fi
}

# Настройка Anonymized DNSCrypt
configure_anonymized_dns() {
    log "INFO" "Настройка Anonymized DNSCrypt..."
    
    # Проверка наличия DNSCrypt-серверов
    if ! grep -q "dnscrypt_servers = true" "$DNSCRYPT_CONFIG"; then
        echo -e "\n${YELLOW}Внимание: DNSCrypt-серверы не включены в конфигурации.${NC}"
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
    
    # Настройка маршрутов
    configure_anonymized_routes
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
                    log "SUCCESS" "${GREEN}Настроена автоматическая маршрутизация через случайные релеи${NC}"
                    ;;
                2)
                    # Выбрать релеи для всех серверов
                    echo -e "\n${BLUE}Доступные релеи:${NC}"
                    list_available_relays
                    
                    echo -e "\n${YELLOW}Введите имена релеев через запятую (например: anon-cs-fr,anon-bcn,anon-tiarap):${NC}"
                    read -p "Релеи: " relay_list
                    
                    if [ -z "$relay_list" ]; then
                        log "ERROR" "${RED}Список релеев не может быть пустым${NC}"
                        return 1
                    fi
                    
                    # Преобразуем список в формат для маршрута
                    local relays=$(echo "$relay_list" | tr ',' ' ' | sed "s/\([a-zA-Z0-9_-]*\)/'\1'/g" | tr ' ' ',')
                    update_anonymized_routes "{ server_name='*', via=[$relays] }"
                    
                    log "SUCCESS" "${GREEN}Настроена автоматическая маршрутизация через выбранные релеи${NC}"
                    ;;
                0)
                    return 0
                    ;;
                *)
                    log "ERROR" "${RED}Неверный выбор${NC}"
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
            log "ERROR" "${RED}Неверный выбор${NC}"
            return 1
            ;;
    esac
}

# Вывод списка доступных DNSCrypt-серверов
list_available_servers() {
    # Проверка наличия кэш-файла с серверами
    local servers_cache="/etc/dnscrypt-proxy/public-resolvers.md"
    
    if [ ! -f "$servers_cache" ]; then
        echo -e "${YELLOW}Файл с серверами не найден. Загрузите списки серверов с помощью dnscrypt-proxy.${NC}"
        return 1
    fi
    
    # Читаем и выводим список DNSCrypt-серверов
    echo -e "${YELLOW}Список может быть большим. Показаны только первые 20 серверов.${NC}"
    grep -A 1 "^## " "$servers_cache" | grep -v "^--" | head -n 40 | sed 'N;s/\n/ - /' | sed 's/## //' | nl
    
    echo -e "\n${YELLOW}Для просмотра полного списка серверов выполните:${NC}"
    echo "cat $servers_cache | grep -A 1 '^## ' | grep -v '^--' | sed 'N;s/\\n/ - /' | sed 's/## //'"
}

# Вывод списка доступных релеев
list_available_relays() {
    # Проверка наличия кэш-файла с релеями
    local relays_cache="/etc/dnscrypt-proxy/relays.md"
    
    if [ ! -f "$relays_cache" ]; then
        echo -e "${YELLOW}Файл с релеями не найден. Загрузите списки релеев с помощью dnscrypt-proxy.${NC}"
        return 1
    fi
    
    # Читаем и выводим список релеев
    grep -A 1 "^## " "$relays_cache" | grep -v "^--" | sed 'N;s/\n/ - /' | sed 's/## //' | nl
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
            log "ERROR" "${RED}Неверный выбор${NC}"
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
        log "ERROR" "${RED}Имя сервера не может быть пустым${NC}"
        return 1
    fi
    
    echo -e "\n${BLUE}Доступные релеи:${NC}"
    list_available_relays
    
    echo -e "\n${YELLOW}Введите имена релеев через запятую (например: anon-cs-fr,anon-bcn,anon-tiarap):${NC}"
    read -p "Релеи: " relay_list
    
    if [ -z "$relay_list" ]; then
        log "ERROR" "${RED}Список релеев не может быть пустым${NC}"
        return 1
    fi
    
    # Преобразуем список в формат для маршрута
    local relays=$(echo "$relay_list" | tr ',' ' ' | sed "s/\([a-zA-Z0-9_*-]*\)/'\1'/g" | tr ' ' ',')
    local new_route="{ server_name='$server_name', via=[$relays] }"
    
    # Добавляем новый маршрут
    add_route_to_config "$new_route"
    
    log "SUCCESS" "${GREEN}Маршрут успешно добавлен${NC}"
}

# Удаление существующего маршрута
remove_anonymized_route() {
    echo -e "\n${BLUE}Существующие маршруты:${NC}"
    
    # Извлекаем и нумеруем маршруты
    local routes=$(grep -A 20 "routes = \[" "$DNSCRYPT_CONFIG" | grep -v "routes = \[" | grep -v "\]" | grep "server_name" | sed 's/^[ \t]*//' | nl)
    
    if [ -z "$routes" ]; then
        log "ERROR" "${RED}Маршруты не найдены${NC}"
        return 1
    fi
    
    echo "$routes"
    
    echo -e "\n${YELLOW}Введите номер маршрута для удаления:${NC}"
    read -p "Номер маршрута: " route_number
    
    if ! [[ "$route_number" =~ ^[0-9]+$ ]]; then
        log "ERROR" "${RED}Неверный номер маршрута${NC}"
        return 1
    fi
    
    # Получаем маршрут по номеру
    local route_to_remove=$(echo "$routes" | grep "^ *$route_number" | sed 's/^ *[0-9]\+\t//')
    
    if [ -z "$route_to_remove" ]; then
        log "ERROR" "${RED}Маршрут с номером $route_number не найден${NC}"
        return 1
    fi
    
    # Удаляем маршрут из конфигурации
    sed -i "/$(echo "$route_to_remove" | sed 's/[\/&]/\\&/g')/d" "$DNSCRYPT_CONFIG"
    
    log "SUCCESS" "${GREEN}Маршрут успешно удален${NC}"
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
            log "ERROR" "${RED}Имя сервера не может быть пустым${NC}"
            continue
        fi
        
        echo -e "\n${BLUE}Доступные релеи:${NC}"
        list_available_relays
        
        echo -e "\n${YELLOW}Введите имена релеев через запятую (например: anon-cs-fr,anon-bcn,anon-tiarap):${NC}"
        read -p "Релеи: " relay_list
        
        if [ -z "$relay_list" ]; then
            log "ERROR" "${RED}Список релеев не может быть пустым${NC}"
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
    
    log "SUCCESS" "${GREEN}Все маршруты успешно заменены${NC}"
}

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

# Настройка Oblivious DoH (ODoH)
configure_odoh() {
    log "INFO" "Настройка Oblivious DoH (ODoH)..."
    
    echo -e "\n${BLUE}Oblivious DoH (ODoH):${NC}"
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
            log "ERROR" "${RED}Неверный выбор${NC}"
            return 1
            ;;
    esac
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
            log "ERROR" "${RED}Не найдена строка doh_servers в конфигурации${NC}"
            return 1
        fi
    fi
    
    # Добавление источников ODoH серверов и релеев
    add_odoh_sources
    
    log "SUCCESS" "${GREEN}Поддержка ODoH включена${NC}"
    
    # Предлагаем настроить маршруты
    echo -e "\n${YELLOW}Хотите настроить маршруты для ODoH? (y/n):${NC}"
    read -p "> " configure_routes
    
    if [[ "${configure_routes,,}" == "y" ]]; then
        configure_odoh_routes
    fi
}

# Отключение поддержки ODoH
disable_odoh_support() {
    log "INFO" "Отключение поддержки Oblivious DoH..."
    
    # Отключение ODoH серверов
    if grep -q "odoh_servers = " "$DNSCRYPT_CONFIG"; then
        sed -i "s/odoh_servers = .*/odoh_servers = false/" "$DNSCRYPT_CONFIG"
    fi
    
    log "SUCCESS" "${GREEN}Поддержка ODoH отключена${NC}"
}

# Добавление источников для ODoH
add_odoh_sources() {
    log "INFO" "Добавление источников для ODoH..."
    
    # Проверяем наличие секции [sources]
    if ! grep -q "\[sources\]" "$DNSCRYPT_CONFIG"; then
        log "ERROR" "${RED}Секция [sources] не найдена в конфигурации${NC}"
        return 1
    fi
    
    # Добавление источника серверов ODoH
    if ! grep -q "\[sources.odoh-servers\]" "$DNSCRYPT_CONFIG"; then
        # Находим последнюю [sources.*] секцию
        local last_sources_line=$(grep -n "\[sources." "$DNSCRYPT_CONFIG" | tail -n1 | cut -d':' -f1)
        
        if [ -n "$last_sources_line" ]; then
            local insert_line=$((last_sources_line + 10)) # Примерно после конца последней [sources.*] секции
        else
            local sources_line=$(grep -n "\[sources\]" "$DNSCRYPT_CONFIG" | cut -d':' -f1)
            local insert_line=$((sources_line + 1))
        fi
        
        # Добавляем конфигурацию источника ODoH серверов
        sed -i "${insert_line}i\\
\\
  [sources.odoh-servers]\\
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/odoh-servers.md', 'https://download.dnscrypt.info/resolvers-list/v3/odoh-servers.md']\\
  cache_file = 'odoh-servers.md'\\
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'\\
  refresh_delay = 72\\
  prefix = ''" "$DNSCRYPT_CONFIG"
        
        log "SUCCESS" "${GREEN}Источник ODoH-серверов успешно добавлен${NC}"
    fi
    
    # Добавление источника релеев ODoH
    if ! grep -q "\[sources.odoh-relays\]" "$DNSCRYPT_CONFIG"; then
        # Находим строку после последнего источника
        local odoh_servers_line=$(grep -n "\[sources.odoh-servers\]" "$DNSCRYPT_CONFIG" | cut -d':' -f1)
        
        if [ -n "$odoh_servers_line" ]; then
            local insert_line=$((odoh_servers_line + 10)) # Примерно после конца [sources.odoh-servers]
        else
            local last_sources_line=$(grep -n "\[sources." "$DNSCRYPT_CONFIG" | tail -n1 | cut -d':' -f1)
            local insert_line=$((last_sources_line + 10))
        fi
        
        # Добавляем конфигурацию источника ODoH релеев
        sed -i "${insert_line}i\\
\\
  [sources.odoh-relays]\\
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/odoh-relays.md', 'https://download.dnscrypt.info/resolvers-list/v3/odoh-relays.md']\\
  cache_file = 'odoh-relays.md'\\
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'\\
  refresh_delay = 72\\
  prefix = ''" "$DNSCRYPT_CONFIG"
        
        log "SUCCESS" "${GREEN}Источник ODoH-релеев успешно добавлен${NC}"
    fi
    
    return 0
}

# Настройка маршрутов для ODoH
configure_odoh_routes() {
    log "INFO" "Настройка маршрутов для ODoH..."
    
    echo -e "\n${YELLOW}Важное замечание:${NC}"
    echo "Для корректной работы ODoH необходимо включить источники odoh-servers и odoh-relays,"
    echo "а также добавить маршруты для серверов ODoH через релеи ODoH."
    
    # Проверяем, включены ли источники ODoH
    if ! grep -q "\[sources.odoh-servers\]" "$DNSCRYPT_CONFIG" || ! grep -q "\[sources.odoh-relays\]" "$DNSCRYPT_CONFIG"; then
        log "WARN" "${YELLOW}Источники ODoH не настроены. Настраиваем...${NC}"
        add_odoh_sources
    fi
    
    # Проверяем, включены ли ODoH серверы
    if ! grep -q "odoh_servers = true" "$DNSCRYPT_CONFIG"; then
        log "WARN" "${YELLOW}Поддержка ODoH не включена. Включаем...${NC}"
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
                log "ERROR" "${RED}Имя сервера не может быть пустым${NC}"
                return 1
            fi
            
            echo -e "\n${BLUE}Доступные ODoH-релеи:${NC}"
            list_available_odoh_relays
            
            echo -e "\n${YELLOW}Введите имена ODoH-релеев через запятую:${NC}"
            read -p "ODoH-релеи: " odoh_relays
            
            if [ -z "$odoh_relays" ]; then
                log "ERROR" "${RED}Список релеев не может быть пустым${NC}"
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
            log "ERROR" "${RED}Неверный выбор${NC}"
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
    
    log "SUCCESS" "${GREEN}Маршрут для ODoH успешно добавлен${NC}"
    
    # Перезапуск службы для применения изменений
    systemctl restart dnscrypt-proxy
}

# Вывод списка доступных ODoH-серверов
list_available_odoh_servers() {
    # Проверка наличия кэш-файла с ODoH-серверами
    local servers_cache="/etc/dnscrypt-proxy/odoh-servers.md"
    
    if [ ! -f "$servers_cache" ]; then
        echo -e "${YELLOW}Файл с ODoH-серверами не найден. Загрузите списки серверов с помощью dnscrypt-proxy.${NC}"
        return 1
    fi
    
    # Читаем и выводим список ODoH-серверов
    grep -A 1 "^## " "$servers_cache" | grep -v "^--" | sed 'N;s/\n/ - /' | sed 's/## //' | nl
}

# Вывод списка доступных ODoH-релеев
list_available_odoh_relays() {
    # Проверка наличия кэш-файла с ODoH-релеями
    local relays_cache="/etc/dnscrypt-proxy/odoh-relays.md"
    
    if [ ! -f "$relays_cache" ]; then
        echo -e "${YELLOW}Файл с ODoH-релеями не найден. Загрузите списки релеев с помощью dnscrypt-proxy.${NC}"
        return 1
    fi
    
    # Читаем и выводим список ODoH-релеев
    grep -A 1 "^## " "$relays_cache" | grep -v "^--" | sed 'N;s/\n/ - /' | sed 's/## //' | nl
}

# Функция для настройки балансировки нагрузки
configure_load_balancing() {
    log "INFO" "Настройка стратегии балансировки нагрузки..."
    
    echo -e "\n${BLUE}Стратегии балансировки нагрузки:${NC}"
    echo "Стратегия балансировки определяет, как выбираются серверы для запросов из отсортированного списка (от самого быстрого к самому медленному)."
    echo
    echo "Доступные стратегии:"
    echo -e "${YELLOW}first${NC} - всегда выбирается самый быстрый сервер" 
    echo -e "${YELLOW}p2${NC} - случайный выбор из 2 самых быстрых серверов (рекомендуется)"
    echo -e "${YELLOW}ph${NC} - случайный выбор из быстрейшей половины серверов"
    echo -e "${YELLOW}random${NC} - случайный выбор из всех серверов"
    echo
    
    # Получаем текущую стратегию
    local current_strategy=$(grep "lb_strategy = " "$DNSCRYPT_CONFIG" | sed "s/lb_strategy = '\(.*\)'/\1/" | tr -d ' ' || echo "p2")
    
    echo -e "Текущая стратегия: ${GREEN}$current_strategy${NC}"
    echo
    echo "1) first (самый быстрый сервер)"
    echo "2) p2 (топ-2 серверов)"
    echo "3) ph (быстрейшая половина)"
    echo "4) random (случайный выбор)"
    echo "0) Отмена"
    
    read -p "Выберите стратегию (0-4): " lb_choice
    
    local new_strategy=""
    case $lb_choice in
        1) new_strategy="first" ;;
        2) new_strategy="p2" ;;
        3) new_strategy="ph" ;;
        4) new_strategy="random" ;;
        0) return 0 ;;
        *) 
            log "ERROR" "${RED}Неверный выбор${NC}"
            return 1
            ;;
    esac
    
    if [ -n "$new_strategy" ]; then
        # Обновляем стратегию в конфиге
        if grep -q "lb_strategy = " "$DNSCRYPT_CONFIG"; then
            sed -i "s/lb_strategy = .*/lb_strategy = '$new_strategy'/" "$DNSCRYPT_CONFIG"
        else
            # Добавляем новую опцию после [sources]
            sed -i "/\[sources\]/i lb_strategy = '$new_strategy'" "$DNSCRYPT_CONFIG"
        fi
        
        log "SUCCESS" "${GREEN}Стратегия балансировки изменена на '$new_strategy'${NC}"
        
        # Перезапускаем службу
        systemctl restart dnscrypt-proxy
    fi
    
    return 0
}

# Функция для тестирования времени отклика DNS-серверов
test_server_latency() {
    log "INFO" "Тестирование времени отклика DNS-серверов..."
    
    echo -e "\n${BLUE}Тестирование времени отклика:${NC}"
    echo "Этот тест измеряет время ответа каждого настроенного DNS-сервера."
    echo "Результаты помогут выбрать наиболее быстрые серверы для вашего местоположения."
    
    # Проверяем, установлены ли необходимые инструменты
    if ! command -v dig &> /dev/null; then
        log "ERROR" "${RED}Утилита 'dig' не установлена. Установите пакет dnsutils.${NC}"
        return 1
    fi
    
    # Получаем список настроенных серверов (корректный парсинг)
    local server_names_line=$(grep "server_names" "$DNSCRYPT_CONFIG" | head -1)
    
    # Проверим, что строка найдена и имеет нужный формат
    if [ -z "$server_names_line" ]; then
        log "ERROR" "${RED}Настроенные серверы не найдены в конфигурации${NC}"
        return 1
    fi
    
    # Извлекаем только значение массива серверов, используя регулярное выражение
    local server_list=$(echo "$server_names_line" | grep -o "\[\([^]]*\)\]" | sed -e "s/\[//" -e "s/\]//" | tr -d "'" | tr -d '"' | tr ',' ' ')
    
    # Дополнительная проверка, что мы получили корректный список серверов
    if [ -z "$server_list" ]; then
        # Попытка использовать альтернативный метод разбора
        server_list=$(dnscrypt-proxy -list -config "$DNSCRYPT_CONFIG" 2>/dev/null | grep -E "^[^ ]+" | cut -d' ' -f1 | grep -v "^$")
        
        # Если по-прежнему нет серверов, выводим ошибку
        if [ -z "$server_list" ]; then
            log "ERROR" "${RED}Не удалось определить список настроенных серверов${NC}"
            echo -e "${YELLOW}Проверьте корректность конфигурации DNSCrypt (server_names).${NC}"
            return 1
        fi
    fi
    
    echo -e "\n${YELLOW}Настроенные серверы:${NC} $server_list"
    echo -e "\n${BLUE}Выполняется тестирование, пожалуйста, подождите...${NC}"
    
    # Создаем временный файл для результатов
    local tmp_file=$(mktemp)
    
    # Тестируем каждый сервер
    for server in $server_list; do
        # Пропускаем пустые имена или явно некорректные значения
        if [ -z "$server" ] || [[ "$server" == "#"* ]] || [ ${#server} -lt 3 ]; then
            continue
        fi
        
        echo -n "Тестирование сервера $server... "
        
        # Получаем текущий IP сервера из логов dnscrypt-proxy
        local server_ip=$(journalctl -u dnscrypt-proxy -n 200 | grep -i "$server" | grep -o -E "\([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1 | tr -d '(' || echo "")
        
        if [ -z "$server_ip" ]; then
            # Если IP не найден в логах, получаем его через прямой запрос
            server_ip="(IP не определен)"
            
            # Выполняем тестовые запросы
            local best_time=999999
            for i in {1..3}; do
                local time=$(dig @127.0.0.1 +timeout=2 +tries=1 example.com | grep "Query time" | awk '{print $4}')
                
                if [ -n "$time" ] && [ "$time" -lt "$best_time" ]; then
                    best_time=$time
                fi
                sleep 0.5
            done
            
            if [ "$best_time" -eq 999999 ]; then
                best_time="таймаут"
                echo -e "${RED}$best_time${NC}"
            else
                best_time="${best_time}ms"
                echo -e "${GREEN}$best_time${NC} $server_ip"
                echo "$server $best_time $server_ip" >> "$tmp_file"
            fi
        else
            # Если IP найден, проводим измерения
            local best_time=999999
            for i in {1..3}; do
                local time=$(dig @127.0.0.1 +timeout=2 +tries=1 example.com | grep "Query time" | awk '{print $4}')
                
                if [ -n "$time" ] && [ "$time" -lt "$best_time" ]; then
                    best_time=$time
                fi
                sleep 0.5
            done
            
            if [ "$best_time" -eq 999999 ]; then
                best_time="таймаут"
                echo -e "${RED}$best_time${NC}"
            else
                best_time="${best_time}ms"
                echo -e "${GREEN}$best_time${NC} $server_ip"
                echo "$server $best_time $server_ip" >> "$tmp_file"
            fi
        fi
    done
    
    # Проверяем, есть ли результаты
    if [ ! -s "$tmp_file" ]; then
        echo -e "\n${RED}Не удалось получить результаты тестирования для серверов.${NC}"
        echo -e "${YELLOW}Возможно, серверы недоступны или некорректно настроены.${NC}"
        rm -f "$tmp_file"
        return 1
    fi
    
    # Сортируем и выводим результаты от самого быстрого к самому медленному
    echo -e "\n${BLUE}Результаты тестирования (отсортированы по времени отклика):${NC}"
    sort -k2 -n "$tmp_file" | sed 's/ms//g' | awk '{printf "%-30s %-15s", $1, $2"ms"; for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | \
        awk 'BEGIN {print "Сервер                         Время отклика    IP адрес"; print "----------------------------------------------------------------------"}; {print $0}'
    
    # Удаляем временный файл
    rm -f "$tmp_file"
    
    # Предложение применить оптимальные настройки
    echo -e "\n${YELLOW}Хотите настроить DNSCrypt для использования самых быстрых серверов? (y/n):${NC}"
    read -p "> " configure_fastest
    
    if [[ "${configure_fastest,,}" == "y" ]]; then
        configure_fastest_servers
    fi
    
    return 0
}

# Функция для настройки самых быстрых серверов
configure_fastest_servers() {
    log "INFO" "Настройка самых быстрых серверов..."
    
    echo -e "\n${BLUE}Настройка быстрейших серверов:${NC}"
    echo "1) Использовать только самый быстрый сервер"
    echo "2) Использовать 2 самых быстрых сервера (рекомендуется)"
    echo "3) Использовать 3 самых быстрых сервера"
    echo "4) Ввести количество серверов вручную"
    echo "0) Отмена"
    
    read -p "Выберите опцию (0-4): " fastest_option
    
    local num_servers=0
    case $fastest_option in
        1) num_servers=1 ;;
        2) num_servers=2 ;;
        3) num_servers=3 ;;
        4)
            read -p "Введите количество самых быстрых серверов для использования: " custom_num
            if [[ "$custom_num" =~ ^[0-9]+$ ]] && [ "$custom_num" -gt 0 ]; then
                num_servers=$custom_num
            else
                log "ERROR" "${RED}Неверное количество серверов${NC}"
                return 1
            fi
            ;;
        0) return 0 ;;
        *)
            log "ERROR" "${RED}Неверный выбор${NC}"
            return 1
            ;;
    esac
    
    if [ "$num_servers" -gt 0 ]; then
        # Создаем временный файл для сбора данных о серверах
        local tmp_file=$(mktemp)
        
        # Получаем список настроенных серверов (корректный парсинг)
        local server_names_line=$(grep "server_names" "$DNSCRYPT_CONFIG" | head -1)
        local server_list=$(echo "$server_names_line" | grep -o "\[\([^]]*\)\]" | sed -e "s/\[//" -e "s/\]//" | tr -d "'" | tr -d '"' | tr ',' ' ')
        
        # Если не удалось получить список, пробуем альтернативный метод
        if [ -z "$server_list" ]; then
            server_list=$(dnscrypt-proxy -list -config "$DNSCRYPT_CONFIG" 2>/dev/null | grep -E "^[^ ]+" | cut -d' ' -f1 | grep -v "^$")
        fi
        
        # Если все еще нет данных, используем журналы
        if [ -z "$server_list" ]; then
            local sorted_servers=$(journalctl -u dnscrypt-proxy -n 1000 | grep "Server with lowest initial latency" | tail -1 | sed 's/.*: //' | tr -d '[]' | tr ',' ' ')
            
            if [ -z "$sorted_servers" ]; then
                log "ERROR" "${RED}Не удалось получить список серверов${NC}"
                echo -e "${YELLOW}Выполните перезапуск DNSCrypt-proxy и повторите попытку позже.${NC}"
                rm -f "$tmp_file"
                return 1
            fi
            
            # Используем предварительно отсортированный список из журналов
            server_list=$sorted_servers
        else
            # Тестируем каждый сервер для определения самых быстрых
            echo -e "\n${BLUE}Определение самых быстрых серверов...${NC}"
            
            for server in $server_list; do
                # Пропускаем некорректные значения
                if [ -z "$server" ] || [[ "$server" == "#"* ]] || [ ${#server} -lt 3 ]; then
                    continue
                fi
                
                echo -n "Тестирование $server... "
                
                # Выполняем тестовые запросы
                local best_time=999999
                for i in {1..3}; do
                    local time=$(dig @127.0.0.1 +timeout=2 +tries=1 example.com | grep "Query time" | awk '{print $4}')
                    
                    if [ -n "$time" ] && [ "$time" -lt "$best_time" ]; then
                        best_time=$time
                    fi
                    sleep 0.5
                done
                
                if [ "$best_time" -eq 999999 ]; then
                    echo -e "${RED}таймаут${NC}"
                else
                    echo -e "${GREEN}${best_time}ms${NC}"
                    echo "$server $best_time" >> "$tmp_file"
                fi
            done
            
            # Сортируем серверы по времени отклика
            if [ -s "$tmp_file" ]; then
                server_list=$(sort -k2 -n "$tmp_file" | cut -d' ' -f1)
            else
                log "ERROR" "${RED}Не удалось получить результаты тестирования${NC}"
                rm -f "$tmp_file"
                return 1
            fi
        fi
        
        # Выбираем первые N серверов
        local fastest_servers=()
        local count=0
        
        for server in $server_list; do
            fastest_servers+=("$server")
            ((count++))
            
            if [ "$count" -ge "$num_servers" ]; then
                break
            fi
        done
        
        # Проверяем, что у нас есть серверы для добавления
        if [ ${#fastest_servers[@]} -eq 0 ]; then
            log "ERROR" "${RED}Не удалось определить быстрые серверы${NC}"
            rm -f "$tmp_file"
            return 1
        fi
        
        # Формируем строку серверов для конфигурации
        local server_names="["
        for i in "${!fastest_servers[@]}"; do
            if [ "$i" -gt 0 ]; then
                server_names+=", "
            fi
            server_names+="'${fastest_servers[$i]}'"
        done
        server_names+="]"
        
        # Обновляем конфигурацию
        sed -i "s/server_names = .*/server_names = $server_names/" "$DNSCRYPT_CONFIG"
        
        # Настраиваем стратегию балансировки
        local lb_strategy=""
        if [ "$num_servers" -eq 1 ]; then
            lb_strategy="first"
        elif [ "$num_servers" -eq 2 ]; then
            lb_strategy="p2"
        else
            lb_strategy="ph"
        fi
        
        if grep -q "lb_strategy = " "$DNSCRYPT_CONFIG"; then
            sed -i "s/lb_strategy = .*/lb_strategy = '$lb_strategy'/" "$DNSCRYPT_CONFIG"
        else
            sed -i "/\[sources\]/i lb_strategy = '$lb_strategy'" "$DNSCRYPT_CONFIG"
        fi
        
        log "SUCCESS" "${GREEN}Настроено использование $num_servers самых быстрых серверов со стратегией $lb_strategy${NC}"
        echo -e "Выбранные серверы: ${YELLOW}${fastest_servers[*]}${NC}"
        
        # Удаляем временный файл
        rm -f "$tmp_file"
        
        # Перезапуск службы
        systemctl restart dnscrypt-proxy
        echo -e "\n${GREEN}DNSCrypt-proxy перезапущен с новой конфигурацией${NC}"
    fi
    
    return 0
}

# Настройка дополнительной конфигурации
configure_additional_settings() {
    echo -e "\n${BLUE}Дополнительные настройки:${NC}"
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
                
                log "SUCCESS" "${GREEN}Пропуск несовместимых серверов включен${NC}"
            else
                if grep -q "skip_incompatible" "$DNSCRYPT_CONFIG"; then
                    sed -i "s/skip_incompatible = .*/skip_incompatible = false/" "$DNSCRYPT_CONFIG"
                else
                    sed -i "/\[anonymized_dns\]/a skip_incompatible = false" "$DNSCRYPT_CONFIG"
                fi
                
                log "SUCCESS" "${GREEN}Пропуск несовместимых серверов отключен${NC}"
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
                if grep -q "log_level = " "$DNSCRYPT_CONFIG"; then
                    sed -i "s/log_level = .*/log_level = $log_level/" "$DNSCRYPT_CONFIG"
                else
                    echo "log_level = $log_level" >> "$DNSCRYPT_CONFIG"
                fi
                
                log "SUCCESS" "${GREEN}Уровень логирования изменен на $log_level${NC}"
            else
                log "ERROR" "${RED}Неверный уровень логирования${NC}"
            fi
            ;;
        0)
            return 0
            ;;
        *)
            log "ERROR" "${RED}Неверный выбор${NC}"
            return 1
            ;;
    esac
    
    # Перезапуск службы для применения изменений
    systemctl restart dnscrypt-proxy
    
    return 0
}

# Основное меню
main_menu() {
    while true; do
        echo -e "\n${BLUE}===== МЕНЮ НАСТРОЙКИ АНОНИМНОГО DNS =====${NC}"
        echo "1) Проверить текущую конфигурацию"
        echo "2) Настроить Anonymized DNSCrypt"
        echo "3) Настроить Oblivious DoH (ODoH)"
        echo "4) Настроить балансировку нагрузки"
        echo "5) Тестировать время отклика серверов"
        echo "6) Дополнительные настройки"
        echo "7) Перезапустить DNSCrypt-proxy"
        echo "0) Выход"
        
        read -p "Выберите опцию (0-7): " option
        
        case $option in
            1)
                check_anonymized_dns
                ;;
            2)
                backup_config
                configure_anonymized_dns
                ;;
            3)
                backup_config
                configure_odoh
                ;;
            4)
                backup_config
                configure_load_balancing
                ;;
            5)
                test_server_latency
                ;;
            6)
                backup_config
                configure_additional_settings
                ;;
            7)
                systemctl restart dnscrypt-proxy
                log "SUCCESS" "${GREEN}DNSCrypt-proxy перезапущен${NC}"
                ;;
            0)
                log "INFO" "Выход из программы"
                exit 0
                ;;
            *)
                log "ERROR" "${RED}Неверный выбор${NC}"
                ;;
        esac
        
        echo
        read -p "Нажмите Enter для продолжения..."
    done
}

# Проверка root-прав
if [ "$EUID" -ne 0 ]; then
    log "ERROR" "${RED}Этот скрипт должен быть запущен с правами root${NC}"
    exit 1
fi

# Проверка наличия DNSCrypt-proxy
if ! command -v dnscrypt-proxy &>/dev/null; then
    log "ERROR" "${RED}DNSCrypt-proxy не установлен${NC}"
    exit 1
fi

# Запуск основного меню
log "INFO" "Запуск модуля настройки анонимного DNS..."
main_menu