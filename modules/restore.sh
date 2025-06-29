#!/bin/bash
# modules/restore.sh - Модуль восстановления из резервных копий
# Created: 2025-02-16 14:17:12
# Author: gopnikgame

# Подключение общей библиотеки
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Подключение библиотеки диагностики
source "$SCRIPT_DIR/lib/diagnostic.sh" 2>/dev/null || {
    log "WARN" "Не удалось подключить библиотеку diagnostic.sh"
    log "INFO" "Продолжаем с ограниченным функционалом"
}

# Дополнительный путь для локальных бэкапов (не переопределяем BACKUP_DIR)
LOCAL_BACKUP_DIR="/root/dnscrypt_backup"

# Функция восстановления из резервной копии
restore_backup() {
    print_header "ВОССТАНОВЛЕНИЕ ИЗ РЕЗЕРВНОЙ КОПИИ"
    
    # Проверка root-прав уже выполнена через check_root при запуске
    
    # Выбор каталога с резервными копиями
    safe_echo "${BLUE}Выберите каталог с резервными копиями:${NC}"
    echo "1) Стандартный каталог ($BACKUP_DIR)"
    echo "2) Локальный каталог ($LOCAL_BACKUP_DIR)"
    
    read -p "Выберите вариант (1-2): " dir_choice
    
    local backup_base_dir
    case $dir_choice in
        1) backup_base_dir="$BACKUP_DIR" ;;
        2) backup_base_dir="$LOCAL_BACKUP_DIR" ;;
        *) 
            log "ERROR" "Неверный выбор"
            return 1
            ;;
    esac
    
    # Проверка наличия бэкапов
    if [ ! -d "$backup_base_dir" ] || [ -z "$(ls -A "$backup_base_dir" 2>/dev/null)" ]; then
        log "ERROR" "Резервные копии не найдены в $backup_base_dir"
        return 1
    fi
    
    # Список доступных бэкапов
    local backups=($(ls -1 "$backup_base_dir"))
    
    safe_echo "${BLUE}Доступные резервные копии:${NC}"
    local i=1
    for backup in "${backups[@]}"; do
        # Добавляем информацию о дате создания, если это файл .bak
        if [[ "$backup" == *".bak" ]]; then
            local date_part=$(echo "$backup" | grep -oP '\d{8}_\d{6}')
            if [ -n "$date_part" ]; then
                local formatted_date=$(date -d "${date_part:0:8} ${date_part:9:2}:${date_part:11:2}:${date_part:13:2}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
                safe_echo "${CYAN}$i)${NC} $backup ${YELLOW}(создано: $formatted_date)${NC}"
            else
                safe_echo "${CYAN}$i)${NC} $backup"
            fi
        else
            safe_echo "${CYAN}$i)${NC} $backup"
        fi
        ((i++))
    done
    
    # Выбор бэкапа
    read -p "Выберите номер резервной копии (1-${#backups[@]}): " choice
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backups[@]}" ]; then
        log "ERROR" "Неверный выбор"
        return 1
    fi
    
    local selected_backup="${backups[$((choice-1))]}"
    local backup_path="$backup_base_dir/$selected_backup"
    
    # Подтверждение
    read -p "Восстановить из бэкапа $selected_backup? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "Восстановление отменено"
        return 0
    fi
    
    # Останавливаем службу перед восстановлением
    log "INFO" "Остановка службы $DNSCRYPT_SERVICE..."
    if systemctl is-active --quiet $DNSCRYPT_SERVICE; then
        systemctl stop $DNSCRYPT_SERVICE
        sleep 1
    fi
    
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
    else if [ -f "$backup_path" ] && [[ "$backup_path" == *"dnscrypt-config"* ]]; then
        # Это может быть отдельный файл конфигурации
        if restore_config "$DNSCRYPT_CONFIG" "$backup_path"; then
            log "SUCCESS" "Восстановлена конфигурация DNSCrypt"
        else
            restore_status=$((restore_status + 1))
        fi
    else
        log "WARN" "Конфигурация DNSCrypt не найдена в бэкапе"
        restore_status=$((restore_status + 1))
    fi
    fi
    
    # Восстановление resolv.conf
    if [ -f "$backup_path/$(basename "$RESOLV_CONF")" ]; then
        if ! chattr -i "$RESOLV_CONF" 2>/dev/null; then
            log "INFO" "Снят атрибут immutable с resolv.conf"
        fi
        
        # Копирование resolv.conf и установка защиты от изменений
        if cp "$backup_path/$(basename "$RESOLV_CONF")" "$RESOLV_CONF"; then
            chattr +i "$RESOLV_CONF" 2>/dev/null
            log "SUCCESS" "Восстановлен resolv.conf"
        else
            log "ERROR" "Ошибка восстановления resolv.conf"
            restore_status=$((restore_status + 1))
        fi
    else
        log "WARN" "resolv.conf не найден в бэкапе"
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
    fi
    
    # Запуск службы
    log "INFO" "Запуск DNSCrypt..."
    if ! systemctl start $DNSCRYPT_SERVICE; then
        log "ERROR" "Ошибка запуска службы DNSCrypt"
        
        # Используем функции диагностики
        safe_echo "\n${YELLOW}Выполняется диагностика проблемы:${NC}"
        check_dnscrypt_status
        check_port_usage 53
        
        log "WARN" "Попытка перезапуска службы..."
        systemctl restart $DNSCRYPT_SERVICE
        
        if ! systemctl is-active --quiet $DNSCRYPT_SERVICE; then
            log "ERROR" "Невозможно запустить службу DNSCrypt после восстановления"
            systemctl status $DNSCRYPT_SERVICE --no-pager
            
            safe_echo "\n${YELLOW}Вы можете попробовать:${NC}"
            echo "1. Проверить конфигурацию: sudo dnscrypt-proxy -config $DNSCRYPT_CONFIG -check"
            echo "2. Запустить диагностику: sudo $SCRIPT_DIR/modules/fix_dns.sh"
            return 1
        fi
    fi
    
    # Проверка результата
    print_header "ПРОВЕРКА ПОСЛЕ ВОССТАНОВЛЕНИЯ"
    
    if check_service_status $DNSCRYPT_SERVICE; then
        if [ $restore_status -eq 0 ]; then
            log "SUCCESS" "Восстановление выполнено успешно"
        else
            log "WARN" "Восстановление выполнено с предупреждениями"
        fi
        
        # Проверка DNS резолвинга с использованием функций из diagnostic.sh
        log "INFO" "Проверка DNS резолвинга..."
        
        # Тестирование резолвинга с помощью verify_settings из common.sh
        if verify_settings ""; then
            log "SUCCESS" "DNS резолвинг работает корректно"
            
            # Отображаем текущие настройки
            check_current_settings
            
            # Предложение выполнить расширенную проверку
            read -p "Выполнить расширенную проверку и диагностику системы? (y/n): " verify_choice
            if [[ "$verify_choice" =~ ^[Yy]$ ]]; then
                # Используем функции из diagnostic.sh
                check_system_resolver
                check_dns_security
                test_dns_speed
            fi
            
            return 0
        else
            log "ERROR" "Проблема с DNS резолвингом после восстановления"
            
            # Запускаем диагностику
            log "INFO" "Запуск диагностики DNS-проблем..."
            diagnose_dns_issues
            
            return 1
        fi
    else
        log "ERROR" "Служба $DNSCRYPT_SERVICE не запущена после восстановления"
        systemctl status $DNSCRYPT_SERVICE --no-pager
        return 1
    fi
}

# Проверка зависимостей
check_dependencies dig lsof chattr systemctl

# Проверка root-прав
check_root

# Запуск восстановления
restore_backup