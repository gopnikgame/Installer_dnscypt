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
    # Добавляем -s для тихого режима, чтобы вывод не перемешивался
    local api_response=$(curl -s "https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest")
    local latest_version=$(echo "$api_response" | jq -r '.tag_name')
    
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        # Резервный вариант - жестко заданная версия
        latest_version="2.1.12"
        log "WARNING" "${YELLOW}Не удалось получить версию через API, используем версию по умолчанию: $latest_version${NC}"
    else
        # Удаляем 'v' из начала версии
        latest_version=${latest_version#v}
        log "SUCCESS" "Последняя версия DNSCrypt-proxy: ${GREEN}$latest_version${NC}"
    fi
    
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
    local version=$(get_latest_version | tr -d '\n')
    # Проверка, что версия получена правильно
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "ERROR" "${RED}Неверный формат версии: '$version'. Использую версию по умолчанию 2.1.12${NC}"
        version="2.1.12"
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
    log "INFO" "Загрузка DNSCrypt-proxy версии ${version} для архитектуры ${arch}..."
    log "INFO" "URL загрузки: ${download_url}"
    
    # Улучшенная загрузка с проверками
    if ! curl -L --retry 3 --retry-delay 2 -o dnscrypt.tar.gz "$download_url"; then
        log "ERROR" "${RED}Не удалось загрузить DNSCrypt с URL: $download_url${NC}"
        
        # Альтернативный подход - прямая ссылка на последнюю стабильную версию
        local fallback_url="https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/v2.1.12/dnscrypt-proxy-${arch}-2.1.12.tar.gz"
        log "INFO" "Пробуем резервный URL: ${fallback_url}"
        
        if ! curl -L --retry 3 --retry-delay 2 -o dnscrypt.tar.gz "$fallback_url"; then
            log "ERROR" "${RED}Не удалось загрузить DNSCrypt даже с резервного URL${NC}"
            return 1
        fi
        
        version="2.1.12"
        log "INFO" "Используем версию 2.1.12 из резервного источника"
    fi
    
    # Проверяем размер загруженного файла
    local file_size=$(stat -c%s "dnscrypt.tar.gz" 2>/dev/null || stat -f%z "dnscrypt.tar.gz")
    log "INFO" "Размер загруженного архива: $file_size байт"
    
    if [ "$file_size" -lt 1000000 ]; then
        log "ERROR" "${RED}Размер загруженного файла слишком мал: $file_size байт${NC}"
        return 1
    fi
    
    # Распаковка с дополнительной проверкой
    log "INFO" "Распаковка архива..."
    if ! tar -xzf dnscrypt.tar.gz; then
        log "ERROR" "${RED}Ошибка распаковки архива${NC}"
        return 1
    fi
    
    # Вывод содержимого текущей директории для отладки
    log "INFO" "Содержимое распакованного архива:"
    ls -la
    
    # Поиск исполняемого файла
    log "INFO" "Поиск исполняемого файла dnscrypt-proxy..."
    local dnscrypt_binary=$(find . -name "dnscrypt-proxy" -type f)
    
    if [ -z "$dnscrypt_binary" ]; then
        log "ERROR" "${RED}Не удалось найти исполняемый файл dnscrypt-proxy в архиве${NC}"
        return 1
    else
        log "SUCCESS" "Найден исполняемый файл: $dnscrypt_binary"
    fi
    
    # Копирование файлов
    cp "$dnscrypt_binary" "$DNSCRYPT_BIN_PATH"
    chmod 755 "$DNSCRYPT_BIN_PATH"
    chown "$DNSCRYPT_USER:$DNSCRYPT_USER" "$DNSCRYPT_BIN_PATH"
    
    # Поиск и копирование файла конфигурации
    local config_file=$(find . -name "example-dnscrypt-proxy.toml" -type f)
    
    # Копирование примера конфигурации, если нет существующего файла
    if [ ! -f "$DNSCRYPT_CONFIG" ] && [ -n "$config_file" ]; then
        cp "$config_file" "$DNSCRYPT_CONFIG"
        log "INFO" "Скопирован пример конфигурации"
    elif [ ! -f "$DNSCRYPT_CONFIG" ]; then
        log "WARNING" "${YELLOW}Файл конфигурации не найден в архиве${NC}"
        # Создание минимальной конфигурации
        cat > "$DNSCRYPT_CONFIG" << EOL
server_names = ['cloudflare', 'google']
listen_addresses = ['127.0.0.1:53']
max_clients = 250
EOL
        log "INFO" "Создан базовый файл конфигурации"
    fi
    
    # Настройка прав доступа к директориям
    chown -R "$DNSCRYPT_USER:$DNSCRYPT_USER" "/etc/dnscrypt-proxy" "/var/log/dnscrypt-proxy" "$DNSCRYPT_CACHE_DIR"
    
    # Создание systemd сервиса
    if [ -d "/etc/systemd/system" ]; then
        cat > "/etc/systemd/system/dnscrypt-proxy.service" << EOL
[Unit]
Description=DNSCrypt-proxy client
Documentation=https://github.com/DNSCrypt/dnscrypt-proxy/wiki
After=network.target
Before=nss-lookup.target

[Service]
Type=simple
NonBlocking=true
User=${DNSCRYPT_USER}
Group=${DNSCRYPT_USER}
ExecStart=${DNSCRYPT_BIN_PATH} -config ${DNSCRYPT_CONFIG}
Restart=on-failure
RestartSec=10
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOL
        log "INFO" "Создан systemd сервис"
        
        # Перезагрузка systemd
        systemctl daemon-reload
    fi
    
    # Очистка
    cd - >/dev/null
    rm -rf "$temp_dir"
    
    log "SUCCESS" "${GREEN}DNSCrypt версии $version установлен успешно${NC}"
    return 0
}

# Запуск установки
install_dnscrypt