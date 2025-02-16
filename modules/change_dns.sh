#!/bin/bash
# modules/change_dns.sh

# Константы
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
BACKUP_DIR="/var/backup/dnscrypt"
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")

# Цветовые коды
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

# Функция логирования
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "${timestamp} [$1] $2"
}

# Функция для создания резервной копии
backup_config() {
    mkdir -p "$BACKUP_DIR"
    cp "$DNSCRYPT_CONFIG" "${BACKUP_DIR}/dnscrypt-proxy_${TIMESTAMP}.toml"
    log "INFO" "Создана резервная копия конфигурации"
}

# Функция для проверки текущих настроек
check_current_settings() {
    log "INFO" "=== Текущие настройки DNSCrypt ==="
    
    if [ ! -f "$DNSCRYPT_CONFIG" ]; then
        log "ERROR" "Файл конфигурации не найден!"
        return 1
    fi

    echo -e "\n${BLUE}Текущие DNS серверы:${NC}"
    grep "server_names" "$DNSCRYPT_CONFIG" | sed 's/server_names = //'

    echo -e "\n${BLUE}Протоколы и безопасность:${NC}"
    echo -n "DNSSEC: "
    if grep -q "require_dnssec = true" "$DNSCRYPT_CONFIG"; then
        echo -e "${GREEN}Включен${NC}"
    else
        echo -e "${RED}Выключен${NC}"
    fi

    echo -n "NoLog: "
    if grep -q "require_nolog = true" "$DNSCRYPT_CONFIG"; then
        echo -e "${GREEN}Включен${NC}"
    else
        echo -e "${RED}Выключен${NC}"
    fi

    echo -n "NoFilter: "
    if grep -q "require_nofilter = true" "$DNSCRYPT_CONFIG"; then
        echo -e "${GREEN}Включен${NC}"
    else
        echo -e "${RED}Выключен${NC}"
    fi

    echo -e "\n${BLUE}Прослушиваемые адреса:${NC}"
    grep "listen_addresses" "$DNSCRYPT_CONFIG" | sed 's/listen_addresses = //'
}

# Функция для проверки применения настроек
verify_settings() {
    local server_name=$1
    log "INFO" "Проверка применения настроек..."
    
    # Перезапуск службы
    systemctl restart dnscrypt-proxy
    sleep 2

    # Проверка статуса службы
    if ! systemctl is-active --quiet dnscrypt-proxy; then
        log "ERROR" "Служба DNSCrypt не запущена после изменения настроек"
        return 1
    fi

    # Проверка логов на наличие ошибок
    if journalctl -u dnscrypt-proxy -n 50 | grep -i error > /dev/null; then
        log "WARN" "В логах обнаружены ошибки:"
        journalctl -u dnscrypt-proxy -n 50 | grep -i error
    fi

    # Проверка резолвинга
    echo -e "\n${BLUE}Проверка DNS резолвинга:${NC}"
    local test_domains=("google.com" "cloudflare.com" "github.com")
    local success=true

    for domain in "${test_domains[@]}"; do
        echo -n "Тест $domain: "
        if dig @127.0.0.1 "$domain" +short +timeout=5 > /dev/null 2>&1; then
            local resolve_time=$(dig @127.0.0.1 "$domain" +noall +stats 2>/dev/null | grep "Query time" | awk '{print $4}')
            echo -e "${GREEN}OK${NC} (${resolve_time}ms)"
        else
            echo -e "${RED}ОШИБКА${NC}"
            success=false
        fi
    done

    # Проверка используемого сервера
    echo -e "\n${BLUE}Проверка активного DNS сервера:${NC}"
    local current_server=$(dig +short resolver.dnscrypt.info TXT | grep -o '".*"' | tr -d '"')
    if [ -n "$current_server" ]; then
        echo "Активный сервер: $current_server"
        if [[ "$current_server" == *"$server_name"* ]]; then
            echo -e "${GREEN}✓ Настройки применены успешно${NC}"
        else
            echo -e "${YELLOW}⚠ Активный сервер отличается от выбранного${NC}"
        fi
    else
        echo -e "${RED}✗ Не удалось определить активный сервер${NC}"
    fi

    return $success
}

# Функция для применения новых настроек
apply_settings() {
    local server_name=$1
    local dnssec=$2
    local nolog=$3
    local nofilter=$4

    backup_config

    # Обновление настроек в конфигурационном файле
    sed -i "s/server_names = .*/server_names = ['$server_name']/" "$DNSCRYPT_CONFIG"
    sed -i "s/require_dnssec = .*/require_dnssec = $dnssec/" "$DNSCRYPT_CONFIG"
    sed -i "s/require_nolog = .*/require_nolog = $nolog/" "$DNSCRYPT_CONFIG"
    sed -i "s/require_nofilter = .*/require_nofilter = $nofilter/" "$DNSCRYPT_CONFIG"

    log "INFO" "Настройки обновлены"
    verify_settings "$server_name"
}

# Основная функция изменения DNS
change_dns() {
    log "INFO" "=== Настройка DNSCrypt ==="
    
    # Проверка существования конфигурационного файла
    if [ ! -f "$DNSCRYPT_CONFIG" ]; then
        log "ERROR" "Файл конфигурации DNSCrypt не найден"
        return 1
    }

    # Показать текущие настройки
    check_current_settings

    echo -e "\n${BLUE}Доступные предустановленные серверы:${NC}"
    echo "1) cloudflare (Cloudflare)"
    echo "2) google (Google DNS)"
    echo "3) quad9-dnscrypt-ip4-filter-pri (Quad9)"
    echo "4) adguard-dns (AdGuard DNS)"
    echo "5) Ввести другой сервер"
    echo "0) Отмена"

    read -p "Выберите DNS сервер (0-5): " choice

    local server_name=""
    case $choice in
        1) server_name="cloudflare" ;;
        2) server_name="google" ;;
        3) server_name="quad9-dnscrypt-ip4-filter-pri" ;;
        4) server_name="adguard-dns" ;;
        5)
            read -p "Введите имя сервера: " server_name
            ;;
        0)
            log "INFO" "Операция отменена"
            return 0
            ;;
        *)
            log "ERROR" "Неверный выбор"
            return 1
            ;;
    esac

    # Настройки безопасности
    echo -e "\n${BLUE}Настройки безопасности:${NC}"
    
    read -p "Включить DNSSEC? (y/n): " dnssec
    dnssec=$(echo "$dnssec" | tr '[:upper:]' '[:lower:]')
    dnssec=$([[ "$dnssec" == "y" ]] && echo "true" || echo "false")

    read -p "Включить NoLog? (y/n): " nolog
    nolog=$(echo "$nolog" | tr '[:upper:]' '[:lower:]')
    nolog=$([[ "$nolog" == "y" ]] && echo "true" || echo "false")

    read -p "Включить NoFilter? (y/n): " nofilter
    nofilter=$(echo "$nofilter" | tr '[:upper:]' '[:lower:]')
    nofilter=$([[ "$nofilter" == "y" ]] && echo "true" || echo "false")

    # Подтверждение изменений
    echo -e "\n${BLUE}Проверьте настройки:${NC}"
    echo "Сервер: $server_name"
    echo "DNSSEC: $dnssec"
    echo "NoLog: $nolog"
    echo "NoFilter: $nofilter"
    
    read -p "Применить настройки? (y/n): " confirm
    if [[ "${confirm,,}" == "y" ]]; then
        apply_settings "$server_name" "$dnssec" "$nolog" "$nofilter"
    else
        log "INFO" "Операция отменена"
    fi
}

# Запуск скрипта
change_dns