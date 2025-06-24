#!/bin/bash

# Версия библиотеки
LIB_VERSION="1.0.0"

# Цветовые коды для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Пути
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
BACKUP_DIR="/var/backup/dnscrypt"
LOG_DIR="/var/log/dnscrypt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Инициализация системы
init_system() {
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$LOG_DIR"
    chmod 755 "$BACKUP_DIR" "$LOG_DIR"
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
    echo "[${timestamp}] [$level] ${message}" >> "${LOG_DIR}/dnscrypt-manager.log"
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

# Инициализация при первом запуске
init_system