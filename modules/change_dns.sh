#!/bin/bash
# modules/change_dns.sh - Модуль для изменения DNS-серверов и настроек DNSCrypt
# Создано: 2025-06-24
# Автор: gopnikgame

# Подключаем общую библиотеку и diagnostic
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/diagnostic.sh"

# Константы
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")

# =============================================================================
# ГЕОЛОКАЦИЯ И АВТОМАТИЧЕСКИЙ ВЫБОР СЕРВЕРОВ
# =============================================================================

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

# Функция загрузки списков серверов
download_dns_lists() {
    local temp_dir="/tmp/dnscrypt_lists"
    mkdir -p "$temp_dir"
    
    log "INFO" "Загрузка актуальных списков серверов..."
    
    # URL для загрузки серверов
    local servers_url="https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/lib/DNSCrypt_servers.txt"
    
    # Загружаем серверы
    if ! timeout 30 curl -s -o "$temp_dir/servers.txt" "$servers_url"; then
        log "ERROR" "Не удалось загрузить список серверов"
        return 1
    fi
    
    # Проверяем размер файла
    if [[ ! -s "$temp_dir/servers.txt" ]]; then
        log "ERROR" "Загруженный файл серверов пуст"
        return 1
    fi
    
    # Проверяем формат файла
    if ! grep -q '^\[.*\]$' "$temp_dir/servers.txt"; then
        log "WARN" "Файл серверов может быть в старом формате"
    fi
    
    log "SUCCESS" "Список серверов успешно загружен"
    export DNS_SERVERS_FILE="$temp_dir/servers.txt"
    
    return 0
}

# Функция поиска серверов по стране (импортирована из manage_anonymized_dns.sh)
find_servers_by_country() {
    local country="$1"
    local servers_file="$2"
    
    if [[ ! -f "$servers_file" ]]; then
        log "ERROR" "Файл серверов не найден: $servers_file" >&2
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
                log "DEBUG" "Найдена страна: $current_country" >&2
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
                log "DEBUG" "Найден сервер: $server_name ($server_ip)" >&2
            fi
        fi
    done < "$servers_file"
    
    # Выводим найденные серверы
    if [[ ${#found_servers[@]} -gt 0 ]]; then
        printf '%s\n' "${found_servers[@]}"
        log "INFO" "Найдено серверов в стране '$country': ${#found_servers[@]}" >&2
    else
        log "WARN" "Серверы в стране '$country' не найдены" >&2
    fi
    
    return 0
}

# Функция поиска серверов в близких странах
find_nearest_servers_by_region() {
    local primary_country="$1"
    local servers_file="$2"
    local max_servers="${3:-5}"
    
    if [[ ! -f "$servers_file" ]]; then
        log "ERROR" "Файл серверов не найден: $servers_file" >&2
        return 1
    fi
    
    declare -a found_servers=()
    
    # Шаг 1: Ищем серверы в основной стране
    log "INFO" "Поиск серверов в стране: $primary_country" >&2
    local primary_servers=($(find_servers_by_country "$primary_country" "$servers_file"))
    found_servers+=("${primary_servers[@]}")
    
    # Шаг 2: Если серверов недостаточно, ищем в близких странах
    if [[ ${#found_servers[@]} -lt $max_servers ]]; then
        log "INFO" "Поиск серверов в близких регионах..." >&2
        
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
                # Глобальные серверы по умолчанию
                nearby_countries=("GERMANY" "FRANCE" "NETHERLANDS" "UNITED KINGDOM" "SINGAPORE" "USA" "UNITED STATES" "CANADA")
                ;;
        esac
        
        # Ищем серверы в близких странах
        for country in "${nearby_countries[@]}"; do
            if [[ ${#found_servers[@]} -ge $max_servers ]]; then
                break
            fi
            
            local nearby_servers=($(find_servers_by_country "$country" "$servers_file"))
            
            if [[ ${#nearby_servers[@]} -gt 0 ]]; then
                log "INFO" "Найдено серверов в стране $country: ${#nearby_servers[@]}" >&2
                found_servers+=("${nearby_servers[@]}")
            fi
        done
    fi
    
    # Выводим результат
    if [[ ${#found_servers[@]} -gt 0 ]]; then
        printf '%s\n' "${found_servers[@]}"
        log "SUCCESS" "Найдено серверов для региона '$primary_country': ${#found_servers[@]}" >&2
        return 0
    else
        log "ERROR" "Серверы не найдены" >&2
        return 1
    fi
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

# Функция выбора самого быстрого сервера
select_fastest_server() {
    local servers=("$@")
    local fastest_server=""
    local best_ping=999
    
    log "INFO" "Тестирование скорости серверов..." >&2
    
    for server_data in "${servers[@]}"; do
        local server_name="${server_data%:*}"
        local server_ip="${server_data#*:}"
        
        safe_echo "  Тестирование $server_name ($server_ip)..." >&2
        local ping_result=$(test_ping_latency "$server_ip" 3)
        
        if [[ "$ping_result" != "999" && "$ping_result" -lt "$best_ping" ]]; then
            best_ping="$ping_result"
            fastest_server="$server_name"
        fi
        
        safe_echo "    Пинг: ${ping_result}ms" >&2
    done
    
    if [[ -n "$fastest_server" ]]; then
        log "SUCCESS" "Выбран сервер: $fastest_server (пинг: ${best_ping}ms)" >&2
        echo "$fastest_server"
        return 0
    else
        log "ERROR" "Не удалось найти доступный сервер" >&2
        return 1
    fi
}

# Функция проверки анонимного DNS
check_anonymized_dns_active() {
    # Проверяем активную секцию [anonymized_dns]
    if grep -q "^\[anonymized_dns\]" "$DNSCRYPT_CONFIG"; then
        log "DEBUG" "Секция [anonymized_dns] активна"
        return 0
    fi
    
    return 1
}

# Функция отключения анонимного DNS
disable_anonymized_dns() {
    log "INFO" "Отключение анонимного DNS для обычного режима..."
    
    # Комментируем секцию [anonymized_dns]
    if grep -q "^\[anonymized_dns\]" "$DNSCRYPT_CONFIG"; then
        sed -i 's/^\[anonymized_dns\]/#[anonymized_dns]/' "$DNSCRYPT_CONFIG"
        log "SUCCESS" "Секция [anonymized_dns] закомментирована"
    fi
    
    # Комментируем routes в секции anonymized_dns
    sed -i '/^#\[anonymized_dns\]/,/^\[/{ /^routes = /s/^/#/; /^    { /s/^/#/; /^]/s/^/#/; }' "$DNSCRYPT_CONFIG"
    
    # Комментируем skip_incompatible
    sed -i '/^#\[anonymized_dns\]/,/^\[/{ /^skip_incompatible = /s/^/#/; }' "$DNSCRYPT_CONFIG"
    
    log "SUCCESS" "Анонимный DNS отключен"
}

# Автоматическая функция выбора серверов по географическим локациям
configure_auto_geo_servers() {
    safe_echo "\n${BLUE}=== АВТОМАТИЧЕСКИЙ ВЫБОР DNS СЕРВЕРОВ ПО ГЕОЛОКАЦИИ ===${NC}"
    echo
    safe_echo "${YELLOW}Эта функция автоматически определит ваше местоположение и выберет${NC}"
    safe_echo "${YELLOW}оптимальные DNS-серверы из вашего региона или близких стран.${NC}"
    echo
    
    # Подтверждение
    read -p "Продолжить автоматическую настройку? (y/n): " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        log "INFO" "Автоматическая настройка отменена"
        return 0
    fi
    
    # Шаг 1: Проверка анонимного DNS
    if check_anonymized_dns_active; then
        safe_echo "\n${YELLOW}⚠️  Обнаружен активный анонимный DNS${NC}"
        echo "Для обычного выбора серверов необходимо отключить анонимный DNS."
        echo
        read -p "Отключить анонимный DNS и продолжить? (y/n): " disable_anon
        if [[ "${disable_anon,,}" == "y" ]]; then
            backup_config "$DNSCRYPT_CONFIG" "dnscrypt-config-before-auto-geo"
            disable_anonymized_dns
        else
            safe_echo "${BLUE}Для настройки анонимного DNS используйте пункт 'Управление анонимным DNS'${NC}"
            return 0
        fi
    fi
    
    # Шаг 2: Определение геолокации
    if ! get_server_geolocation; then
        log "ERROR" "Не удалось определить геолокацию сервера"
        return 1
    fi
    
    # Шаг 3: Загрузка списков серверов
    if ! download_dns_lists; then
        log "ERROR" "Не удалось загрузить списки серверов"
        return 1
    fi
    
    # Шаг 4: Поиск серверов в регионе
    safe_echo "\n${BLUE}Поиск оптимальных DNS-серверов...${NC}"
    
    # Ищем серверы в стране пользователя и близких регионах
    local servers_in_region=($(find_nearest_servers_by_region "$SERVER_COUNTRY" "$DNS_SERVERS_FILE" 10))
    
    if [[ ${#servers_in_region[@]} -eq 0 ]]; then
        log "WARN" "Серверы в регионе не найдены, используем глобальные серверы"
        
        # Используем резервные серверы
        local selected_server="'quad9-dnscrypt-ip4-filter-pri'"
        local backup_servers="'cloudflare', 'google'"
    else
        safe_echo "${GREEN}Найдено серверов в регионе: ${#servers_in_region[@]}${NC}"
        
        # Показываем найденные серверы
        safe_echo "\n${BLUE}Найденные серверы:${NC}"
        for ((i=0; i<${#servers_in_region[@]} && i<10; i++)); do
            local server_data="${servers_in_region[i]}"
            local server_name="${server_data%:*}"
            local server_ip="${server_data#*:}"
            echo "  $((i+1)). $server_name ($server_ip)"
        done
        
        # Тестируем скорость серверов и выбираем лучший
        safe_echo "\n${BLUE}Тестирование скорости серверов...${NC}"
        local fastest_server=$(select_fastest_server "${servers_in_region[@]}")
        
        if [[ -z "$fastest_server" ]]; then
            log "WARN" "Не удалось определить быстрый сервер, используем Quad9"
            local selected_server="'quad9-dnscrypt-ip4-filter-pri'"
            local backup_servers="'cloudflare', 'google'"
        else
            local selected_server="'$fastest_server'"
            local backup_servers="'quad9-dnscrypt-ip4-filter-pri', 'cloudflare', 'google'"
        fi
    fi
    
    # Шаг 5: Создание резервной копии и настройка
    if ! check_anonymized_dns_active; then
        backup_config "$DNSCRYPT_CONFIG" "dnscrypt-config-before-auto-geo"
    fi
    
    # Раскомментируем server_names если он закомментирован
    if grep -q "^#server_names = " "$DNSCRYPT_CONFIG"; then
        sed -i 's/^#server_names = /server_names = /' "$DNSCRYPT_CONFIG"
        log "SUCCESS" "server_names раскомментирован для обычного режима"
    fi
    
    # Настраиваем серверы
    local full_server_list="[$selected_server, $backup_servers]"
    sed -i "s/server_names = .*/server_names = $full_server_list/" "$DNSCRYPT_CONFIG"
    
    # Очищаем список заблокированных серверов, чтобы избежать конфликтов
    if grep -q "disabled_server_names = " "$DNSCRYPT_CONFIG"; then
        sed -i "s/disabled_server_names = .*/disabled_server_names = []/" "$DNSCRYPT_CONFIG"
    fi

    # Включаем DoH серверы (cloudflare, google - DoH серверы)
    if ! grep -q "^doh_servers = true" "$DNSCRYPT_CONFIG"; then
        if grep -q "^doh_servers = " "$DNSCRYPT_CONFIG"; then
            sed -i 's/^doh_servers = .*/doh_servers = true/' "$DNSCRYPT_CONFIG"
        else
            sed -i "/^server_names = /a doh_servers = true" "$DNSCRYPT_CONFIG"
        fi
        log "SUCCESS" "DoH серверы включены (cloudflare, google поддерживают DoH)"
    fi
    
    # Настраиваем балансировку нагрузки
    if grep -q "^lb_strategy = " "$DNSCRYPT_CONFIG"; then
        sed -i "s/^lb_strategy = .*/lb_strategy = 'ph'/" "$DNSCRYPT_CONFIG"
    else
        sed -i "/^server_names = /a lb_strategy = 'ph'" "$DNSCRYPT_CONFIG"
    fi
    
    # Настраиваем таймаут
    if grep -q "timeout = " "$DNSCRYPT_CONFIG"; then
        sed -i "s/timeout = .*/timeout = 2500/" "$DNSCRYPT_CONFIG"
    else
        sed -i "/lb_strategy = /a timeout = 2500" "$DNSCRYPT_CONFIG"
    fi
    
    # Шаг 6: Применение конфигурации
    safe_echo "\n${BLUE}Применение конфигурации:${NC}"
    echo "  Основной регион: $SERVER_COUNTRY ($SERVER_COUNTRY_CODE)"
    echo "  Выбранные серверы: $full_server_list"
    echo "  DoH поддержка: включена (для cloudflare, google)"
    echo "  Балансировка: 'ph' (p2 hash)"
    echo "  Таймаут: 2500ms"
    echo
    
    read -p "Применить эту конфигурацию? (y/n): " apply_confirm
    if [[ "${apply_confirm,,}" != "y" ]]; then
        log "INFO" "Конфигурация не применена"
        return 0
    fi
    
    # Перезапускаем службу
    log "INFO" "Перезапуск DNSCrypt-proxy для применения изменений..."
    if restart_service "dnscrypt-proxy"; then
        safe_echo "\n${GREEN}=== АВТОМАТИЧЕСКАЯ НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО ===${NC}"
        echo
        safe_echo "${BLUE}Конфигурация DNS:${NC}"
        echo "  ✅ Режим: Обычный DNS (не анонимный)"
        echo "  ✅ Серверы: $full_server_list"
        echo "  ✅ Регион: $SERVER_COUNTRY"
        echo "  ✅ DoH поддержка: включена"
        echo "  ✅ Балансировка нагрузки: активна"
        echo
        safe_echo "${YELLOW}Рекомендации:${NC}"
        echo "  • Проверьте работу DNS: dig @127.0.0.1 google.com"
        echo "  • Проверьте логи: journalctl -u dnscrypt-proxy -f"
        echo "  • При проблемах используйте пункт 'Исправить DNS резолвинг'"
        
        log "SUCCESS" "Автоматическая геолокационная настройка завершена"
        
        # Тестируем выбранный сервер
        sleep 2
        local primary_server=$(echo $selected_server | sed "s/'//g")
        verify_settings "$primary_server"
    else
        log "ERROR" "Ошибка при перезапуске службы"
        return 1
    fi
    
    # Очистка временных файлов
    rm -rf "/tmp/dnscrypt_lists" 2>/dev/null
    
    return 0
}

# Обновленная функция configure_geo_servers с автоматической опцией
configure_geo_servers() {
    safe_echo "\n${BLUE}Выбор DNS серверов по географическому расположению:${NC}"
    echo "1) 🌍 Автоматический выбор по геолокации (рекомендуется)"
    echo "2) Северная Америка (Торонто, Лос-Анджелес)"
    echo "3) Европа (Амстердам, Франкфурт, Париж)"
    echo "4) Азия (Токио, Фуджейра, Сидней)"
    echo "5) Ручной выбор основного сервера"
    echo "0) Отмена"
    
    read -p "Выберите регион (0-5): " geo_choice
    
    local server_name=""
    case $geo_choice in
        1)
            # Новая автоматическая функция
            configure_auto_geo_servers
            return $?
            ;;
        2)
            safe_echo "\n${BLUE}Доступные серверы Северной Америки:${NC}"
            echo "1) dnscry.pt-toronto (Торонто, Канада)"
            echo "2) dnscry.pt-losangeles (Лос-Анджелес, США)"
            echo "0) Назад"
            
            read -p "Выберите основной сервер (0-2): " na_choice
            
            case $na_choice in
                1)
                    server_name="['dnscry.pt-toronto', 'cloudflare', 'google', 'quad9-dnscrypt-ip4-filter-pri']"
                    log "INFO" "Выбран сервер Торонто с резервными серверами"
                    ;;
                2)
                    server_name="['dnscry.pt-losangeles', 'cloudflare', 'google', 'quad9-dnscrypt-ip4-filter-pri']"
                    log "INFO" "Выбран сервер Лос-Анджелес с резервными серверами"
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
        3)
            safe_echo "\n${BLUE}Доступные серверы Европы:${NC}"
            echo "1) dnscry.pt-amsterdam (Амстердам, Нидерланды)"
            echo "2) dnscry.pt-frankfurt (Франкфурт, Германия)"
            echo "3) dnscry.pt-paris (Париж, Франция)"
            echo "0) Назад"
            
            read -p "Выберите основной сервер (0-3): " eu_choice
            
            case $eu_choice in
                1)
                    server_name="['dnscry.pt-amsterdam', 'cloudflare', 'google', 'quad9-dnscrypt-ip4-filter-pri']"
                    log "INFO" "Выбран сервер Амстердам с резервными серверами"
                    ;;
                2)
                    server_name="['dnscry.pt-frankfurt', 'cloudflare', 'google', 'quad9-dnscrypt-ip4-filter-pri']"
                    log "INFO" "Выбран сервер Франкфурт с резервными серверами"
                    ;;
                3)
                    server_name="['dnscry.pt-paris', 'cloudflare', 'google', 'quad9-dnscrypt-ip4-filter-pri']"
                    log "INFO" "Выбран сервер Париж с резервными серверами"
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
        4)
            safe_echo "\n${BLUE}Доступные серверы Азии и Океании:${NC}"
            echo "1) dnscry.pt-tokyo (Токио, Япония)"
            echo "2) dnscry.pt-fujairah (Фуджейра, ОАЭ)"
            echo "3) dnscry.pt-sydney02 (Сидней, Австралия)"
            echo "0) Назад"
            
            read -p "Выберите основной сервер (0-3): " asia_choice
            
            case $asia_choice in
                1)
                    server_name="['dnscry.pt-tokyo', 'cloudflare', 'google', 'quad9-dnscrypt-ip4-filter-pri']"
                    log "INFO" "Выбран сервер Токио с резервными серверами"
                    ;;
                2)
                    server_name="['dnscry.pt-fujairah', 'cloudflare', 'google', 'quad9-dnscrypt-ip4-filter-pri']"
                    log "INFO" "Выбран сервер Фуджейра с резервными серверами"
                    ;;
                3)
                    server_name="['dnscry.pt-sydney02', 'cloudflare', 'google', 'quad9-dnscrypt-ip4-filter-pri']"
                    log "INFO" "Выбран сервер Сидней с резервными серверами"
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
        5)
            safe_echo "\n${BLUE}Все доступные серверы dnscry.pt:${NC}"
            echo "1) dnscry.pt-amsterdam (Амстердам, Нидерланды)"
            echo "2) dnscry.pt-frankfurt (Франкфурт, Германия)"
            echo "3) dnscry.pt-paris (Париж, Франция)"
            echo "4) dnscry.pt-toronto (Торонто, Канада)"
            echo "5) dnscry.pt-losangeles (Лос-Анджелес, США)"
            echo "6) dnscry.pt-tokyo (Токио, Япония)"
            echo "7) dnscry.pt-fujairah (Фуджейра, ОАЭ)"
            echo "8) dnscry.pt-sydney02 (Сидней, Австралия)"
            echo "0) Назад"
            
            read -p "Выберите основной сервер (0-8): " manual_choice
            
            local primary_server=""
            case $manual_choice in
                1) primary_server="dnscry.pt-amsterdam" ;;
                2) primary_server="dnscry.pt-frankfurt" ;;
                3) primary_server="dnscry.pt-paris" ;;
                4) primary_server="dnscry.pt-toronto" ;;
                5) primary_server="dnscry.pt-losangeles" ;;
                6) primary_server="dnscry.pt-tokyo" ;;
                7) primary_server="dnscry.pt-fujairah" ;;
                8) primary_server="dnscry.pt-sydney02" ;;
                0) return 0 ;;
                *) 
                    log "ERROR" "Неверный выбор"
                    return 1
                    ;;
            esac
            
            server_name="['$primary_server', 'cloudflare', 'google', 'quad9-dnscrypt-ip4-filter-pri']"
            log "INFO" "Выбран сервер $primary_server с резервными серверами"
            ;;
        0)
            return 0
            ;;
        *)
            log "ERROR" "Неверный выбор"
            return 1
            ;;
    esac
    
    # Если сервер был выбран, обновляем настройки
    if [ -n "$server_name" ]; then
        # Проверяем анонимный DNS и отключаем при необходимости
        if check_anonymized_dns_active; then
            safe_echo "\n${YELLOW}⚠️  Анонимный DNS активен. Отключение для обычного режима...${NC}"
            backup_config "$DNSCRYPT_CONFIG" "dnscrypt-config-before-geo"
            disable_anonymized_dns
        fi
        
        # Раскомментируем server_names если он закомментирован
        if grep -q "^#server_names = " "$DNSCRYPT_CONFIG"; then
            sed -i 's/^#server_names = /server_names = /' "$DNSCRYPT_CONFIG"
            log "SUCCESS" "server_names раскомментирован для обычного режима"
        fi
        
        # Обновляем основные настройки серверов
        sed -i "s/server_names = .*/server_names = $server_name/" "$DNSCRYPT_CONFIG"
        
        # Включаем DoH серверы
        if ! grep -q "^doh_servers = true" "$DNSCRYPT_CONFIG"; then
            if grep -q "^doh_servers = " "$DNSCRYPT_CONFIG"; then
                sed -i 's/^doh_servers = .*/doh_servers = true/' "$DNSCRYPT_CONFIG"
            else
                sed -i "/^server_names = /a doh_servers = true" "$DNSCRYPT_CONFIG"
            fi
            log "SUCCESS" "DoH серверы включены (cloudflare, google поддерживают DoH)"
        fi
        
        # Настраиваем балансировку нагрузки
        if grep -q "^lb_strategy = " "$DNSCRYPT_CONFIG"; then
            sed -i "s/^lb_strategy = .*/lb_strategy = 'ph'/" "$DNSCRYPT_CONFIG"
        else
            sed -i "/^server_names = /a lb_strategy = 'ph'" "$DNSCRYPT_CONFIG"
        fi
        
        # Настраиваем таймаут
        if grep -q "timeout = " "$DNSCRYPT_CONFIG"; then
            sed -i "s/timeout = .*/timeout = 2500/" "$DNSCRYPT_CONFIG"
        else
            sed -i "/lb_strategy = /a timeout = 2500" "$DNSCRYPT_CONFIG"
        fi
        
        log "INFO" "DNS серверы изменены на $server_name"
        
        restart_service "dnscrypt-proxy"
        sleep 2
        
        verify_settings "$(echo $server_name | sed 's/\[\|\]//g' | sed "s/'//g" | cut -d',' -f1)"
    fi
    
    return 0
}

# Настройка параметров кэширования
configure_cache() {
    safe_echo "\n${BLUE}Настройка кэширования DNS:${NC}"
    echo "Кэширование DNS уменьшает задержку запросов и снижает нагрузку на сеть."
    echo
    echo "1) Включить кэширование (рекомендуется)"
    echo "2) Выключить кэширование"
    echo "3) Настроить параметры кэша"
    echo "0) Назад"
    
    read -p "Выберите опцию (0-3): " cache_option
    
    case $cache_option in
        1)
            # Включаем кэширование с параметрами по умолчанию
            if grep -q "cache = " "$DNSCRYPT_CONFIG"; then
                sed -i "s/cache = .*/cache = true/" "$DNSCRYPT_CONFIG"
            else
                sed -i "/\[sources\]/i cache = true" "$DNSCRYPT_CONFIG"
            fi
            
            # Устанавливаем размер кэша и другие параметры, если их нет
            if ! grep -q "cache_size = " "$DNSCRYPT_CONFIG"; then
                sed -i "/cache = true/a cache_size = 4096" "$DNSCRYPT_CONFIG"
            fi
            
            if ! grep -q "cache_min_ttl = " "$DNSCRYPT_CONFIG"; then
                sed -i "/cache_size = /a cache_min_ttl = 2400" "$DNSCRYPT_CONFIG"
            fi
            
            if ! grep -q "cache_max_ttl = " "$DNSCRYPT_CONFIG"; then
                sed -i "/cache_min_ttl = /a cache_max_ttl = 86400" "$DNSCRYPT_CONFIG"
            fi
            
            if ! grep -q "cache_neg_min_ttl = " "$DNSCRYPT_CONFIG"; then
                sed -i "/cache_max_ttl = /a cache_neg_min_ttl = 60" "$DNSCRYPT_CONFIG"
            fi
            
            if ! grep -q "cache_neg_max_ttl = " "$DNSCRYPT_CONFIG"; then
                sed -i "/cache_neg_min_ttl = /a cache_neg_max_ttl = 600" "$DNSCRYPT_CONFIG"
            fi
            
            log "SUCCESS" "Кэширование включено с настройками по умолчанию"
            ;;
        2)
            # Выключаем кэширование
            if grep -q "cache = " "$DNSCRYPT_CONFIG"; then
                sed -i "s/cache = .*/cache = false/" "$DNSCRYPT_CONFIG"
            else
                sed -i "/\[sources\]/i cache = false" "$DNSCRYPT_CONFIG"
            fi
            
            log "SUCCESS" "Кэширование отключено"
            ;;
        3)
            # Настраиваем параметры кэша
            safe_echo "\n${BLUE}Настройка параметров кэша:${NC}"
            
            # Проверяем, включен ли кэш
            if ! grep -q "cache = true" "$DNSCRYPT_CONFIG"; then
                if grep -q "cache = " "$DNSCRYPT_CONFIG"; then
                    sed -i "s/cache = .*/cache = true/" "$DNSCRYPT_CONFIG"
                else
                    sed -i "/\[sources\]/i cache = true" "$DNSCRYPT_CONFIG"
                fi
                log "INFO" "Кэширование было выключено. Сейчас включено."
            fi
            
            # Получаем текущие значения или устанавливаем значения по умолчанию
            local current_size=$(grep "cache_size = " "$DNSCRYPT_CONFIG" | sed 's/cache_size = //' || echo "4096")
            local current_min_ttl=$(grep "cache_min_ttl = " "$DNSCRYPT_CONFIG" | sed 's/cache_min_ttl = //' || echo "2400")
            local current_max_ttl=$(grep "cache_max_ttl = " "$DNSCRYPT_CONFIG" | sed 's/cache_max_ttl = //' || echo "86400")
            local current_neg_min_ttl=$(grep "cache_neg_min_ttl = " "$DNSCRYPT_CONFIG" | sed 's/cache_neg_min_ttl = //' || echo "60")
            local current_neg_max_ttl=$(grep "cache_neg_max_ttl = " "$DNSCRYPT_CONFIG" | sed 's/cache_neg_max_ttl = //' || echo "600")
            
            # Запрашиваем новые значения
            safe_echo "Текущий размер кэша: ${YELLOW}$current_size${NC} (рекомендуется 4096 для домашней сети)"
            read -p "Новый размер кэша [Enter для сохранения текущего]: " new_size
            new_size=${new_size:-$current_size}
            
            safe_echo "Текущее минимальное TTL: ${YELLOW}$current_min_ttl${NC} секунд (рекомендуется 2400)"
            read -p "Новое минимальное TTL [Enter для сохранения текущего]: " new_min_ttl
            new_min_ttl=${new_min_ttl:-$current_min_ttl}
            
            safe_echo "Текущее максимальное TTL: ${YELLOW}$current_max_ttl${NC} секунд (рекомендуется 86400)"
            read -p "Новое максимальное TTL [Enter для сохранения текущего]: " new_max_ttl
            new_max_ttl=${new_max_ttl:-$current_max_ttl}
            
            safe_echo "Текущее минимальное отрицательное TTL: ${YELLOW}$current_neg_min_ttl${NC} секунд (рекомендуется 60)"
            read -p "Новое минимальное отрицательное TTL [Enter для сохранения текущего]: " new_neg_min_ttl
            new_neg_min_ttl=${new_neg_min_ttl:-$current_neg_min_ttl}
            
            safe_echo "Текущее максимальное отрицательное TTL: ${YELLOW}$current_neg_max_ttl${NC} секунд (рекомендуется 600)"
            read -p "Новое максимальное отрицательное TTL [Enter для сохранения текущего]: " new_neg_max_ttl
            new_neg_max_ttl=${new_neg_max_ttl:-$current_neg_max_ttl}
            
            # Обновляем настройки
            if grep -q "cache_size = " "$DNSCRYPT_CONFIG"; then
                sed -i "s/cache_size = .*/cache_size = $new_size/" "$DNSCRYPT_CONFIG"
            else
                sed -i "/cache = true/a cache_size = $new_size" "$DNSCRYPT_CONFIG"
            fi
            
            if grep -q "cache_min_ttl = " "$DNSCRYPT_CONFIG"; then
                sed -i "s/cache_min_ttl = .*/cache_min_ttl = $new_min_ttl/" "$DNSCRYPT_CONFIG"
            else
                sed -i "/cache_size = /a cache_min_ttl = $new_min_ttl" "$DNSCRYPT_CONFIG"
            fi
            
            if grep -q "cache_max_ttl = " "$DNSCRYPT_CONFIG"; then
                sed -i "s/cache_max_ttl = .*/cache_max_ttl = $new_max_ttl/" "$DNSCRYPT_CONFIG"
            else
                sed -i "/cache_min_ttl = /a cache_max_ttl = $new_max_ttl" "$DNSCRYPT_CONFIG"
            fi
            
            if grep -q "cache_neg_min_ttl = " "$DNSCRYPT_CONFIG"; then
                sed -i "s/cache_neg_min_ttl = .*/cache_neg_min_ttl = $new_neg_min_ttl/" "$DNSCRYPT_CONFIG"
            else
                sed -i "/cache_max_ttl = /a cache_neg_min_ttl = $new_neg_min_ttl" "$DNSCRYPT_CONFIG"
            fi
            
            if grep -q "cache_neg_max_ttl = " "$DNSCRYPT_CONFIG"; then
                sed -i "s/cache_neg_max_ttl = .*/cache_neg_max_ttl = $new_neg_max_ttl/" "$DNSCRYPT_CONFIG"
            else
                sed -i "/cache_neg_min_ttl = /a cache_neg_max_ttl = $new_neg_max_ttl" "$DNSCRYPT_CONFIG"
            fi
            
            log "SUCCESS" "Параметры кэша обновлены"
            ;;
        0)
            return 0
            ;;
        *)
            log "ERROR" "Неверный выбор"
            return 1
            ;;
    esac
    
    restart_service "dnscrypt-proxy"
    
    return 0
}

# Меню расширенных настроек
advanced_settings() {
    while true; do
        safe_echo "\n${BLUE}Дополнительные настройки DNSCrypt:${NC}"
        echo "1) Настройка HTTP/3 для DoH"
        echo "2) Настройка кэширования DNS"
        echo "3) Управление блокировкой IPv6"
        echo "4) Настройка источников DNS серверов"
        echo "5) Включить/выключить горячую перезагрузку"
        echo "6) Тестировать скорость DNS-серверов"
        echo "0) Вернуться в основное меню"
        
        read -p "Выберите опцию (0-6): " advanced_choice
        
        case $advanced_choice in
            1)
                configure_http3
                ;;
            2)
                configure_cache
                ;;
            3)
                safe_echo "\n${BLUE}Блокировка IPv6:${NC}"
                echo "Если у вас нет IPv6-подключения, блокировка запросов IPv6 может ускорить работу DNS."
                echo "Внимание: на некоторых ОС (например, macOS) блокировка может вызвать проблемы с разрешением имен."
                
                read -p "Включить блокировку IPv6? (y/n): " block_ipv6
                if [[ "${block_ipv6,,}" == "y" ]]; then
                    if grep -q "block_ipv6 = " "$DNSCRYPT_CONFIG"; then
                        sed -i "s/block_ipv6 = .*/block_ipv6 = true/" "$DNSCRYPT_CONFIG"
                    else
                        sed -i "/\[query_log\]/i block_ipv6 = true" "$DNSCRYPT_CONFIG"
                    fi
                    log "SUCCESS" "Блокировка IPv6 включена"
                else
                    if grep -q "block_ipv6 = " "$DNSCRYPT_CONFIG"; then
                        sed -i "s/block_ipv6 = .*/block_ipv6 = false/" "$DNSCRYPT_CONFIG"
                    else
                        sed -i "/\[query_log\]/i block_ipv6 = false" "$DNSCRYPT_CONFIG"
                    fi
                    log "SUCCESS" "Блокировка IPv6 отключена"
                fi
                
                restart_service "dnscrypt-proxy"
                ;;
            4)
                configure_sources
                ;;
            5)
                safe_echo "\n${BLUE}Горячая перезагрузка:${NC}"
                echo "Позволяет вносить изменения в файлы конфигурации без перезапуска прокси."
                echo "Может увеличить использование CPU и памяти. По умолчанию отключена."
                
                read -p "Включить горячую перезагрузку? (y/n): " hot_reload
                if [[ "${hot_reload,,}" == "y" ]]; then
                    if grep -q "enable_hot_reload = " "$DNSCRYPT_CONFIG"; then
                        sed -i "s/enable_hot_reload = .*/enable_hot_reload = true/" "$DNSCRYPT_CONFIG"
                    else
                        sed -i "/\[query_log\]/i enable_hot_reload = true" "$DNSCRYPT_CONFIG"
                    fi
                    log "SUCCESS" "Горячая перезагрузка включена"
                else
                    if grep -q "enable_hot_reload = " "$DNSCRYPT_CONFIG"; then
                        sed -i "s/enable_hot_reload = .*/enable_hot_reload = false/" "$DNSCRYPT_CONFIG"
                    else
                        sed -i "/\[query_log\]/i enable_hot_reload = false" "$DNSCRYPT_CONFIG"
                    fi
                    log "SUCCESS" "Горячая перезагрузка отключена"
                fi
                
                restart_service "dnscrypt-proxy"
                ;;
            6)
                # Используем функцию из diagnostic.sh
                test_dns_speed
                ;;
            0)
                return 0
                ;;
            *)
                log "ERROR" "Неверный выбор"
                ;;
        esac
    done
}

# Настройка источников DNS серверов
configure_sources() {
    safe_echo "\n${BLUE}Настройка источников DNS серверов:${NC}"
    echo "DNSCrypt-proxy может загружать списки серверов из различных источников."
    
    # Проверяем наличие секции [sources] в конфигурации
    if ! grep -q "\[sources\]" "$DNSCRYPT_CONFIG"; then
        safe_echo "${RED}Секция [sources] не найдена в конфигурации.${NC}"
        safe_echo "Добавляем стандартный источник public-resolvers."
        
        cat >> "$DNSCRYPT_CONFIG" << EOL

[sources]

  [sources.'public-resolvers']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
  cache_file = 'public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 72
  prefix = ''
EOL
        log "SUCCESS" "Добавлен стандартный источник public-resolvers"
    fi
    
    # Читаем текущие источники
    safe_echo "\n${BLUE}Текущие источники:${NC}"
    sed -n '/\[sources\]/,/\[.*/p' "$DNSCRYPT_CONFIG" | grep -v "^\[" | grep -v "^$"
    
    echo -e "\n1) Добавить новый источник"
    echo "2) Удалить источник"
    echo "3) Просмотреть доступные серверы"
    echo "0) Назад"
    
    read -p "Выберите опцию (0-3): " source_option
    
    case $source_option in
        1)
            safe_echo "\n${BLUE}Добавление нового источника:${NC}"
            read -p "Имя источника (например, 'my-resolvers'): " source_name
            
            if [ -z "$source_name" ]; then
                log "ERROR" "Имя источника не может быть пустым"
                return 1
            fi
            
            read -p "URL источника: " source_url
            
            if [ -z "$source_url" ]; then
                log "ERROR" "URL источника не может быть пустым"
                return 1
            fi
            
            read -p "Имя файла кэша (например, 'my-resolvers.md'): " cache_file
            
            if [ -z "$cache_file" ]; then
                cache_file="${source_name}.md"
                log "INFO" "Установлено имя файла кэша по умолчанию: $cache_file"
            fi
            
            read -p "Ключ проверки подписи Minisign (оставьте пустым, если неизвестен): " minisign_key
            
            read -p "Период обновления в часах [72]: " refresh_delay
            refresh_delay=${refresh_delay:-72}
            
            read -p "Префикс для имен серверов из этого источника (оставьте пустым, если не требуется): " prefix
            
            # Добавляем новый источник
            cat >> "$DNSCRYPT_CONFIG" << EOL

  [sources.'$source_name']
  urls = ['$source_url']
  cache_file = '$cache_file'
EOL
            
            if [ -n "$minisign_key" ]; then
                echo "  minisign_key = '$minisign_key'" >> "$DNSCRYPT_CONFIG"
            fi
            
            echo "  refresh_delay = $refresh_delay" >> "$DNSCRYPT_CONFIG"
            
            if [ -n "$prefix" ]; then
                echo "  prefix = '$prefix'" >> "$DNSCRYPT_CONFIG"
            else
                echo "  prefix = ''" >> "$DNSCRYPT_CONFIG"
            fi
            
            log "SUCCESS" "Источник '$source_name' добавлен"
            
            restart_service "dnscrypt-proxy"
            ;;
        2)
            safe_echo "\n${BLUE}Удаление источника:${NC}"
            
            # Получаем список источников
            local sources=$(grep -n "\[sources\.'.*'\]" "$DNSCRYPT_CONFIG" | sed 's/:.*//' | awk '{print $1}')
            
            if [ -z "$sources" ]; then
                log "ERROR" "Источники не найдены"
                return 1
            fi
            
            # Выводим список источников для выбора
            local i=1
            local source_names=()
            echo "Доступные источники:"
            
            while read -r line_num; do
                local source_name=$(sed -n "${line_num}p" "$DNSCRYPT_CONFIG" | grep -o "'.*'" | sed "s/'//g")
                echo "$i) $source_name"
                source_names[$i]=$source_name
                ((i++))
            done <<< "$sources"
            
            read -p "Выберите источник для удаления (1-$((i-1))): " source_choice
            
            if [[ "$source_choice" =~ ^[0-9]+$ ]] && [ "$source_choice" -ge 1 ] && [ "$source_choice" -lt "$i" ]; then
                local selected_source="${source_names[$source_choice]}"
                
                # Удаляем выбранный источник
                local start_line=$(grep -n "\[sources\.'$selected_source'\]" "$DNSCRYPT_CONFIG" | cut -d':' -f1)
                local end_line=$(awk "NR > $start_line && /^\[/ {print NR-1; exit}" "$DNSCRYPT_CONFIG")
                
                if [ -z "$end_line" ]; then
                    end_line=$(wc -l "$DNSCRYPT_CONFIG" | awk '{print $1}')
                fi
                
                sed -i "${start_line},${end_line}d" "$DNSCRYPT_CONFIG"
                
                log "SUCCESS" "Источник '$selected_source' удален"
                
                restart_service "dnscrypt-proxy"
            else
                log "ERROR" "Неверный выбор"
                return 1
            fi
            ;;
        3)
            safe_echo "\n${BLUE}Доступные серверы:${NC}"
            echo "1) Список DNSCrypt серверов"
            echo "2) Список релеев"
            echo "3) Список ODoH серверов"
            echo "4) Список ODoH релеев"
            echo "0) Назад"
            
            read -p "Выберите список для просмотра (0-4): " list_choice
            
            case $list_choice in
                1) list_available_servers ;;
                2) list_available_relays ;;
                3) list_available_odoh_servers ;;
                4) list_available_odoh_relays ;;
                0) return 0 ;;
                *) log "ERROR" "Неверный выбор" ;;
            esac
            ;;
        0)
            return 0
            ;;
        *)
            log "ERROR" "Неверный выбор"
            return 1
            ;;
    esac
    
    return 0
}

# Основная функция изменения DNS
change_dns() {
    # Отображение заголовка
    print_header "НАСТРОЙКА DNSCRYPT"
    
    # Проверка root-прав
    check_root
    
    # Проверка установки DNSCrypt
    if ! check_dnscrypt_installed; then
        log "ERROR" "DNSCrypt-proxy не установлен. Установите его перед настройкой."
        safe_echo "${YELLOW}Используйте пункт меню 'Установить DNSCrypt'${NC}"
        return 1
    fi

    # Проверка существования конфигурационного файла
    if [ ! -f "$DNSCRYPT_CONFIG" ]; then
        log "ERROR" "Файл конфигурации DNSCrypt не найден"
        return 1
    fi

    while true; do
        # Показать текущие настройки
        check_current_settings
    
        safe_echo "\n${BLUE}Меню настройки DNSCrypt:${NC}"
        echo "1) 🌍 Автоматический выбор серверов по геолокации"
        echo "2) Настройка серверов по географическому расположению"
        echo "3) Изменить DNS сервер вручную"
        echo "4) Настройки безопасности (DNSSEC, NoLog, NoFilter)"
        echo "5) Настройки протоколов (IPv4/IPv6, DNSCrypt/DoH/ODoH)"
        echo "6) Расширенные настройки"
        echo "7) Проверить текущую конфигурацию"
        echo "8) Тестировать скорость DNS серверов"
        echo "9) Проверка безопасности DNS"
        echo "0) Выход"
        
        read -p "Выберите опцию (0-9): " main_choice
        
        case $main_choice in
            1)
                configure_auto_geo_servers
                ;;
            
            2)
                configure_geo_servers
                ;;
            
            3)
                # Ручной выбор сервера
                safe_echo "\n${BLUE}Доступные предустановленные серверы:${NC}"
                echo "1) cloudflare (Cloudflare)"
                echo "2) google (Google DNS)"
                echo "3) quad9-dnscrypt-ip4-filter-pri (Quad9)"
                echo "4) adguard-dns (AdGuard DNS)"
                echo "5) Ввести другой сервер"
                echo "0) Отмена"
            
                read -p "Выберите DNS сервер (0-5): " choice
            
                local server_name=""
                case $choice in
                    1) server_name="['cloudflare']" ;;
                    2) server_name="['google']" ;;
                    3) server_name="['quad9-dnscrypt-ip4-filter-pri']" ;;
                    4) server_name="['adguard-dns']" ;;
                    5)
                        safe_echo "\n${BLUE}Примеры форматов ввода DNS серверов:${NC}"
                        echo "1. Один сервер: quad9-dnscrypt-ip4-filter-pri"
                        echo "2. Несколько серверов: ['quad9-dnscrypt-ip4-filter-pri', 'cloudflare']"
                        echo "3. С указанием протокола: sdns://... (для DoH/DoT/DNSCrypt серверов)"
                        safe_echo "\nПопулярные серверы:"
                        echo "- cloudflare           (Cloudflare DNS)"
                        echo "- google               (Google DNS)"
                        echo "- quad9-dnscrypt-ip4-filter-pri  (Quad9 DNS с фильтрацией)"
                        echo "- adguard-dns         (AdGuard DNS с блокировкой рекламы)"
                        echo "- cleanbrowsing-adult (CleanBrowsing с семейным фильтром)"
                        safe_echo "\n${YELLOW}Внимание: Имя сервера должно точно соответствовать записи в resolvers-info.md${NC}"
                        safe_echo "${BLUE}Полный список серверов доступен по адресу:${NC}"
                        echo "https://github.com/DNSCrypt/dnscrypt-proxy/wiki/Public-resolvers"
                        
                        read -p $'\nВведите имя сервера или массив серверов: ' input_server_name
                        if [[ -z "$input_server_name" ]]; then
                            log "ERROR" "Имя сервера не может быть пустым"
                            continue
                        fi
                        
                        # Проверяем, является ли ввод уже массивом
                        if [[ "$input_server_name" == \[*\] ]]; then
                            server_name="$input_server_name"
                        else
                            # Если нет, то создаем массив
                            server_name="['$input_server_name']"
                        fi
                        ;;
                    0)
                        log "INFO" "Операция отменена"
                        continue
                        ;;
                    *)
                        log "ERROR" "Неверный выбор"
                        continue
                        ;;
                esac
                
                # Если сервер был выбран, обновляем настройки
                if [ -n "$server_name" ]; then
                    # Проверяем анонимный DNS и отключаем при необходимости
                    if check_anonymized_dns_active; then
                        safe_echo "\n${YELLOW}⚠️  Анонимный DNS активен. Отключение для обычного режима...${NC}"
                        backup_config "$DNSCRYPT_CONFIG" "dnscrypt-config-before-manual"
                        disable_anonymized_dns
                    fi
                    
                    # Раскомментируем server_names если он закомментирован
                    if grep -q "^#server_names = " "$DNSCRYPT_CONFIG"; then
                        sed -i 's/^#server_names = /server_names = /' "$DNSCRYPT_CONFIG"
                        log "SUCCESS" "server_names раскомментирован для обычного режима"
                    fi
                    
                    sed -i "s/server_names = .*/server_names = $server_name/" "$DNSCRYPT_CONFIG"
                    log "INFO" "DNS сервер изменен на $server_name"
                    
                    restart_service "dnscrypt-proxy"
                    sleep 2
                    
                    verify_settings "$(echo $server_name | sed 's/\[\|\]//g' | sed "s/'//g" | cut -d',' -f1)"
                fi
                ;;
            
            4)
                safe_echo "\n${BLUE}Настройки безопасности:${NC}"
                
                read -p "Включить DNSSEC (проверка криптографических подписей)? (y/n): " dnssec
                dnssec=$(echo "$dnssec" | tr '[:upper:]' '[:lower:]')
                dnssec=$([[ "$dnssec" == "y" ]] && echo "true" || echo "false")
            
                read -p "Включить NoLog (только серверы без логирования)? (y/n): " nolog
                nolog=$(echo "$nolog" | tr '[:upper:]' '[:lower:]')
                nolog=$([[ "$nolog" == "y" ]] && echo "true" || echo "false")
            
                read -p "Включить NoFilter (только серверы без фильтрации)? (y/n): " nofilter
                nofilter=$(echo "$nofilter" | tr '[:upper:]' '[:lower:]')
                nofilter=$([[ "$nofilter" == "y" ]] && echo "true" || echo "false")
                
                # Проверяем анонимный DNS и отключаем при необходимости
                if check_anonymized_dns_active; then
                    safe_echo "\n${YELLOW}⚠️  Анонимный DNS активен. Отключение для применения настроек безопасности...${NC}"
                    backup_config "$DNSCRYPT_CONFIG" "dnscrypt-config-before-security"
                    disable_anonymized_dns
                fi
                
                # Раскомментируем server_names если он закомментирован
                if grep -q "^#server_names = " "$DNSCRYPT_CONFIG"; then
                    sed -i 's/^#server_names = /server_names = /' "$DNSCRYPT_CONFIG"
                    log "SUCCESS" "server_names раскомментирован для обычного режима"
                fi
                
                # Обновляем настройки
                sed -i "s/require_dnssec = .*/require_dnssec = $dnssec/" "$DNSCRYPT_CONFIG"
                sed -i "s/require_nolog = .*/require_nolog = $nolog/" "$DNSCRYPT_CONFIG"
                sed -i "s/require_nofilter = .*/require_nofilter = $nofilter/" "$DNSCRYPT_CONFIG"
                
                log "INFO" "Настройки безопасности обновлены"
                
                restart_service "dnscrypt-proxy"
                sleep 2
                ;;
                
            5)
                safe_echo "\n${BLUE}Настройки протоколов:${NC}"
                
                read -p "Использовать серверы IPv4? (y/n): " ipv4
                ipv4=$(echo "$ipv4" | tr '[:upper:]' '[:lower:]')
                ipv4=$([[ "$ipv4" == "y" ]] && echo "true" || echo "false")
                
                read -p "Использовать серверы IPv6? (y/n): " ipv6
                ipv6=$(echo "$ipv6" | tr '[:upper:]' '[:lower:]')
                ipv6=$([[ "$ipv6" == "y" ]] && echo "true" || echo "false")
                
                read -p "Использовать серверы DNSCrypt? (y/n): " dnscrypt
                dnscrypt=$(echo "$dnscrypt" | tr '[:upper:]' '[:lower:]')
                dnscrypt=$([[ "$dnscrypt" == "y" ]] && echo "true" || echo "false")
                
                read -p "Использовать серверы DNS-over-HTTPS (DoH)? (y/n): " doh
                doh=$(echo "$doh" | tr '[:upper:]' '[:lower:]')
                doh=$([[ "$doh" == "y" ]] && echo "true" || echo "false")
                
                read -p "Использовать серверы Oblivious DoH (ODoH)? (y/n): " odoh
                odoh=$(echo "$odoh" | tr '[:upper:]' '[:lower:]')
                odoh=$([[ "$odoh" == "y" ]] && echo "true" || echo "false")
                
                # Проверяем анонимный DNS и отключаем при необходимости
                if check_anonymized_dns_active; then
                    safe_echo "\n${YELLOW}⚠️  Анонимный DNS активен. Отключение для применения настроек протоколов...${NC}"
                    backup_config "$DNSCRYPT_CONFIG" "dnscrypt-config-before-protocols"
                    disable_anonymized_dns
                fi
                
                # Раскомментируем server_names если он закомментирован
                if grep -q "^#server_names = " "$DNSCRYPT_CONFIG"; then
                    sed -i 's/^#server_names = /server_names = /' "$DNSCRYPT_CONFIG"
                    log "SUCCESS" "server_names раскомментирован для обычного режима"
                fi
                
                # Обновляем настройки
                sed -i "s/ipv4_servers = .*/ipv4_servers = $ipv4/" "$DNSCRYPT_CONFIG"
                sed -i "s/ipv6_servers = .*/ipv6_servers = $ipv6/" "$DNSCRYPT_CONFIG"
                sed -i "s/dnscrypt_servers = .*/dnscrypt_servers = $dnscrypt/" "$DNSCRYPT_CONFIG"
                sed -i "s/doh_servers = .*/doh_servers = $doh/" "$DNSCRYPT_CONFIG"
                sed -i "s/odoh_servers = .*/odoh_servers = $odoh/" "$DNSCRYPT_CONFIG"
                
                log "INFO" "Настройки протоколов обновлены"
                
                restart_service "dnscrypt-proxy"
                sleep 2
                ;;
                
            6)
                advanced_settings
                ;;
                
            7)
                extended_verify_config
                ;;
                
            8)
                # Используем функцию из diagnostic.sh
                test_dns_speed
                ;;
                
            9)
                # Используем функцию из diagnostic.sh
                check_dns_security
                ;;
                
            0)
                log "INFO" "Выход из настройки DNSCrypt"
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

# Проверяем, запущен ли скрипт напрямую или как модуль
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Запускаем основную функцию, если скрипт запущен напрямую
    change_dns
fi