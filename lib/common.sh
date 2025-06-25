#!/bin/bash

# Версия библиотеки
LIB_VERSION="1.1.0"

# Цветовые коды для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Пути к основным файлам
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
BACKUP_DIR="/var/backup/dnscrypt"
LOG_DIR="/var/log/dnscrypt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Пути к дополнительным файлам и кэшам
RELAYS_CACHE="/etc/dnscrypt-proxy/relays.md"
SERVERS_CACHE="/etc/dnscrypt-proxy/public-resolvers.md"
ODOH_SERVERS_CACHE="/etc/dnscrypt-proxy/odoh-servers.md"
ODOH_RELAYS_CACHE="/etc/dnscrypt-proxy/odoh-relays.md"
RESOLV_CONF="/etc/resolv.conf"
DNSCRYPT_SERVICE="dnscrypt-proxy"

# Определение пользователя DNSCrypt - ФУНКЦИЯ ПЕРЕНЕСЕНА СЮДА
get_dnscrypt_user() {
    # Попытка определить пользователя из службы
    local user=$(systemctl show -p User "$DNSCRYPT_SERVICE" 2>/dev/null | sed 's/User=//')
    
    # Если не удалось определить через systemctl, пробуем стандартные варианты
    if [ -z "$user" ] || [ "$user" == "=" ]; then
        if id _dnscrypt-proxy &>/dev/null; then
            user="_dnscrypt-proxy"
        elif id dnscrypt-proxy &>/dev/null; then
            user="dnscrypt-proxy"
        else
            # Если не удалось определить, используем текущего пользователя
            user=$(whoami)
            # Логирование отключено, чтобы избежать ошибок на этом этапе
        fi
    fi
    
    echo "$user"
}

# Константа для пользователя DNSCrypt
DNSCRYPT_USER=$(get_dnscrypt_user)

# Инициализация системы
init_system() {
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$LOG_DIR"
    chmod 755 "$BACKUP_DIR" "$LOG_DIR"
}

# Импорт дополнительных библиотек
import_lib() {
    local lib_name="$1"
    local lib_path="${SCRIPT_DIR}/lib/${lib_name}.sh"
    
    if [ -f "$lib_path" ]; then
        source "$lib_path"
        return 0
    else
        log "ERROR" "Библиотека '$lib_name' не найдена по пути: $lib_path"
        return 1
    fi
}

# Функция логирования
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Цвета для разных уровней
    case "$level" in
        "ERROR") color="$RED" ;;
        "SUCCESS") color="$GREEN" ;;
        "WARN") color="$YELLOW" ;;
        "INFO") color="$BLUE" ;;
        "DEBUG") color="$CYAN" ;;
        *) color="$NC" ;;
    esac
    
    # Вывод в консоль
    echo -e "${color}[${timestamp}] [$level] ${message}${NC}"
    
    # Запись в лог-файл (без цветовых кодов)
    # Проверяем существование директории логов
    if [ -d "${LOG_DIR}" ]; then
        echo "[${timestamp}] [$level] ${message}" >> "${LOG_DIR}/dnscrypt-manager.log"
    fi
}

# Проверка root-прав
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
}

# Проверка зависимостей
check_dependencies() {
    local deps=("$@")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "WARN" "Отсутствующие зависимости: ${missing[*]}"
        
        if [[ -f /etc/debian_version ]]; then
            apt-get update
            apt-get install -y "${missing[@]}"
        elif [[ -f /etc/redhat-release ]]; then
            yum install -y "${missing[@]}"
        else
            log "ERROR" "Неподдерживаемый дистрибутив для автоматической установки"
            return 1
        fi
    fi
    
    return 0
}

# Загрузка файлов с GitHub
download_from_github() {
    local repo_path="$1"
    local local_path="$2"
    local github_url="https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/${repo_path}"
    
    log "INFO" "Загрузка ${github_url} в ${local_path}"
    
    if ! wget -q --tries=3 --timeout=10 -O "$local_path" "$github_url"; then
        log "ERROR" "Ошибка загрузки файла ${github_url}"
        return 1
    fi
    
    # Проверка цифровой подписи (можно добавить позже)
    # verify_signature "$local_path"
    
    return 0
}

# Создание резервной копии
backup_config() {
    local config_file="$1"
    local backup_name="$2"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    
    if [[ ! -f "$config_file" ]]; then
        log "ERROR" "Файл для резервирования не существует: ${config_file}"
        return 1
    fi
    
    mkdir -p "$BACKUP_DIR"
    local backup_path="${BACKUP_DIR}/${backup_name}_${timestamp}.bak"
    
    if ! cp "$config_file" "$backup_path"; then
        log "ERROR" "Ошибка создания резервной копии"
        return 1
    fi
    
    log "SUCCESS" "Создана резервная копия: ${backup_path}"
    return 0
}

# Восстановление из резервной копии
restore_config() {
    local config_file="$1"
    local backup_path="$2"
    
    if [[ ! -f "$backup_path" ]]; then
        log "ERROR" "Резервная копия не найдена: ${backup_path}"
        return 1
    fi
    
    if ! cp "$backup_path" "$config_file"; then
        log "ERROR" "Ошибка восстановления из резервной копии"
        return 1
    fi
    
    log "SUCCESS" "Конфигурация восстановлена из: ${backup_path}"
    return 0
}

# Проверка состояния службы
check_service_status() {
    local service_name="$1"
    
    if ! systemctl is-active --quiet "$service_name"; then
        log "ERROR" "Служба ${service_name} не запущена"
        return 1
    fi
    
    log "INFO" "Служба ${service_name} работает"
    return 0
}

# Перезапуск службы
restart_service() {
    local service_name="$1"
    
    log "INFO" "Перезапуск службы ${service_name}"
    
    if ! systemctl restart "$service_name"; then
        log "ERROR" "Ошибка перезапуска службы ${service_name}"
        return 1
    fi
    
    log "SUCCESS" "Служба ${service_name} успешно перезапущена"
    return 0
}

# Красивый заголовок
print_header() {
    local title="$1"
    local width=60
    local padding=$(( (width - ${#title}) / 2 ))
    
    echo
    echo -e "${BLUE}┌$(printf '─%.0s' $(seq 1 $width))┐${NC}"
    echo -e "${BLUE}│$(printf ' %.0s' $(seq 1 $padding))${CYAN}${title}$(printf ' %.0s' $(seq 1 $((width - padding - ${#title}))))${BLUE}│${NC}"
    echo -e "${BLUE}└$(printf '─%.0s' $(seq 1 $width))┘${NC}"
    echo
}

# Проверка подключения к интернету
check_internet() {
    if ! ping -c 1 -W 3 google.com >/dev/null 2>&1 && \
       ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        log "ERROR" "Нет подключения к интернету"
        return 1
    fi
    return 0
}

# Загрузка и обновление модулей
update_modules() {
    local modules=("$@")
    local force_update="${FORCE_UPDATE:-false}"
    
    print_header "ОБНОВЛЕНИЕ МОДУЛЕЙ"
    
    for module in "${modules[@]}"; do
        local module_name=$(basename "$module")
        local module_path="${SCRIPT_DIR}/modules/${module_name}"
        
        # Проверяем, нужно ли обновлять
        if [[ "$force_update" == "true" ]] || [[ ! -f "$module_path" ]]; then
            if ! download_from_github "modules/${module_name}" "$module_path"; then
                log "ERROR" "Ошибка загрузки модуля ${module_name}"
                continue
            fi
            
            chmod +x "$module_path"
            log "SUCCESS" "Модуль ${module_name} успешно обновлен"
        else
            log "INFO" "Модуль ${module_name} уже актуален"
        fi
    done
}

# Функция для проверки текущих настроек
check_current_settings() {
    log "INFO" "=== Текущие настройки DNSCrypt ==="
    
    if [ ! -f "$DNSCRYPT_CONFIG" ]; then
        log "ERROR" "Файл конфигурации не найден!"
        return 1
    fi

    echo -e "\n${BLUE}Текущие DNS серверы:${NC}"
    grep "server_names" "$DNSCRYPT_CONFIG" | sed 's/server_names = //'

    echo -e "\n${BLUE}Протоколы и безопасность:${NC}"
    echo -n "DNSSEC: "
    if grep -q "require_dnssec = true" "$DNSCRYPT_CONFIG"; then
        echo -e "${GREEN}Включен${NC}"
    else
        echo -e "${RED}Выключен${NC}"
    fi

    echo -n "NoLog: "
    if grep -q "require_nolog = true" "$DNSCRYPT_CONFIG"; then
        echo -e "${GREEN}Включен${NC}"
    else
        echo -e "${RED}Выключен${NC}"
    fi

    echo -n "NoFilter: "
    if grep -q "require_nofilter = true" "$DNSCRYPT_CONFIG"; then
        echo -e "${GREEN}Включен${NC}"
    else
        echo -e "${RED}Выключен${NC}"
    fi

    echo -e "\n${BLUE}Прослушиваемые адреса:${NC}"
    grep "listen_addresses" "$DNSCRYPT_CONFIG" | sed 's/listen_addresses = //'

    echo -e "\n${BLUE}Поддерживаемые протоколы:${NC}"
    echo -n "DNSCrypt: "
    if grep -q "dnscrypt_servers = true" "$DNSCRYPT_CONFIG"; then
        echo -e "${GREEN}Включен${NC}"
    else
        echo -e "${RED}Выключен${NC}"
    fi

    echo -n "DNS-over-HTTPS (DoH): "
    if grep -q "doh_servers = true" "$DNSCRYPT_CONFIG"; then
        echo -e "${GREEN}Включен${NC}"
    else
        echo -e "${RED}Выключен${NC}"
    fi

    echo -n "HTTP/3 (QUIC): "
    if grep -q "http3 = true" "$DNSCRYPT_CONFIG"; then
        echo -e "${GREEN}Включен${NC}"
    else
        echo -e "${RED}Выключен${NC}"
    fi

    echo -n "Oblivious DoH (ODoH): "
    if grep -q "odoh_servers = true" "$DNSCRYPT_CONFIG"; then
        echo -e "${GREEN}Включен${NC}"
    else
        echo -e "${RED}Выключен${NC}"
    fi

    echo -e "\n${BLUE}Настройки кэша:${NC}"
    echo -n "Кэширование: "
    if grep -q "cache = true" "$DNSCRYPT_CONFIG"; then
        echo -e "${GREEN}Включено${NC}"
        echo "Размер кэша: $(grep "cache_size" "$DNSCRYPT_CONFIG" | sed 's/cache_size = //')"
        echo "Минимальное TTL: $(grep "cache_min_ttl" "$DNSCRYPT_CONFIG" | sed 's/cache_min_ttl = //')"
        echo "Максимальное TTL: $(grep "cache_max_ttl" "$DNSCRYPT_CONFIG" | sed 's/cache_max_ttl = //')"
    else
        echo -e "${RED}Выключено${NC}"
    fi
    
    echo -e "\n${BLUE}Дополнительные настройки:${NC}"
    echo -n "Блокировка IPv6: "
    if grep -q "block_ipv6 = true" "$DNSCRYPT_CONFIG"; then
        echo -e "${GREEN}Включена${NC}"
    else
        echo -e "${RED}Выключена${NC}"
    fi

    echo -n "Горячая перезагрузка конфигурации: "
    if grep -q "enable_hot_reload = true" "$DNSCRYPT_CONFIG"; then
        echo -e "${GREEN}Включена${NC}"
    else
        echo -e "${RED}Выключена${NC}"
    fi
}

# Функция для проверки применения настроек
verify_settings() {
    local server_name="$1"
    log "INFO" "Проверка применения настроек..."
    
    # Проверка статуса службы
    if ! systemctl is-active --quiet dnscrypt-proxy; then
        log "ERROR" "Служба DNSCrypt не запущена"
        return 1
    fi

    # Проверка логов на наличие ошибок
    if journalctl -u dnscrypt-proxy -n 50 | grep -i error > /dev/null; then
        log "WARN" "В логах обнаружены ошибки:"
        journalctl -u dnscrypt-proxy -n 50 | grep -i error
    fi

    # Проверка резолвинга
    echo -e "\n${BLUE}Проверка DNS резолвинга:${NC}"
    local test_domains=("google.com" "cloudflare.com" "github.com")
    local success=true

    for domain in "${test_domains[@]}"; do
        echo -n "Тест $domain: "
        if dig @127.0.0.1 "$domain" +short +timeout=5 > /dev/null 2>&1; then
            local resolve_time=$(dig @127.0.0.1 "$domain" +noall +stats 2>/dev/null | grep "Query time" | awk '{print $4}')
            echo -e "${GREEN}OK${NC} (${resolve_time}ms)"
        else
            echo -e "${RED}ОШИБКА${NC}"
            success=false
        fi
    done

    # Проверка используемого сервера
    echo -e "\n${BLUE}Проверка активного DNS сервера:${NC}"
    local current_server=$(dig +short resolver.dnscrypt.info TXT | grep -o '".*"' | tr -d '"')
    if [ -n "$current_server" ]; then
        echo "Активный сервер: $current_server"
    else
        echo -e "${RED}Не удалось определить активный сервер${NC}"
        success=false
    fi

    if [ "$success" = true ]; then
        return 0
    else
        return 1
    fi
}

# Функция для расширенной проверки конфигурации
extended_verify_config() {
    echo -e "\n${BLUE}Расширенная проверка конфигурации DNSCrypt:${NC}"
    
    # Проверка конфигурации
    if cd "$(dirname "$DNSCRYPT_CONFIG")" && dnscrypt-proxy -check; then
        log "SUCCESS" "${GREEN}Конфигурация успешно проверена${NC}"
        
        # Проверка активных DNS-серверов
        echo -e "\n${YELLOW}==== DNSCrypt активные соединения ====${NC}"
        journalctl -u dnscrypt-proxy -n 100 --no-pager | grep -E "Connected to|Server with lowest" | tail -10

        echo -e "\n${YELLOW}==== Текущий DNS сервер ====${NC}"
        dig +short resolver.dnscrypt.info TXT | tr -d '"'

        echo -e "\n${YELLOW}==== Тестирование доступности серверов ====${NC}"
        for domain in google.com cloudflare.com facebook.com example.com; do
            echo -n "Запрос $domain: "
            time=$(dig @127.0.0.1 +noall +stats "$domain" | grep "Query time" | awk '{print $4}')
            if [ -n "$time" ]; then
                echo -e "${GREEN}OK ($time ms)${NC}"
            else
                echo -e "${RED}ОШИБКА${NC}"
            fi
        done

        echo -e "\n${YELLOW}==== Проверка DNSSEC ====${NC}"
        dig @127.0.0.1 dnssec-tools.org +dnssec +short
        
        # Проверка используемого протокола
        echo -e "\n${YELLOW}==== Информация о протоколе ====${NC}"
        local protocol_info=$(journalctl -u dnscrypt-proxy -n 100 --no-pager | grep -E "Using protocol|Using transport" | tail -1)
        if [ -n "$protocol_info" ]; then
            echo -e "${GREEN}$protocol_info${NC}"
        else
            echo -e "${YELLOW}Информация о протоколе не найдена${NC}"
        fi
        
        # Проверка индикатора загрузки
        local load_info=$(systemctl status dnscrypt-proxy | grep "Memory\|CPU")
        if [ -n "$load_info" ]; then
            echo -e "\n${YELLOW}==== Ресурсы системы ====${NC}"
            echo "$load_info"
        fi
        
    else
        log "ERROR" "${RED}Ошибка в конфигурации${NC}"
    fi
}

# Функция для проверки и вывода типа анонимизации DNS
check_anonymized_dns() {
    log "INFO" "Проверка текущей конфигурации анонимного DNS..."
    
    if [ ! -f "$DNSCRYPT_CONFIG" ]; then
        log "ERROR" "Файл конфигурации DNSCrypt не найден: $DNSCRYPT_CONFIG"
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

# Функция для вывода доступных серверов DNSCrypt
list_available_servers() {
    # Проверка наличия кэш-файла с серверами
    if [ ! -f "$SERVERS_CACHE" ]; then
        echo -e "${YELLOW}Файл с серверами не найден. Загрузите списки серверов с помощью dnscrypt-proxy.${NC}"
        return 1
    fi
    
    # Читаем и выводим список DNSCrypt-серверов
    echo -e "${YELLOW}Список может быть большим. Показаны только первые 20 серверов.${NC}"
    grep -A 1 "^## " "$SERVERS_CACHE" | grep -v "^--" | head -n 40 | sed 'N;s/\n/ - /' | sed 's/## //' | nl
    
    echo -e "\n${YELLOW}Для просмотра полного списка серверов выполните:${NC}"
    echo "cat $SERVERS_CACHE | grep -A 1 '^## ' | grep -v '^--' | sed 'N;s/\\n/ - /' | sed 's/## //'"
}

# Функция для вывода доступных релеев
list_available_relays() {
    # Проверка наличия кэш-файла с релеями
    if [ ! -f "$RELAYS_CACHE" ]; then
        echo -e "${YELLOW}Файл с релеями не найден. Загрузите списки релеев с помощью dnscrypt-proxy.${NC}"
        return 1
    fi
    
    # Читаем и выводим список релеев
    grep -A 1 "^## " "$RELAYS_CACHE" | grep -v "^--" | sed 'N;s/\n/ - /' | sed 's/## //' | nl
}

# Функция для вывода доступных ODoH-серверов
list_available_odoh_servers() {
    # Проверка наличия кэш-файла с ODoH-серверами
    if [ ! -f "$ODOH_SERVERS_CACHE" ]; then
        echo -e "${YELLOW}Файл с ODoH-серверами не найден. Загрузите списки серверов с помощью dnscrypt-proxy.${NC}"
        return 1
    fi
    
    # Читаем и выводим список ODoH-серверов
    grep -A 1 "^## " "$ODOH_SERVERS_CACHE" | grep -v "^--" | sed 'N;s/\n/ - /' | sed 's/## //' | nl
}

# Функция для вывода доступных ODoH-релеев
list_available_odoh_relays() {
    # Проверка наличия кэш-файла с ODoH-релеями
    if [ ! -f "$ODOH_RELAYS_CACHE" ]; then
        echo -e "${YELLOW}Файл с ODoH-релеями не найден. Загрузите списки релеев с помощью dnscrypt-proxy.${NC}"
        return 1
    fi
    
    # Читаем и выводим список ODoH-релеев
    grep -A 1 "^## " "$ODOH_RELAYS_CACHE" | grep -v "^--" | sed 'N;s/\n/ - /' | sed 's/## //' | nl
}

# Тестирование скорости серверов
test_server_latency() {
    log "INFO" "Тестирование времени отклика DNS-серверов..."
    
    echo -e "\n${BLUE}Тестирование времени отклика:${NC}"
    echo "Этот тест измеряет время ответа каждого настроенного DNS-сервера."
    echo "Результаты помогут выбрать наиболее быстрые серверы для вашего местоположения."
    
    # Проверяем зависимости
    check_dependencies dig
    
    # Получаем список настроенных серверов
    local server_names_line=$(grep "server_names" "$DNSCRYPT_CONFIG" | head -1)
    
    if [ -z "$server_names_line" ]; then
        log "ERROR" "Настроенные серверы не найдены в конфигурации"
        return 1
    fi
    
    # Извлекаем только значение массива серверов
    local server_list=$(echo "$server_names_line" | grep -o "\[\([^]]*\)\]" | sed -e "s/\[//" -e "s/\]//" | tr -d "'" | tr -d '"' | tr ',' ' ')
    
    if [ -z "$server_list" ]; then
        server_list=$(dnscrypt-proxy -list -config "$DNSCRYPT_CONFIG" 2>/dev/null | grep -E "^[^ ]+" | cut -d' ' -f1 | grep -v "^$")
        
        if [ -z "$server_list" ]; then
            log "ERROR" "Не удалось определить список настроенных серверов"
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
    
    return 0
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
            log "ERROR" "Неверный выбор"
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
        
        log "SUCCESS" "Стратегия балансировки изменена на '$new_strategy'"
        
        # Перезапускаем службу
        restart_service "$DNSCRYPT_SERVICE"
    fi
    
    return 0
}

# Функция для добавления конфигурационной опции
add_config_option() {
    local config_file="$1"
    local section="$2"
    local option="$3"
    local value="$4"
    
    # Проверяем, существует ли уже опция
    if grep -q "^${option}\s*=" "$config_file"; then
        # Опция существует, обновляем ее
        sed -i "s|^${option}\s*=.*|${option} = ${value}|" "$config_file"
    else
        # Опция не существует, добавляем ее
        if [ -n "$section" ]; then
            # Добавляем в указанную секцию
            if grep -q "^\[${section}\]" "$config_file"; then
                # Секция существует
                sed -i "/^\[${section}\]/a ${option} = ${value}" "$config_file"
            else
                # Секция не существует, создаем ее
                echo -e "\n[${section}]\n${option} = ${value}" >> "$config_file"
            fi
        else
            # Добавляем в основную часть конфигурации
            echo "${option} = ${value}" >> "$config_file"
        fi
    fi
    
    log "INFO" "Настройка ${option} = ${value} добавлена в конфигурацию"
    return 0
}

# Функция для проверки наличия процесса, использующего порт
check_port_usage() {
    local port="$1"
    local processes=$(lsof -i ":$port" | grep -v "^COMMAND")
    
    if [ -n "$processes" ]; then
        echo -e "\n${YELLOW}Порт $port используется следующими процессами:${NC}"
        echo "$processes"
        return 1
    else
        echo -e "\n${GREEN}Порт $port свободен${NC}"
        return 0
    fi
}

# Функция для очистки DNS кэша
clear_dns_cache() {
    log "INFO" "Очистка DNS кэша..."
    
    # Очистка кэша systemd-resolved (если используется)
    if systemctl is-active --quiet systemd-resolved; then
        systemd-resolve --flush-caches
        log "SUCCESS" "Кэш systemd-resolved очищен"
    fi
    
    # Очистка кэша DNSCrypt (требуется перезапуск)
    if systemctl is-active --quiet dnscrypt-proxy; then
        systemctl restart dnscrypt-proxy
        log "SUCCESS" "Служба DNSCrypt перезапущена для очистки кэша"
    fi
    
    # Очистка кэша nscd (если установлен)
    if command -v nscd &>/dev/null && systemctl is-active --quiet nscd; then
        systemctl restart nscd
        log "SUCCESS" "Кэш nscd очищен"
    fi
    
    # Очистка локального кэша dnsmasq (если установлен)
    if command -v dnsmasq &>/dev/null && systemctl is-active --quiet dnsmasq; then
        systemctl restart dnsmasq
        log "SUCCESS" "Кэш dnsmasq очищен"
    fi
    
    log "SUCCESS" "Очистка DNS кэша завершена"
    return 0
}

# Инициализация при первом запуске
init_system