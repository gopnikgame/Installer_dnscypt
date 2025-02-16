#!/bin/bash

# Метаданные
VERSION="2.0.21"
SCRIPT_START_TIME="2025-02-16 07:39:59"
CURRENT_USER="gopnikgame"

# Константы
DNSCRYPT_USER="dnscrypt"
DNSCRYPT_GROUP="dnscrypt"
DNSCRYPT_BIN_PATH="/usr/local/bin/dnscrypt-proxy"
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
DNSCRYPT_CACHE_DIR="/var/cache/dnscrypt-proxy"
BACKUP_DIR="/var/backup/dns_$(date +%Y%m%d_%H%M%S)"
DEBUG_DIR="/var/log/dnscrypt"
LOG_FILE="${DEBUG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
STATE_FILE="/tmp/dnscrypt_install_state"

# Создаём директорию для отладки
mkdir -p "$DEBUG_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Конфигурации DNS серверов
declare -A DNS_SERVERS=(
    ["Cloudflare"]="cloudflare"
    ["Quad9"]="quad9"
    ["OpenDNS"]="opendns"
    ["AdGuard"]="adguard-dns"
    ["Anonymous Montreal"]="anon-cs-montreal"
)

# Функция логирования
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local caller_info=""
    
    if [ "$level" = "DEBUG" ] || [ "$level" = "ERROR" ]; then
        local caller_function="${FUNCNAME[1]}"
        local caller_line="${BASH_LINENO[0]}"
        caller_info="($caller_function:$caller_line)"
    fi
    
    local log_message="$timestamp [$level] $caller_info $message"
    echo "$log_message" >> "$LOG_FILE"
    
    case "$level" in
        "ERROR")
            echo -e "\e[31m$log_message\e[0m" >&2
            ;;
        "WARN")
            echo -e "\e[33m$log_message\e[0m"
            ;;
        "SUCCESS")
            echo -e "\e[32m$log_message\e[0m"
            ;;
        "INFO")
            echo "$log_message"
            ;;
        "DEBUG")
            if [ "${DEBUG:-false}" = "true" ]; then
                echo -e "\e[34m$log_message\e[0m"
            fi
            ;;
    esac
}

# Настройка обработки ошибок
set -o errexit
set -o pipefail
set -o nounset

# Проверка root прав
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
    log "INFO" "Root права подтверждены"
}

# Установка русской локали
setup_russian_locale() {
    log "INFO" "Проверка поддержки русского языка..."
    
    if ! locale -a | grep -q "ru_RU.utf8"; then
        log "INFO" "Установка русской локали..."
        
        if [ -f /etc/debian_version ]; then
            apt-get update
            apt-get install -y locales
            sed -i 's/# ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
            locale-gen ru_RU.UTF-8
        elif [ -f /etc/fedora-release ]; then
            dnf install -y glibc-langpack-ru
        elif [ -f /etc/centos-release ]; then
            yum install -y glibc-langpack-ru
        else
            log "WARN" "Неизвестная система, установка локали может не удаться"
            return 1
        fi
    fi
    
    export LANG=ru_RU.UTF-8
    export LC_ALL=ru_RU.UTF-8
    
    if locale | grep -q "ru_RU.UTF-8"; then
        log "SUCCESS" "Русская локаль успешно установлена"
        return 0
    else
        log "ERROR" "Не удалось установить русскую локаль"
        return 1
    fi
}

# Проверка установки DNSCrypt
check_dnscrypt_installed() {
    log "INFO" "Проверка установки DNSCrypt..."
    if [ -f "$DNSCRYPT_BIN_PATH" ] && systemctl is-active --quiet dnscrypt-proxy; then
        log "INFO" "DNSCrypt установлен и работает"
        return 0
    else
        log "INFO" "DNSCrypt не установлен"
        return 1
    fi
}

# Проверка установки 3x-ui
check_3xui_installed() {
    log "INFO" "Проверка установки 3x-ui..."
    if [ -f "/usr/local/x-ui/x-ui" ] && systemctl is-active --quiet x-ui; then
        log "INFO" "3x-ui установлен и работает"
        return 0
    else
        log "INFO" "3x-ui не установлен"
        return 1
    fi
}

# Сохранение состояния установки
save_state() {
    echo "$1" > "$STATE_FILE"
}

# Проверка системных требований
check_prerequisites() {
    log "INFO" "Проверка необходимых компонентов..."
    
    local required_commands=("curl" "wget" "tar" "systemctl" "dig" "ss")
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [ ${#missing_commands[@]} -ne 0 ]; then
        log "ERROR" "Отсутствуют необходимые команды: ${missing_commands[*]}"
        log "INFO" "Установите: ${missing_commands[*]}"
        return 1
    fi
    
    log "INFO" "Все необходимые компоненты присутствуют"
    return 0
}

# Функция диагностики DNSCrypt
diagnose_dnscrypt() {
    log "INFO" "=== Запуск диагностики DNSCrypt ==="
    local issues=0

    echo
    echo "🔍 Начинаю комплексную проверку DNSCrypt..."
    echo

    # 1. Проверка службы DNSCrypt
    echo "1️⃣ Проверка статуса службы DNSCrypt:"
    if systemctl is-active --quiet dnscrypt-proxy; then
        echo "✅ Служба DNSCrypt активна и работает"
        
        # Получение времени работы службы
        local uptime=$(systemctl show dnscrypt-proxy --property=ActiveEnterTimestamp | cut -d'=' -f2)
        echo "ℹ️ Время работы с: $uptime"
    else
        echo "❌ Служба DNSCrypt не запущена!"
        systemctl status dnscrypt-proxy
        issues=$((issues + 1))
    fi
    echo

    # 2. Проверка текущего DNS сервера
    echo "2️⃣ Проверка текущего DNS сервера:"
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        local current_server=$(grep "server_names" "$DNSCRYPT_CONFIG" | cut -d"'" -f2)
        echo "ℹ️ Текущий DNS сервер: $current_server"
        
        # Получение статистики использования
        if [ -f "/var/log/dnscrypt-proxy/dnscrypt-proxy.log" ]; then
            echo "📊 Статистика запросов:"
            tail -n 50 /var/log/dnscrypt-proxy/dnscrypt-proxy.log | grep -i "server" | tail -n 5
        fi
    else
        echo "❌ Конфигурационный файл DNSCrypt не найден!"
        issues=$((issues + 1))
    fi
    echo

    # 3. Тестирование разрешения имён
    echo "3️⃣ Тест разрешения доменных имён:"
    local test_domains=("google.com" "cloudflare.com" "github.com")
    
    for domain in "${test_domains[@]}"; do
        echo -n "🌐 Тестирование $domain: "
        if dig @127.0.0.1 "$domain" +short +timeout=5 > /dev/null 2>&1; then
            local resolve_time=$(dig @127.0.0.1 "$domain" +noall +stats | grep "Query time" | cut -d':' -f2-)
            echo "✅ OK $resolve_time"
        else
            echo "❌ Ошибка разрешения"
            issues=$((issues + 1))
        fi
    done
    echo

    # 4. Проверка подключения к интернету
    echo "4️⃣ Проверка доступа в интернет:"
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "✅ Интернет-соединение работает"
    else
        echo "❌ Проблемы с интернет-соединением"
        issues=$((issues + 1))
    fi
    echo

    # 5. Проверка логов на наличие ошибок
    echo "5️⃣ Анализ логов DNSCrypt:"
    if [ -f "/var/log/dnscrypt-proxy/dnscrypt-proxy.log" ]; then
        local errors=$(grep -i "error\|failed\|warning" /var/log/dnscrypt-proxy/dnscrypt-proxy.log | tail -n 5)
        if [ -n "$errors" ]; then
            echo "⚠️ Последние ошибки в логах:"
            echo "$errors"
            issues=$((issues + 1))
        else
            echo "✅ Ошибок в логах не обнаружено"
        fi
    else
        echo "❌ Лог-файл не найден"
        issues=$((issues + 1))
    fi
    echo

    # 6. Проверка конфигурации
    echo "6️⃣ Проверка конфигурации DNSCrypt:"
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        echo "📄 Текущие настройки:"
        grep -E "server_names|listen_addresses|require_dnssec|require_nolog|cache" "$DNSCRYPT_CONFIG" | while read -r line; do
            echo "   $line"
        done
    else
        echo "❌ Файл конфигурации не найден"
        issues=$((issues + 1))
    fi
    echo

    # Итоговый отчёт
    echo "=== Результаты диагностики ==="
    if [ $issues -eq 0 ]; then
        echo "✅ Все проверки пройдены успешно!"
    else
        echo "⚠️ Обнаружено проблем: $issues"
        echo "📋 Рекомендации:"
        echo "   1. Проверьте логи: /var/log/dnscrypt-proxy/dnscrypt-proxy.log"
        echo "   2. Проверьте конфигурацию: $DNSCRYPT_CONFIG"
        echo "   3. При необходимости перезапустите службу: systemctl restart dnscrypt-proxy"
    fi
}

# Изменение DNS сервера
change_dns_server() {
    log "INFO" "=== Изменение DNS сервера ==="
    
    echo
    echo "Доступные DNS серверы:"
    echo "1) Cloudflare DNS (Быстрый, ориентирован на приватность)"
    echo "2) Quad9 (Повышенная безопасность, блокировка вредоносных доменов)"
    echo "3) OpenDNS (Семейный фильтр, блокировка нежелательного контента)"
    echo "4) AdGuard DNS (Блокировка рекламы и трекеров)"
    echo "5) Anonymous Montreal (Анонимный релей через Канаду)"
    echo
    
    read -p "Выберите DNS сервер (1-5): " dns_choice
    echo
    
    case $dns_choice in
        1) selected_server="cloudflare"
           server_name="Cloudflare DNS";;
        2) selected_server="quad9"
           server_name="Quad9";;
        3) selected_server="opendns"
           server_name="OpenDNS";;
        4) selected_server="adguard-dns"
           server_name="AdGuard DNS";;
        5) selected_server="anon-cs-montreal"
           server_name="Anonymous Montreal";;
        *) log "ERROR" "Неверный выбор"
           return 1;;
    esac
    
    cp "$DNSCRYPT_CONFIG" "${DNSCRYPT_CONFIG}.backup"
    
    log "INFO" "Обновление конфигурации DNSCrypt для использования $server_name..."
    
    cat > "$DNSCRYPT_CONFIG" << EOL
server_names = ['${selected_server}']
listen_addresses = ['127.0.0.1:53']
max_clients = 250
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = true
doh_servers = true
require_dnssec = true
require_nolog = true
require_nofilter = true
force_tcp = false
timeout = 5000
keepalive = 30
log_level = 2
use_syslog = true
cache = true
cache_size = 4096
cache_min_ttl = 2400
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600
[sources]
  [sources.'public-resolvers']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md']
  cache_file = 'public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 72
  prefix = ''
EOL

    systemctl restart dnscrypt-proxy
    
    if systemctl is-active --quiet dnscrypt-proxy; then
        if dig @127.0.0.1 google.com +short +timeout=5 > /dev/null 2>&1; then
            log "SUCCESS" "DNS сервер успешно изменён на $server_name"
            return 0
        else
            log "ERROR" "Тест разрешения DNS не пройден"
            mv "${DNSCRYPT_CONFIG}.backup" "$DNSCRYPT_CONFIG"
            systemctl restart dnscrypt-proxy
            return 1
        fi
    else
        log "ERROR" "Служба DNSCrypt не запустилась"
        mv "${DNSCRYPT_CONFIG}.backup" "$DNSCRYPT_CONFIG"
        systemctl restart dnscrypt-proxy
        return 1
    fi
}

# Функция настройки DNS для 3x-ui
configure_3xui_dns() {
    log "INFO" "=== Настройка DNS для 3x-ui ==="
    
    local xui_config="/usr/local/x-ui/config.json"
    
    if [ ! -f "$xui_config" ]; then
        log "ERROR" "Конфигурационный файл 3x-ui не найден"
        return 1
    fi
    
    cp "$xui_config" "${xui_config}.backup"
    
    local current_dns=$(grep -o '"dns_server":"[^"]*"' "$xui_config" | cut -d'"' -f4)
    log "INFO" "Текущий DNS сервер в 3x-ui: $current_dns"
    
    sed -i 's/"dns_server":"[^"]*"/"dns_server":"127.0.0.1"/' "$xui_config"
    
    systemctl restart x-ui
    
    if systemctl is-active --quiet x-ui; then
        log "SUCCESS" "Настройка DNS для 3x-ui выполнена успешно"
        return 0
    else
        log "ERROR" "Не удалось перезапустить 3x-ui"
        mv "${xui_config}.backup" "$xui_config"
        systemctl restart x-ui
        return 1
    fi
}

# Основная функция
main() {
    log "INFO" "Запуск скрипта (Версия: $VERSION)"
    log "INFO" "Время запуска: $SCRIPT_START_TIME"
    log "INFO" "Текущий пользователь: $CURRENT_USER"
    
    check_root || exit 1
    setup_russian_locale || log "WARN" "Продолжаем работу без русской локали"
    
    if ! check_dnscrypt_installed; then
        log "INFO" "DNSCrypt не установлен, начинаем установку..."
        check_prerequisites || exit 1
        check_system_state || exit 1
        check_port_53 || exit 1
        create_backup || exit 1
        
        if ! install_dnscrypt; then
            log "ERROR" "Установка не удалась"
            rollback_system
            exit 1
        fi
        
        if ! verify_installation; then
            log "ERROR" "Проверка установки не удалась"
            rollback_system
            exit 1
        fi
        
        log "SUCCESS" "Установка DNSCrypt успешно завершена"
        log "INFO" "Перезапустите скрипт для настройки интеграции с 3x-ui"
        exit 0
    else
        echo
        echo "DNSCrypt установлен. Выберите действие:"
        echo "1) Изменить DNS сервер"
        echo "2) Настроить интеграцию с 3x-ui"
        echo "3) Запустить диагностику DNSCrypt"
        echo "4) Выход"
        echo
        read -p "Выберите действие (1-4): " option
        echo
        
        case $option in
            1)
                change_dns_server
                ;;
            2)
                if ! check_3xui_installed; then
                    log "ERROR" "3x-ui не установлен. Установите 3x-ui командой:"
                    log "INFO" "bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)"
                    exit 1
                fi
                
                echo "Настроить 3x-ui для работы через DNSCrypt?"
                echo "Будет выполнено:"
                echo "1. Обновление настроек DNS в 3x-ui на localhost (127.0.0.1)"
                echo "2. Перезапуск службы 3x-ui"
                echo "3. Создание резервной копии настроек"
                echo
                read -p "Продолжить? (д/н): " -n 1 -r
                echo
                
                if [[ $REPLY =~ ^[ДдYy]$ ]]; then
                    if configure_3xui_dns; then
                        log "SUCCESS" "3x-ui успешно настроен"
                        log "INFO" "Настройка завершена!"
                    else
                        log "ERROR" "Ошибка настройки DNS для 3x-ui"
                        exit 1
                    fi
                else
                    log "INFO" "Настройка отменена пользователем"
                    exit 0
                fi
                ;;
            3)
                diagnose_dnscrypt
                ;;
            4)
                log "INFO" "Выход из программы..."
                exit 0
                ;;
            *)
                log "ERROR" "Неверный выбор"
                exit 1
                ;;
        esac
    fi
}

# Функция очистки
cleanup() {
    local exit_code=$?
    log "INFO" "Завершение работы скрипта с кодом: $exit_code"
    if [ $exit_code -ne 0 ]; then
        log "ERROR" "Скрипт завершился с ошибкой $exit_code"
        rollback_system
    fi
    exit $exit_code
}

# Устанавливаем trap для очистки
trap cleanup EXIT

# Запускаем основную функцию
main