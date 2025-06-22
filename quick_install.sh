#!/bin/bash

# Version: 1.1.0
# Author: gopnikgame
# Created: 2025-06-22
# Last Modified: 2025-06-22

# Цветовые коды
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Константы
INSTALL_VERSION="1.1.0"
MAIN_SCRIPT_URL="https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/main.sh"
SCRIPT_DIR="/usr/local/dnscrypt-scripts"
MODULES_DIR="${SCRIPT_DIR}/modules"
LOG_DIR="/var/log/dnscrypt"

# Функции для красивого вывода
print_header() {
    local title="$1"
    local width=60
    local padding=$(( (width - ${#title}) / 2 ))
    echo
    echo -e "${BLUE}┌$( printf '─%.0s' $(seq 1 $width) )┐${NC}"
    echo -e "${BLUE}│$( printf ' %.0s' $(seq 1 $padding) )${CYAN}$title$( printf ' %.0s' $(seq 1 $(( width - padding - ${#title} )) ) )${BLUE}│${NC}"
    echo -e "${BLUE}└$( printf '─%.0s' $(seq 1 $width) )┘${NC}"
    echo
}

print_step() {
    echo -e "${YELLOW}➜${NC} $1"
}

print_success() {
    echo -e "${GREEN}✔${NC} $1"
}

print_error() {
    echo -e "${RED}✘${NC} $1"
}

# Функция логирования
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    # Вывод в консоль
    case $level in
        "ERROR") echo -e "${timestamp} [${RED}$level${NC}] $message" ;;
        "SUCCESS") echo -e "${timestamp} [${GREEN}$level${NC}] $message" ;;
        "INFO") echo -e "${timestamp} [${BLUE}$level${NC}] $message" ;;
        *) echo -e "${timestamp} [$level] $message" ;;
    esac
    
    # Запись в лог-файл (без цветовых кодов)
    echo "${timestamp} [$level] $(echo "$message" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")" >> "$LOG_DIR/dnscrypt-installer.log"
}

# Проверка root прав
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
}

# Проверка зависимостей
check_dependencies() {
    local deps=("wget" "systemctl" "curl" "grep")
    local missing_deps=()

    print_header "ПРОВЕРКА ЗАВИСИМОСТЕЙ"
    
    for dep in "${deps[@]}"; do
        print_step "Проверка $dep..."
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
            print_error "$dep не найден"
        else
            print_success "$dep найден"
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_step "Установка отсутствующих зависимостей: ${missing_deps[*]}"
        if [ -f /etc/debian_version ]; then
            apt-get update -qq
            apt-get install -y "${missing_deps[@]}"
        elif [ -f /etc/redhat-release ]; then
            yum install -y "${missing_deps[@]}"
        else
            print_error "Неподдерживаемый дистрибутив. Установите зависимости вручную"
            exit 1
        fi
    fi
}

# Создание директорий
create_directories() {
    print_step "Создание необходимых директорий..."
    mkdir -p "$MODULES_DIR"
    mkdir -p "$LOG_DIR"
    chmod 755 "$MODULES_DIR"
    chmod 755 "$LOG_DIR"
    print_success "Директории созданы"
}

# Загрузка главного скрипта
download_main_script() {
    print_header "УСТАНОВКА DNSCRYPT MANAGER"
    print_step "Загрузка основного скрипта..."
    
    if wget -q -O "/usr/local/bin/dnscrypt_manager" "$MAIN_SCRIPT_URL"; then
        chmod +x "/usr/local/bin/dnscrypt_manager"
        print_success "Основной скрипт успешно установлен"
        
        # Создание символической ссылки
        ln -sf "/usr/local/bin/dnscrypt_manager" "/usr/local/bin/dnscrypt-manager"
        print_success "Символическая ссылка создана"
        
        return 0
    else
        print_error "Ошибка при загрузке основного скрипта"
        return 1
    fi
}

# Финальный вывод
show_completion() {
    print_header "УСТАНОВКА ЗАВЕРШЕНА"
    echo -e "${GREEN}DNSCrypt Manager версии $INSTALL_VERSION успешно установлен${NC}"
    echo
    echo -e "Для запуска используйте команду: ${YELLOW}sudo dnscrypt_manager${NC} или ${YELLOW}sudo dnscrypt-manager${NC}"
    echo -e "Все модули будут автоматически загружены при первом запуске"
    echo
}

# Основная функция
main() {
    print_header "DNSCRYPT MANAGER INSTALLER v$INSTALL_VERSION"
    
    check_root
    check_dependencies
    create_directories
    
    if download_main_script; then
        show_completion
        
        print_step "Автоматический запуск DNSCrypt Manager..."
        echo -e "Для выхода из менеджера используйте опцию '${RED}0) Выход${NC}'"
        echo
        
        # Небольшая задержка перед запуском
        sleep 2
        
        # Запуск основного скрипта
        /usr/local/bin/dnscrypt_manager
    else
        print_error "Установка не завершена из-за ошибок"
        exit 1
    fi
}

# Запуск установки
main