#!/bin/bash
# modules/backup.sh

# Константы
BACKUP_DIR="/root/dnscrypt_backup"
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
RESOLV_CONF="/etc/resolv.conf"

# Функция логирования
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$timestamp [$1] $2"
}

create_backup() {
    log "INFO" "=== Создание резервной копии ==="
    
    # Создание директории для бэкапа
    local backup_date=$(date +%Y%m%d_%H%M%S)
    local backup_path="${BACKUP_DIR}/${backup_date}"
    mkdir -p "$backup_path"
    
    # Список файлов для бэкапа
    local files_to_backup=(
        "$DNSCRYPT_CONFIG"
        "$RESOLV_CONF"
        "/etc/systemd/system/dnscrypt-proxy.service"
    )
    
    # Копирование файлов
    for file in "${files_to_backup[@]}"; do
        if [ -f "$file" ]; then
            cp "$file" "$backup_path/$(basename "$file")"
            log "INFO" "Сохранен файл: $file"
        fi
    done
    
    # Сохранение состояния служб
    systemctl status dnscrypt-proxy > "$backup_path/service_status.txt"
    
    # Сохранение текущих настроек DNS
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl status > "$backup_path/dns_settings.txt"
    fi
    
    # Проверка результата
    if [ -d "$backup_path" ] && [ "$(ls -A "$backup_path")" ]; then
        log "SUCCESS" "Резервная копия создана в: $backup_path"
        return 0
    else
        log "ERROR" "Ошибка при создании резервной копии"
        return 1
    fi
}

# Запуск создания бэкапа
create_backup