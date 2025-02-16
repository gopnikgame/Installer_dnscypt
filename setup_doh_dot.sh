#!/bin/bash

# Метаданные
VERSION="2.0.25"
SCRIPT_START_TIME="2025-02-16 08:33:45"
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

# Проверка системного состояния
check_system_state() {
    log "INFO" "Проверка состояния системы..."
    
    # Проверка загрузки системы
    local load=$(uptime | awk -F'load average:' '{ print $2 }' | cut -d, -f1)
    if (( $(echo "$load > 5.0" | bc -l) )); then
        log "WARN" "Высокая загрузка системы: $load"
    fi
    
    # Проверка свободной памяти
    local mem_total=$(free -m | awk '/^Mem:/{print $2}')
    local mem_available=$(free -m | awk '/^Mem:/{print $7}')
    local mem_percent=$((mem_available * 100 / mem_total))
    
    if [ $mem_percent -lt 20 ]; then
        log "WARN" "Мало свободной памяти: $mem_available MB ($mem_percent%)"
    fi
    
    # Проверка места на диске
    local disk_free=$(df -m / | awk 'NR==2 {print $4}')
    if [ "$disk_free" -lt 1024 ]; then
        log "ERROR" "Недостаточно места на диске: $disk_free MB"
        return 1
    fi
    
    # Проверка сетевого подключения
    if ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        log "ERROR" "Нет доступа к интернету"
        return 1
    fi
    
    log "SUCCESS" "Проверка состояния системы успешна"
    return 0
}

# Проверка порта 53
check_port_53() {
    log "INFO" "Проверка порта 53..."
    local port_in_use=false
    local service_using=""
    
    # Проверка использования порта
    if ss -lntu | grep -q ':53 '; then
        port_in_use=true
        
        # Определение сервиса, использующего порт
        if systemctl is-active --quiet systemd-resolved; then
            service_using="systemd-resolved"
        elif systemctl is-active --quiet named; then
            service_using="named (BIND)"
        elif systemctl is-active --quiet dnsmasq; then
            service_using="dnsmasq"
        else
            service_using="неизвестный сервис"
        fi
        
        log "WARN" "Порт 53 занят сервисом: $service_using"
        
        # Обработка различных сервисов
        case $service_using in
            "systemd-resolved")
                log "INFO" "Отключение systemd-resolved..."
                systemctl stop systemd-resolved
                systemctl disable systemd-resolved
                if [ -f "/etc/resolv.conf" ]; then
                    cp "/etc/resolv.conf" "${BACKUP_DIR}/resolv.conf.backup"
                    echo "nameserver 8.8.8.8" > "/etc/resolv.conf"
                fi
                ;;
            "named (BIND)")
                log "INFO" "Отключение BIND..."
                systemctl stop named
                systemctl disable named
                ;;
            "dnsmasq")
                log "INFO" "Отключение dnsmasq..."
                systemctl stop dnsmasq
                systemctl disable dnsmasq
                ;;
            *)
                log "ERROR" "Не удалось определить сервис, использующий порт 53"
                return 1
                ;;
        esac
        
        # Повторная проверка порта
        if ss -lntu | grep -q ':53 '; then
            log "ERROR" "Не удалось освободить порт 53"
            return 1
        fi
    fi
    
    log "SUCCESS" "Порт 53 доступен"
    return 0
}

# Создание резервных копий
create_backup() {
    log "INFO" "Создание резервных копий..."
    
    # Создание директории для бэкапов
    mkdir -p "$BACKUP_DIR"
    
    # Бэкап DNS конфигурации
    if [ -f "/etc/resolv.conf" ]; then
        cp -p "/etc/resolv.conf" "${BACKUP_DIR}/resolv.conf.backup"
    fi
    
    # Бэкап systemd-resolved конфигурации
    if [ -f "/etc/systemd/resolved.conf" ]; then
        cp -p "/etc/systemd/resolved.conf" "${BACKUP_DIR}/resolved.conf.backup"
    fi
    
    # Бэкап конфигурации DNSCrypt если есть
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        cp -p "$DNSCRYPT_CONFIG" "${BACKUP_DIR}/dnscrypt-proxy.toml.backup"
    fi
    
    # Бэкап конфигурации 3x-ui если есть
    if [ -f "/usr/local/x-ui/config.json" ]; then
        cp -p "/usr/local/x-ui/config.json" "${BACKUP_DIR}/x-ui-config.json.backup"
    fi
    
    log "SUCCESS" "Резервные копии созданы в $BACKUP_DIR"
    return 0
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

# Проверка системных требований
check_prerequisites() {
    log "INFO" "Проверка необходимых компонентов..."
    
    local required_commands=("curl" "wget" "tar" "systemctl" "dig" "ss" "useradd" "groupadd" "sed" "grep")
    local missing_commands=()
    local missing_packages=()
    
    # Проверка наличия команд
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
            case "$cmd" in
                "curl") missing_packages+=("curl");;
                "wget") missing_packages+=("wget");;
                "tar") missing_packages+=("tar");;
                "systemctl") missing_packages+=("systemd");;
                "dig") missing_packages+=("dnsutils" "bind-utils");;
                "ss") missing_packages+=("iproute2");;
                "useradd"|"groupadd") missing_packages+=("shadow-utils");;
                "sed"|"grep") missing_packages+=("grep" "sed");;
            esac
        fi
    done
    # Если есть отсутствующие команды, пытаемся их установить
    if [ ${#missing_commands[@]} -ne 0 ]; then
        log "ERROR" "Отсутствуют необходимые команды: ${missing_commands[*]}"
        
        # Определение пакетного менеджера и установка пакетов
        if command -v apt-get >/dev/null 2>&1; then
            log "INFO" "Обнаружен apt-get, установка необходимых пакетов..."
            apt-get update
            apt-get install -y ${missing_packages[@]}
        elif command -v yum >/dev/null 2>&1; then
            log "INFO" "Обнаружен yum, установка необходимых пакетов..."
            yum install -y ${missing_packages[@]}
        elif command -v dnf >/dev/null 2>&1; then
            log "INFO" "Обнаружен dnf, установка необходимых пакетов..."
            dnf install -y ${missing_packages[@]}
        else
            log "ERROR" "Не удалось определить пакетный менеджер"
            log "INFO" "Установите вручную следующие пакеты: ${missing_packages[*]}"
            return 1
        fi
        
        # Повторная проверка после установки
        for cmd in "${required_commands[@]}"; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                log "ERROR" "Не удалось установить все необходимые компоненты"
                return 1
            fi
        done
    fi
    
    # Проверка версии системы
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        log "INFO" "Обнаружена система: $PRETTY_NAME"
    else
        log "WARN" "Не удалось определить версию системы"
    fi
    
    # Проверка архитектуры
    local arch=$(uname -m)
    case "$arch" in
        x86_64|aarch64)
            log "INFO" "Поддерживаемая архитектура: $arch"
            ;;
        *)
            log "ERROR" "Неподдерживаемая архитектура: $arch"
            return 1
            ;;
    esac
    
    # Проверка свободного места
    local free_space=$(df -k /usr/local/bin | awk 'NR==2 {print $4}')
    if [ "$free_space" -lt 102400 ]; then # Минимум 100MB
        log "ERROR" "Недостаточно свободного места: $free_space KB (требуется минимум 100MB)"
        return 1
    fi
    
    log "SUCCESS" "Все необходимые компоненты присутствуют"
    return 0
}

# Диагностика DNSCrypt
diagnose_dnscrypt() {
    log "INFO" "=== Запуск диагностики DNSCrypt ==="
    local issues=0
    
    echo
    echo "🔍 Начинаю комплексную проверку DNSCrypt..."
    echo
    
    # Проверка службы
    echo "1️⃣ Проверка статуса службы DNSCrypt:"
    if systemctl is-active --quiet dnscrypt-proxy; then
        local uptime=$(systemctl show dnscrypt-proxy --property=ActiveEnterTimestamp | cut -d'=' -f2)
        echo "✅ Служба DNSCrypt активна"
        echo "ℹ️ Время работы с: $uptime"
    else
        echo "❌ Служба DNSCrypt не запущена!"
        systemctl status dnscrypt-proxy
        issues=$((issues + 1))
    fi
    
    # Проверка конфигурации
    echo -e "\n2️⃣ Проверка конфигурации:"
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        echo "✅ Конфигурационный файл найден"
        local current_server=$(grep "server_names" "$DNSCRYPT_CONFIG" | cut -d"'" -f2)
        echo "ℹ️ Текущий DNS сервер: $current_server"
    else
        echo "❌ Конфигурационный файл отсутствует!"
        issues=$((issues + 1))
    fi
    
    # Тест разрешения имён
    echo -e "\n3️⃣ Тест разрешения доменных имён:"
    local test_domains=("google.com" "cloudflare.com" "github.com")
    for domain in "${test_domains[@]}"; do
        echo -n "🌐 Тестирование $domain: "
        if dig @127.0.0.1 "$domain" +short +timeout=5 > /dev/null; then
            local resolve_time=$(dig @127.0.0.1 "$domain" +noall +stats | grep "Query time" | cut -d':' -f2-)
            echo "✅ OK$resolve_time"
        else
            echo "❌ Ошибка"
            issues=$((issues + 1))
        fi
    done
    
    # Проверка логов
    echo -e "\n4️⃣ Анализ логов:"
    if [ -f "/var/log/dnscrypt-proxy/dnscrypt-proxy.log" ]; then
        local errors=$(grep -i "error\|failed\|warning" /var/log/dnscrypt-proxy/dnscrypt-proxy.log | tail -n 5)
        if [ -n "$errors" ]; then
            echo "⚠️ Найдены ошибки в логах:"
            echo "$errors"
            issues=$((issues + 1))
        else
            echo "✅ Ошибок в логах не обнаружено"
        fi
    else
        echo "⚠️ Лог-файл не найден"
    fi
    
    # Итоговый отчёт
    echo -e "\n=== Результаты диагностики ==="
    if [ $issues -eq 0 ]; then
        log "SUCCESS" "Все проверки пройдены успешно!"
    else
        log "WARN" "Обнаружено проблем: $issues"
        echo "📋 Рекомендации:"
        echo "   1. Проверьте логи: /var/log/dnscrypt-proxy/dnscrypt-proxy.log"
        echo "   2. Проверьте конфигурацию: $DNSCRYPT_CONFIG"
        echo "   3. При необходимости перезапустите службу: systemctl restart dnscrypt-proxy"
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