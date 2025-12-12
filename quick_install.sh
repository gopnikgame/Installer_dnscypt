#!/bin/sh
# Compatible with bash and ash (BusyBox)

# Version: 1.2.1
# Author: gopnikgame
# Created: 2025-06-22
# Last Modified: 2025-12-12

# Подгрузка общих функций
SCRIPT_DIR="/usr/local/dnscrypt-scripts"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || . "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || {
    # Если библиотека не найдена, создаем временную директорию и загружаем
    mkdir -p "${SCRIPT_DIR}/lib"
    wget -q -O "${SCRIPT_DIR}/lib/common.sh" "https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/lib/common.sh" 
    source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || . "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || {
        # Если не удалось загрузить, создаем минимальные необходимые функции
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        CYAN='\033[0;36m'
        NC='\033[0m'
        
        print_header() {
            printf "\n${BLUE}=== %s ===${NC}\n\n" "$1"
        }
        
        log() {
            printf "%s [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"
        }
        
        # Проверка root-прав
        check_root() {
            if [ "$(id -u)" -ne 0 ]; then
                log "ERROR" "${RED}Этот скрипт должен быть запущен с правами root${NC}"
                exit 1
            fi
        }
        
        # Функция определения платформы
        detect_platform() {
            if [ -f /etc/openwrt_release ]; then
                echo "openwrt"
                return 0
            elif [ -f /etc/debian_version ]; then
                echo "debian"
                return 0
            else
                echo "unknown"
                return 1
            fi
        }
        
        check_dependencies() {
            for dep in "$@"; do
                if ! command -v "$dep" >/dev/null 2>&1; then
                    log "ERROR" "${RED}Не найдена зависимость: $dep${NC}"
                    exit 1
                fi
            done
        }
    }
}

# Константы
INSTALL_VERSION="1.2.1"
MAIN_SCRIPT_URL="https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/main.sh"
SCRIPT_DIR="/usr/local/dnscrypt-scripts"
MODULES_DIR="${SCRIPT_DIR}/modules"
LIB_DIR="${SCRIPT_DIR}/lib"
LOG_DIR="/var/log/dnscrypt"

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

# Функция для отображения шагов
print_step() {
    printf "${YELLOW}➜${NC} %s\n" "$1"
}

# Загрузка библиотек
download_libraries() {
    print_step "Загрузка библиотек..."
    
    local libraries="common.sh anonymized_dns.sh diagnostic.sh"
    local success=true
    
    for lib in $libraries; do
        local lib_url="https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/lib/${lib}"
        local lib_path="${LIB_DIR}/${lib}"
        
        printf "Загрузка %s... " "$lib"
        if wget -q --tries=3 --timeout=10 -O "$lib_path" "$lib_url"; then
            printf "${GREEN}Успешно${NC}\n"
            # Проверка, что библиотека не пуста
            if [ ! -s "$lib_path" ]; then
                printf "${YELLOW}Файл пуст, создаем заглушку${NC}\n"
                printf "#!/bin/sh\n# %s - Пустая библиотека\n" "$lib" > "$lib_path"
            fi
        else
            printf "${RED}Ошибка${NC}\n"
            log "ERROR" "Ошибка при загрузке библиотеки ${lib}"
            
            # Создаем заглушку для библиотеки
            printf "#!/bin/sh\n# %s - Пустая библиотека, создана автоматически\n" "$lib" > "$lib_path"
            
            success=false
        fi
    done
    
    if [ "$success" = "true" ]; then
        log "SUCCESS" "Все библиотеки успешно загружены"
        return 0
    else
        log "WARN" "Некоторые библиотеки могли быть не загружены, созданы заглушки"
        return 0
    fi
}

# Создание символических ссылок на библиотеки
create_symlinks() {
    print_step "Создание символических ссылок..."
    
    # Создаем директорию lib в /usr/local/bin, если она не существует
    mkdir -p /usr/local/bin/lib
    
    # Создаем символические ссылки для всех библиотек
    for lib_file in "${LIB_DIR}"/*.sh; do
        [ -f "$lib_file" ] || continue
        local lib_name=$(basename "$lib_file")
        ln -sf "$lib_file" "/usr/local/bin/lib/$lib_name"
    done
    
    log "SUCCESS" "Символические ссылки успешно созданы"
    return 0
}

# Патчинг пути к библиотекам в основном скрипте
patch_main_script() {
    print_step "Корректировка путей в основном скрипте..."
    
    # Проверяем, что файл существует
    if [ ! -f "${SCRIPT_DIR}/main.sh" ]; then
        log "ERROR" "Основной скрипт не найден"
        return 1
    fi
    
    # Добавляем строку для загрузки общей библиотеки с абсолютными путями
    sed -i '5i# Добавляем абсолютный путь к библиотекам\nif [ ! -f "${SCRIPT_DIR}/lib/common.sh" ]; then\n  SCRIPT_DIR="/usr/local/dnscrypt-scripts"\nfi' "${SCRIPT_DIR}/main.sh" 2>/dev/null || true
    
    log "SUCCESS" "Пути в основном скрипте скорректированы"
    return 0
}

# Загрузка главного скрипта
download_main_script() {
    print_header "УСТАНОВКА DNSCRYPT MANAGER"
    print_step "Загрузка основного скрипта..."
    
    if wget -q --tries=3 --timeout=15 -O "${SCRIPT_DIR}/main.sh" "$MAIN_SCRIPT_URL"; then
        chmod +x "${SCRIPT_DIR}/main.sh"
        
        # Патчим пути в основном скрипте
        patch_main_script
        
        # Создание символической ссылки
        ln -sf "${SCRIPT_DIR}/main.sh" "/usr/local/bin/dnscrypt_manager"
        ln -sf "${SCRIPT_DIR}/main.sh" "/usr/local/bin/dnscrypt-manager"
        log "SUCCESS" "Основной скрипт успешно установлен"
        
        return 0
    else
        log "ERROR" "Ошибка при загрузке основного скрипта"
        return 1
    fi
}

# Финальный вывод
show_completion() {
    print_header "УСТАНОВКА ЗАВЕРШЕНА"
    log "SUCCESS" "Система управления DNSCrypt Manager версии $INSTALL_VERSION успешно загружена"
    printf "\n"
    printf "${GREEN}✅ Система управления успешно установлена и готова к использованию!${NC}\n"
    printf "\n"
    
    # Определяем платформу для корректного вывода команд
    local platform=$(detect_platform 2>/dev/null || echo "unknown")
    
    if [ "$platform" = "openwrt" ]; then
        printf "Для запуска используйте:\n"
        printf "  ${YELLOW}dnscrypt_manager${NC}\n"
        printf "  ${YELLOW}dnscrypt-manager${NC}\n"
        printf "  или\n"
        printf "  ${YELLOW}sh %s/main.sh${NC}\n" "$SCRIPT_DIR"
    else
        printf "Для запуска используйте одну из команд:\n"
        printf "  ${YELLOW}sudo dnscrypt_manager${NC}\n"
        printf "  ${YELLOW}sudo dnscrypt-manager${NC}\n"
        printf "  или\n"
        printf "  ${YELLOW}sudo bash %s/main.sh${NC}\n" "$SCRIPT_DIR"
    fi
    
    printf "\n"
    printf "Все модули будут автоматически загружены при первом запуске\n"
    printf "\n"
}

# Основная функция
main() {
    print_header "DNSCRYPT MANAGER INSTALLER v$INSTALL_VERSION"
    
    check_root
    
    # Определяем платформу для проверки зависимостей
    local platform=$(detect_platform 2>/dev/null || echo "unknown")
    
    # Проверяем зависимости в зависимости от платформы
    if [ "$platform" = "openwrt" ]; then
        # На OpenWRT проверяем только базовые команды
        check_dependencies wget grep
    else
        # На Linux проверяем включая systemctl
        check_dependencies wget grep
        # curl опционален
        command -v systemctl >/dev/null 2>&1 || log "WARN" "systemctl не найден"
        command -v curl >/dev/null 2>&1 || log "WARN" "curl не найден"
    fi
    
    create_directories
    
    # Загрузка библиотек перед скриптом
    if download_libraries; then
        log "SUCCESS" "Библиотеки успешно загружены"
        
        # Создание символических ссылок для библиотек
        create_symlinks
    else
        log "WARN" "Некоторые библиотеки могут быть не загружены"
    fi
    
    if download_main_script; then
        show_completion
    else
        log "ERROR" "Установка не завершена из-за ошибок"
        exit 1
    fi
}

# Запуск установки
main