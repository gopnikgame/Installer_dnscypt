#!/bin/sh
# Compatible with bash and ash (BusyBox)

# Version: 1.3.0
# Author: gopnikgame
# Created: 2025-06-22
# Last Modified: 2025-12-12

# Определяем свежий main один раз, чтобы вся установка использовала один commit.
REPOSITORY_API="${DNSCRYPT_REPOSITORY_API:-https://api.github.com/repos/gopnikgame/Installer_dnscypt/commits/main}"
REPOSITORY_RAW_BASE="${DNSCRYPT_REPOSITORY_RAW_BASE:-https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt}"
if ! command -v wget >/dev/null 2>&1; then
    printf '%s\n' "wget не найден; установка остановлена" >&2
    exit 1
fi
if ! command -v bash >/dev/null 2>&1; then
    printf '%s\n' "bash не найден; DNSCrypt Manager не может быть установлен" >&2
    exit 1
fi
commit_response=$(wget -q --tries=5 --timeout=30 -O - "$REPOSITORY_API") || {
    printf '%s\n' "Не удалось определить свежий commit main" >&2
    exit 1
}
INSTALL_COMMIT=$(printf '%s\n' "$commit_response" | sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | sed -n '1p')
case "$INSTALL_COMMIT" in
    *[!0-9a-f]*|'') printf '%s\n' "GitHub API вернул некорректный commit" >&2; exit 1 ;;
esac
[ "${#INSTALL_COMMIT}" -eq 40 ] || { printf '%s\n' "GitHub API вернул некорректный commit" >&2; exit 1; }
DOWNLOAD_BASE="${REPOSITORY_RAW_BASE}/${INSTALL_COMMIT}"

# Подгрузка общих функций
SCRIPT_DIR="/usr/local/dnscrypt-scripts"
. "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || {
    # Если библиотека не найдена, создаем временную директорию и загружаем
    mkdir -p "${SCRIPT_DIR}/lib"
    wget -q --tries=5 --timeout=30 -O "${SCRIPT_DIR}/lib/system.sh" "${DOWNLOAD_BASE}/lib/system.sh"
    wget -q --tries=5 --timeout=30 -O "${SCRIPT_DIR}/lib/common.sh" "${DOWNLOAD_BASE}/lib/common.sh"
    . "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || {
        # Если не удалось загрузить, создаем минимальные необходимые функции
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
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
INSTALL_VERSION="1.3.0"
MAIN_SCRIPT_URL="${DOWNLOAD_BASE}/main.sh"
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
    
    libraries="system.sh common.sh anonymized_dns.sh diagnostic.sh"
    success=true
    
    for lib in $libraries; do
        lib_url="${DOWNLOAD_BASE}/lib/${lib}"
        lib_path="${LIB_DIR}/${lib}"
        candidate="${lib_path}.tmp"
        
        printf "Загрузка %s... " "$lib"
        if wget -q --tries=5 --timeout=30 -O "$candidate" "$lib_url" && \
            [ -s "$candidate" ] && bash -n "$candidate"; then
            mv -f "$candidate" "$lib_path"
            printf "${GREEN}Успешно${NC}\n"
        else
            printf "${RED}Ошибка${NC}\n"
            log "ERROR" "Ошибка при загрузке библиотеки ${lib}"
            rm -f "$candidate"
            success=false
        fi
    done
    
    if [ "$success" = "true" ]; then
        log "SUCCESS" "Все библиотеки успешно загружены"
        return 0
    else
        log "ERROR" "Не все библиотеки загружены; установка остановлена"
        return 1
    fi
}

# Загрузка главного скрипта
download_main_script() {
    print_header "УСТАНОВКА DNSCRYPT MANAGER"
    print_step "Загрузка основного скрипта..."
    
    candidate="${SCRIPT_DIR}/main.sh.tmp"
    if wget -q --tries=5 --timeout=30 -O "$candidate" "$MAIN_SCRIPT_URL" && \
        [ -s "$candidate" ] && bash -n "$candidate"; then
        chmod +x "$candidate"
        mv -f "$candidate" "${SCRIPT_DIR}/main.sh"
        
        # Создание символической ссылки
        ln -sf "${SCRIPT_DIR}/main.sh" "/usr/local/bin/dnscrypt_manager"
        ln -sf "${SCRIPT_DIR}/main.sh" "/usr/local/bin/dnscrypt-manager"
        log "SUCCESS" "Основной скрипт успешно установлен"
        
        return 0
    else
        rm -f "$candidate"
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
    platform=$(detect_platform 2>/dev/null || echo "unknown")
    
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
    platform=$(detect_platform 2>/dev/null || echo "unknown")
    
    # Проверяем зависимости в зависимости от платформы
    if [ "$platform" = "openwrt" ]; then
        # На OpenWRT проверяем только базовые команды
        check_dependencies wget grep
    else
        # На Linux менеджер служб определяется после загрузки common.sh.
        check_dependencies wget grep
        # curl опционален
        command -v curl >/dev/null 2>&1 || log "WARN" "curl не найден"
    fi
    
    create_directories
    
    # Загрузка библиотек перед скриптом
    if download_libraries; then
        log "SUCCESS" "Библиотеки успешно загружены"
    else
        log "ERROR" "Библиотеки не прошли загрузку и проверку"
        exit 1
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
