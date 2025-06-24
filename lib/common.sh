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

# Инициализация при первом запуске
init_system