#!/bin/bash
# main.sh
# Created: 2025-02-16 16:32:02 UTC
# Author: gopnikgame
# Description: Главный скрипт управления DNSCrypt

# Метаданные
VERSION="2.0.55"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
MODULES_DIR="/usr/local/dnscrypt-scripts/modules"
GITHUB_RAW_URL="https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/modules"
LOG_FILE="/var/log/dnscrypt-installer.log"

# Цветовые коды для вывода
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m" # No Color

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

# Проверка root прав
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "ERROR" "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
}

# Создание необходимых директорий
create_directories() {
    mkdir -p "$MODULES_DIR"
    chmod 755 "$MODULES_DIR"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
}

# Загрузка модуля
download_module() {
    local module_name=$1
    local module_url="$GITHUB_RAW_URL/${module_name}.sh"
    local module_path="$MODULES_DIR/${module_name}.sh"
    
    log "INFO" "Загрузка модуля $module_name... из $module_url"
    
    if wget -q "$module_url" -O "$module_path"; then
        chmod +x "$module_path"
        log "SUCCESS" "Модуль $module_name загружен успешно"
        return 0
    else
        log "ERROR" "Не удалось загрузить модуль $module_name"
        return 1
    fi
}

# Проверка и загрузка модуля
ensure_module() {
    local module_name=$1
    local module_path="$MODULES_DIR/${module_name}.sh"
    
    # Всегда загружаем свежую версию модуля
    download_module "$module_name"
    return $?
}

# Выполнение модуля
execute_module() {
    local module_name=$1
    local module_path="$MODULES_DIR/${module_name}.sh"
    
    if ensure_module "$module_name"; then
        log "INFO" "Запуск модуля $module_name..."
        bash "$module_path"
        local exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            log "SUCCESS" "Модуль $module_name выполнен успешно"
        else
            log "ERROR" "Модуль $module_name завершился с ошибкой (код: $exit_code)"
        fi
        
        return $exit_code
    else
        return 1
    fi
}

# Очистка экрана и вывод заголовка
show_header() {
    clear
    echo -e "${GREEN}=== DNSCrypt Manager v$VERSION ===${NC}"
    echo "Текущее время: $(date "+%Y-%m-%d %H:%M:%S UTC")"
    echo "Пользователь: gopnikgame"
    echo "----------------------------------------"
}

# Главное меню
main_menu() {
    while true; do
        show_header
        echo "1) Установить DNSCrypt"
        echo "2) Проверить установку"
        echo "3) Изменить DNS сервер"
        echo "4) Проверить текущий DNS"
        echo "5) Исправить DNS резолвинг"
        echo "6) Управление службой"
        echo "7) Очистить кэш"
        echo "8) Создать резервную копию"
        echo "9) Восстановить из резервной копии"
        echo "L) Показать лог"
        echo "0) Выход"
        echo
        read -p "Выберите действие: " choice
        echo
        
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
            [Ll]) tail -n 50 "$LOG_FILE" ;;
            0) 
                log "INFO" "Завершение работы..."
                exit 0
                ;;
            *)
                log "ERROR" "Неверный выбор"
                ;;
        esac
        
        echo
        read -p "Нажмите Enter для продолжения..."
    done
}

# Проверяем что скрипт запущен с правами root
check_root

# Создаем необходимые директории
create_directories

# Запускаем главное меню
main_menu