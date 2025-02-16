#!/bin/bash
# modules/verify_installation.sh

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

verify_installation() {
    log "INFO" "=== Проверка установки DNSCrypt ==="
    local errors=0

    # Проверка бинарного файла
    if [ ! -x "$DNSCRYPT_BIN_PATH" ]; then
        log "ERROR" "DNSCrypt не установлен"
        return 1
    fi

    # Проверка конфигурации
    if [ ! -f "$DNSCRYPT_CONFIG" ]; then
        log "ERROR" "Конфигурация отсутствует"
        return 1
    fi

    # Проверка службы
    if ! systemctl is-active --quiet dnscrypt-proxy; then
        log "ERROR" "Служба DNSCrypt не запущена"
        errors=$((errors + 1))
    else
        log "SUCCESS" "Служба DNSCrypt активна"
    fi

    # Проверка порта
    if ! ss -lntu | grep -q ':53.*LISTEN'; then
        log "ERROR" "Порт 53 не прослушивается"
        errors=$((errors + 1))
    else
        log "SUCCESS" "Порт 53 активен"
    fi

    # Тест резолвинга
    if dig @127.0.0.1 google.com +short +timeout=5 > /dev/null; then
        log "SUCCESS" "DNS резолвинг работает"
    else
        log "ERROR" "Проблема с DNS резолвингом"
        errors=$((errors + 1))
    fi

    if [ $errors -eq 0 ]; then
        log "SUCCESS" "Все проверки пройдены успешно"
        return 0
    else
        log "ERROR" "Найдено $errors проблем"
        return 1
    fi
}

# Запуск проверки
verify_installation