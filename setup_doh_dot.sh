#!/bin/bash

# Метаданные
VERSION="2.0.31"
SCRIPT_START_TIME="2025-02-16 10:35:30"
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

# Сохранение состояния установки
save_state() {
    echo "$1" > "$STATE_FILE"
}

# Функции подготовки системы

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
            return 1
        fi
    fi
    
    log "SUCCESS" "Все необходимые компоненты присутствуют"
    return 0
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
    
    # Проверяем различными способами
    local port_in_use=false
    
    # Проверка через ss
    if ss -lntu | grep -q ':53 .*LISTEN'; then
        port_in_use=true
    fi
    
    # Проверка через netstat (для старых систем)
    if ! $port_in_use && command -v netstat >/dev/null 2>&1; then
        if netstat -lnp | grep -q ':53 .*LISTEN'; then
            port_in_use=true
        fi
    fi
    
    if $port_in_use; then
        local service_name=""
        
        # Проверяем известные службы DNS
        for service in systemd-resolved named dnsmasq bind9; do
            if systemctl is-active --quiet $service; then
                service_name="$service"
                log "INFO" "Обнаружен активный DNS сервис: $service"
                
                # Создаем резервную копию resolv.conf
                if [ -f "/etc/resolv.conf" ]; then
                    cp "/etc/resolv.conf" "${BACKUP_DIR}/resolv.conf.backup.${service}"
                fi
                
                # Останавливаем и отключаем сервис
                systemctl stop $service
                systemctl disable $service
                log "INFO" "Отключен сервис: $service_name"
                
                # Проверяем успешность остановки
                if systemctl is-active --quiet $service; then
                    log "ERROR" "Не удалось остановить сервис $service"
                    return 1
                fi
                break
            fi
        done
        
        # Проверяем, освободился ли порт
        sleep 2
        if ss -lntu | grep -q ':53 .*LISTEN'; then
            log "ERROR" "Не удалось освободить порт 53"
            log "DEBUG" "Процессы, использующие порт 53:"
            if command -v lsof >/dev/null 2>&1; then
                lsof -i :53
            else
                netstat -tulpn | grep ':53'
            fi
            return 1
        fi
    fi
    
    # Проверяем, что порт действительно свободен
    if ! nc -z localhost 53 2>/dev/null; then
        log "SUCCESS" "Порт 53 доступен"
        return 0
    else
        log "ERROR" "Порт 53 все еще занят"
        return 1
    fi
}

# Создание резервных копий
create_backup() {
    log "INFO" "Создание резервных копий..."
    mkdir -p "$BACKUP_DIR"
    
    local files_to_backup=(
        "/etc/resolv.conf"
        "/etc/systemd/resolved.conf"
        "$DNSCRYPT_CONFIG"
        "/usr/local/x-ui/config.json"
    )
    
    for file in "${files_to_backup[@]}"; do
        if [ -f "$file" ]; then
            cp -p "$file" "${BACKUP_DIR}/$(basename "$file").backup"
        fi
    done
    
    log "SUCCESS" "Резервные копии созданы в $BACKUP_DIR"
    return 0
}


# Установка DNSCrypt
install_dnscrypt() {
    log "INFO" "=== Установка DNSCrypt ==="
    local installation_steps=0
    local total_steps=8
    
    # Шаг 1: Создание пользователя и группы
    log "INFO" "(Шаг 1/$total_steps) Создание системного пользователя и группы..."
    if ! getent group "$DNSCRYPT_GROUP" >/dev/null; then
        groupadd -r "$DNSCRYPT_GROUP"
    fi
    if ! getent passwd "$DNSCRYPT_USER" >/dev/null; then
        useradd -r -g "$DNSCRYPT_GROUP" -s /bin/false -d "$DNSCRYPT_CACHE_DIR" "$DNSCRYPT_USER"
    fi
    installation_steps=$((installation_steps + 1))
    
    # Шаг 2: Получение последней версии
    log "INFO" "(Шаг 2/$total_steps) Получение информации о последней версии..."
    local latest_version
    latest_version=$(curl -s https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest | grep '"tag_name":' | cut -d'"' -f4)
    if [ -z "$latest_version" ]; then
        log "ERROR" "Не удалось получить информацию о последней версии DNSCrypt"
        return 1
    fi
    installation_steps=$((installation_steps + 1))
    
    # Шаг 3: Определение архитектуры и загрузка
    log "INFO" "(Шаг 3/$total_steps) Определение архитектуры и загрузка файлов..."
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
    installation_steps=$((installation_steps + 1))
    
    # Шаг 4: Установка файлов
    log "INFO" "(Шаг 4/$total_steps) Установка файлов..."
    cd "$temp_dir"
    if ! tar xzf dnscrypt.tar.gz; then
        log "ERROR" "Ошибка распаковки архива"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Создание необходимых директорий
    mkdir -p "/etc/dnscrypt-proxy"
    mkdir -p "$DNSCRYPT_CACHE_DIR"
    
    # Копирование и настройка прав
    cp "linux-${arch}/dnscrypt-proxy" "$DNSCRYPT_BIN_PATH"
    chmod 755 "$DNSCRYPT_BIN_PATH"
    chown "$DNSCRYPT_USER:$DNSCRYPT_GROUP" "$DNSCRYPT_CACHE_DIR"
    installation_steps=$((installation_steps + 1))
    
    # Шаг 5: Создание конфигурации
    log "INFO" "(Шаг 5/$total_steps) Создание конфигурации..."
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
log_file = '/var/log/dnscrypt-proxy/dnscrypt-proxy.log'

[sources]
  [sources.'public-resolvers']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md']
  cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 72
  prefix = ''
EOL

    # Создание директории для логов и кэша
    mkdir -p /var/log/dnscrypt-proxy
    mkdir -p /var/cache/dnscrypt-proxy
    chown -R "$DNSCRYPT_USER:$DNSCRYPT_GROUP" /var/log/dnscrypt-proxy
    chown -R "$DNSCRYPT_USER:$DNSCRYPT_GROUP" /var/cache/dnscrypt-proxy
    chmod 755 /var/log/dnscrypt-proxy
    chmod 755 /var/cache/dnscrypt-proxy
    installation_steps=$((installation_steps + 1))
    
    # Шаг 6: Настройка capabilities
    log "INFO" "(Шаг 6/$total_steps) Настройка прав для работы с портом 53..."
    if ! command -v setcap >/dev/null 2>&1; then
        log "INFO" "Установка утилиты setcap..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y libcap2-bin
        elif command -v yum >/dev/null 2>&1; then
            yum install -y libcap
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y libcap
        else
            log "ERROR" "Не удалось установить утилиту setcap"
            return 1
        fi
    fi
    
    # Устанавливаем capabilities
    if ! setcap 'cap_net_bind_service=+ep' "$DNSCRYPT_BIN_PATH"; then
        log "ERROR" "Не удалось установить capabilities"
        return 1
    fi
    
    # Проверяем установку capabilities
    if ! getcap "$DNSCRYPT_BIN_PATH" | grep -q 'cap_net_bind_service'; then
        log "ERROR" "Проверка установки capabilities не удалась"
        return 1
    fi
    installation_steps=$((installation_steps + 1))
    
    # Шаг 7: Создание systemd сервиса
    log "INFO" "(Шаг 7/$total_steps) Настройка systemd сервиса..."
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
WorkingDirectory=/var/cache/dnscrypt-proxy

[Install]
WantedBy=multi-user.target
EOL
    installation_steps=$((installation_steps + 1))
    
    # Шаг 8: Запуск службы
    log "INFO" "(Шаг 8/$total_steps) Запуск службы..."
    systemctl daemon-reload
    systemctl enable dnscrypt-proxy
    
    # Очистка временных файлов
    rm -rf "$temp_dir"
    
    # Запуск службы с проверкой
    if systemctl start dnscrypt-proxy; then
        sleep 10
        if systemctl is-active --quiet dnscrypt-proxy; then
            installation_steps=$((installation_steps + 1))
            log "SUCCESS" "DNSCrypt успешно установлен (выполнено $installation_steps из $total_steps шагов)"
            return 0
        else
            log "ERROR" "Служба DNSCrypt не запустилась"
            log "DEBUG" "Журнал службы:"
            journalctl -u dnscrypt-proxy --no-pager -n 50
            return 1
        fi
    else
        log "ERROR" "Не удалось запустить службу DNSCrypt"
        log "DEBUG" "Журнал службы:"
        journalctl -u dnscrypt-proxy --no-pager -n 50
        return 1
    fi
}

# Проверка установки
# Метаданные
VERSION="2.0.41"
SCRIPT_START_TIME="2025-02-16 11:02:02" 
CURRENT_USER="gopnikgame"

# Функция проверки установки
verify_installation() {
    log "INFO" "=== Проверка установки DNSCrypt ==="
    local errors=0
    local error_details=()

    # Проверка бинарного файла
    log "INFO" "Проверка бинарного файла..."
    if [ ! -x "$DNSCRYPT_BIN_PATH" ]; then
        log "ERROR" "Бинарный файл DNSCrypt не найден или не исполняемый"
        log "DEBUG" "Путь: $DNSCRYPT_BIN_PATH" 
        errors=$((errors + 1))
        error_details+=("Проблема с бинарным файлом")
    else
        log "INFO" "✓ Бинарный файл DNSCrypt найден и имеет правильные права"
    fi

    # Проверка конфигурации
    log "INFO" "Проверка конфигурации..."
    if [ ! -f "$DNSCRYPT_CONFIG" ]; then
        log "ERROR" "Файл конфигурации не найден"
        errors=$((errors + 1))
        error_details+=("Отсутствует файл конфигурации")
    else
        log "INFO" "✓ Файл конфигурации найден"
        if ! grep -q "listen_addresses.*=.*\['127.0.0.1:53'\]" "$DNSCRYPT_CONFIG"; then
            log "ERROR" "Некорректная конфигурация прослушиваемого адреса"
            errors=$((errors + 1))
            error_details+=("Некорректная конфигурация адреса")
        fi
    fi

    # Проверка прав доступа к директориям
    log "INFO" "Проверка прав доступа к директориям..."
    local directories=("$DNSCRYPT_CACHE_DIR" "/var/log/dnscrypt-proxy" "/var/cache/dnscrypt-proxy")
    for dir in "${directories[@]}"; do
        if [ ! -d "$dir" ]; then
            log "ERROR" "Директория $dir не существует"
            errors=$((errors + 1))
            error_details+=("Отсутствует директория $dir")
            continue
        fi

        # Проверка владельца директории
        local dir_owner=$(stat -c '%U' "$dir")
        if [ "$dir_owner" != "$DNSCRYPT_USER" ]; then
            log "ERROR" "Неправильный владелец директории $dir: $dir_owner (должен быть $DNSCRYPT_USER)"
            errors=$((errors + 1))
            error_details+=("Неправильный владелец $dir")
        fi

        # Проверка прав на запись
        if ! su -s /bin/bash "$DNSCRYPT_USER" -c "test -w '$dir'"; then
            log "ERROR" "Неправильные права доступа к директории $dir"
            log "DEBUG" "Текущие права: $(ls -ld "$dir")"
            errors=$((errors + 1))
            error_details+=("Нет прав на запись в $dir")
        else
            log "INFO" "✓ Директория $dir имеет корректные права"
        fi
    done

    # Проверка capabilities
    log "INFO" "Проверка специальных прав (capabilities)..."
    if ! command -v getcap >/dev/null 2>&1; then
        log "ERROR" "Утилита getcap не найдена"
        errors=$((errors + 1))
        error_details+=("Отсутствует утилита getcap")
    elif ! getcap "$DNSCRYPT_BIN_PATH" | grep -q 'cap_net_bind_service'; then
        log "ERROR" "Отсутствуют необходимые права для работы с портом 53"
        log "DEBUG" "Текущие capabilities: $(getcap "$DNSCRYPT_BIN_PATH")"
        errors=$((errors + 1))
        error_details+=("Отсутствуют capabilities для порта 53")
    else
        log "INFO" "✓ Права для работы с портом 53 корректны"
    fi

    # Проверка службы
    log "INFO" "Проверка статуса службы..."
    if ! systemctl is-active --quiet dnscrypt-proxy; then
        log "ERROR" "Служба DNSCrypt не запущена"
        log "DEBUG" "Статус службы:"
        systemctl status dnscrypt-proxy --no-pager
        errors=$((errors + 1))
        error_details+=("Служба не запущена")
    else
        local uptime=$(systemctl show dnscrypt-proxy --property=ActiveEnterTimestamp | cut -d'=' -f2)
        log "INFO" "✓ Служба DNSCrypt активна (запущена с: $uptime)"
    fi

    # Проверка порта 53
    log "INFO" "Проверка прослушивания порта 53..."
    local port_check_failed=true
    
    # Проверка через ss
    if ss -lntu | grep -q ':53.*LISTEN'; then
        port_check_failed=false
        local port_info=$(ss -lntp | grep ':53.*LISTEN')
        if echo "$port_info" | grep -q "dnscrypt"; then
            log "INFO" "✓ Порт 53 прослушивается процессом DNSCrypt"
        else
            local port_owner=$(echo "$port_info" | awk '{print $7}' | cut -d'"' -f2)
            log "WARN" "Порт 53 прослушивается процессом: ${port_owner:-неизвестно}"
        fi
    fi
    
    # Проверка через netstat если ss не нашел порт
    if $port_check_failed && command -v netstat >/dev/null 2>&1; then
        if netstat -lnp | grep -q ':53.*LISTEN'; then
            port_check_failed=false
            log "INFO" "✓ Порт 53 прослушивается (обнаружено через netstat)"
        fi
    fi
    
    # Дополнительная проверка через nc
    if $port_check_failed && command -v nc >/dev/null 2>&1; then
        if nc -z localhost 53 2>/dev/null; then
            port_check_failed=false
            log "INFO" "✓ Порт 53 отвечает на запросы (проверено через nc)"
        fi
    fi

    if $port_check_failed; then
        log "ERROR" "Порт 53 не прослушивается"
        log "DEBUG" "Текущие прослушиваемые порты:"
        ss -lntu | grep 'LISTEN'
        errors=$((errors + 1))
        error_details+=("Порт 53 не прослушивается")
    fi

    # Проверка работоспособности DNS
    log "INFO" "Проверка DNS резолвинга..."
    local dns_success=0
    local total_tests=3
    local test_domains=("google.com" "cloudflare.com" "github.com")
    
    for domain in "${test_domains[@]}"; do
        if dig @127.0.0.1 "$domain" +short +timeout=5 > /dev/null 2>&1; then
            local resolve_time=$(dig @127.0.0.1 "$domain" +noall +stats 2>/dev/null | grep "Query time" | awk '{print $4}')
            log "INFO" "✓ $domain - OK (время ответа: ${resolve_time:-0}ms)"
            dns_success=$((dns_success + 1))
        else
            log "WARN" "✗ Не удалось разрешить $domain"
        fi
    done

    if [ $dns_success -eq $total_tests ]; then
        log "INFO" "✓ DNS резолвинг работает корректно ($dns_success из $total_tests)"
        # Если DNS работает, но были проблемы с портом, уменьшаем счетчик ошибок
        if [ $errors -gt 0 ] && [ $port_check_failed = true ]; then
            errors=$((errors - 1))
            error_details=(${error_details[@]/Порт 53 не прослушивается/})
            log "INFO" "DNS работает корректно несмотря на проблемы с определением порта"
        fi
    else
        log "ERROR" "Проблемы с DNS резолвингом ($dns_success из $total_tests успешно)"
        errors=$((errors + 1))
        error_details+=("Проблемы с DNS резолвингом")
    fi

    # Вывод результата
    if [ $errors -eq 0 ]; then
        log "SUCCESS" "=== Все проверки успешно пройдены ==="
        return 0
    else
        log "ERROR" "=== При проверке установки обнаружено $errors ошибок ==="
        if [ ${#error_details[@]} -gt 0 ]; then
            log "DEBUG" "Список проблем:"
            printf '%s\n' "${error_details[@]}" | sed 's/^/- /'
        fi
        return 1
    fi
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
    
    # Восстановление конфигураций из бэкапа
    if [ -d "$BACKUP_DIR" ]; then
        log "INFO" "Восстановление конфигураций из бэкапа..."
        
        if [ -f "${BACKUP_DIR}/resolv.conf.backup" ]; then
            cp -f "${BACKUP_DIR}/resolv.conf.backup" "/etc/resolv.conf"
        fi
        
        if [ -f "${BACKUP_DIR}/resolved.conf.backup" ]; then
            cp -f "${BACKUP_DIR}/resolved.conf.backup" "/etc/systemd/resolved.conf"
            systemctl enable systemd-resolved 2>/dev/null || true
            systemctl start systemd-resolved 2>/dev/null || true
        fi
        
        if [ -f "${BACKUP_DIR}/x-ui-config.json.backup" ]; then
            cp -f "${BACKUP_DIR}/x-ui-config.json.backup" "/usr/local/x-ui/config.json"
            systemctl restart x-ui 2>/dev/null || true
        fi
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
    sed -i "s/server_names = \\[[^]]*\\]/server_names = ['${selected_server}']/g" "$DNSCRYPT_CONFIG"
    
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

# Метаданные
VERSION="2.0.38"
SCRIPT_START_TIME="2025-02-16 10:48:33"
CURRENT_USER="gopnikgame"

# Основная функция
main() {
    log "INFO" "=== DNSCrypt Installer v$VERSION ==="
    log "INFO" "Время запуска: $SCRIPT_START_TIME"
    log "INFO" "Пользователь: $CURRENT_USER"
    
    # Проверка root прав
    check_root || {
        log "ERROR" "Скрипт должен быть запущен с правами root"
        exit 1
    }
    
    # Настройка русской локали
    setup_russian_locale || {
        log "WARN" "Не удалось установить русскую локаль, продолжаем работу..."
    }
    
    # Проверка наличия установленного DNSCrypt
    if ! check_dnscrypt_installed; then
        log "INFO" "DNSCrypt не установлен. Начинаем процесс установки..."
        
        # Предварительные проверки
        check_prerequisites || {
            log "ERROR" "Не удалось выполнить предварительные проверки"
            exit 1
        }
        
        check_system_state || {
            log "ERROR" "Система не готова к установке"
            exit 1
        }
        
        check_port_53 || {
            log "ERROR" "Не удалось освободить порт 53"
            exit 1
        }
        
        # Создание резервных копий
        create_backup || {
            log "ERROR" "Не удалось создать резервные копии"
            exit 1
        }
        
        # Установка DNSCrypt
        if ! install_dnscrypt; then
            log "ERROR" "Установка DNSCrypt не удалась"
            rollback_system
            exit 1
        fi
        
        # Проверка установки
        if ! verify_installation; then
            log "ERROR" "Проверка установки не удалась"
            rollback_system
            exit 1
        fi
        
        log "SUCCESS" "Установка DNSCrypt успешно завершена"
        log "INFO" "Для настройки интеграции с 3x-ui перезапустите скрипт"
        return 0
    fi
    
    # Если DNSCrypt уже установлен, показываем меню
    while true; do
        echo
        echo "════════════════════════════════════"
        echo "           МЕНЮ УПРАВЛЕНИЯ          "
        echo "════════════════════════════════════"
        echo "1) Изменить DNS сервер"
        echo "2) Настроить интеграцию с 3x-ui"
        echo "3) Запустить диагностику DNSCrypt"
        echo "4) Выход"
        echo "════════════════════════════════════"
        echo
        read -p "Выберите действие (1-4): " option
        echo
        
        case $option in
            1)
                if ! change_dns_server; then
                    log "ERROR" "Не удалось изменить DNS сервер"
                    continue
                fi
                ;;
            2)
                if ! check_3xui_installed; then
                    log "ERROR" "3x-ui не установлен"
                    echo
                    log "INFO" "Для установки 3x-ui выполните команду:"
                    echo "bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)"
                    continue
                fi
                
                echo "Настройка интеграции с 3x-ui"
                echo "═══════════════════════════════"
                echo "Будет выполнено:"
                echo "1. Обновление DNS настроек в 3x-ui на 127.0.0.1"
                echo "2. Создание резервной копии конфигурации"
                echo "3. Перезапуск службы 3x-ui"
                echo
                read -p "Продолжить? (д/н): " -n 1 -r
                echo
                
                if [[ $REPLY =~ ^[ДдYy]$ ]]; then
                    if configure_3xui_dns; then
                        log "SUCCESS" "Интеграция с 3x-ui настроена успешно"
                    else
                        log "ERROR" "Ошибка настройки интеграции с 3x-ui"
                    fi
                else
                    log "INFO" "Настройка отменена пользователем"
                fi
                ;;
            3)
                diagnose_dnscrypt
                ;;
            4)
                log "INFO" "Завершение работы..."
                exit 0
                ;;
            *)
                log "ERROR" "Неверный выбор. Пожалуйста, выберите пункт от 1 до 4"
                continue
                ;;
        esac
        
        # Пауза после выполнения действия
        echo
        read -p "Нажмите Enter для продолжения..."
    done
}

# Запуск основной функции
main