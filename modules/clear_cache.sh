#!/bin/bash
# modules/clear_cache.sh

# Константы
DNSCRYPT_USER="dnscrypt"
DNSCRYPT_CACHE_DIR="/var/cache/dnscrypt-proxy"
DNSCRYPT_SERVICE="dnscrypt-proxy"

# Функция логирования
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$timestamp [$1] $2"
}

clear_cache() {
    log "INFO" "=== Очистка кэша DNSCrypt ==="
    
    # Проверка директории кэша
    if [ ! -d "$DNSCRYPT_CACHE_DIR" ]; then
        log "ERROR" "Директория кэша не найдена"
        return 1
    fi
    
    # Остановка службы
    log "INFO" "Остановка DNSCrypt..."
    systemctl stop $DNSCRYPT_SERVICE
    
    # Очистка кэша
    log "INFO" "Удаление файлов кэша..."
    rm -f "$DNSCRYPT_CACHE_DIR"/*
    
    # Установка прав
    chown "$DNSCRYPT_USER:$DNSCRYPT_USER" "$DNSCRYPT_CACHE_DIR"
    chmod 700 "$DNSCRYPT_CACHE_DIR"
    
    # Запуск службы
    log "INFO" "Запуск DNSCrypt..."
    systemctl start $DNSCRYPT_SERVICE
    
    # Проверка
    if systemctl is-active --quiet $DNSCRYPT_SERVICE; then
        log "SUCCESS" "Кэш очищен, служба перезапущена"
        return 0
    else
        log "ERROR" "Ошибка при перезапуске службы"
        systemctl status $DNSCRYPT_SERVICE --no-pager
        return 1
    fi
}

# Запуск очистки кэша
clear_cache