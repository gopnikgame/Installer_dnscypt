#!/bin/bash

# Константы
DNSCRYPT_BIN_PATH="/usr/local/bin/dnscrypt-proxy"
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
DNSCRYPT_USER="dnscrypt"
DNSCRYPT_CACHE_DIR="/var/cache/dnscrypt-proxy"

# Функция логирования
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$timestamp [$1] $2"
}

# Установка DNSCrypt
install_dnscrypt() {
    log "INFO" "Начало установки DNSCrypt..."
    
    # Создание пользователя
    if ! id -u "$DNSCRYPT_USER" >/dev/null 2>&1; then
        useradd -r -s /bin/false "$DNSCRYPT_USER"
        log "INFO" "Создан пользователь $DNSCRYPT_USER"
    fi
    
    # Создание директорий
    mkdir -p "/etc/dnscrypt-proxy" "/var/log/dnscrypt-proxy" "/var/cache/dnscrypt-proxy"
    
    # Загрузка DNSCrypt
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    
    wget -q "https://github.com/DNSCrypt/dnscrypt-proxy/releases/latest/download/dnscrypt-proxy-linux_x86_64-2.1.5.tar.gz" -O dnscrypt.tar.gz
    
    if [ ! -f "dnscrypt.tar.gz" ]; then
        log "ERROR" "Не удалось загрузить DNSCrypt"
        return 1
    fi
    
    # Установка
    tar xzf dnscrypt.tar.gz
    cp linux-x86_64/dnscrypt-proxy "$DNSCRYPT_BIN_PATH"
    chmod 755 "$DNSCRYPT_BIN_PATH"
    chown "$DNSCRYPT_USER:$DNSCRYPT_USER" "$DNSCRYPT_BIN_PATH"
    
    # Очистка
    cd - >/dev/null
    rm -rf "$temp_dir"
    
    log "SUCCESS" "DNSCrypt установлен"
    return 0
}

# Запуск установки
install_dnscrypt