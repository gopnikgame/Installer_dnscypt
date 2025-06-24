#!/bin/bash
# modules/restore.sh
# Created: 2025-02-16 14:17:12
# Author: gopnikgame

# Подключение общей библиотеки
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Локальный путь для бэкапов (переопределяем общий BACKUP_DIR)
LOCAL_BACKUP_DIR="/root/dnscrypt_backup"
RESOLV_CONF="/etc/resolv.conf"
DNSCRYPT_SERVICE="dnscrypt-proxy"

restore_backup() {
    print_header "ВОССТАНОВЛЕНИЕ ИЗ РЕЗЕРВНОЙ КОПИИ"
    
    # Проверка root-прав
    check_root
    
    # Проверка наличия бэкапов
    if [ ! -d "$LOCAL_BACKUP_DIR" ] || [ -z "$(ls -A "$LOCAL_BACKUP_DIR")" ]; then
        log "ERROR" "Резервные копии не найдены в $LOCAL_BACKUP_DIR"
        return 1
    fi
    
    # Список доступных бэкапов
    local backups=($(ls -1 "$LOCAL_BACKUP_DIR"))
    
    echo -e "${BLUE}Доступные резервные копии:${NC}"
    local i=1
    for backup in "${backups[@]}"; do
        echo -e "${CYAN}$i)${NC} $backup"
        ((i++))
    done
    
    # Выбор бэкапа
    read -p "Выберите номер резервной копии (1-${#backups[@]}): " choice
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backups[@]}" ]; then
        log "ERROR" "Неверный выбор"
        return 1
    fi
    
    local selected_backup="${backups[$((choice-1))]}"
    local backup_path="$LOCAL_BACKUP_DIR/$selected_backup"
    
    # Подтверждение
    read -p "Восстановить из бэкапа $selected_backup? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "Восстановление отменено"
        return 0
    fi
    
    # Остановка службы
    log "INFO" "Остановка службы $DNSCRYPT_SERVICE..."
    systemctl stop $DNSCRYPT_SERVICE
    
    # Восстановление файлов
    local restore_status=0
    
    # Восстановление конфигурации DNSCrypt
    if [ -f "$backup_path/$(basename "$DNSCRYPT_CONFIG")" ]; then
        # Используем функцию restore_config из common.sh
        if restore_config "$DNSCRYPT_CONFIG" "$backup_path/$(basename "$DNSCRYPT_CONFIG")"; then
            log "SUCCESS" "Восстановлена конфигурация DNSCrypt"
        else
            restore_status=$((restore_status + 1))
        fi
    else
        log "WARN" "Конфигурация DNSCrypt не найдена в бэкапе"
        restore_status=$((restore_status + 1))
    fi
    
    # Восстановление resolv.conf
    if [ -f "$backup_path/$(basename "$RESOLV_CONF")" ]; then
        if ! chattr -i "$RESOLV_CONF" 2>/dev/null; then
            log "INFO" "Снят атрибут immutable с resolv.conf"
        fi
        
        # Копирование resolv.conf и установка защиты от изменений
        if cp "$backup_path/$(basename "$RESOLV_CONF")" "$RESOLV_CONF"; then
            chattr +i "$RESOLV_CONF"
            log "SUCCESS" "Восстановлен resolv.conf"
        else
            log "ERROR" "Ошибка восстановления resolv.conf"
            restore_status=$((restore_status + 1))
        fi
    else
        log "WARN" "resolv.conf не найден в бэкапе"
        restore_status=$((restore_status + 1))
    fi
    
    # Восстановление службы
    if [ -f "$backup_path/dnscrypt-proxy.service" ]; then
        if cp "$backup_path/dnscrypt-proxy.service" "/etc/systemd/system/"; then
            systemctl daemon-reload
            log "SUCCESS" "Восстановлен файл службы"
        else
            log "ERROR" "Ошибка восстановления файла службы"
            restore_status=$((restore_status + 1))
        fi
    else
        log "WARN" "Файл службы не найден в бэкапе"
        restore_status=$((restore_status + 1))
    fi
    
    # Запуск службы
    log "INFO" "Запуск DNSCrypt..."
    if ! systemctl start $DNSCRYPT_SERVICE; then
        log "ERROR" "Ошибка запуска службы DNSCrypt"
        systemctl status $DNSCRYPT_SERVICE --no-pager
        return 1
    fi
    
    # Проверка результата с использованием функций из common.sh
    if check_service_status $DNSCRYPT_SERVICE; then
        if [ $restore_status -eq 0 ]; then
            log "SUCCESS" "Восстановление выполнено успешно"
        else
            log "WARN" "Восстановление выполнено с предупреждениями"
        fi
        
        # Проверка DNS резолвинга
        log "INFO" "Проверка DNS резолвинга..."
        if dig @127.0.0.1 google.com +short +timeout=5 > /dev/null; then
            log "SUCCESS" "DNS резолвинг работает"
            
            # Расширенная проверка конфигурации по запросу
            read -p "Выполнить расширенную проверку конфигурации? (y/n): " verify_choice
            if [[ "$verify_choice" =~ ^[Yy]$ ]]; then
                extended_verify_config
            fi
            
            return 0
        else
            log "ERROR" "Проблема с DNS резолвингом после восстановления"
            return 1
        fi
    else
        log "ERROR" "Служба $DNSCRYPT_SERVICE не запущена после восстановления"
        systemctl status $DNSCRYPT_SERVICE --no-pager
        return 1
    fi
}

# Запуск восстановления
restore_backup