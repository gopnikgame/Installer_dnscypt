#!/bin/bash
# modules/manage_anonymized_dns.sh - Модуль управления анонимным DNS через DNSCrypt
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

# Функция поиска серверов по стране (обновлена под новый формат)
find_servers_by_country() {
    local country="$1"
    local servers_file="$2"
    
    if [[ ! -f "$servers_file" ]]; then
        log "ERROR" "Файл серверов не найден: $servers_file"
        return 1
    fi
    
    # Массив для хранения найденных серверов
    declare -a found_servers=()
    
    # Флаг для отслеживания, находимся ли мы в нужной стране
    local in_target_country=false
    local current_country=""
    
    while IFS= read -r line; do
        # Пропускаем пустые строки и комментарии
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Проверяем, является ли строка названием страны (в квадратных скобках)
        if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
            current_country="${BASH_REMATCH[1]}"
            # Проверяем, соответствует ли страна искомой (нечувствительно к регистру)
            if echo "$current_country" | grep -qi "$country"; then
                in_target_country=true
                log "DEBUG" "Найдена страна: $current_country"
            else
                in_target_country=false
            fi
            continue
        fi
        
        # Проверяем, является ли строка названием города (в кавычках)
        if [[ "$line" =~ ^\"([^\"]+)\"$ ]]; then
            # Это город, пропускаем (используем только для контекста)
            continue
        fi
        
        # Если мы в нужной стране и это строка с сервером
        if [[ "$in_target_country" == true ]] && [[ ! "$line" =~ ^\[.*\]$ ]] && [[ ! "$line" =~ ^\".*\"$ ]]; then
            # Извлекаем имя сервера (первое слово) и IP-адрес (последний элемент)
            local server_name=$(echo "$line" | awk '{print $1}')
            local server_ip=$(echo "$line" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | tail -1)
            
            if [[ -n "$server_name" && -n "$server_ip" ]]; then
                found_servers+=("$server_name:$server_ip")
                log "DEBUG" "Найден сервер: $server_name ($server_ip)"
            fi
        fi
    done < "$servers_file"
    
    # Выводим найденные серверы
    if [[ ${#found_servers[@]} -gt 0 ]]; then
        printf '%s\n' "${found_servers[@]}"
        log "INFO" "Найдено серверов в стране '$country': ${#found_servers[@]}"
    else
        log "WARN" "Серверы в стране '$country' не найдены"
    fi
    
    return 0
}

# Функция поиска релеев по стране (обновлена под новый формат)
find_relays_by_country() {
    local country="$1"
    local relays_file="$2"
    
    if [[ ! -f "$relays_file" ]]; then
        log "ERROR" "Файл релеев не найден: $relays_file"
        return 1
    fi
    
    # Массив для хранения найденных релеев
    declare -a found_relays=()
    
    # Флаг для отслеживания, находимся ли мы в нужной стране
    local in_target_country=false
    local current_country=""
    
    while IFS= read -r line; do
        # Пропускаем пустые строки и комментарии
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Проверяем, является ли строка названием страны (в квадратных скобках)
        if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
            current_country="${BASH_REMATCH[1]}"
            # Проверяем, соответствует ли страна искомой (нечувствительно к регистру)
            if echo "$current_country" | grep -qi "$country"; then
                in_target_country=true
                log "DEBUG" "Найдена страна: $current_country"
            else
                in_target_country=false
            fi
            continue
        fi
        
        # Проверяем, является ли строка названием города (в кавычках)
        if [[ "$line" =~ ^\"([^\"]+)\"$ ]]; then
            # Это город, пропускаем (используем только для контекста)
            continue
        fi
        
        # Если мы в нужной стране и это строка с релеем
        if [[ "$in_target_country" == true ]] && [[ ! "$line" =~ ^\[.*\]$ ]] && [[ ! "$line" =~ ^\".*\"$ ]]; then
            # Извлекаем имя релея (первое слово) и IP-адрес (последний элемент)
            local relay_name=$(echo "$line" | awk '{print $1}')
            local relay_ip=$(echo "$line" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | tail -1)
            
            if [[ -n "$relay_name" && -n "$relay_ip" ]]; then
                found_relays+=("$relay_name:$relay_ip")
                log "DEBUG" "Найден релей: $relay_name ($relay_ip)"
            fi
        fi
    done < "$relays_file"
    
    # Выводим найденные релеи
    if [[ ${#found_relays[@]} -gt 0 ]]; then
        printf '%s\n' "${found_relays[@]}"
        log "INFO" "Найдено релеев в стране '$country': ${#found_relays[@]}"
    else
        log "WARN" "Релеи в стране '$country' не найдены"
    fi
    
    return 0
}

# Функция поиска релеев по стране (обновлена под новый формат) - БЕЗ логов в stdout
find_relays_by_country_silent() {
    local country="$1"
    local relays_file="$2"
    
    if [[ ! -f "$relays_file" ]]; then
        return 1
    fi
    
    # Массив для хранения найденных релеев
    declare -a found_relays=()
    
    # Флаг для отслеживания, находимся ли мы в нужной стране
    local in_target_country=false
    local current_country=""
    
    while IFS= read -r line; do
        # Пропускаем пустые строки и комментарии
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Проверяем, является ли строка названием страны (в квадратных скобках)
        if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
            current_country="${BASH_REMATCH[1]}"
            # Проверяем, соответствует ли страна искомой (нечувствительно к регистру)
            if echo "$current_country" | grep -qi "$country"; then
                in_target_country=true
            else
                in_target_country=false
            fi
            continue
        fi
        
        # Проверяем, является ли строка названием города (в кавычках)
        if [[ "$line" =~ ^\"([^\"]+)\"$ ]]; then
            # Это город, пропускаем (используем только для контекста)
            continue
        fi
        
        # Если мы в нужной стране и это строка с релеем
        if [[ "$in_target_country" == true ]] && [[ ! "$line" =~ ^\[.*\]$ ]] && [[ ! "$line" =~ ^\".*\"$ ]]; then
            # Извлекаем имя релея (первое слово) и IP-адрес (последний элемент)
            local relay_name=$(echo "$line" | awk '{print $1}')
            local relay_ip=$(echo "$line" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | tail -1)
            
            if [[ -n "$relay_name" && -n "$relay_ip" ]]; then
                found_relays+=("$relay_name:$relay_ip")
            fi
        fi
    done < "$relays_file"
    
    # Выводим найденные релеи БЕЗ логирования
    if [[ ${#found_relays[@]} -gt 0 ]]; then
        printf '%s\n' "${found_relays[@]}"
        return 0
    fi
    
    return 1
}

# Улучшенная функция поиска релеев с обработкой близких регионов
find_nearest_relays_by_region() {
    local primary_country="$1"
    local relays_file="$2"
    local max_relays="${3:-5}"
    
    if [[ ! -f "$relays_file" ]]; then
        log "ERROR" "Файл релеев не найден: $relays_file" >&2
        return 1
    fi
    
    declare -a found_relays=()
    
    # Шаг 1: Ищем релеи в основной стране
    log "INFO" "Поиск релеев в стране: $primary_country" >&2
    local primary_relays=($(find_relays_by_country_silent "$primary_country" "$relays_file"))
    found_relays+=("${primary_relays[@]}")
    
    # Шаг 2: Если релеев недостаточно, ищем в близких странах
    if [[ ${#found_relays[@]} -lt $max_relays ]]; then
        log "INFO" "Поиск релеев в близких регионах..." >&2
        
        # Определяем близкие страны на основе кода страны
        local nearby_countries=()
        case "$SERVER_COUNTRY_CODE" in
            "RU")
                nearby_countries=("GERMANY" "FRANCE" "NETHERLANDS" "FINLAND" "ESTONIA" "LATVIA" "LITHUANIA" "POLAND" "CZECH REPUBLIC" "AUSTRIA" "SWITZERLAND")
                ;;
            "US")
                nearby_countries=("CANADA" "MEXICO" "UNITED KINGDOM" "GERMANY" "FRANCE" "NETHERLANDS")
                ;;
            "CA")
                nearby_countries=("USA" "UNITED STATES" "UNITED KINGDOM" "GERMANY" "FRANCE" "NETHERLANDS")
                ;;
            "GB"|"UK")
                nearby_countries=("FRANCE" "GERMANY" "NETHERLANDS" "BELGIUM" "IRELAND" "SPAIN" "ITALY")
                ;;
            "DE")
                nearby_countries=("FRANCE" "NETHERLANDS" "AUSTRIA" "SWITZERLAND" "BELGIUM" "POLAND" "CZECH REPUBLIC")
                ;;
            "FR")
                nearby_countries=("GERMANY" "SWITZERLAND" "BELGIUM" "NETHERLANDS" "SPAIN" "ITALY" "UNITED KINGDOM")
                ;;
            "JP")
                nearby_countries=("SINGAPORE" "SOUTH KOREA" "HONG KONG" "TAIWAN" "AUSTRALIA" "GERMANY" "FRANCE" "NETHERLANDS")
                ;;
            "AU")
                nearby_countries=("SINGAPORE" "NEW ZEALAND" "HONG KONG" "JAPAN" "GERMANY" "FRANCE" "NETHERLANDS")
                ;;
            "CN")
                nearby_countries=("SINGAPORE" "HONG KONG" "TAIWAN" "JAPAN" "SOUTH KOREA" "GERMANY" "FRANCE" "NETHERLANDS")
                ;;
            "BR")
                nearby_countries=("ARGENTINA" "CHILE" "MEXICO" "USA" "UNITED STATES" "GERMANY" "FRANCE" "NETHERLANDS")
                ;;
            "IN")
                nearby_countries=("SINGAPORE" "HONG KONG" "GERMANY" "FRANCE" "NETHERLANDS" "UNITED KINGDOM")
                ;;
            *)
                # Глобальные релеи по умолчанию
                nearby_countries=("GERMANY" "FRANCE" "NETHERLANDS" "UNITED KINGDOM" "SINGAPORE" "USA" "UNITED STATES" "CANADA")
                ;;
        esac
        
        # Ищем релеи в близких странах
        for country in "${nearby_countries[@]}"; do
            if [[ ${#found_relays[@]} -ge $max_relays ]]; then
                break
            fi
            
            local nearby_relays=($(find_relays_by_country_silent "$country" "$relays_file"))
            
            if [[ ${#nearby_relays[@]} -gt 0 ]]; then
                log "INFO" "Найдено релеев в стране $country: ${#nearby_relays[@]}" >&2
                found_relays+=("${nearby_relays[@]}")
            fi
        done
    fi
    
    # Шаг 3: Если релеев все еще недостаточно, ищем глобальные релеи
    if [[ ${#found_relays[@]} -lt 2 ]]; then
        log "INFO" "Поиск дополнительных глобальных релеев..." >&2
        
        # Получаем все доступные релеи из файла
        local global_relays=()
        local current_country=""
        
        while IFS= read -r line; do
            # Пропускаем пустые строки и комментарии
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            
            # Проверяем, является ли строка названием страны
            if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
                current_country="${BASH_REMATCH[1]}"
                continue
            fi
            
            # Проверяем, является ли строка названием города
            if [[ "$line" =~ ^\"([^\"]+)\"$ ]]; then
                continue
            fi
            
            # Если это строка с релеем
            if [[ ! "$line" =~ ^\[.*\]$ ]] && [[ ! "$line" =~ ^\".*\"$ ]] && [[ -n "$current_country" ]]; then
                local relay_name=$(echo "$line" | awk '{print $1}')
                local relay_ip=$(echo "$line" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | tail -1)
                
                if [[ -n "$relay_name" && -n "$relay_ip" ]]; then
                    # Проверяем, что этот релей еще не добавлен
                    local already_added=false
                    for existing_relay in "${found_relays[@]}"; do
                        if [[ "$existing_relay" == "$relay_name:$relay_ip" ]]; then
                            already_added=true
                            break
                        fi
                    done
                    
                    if [[ "$already_added" == false ]]; then
                        global_relays+=("$relay_name:$relay_ip")
                        if [[ ${#global_relays[@]} -ge 10 ]]; then
                            break
                        fi
                    fi
                fi
            fi
        done < "$relays_file"
        
        # Добавляем глобальные релеи
        for relay in "${global_relays[@]}"; do
            if [[ ${#found_relays[@]} -ge $max_relays ]]; then
                break
            fi
            found_relays+=("$relay")
        done
    fi
    
    # Выводим результат БЕЗ логирования в stdout
    if [[ ${#found_relays[@]} -gt 0 ]]; then
        printf '%s\n' "${found_relays[@]}"
        log "SUCCESS" "Найдено релеев для региона '$primary_country': ${#found_relays[@]}" >&2
        return 0
    else
        log "ERROR" "Релеи не найдены" >&2
        return 1
    fi
}

# Функция определения геолокации сервера
get_server_geolocation() {
    local retry_count=3
    local timeout=10
    
    log "INFO" "Определение геолокации сервера..."
    
    # Получаем внешний IP адрес
    local external_ip=""
    for attempt in {1..3}; do
        external_ip=$(timeout "$timeout" curl -s https://api.ipify.org || timeout "$timeout" curl -s https://ifconfig.me || timeout "$timeout" wget -qO- https://ipecho.net/plain)
        if [[ -n "$external_ip" && "$external_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            break
        fi
        log "WARN" "Попытка $attempt получения IP адреса неудачна"
        sleep 2
    done
    
    if [[ -z "$external_ip" ]]; then
        log "ERROR" "Не удалось определить внешний IP адрес"
        return 1
    fi
    
    log "INFO" "Внешний IP адрес: $external_ip"
    
    # Запрос к API геолокации
    local geo_response=""
    for attempt in {1..3}; do
        geo_response=$(timeout "$timeout" curl -s "http://ip-api.com/json/$external_ip?fields=status,message,country,countryCode,region,regionName,city" 2>/dev/null)
        if [[ -n "$geo_response" ]]; then
            break
        fi
        log "WARN" "Попытка $attempt запроса геолокации неудачна"
        sleep 2
    done
    
    if [[ -z "$geo_response" ]]; then
        log "ERROR" "Не удалось получить данные геолокации"
        return 1
    fi
    
    # Проверяем статус ответа
    local status=$(echo "$geo_response" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    if [[ "$status" != "success" ]]; then
        local message=$(echo "$geo_response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        log "ERROR" "Ошибка геолокации: $message"
        return 1
    fi
    
    # Извлекаем данные
    local country=$(echo "$geo_response" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
    local country_code=$(echo "$geo_response" | grep -o '"countryCode":"[^"]*"' | cut -d'"' -f4)
    local region=$(echo "$geo_response" | grep -o '"regionName":"[^"]*"' | cut -d'"' -f4)
    local city=$(echo "$geo_response" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
    
    # Выводим результат
    safe_echo "\n${GREEN}Геолокация сервера:${NC}"
    echo "  IP адрес: $external_ip"
    echo "  Страна: $country ($country_code)"
    echo "  Регион: $region"
    echo "  Город: $city"
    
    # Сохраняем в глобальные переменные
    export SERVER_IP="$external_ip"
    export SERVER_COUNTRY="$country"
    export SERVER_COUNTRY_CODE="$country_code"
    export SERVER_REGION="$region"
    export SERVER_CITY="$city"
    
    return 0
}

# Функция загрузки списков серверов и релеев (обновлена для нового формата)
download_dns_lists() {
    local temp_dir="/tmp/dnscrypt_lists"
    mkdir -p "$temp_dir"
    
    log "INFO" "Загрузка актуальных списков серверов и релеев..."
    
    # URL для загрузки (обновлены под новый формат)
    local servers_url="https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/lib/DNSCrypt_servers.txt"
    local relays_url="https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/lib/DNSCrypt_relay.txt"
    
    # Загружаем серверы
    if ! timeout 30 curl -s -o "$temp_dir/servers.txt" "$servers_url"; then
        log "ERROR" "Не удалось загрузить список серверов"
        return 1
    fi
    
    # Загружаем релеи
    if ! timeout 30 curl -s -o "$temp_dir/relays.txt" "$relays_url"; then
        log "ERROR" "Не удалось загрузить список релеев"
        return 1
    fi
    
    # Проверяем размер файлов
    if [[ ! -s "$temp_dir/servers.txt" ]] || [[ ! -s "$temp_dir/relays.txt" ]]; then
        log "ERROR" "Загруженные файлы пусты"
        return 1
    fi
    
    # Проверяем формат файлов (новый формат)
    if ! grep -q '^\[.*\]$' "$temp_dir/servers.txt"; then
        log "WARN" "Файл серверов может быть в старом формате"
    fi
    
    if ! grep -q '^\[.*\]$' "$temp_dir/relays.txt"; then
        log "WARN" "Файл релеев может быть в старом формате"
    fi
    
    log "SUCCESS" "Списки серверов и релеев успешно загружены"
    export DNS_SERVERS_FILE="$temp_dir/servers.txt"
    export DNS_RELAYS_FILE="$temp_dir/relays.txt"
    
    return 0
}

# Функция проверки времени отклика
test_ping_latency() {
    local host="$1"
    local timeout="${2:-5}"
    
    # Проверяем доступность ping
    if ! command -v ping >/dev/null 2>&1; then
        echo "999"
        return 1
    fi
    
    # Выполняем ping
    local result=$(ping -c 3 -W "$timeout" "$host" 2>/dev/null | grep 'avg' | awk -F'/' '{print $5}' | cut -d'.' -f1)
    
    if [[ -n "$result" && "$result" =~ ^[0-9]+$ ]]; then
        echo "$result"
        return 0
    else
        echo "999"
        return 1
    fi
}

# Функция выбора серверов и релеев по региону (обновленная)
configure_regional_anonymized_dns() {
    safe_echo "\n${BLUE}=== АВТОМАТИЧЕСКАЯ НАСТРОЙКА АНОНИМНОГО DNS ПО РЕГИОНУ ===${NC}"
    echo
    safe_echo "${YELLOW}Эта функция автоматически настроит анонимный DNS на основе вашего региона.${NC}"
    echo "Будет определено местоположение сервера и выбраны оптимальные серверы и релеи."
    echo
    
    # Подтверждение
    read -p "Продолжить автоматическую настройку? (y/n): " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        log "INFO" "Автоматическая настройка отменена"
        return 0
    fi
    
    # Шаг 1: Определение геолокации
    if ! get_server_geolocation; then
        log "ERROR" "Не удалось определить геолокацию сервера"
        return 1
    fi
    
    # Шаг 2: Загрузка списков
    if ! download_dns_lists; then
        log "ERROR" "Не удалось загрузить списки серверов и релеев"
        return 1
    fi
    
    # Шаг 3: Выбор основного сервера
    safe_echo "\n${BLUE}Выбор основного DNS-сервера:${NC}"
    echo "1) Использовать рекомендуемый Quad9 сервер (quad9-dnscrypt-ip4-filter-ecs-pri)"
    echo "2) Автоматически выбрать локальный сервер из страны: $SERVER_COUNTRY"
    echo "0) Отмена"
    
    read -p "Выберите опцию (0-2): " server_choice
    
    local selected_server=""
    case $server_choice in
        1)
            selected_server="quad9-dnscrypt-ip4-filter-ecs-pri"
            log "INFO" "Выбран сервер Quad9: $selected_server"
            ;;
        2)
            # Поиск серверов в стране
            safe_echo "\n${BLUE}Поиск серверов в стране: $SERVER_COUNTRY${NC}"
            
            local servers_in_country=($(find_servers_by_country "$SERVER_COUNTRY" "$DNS_SERVERS_FILE"))
            
            if [[ ${#servers_in_country[@]} -eq 0 ]]; then
                log "WARN" "Серверы в стране $SERVER_COUNTRY не найдены"
                safe_echo "${YELLOW}Будет использован Quad9 сервер по умолчанию${NC}"
                selected_server="quad9-dnscrypt-ip4-filter-ecs-pri"
            else
                safe_echo "${GREEN}Найдено серверов: ${#servers_in_country[@]}${NC}"
                
                # Выбираем самый быстрый сервер
                selected_server=$(select_fastest_server "${servers_in_country[@]}")
                
                if [[ -z "$selected_server" ]]; then
                    log "WARN" "Не удалось определить быстрый сервер, используем Quad9"
                    selected_server="quad9-dnscrypt-ip4-filter-ecs-pri"
                fi
            fi
            ;;
        0)
            log "INFO" "Настройка отменена"
            return 0
            ;;
        *)
            log "ERROR" "Неверный выбор"
            return 1
            ;;
    esac
    
    # Шаг 4: Улучшенный поиск релеев
    safe_echo "\n${BLUE}Поиск релеев для анонимизации...${NC}"
    
    # Используем улучшенную функцию поиска релеев
    local relays_in_region=($(find_nearest_relays_by_region "$SERVER_COUNTRY" "$DNS_RELAYS_FILE" 10))
    
    if [[ ${#relays_in_region[@]} -eq 0 ]]; then
        log "ERROR" "Не найдены подходящие релеи для анонимизации"
        safe_echo "${RED}Возможные причины:${NC}"
        echo "  - Проблемы с загрузкой списка релеев"
        echo "  - Сетевые проблемы"
        echo "  - Неправильный формат файла релеев"
        echo
        safe_echo "${YELLOW}Попробуйте:${NC}"
        echo "  1. Перезапустить скрипт"
        echo "  2. Проверить подключение к интернету"
        echo "  3. Использовать ручную настройку (пункт 3 главного меню)"
        return 1
    fi
    
    safe_echo "${GREEN}Найдено релеев для анонимизации: ${#relays_in_region[@]}${NC}"
    
    # Показываем найденные релеи
    safe_echo "\n${BLUE}Найденные релеи:${NC}"
    for ((i=0; i<${#relays_in_region[@]} && i<10; i++)); do
        local relay_data="${relays_in_region[i]}"
        local relay_name="${relay_data%:*}"
        local relay_ip="${relay_data#*:}"
        echo "  $((i+1)). $relay_name ($relay_ip)"
    done
    
    # Тестируем скорость релеев и выбираем лучшие
    safe_echo "\n${BLUE}Тестирование скорости релеев...${NC}"
    local sorted_relays=($(sort_relays_by_speed "${relays_in_region[@]}"))
    
    # Берем топ-3 релея
    local selected_relays=()
    local max_relays=3
    for (( i=0; i<${#sorted_relays[@]} && i<$max_relays; i++ )); do
        selected_relays+=("${sorted_relays[i]}")
    done
    
    if [[ ${#selected_relays[@]} -eq 0 ]]; then
        log "ERROR" "Не удалось выбрать быстрые релеи"
        return 1
    fi
    
    # Шаг 5: Применение конфигурации
    safe_echo "\n${BLUE}Применение конфигурации:${NC}"
    echo "  Основной сервер: $selected_server"
    echo "  Релеи для анонимизации:"
    for relay in "${selected_relays[@]}"; do
        echo "    - $relay"
    done
    echo
    
    read -p "Применить эту конфигурацию? (y/n): " apply_confirm
    if [[ "${apply_confirm,,}" != "y" ]]; then
        log "INFO" "Конфигурация не применена"
        return 0
    fi
    
    # Создаем резервную копию
    backup_config "$DNSCRYPT_CONFIG" "dnscrypt-config-before-regional"
    
    # Активируем секцию anonymized_dns
    enable_anonymized_dns_section
    
    # Настраиваем server_names
    sed -i "s/^server_names = .*/server_names = ['$selected_server']/" "$DNSCRYPT_CONFIG"
    
    # Настраиваем маршруты
    local relays_formatted=""
    for relay in "${selected_relays[@]}"; do
        local relay_name="${relay%:*}"
        if [[ -n "$relays_formatted" ]]; then
            relays_formatted+=", "
        fi
        relays_formatted+="'$relay_name'"
    done
    
    local route_config="routes = [
    { server_name='$selected_server', via=[$relays_formatted] }
]"
    
    # Заменяем секцию routes
    if grep -q "routes = \[" "$DNSCRYPT_CONFIG"; then
        sed -i "/routes = \[/,/\]/c\\$route_config" "$DNSCRYPT_CONFIG"
    else
        # Добавляем routes в секцию anonymized_dns
        sed -i "/^\[anonymized_dns\]/a\\$route_config" "$DNSCRYPT_CONFIG"
    fi
    
    # Включаем skip_incompatible
    add_config_option "$DNSCRYPT_CONFIG" "anonymized_dns" "skip_incompatible" "true"
    
    # Перезапускаем службу
    log "INFO" "Перезапуск DNSCrypt-proxy для применения изменений..."
    if restart_service "$DNSCRYPT_SERVICE"; then
        safe_echo "\n${GREEN}=== НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО ===${NC}"
        echo
        safe_echo "${BLUE}Конфигурация анонимного DNS:${NC}"
        echo "  ✅ Основной сервер: $selected_server"
        echo "  ✅ Количество релеев: ${#selected_relays[@]}"
        echo "  ✅ Страна сервера: $SERVER_COUNTRY"
        echo "  ✅ Анонимизация активна"
        echo
        safe_echo "${YELLOW}Рекомендации:${NC}"
        echo "  • Проверьте работу DNS: dig @127.0.0.1 google.com"
        echo "  • Проверьте логи: journalctl -u dnscrypt-proxy -f"
        echo "  • При проблемах используйте пункт 'Исправить конфигурацию'"
        
        log "SUCCESS" "Региональная настройка анонимного DNS завершена"
    else
        log "ERROR" "Ошибка при перезапуске службы"
        return 1
    fi
    
    # Очистка временных файлов
    rm -rf "/tmp/dnscrypt_lists" 2>/dev/null
    
    return 0
}

# Функция для отображения серверов по странам (новый формат)
display_servers_by_region() {
    local servers_file="${1:-$DNS_SERVERS_FILE}"
    
    if [[ ! -f "$servers_file" ]]; then
        if [[ -f "$SCRIPT_DIR/lib/DNSCrypt_servers.txt" ]]; then
            servers_file="$SCRIPT_DIR/lib/DNSCrypt_servers.txt"
        else
            log "ERROR" "Файл серверов не найден"
            return 1
        fi
    fi
    
    safe_echo "\n${BLUE}Доступные DNS-серверы по регионам:${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    local current_country=""
    local current_city=""
    local server_count=0
    
    while IFS= read -r line; do
        # Пропускаем пустые строки и комментарии
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Проверяем, является ли строка названием страны
        if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
            current_country="${BASH_REMATCH[1]}"
            safe_echo "\n${GREEN}🌍 $current_country${NC}"
            continue
        fi
        
        # Проверяем, является ли строка названием города
        if [[ "$line" =~ ^\"([^\"]+)\"$ ]]; then
            current_city="${BASH_REMATCH[1]}"
            safe_echo "  ${YELLOW}📍 $current_city${NC}"
            continue
        fi
        
        # Если это строка с сервером
        if [[ ! "$line" =~ ^\[.*\]$ ]] && [[ ! "$line" =~ ^\".*\"$ ]] && [[ -n "$current_country" ]]; then
            local server_name=$(echo "$line" | awk '{print $1}')
            local server_ip=$(echo "$line" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | tail -1)
            local features=$(echo "$line" | awk '{for(i=2;i<=NF-1;i++) printf "%s ", $i; print ""}' | sed 's/| /|/g')
            
            if [[ -n "$server_name" && -n "$server_ip" ]]; then
                echo "    🔸 $server_name ($server_ip)"
                echo "       $features"
                ((server_count++))
            fi
        fi
    done < "$servers_file"
    
    echo "════════════════════════════════════════════════════════════════"
    safe_echo "${CYAN}Всего серверов: $server_count${NC}"
}

# Функция для отображения релеев по странам (новый формат)
display_relays_by_region() {
    local relays_file="${1:-$DNS_RELAYS_FILE}"
    
    if [[ ! -f "$relays_file" ]]; then
        if [[ -f "$SCRIPT_DIR/lib/DNSCrypt_relay.txt" ]]; then
            relays_file="$SCRIPT_DIR/lib/DNSCrypt_relay.txt"
        else
            log "ERROR" "Файл релеев не найден"
            return 1
        fi
    fi
    
    safe_echo "\n${BLUE}Доступные DNS-релеи по регионам:${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    local current_country=""
    local current_city=""
    local relay_count=0
    
    while IFS= read -r line; do
        # Пропускаем пустые строки и комментарии
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Проверяем, является ли строка названием страны
        if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
            current_country="${BASH_REMATCH[1]}"
            safe_echo "\n${GREEN}🌍 $current_country${NC}"
            continue
        fi
        
        # Проверяем, является ли строка названием города
        if [[ "$line" =~ ^\"([^\"]+)\"$ ]]; then
            current_city="${BASH_REMATCH[1]}"
            safe_echo "  ${YELLOW}📍 $current_city${NC}"
            continue
        fi
        
        # Если это строка с релеем
        if [[ ! "$line" =~ ^\[.*\]$ ]] && [[ ! "$line" =~ ^\".*\"$ ]] && [[ -n "$current_country" ]]; then
            local relay_name=$(echo "$line" | awk '{print $1}')
            local relay_ip=$(echo "$line" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | tail -1)
            local features=$(echo "$line" | awk '{for(i=2;i<=NF-1;i++) printf "%s ", $i; print ""}')
            
            if [[ -n "$relay_name" && -n "$relay_ip" ]]; then
                echo "    🔸 $relay_name ($relay_ip)"
                echo "       $features"
                ((relay_count++))
            fi
        fi
    done < "$relays_file"
    
    echo "════════════════════════════════════════════════════════════════"
    safe_echo "${CYAN}Всего релеев: $relay_count${NC}"
}

# Функция для поиска серверов по ключевым словам (новый формат)
search_servers() {
    local search_term="$1"
    local servers_file="${2:-$DNS_SERVERS_FILE}"
    
    if [[ -z "$search_term" ]]; then
        read -p "Введите поисковый запрос (страна, город или имя сервера): " search_term
    fi
    
    if [[ -z "$search_term" ]]; then
        log "ERROR" "Поисковый запрос не может быть пустым"
        return 1
    fi
    
    if [[ ! -f "$servers_file" ]]; then
        if [[ -f "$SCRIPT_DIR/lib/DNSCrypt_servers.txt" ]]; then
            servers_file="$SCRIPT_DIR/lib/DNSCrypt_servers.txt"
        else
            log "ERROR" "Файл серверов не найден"
            return 1
        fi
    fi
    
    safe_echo "\n${BLUE}Результаты поиска серверов по запросу: '$search_term'${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    local current_country=""
    local current_city=""
    local found_count=0
    local match_context=""
    
    while IFS= read -r line; do
        # Пропускаем пустые строки и комментарии
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Проверяем, является ли строка названием страны
        if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
            current_country="${BASH_REMATCH[1]}"
            if echo "$current_country" | grep -qi "$search_term"; then
                match_context="country"
            else
                match_context=""
            fi
            continue
        fi
        
        # Проверяем, является ли строка названием города
        if [[ "$line" =~ ^\"([^\"]+)\"$ ]]; then
            current_city="${BASH_REMATCH[1]}"
            if echo "$current_city" | grep -qi "$search_term"; then
                match_context="city"
            elif [[ "$match_context" != "country" ]]; then
                match_context=""
            fi
            continue
        fi
        
        # Если это строка с сервером
        if [[ ! "$line" =~ ^\[.*\]$ ]] && [[ ! "$line" =~ ^\".*\"$ ]] && [[ -n "$current_country" ]]; then
            local server_name=$(echo "$line" | awk '{print $1}')
            local server_ip=$(echo "$line" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | tail -1)
            local features=$(echo "$line" | awk '{for(i=2;i<=NF-1;i++) printf "%s ", $i; print ""}')
            
            # Проверяем совпадения
            local show_server=false
            if [[ "$match_context" == "country" ]] || [[ "$match_context" == "city" ]]; then
                show_server=true
            elif echo "$server_name" | grep -qi "$search_term"; then
                show_server=true
            elif echo "$features" | grep -qi "$search_term"; then
                show_server=true
            fi
            
            if [[ "$show_server" == true && -n "$server_name" && -n "$server_ip" ]]; then
                safe_echo "\n${GREEN}🌍 $current_country${NC} ${YELLOW}📍 $current_city${NC}"
                echo "    🔸 $server_name ($server_ip)"
                echo "       $features"
                ((found_count++))
            fi
        fi
    done < "$servers_file"
    
    echo "════════════════════════════════════════════════════════════════"
    if [[ $found_count -eq 0 ]]; then
        safe_echo "${YELLOW}По запросу '$search_term' серверы не найдены${NC}"
    else
        safe_echo "${CYAN}Найдено серверов: $found_count${NC}"
    fi
}

# Функция для поиска релеев по ключевым словам (новый формат)
search_relays() {
    local search_term="$1"
    local relays_file="${2:-$DNS_RELAYS_FILE}"
    
    if [[ -z "$search_term" ]]; then
        read -p "Введите поисковый запрос (страна, город или имя релея): " search_term
    fi
    
    if [[ -z "$search_term" ]]; then
        log "ERROR" "Поисковый запрос не может быть пустым"
        return 1
    fi
    
    if [[ ! -f "$relays_file" ]]; then
        if [[ -f "$SCRIPT_DIR/lib/DNSCrypt_relay.txt" ]]; then
            relays_file="$SCRIPT_DIR/lib/DNSCrypt_relay.txt"
        else
            log "ERROR" "Файл релеев не найден"
            return 1
        fi
    fi
    
    safe_echo "\n${BLUE}Результаты поиска релеев по запросу: '$search_term'${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    local current_country=""
    local current_city=""
    local found_count=0
    local match_context=""
    
    while IFS= read -r line; do
        # Пропускаем пустые строки и комментарии
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Проверяем, является ли строка названием страны
        if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
            current_country="${BASH_REMATCH[1]}"
            if echo "$current_country" | grep -qi "$search_term"; then
                match_context="country"
            else
                match_context=""
            fi
            continue
        fi
        
        # Проверяем, является ли строка названием города
        if [[ "$line" =~ ^\"([^\"]+)\"$ ]]; then
            current_city="${BASH_REMATCH[1]}"
            if echo "$current_city" | grep -qi "$search_term"; then
                match_context="city"
            elif [[ "$match_context" != "country" ]]; then
                match_context=""
            fi
            continue
        fi
        
        # Если это строка с релеем
        if [[ ! "$line" =~ ^\[.*\]$ ]] && [[ ! "$line" =~ ^\".*\"$ ]] && [[ -n "$current_country" ]]; then
            local relay_name=$(echo "$line" | awk '{print $1}')
            local relay_ip=$(echo "$line" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | tail -1)
            local features=$(echo "$line" | awk '{for(i=2;i<=NF-1;i++) printf "%s ", $i; print ""}')
            
            # Проверяем совпадения
            local show_relay=false
            if [[ "$match_context" == "country" ]] || [[ "$match_context" == "city" ]]; then
                show_relay=true
            elif echo "$relay_name" | grep -qi "$search_term"; then
                show_relay=true
            elif echo "$features" | grep -qi "$search_term"; then
                show_relay=true
            fi
            
            if [[ "$show_relay" == true && -n "$relay_name" && -n "$relay_ip" ]]; then
                safe_echo "\n${GREEN}🌍 $current_country${NC} ${YELLOW}📍 $current_city${NC}"
                echo "    🔗 $relay_name ($relay_ip)"
                echo "       $features"
                ((found_count++))
            fi
        fi
    done < "$relays_file"
    
    echo "════════════════════════════════════════════════════════════════"
    if [[ $found_count -eq 0 ]]; then
        safe_echo "${YELLOW}По запросу '$search_term' релеи не найдены${NC}"
    else
        safe_echo "${CYAN}Найдено релеев: $found_count${NC}"
    fi
}

# Функция для интерактивного выбора серверов из списка
interactive_server_selection() {
    local servers_file="${1:-$DNS_SERVERS_FILE}"
    
    if [[ ! -f "$servers_file" ]]; then
        if [[ -f "$SCRIPT_DIR/lib/DNSCrypt_servers.txt" ]]; then
            servers_file="$SCRIPT_DIR/lib/DNSCrypt_servers.txt"
        else
            log "ERROR" "Файл серверов не найден"
            return 1
        fi
    fi
    
    safe_echo "\n${BLUE}Интерактивный выбор DNS-серверов:${NC}"
    echo "1) Показать все серверы по регионам"
    echo "2) Поиск серверов"
    echo "3) Показать серверы конкретной страны"
    echo "4) Показать рекомендуемые серверы"
    echo "0) Назад"
    
    read -p "Выберите опцию (0-4): " selection_option
    
    case $selection_option in
        1)
            display_servers_by_region "$servers_file"
            ;;
        2)
            search_servers "" "$servers_file"
            ;;
        3)
            safe_echo "\n${BLUE}Доступные страны:${NC}"
            grep '^\[.*\]$' "$servers_file" | sed 's/^\[\(.*\)\]$/  \1/' | sort | uniq | nl
            echo
            read -p "Введите название страны: " country_name
            if [[ -n "$country_name" ]]; then
                find_servers_by_country "$country_name" "$servers_file"
            fi
            ;;
        4)
            safe_echo "\n${BLUE}Рекомендуемые DNS-серверы:${NC}"
            echo "🔸 quad9-dnscrypt-ip4-filter-pri (Quad9 с фильтрацией)"
            echo "🔸 quad9-dnscrypt-ip4-nofilter-pri (Quad9 без фильтрации)"
            echo "🔸 cloudflare (Cloudflare DNS)"
            echo "🔸 google (Google DNS)"
            ;;
        0)
            return 0
            ;;
        *)
            log "ERROR" "Неверный выбор"
            return 1
            ;;
    esac
    
    read -p "Нажмите Enter для продолжения..."
    return 0
}

# Новое подменю для просмотра серверов и релеев
show_servers_and_relays_menu() {
    while true; do
        safe_echo "\n${BLUE}=== ПРОСМОТР СЕРВЕРОВ И РЕЛЕЕВ ===${NC}"
        echo "1) Показать DNS-серверы по регионам"
        echo "2) Показать DNS-релеи по регионам"
        echo "3) Поиск DNS-серверов"
        echo "4) Поиск DNS-релеев"
        echo "5) Интерактивный выбор серверов"
        echo "6) Загрузить свежие списки из интернета"
        echo "7) Показать статистику серверов"
        echo "0) Назад в главное меню"
        
        read -p "Выберите опцию (0-7): " submenu_option
        
        case $submenu_option in
            1)
                display_servers_by_region
                ;;
            2)
                display_relays_by_region
                ;;
            3)
                search_servers
                ;;
            4)
                search_relays
                ;;
            5)
                interactive_server_selection
                ;;
            6)
                if download_dns_lists; then
                    log "SUCCESS" "Списки серверов и релеев обновлены"
                else
                    log "ERROR" "Не удалось обновить списки"
                fi
                ;;
            7)
                show_servers_statistics
                ;;
            0)
                return 0
                ;;
            *)
                log "ERROR" "Неверный выбор"
                ;;
        esac
        
        echo
        read -p "Нажмите Enter для продолжения..."
    done
}

# Функция для функций активации секции anonymized_dns (если отсутствует)
enable_anonymized_dns_section() {
    log "INFO" "Активация секции [anonymized_dns]..."
    
    # Проверяем, активна ли уже секция
    if grep -q "^\[anonymized_dns\]" "$DNSCRYPT_CONFIG"; then
        log "INFO" "Секция [anonymized_dns] уже активна"
        return 0
    fi
    
    # Проверяем, есть ли закомментированная секция
    if grep -q "^#\[anonymized_dns\]" "$DNSCRYPT_CONFIG"; then
        # Раскомментируем секцию и базовые настройки
        sed -i 's/^#\[anonymized_dns\]/[anonymized_dns]/' "$DNSCRYPT_CONFIG"
        sed -i '/^\[anonymized_dns\]/,/^$/s/^#routes = \[/routes = [/' "$DNSCRYPT_CONFIG"
        sed -i '/^\[anonymized_dns\]/,/^$/s/^#skip_incompatible = false/skip_incompatible = true/' "$DNSCRYPT_CONFIG"
        log "SUCCESS" "Секция [anonymized_dns] активирована"
    else
        # Добавляем новую секцию в конец файла
        configure_anonymized_dns
    fi
    
    return 0
}

# Функция настройки маршрутов для Anonymized DNSCrypt (если отсутствует)
configure_anonymized_routes() {
    log "INFO" "Настройка маршрутов для Anonymized DNSCrypt..."
    
    # Убеждаемся, что секция активна
    enable_anonymized_dns_section
    
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

# Функция настройки дополнительной конфигурации анонимного DNS (если отсутствует)
configure_additional_anon_settings() {
    safe_echo "\n${BLUE}Дополнительные настройки анонимного DNS:${NC}"
    echo "1) Настройка пропуска несовместимых серверов"
    echo "2) Настройка логирования и отладки"
    echo "3) Настройка прямого получения сертификатов"
    echo "0) Отмена"
    
    read -p "Выберите опцию (0-3): " additional_option
    
    case $additional_option in
        1)
            # Настройка пропуска несовместимых серверов
            safe_echo "\n${BLUE}Пропуск несовместимых серверов:${NC}"
            echo "Если включено, серверы несовместимые с анонимизацией будут пропускаться"
            echo "вместо использования прямого подключения к ним."
            
            read -p "Включить пропуск несовместимых серверов? (y/n): " skip_incompatible
            
            enable_anonymized_dns_section
            
            if [[ "${skip_incompatible,,}" == "y" ]]; then
                add_config_option "$DNSCRYPT_CONFIG" "anonymized_dns" "skip_incompatible" "true"
                log "SUCCESS" "Пропуск несовместимых серверов включен"
            else
                add_config_option "$DNSCRYPT_CONFIG" "anonymized_dns" "skip_incompatible" "false"
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
        3)
            # Настройка прямого получения сертификатов
            safe_echo "\n${BLUE}Прямое получение сертификатов:${NC}"
            echo "Если включено, для несовместимых серверов публичные сертификаты"
            echo "будут получены напрямую, но сами запросы все равно пойдут через релеи."
            
            read -p "Включить прямое получение сертификатов? (y/n): " direct_cert_fallback
            
            enable_anonymized_dns_section
            
            if [[ "${direct_cert_fallback,,}" == "y" ]]; then
                add_config_option "$DNSCRYPT_CONFIG" "anonymized_dns" "direct_cert_fallback" "true"
                log "SUCCESS" "Прямое получение сертификатов включено"
            else
                add_config_option "$DNSCRYPT_CONFIG" "anonymized_dns" "direct_cert_fallback" "false"
                log "SUCCESS" "Прямое получение сертификатов отключено"
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

# Функция исправления конфигурации анонимного DNS (если отсутствует)
fix_anonymized_dns_config() {
    log "INFO" "Проверка и исправление конфигурации анонимного DNS..."
    
    safe_echo "\n${BLUE}Проверка настроек анонимного DNS:${NC}"
    
    # Проверка наличия источника релеев
    if ! grep -q "\[sources.relays\]" "$DNSCRYPT_CONFIG" && ! grep -q "\[sources.'relays'\]" "$DNSCRYPT_CONFIG"; then
        log "WARN" "Источник релеев не найден. Добавление..."
        add_relays_source
    else
        log "SUCCESS" "Источник релеев настроен"
    fi
    
    # Проверка включения DNSCrypt-серверов
    if ! grep -q "dnscrypt_servers = true" "$DNSCRYPT_CONFIG"; then
        log "WARN" "DNSCrypt-серверы не включены. Исправление..."
        add_config_option "$DNSCRYPT_CONFIG" "" "dnscrypt_servers" "true"
    else
        log "SUCCESS" "DNSCrypt-серверы включены"
    fi
    
    # Проверка секции anonymized_dns
    if ! grep -q "^\[anonymized_dns\]" "$DNSCRYPT_CONFIG"; then
        log "WARN" "Секция [anonymized_dns] не активна. Исправление..."
        enable_anonymized_dns_section
    else
        log "SUCCESS" "Секция [anonymized_dns] активна"
    fi
    
    # Проверка маршрутов
    if ! grep -A 10 "\[anonymized_dns\]" "$DNSCRYPT_CONFIG" | grep -q "routes.*="; then
        log "WARN" "Маршруты не настроены. Добавление базового маршрута..."
        add_route_to_config "{ server_name='*', via=['*'] }"
        log "INFO" "Добавлен базовый маршрут с автоматическим выбором релеев"
    else
        log "SUCCESS" "Маршруты настроены"
    fi
    
    log "SUCCESS" "Проверка конфигурации анонимного DNS завершена"
    
    # Перезапуск службы
    restart_service "$DNSCRYPT_SERVICE"
    
    return 0
}

# Функции для ручной настройки маршрутов (если отсутствуют)
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
    local routes_content=""
    local continue_adding="y"
    local first_route=true
    
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
        
        if [ "$first_route" = false ]; then
            routes_content+=",\n"
        fi
        
        routes_content+="    { server_name='$server_name', via=[$relays] }"
        first_route=false
        
        safe_echo "\n${YELLOW}Добавить еще один маршрут? (y/n):${NC}"
        read -p "> " continue_adding
    done
    
    # Обновляем маршруты в конфигурации с правильным форматированием
    local new_routes_section="routes = [\n$routes_content\n]"
    
    # Заменяем секцию routes
    sed -i "/routes = \[/,/\]/c\\$new_routes_section" "$DNSCRYPT_CONFIG"
    
    log "SUCCESS" "Все маршруты успешно заменены"
}

# Функции из anonymized_dns.sh (если они не подключены)
update_anonymized_routes() {
    local route="$1"
    
    log "INFO" "Обновление маршрутов в конфигурации"
    
    # Обновляем маршруты в конфигурации с правильным форматированием
    local new_routes="routes = [\n    $route\n]"
    
    # Находим секцию anonymized_dns и заменяем маршруты
    if grep -q "^\[anonymized_dns\]" "$DNSCRYPT_CONFIG"; then
        # Заменяем существующие маршруты
        sed -i "/\[anonymized_dns\]/,/^\[/{/routes\s*=/,/\]/c\\$new_routes
        }" "$DNSCRYPT_CONFIG"
    else
        log "ERROR" "Секция [anonymized_dns] не найдена"
        return 1
    fi
    
    log "SUCCESS" "Маршруты успешно обновлены"
    return 0
}

add_route_to_config() {
    local new_route="$1"
    
    log "INFO" "Добавление маршрута: $new_route"
    
    # Проверяем, есть ли уже маршруты и активна ли секция
    if grep -q "^\[anonymized_dns\]" "$DNSCRYPT_CONFIG"; then
        # Секция есть, проверяем маршруты
        if grep -A 20 "\[anonymized_dns\]" "$DNSCRYPT_CONFIG" | grep -q "routes\s*=\s*\[\s*\]"; then
            # Пустой массив маршрутов, заменяем его
            sed -i "/\[anonymized_dns\]/,/^\[/s/routes\s*=\s*\[\s*\]/routes = [\n    $new_route\n]/" "$DNSCRYPT_CONFIG"
        elif grep -A 20 "\[anonymized_dns\]" "$DNSCRYPT_CONFIG" | grep -q "routes\s*=\s*\["; then
            # Уже есть маршруты, добавляем новый перед закрывающей скобкой
            sed -i "/\[anonymized_dns\]/,/^\[/{/\]/i\    $new_route,
            }" "$DNSCRYPT_CONFIG"
        else
            # Нет маршрутов в секции, добавляем
            sed -i "/\[anonymized_dns\]/a routes = [\n    $new_route\n]" "$DNSCRYPT_CONFIG"
        fi
    else
        log "ERROR" "Секция [anonymized_dns] не найдена. Используйте enable_anonymized_dns_section сначала."
        return 1
    fi
    
    log "SUCCESS" "Маршрут успешно добавлен"
    return 0
}

add_relays_source() {
    log "INFO" "Добавление источника релеев для Anonymized DNSCrypt..."
    
    # Проверяем, есть ли уже источник релеев (в разных форматах)
    if grep -q "\[sources.relays\]" "$DNSCRYPT_CONFIG" || grep -q "\[sources.'relays'\]" "$DNSCRYPT_CONFIG"; then
        log "INFO" "Источник релеев уже настроен"
        return 0
    fi
    
    # Находим секцию [sources]
    local sources_line=$(grep -n "\[sources\]" "$DNSCRYPT_CONFIG" | cut -d':' -f1)
    
    if [ -n "$sources_line" ]; then
        # Добавляем после последней [sources.*] секции
        local last_sources_line=$(grep -n "\[sources\." "$DNSCRYPT_CONFIG" | tail -n1 | cut -d':' -f1)
        
        if [ -n "$last_sources_line" ]; then
            # Найдем конец последней секции sources
            local insert_line=$((last_sources_line + 8)) # После типичной секции sources
        else
            local insert_line=$((sources_line + 1))
        fi
        
        # Добавляем конфигурацию источника релеев
        sed -i "${insert_line}i\\
\\
### Anonymized DNS relays\\
\\
[sources.relays]\\
urls = [\\
  'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/relays.md',\\
  'https://download.dnscrypt.info/resolvers-list/v3/relays.md',\\
]\\
cache_file = 'relays.md'\\
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'\\
refresh_delay = 73\\
prefix = ''" "$DNSCRYPT_CONFIG"
        
        log "SUCCESS" "${GREEN}Источник релеев успешно добавлен${NC}"
    else
        log "ERROR" "${RED}Секция [sources] не найдена в конфигурационном файле${NC}"
        return 1
    fi
    
    return 0
}

# Функции для выбора быстрых серверов и релеев
select_fastest_server() {
    local servers=("$@")
    local fastest_server=""
    local best_ping=999
    
    log "INFO" "Тестирование скорости серверов..."
    
    for server_data in "${servers[@]}"; do
        local server_name="${server_data%:*}"
        local server_ip="${server_data#*:}"
        
        safe_echo "  Тестирование $server_name ($server_ip)..."
        local ping_result=$(test_ping_latency "$server_ip" 3)
        
        if [[ "$ping_result" != "999" && "$ping_result" -lt "$best_ping" ]]; then
            best_ping="$ping_result"
            fastest_server="$server_name"
        fi
        
        safe_echo "    Пинг: ${ping_result}ms"
    done
    
    if [[ -n "$fastest_server" ]]; then
        log "SUCCESS" "Выбран сервер: $fastest_server (пинг: ${best_ping}ms)"
        echo "$fastest_server"
        return 0
    else
        log "ERROR" "Не удалось найти доступный сервер"
        return 1
    fi
}

sort_relays_by_speed() {
    local relays=("$@")
    declare -a relay_speeds=()
    
    log "INFO" "Тестирование скорости релеев..."
    
    # Тестируем каждый релей
    for relay_data in "${relays[@]}"; do
        local relay_name="${relay_data%:*}"
        local relay_ip="${relay_data#*:}"
        
        safe_echo "  Тестирование $relay_name ($relay_ip)..."
        local ping_result=$(test_ping_latency "$relay_ip" 3)
        
        relay_speeds+=("$ping_result:$relay_name")
        safe_echo "    Пинг: ${ping_result}ms"
    done
    
    # Сортируем по скорости
    local sorted_relays=($(printf '%s\n' "${relay_speeds[@]}" | sort -n | cut -d':' -f2))
    
    # Выводим отсортированный список
    printf '%s\n' "${sorted_relays[@]}"
    return 0
}

# Добавляем новый пункт в главное меню
main_menu() {
    while true; do
        print_header "УПРАВЛЕНИЕ АНОНИМНЫМ DNS"
        echo "1) Проверить текущую конфигурацию анонимного DNS"
        echo "2) Настроить Anonymized DNSCrypt"
        echo "3) Настроить маршруты для анонимизации"
        echo "4) Тестировать время отклика серверов"
        echo "5) Дополнительные настройки анонимизации"
        echo "6) Исправить конфигурацию анонимного DNS"
        echo "7) Перезапустить DNSCrypt-proxy"
        safe_echo "${GREEN}8) 🌍 Автоматическая настройка по региону${NC}"
        safe_echo "${CYAN}9) 📋 Просмотр серверов и релеев${NC}"
        echo "0) Выход"
        
        read -p "Выберите опцию (0-9): " option
        
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
                configure_anonymized_routes
                ;;
            4)
                test_server_latency
                ;;
            5)
                backup_config "$DNSCRYPT_CONFIG" "dnscrypt-config"
                configure_additional_anon_settings
                ;;
            6)
                backup_config "$DNSCRYPT_CONFIG" "dnscrypt-config"
                fix_anonymized_dns_config
                ;;
            7)
                restart_service "$DNSCRYPT_SERVICE"
                ;;
            8)
                configure_regional_anonymized_dns
                ;;
            9)
                show_servers_and_relays_menu
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