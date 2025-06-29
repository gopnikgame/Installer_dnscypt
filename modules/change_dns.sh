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

# Функция для применения новых настроек
apply_settings() {
    local server_name="$1"
    local dnssec="$2"
    local nolog="$3"
    local nofilter="$4"
    local ipv4="$5"
    local ipv6="$6"
    local dnscrypt="$7"
    local doh="$8"
    local odoh="$9"
    local http3="${10}"
    local block_ipv6="${11}"
    local cache="${12}"
    local hot_reload="${13}"

    # Создаем резервную копию перед изменениями
    backup_config "$DNSCRYPT_CONFIG" "dnscrypt-proxy"

    # Обновление настроек в конфигурационном файле
    sed -i "s/server_names = .*/server_names = $server_name/" "$DNSCRYPT_CONFIG"
    sed -i "s/require_dnssec = .*/require_dnssec = $dnssec/" "$DNSCRYPT_CONFIG"
    sed -i "s/require_nolog = .*/require_nolog = $nolog/" "$DNSCRYPT_CONFIG"
    sed -i "s/require_nofilter = .*/require_nofilter = $nofilter/" "$DNSCRYPT_CONFIG"
    sed -i "s/ipv4_servers = .*/ipv4_servers = $ipv4/" "$DNSCRYPT_CONFIG"
    sed -i "s/ipv6_servers = .*/ipv6_servers = $ipv6/" "$DNSCRYPT_CONFIG"
    sed -i "s/dnscrypt_servers = .*/dnscrypt_servers = $dnscrypt/" "$DNSCRYPT_CONFIG"
    sed -i "s/doh_servers = .*/doh_servers = $doh/" "$DNSCRYPT_CONFIG"
    sed -i "s/odoh_servers = .*/odoh_servers = $odoh/" "$DNSCRYPT_CONFIG"
    
    # Настройки HTTP/3
    if grep -q "http3 = " "$DNSCRYPT_CONFIG"; then
        sed -i "s/http3 = .*/http3 = $http3/" "$DNSCRYPT_CONFIG"
    else
        # Если параметра нет, добавляем его
        sed -i "/\[dnscrypt\]/a http3 = $http3" "$DNSCRYPT_CONFIG"
    fi
    
    # Блокировка IPv6
    if grep -q "block_ipv6 = " "$DNSCRYPT_CONFIG"; then
        sed -i "s/block_ipv6 = .*/block_ipv6 = $block_ipv6/" "$DNSCRYPT_CONFIG"
    else
        # Если параметра нет, добавляем его
        sed -i "/\[query_log\]/i block_ipv6 = $block_ipv6" "$DNSCRYPT_CONFIG"
    fi
    
    # Настройки кэша
    if grep -q "cache = " "$DNSCRYPT_CONFIG"; then
        sed -i "s/cache = .*/cache = $cache/" "$DNSCRYPT_CONFIG"
    else
        # Если параметра нет, добавляем его
        sed -i "/\[sources\]/i cache = $cache" "$DNSCRYPT_CONFIG"
    fi
    
    # Горячая перезагрузка
    if grep -q "enable_hot_reload = " "$DNSCRYPT_CONFIG"; then
        sed -i "s/enable_hot_reload = .*/enable_hot_reload = $hot_reload/" "$DNSCRYPT_CONFIG"
    else
        # Если параметра нет, добавляем его
        sed -i "/\[query_log\]/i enable_hot_reload = $hot_reload" "$DNSCRYPT_CONFIG"
    fi

    log "INFO" "Настройки обновлены"
    
    # Перезапускаем службу
    restart_service "dnscrypt-proxy"
    sleep 2

    # Проверяем применение настроек
    verify_settings "$(echo $server_name | sed 's/\[\|\]//g' | sed "s/'//g" | cut -d',' -f1)"
}

# Настройка HTTP/3 для DoH
configure_http3() {
    safe_echo "\n${BLUE}Настройка HTTP/3 (QUIC) для DNS-over-HTTPS:${NC}"
    echo "HTTP/3 - новый протокол, использующий UDP вместо TCP, что может улучшить скорость"
    echo "и устойчивость соединения, особенно в сетях с большими потерями пакетов."
    echo
    echo "1) Включить HTTP/3 (для серверов, поддерживающих его)"
    echo "2) Включить пробу HTTP/3 (пытаться использовать HTTP/3 для всех DoH серверов)"
    echo "3) Выключить HTTP/3"
    echo "0) Назад"
    
    read -p "Выберите опцию (0-3): " http3_option
    
    case $http3_option in
        1)
            # Включаем HTTP/3, но не пробу
            if grep -q "http3 = " "$DNSCRYPT_CONFIG"; then
                sed -i "s/http3 = .*/http3 = true/" "$DNSCRYPT_CONFIG"
            else
                sed -i "/\[dnscrypt\]/a http3 = true" "$DNSCRYPT_CONFIG"
            fi
            
            if grep -q "http3_probe = " "$DNSCRYPT_CONFIG"; then
                sed -i "s/http3_probe = .*/http3_probe = false/" "$DNSCRYPT_CONFIG"
            else
                sed -i "/http3 = true/a http3_probe = false" "$DNSCRYPT_CONFIG"
            fi
            
            log "SUCCESS" "HTTP/3 включен"
            ;;
        2)
            # Включаем HTTP/3 и пробу
            if grep -q "http3 = " "$DNSCRYPT_CONFIG"; then
                sed -i "s/http3 = .*/http3 = true/" "$DNSCRYPT_CONFIG"
            else
                sed -i "/\[dnscrypt\]/a http3 = true" "$DNSCRYPT_CONFIG"
            fi
            
            if grep -q "http3_probe = " "$DNSCRYPT_CONFIG"; then
                sed -i "s/http3_probe = .*/http3_probe = true/" "$DNSCRYPT_CONFIG"
            else
                sed -i "/http3 = true/a http3_probe = true" "$DNSCRYPT_CONFIG"
            fi
            
            log "SUCCESS" "HTTP/3 и проба HTTP/3 включены"
            ;;
        3)
            # Отключаем HTTP/3
            if grep -q "http3 = " "$DNSCRYPT_CONFIG"; then
                sed -i "s/http3 = .*/http3 = false/" "$DNSCRYPT_CONFIG"
            else
                sed -i "/\[dnscrypt\]/a http3 = false" "$DNSCRYPT_CONFIG"
            fi
            
            if grep -q "http3_probe = " "$DNSCRYPT_CONFIG"; then
                sed -i "s/http3_probe = .*/http3_probe = false/" "$DNSCRYPT_CONFIG"
            fi
            
            log "SUCCESS" "HTTP/3 отключен"
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

# Добавляем функцию выбора серверов по географическим локациям
configure_geo_servers() {
    safe_echo "\n${BLUE}Выбор DNS серверов по географическому расположению:${NC}"
    echo "1) Северная Америка (Торонто, Лос-Анджелес)"
    echo "2) Европа (Амстердам, Франкфурт, Париж)"
    echo "3) Азия (Токио, Фуджейра, Сидней)"
    echo "4) Ручной выбор основного сервера"
    echo "0) Отмена"
    
    read -p "Выберите регион (0-4): " geo_choice
    
    local server_name=""
    case $geo_choice in
        1)
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
        2)
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
        3)
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
        4)
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
        # Обновляем основные настройки серверов
        sed -i "s/server_names = .*/server_names = $server_name/" "$DNSCRYPT_CONFIG"
        
        # Настраиваем балансировку нагрузки
        if grep -q "lb_strategy = " "$DNSCRYPT_CONFIG"; then
            sed -i "s/lb_strategy = .*/lb_strategy = 'ph'/" "$DNSCRYPT_CONFIG"
        else
            sed -i "/server_names = /a lb_strategy = 'ph'" "$DNSCRYPT_CONFIG"
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
        echo "1) Настройка серверов по географическому расположению"
        echo "2) Изменить DNS сервер вручную"
        echo "3) Настройки безопасности (DNSSEC, NoLog, NoFilter)"
        echo "4) Настройки протоколов (IPv4/IPv6, DNSCrypt/DoH/ODoH)"
        echo "5) Расширенные настройки"
        echo "6) Проверить текущую конфигурацию"
        echo "7) Тестировать скорость DNS серверов"
        echo "8) Проверка безопасности DNS"
        echo "0) Выход"
        
        read -p "Выберите опцию (0-8): " main_choice
        
        case $main_choice in
            1)
                configure_geo_servers
                ;;
            
            2)
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
                    sed -i "s/server_names = .*/server_names = $server_name/" "$DNSCRYPT_CONFIG"
                    log "INFO" "DNS сервер изменен на $server_name"
                    
                    restart_service "dnscrypt-proxy"
                    sleep 2
                    
                    verify_settings "$(echo $server_name | sed 's/\[\|\]//g' | sed "s/'//g" | cut -d',' -f1)"
                fi
                ;;
            
            3)
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
                
                # Обновляем настройки
                sed -i "s/require_dnssec = .*/require_dnssec = $dnssec/" "$DNSCRYPT_CONFIG"
                sed -i "s/require_nolog = .*/require_nolog = $nolog/" "$DNSCRYPT_CONFIG"
                sed -i "s/require_nofilter = .*/require_nofilter = $nofilter/" "$DNSCRYPT_CONFIG"
                
                log "INFO" "Настройки безопасности обновлены"
                
                restart_service "dnscrypt-proxy"
                sleep 2
                ;;
                
            4)
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
                
            5)
                advanced_settings
                ;;
                
            6)
                extended_verify_config
                ;;
                
            7)
                # Используем функцию из diagnostic.sh
                test_dns_speed
                ;;
                
            8)
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