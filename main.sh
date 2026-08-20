#!/bin/bash

# Подгрузка общих функций. readlink -f сохраняет правильный каталог при
# запуске через /usr/local/bin/dnscrypt_manager.
resolve_script_dir() {
    local source_path
    source_path=$(readlink -f "$1") || return 1
    cd "$(dirname "$source_path")" && pwd
}
SCRIPT_DIR="$(resolve_script_dir "${BASH_SOURCE[0]}")"
source "${SCRIPT_DIR}/lib/common.sh"

# Импорт дополнительных библиотек
import_lib "anonymized_dns"
import_lib "diagnostic"

# Версия скрипта
SCRIPT_VERSION="2.1.0"

# Константы
MODULES_DIR="${SCRIPT_DIR}/modules"
CONFIG_DIR="/etc/dnscrypt-manager"
GITHUB_API_URL="${DNSCRYPT_GITHUB_API_URL:-https://api.github.com/repos/gopnikgame/Installer_dnscypt/commits/main}"
GITHUB_RAW_BASE="${DNSCRYPT_GITHUB_RAW_BASE:-https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt}"
GITHUB_REPO=""
UPDATE_COMMIT=""

# Порядок и описание модулей
declare -a MODULE_ORDER=(
    "install_dnscrypt.sh"
    "verify_installation.sh"
    "check_dns.sh"
    "change_dns.sh"
    "fix_dns.sh"
    "manage_anonymized_dns.sh"
    "clear_cache.sh"
    "restore.sh"
    "autoremove.sh"
)

declare -A MODULES=(
    ["install_dnscrypt.sh"]="Установка DNSCrypt"
    ["verify_installation.sh"]="Проверка установки"
    ["check_dns.sh"]="Проверка DNS"
    ["change_dns.sh"]="Изменение настроек DNS"
    ["fix_dns.sh"]="Исправление проблем DNS"
    ["manage_anonymized_dns.sh"]="Управление анонимным DNS"
    ["clear_cache.sh"]="Очистка кэша"
    ["restore.sh"]="Восстановление из резервной копии"
    ["autoremove.sh"]="Полное удаление DNSCrypt"
)

declare -A MODULE_DESCRIPTIONS=(
    ["install_dnscrypt.sh"]="Полная установка и первоначальная настройка DNSCrypt-proxy"
    ["verify_installation.sh"]="Проверка корректности установки и работы DNSCrypt"
    ["check_dns.sh"]="Диагностика текущей конфигурации DNS"
    ["change_dns.sh"]="Изменение серверов DNS и параметров безопасности"
    ["fix_dns.sh"]="Исправление распространенных проблем с DNS"
    ["manage_anonymized_dns.sh"]="Настройка и управление анонимизацией DNS (DNSCrypt и ODoH)"
    ["clear_cache.sh"]="Очистка кэша DNS и DNSCrypt"
    ["restore.sh"]="Восстановление предыдущих конфигураций"
    ["autoremove.sh"]="Полное удаление DNSCrypt, восстановление стандартных настроек DNS и очистка системы"
)

# Основные функции

resolve_update_snapshot() {
    local response commit
    response=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 90 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "$GITHUB_API_URL") || return 1
    commit=$(sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' <<< "$response" | sed -n '1p')
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 1
    UPDATE_COMMIT="$commit"
    GITHUB_REPO="${GITHUB_RAW_BASE}/${commit}"
    log "INFO" "Выбран свежий snapshot main: ${UPDATE_COMMIT}"
}

# Загрузка и обновление модулей
update_modules() {
    print_header "ОБНОВЛЕНИЕ МОДУЛЕЙ"
    
    local force_update=${1:-false}
    local updated=0
    local errors=0

    for module in "${MODULE_ORDER[@]}"; do
        module_file="${MODULES_DIR}/${module}"
        github_url="${GITHUB_REPO}/modules/${module}"
        
        # Проверяем, нужно ли обновлять
        if [[ "$force_update" == "true" ]] || [[ ! -f "$module_file" ]]; then
            log "INFO" "Загрузка модуля: ${module}"
            
            if ! wget -q --tries=5 --timeout=30 -O "${module_file}.tmp" "$github_url"; then
                log "ERROR" "Ошибка загрузки модуля ${module}"
                rm -f "${module_file}.tmp"
                ((errors++))
                continue
            fi
            
            # Проверяем, что файл не пустой
            if [[ ! -s "${module_file}.tmp" ]]; then
                log "ERROR" "Пустой файл модуля ${module}"
                rm -f "${module_file}.tmp"
                ((errors++))
                continue
            fi

            if ! bash -n "${module_file}.tmp"; then
                log "ERROR" "Модуль ${module} не прошёл bash -n"
                rm -f "${module_file}.tmp"
                ((errors++))
                continue
            fi
            
            # Проверяем наличие bash-шебанга
            if ! head -1 "${module_file}.tmp" | grep -q "^#!/bin/bash"; then
                log "ERROR" "Некорректный модуль ${module} (отсутствует shebang)"
                rm -f "${module_file}.tmp"
                ((errors++))
                continue
            fi
            
            mv "${module_file}.tmp" "$module_file"
            chmod +x "$module_file"
            ((updated++))
            log "SUCCESS" "Модуль ${module} успешно обновлен"
        else
            log "INFO" "Модуль ${module} уже актуален"
        fi
    done
    
    # Обновление библиотек
    update_libraries "$force_update"
    
    if [[ $updated -gt 0 ]]; then
        log "SUCCESS" "Обновлено модулей: ${updated}"
    fi
    
    if [[ $errors -gt 0 ]]; then
        log "WARN" "Ошибок при обновлении: ${errors}"
    fi
    
    return $errors
}

# Обновление библиотек
update_libraries() {
    local force_update=${1:-false}
    local lib_dir="${SCRIPT_DIR}/lib"
    mkdir -p "$lib_dir"
    
    local libs=("common.sh" "system.sh" "anonymized_dns.sh" "diagnostic.sh")
    local updated_libs=0
    local errors_libs=0
    local critical_error=false
    
    for lib in "${libs[@]}"; do
        lib_file="${lib_dir}/${lib}"
        github_url="${GITHUB_REPO}/lib/${lib}"
        
        if [[ "$force_update" == "true" ]] || [[ ! -f "$lib_file" ]]; then
            log "INFO" "Загрузка библиотеки: ${lib}"
            
            if ! wget -q --tries=5 --timeout=30 -O "${lib_file}.tmp" "$github_url"; then
                log "ERROR" "Ошибка загрузки библиотеки ${lib}"
                rm -f "${lib_file}.tmp"
                ((errors_libs++))
                
                # common.sh критически важна
                if [[ "$lib" == "common.sh" ]]; then
                    critical_error=true
                fi
                continue
            fi
            
            # Проверяем, что файл не пустой и синтаксически корректный.
            if [[ ! -s "${lib_file}.tmp" ]]; then
                log "WARN" "Пустая библиотека ${lib}"
                rm -f "${lib_file}.tmp"
                ((errors_libs++))
                [[ "$lib" == "common.sh" ]] && critical_error=true
                continue
            fi
            if ! bash -n "${lib_file}.tmp"; then
                log "ERROR" "Библиотека ${lib} не прошла bash -n"
                rm -f "${lib_file}.tmp"
                ((errors_libs++))
                [[ "$lib" == "common.sh" ]] && critical_error=true
                continue
            fi
            
            mv "${lib_file}.tmp" "$lib_file"
            ((updated_libs++))
            log "SUCCESS" "Библиотека ${lib} успешно обновлена"
        fi
    done
    
    if [[ $updated_libs -gt 0 ]]; then
        log "SUCCESS" "Обновлено библиотек: ${updated_libs}"
    fi
    
    if [[ $errors_libs -gt 0 ]]; then
        log "WARN" "Ошибок при обновлении библиотек: ${errors_libs}"
    fi
    
    # Если есть критическая ошибка, прерываем выполнение
    if [[ "$critical_error" == "true" ]]; then
        log "ERROR" "Критическая ошибка при загрузке обязательных библиотек"
        return 1
    fi
    
    return 0
}

# Запуск модуля
run_module() {
    local module_name="$1"
    local module_path="${MODULES_DIR}/${module_name}"
    
    if [[ ! -f "$module_path" ]]; then
        log "ERROR" "Модуль ${module_name} не найден"
        return 1
    fi
    
    print_header "${MODULES[$module_name]}"
    safe_echo "${BLUE}Описание:${NC} ${MODULE_DESCRIPTIONS[$module_name]}"
    echo
    
    # Дополнительное предупреждение для модуля удаления
    if [[ "$module_name" == "autoremove.sh" ]]; then
        safe_echo "${RED}ВАЖНО: Данный модуль полностью удалит DNSCrypt и все связанные с ним файлы!${NC}"
        safe_echo "${RED}Будут восстановлены стандартные настройки DNS, и удалены все конфигурации DNSCrypt.${NC}"
        echo
        read -p "Вы действительно хотите продолжить? (y/n): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log "INFO" "Операция отменена пользователем"
            return 0
        fi
    fi
    
    # Запуск модуля
    if ! bash "$module_path"; then
        log "ERROR" "Модуль ${module_name} завершился с ошибкой"
        return 1
    fi
    
    return 0
}

# Показать информацию о модуле
show_module_info() {
    local module_name="$1"
    
    safe_echo "\n${CYAN}Подробная информация о модуле:${NC}"
    safe_echo "${GREEN}Название:${NC} ${MODULES[$module_name]}"
    safe_echo "${GREEN}Файл:${NC} ${module_name}"
    safe_echo "${GREEN}Описание:${NC} ${MODULE_DESCRIPTIONS[$module_name]}"
    
    # Дополнительная информация из самого модуля
    if [[ -f "${MODULES_DIR}/${module_name}" ]]; then
        safe_echo "\n${CYAN}Дополнительная информация:${NC}"
        grep -A 10 "# Description:" "${MODULES_DIR}/${module_name}" | sed 's/# Description: //' | grep -v "#"
    fi
}

# Главное меню
show_menu() {
    while true; do
        print_header "DNSCRYPT MANAGER v${SCRIPT_VERSION}"
        safe_echo "${YELLOW}Текущая дата:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
        safe_echo "${YELLOW}Выберите действие:${NC}"
        
        local i=1
        for module in "${MODULE_ORDER[@]}"; do
            # Выделяем модуль удаления красным цветом
            if [[ "$module" == "autoremove.sh" ]]; then
                safe_echo "$i) ${RED}${MODULES[$module]}${NC}"
            else
                safe_echo "$i) ${GREEN}${MODULES[$module]}${NC}"
            fi
            ((i++))
        done
        
        safe_echo "$i) ${YELLOW}Обновить все модули${NC}"
        ((i++))
        safe_echo "$i) ${YELLOW}Показать информацию о модуле${NC}"
        ((i++))
        safe_echo "0) ${RED}Выход${NC}"
        
        read -p "Выберите опцию [0-$((i-1))]: " choice
        
        case $choice in
            0)
                log "INFO" "Завершение работы"
                exit 0
                ;;
            $((i-1)))
                # Показать информацию о модуле
                safe_echo "\n${BLUE}Выберите модуль для просмотра информации:${NC}"
                local j=1
                for module in "${MODULE_ORDER[@]}"; do
                    safe_echo "$j) ${MODULES[$module]}"
                    ((j++))
                done
                read -p "Выберите модуль [1-$((j-1))]: " module_choice
                
                if [[ "$module_choice" =~ ^[0-9]+$ ]] && [[ "$module_choice" -ge 1 ]] && [[ "$module_choice" -lt "$j" ]]; then
                    show_module_info "${MODULE_ORDER[$((module_choice-1))]}"
                else
                    log "ERROR" "Неверный выбор"
                fi
                ;;
            $((i-2)))
                if resolve_update_snapshot; then
                    update_modules true
                else
                    log "ERROR" "Не удалось определить свежий snapshot main"
                fi
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#MODULE_ORDER[@]} ]]; then
                    run_module "${MODULE_ORDER[$((choice-1))]}"
                else
                    log "ERROR" "Неверный выбор"
                fi
                ;;
        esac
        
        echo
        read -p "Нажмите Enter для продолжения..."
    done
}

# Проверка системы
check_system() {
    check_root
    check_dependencies wget curl grep sed awk
    mkdir -p "$MODULES_DIR"
    mkdir -p "$CONFIG_DIR"
    
    # Проверка совместимости между модулями и библиотеками
    if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
        # Проверка версии библиотеки common.sh
        local lib_version
        lib_version=$(grep "LIB_VERSION=" "${SCRIPT_DIR}/lib/common.sh" | cut -d'"' -f2)
        if [[ -n "$lib_version" && "$lib_version" < "1.0.0" ]]; then
            log "WARN" "Библиотека common.sh устарела (версия $lib_version). Рекомендуется обновление."
        fi
    else
        log "ERROR" "Критическая библиотека common.sh отсутствует!"
        return 1
    fi
}

# Основная функция
main() {
    check_system
    
    # При каждом запуске обновляем все файлы из одного свежего snapshot main.
    if ! resolve_update_snapshot; then
        log "ERROR" "Не удалось определить свежий snapshot main"
        return 1
    fi
    if ! update_modules true; then
        log "WARN" "Не все модули были загружены корректно"
    fi
    
    show_menu
}

# Запуск
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
