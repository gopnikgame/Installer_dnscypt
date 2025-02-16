#!/bin/bash

# Константы
DNSCRYPT_BIN="/usr/local/bin/dnscrypt-proxy"
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
DNSCRYPT_SERVICE="dnscrypt-proxy.service"
LOG_FILE="/var/log/dnscrypt-installer.log"

# Цветовой вывод
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

# Функция логирования
log() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case $level in
        "ERROR")
            echo -e "${RED}$timestamp [$level] $message${NC}"
            ;;
        "SUCCESS")
            echo -e "${GREEN}$timestamp [$level] $message${NC}"
            ;;
        "WARN")
            echo -e "${YELLOW}$timestamp [$level] $message${NC}"
            ;;
        *)
            echo "$timestamp [$level] $message"
            ;;
    esac
    
    echo "$timestamp [$level] $message" >> "$LOG_FILE"
}

verify_installation() {
    local errors=0
    
    log "INFO" "Начало проверки установки DNSCrypt..."
    
    # 1. Проверка наличия бинарного файла
    if [ -f "$DNSCRYPT_BIN" ]; then
        log "SUCCESS" "DNSCrypt бинарный файл найден"
        if [ -x "$DNSCRYPT_BIN" ]; then
            log "SUCCESS" "DNSCrypt бинарный файл имеет права на выполнение"
        else
            log "ERROR" "DNSCrypt бинарный файл не имеет прав на выполнение"
            chmod +x "$DNSCRYPT_BIN"
            errors=$((errors + 1))
        fi
    else
        log "ERROR" "DNSCrypt бинарный файл не найден"
        errors=$((errors + 1))
    fi
    
    # 2. Проверка конфигурационного файла
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        log "SUCCESS" "Конфигурационный файл найден"
    else
        log "ERROR" "Конфигурационный файл не найден"
        errors=$((errors + 1))
    fi
    
    # 3. Проверка службы systemd
    if systemctl is-active --quiet dnscrypt-proxy; then
        log "SUCCESS" "Служба DNSCrypt активна"
    else
        log "ERROR" "Служба DNSCrypt не запущена"
        errors=$((errors + 1))
    fi
    
    # 4. Проверка портов
    if netstat -tulpn | grep -q ":53 .*dnscrypt-proxy"; then
        log "SUCCESS" "DNSCrypt слушает порт 53"
    else
        log "ERROR" "DNSCrypt не слушает порт 53"
        errors=$((errors + 1))
    fi
    
    # 5. Проверка DNS резолвинга
    if dig @127.0.0.1 google.com +short +timeout=5 > /dev/null 2>&1; then
        log "SUCCESS" "DNS резолвинг работает"
    else
        log "ERROR" "Проблема с DNS резолвингом"
        errors=$((errors + 1))
    fi
    
    # Итоговый результат
    if [ $errors -eq 0 ]; then
        log "SUCCESS" "Проверка завершена успешно. Ошибок не найдено."
        return 0
    else
        log "ERROR" "Проверка завершена. Найдено ошибок: $errors"
        return 1
    fi
}

# Проверка root прав
if [ "$EUID" -ne 0 ]; then
    log "ERROR" "Этот скрипт должен быть запущен с правами root"
    exit 1
fi

# Запуск проверки
verify_installation