#!/bin/bash

# Подгрузка общих функций
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Импорт дополнительных библиотек
import_lib "anonymized_dns"
import_lib "diagnostic"

# Версия скрипта
SCRIPT_VERSION="2.1.0"

# Константы
MODULES_DIR="${SCRIPT_DIR}/modules"
CONFIG_DIR="/etc/dnscrypt-manager"
GITHUB_REPO="https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main"

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
            
            if ! wget -q --tries=3 --timeout=10 -O "${module_file}.tmp" "$github_url"; then
                log "ERROR" "Ошибка загрузки модуля ${module}"
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
    
    local libs=("common.sh" "anonymized_dns.sh" "diagnostic.sh")
    local updated_libs=0
    local errors_libs=0
    local critical_error=false
    
    for lib in "${libs[@]}"; do
        lib_file="${lib_dir}/${lib}"
        github_url="${GITHUB_REPO}/lib/${lib}"
        
        if [[ "$force_update" == "true" ]] || [[ ! -f "$lib_file" ]]; then
            log "INFO" "Загрузка библиотеки: ${lib}"
            
            if ! wget -q --tries=3 --timeout=10 -O "${lib_file}.tmp" "$github_url"; then
                log "ERROR" "Ошибка загрузки библиотеки ${lib}"
                ((errors_libs++))
                
                # common.sh критически важна
                if [[ "$lib" == "common.sh" ]]; then
                    critical_error=true
                fi
                continue
            fi
            
            # Проверяем, что файл не пустой
            if [[ ! -s "${lib_file}.tmp" ]]; then
                log "WARN" "Пустая библиотека ${lib}"
                # Создаем заглушку для библиотеки
                echo "#!/bin/bash" > "${lib_file}.tmp"
                echo "# ${lib} - Пустая библиотека, будет обновлена позже" >> "${lib_file}.tmp"
                
                # common.sh критически важна
                if [[ "$lib" == "common.sh" ]]; then
                    critical_error=true
                fi
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
    echo -e "${BLUE}Описание:${NC} ${MODULE_DESCRIPTIONS[$module_name]}"
    echo
    
    # Дополнительное предупреждение для модуля удаления
    if [[ "$module_name" == "autoremove.sh" ]]; then
        echo -e "${RED}ВАЖНО: Данный модуль полностью удалит DNSCrypt и все связанные с ним файлы!${NC}"
        echo -e "${RED}Будут восстановлены стандартные настройки DNS, и удалены все конфигурации DNSCrypt.${NC}"
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
    
    echo -e "\n${CYAN}Подробная информация о модуле:${NC}"
    echo -e "${GREEN}Название:${NC} ${MODULES[$module_name]}"
    echo -e "${GREEN}Файл:${NC} ${module_name}"
    echo -e "${GREEN}Описание:${NC} ${MODULE_DESCRIPTIONS[$module_name]}"
    
    # Дополнительная информация из самого модуля
    if [[ -f "${MODULES_DIR}/${module_name}" ]]; then
        echo -e "\n${CYAN}Дополнительная информация:${NC}"
        grep -A 10 "# Description:" "${MODULES_DIR}/${module_name}" | sed 's/# Description: //' | grep -v "#"
    fi
}

# Главное меню
show_menu() {
    while true; do
        print_header "DNSCRYPT MANAGER v${SCRIPT_VERSION}"
        echo -e "${YELLOW}Текущая дата:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
        echo -e "${YELLOW}Выберите действие:${NC}"
        
        local i=1
        for module in "${MODULE_ORDER[@]}"; do
            # Выделяем модуль удаления красным цветом
            if [[ "$module" == "autoremove.sh" ]]; then
                echo -e "$i) ${RED}${MODULES[$module]}${NC}"
            else
                echo -e "$i) ${GREEN}${MODULES[$module]}${NC}"
            fi
            ((i++))
        done
        
        echo -e "$i) ${YELLOW}Обновить все модули${NC}"
        ((i++))
        echo -e "$i) ${YELLOW}Показать информацию о модуле${NC}"
        ((i++))
        echo -e "0) ${RED}Выход${NC}"
        
        read -p "Выберите опцию [0-$((i-1))]: " choice
        
        case $choice in
            0)
                log "INFO" "Завершение работы"
                exit 0
                ;;
            $((i-1)))
                # Показать информацию о модуле
                echo -e "\n${BLUE}Выберите модуль для просмотра информации:${NC}"
                local j=1
                for module in "${MODULE_ORDER[@]}"; do
                    echo -e "$j) ${MODULES[$module]}"
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
                update_modules true
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
        local lib_version=$(grep "LIB_VERSION=" "${SCRIPT_DIR}/lib/common.sh" | cut -d'"' -f2)
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
    
    # Первоначальное обновление модулей
    if ! update_modules; then
        log "WARN" "Не все модулы были загружены корректно"
    fi
    
    show_menu
}

# Запуск
main "$@"