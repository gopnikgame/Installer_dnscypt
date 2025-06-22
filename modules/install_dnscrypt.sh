#!/bin/bash

# Цветовые коды
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Константы
DNSCRYPT_BIN_PATH="/usr/local/bin/dnscrypt-proxy"
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
DNSCRYPT_USER="dnscrypt"
DNSCRYPT_CACHE_DIR="/var/cache/dnscrypt-proxy"

# Функция логирования
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "$timestamp [$1] $2"
}

# Проверка зависимостей
check_dependencies() {
    log "INFO" "Проверка зависимостей..."
    local missing_deps=0
    local deps=("wget" "tar" "curl" "jq")
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log "ERROR" "${RED}Отсутствует зависимость: $dep${NC}"
            missing_deps=$((missing_deps+1))
        fi
    done
    
    if [ $missing_deps -gt 0 ]; then
        log "INFO" "${YELLOW}Установка отсутствующих зависимостей...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y wget tar curl jq
        elif command -v yum &> /dev/null; then
            yum install -y wget tar curl jq
        else
            log "ERROR" "${RED}Не удалось определить пакетный менеджер. Установите зависимости вручную.${NC}"
            return 1
        fi
    fi
    
    log "SUCCESS" "${GREEN}Все зависимости установлены${NC}"
    return 0
}

# Определение архитектуры системы
get_architecture() {
    local arch=$(uname -m)
    case $arch in
        x86_64)
            echo "linux_x86_64"
            ;;
        aarch64|arm64)
            echo "linux_arm64"
            ;;
        armv7l)
            echo "linux_armv7"
            ;;
        *)
            log "ERROR" "${RED}Неподдерживаемая архитектура: $arch${NC}"
            return 1
            ;;
    esac
}

# Получение последней версии DNSCrypt
get_latest_version() {
    log "INFO" "Определение последней версии DNSCrypt-proxy..."
    
    # Получение последней версии с GitHub API
    local latest_version=$(curl -s https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest | jq -r '.tag_name')
    
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        log "ERROR" "${RED}Не удалось определить последнюю версию${NC}"
        return 1
    fi
    
    # Удаляем 'v' из начала версии
    latest_version=${latest_version#v}
    log "SUCCESS" "Последняя версия DNSCrypt-proxy: ${GREEN}$latest_version${NC}"
    echo "$latest_version"
}

# Установка DNSCrypt
install_dnscrypt() {
    log "INFO" "${BLUE}Начало установки DNSCrypt...${NC}"
    
    # Проверка зависимостей
    if ! check_dependencies; then
        log "ERROR" "${RED}Проверка зависимостей не пройдена${NC}"
        return 1
    fi
    
    # Определение архитектуры
    local arch=$(get_architecture)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Получение последней версии
    local version=$(get_latest_version)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Создание пользователя
    if ! id -u "$DNSCRYPT_USER" >/dev/null 2>&1; then
        useradd -r -s /bin/false "$DNSCRYPT_USER"
        log "INFO" "Создан пользователь $DNSCRYPT_USER"
    fi
    
    # Создание директорий
    mkdir -p "/etc/dnscrypt-proxy" "/var/log/dnscrypt-proxy" "$DNSCRYPT_CACHE_DIR"
    
    # Загрузка DNSCrypt
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    
    local download_url="https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/v${version}/dnscrypt-proxy-${arch}-${version}.tar.gz"
    log "INFO" "Загрузка DNSCrypt-proxy v${version} для архитектуры ${arch}..."
    
    wget -q "$download_url" -O dnscrypt.tar.gz
    
    if [ ! -f "dnscrypt.tar.gz" ]; then
        log "ERROR" "${RED}Не удалось загрузить DNSCrypt${NC}"
        return 1
    fi
    
    # Установка
    tar xzf dnscrypt.tar.gz
    
    # Имя директории может различаться в зависимости от архитектуры
    local extract_dir
    for dir in */; do
        if [ -f "${dir}dnscrypt-proxy" ]; then
            extract_dir="${dir}"
            break
        fi
    done
    
    if [ -z "$extract_dir" ]; then
        log "ERROR" "${RED}Не удалось найти исполняемый файл dnscrypt-proxy в архиве${NC}"
        return 1
    fi
    
    cp "${extract_dir}dnscrypt-proxy" "$DNSCRYPT_BIN_PATH"
    chmod 755 "$DNSCRYPT_BIN_PATH"
    chown "$DNSCRYPT_USER:$DNSCRYPT_USER" "$DNSCRYPT_BIN_PATH"
    
    # Копирование примера конфигурации, если нет существующего файла
    if [ ! -f "$DNSCRYPT_CONFIG" ]; then
        if [ -f "${extract_dir}example-dnscrypt-proxy.toml" ]; then
            cp "${extract_dir}example-dnscrypt-proxy.toml" "$DNSCRYPT_CONFIG"
            log "INFO" "Скопирован пример конфигурации"
        fi
    fi
    
    # Настройка прав доступа к директориям
    chown -R "$DNSCRYPT_USER:$DNSCRYPT_USER" "/etc/dnscrypt-proxy" "/var/log/dnscrypt-proxy" "$DNSCRYPT_CACHE_DIR"
    
    # Очистка
    cd - >/dev/null
    rm -rf "$temp_dir"
    
    log "SUCCESS" "${GREEN}DNSCrypt версии $version установлен успешно${NC}"
    return 0
}

# Запуск установки
install_dnscrypt