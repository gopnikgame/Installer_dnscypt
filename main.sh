# Главный скрипт (main.sh):
#!/bin/bash

VERSION="2.0.55"
SCRIPT_START_TIME="2025-02-16 13:37:06"
CURRENT_USER="gopnikgame"
SCRIPTS_DIR="/usr/local/dnscrypt-scripts"
GITHUB_RAW_URL="https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main"

# Базовые функции логирования
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$timestamp [$1] $2"
}

# Проверка root прав
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "ERROR" "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
}

# Создание директории для скриптов
create_scripts_dir() {
    mkdir -p "$SCRIPTS_DIR"
    chmod 755 "$SCRIPTS_DIR"
}

# Загрузка модуля
download_module() {
    local module_name=$1
    local module_url="$GITHUB_RAW_URL/modules/${module_name}.sh"
    local module_path="$SCRIPTS_DIR/${module_name}.sh"
    
    log "INFO" "Загрузка модуля $module_name..."
    if wget -q "$module_url" -O "$module_path"; then
        chmod +x "$module_path"
        log "SUCCESS" "Модуль $module_name загружен"
        return 0
    else
        log "ERROR" "Не удалось загрузить модуль $module_name"
        return 1
    fi
}

# Выполнение модуля
execute_module() {
    local module_name=$1
    local module_path="$SCRIPTS_DIR/${module_name}.sh"
    
    if [ ! -f "$module_path" ]; then
        if ! download_module "$module_name"; then
            return 1
        fi
    fi
    
    log "INFO" "Запуск модуля $module_name..."
    bash "$module_path"
    return $?
}

# Главное меню
main_menu() {
    while true; do
        clear
        echo "=== DNSCrypt Manager v$VERSION ==="
        echo "1) Установить DNSCrypt"
        echo "2) Проверить установку"
        echo "3) Изменить DNS сервер"
        echo "4) Проверить текущий DNS"
        echo "5) Исправить DNS резолвинг"
        echo "6) Управление службой"
        echo "7) Очистить кэш"
        echo "8) Создать резервную копию"
        echo "9) Восстановить из резервной копии"
        echo "0) Выход"
        
        read -p "Выберите действие (0-9): " choice
        
        case $choice in
            1) execute_module "install_dnscrypt" ;;
            2) execute_module "verify_installation" ;;
            3) execute_module "change_dns" ;;
            4) execute_module "check_dns" ;;
            5) execute_module "fix_dns" ;;
            6) execute_module "manage_service" ;;
            7) execute_module "clear_cache" ;;
            8) execute_module "backup" ;;
            9) execute_module "restore" ;;
            0) 
                log "INFO" "Завершение работы..."
                exit 0
                ;;
            *)
                log "ERROR" "Неверный выбор"
                ;;
        esac
        
        read -p "Нажмите Enter для продолжения..."
    done
}

# Запуск программы
check_root
create_scripts_dir
main_menu
