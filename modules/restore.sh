#!/bin/bash
# modules/restore.sh - Модуль восстановления DNSCrypt Manager
# Version: 2.1.0
# Created: 2025-02-16 14:17:12
# Updated: 2025-06-29 15:30:00
# Author: gopnikgame

# Подключение общей библиотеки
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Подключение библиотеки диагностики
source "$SCRIPT_DIR/lib/diagnostic.sh" 2>/dev/null || {
    log "WARN" "Не удалось подключить библиотеку diagnostic.sh"
    log "INFO" "Продолжаем с ограниченным функционалом"
}

# Версия модуля восстановления
RESTORE_VERSION="2.1.0"

# Дополнительные каталоги для бэкапов
LOCAL_BACKUP_DIR="/root/dnscrypt_backup"
EMERGENCY_BACKUP_DIR="/tmp/dnscrypt_emergency"
SYSTEM_BACKUP_DIR="/var/backups/dnscrypt"

# Metadata файл для бэкапов
BACKUP_METADATA_FILE="backup_metadata.json"

# Максимальное количество резервных копий для хранения
MAX_BACKUPS=10

# Функция создания экстренной резервной копии перед восстановлением
create_emergency_backup() {
    log "INFO" "Создание экстренной резервной копии перед восстановлением..."
    
    local emergency_timestamp=$(date '+%Y%m%d_%H%M%S')
    local emergency_backup_path="${EMERGENCY_BACKUP_DIR}/emergency_${emergency_timestamp}"
    
    mkdir -p "$emergency_backup_path"
    
    # Бэкап конфигурации DNSCrypt
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        cp "$DNSCRYPT_CONFIG" "${emergency_backup_path}/dnscrypt-proxy.toml"
        log "SUCCESS" "Сохранена конфигурация DNSCrypt"
    fi
    
    # Бэкап resolv.conf
    if [ -f "$RESOLV_CONF" ]; then
        cp "$RESOLV_CONF" "${emergency_backup_path}/resolv.conf"
        log "SUCCESS" "Сохранен resolv.conf"
    fi
    
    # Бэкап службы
    local service_file="/etc/systemd/system/dnscrypt-proxy.service"
    if [ -f "$service_file" ]; then
        cp "$service_file" "${emergency_backup_path}/dnscrypt-proxy.service"
        log "SUCCESS" "Сохранен файл службы"
    fi
    
    # Сохранение метаданных
    cat > "${emergency_backup_path}/metadata.json" <<EOF
{
    "type": "emergency",
    "created": "${emergency_timestamp}",
    "version": "${RESTORE_VERSION}",
    "system_info": "$(uname -a)",
    "dnscrypt_status": "$(systemctl is-active dnscrypt-proxy)",
    "files": {
        "dnscrypt_config": "$([ -f "$DNSCRYPT_CONFIG" ] && echo "yes" || echo "no")",
        "resolv_conf": "$([ -f "$RESOLV_CONF" ] && echo "yes" || echo "no")",
        "service_file": "$([ -f "$service_file" ] && echo "yes" || echo "no")"
    }
}
EOF
    
    log "SUCCESS" "Экстренная резервная копия создана: ${emergency_backup_path}"
    echo "$emergency_backup_path"
}

# Функция для получения информации о бэкапе
get_backup_info() {
    local backup_path="$1"
    local metadata_file="${backup_path}/metadata.json"
    
    if [ -f "$metadata_file" ]; then
        # Читаем метаданные из JSON
        local created=$(grep -o '"created": "[^"]*"' "$metadata_file" | cut -d'"' -f4)
        local type=$(grep -o '"type": "[^"]*"' "$metadata_file" | cut -d'"' -f4)
        local version=$(grep -o '"version": "[^"]*"' "$metadata_file" | cut -d'"' -f4 2>/dev/null || echo "unknown")
        
        echo "Тип: $type, Создан: $created, Версия: $version"
    else
        # Пытаемся определить информацию из имени файла
        local date_part=$(echo "$(basename "$backup_path")" | grep -oP '\d{8}_\d{6}')
        if [ -n "$date_part" ]; then
            local formatted_date=$(date -d "${date_part:0:8} ${date_part:9:2}:${date_part:11:2}:${date_part:13:2}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
            echo "Создан: $formatted_date (Legacy backup)"
        else
            echo "Неизвестная информация"
        fi
    fi
}

# Функция для валидации бэкапа
validate_backup() {
    local backup_path="$1"
    local validation_score=0
    local max_score=5
    
    log "INFO" "Валидация резервной копии: $backup_path"
    
    # Проверка наличия основных файлов
    if [ -f "${backup_path}/dnscrypt-proxy.toml" ] || [ -f "${backup_path}/$(basename "$DNSCRYPT_CONFIG")" ]; then
        validation_score=$((validation_score + 2))
        log "SUCCESS" "Конфигурация DNSCrypt найдена"
    else
        log "WARN" "Конфигурация DNSCrypt не найдена"
    fi
    
    if [ -f "${backup_path}/resolv.conf" ] || [ -f "${backup_path}/$(basename "$RESOLV_CONF")" ]; then
        validation_score=$((validation_score + 1))
        log "SUCCESS" "Файл resolv.conf найден"
    else
        log "WARN" "Файл resolv.conf не найден"
    fi
    
    if [ -f "${backup_path}/dnscrypt-proxy.service" ]; then
        validation_score=$((validation_score + 1))
        log "SUCCESS" "Файл службы найден"
    else
        log "WARN" "Файл службы не найден"
    fi
    
    # Проверка метаданных
    if [ -f "${backup_path}/metadata.json" ]; then
        validation_score=$((validation_score + 1))
        log "SUCCESS" "Метаданные найдены"
    else
        log "INFO" "Метаданные отсутствуют (legacy backup)"
    fi
    
    # Оценка валидности
    local validity_percent=$((validation_score * 100 / max_score))
    
    if [ $validity_percent -ge 80 ]; then
        safe_echo "${GREEN}Бэкап валиден (${validity_percent}%)${NC}"
        return 0
    elif [ $validity_percent -ge 40 ]; then
        safe_echo "${YELLOW}Бэкап частично валиден (${validity_percent}%)${NC}"
        return 1
    else
        safe_echo "${RED}Бэкап поврежден (${validity_percent}%)${NC}"
        return 2
    fi
}

# Функция получения всех доступных бэкапов
get_available_backups() {
    local backup_dirs=("$BACKUP_DIR" "$LOCAL_BACKUP_DIR" "$SYSTEM_BACKUP_DIR" "$EMERGENCY_BACKUP_DIR")
    local -a all_backups=()
    
    for dir in "${backup_dirs[@]}"; do
        if [ -d "$dir" ]; then
            # Ищем как файлы .bak, так и папки с бэкапами
            while IFS= read -r -d '' backup; do
                all_backups+=("$backup")
            done < <(find "$dir" -maxdepth 1 \( -name "*.bak" -o -type d \) -not -path "$dir" -print0 2>/dev/null)
        fi
    done
    
    # Сортируем по времени модификации (новые сначала)
    printf '%s\0' "${all_backups[@]}" | sort -z -t '\0' -k1,1 -r
}

# Расширенная функция выбора и восстановления
restore_backup() {
    print_header "РАСШИРЕННАЯ СИСТЕМА ВОССТАНОВЛЕНИЯ v${RESTORE_VERSION}"
    
    # Проверка root-прав
    check_root
    
    # Получение списка всех доступных бэкапов
    local -a backups=()
    while IFS= read -r -d '' backup; do
        if [ -n "$backup" ]; then
            backups+=("$backup")
        fi
    done < <(get_available_backups)
    
    if [ ${#backups[@]} -eq 0 ]; then
        log "ERROR" "Резервные копии не найдены"
        safe_echo "\n${YELLOW}Проверенные каталоги:${NC}"
        echo "  - $BACKUP_DIR"
        echo "  - $LOCAL_BACKUP_DIR"
        echo "  - $SYSTEM_BACKUP_DIR"
        echo "  - $EMERGENCY_BACKUP_DIR"
        return 1
    fi
    
    # Отображение доступных бэкапов с расширенной информацией
    safe_echo "${BLUE}Доступные резервные копии:${NC}"
    echo "┌─────┬─────────────────────────────────────────────────────────────────────────────┐"
    echo "│ №   │ Информация о резервной копии                                                │"
    echo "├─────┼─────────────────────────────────────────────────────────────────────────────┤"
    
    local i=1
    for backup in "${backups[@]}"; do
        local backup_name=$(basename "$backup")
        local backup_info=$(get_backup_info "$backup")
        local backup_size=$(du -sh "$backup" 2>/dev/null | cut -f1 || echo "N/A")
        
        printf "│ %-3s │ %-75s │\n" "$i" "$backup_name"
        printf "│     │ %-75s │\n" "$backup_info"
        printf "│     │ Размер: %-10s Путь: %-55s │\n" "$backup_size" "$(dirname "$backup")"
        
        # Валидация бэкапа
        local validation_result=""
        validate_backup "$backup" >/dev/null 2>&1
        case $? in
            0) validation_result="${GREEN}✓ Валиден${NC}" ;;
            1) validation_result="${YELLOW}⚠ Частично валиден${NC}" ;;
            2) validation_result="${RED}✗ Поврежден${NC}" ;;
        esac
        printf "│     │ Статус: %-67s │\n" "$(echo -e "$validation_result")"
        
        if [ $i -lt ${#backups[@]} ]; then
            echo "├─────┼─────────────────────────────────────────────────────────────────────────────┤"
        fi
        ((i++))
    done
    echo "└─────┴─────────────────────────────────────────────────────────────────────────────┘"
    
    # Дополнительные опции
    safe_echo "\n${BLUE}Дополнительные опции:${NC}"
    echo "$((${#backups[@]} + 1))) Создать новый полный бэкап перед восстановлением"
    echo "$((${#backups[@]} + 2))) Показать детальную информацию о бэкапе"
    echo "$((${#backups[@]} + 3))) Очистить старые бэкапы"
    echo "0) Отмена"
    
    # Выбор действия
    read -p "Выберите номер резервной копии или действие (0-$((${#backups[@]} + 3))): " choice
    
    # Обработка дополнительных опций
    if [ "$choice" -eq "$((${#backups[@]} + 1))" ]; then
        create_full_backup_before_restore
        return $?
    elif [ "$choice" -eq "$((${#backups[@]} + 2))" ]; then
        show_detailed_backup_info "${backups[@]}"
        return $?
    elif [ "$choice" -eq "$((${#backups[@]} + 3))" ]; then
        cleanup_old_backups
        return $?
    elif [ "$choice" -eq 0 ]; then
        log "INFO" "Восстановление отменено"
        return 0
    fi
    
    # Проверка корректности выбора
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backups[@]}" ]; then
        log "ERROR" "Неверный выбор"
        return 1
    fi
    
    local selected_backup="${backups[$((choice-1))]}"
    local selected_name=$(basename "$selected_backup")
    
    # Валидация выбранного бэкапа
    safe_echo "\n${BLUE}Валидация выбранного бэкапа...${NC}"
    validate_backup "$selected_backup"
    local validation_status=$?
    
    if [ $validation_status -eq 2 ]; then
        safe_echo "\n${RED}ПРЕДУПРЕЖДЕНИЕ: Выбранный бэкап может быть поврежден!${NC}"
        read -p "Продолжить восстановление из поврежденного бэкапа? (y/N): " force_restore
        if [[ ! "$force_restore" =~ ^[Yy]$ ]]; then
            log "INFO" "Восстановление отменено"
            return 0
        fi
    fi
    
    # Подтверждение восстановления
    safe_echo "\n${YELLOW}Выбран бэкап:${NC} $selected_name"
    safe_echo "${YELLOW}Информация:${NC} $(get_backup_info "$selected_backup")"
    
    read -p "Подтвердите восстановление (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "Восстановление отменено"
        return 0
    fi
    
    # Создание экстренной резервной копии
    local emergency_backup_path=$(create_emergency_backup)
    
    # Выполнение восстановления
    perform_restore "$selected_backup" "$emergency_backup_path"
}

# Функция выполнения восстановления
perform_restore() {
    local backup_path="$1"
    local emergency_backup_path="$2"
    
    print_header "ВЫПОЛНЕНИЕ ВОССТАНОВЛЕНИЯ"
    
    # Остановка службы
    log "INFO" "Остановка службы DNSCrypt..."
    if systemctl is-active --quiet "$DNSCRYPT_SERVICE"; then
        systemctl stop "$DNSCRYPT_SERVICE"
        sleep 2
    fi
    
    local restore_status=0
    local restored_files=()
    local failed_files=()
    
    # Восстановление конфигурации DNSCrypt
    restore_dnscrypt_config "$backup_path" restored_files failed_files
    restore_status=$((restore_status + $?))
    
    # Восстановление resolv.conf
    restore_resolv_conf "$backup_path" restored_files failed_files
    restore_status=$((restore_status + $?))
    
    # Восстановление службы
    restore_service_file "$backup_path" restored_files failed_files
    restore_status=$((restore_status + $?))
    
    # Восстановление дополнительных файлов
    restore_additional_files "$backup_path" restored_files failed_files
    
    # Запуск и проверка службы
    start_and_verify_service "$restore_status"
    local service_status=$?
    
    # Отчет о восстановлении
    generate_restore_report "$backup_path" "$emergency_backup_path" "${restored_files[@]}" "${failed_files[@]}" "$service_status"
    
    return $service_status
}

# Функция восстановления конфигурации DNSCrypt
restore_dnscrypt_config() {
    local backup_path="$1"
    local -n restored_ref=$2
    local -n failed_ref=$3
    
    local config_files=("dnscrypt-proxy.toml" "$(basename "$DNSCRYPT_CONFIG")")
    local config_restored=false
    
    for config_file in "${config_files[@]}"; do
        if [ -f "${backup_path}/${config_file}" ]; then
            log "INFO" "Восстановление конфигурации DNSCrypt из ${config_file}..."
            
            if restore_config "$DNSCRYPT_CONFIG" "${backup_path}/${config_file}"; then
                log "SUCCESS" "Конфигурация DNSCrypt восстановлена"
                restored_ref+=("DNSCrypt config: ${config_file}")
                config_restored=true
                break
            else
                log "ERROR" "Ошибка восстановления конфигурации DNSCrypt"
                failed_ref+=("DNSCrypt config: ${config_file}")
            fi
        fi
    done
    
    if [ "$config_restored" = false ]; then
        log "WARN" "Конфигурация DNSCrypt не найдена в бэкапе"
        failed_ref+=("DNSCrypt config: не найдена")
        return 1
    fi
    
    return 0
}

# Функция восстановления resolv.conf
restore_resolv_conf() {
    local backup_path="$1"
    local -n restored_ref=$2
    local -n failed_ref=$3
    
    if [ -f "${backup_path}/resolv.conf" ]; then
        log "INFO" "Восстановление resolv.conf..."
        
        # Снимаем защиту от записи
        if ! chattr -i "$RESOLV_CONF" 2>/dev/null; then
            log "DEBUG" "Атрибут immutable не был установлен"
        fi
        
        if cp "${backup_path}/resolv.conf" "$RESOLV_CONF"; then
            # Устанавливаем защиту от записи
            chattr +i "$RESOLV_CONF" 2>/dev/null || log "WARN" "Не удалось установить защиту resolv.conf"
            log "SUCCESS" "resolv.conf восстановлен"
            restored_ref+=("resolv.conf")
            return 0
        else
            log "ERROR" "Ошибка восстановления resolv.conf"
            failed_ref+=("resolv.conf")
            return 1
        fi
    else
        log "WARN" "resolv.conf не найден в бэкапе"
        failed_ref+=("resolv.conf: не найден")
        return 1
    fi
}

# Функция восстановления файла службы
restore_service_file() {
    local backup_path="$1"
    local -n restored_ref=$2
    local -n failed_ref=$3
    
    if [ -f "${backup_path}/dnscrypt-proxy.service" ]; then
        log "INFO" "Восстановление файла службы..."
        
        if cp "${backup_path}/dnscrypt-proxy.service" "/etc/systemd/system/"; then
            systemctl daemon-reload
            log "SUCCESS" "Файл службы восстановлен"
            restored_ref+=("service file")
            return 0
        else
            log "ERROR" "Ошибка восстановления файла службы"
            failed_ref+=("service file")
            return 1
        fi
    else
        log "WARN" "Файл службы не найден в бэкапе"
        return 0
    fi
}

# Функция восстановления дополнительных файлов
restore_additional_files() {
    local backup_path="$1"
    local -n restored_ref=$2
    local -n failed_ref=$3
    
    # Восстановление кэш-файлов (если они есть)
    local cache_files=("public-resolvers.md" "relays.md" "odoh-servers.md" "odoh-relays.md")
    
    for cache_file in "${cache_files[@]}"; do
        if [ -f "${backup_path}/${cache_file}" ]; then
            local target_path="/etc/dnscrypt-proxy/${cache_file}"
            
            if cp "${backup_path}/${cache_file}" "$target_path" 2>/dev/null; then
                log "SUCCESS" "Восстановлен кэш-файл: ${cache_file}"
                restored_ref+=("cache: ${cache_file}")
            else
                log "WARN" "Не удалось восстановить кэш-файл: ${cache_file}"
                failed_ref+=("cache: ${cache_file}")
            fi
        fi
    done
}

# Функция запуска и проверки службы
start_and_verify_service() {
    local previous_status="$1"
    
    log "INFO" "Запуск службы DNSCrypt..."
    
    # Проверка конфигурации перед запуском
    if command -v dnscrypt-proxy >/dev/null 2>&1; then
        if ! dnscrypt-proxy -check -config "$DNSCRYPT_CONFIG" >/dev/null 2>&1; then
            log "ERROR" "Конфигурация содержит ошибки"
            safe_echo "\n${YELLOW}Подробности ошибки:${NC}"
            dnscrypt-proxy -check -config "$DNSCRYPT_CONFIG" 2>&1 | head -5
            return 1
        fi
    fi
    
    # Запуск службы
    if ! systemctl start "$DNSCRYPT_SERVICE"; then
        log "ERROR" "Ошибка запуска службы DNSCrypt"
        
        # Диагностика проблемы
        safe_echo "\n${YELLOW}Диагностика проблемы:${NC}"
        if command -v check_dnscrypt_status >/dev/null 2>&1; then
            check_dnscrypt_status
        fi
        
        if command -v check_port_usage >/dev/null 2>&1; then
            check_port_usage 53
        fi
        
        # Показываем статус службы
        systemctl status "$DNSCRYPT_SERVICE" --no-pager -l
        
        return 1
    fi
    
    # Ожидание стабилизации службы
    log "INFO" "Ожидание стабилизации службы..."
    sleep 3
    
    # Проверка работоспособности
    if ! systemctl is-active --quiet "$DNSCRYPT_SERVICE"; then
        log "ERROR" "Служба не запущена после восстановления"
        return 1
    fi
    
    # Проверка DNS резолвинга
    log "INFO" "Проверка DNS резолвинга..."
    if verify_settings ""; then
        log "SUCCESS" "DNS резолвинг работает корректно"
        return 0
    else
        log "WARN" "Проблемы с DNS резолвингом после восстановления"
        return 1
    fi
}

# Функция генерации отчета о восстановлении
generate_restore_report() {
    local backup_path="$1"
    local emergency_backup_path="$2"
    shift 2
    local restored_files=("$@")
    
    print_header "ОТЧЕТ О ВОССТАНОВЛЕНИИ"
    
    safe_echo "${BLUE}Исходный бэкап:${NC} $(basename "$backup_path")"
    safe_echo "${BLUE}Информация о бэкапе:${NC} $(get_backup_info "$backup_path")"
    safe_echo "${BLUE}Экстренная копия:${NC} $emergency_backup_path"
    safe_echo "${BLUE}Время восстановления:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
    
    safe_echo "\n${GREEN}Восстановленные файлы:${NC}"
    if [ ${#restored_files[@]} -eq 0 ]; then
        echo "  Нет восстановленных файлов"
    else
        for file in "${restored_files[@]}"; do
            echo "  ✓ $file"
        done
    fi
    
    safe_echo "\n${BLUE}Текущий статус системы:${NC}"
    if systemctl is-active --quiet "$DNSCRYPT_SERVICE"; then
        safe_echo "  Служба DNSCrypt: ${GREEN}активна${NC}"
        
        # Показываем текущие настройки
        safe_echo "\n${BLUE}Текущие настройки:${NC}"
        check_current_settings
        
        # Предложение расширенной проверки
        echo
        read -p "Выполнить полную проверку системы? (y/N): " verify_choice
        if [[ "$verify_choice" =~ ^[Yy]$ ]]; then
            extended_verify_config
        fi
    else
        safe_echo "  Служба DNSCrypt: ${RED}неактивна${NC}"
        
        # Предложение восстановления из экстренной копии
        echo
        read -p "Восстановить из экстренной копии? (y/N): " emergency_restore
        if [[ "$emergency_restore" =~ ^[Yy]$ ]]; then
            perform_restore "$emergency_backup_path" ""
        fi
    fi
}

# Функция создания полного бэкапа перед восстановлением
create_full_backup_before_restore() {
    log "INFO" "Создание полного бэкапа текущей конфигурации..."
    
    backup_config "$DNSCRYPT_CONFIG" "pre-restore-dnscrypt"
    backup_config "$RESOLV_CONF" "pre-restore-resolv"
    
    log "SUCCESS" "Полный бэкап создан"
    
    # Возвращаемся к основному меню восстановления
    restore_backup
}

# Функция показа детальной информации о бэкапе
show_detailed_backup_info() {
    local backups=("$@")
    
    echo "Выберите бэкап для просмотра детальной информации:"
    local i=1
    for backup in "${backups[@]}"; do
        echo "$i) $(basename "$backup")"
        ((i++))
    done
    echo "0) Назад"
    
    read -p "Выберите номер (0-$((${#backups[@]})): " choice
    
    if [ "$choice" -eq 0 ]; then
        restore_backup
        return
    fi
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backups[@]}" ]; then
        log "ERROR" "Неверный выбор"
        return 1
    fi
    
    local selected_backup="${backups[$((choice-1))]}"
    
    print_header "ДЕТАЛЬНАЯ ИНФОРМАЦИЯ О БЭКАПЕ"
    
    safe_echo "${BLUE}Путь:${NC} $selected_backup"
    safe_echo "${BLUE}Информация:${NC} $(get_backup_info "$selected_backup")"
    safe_echo "${BLUE}Размер:${NC} $(du -sh "$selected_backup" 2>/dev/null | cut -f1 || echo "N/A")"
    
    safe_echo "\n${BLUE}Содержимое бэкапа:${NC}"
    if [ -d "$selected_backup" ]; then
        ls -la "$selected_backup"
    elif [ -f "$selected_backup" ]; then
        echo "Файл бэкапа: $(file "$selected_backup")"
    fi
    
    safe_echo "\n${BLUE}Валидация:${NC}"
    validate_backup "$selected_backup"
    
    if [ -f "${selected_backup}/metadata.json" ]; then
        safe_echo "\n${BLUE}Метаданные:${NC}"
        cat "${selected_backup}/metadata.json" | python3 -m json.tool 2>/dev/null || cat "${selected_backup}/metadata.json"
    fi
    
    read -p "Нажмите Enter для возврата в меню..."
    restore_backup
}

# Функция очистки старых бэкапов
cleanup_old_backups() {
    log "INFO" "Очистка старых резервных копий..."
    
    local backup_dirs=("$BACKUP_DIR" "$LOCAL_BACKUP_DIR" "$SYSTEM_BACKUP_DIR")
    local cleaned_count=0
    
    for dir in "${backup_dirs[@]}"; do
        if [ -d "$dir" ]; then
            safe_echo "\n${BLUE}Очистка каталога: $dir${NC}"
            
            # Получаем список бэкапов, отсортированный по времени (старые первыми)
            local -a old_backups=()
            while IFS= read -r -d '' backup; do
                old_backups+=("$backup")
            done < <(find "$dir" -maxdepth 1 \( -name "*.bak" -o -type d \) -not -path "$dir" -print0 2>/dev/null | sort -z)
            
            # Удаляем старые бэкапы, оставляя только MAX_BACKUPS
            local backups_count=${#old_backups[@]}
            if [ $backups_count -gt $MAX_BACKUPS ]; then
                local to_delete=$((backups_count - MAX_BACKUPS))
                
                safe_echo "Найдено $backups_count бэкапов, удаляем $to_delete старых..."
                
                for ((i=0; i<to_delete; i++)); do
                    local backup_to_delete="${old_backups[i]}"
                    echo "Удаление: $(basename "$backup_to_delete")"
                    
                    if rm -rf "$backup_to_delete"; then
                        cleaned_count=$((cleaned_count + 1))
                    else
                        log "ERROR" "Не удалось удалить: $backup_to_delete"
                    fi
                done
            else
                echo "Количество бэкапов ($backups_count) не превышает лимит ($MAX_BACKUPS)"
            fi
        fi
    done
    
    log "SUCCESS" "Очистка завершена. Удалено бэкапов: $cleaned_count"
    
    read -p "Нажмите Enter для возврата в меню..."
    restore_backup
}

# Основная функция - точка входа
main() {
    # Проверка зависимостей
    check_dependencies dig lsof chattr systemctl
    
    # Проверка root-прав
    check_root
    
    # Инициализация каталогов
    mkdir -p "$LOCAL_BACKUP_DIR" "$EMERGENCY_BACKUP_DIR" "$SYSTEM_BACKUP_DIR"
    
    # Запуск основной функции восстановления
    restore_backup
}

# Запуск, если скрипт выполняется напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi