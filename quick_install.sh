#!/bin/bash

# Version: 1.2.0
# Author: gopnikgame
# Created: 2025-06-22
# Last Modified: 2025-06-24

# Подгрузка общих функций
SCRIPT_DIR="/usr/local/dnscrypt-scripts"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || {
    # Если библиотека не найдена, создаем временную директорию и загружаем
    mkdir -p "${SCRIPT_DIR}/lib"
    wget -q -O "${SCRIPT_DIR}/lib/common.sh" "https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/lib/common.sh" 
    source "${SCRIPT_DIR}/lib/common.sh"
}

# Константы
INSTALL_VERSION="1.2.0"
MAIN_SCRIPT_URL="https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/main.sh"
MODULES_DIR="${SCRIPT_DIR}/modules"
LIB_DIR="${SCRIPT_DIR}/lib"

# Создание директорий
create_directories() {
    print_step "Создание необходимых директорий..."
    mkdir -p "$MODULES_DIR"
    mkdir -p "$LIB_DIR"
    mkdir -p "$LOG_DIR"
    chmod 755 "$MODULES_DIR"
    chmod 755 "$LIB_DIR"
    chmod 755 "$LOG_DIR"
    log "SUCCESS" "Директории созданы"
}

# Функция для отображения шагов (оставляем для удобства)
print_step() {
    echo -e "${YELLOW}➜${NC} $1"
}

# Загрузка библиотек
download_libraries() {
    print_step "Загрузка библиотек..."
    
    local libraries=("common.sh" "anonymized_dns.sh" "diagnostic.sh")
    local success=true
    
    for lib in "${libraries[@]}"; do
        local lib_url="https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/lib/${lib}"
        local lib_path="${LIB_DIR}/${lib}"
        
        if ! wget -q -O "$lib_path" "$lib_url"; then
            log "ERROR" "Ошибка при загрузке библиотеки ${lib}"
            success=false
        else
            log "SUCCESS" "Библиотека ${lib} успешно загружена"
        fi
    done
    
    if [ "$success" = true ]; then
        log "SUCCESS" "Все библиотеки успешно загружены"
        return 0
    else
        log "ERROR" "Возникли ошибки при загрузке библиотек"
        return 1
    fi
}

# Загрузка главного скрипта
download_main_script() {
    print_header "УСТАНОВКА DNSCRYPT MANAGER"
    print_step "Загрузка основного скрипта..."
    
    if wget -q -O "/usr/local/bin/dnscrypt_manager" "$MAIN_SCRIPT_URL"; then
        chmod +x "/usr/local/bin/dnscrypt_manager"
        log "SUCCESS" "Основной скрипт успешно установлен"
        
        # Создание символической ссылки
        ln -sf "/usr/local/bin/dnscrypt_manager" "/usr/local/bin/dnscrypt-manager"
        log "SUCCESS" "Символическая ссылка создана"
        
        return 0
    else
        log "ERROR" "Ошибка при загрузке основного скрипта"
        return 1
    fi
}

# Финальный вывод
show_completion() {
    print_header "УСТАНОВКА ЗАВЕРШЕНА"
    log "SUCCESS" "DNSCrypt Manager версии $INSTALL_VERSION успешно установлен"
    echo
    echo -e "Для запуска используйте команду: ${YELLOW}sudo dnscrypt_manager${NC} или ${YELLOW}sudo dnscrypt-manager${NC}"
    echo -e "Все модули будут автоматически загружены при первом запуске"
    echo
}

# Основная функция
main() {
    print_header "DNSCRYPT MANAGER INSTALLER v$INSTALL_VERSION"
    
    check_root
    check_dependencies wget systemctl curl grep
    create_directories
    
    # Загрузка библиотек перед скриптом
    if download_libraries; then
        log "SUCCESS" "Библиотеки успешно загружены"
    else
        log "WARN" "Некоторые библиотеки могут быть не загружены"
    fi
    
    if download_main_script; then
        show_completion
        
        print_step "Автоматический запуск DNSCrypt Manager..."
        echo -e "Для выхода из менеджера используйте опцию '${RED}0) Выход${NC}'"
        echo
        
        # Небольшая задержка перед запуском
        sleep 1
        
        # Запуск основного скрипта
        /usr/local/bin/dnscrypt_manager
    else
        log "ERROR" "Установка не завершена из-за ошибок"
        exit 1
    fi
}

# Запуск установки
main