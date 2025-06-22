#!/bin/bash

# Цветовые коды
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Константы
MODULES_DIR="/usr/local/dnscrypt-scripts/modules"
LOG_DIR="/var/log/dnscrypt"
GITHUB_RAW="https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/modules"

# Массив модулей
declare -A MODULES=(
    ["install_dnscrypt.sh"]="Установка DNSCrypt"
    ["verify_installation.sh"]="Проверка установки"
    ["change_dns.sh"]="Смена DNS сервера"
    ["check_dns.sh"]="Проверка текущего DNS"
    ["fix_dns.sh"]="Исправление DNS резолвинга"
    ["manage_service.sh"]="Управление службой"
    ["clear_cache.sh"]="Очистка кэша"
    ["backup.sh"]="Создание резервной копии"
    ["restore.sh"]="Восстановление из резервной копии"
)

# Функция логирования
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "${timestamp} [$1] $2"
    echo -e "${timestamp} [$1] $2" >> "$LOG_DIR/dnscrypt-installer.log"
}

# Создание необходимых директорий
create_directories() {
    mkdir -p "$MODULES_DIR"
    mkdir -p "$LOG_DIR"
    chmod 755 "$MODULES_DIR"
    chmod 755 "$LOG_DIR"
}

# Проверка и загрузка модулей
check_and_download_modules() {
    local missing_modules=0
    
    for module in "${!MODULES[@]}"; do
        if [ ! -f "$MODULES_DIR/$module" ]; then
            log "INFO" "Загрузка модуля: $module..."
            if wget -q "$GITHUB_RAW/$module" -O "$MODULES_DIR/$module"; then
                chmod +x "$MODULES_DIR/$module"
                log "SUCCESS" "Модуль $module успешно загружен"
            else
                log "ERROR" "Ошибка загрузки модуля $module"
                ((missing_modules++))
            fi
        fi
    done
    
    return $missing_modules
}

# Проверка root прав
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "ERROR" "${RED}Этот скрипт должен быть запущен с правами root${NC}"
        exit 1
    fi
}

# Очистка экрана и вывод меню
show_menu() {
    clear
    echo -e "${BLUE}=== DNSCrypt Manager ===${NC}"
    echo -e "${YELLOW}Текущая дата: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo

    local i=1
    for module in "${!MODULES[@]}"; do
        echo -e "$i. ${MODULES[$module]}"
        ((i++))
    done
    
    echo -e "\n0. Выход"
    echo
}

# Основная функция
main() {
    check_root
    create_directories
    
    # Проверка и загрузка модулей
    if ! check_and_download_modules; then
        log "ERROR" "${RED}Не удалось загрузить все необходимые модули${NC}"
        exit 1
    fi

    while true; do
        show_menu
        read -p "Выберите действие (0-${#MODULES[@]}): " choice
        
        case $choice in
            0)
                echo -e "\n${GREEN}До свидания!${NC}"
                exit 0
                ;;
            [1-9]|10)
                local i=1
                for module in "${!MODULES[@]}"; do
                    if [ "$i" -eq "$choice" ]; then
                        if [ -f "$MODULES_DIR/$module" ]; then
                            bash "$MODULES_DIR/$module"
                        else
                            log "ERROR" "Модуль $module не найден"
                        fi
                        break
                    fi
                    ((i++))
                done
                ;;
            *)
                log "ERROR" "Неверный выбор"
                sleep 1
                ;;
        esac
    done
}

# Запуск основной функции
main