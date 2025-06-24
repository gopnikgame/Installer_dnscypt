#!/bin/bash
# modules/clear_cache.sh

# Подключаем общую библиотеку
source "$(dirname "$0")/../lib/common.sh"

# Константы
DNSCRYPT_USER="dnscrypt"
DNSCRYPT_CACHE_DIR="/var/cache/dnscrypt-proxy"
DNSCRYPT_SERVICE="dnscrypt-proxy"

clear_cache() {
    # Используем print_header из common.sh для заголовка
    print_header "ОЧИСТКА КЭША DNSCRYPT"
    
    # Проверка root-прав
    check_root
    
    # Проверка директории кэша
    if [ ! -d "$DNSCRYPT_CACHE_DIR" ]; then
        log "ERROR" "Директория кэша не найдена: $DNSCRYPT_CACHE_DIR"
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
    
    # Запуск службы вместо прямого вызова systemctl
    log "INFO" "Запуск DNSCrypt..."
    if ! systemctl start $DNSCRYPT_SERVICE; then
        log "ERROR" "Ошибка при запуске службы"
        systemctl status $DNSCRYPT_SERVICE --no-pager
        return 1
    fi
    
    # Проверка состояния службы с использованием функции из common.sh
    if check_service_status $DNSCRYPT_SERVICE; then
        log "SUCCESS" "Кэш успешно очищен, служба перезапущена"
        
        # Если настройки кэширования включены, покажем текущие параметры кэша
        if grep -q "cache = true" "$DNSCRYPT_CONFIG"; then
            echo -e "\n${BLUE}Текущие настройки кэша:${NC}"
            echo -n "Размер кэша: "
            grep "cache_size" "$DNSCRYPT_CONFIG" | sed 's/cache_size = //'
            echo -n "Минимальное TTL: "
            grep "cache_min_ttl" "$DNSCRYPT_CONFIG" | sed 's/cache_min_ttl = //'
            echo -n "Максимальное TTL: "
            grep "cache_max_ttl" "$DNSCRYPT_CONFIG" | sed 's/cache_max_ttl = //'
        fi
    else
        return 1
    fi
    
    return 0
}

# Проверяем, запущен ли скрипт напрямую или как модуль
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Запускаем функцию очистки кэша, если скрипт запущен напрямую
    clear_cache
fi