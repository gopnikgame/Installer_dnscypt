#!/bin/bash

# Метаданные
VERSION="2.0.23"
SCRIPT_START_TIME="2025-02-16 08:03:52"
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
    
    # Если есть отсутствующие команды
    if [ ${#missing_commands[@]} -ne 0 ]; then
        log "ERROR" "Отсутствуют необходимые команды: ${missing_commands[*]}"
        
        # Определение пакетного менеджера
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
# Откат системы к исходному состоянию
rollback_system() {
    log "INFO" "=== Начало отката системы ==="
    
    # Остановка и отключение DNSCrypt
    log "INFO" "Остановка DNSCrypt..."
    systemctl stop dnscrypt-proxy 2>/dev/null || true
    systemctl disable dnscrypt-proxy 2>/dev/null || true
    
    # Удаление файлов DNSCrypt
    log "INFO" "Удаление файлов DNSCrypt..."
    rm -f "$DNSCRYPT_BIN_PATH" 2>/dev/null || true
    rm -rf "/etc/dnscrypt-proxy" 2>/dev/null || true
    rm -rf "$DNSCRYPT_CACHE_DIR" 2>/dev/null || true
    
    # Восстановление оригинальной конфигурации DNS
    log "INFO" "Восстановление конфигурации DNS..."
    if [ -f "${BACKUP_DIR}/resolv.conf.backup" ]; then
        cp -f "${BACKUP_DIR}/resolv.conf.backup" "/etc/resolv.conf"
    fi
    
    # Восстановление systemd-resolved если был
    if [ -f "${BACKUP_DIR}/resolved.conf.backup" ]; then
        cp -f "${BACKUP_DIR}/resolved.conf.backup" "/etc/systemd/resolved.conf"
        systemctl enable systemd-resolved 2>/dev/null || true
        systemctl start systemd-resolved 2>/dev/null || true
    fi
    
    # Восстановление конфигурации 3x-ui если была
    if [ -f "${BACKUP_DIR}/x-ui-config.json.backup" ]; then
        cp -f "${BACKUP_DIR}/x-ui-config.json.backup" "/usr/local/x-ui/config.json"
        systemctl restart x-ui 2>/dev/null || true
    fi
    
    # Удаление временных файлов
    rm -f "$STATE_FILE" 2>/dev/null || true
    
    log "INFO" "Откат системы завершён"
    
    # Проверка DNS-резолвинга после отката
    if ! dig @1.1.1.1 google.com +short +timeout=5 > /dev/null 2>&1; then
        log "WARN" "После отката возможны проблемы с DNS. Проверьте настройки сети"
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
        1) selected_server="${DNS_SERVERS[Cloudflare]}"
           server_name="Cloudflare DNS";;
        2) selected_server="${DNS_SERVERS[Quad9]}"
           server_name="Quad9";;
        3) selected_server="${DNS_SERVERS[OpenDNS]}"
           server_name="OpenDNS";;
        4) selected_server="${DNS_SERVERS[AdGuard]}"
           server_name="AdGuard DNS";;
        5) selected_server="${DNS_SERVERS[Anonymous Montreal]}"
           server_name="Anonymous Montreal";;
        *) log "ERROR" "Неверный выбор"
           return 1;;
    esac
    
    cp "$DNSCRYPT_CONFIG" "${DNSCRYPT_CONFIG}.backup"
    
    sed -i "s/server_names = \[[^]]*\]/server_names = ['${selected_server}']/" "$DNSCRYPT_CONFIG"
    
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

# Настройка DNS для 3x-ui
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
# Установка DNSCrypt
install_dnscrypt() {
    log "INFO" "=== Установка DNSCrypt ==="
    
    # Создание пользователя и группы
    if ! getent group "$DNSCRYPT_GROUP" >/dev/null; then
        groupadd -r "$DNSCRYPT_GROUP"
    fi
    if ! getent passwd "$DNSCRYPT_USER" >/dev/null; then
        useradd -r -g "$DNSCRYPT_GROUP" -s /bin/false -d "$DNSCRYPT_CACHE_DIR" "$DNSCRYPT_USER"
    fi
    
    # Загрузка последней версии DNSCrypt
    local latest_version=$(curl -s https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest | grep '"tag_name":' | cut -d'"' -f4)
    if [ -z "$latest_version" ]; then
        log "ERROR" "Не удалось получить последнюю версию DNSCrypt"
        return 1
    fi
    
    local arch
    case $(uname -m) in
        x86_64) arch="x86_64";;
        aarch64) arch="arm64";;
        *) log "ERROR" "Неподдерживаемая архитектура: $(uname -m)"
           return 1;;
    esac
    
    local download_url="https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${latest_version}/dnscrypt-proxy-linux_${arch}-${latest_version}.tar.gz"
    local temp_dir=$(mktemp -d)
    
    log "INFO" "Загрузка DNSCrypt версии ${latest_version}..."
    if ! wget -q "$download_url" -O "${temp_dir}/dnscrypt.tar.gz"; then
        log "ERROR" "Ошибка загрузки DNSCrypt"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Распаковка и установка
    cd "$temp_dir"
    tar xzf dnscrypt.tar.gz
    cp "linux-${arch}/dnscrypt-proxy" "$DNSCRYPT_BIN_PATH"
    chmod 755 "$DNSCRYPT_BIN_PATH"
    
    # Создание директорий и настройка прав
    mkdir -p "/etc/dnscrypt-proxy"
    mkdir -p "$DNSCRYPT_CACHE_DIR"
    chown "$DNSCRYPT_USER:$DNSCRYPT_GROUP" "$DNSCRYPT_CACHE_DIR"
    
    # Создание базовой конфигурации
    cat > "$DNSCRYPT_CONFIG" << EOL
server_names = ['cloudflare']
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

    # Создание systemd сервиса
    cat > /etc/systemd/system/dnscrypt-proxy.service << EOL
[Unit]
Description=DNSCrypt-proxy client
Documentation=https://github.com/DNSCrypt/dnscrypt-proxy/wiki
After=network.target
Before=nss-lookup.target
Wants=network.target nss-lookup.target

[Service]
NonBlocking=true
User=$DNSCRYPT_USER
Group=$DNSCRYPT_GROUP
Type=simple
ExecStart=$DNSCRYPT_BIN_PATH -config $DNSCRYPT_CONFIG
Restart=always
RestartSec=30
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOL

    # Очистка
    rm -rf "$temp_dir"
    
    # Запуск службы
    systemctl daemon-reload
    systemctl enable dnscrypt-proxy
    systemctl start dnscrypt-proxy
    
    log "SUCCESS" "DNSCrypt успешно установлен"
    return 0
}

# Проверка установки
verify_installation() {
    log "INFO" "Проверка установки DNSCrypt..."
    
    # Проверка бинарного файла
    if [ ! -x "$DNSCRYPT_BIN_PATH" ]; then
        log "ERROR" "Бинарный файл DNSCrypt не найден или не исполняемый"
        return 1
    fi
    
    # Проверка конфигурации
    if [ ! -f "$DNSCRYPT_CONFIG" ]; then
        log "ERROR" "Файл конфигурации не найден"
        return 1
    fi
    
    # Проверка службы
    if ! systemctl is-active --quiet dnscrypt-proxy; then
        log "ERROR" "Служба DNSCrypt не запущена"
        return 1
    fi
    
    # Проверка DNS резолвинга
    if ! dig @127.0.0.1 google.com +short +timeout=5 > /dev/null; then
        log "ERROR" "Тест DNS резолвинга не пройден"
        return 1
    fi
    
    log "SUCCESS" "Проверка установки успешно завершена"
    return 0
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
        return 0
    fi
    
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
