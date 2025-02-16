#!/bin/bash
# modules/restore.sh
# Created: 2025-02-16 14:17:12
# Author: gopnikgame

# Константы
BACKUP_DIR="/root/dnscrypt_backup"
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
RESOLV_CONF="/etc/resolv.conf"
DNSCRYPT_SERVICE="dnscrypt-proxy"

# Функция логирования
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$timestamp [$1] $2"
}

restore_backup() {
    log "INFO" "=== Восстановление из резервной копии ==="
    
    # Проверка наличия бэкапов
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR")" ]; then
        log "ERROR" "Резервные копии не найдены"
        return 1
    fi
    
    # Список доступных бэкапов
    local backups=($(ls -1 "$BACKUP_DIR"))
    
    echo "Доступные резервные копии:"
    local i=1
    for backup in "${backups[@]}"; do
        echo "$i) $backup"
        ((i++))
    done
    
    # Выбор бэкапа
    read -p "Выберите номер резервной копии (1-${#backups[@]}): " choice
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backups[@]}" ]; then
        log "ERROR" "Неверный выбор"
        return 1
    fi
    
    local selected_backup="${backups[$((choice-1))]}"
    local backup_path="$BACKUP_DIR/$selected_backup"
    
    # Подтверждение
    read -p "Восстановить из бэкапа $selected_backup? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "Восстановление отменено"
        return 0
    fi
    
    # Остановка службы
    log "INFO" "Остановка DNSCrypt..."
    systemctl stop $DNSCRYPT_SERVICE
    
    # Восстановление файлов
    local restore_status=0
    
    # Восстановление конфигурации DNSCrypt
    if [ -f "$backup_path/$(basename "$DNSCRYPT_CONFIG")" ]; then
        cp "$backup_path/$(basename "$DNSCRYPT_CONFIG")" "$DNSCRYPT_CONFIG"
        log "INFO" "Восстановлена конфигурация DNSCrypt"
    else
        log "WARN" "Конфигурация DNSCrypt не найдена в бэкапе"
        restore_status=$((restore_status + 1))
    fi
    
    # Восстановление resolv.conf
    if [ -f "$backup_path/$(basename "$RESOLV_CONF")" ]; then
        if ! chattr -i "$RESOLV_CONF" 2>/dev/null; then
            log "INFO" "Снят атрибут immutable с resolv.conf"
        fi
        cp "$backup_path/$(basename "$RESOLV_CONF")" "$RESOLV_CONF"
        chattr +i "$RESOLV_CONF"
        log "INFO" "Восстановлен resolv.conf"
    else
        log "WARN" "resolv.conf не найден в бэкапе"
        restore_status=$((restore_status + 1))
    fi
    
    # Восстановление службы
    if [ -f "$backup_path/dnscrypt-proxy.service" ]; then
        cp "$backup_path/dnscrypt-proxy.service" "/etc/systemd/system/"
        systemctl daemon-reload
        log "INFO" "Восстановлен файл службы"
    else
        log "WARN" "Файл службы не найден в бэкапе"
        restore_status=$((restore_status + 1))
    fi
    
    # Запуск службы
    log "INFO" "Запуск DNSCrypt..."
    systemctl start $DNSCRYPT_SERVICE
    
    # Проверка результата
    if systemctl is-active --quiet $DNSCRYPT_SERVICE; then
        if [ $restore_status -eq 0 ]; then
            log "SUCCESS" "Восстановление выполнено успешно"
        else
            log "WARN" "Восстановление выполнено с предупреждениями"
        fi
        
        # Проверка DNS
        if dig @127.0.0.1 google.com +short +timeout=5 > /dev/null; then
            log "SUCCESS" "DNS резолвинг работает"
            return 0
        else
            log "ERROR" "Проблема с DNS резолвингом после восстановления"
            return 1
        fi
    else
        log "ERROR" "Ошибка при запуске службы после восстановления"
        systemctl status $DNSCRYPT_SERVICE --no-pager
        return 1
    fi
}

# Запуск восстановления
restore_backup