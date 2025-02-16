#!/bin/bash
#
# DNSCrypt Installer & Manager
# Author: gopnikgame
# Version: 2.0.55
# Last update: 2025-02-16 13:18:43

# Метаданные
VERSION="2.0.55"
SCRIPT_START_TIME="2025-02-16 13:18:43"
CURRENT_USER="gopnikgame"

# Константы
DNSCRYPT_BIN_PATH="/usr/local/bin/dnscrypt-proxy"
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
DNSCRYPT_USER="dnscrypt"
DNSCRYPT_CACHE_DIR="/var/cache/dnscrypt-proxy"
BACKUP_DIR="/root/dnscrypt_backup"
STATE_FILE="/tmp/dnscrypt_install_state"

# DNS серверы
declare -A DNS_SERVERS=(
    ["Cloudflare"]="cloudflare"
    ["Quad9"]="quad9"
    ["OpenDNS"]="opendns"
    ["AdGuard"]="adguard-dns"
    ["Anonymous Montreal"]="anon-montreal"
)

# Обработка прерываний и выхода
trap 'cleanup' EXIT
trap 'cleanup_interrupt' INT TERM
# Базовые функции и обработчики ошибок

# Функция логирования
log() {
    local level=$1
    shift
    local message=$@
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "$timestamp [$level] $message"
}

# Функция очистки при выходе
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log "ERROR" "(cleanup:${BASH_LINENO[0]}) Скрипт завершился с ошибкой $exit_code"
        if [ -f "$STATE_FILE" ]; then
            log "INFO" "=== Начало отката системы ==="
            log "INFO" "Остановка DNSCrypt..."
            systemctl stop dnscrypt-proxy 2>/dev/null
            log "INFO" "Удаление файлов DNSCrypt..."
            rm -f "$DNSCRYPT_BIN_PATH" 2>/dev/null
            rm -rf "/etc/dnscrypt-proxy" 2>/dev/null
            rollback_system
            log "INFO" "Откат системы завершён"
        fi
    fi
    rm -f "$STATE_FILE" 2>/dev/null
}

# Функция обработки прерывания
cleanup_interrupt() {
    log "WARN" "Получен сигнал прерывания"
    cleanup
    exit 1
}

# Функция для отслеживания состояния установки
mark_state() {
    echo "$1" > "$STATE_FILE"
}

# Функция проверки root прав
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "ERROR" "Этот скрипт должен быть запущен с правами root"
        return 1
    fi
    return 0
}

# Настройка русской локали
setup_russian_locale() {
    log "INFO" "Настройка русской локали..."
    if ! locale -a | grep -q "ru_RU.utf8"; then
        if ! locale-gen ru_RU.UTF-8 > /dev/null 2>&1; then
            log "WARN" "Не удалось установить русскую локаль"
            return 1
        fi
    fi
    export LANG=ru_RU.UTF-8
    export LC_ALL=ru_RU.UTF-8
    return 0
}

# Функция создания бэкапа
create_backup() {
    log "INFO" "Создание резервной копии..."
    
    mkdir -p "$BACKUP_DIR"
    
    # Бэкап resolv.conf
    if [ -f "/etc/resolv.conf" ]; then
        cp "/etc/resolv.conf" "$BACKUP_DIR/resolv.conf.backup"
    fi
    
    # Бэкап конфигурации DNSCrypt
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        cp "$DNSCRYPT_CONFIG" "$BACKUP_DIR/dnscrypt-proxy.toml.backup"
    fi
    
    # Сохраняем список процессов на порту 53
    if command -v lsof >/dev/null 2>&1; then
        lsof -i :53 > "$BACKUP_DIR/port_53_processes.txt" 2>/dev/null
    fi
    
    # Сохраняем DNS настройки
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl status > "$BACKUP_DIR/dns_settings.txt" 2>/dev/null
    fi
    
    log "SUCCESS" "Резервная копия создана в $BACKUP_DIR"
    return 0
}

# Функция отката изменений
rollback_system() {
    log "INFO" "Откат изменений системы..."
    
    if [ ! -d "$BACKUP_DIR" ]; then
        log "ERROR" "Директория с резервными копиями не найдена"
        return 1
    fi
    
    # Восстанавливаем файлы из бэкапа
    if [ -f "$BACKUP_DIR/resolv.conf.backup" ]; then
        cp "$BACKUP_DIR/resolv.conf.backup" "/etc/resolv.conf"
    fi
    
    if [ -f "$BACKUP_DIR/dnscrypt-proxy.toml.backup" ]; then
        cp "$BACKUP_DIR/dnscrypt-proxy.toml.backup" "$DNSCRYPT_CONFIG"
    fi
    
    # Восстанавливаем системные службы
    if grep -q "systemd-resolved" "$BACKUP_DIR/port_53_processes.txt" 2>/dev/null; then
        systemctl restart systemd-resolved
    fi
    
    log "SUCCESS" "Система восстановлена из резервной копии"
    return 0
}

# Функции проверки системы и предварительной подготовки

check_prerequisites() {
    log "INFO" "Проверка предварительных требований..."
    
    # Проверка наличия необходимых утилит
    local required_utils=("wget" "tar" "systemctl" "dig" "ss" "getcap")
    local missing_utils=()
    
    for util in "${required_utils[@]}"; do
        if ! command -v "$util" >/dev/null 2>&1; then
            missing_utils+=("$util")
        fi
    done
    
    if [ ${#missing_utils[@]} -ne 0 ]; then
        log "ERROR" "Отсутствуют необходимые утилиты: ${missing_utils[*]}"
        log "INFO" "Установите их с помощью: apt-get install ${missing_utils[*]}"
        return 1
    fi
    
    # Проверка свободного места
    local required_space=100000  # 100MB в KB
    local available_space=$(df -k /usr/local/bin | awk 'NR==2 {print $4}')
    
    if [ "$available_space" -lt "$required_space" ]; then
        log "ERROR" "Недостаточно свободного места (требуется минимум 100MB)"
        return 1
    fi
    
    log "SUCCESS" "Все предварительные требования выполнены"
    return 0
}

check_system_state() {
    log "INFO" "Проверка состояния системы..."
    
    # Проверка загрузки процессора
    local cpu_load=$(uptime | awk -F'load average:' '{print $2}' | cut -d, -f1)
    if (( $(echo "$cpu_load > 2.0" | bc -l) )); then
        log "WARN" "Высокая загрузка системы: $cpu_load"
    fi
    
    # Проверка свободной памяти
    local free_mem=$(free -m | awk 'NR==2 {print $4}')
    if [ "$free_mem" -lt 100 ]; then
        log "WARN" "Мало свободной памяти: ${free_mem}MB"
    fi
    
    # Проверка сетевого подключения
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        log "ERROR" "Отсутствует подключение к интернету"
        return 1
    fi
    
    # Проверка системных служб
    local required_services=("systemd-resolved" "networking")
    for service in "${required_services[@]}"; do
        if ! systemctl is-active --quiet "$service"; then
            log "WARN" "Служба $service не активна"
        fi
    done
    
    log "SUCCESS" "Система готова к установке"
    return 0
}

check_port_53() {
    log "INFO" "Проверка порта 53..."
    
    local port_in_use=false
    local service_using_port=""
    
    # Проверка через ss
    if ss -lntu | grep -q ':53 .*LISTEN'; then
        port_in_use=true
        service_using_port=$(ss -lntp | grep ':53 .*LISTEN' | awk '{print $7}' | cut -d'"' -f2)
    fi
    
    # Проверка через netstat если ss не нашел
    if ! $port_in_use && command -v netstat >/dev/null 2>&1; then
        if netstat -lnp | grep -q ':53 .*LISTEN'; then
            port_in_use=true
            service_using_port=$(netstat -lnp | grep ':53 .*LISTEN' | awk '{print $7}' | cut -d'/' -f2)
        fi
    fi
    
    if $port_in_use; then
        log "INFO" "Порт 53 занят процессом: $service_using_port"
        
        # Особая обработка для известных служб
        case "$service_using_port" in
            systemd-resolved)
                log "INFO" "Отключение systemd-resolved..."
                systemctl stop systemd-resolved
                systemctl disable systemd-resolved
                ;;
            named|bind)
                log "INFO" "Отключение BIND..."
                systemctl stop named bind9
                systemctl disable named bind9
                ;;
            dnsmasq)
                log "INFO" "Отключение dnsmasq..."
                systemctl stop dnsmasq
                systemctl disable dnsmasq
                ;;
            *)
                log "ERROR" "Неизвестный процесс использует порт 53"
                return 1
                ;;
        esac
        
        # Проверяем, освободился ли порт
        sleep 2
        if ss -lntu | grep -q ':53 .*LISTEN'; then
            log "ERROR" "Не удалось освободить порт 53"
            return 1
        fi
    fi
    
    log "SUCCESS" "Порт 53 доступен"
    return 0
}

# Функции установки и настройки DNSCrypt

install_dnscrypt() {
    log "INFO" "Начало установки DNSCrypt..."
    mark_state "installation_started"
    
    # Создание пользователя для DNSCrypt если его нет
    if ! id -u "$DNSCRYPT_USER" >/dev/null 2>&1; then
        useradd -r -s /bin/false "$DNSCRYPT_USER"
        log "INFO" "Создан пользователь $DNSCRYPT_USER"
    fi
    
    # Создание необходимых директорий
    local directories=(
        "/etc/dnscrypt-proxy"
        "/var/log/dnscrypt-proxy"
        "/var/cache/dnscrypt-proxy"
        "/usr/local/bin"
    )
    
    for dir in "${directories[@]}"; do
        mkdir -p "$dir"
        chown "$DNSCRYPT_USER:$DNSCRYPT_USER" "$dir"
    done
    
    # Загрузка последней версии DNSCrypt
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    
    log "INFO" "Загрузка DNSCrypt..."
    wget -q "https://github.com/DNSCrypt/dnscrypt-proxy/releases/latest/download/dnscrypt-proxy-linux_x86_64-2.1.5.tar.gz" -O dnscrypt.tar.gz
    
    if [ ! -f "dnscrypt.tar.gz" ]; then
        log "ERROR" "Не удалось загрузить DNSCrypt"
        return 1
    fi
    
    # Распаковка и установка
    tar xzf dnscrypt.tar.gz
    cp linux-x86_64/dnscrypt-proxy "$DNSCRYPT_BIN_PATH"
    chmod 755 "$DNSCRYPT_BIN_PATH"
    chown "$DNSCRYPT_USER:$DNSCRYPT_USER" "$DNSCRYPT_BIN_PATH"
    
    # Установка capabilities
    setcap CAP_NET_BIND_SERVICE=+eip "$DNSCRYPT_BIN_PATH"
    
    # Создание базовой конфигурации
    create_default_config
    
    # Создание systemd сервиса
    create_systemd_service
    
    # Очистка
    cd - >/dev/null
    rm -rf "$temp_dir"
    
    if [ $? -eq 0 ]; then
        rm -f "$STATE_FILE"
        log "SUCCESS" "DNSCrypt установлен успешно"
        return 0
    else
        log "ERROR" "Ошибка при установке DNSCrypt"
        return 1
    fi
}

create_default_config() {
    log "INFO" "Создание конфигурации по умолчанию..."
    
    cat > "$DNSCRYPT_CONFIG" << EOF
# DNSCrypt configuration file
listen_addresses = ['127.0.0.1:53']
server_names = ['cloudflare']
max_clients = 250
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = true
doh_servers = true
require_dnssec = true
require_nolog = true
require_nofilter = true
force_tcp = false
timeout = 2500
keepalive = 30
log_level = 2
use_syslog = true
fallback_resolver = '1.1.1.1:53'
ignore_system_dns = true
netprobe_timeout = 30
cache = true
cache_size = 4096
cache_min_ttl = 600
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600
[sources]
  [sources.'public-resolvers']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
  cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 72
  prefix = ''
EOF
    
    chown "$DNSCRYPT_USER:$DNSCRYPT_USER" "$DNSCRYPT_CONFIG"
    chmod 644 "$DNSCRYPT_CONFIG"
    
    log "SUCCESS" "Конфигурация создана"
    return 0
}

create_systemd_service() {
    log "INFO" "Создание systemd сервиса..."
    
    cat > "/etc/systemd/system/dnscrypt-proxy.service" << EOF
[Unit]
Description=DNSCrypt-proxy client
Documentation=https://github.com/DNSCrypt/dnscrypt-proxy/wiki
After=network.target
Before=nss-lookup.target
Wants=network.target nss-lookup.target

[Service]
Type=simple
NonBlocking=true
User=$DNSCRYPT_USER
ExecStart=$DNSCRYPT_BIN_PATH -config $DNSCRYPT_CONFIG
Restart=always
RestartSec=30
LimitNOFILE=65536

# Process capabilities
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

# Security
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
PrivateTmp=true
PrivateDevices=true

[Install]
WantedBy=multi-user.target
EOF
    
    # Перезагрузка systemd и запуск сервиса
    systemctl daemon-reload
    systemctl enable dnscrypt-proxy
    systemctl start dnscrypt-proxy
    
    log "SUCCESS" "Сервис DNSCrypt создан и запущен"
    return 0
}

# Функции проверки установки и управления DNSCrypt

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
    
    if $port_check_failed && command -v netstat >/dev/null 2>&1; then
        if netstat -lnp | grep -q ':53.*LISTEN'; then
            port_check_failed=false
            log "INFO" "✓ Порт 53 прослушивается (обнаружено через netstat)"
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

# Функции проверки DNS и управления конфигурацией

check_current_dns() {
    log "INFO" "=== Проверка текущего DNS сервера ==="
    
    # Проверка через resolv.conf
    log "INFO" "Проверка /etc/resolv.conf:"
    if [ -f "/etc/resolv.conf" ]; then
        echo "Содержимое resolv.conf:"
        grep "nameserver" /etc/resolv.conf | sed 's/^/  /'
    else
        log "WARN" "Файл /etc/resolv.conf не найден"
    fi
    
    # Проверка через resolvectl
    if command -v resolvectl >/dev/null 2>&1; then
        log "INFO" "Статус systemd-resolved:"
        resolvectl status | grep -E "DNS Server|Current DNS" | sed 's/^/  /'
    fi
    
    # Проверка через DNSCrypt
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        log "INFO" "Текущий DNSCrypt сервер:"
        current_server=$(grep "server_names" "$DNSCRYPT_CONFIG" | cut -d"'" -f2)
        echo "  Настроенный сервер: $current_server"
        
        # Проверка активного сервера из лога
        local active_server=$(journalctl -u dnscrypt-proxy -n 50 | grep "Server with lowest initial latency" | tail -n 1)
        if [ -n "$active_server" ]; then
            echo "  Активный сервер: $active_server"
        fi
    fi
    
    # Тест резолвинга
    log "INFO" "Тест резолвинга через dig:"
    local test_domain="google.com"
    echo "  Запрос к $test_domain:"
    dig +short "$test_domain" | sed 's/^/    /'
    
    # Проверка через какой сервер идет резолвинг
    echo "  Полная информация о запросе:"
    dig "$test_domain" +noall +comments | grep -E "SERVER:|Query time:" | sed 's/^/    /'
}

fix_dns_resolution() {
    log "INFO" "=== Исправление настроек DNS резолвинга ==="
    
    # Проверяем текущие настройки
    local current_dns=$(grep "nameserver" /etc/resolv.conf | head -n1)
    log "INFO" "Текущий DNS сервер: $current_dns"
    
    # Проверяем работу DNSCrypt
    if ! dig @127.0.0.1 google.com +short +timeout=5 > /dev/null; then
        log "ERROR" "DNSCrypt не отвечает на запросы. Сначала исправьте работу DNSCrypt"
        return 1
    fi
    
    # Создаем бэкап
    if [ ! -f "/etc/resolv.conf.backup" ]; then
        cp /etc/resolv.conf /etc/resolv.conf.backup
        log "INFO" "Создан бэкап /etc/resolv.conf"
    fi
    
    # Проверяем systemd-resolved
    if systemctl is-active --quiet systemd-resolved; then
        log "INFO" "Настройка systemd-resolved..."
        mkdir -p /etc/systemd/resolved.conf.d/
        cat > /etc/systemd/resolved.conf.d/dnscrypt.conf << EOF
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
EOF
        systemctl restart systemd-resolved
    fi
    
    # Устанавливаем локальный DNS
    log "INFO" "Установка локального DNS сервера..."
    if ! chattr -i /etc/resolv.conf 2>/dev/null; then
        log "WARN" "Не удалось снять атрибут immutable (возможно его не было)"
    fi
    
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    
    # Защищаем от изменений
    chattr +i /etc/resolv.conf
    
    # Проверяем результат
    if dig google.com +short > /dev/null; then
        log "SUCCESS" "DNS резолвинг настроен корректно"
        log "INFO" "Теперь запросы идут через DNSCrypt"
        return 0
    else
        log "ERROR" "Проблема с DNS резолвингом после изменений"
        log "INFO" "Восстанавливаем из бэкапа..."
        chattr -i /etc/resolv.conf
        cp /etc/resolv.conf.backup /etc/resolv.conf
        return 1
    fi
}

change_dns_server() {
    log "INFO" "=== Изменение DNS сервера ==="
    
    # Показываем доступные серверы
    log "INFO" "Доступные DNS серверы:"
    local i=1
    declare -a server_keys
    for key in "${!DNS_SERVERS[@]}"; do
        echo "  $i) $key (${DNS_SERVERS[$key]})"
        server_keys[$i]=$key
        ((i++))
    done
    
    # Запрашиваем выбор пользователя
    read -p "Выберите номер сервера (1-${#DNS_SERVERS[@]}): " choice
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#DNS_SERVERS[@]}" ]; then
        log "ERROR" "Неверный выбор"
        return 1
    fi
    
    local selected_key=${server_keys[$choice]}
    local selected_server=${DNS_SERVERS[$selected_key]}
    
    log "INFO" "Выбран сервер: $selected_key ($selected_server)"
    
    # Создаем бэкап конфигурации
    cp "$DNSCRYPT_CONFIG" "${DNSCRYPT_CONFIG}.backup"
    
    # Обновляем конфигурацию
    sed -i "s/server_names = \['[^']*'\]/server_names = ['$selected_server']/" "$DNSCRYPT_CONFIG"
    
    # Перезапускаем службу
    systemctl restart dnscrypt-proxy
    
    # Проверяем работоспособность
    sleep 2
    if dig @127.0.0.1 google.com +short +timeout=5 > /dev/null; then
        log "SUCCESS" "DNS сервер успешно изменен на $selected_key"
        return 0
    else
        log "ERROR" "Проблема после изменения DNS сервера"
        log "INFO" "Восстанавливаем предыдущую конфигурацию..."
        mv "${DNSCRYPT_CONFIG}.backup" "$DNSCRYPT_CONFIG"
        systemctl restart dnscrypt-proxy
        return 1
    fi
}

# Функции управления сервисом и основное меню

manage_service() {
    log "INFO" "=== Управление службой DNSCrypt ==="
    
    echo "Выберите действие:"
    echo "1) Статус службы"
    echo "2) Запустить службу"
    echo "3) Остановить службу"
    echo "4) Перезапустить службу"
    echo "5) Просмотр логов"
    echo "6) Вернуться в главное меню"
    
    read -p "Ваш выбор (1-6): " choice
    
    case $choice in
        1)
            systemctl status dnscrypt-proxy --no-pager
            ;;
        2)
            log "INFO" "Запуск службы DNSCrypt..."
            systemctl start dnscrypt-proxy
            sleep 2
            if systemctl is-active --quiet dnscrypt-proxy; then
                log "SUCCESS" "Служба успешно запущена"
            else
                log "ERROR" "Не удалось запустить службу"
                systemctl status dnscrypt-proxy --no-pager
            fi
            ;;
        3)
            log "INFO" "Остановка службы DNSCrypt..."
            systemctl stop dnscrypt-proxy
            if ! systemctl is-active --quiet dnscrypt-proxy; then
                log "SUCCESS" "Служба остановлена"
            else
                log "ERROR" "Не удалось остановить службу"
            fi
            ;;
        4)
            log "INFO" "Перезапуск службы DNSCrypt..."
            systemctl restart dnscrypt-proxy
            sleep 2
            if systemctl is-active --quiet dnscrypt-proxy; then
                log "SUCCESS" "Служба успешно перезапущена"
            else
                log "ERROR" "Не удалось перезапустить службу"
                systemctl status dnscrypt-proxy --no-pager
            fi
            ;;
        5)
            log "INFO" "Последние записи журнала:"
            journalctl -u dnscrypt-proxy -n 50 --no-pager
            ;;
        6)
            return 0
            ;;
        *)
            log "ERROR" "Неверный выбор"
            return 1
            ;;
    esac
}

clear_cache() {
    log "INFO" "=== Очистка кэша DNSCrypt ==="
    
    # Проверяем наличие директории кэша
    if [ ! -d "$DNSCRYPT_CACHE_DIR" ]; then
        log "ERROR" "Директория кэша не найдена"
        return 1
    fi
    
    # Останавливаем службу
    log "INFO" "Остановка службы DNSCrypt..."
    systemctl stop dnscrypt-proxy
    
    # Очищаем кэш
    log "INFO" "Удаление файлов кэша..."
    rm -f "$DNSCRYPT_CACHE_DIR"/*
    
    # Проверяем права доступа
    chown "$DNSCRYPT_USER:$DNSCRYPT_USER" "$DNSCRYPT_CACHE_DIR"
    chmod 700 "$DNSCRYPT_CACHE_DIR"
    
    # Запускаем службу
    log "INFO" "Запуск службы DNSCrypt..."
    systemctl start dnscrypt-proxy
    
    # Проверяем результат
    if systemctl is-active --quiet dnscrypt-proxy; then
        log "SUCCESS" "Кэш успешно очищен, служба перезапущена"
        return 0
    else
        log "ERROR" "Проблема при перезапуске службы после очистки кэша"
        systemctl status dnscrypt-proxy --no-pager
        return 1
    fi
}

main_menu() {
    # Создаем временный файл состояния
    touch "$STATE_FILE"
    
    while true; do
        echo
        echo "=== DNSCrypt Manager v$VERSION ==="
        echo "1) Установить DNSCrypt"
        echo "2) Проверить установку"
        echo "3) Изменить DNS сервер"
        echo "4) Проверить текущий DNS"
        echo "5) Исправить DNS резолвинг"
        echo "6) Управление службой"
        echo "7) Очистить кэш"
        echo "8) Создать резервную копию"
        echo "9) Восстановить из резервной копии"
        echo "0) Выход"
        
        read -p "Выберите действие (0-9): " choice
        echo
        
        case $choice in
            1)
                check_prerequisites && \
                check_system_state && \
                check_port_53 && \
                create_backup && \
                install_dnscrypt
                ;;
            2)
                verify_installation
                ;;
            3)
                change_dns_server
                ;;
            4)
                check_current_dns
                ;;
            5)
                fix_dns_resolution
                ;;
            6)
                manage_service
                ;;
            7)
                clear_cache
                ;;
            8)
                create_backup
                ;;
            9)
                rollback_system
                ;;
            0)
                log "INFO" "Завершение работы..."
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

# Запуск программы
if ! check_root; then
    log "ERROR" "Этот скрипт должен быть запущен с правами root"
    exit 1
fi

setup_russian_locale
main_menu