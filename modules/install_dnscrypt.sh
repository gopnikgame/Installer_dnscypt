#!/bin/bash

# Подгрузка общих функций
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Подключение диагностической библиотеки
source "${SCRIPT_DIR}/lib/diagnostic.sh" 2>/dev/null || {
    log "WARN" "Библиотека diagnostic.sh не найдена. Некоторые функции будут недоступны."
    log "INFO" "Продолжение установки с ограниченной функциональностью..."
}

# Description:
# Полная установка DNSCrypt-proxy с автоматической настройкой.
# Скрипт загружает последнюю версию DNSCrypt-proxy с GitHub и устанавливает её.

# Константы
INSTALL_DIR="/opt/dnscrypt-proxy"
CONFIG_DIR="/etc/dnscrypt-proxy"
CONFIG_FILE="${CONFIG_DIR}/dnscrypt-proxy.toml"
SERVICE_NAME="dnscrypt-proxy"
DNSCRYPT_USER="dnscrypt-proxy"
DNSCRYPT_GROUP="dnscrypt-proxy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
EXAMPLE_CONFIG_URL="https://raw.githubusercontent.com/DNSCrypt/dnscrypt-proxy/master/dnscrypt-proxy/example-dnscrypt-proxy.toml"
LATEST_URL="https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest"
DNSCRYPT_PUBLIC_KEY="RWTk1xXqcTODeYttYMCMLo0YJHaFEHn7a3akqHlb/7QvIQXHVPxKbjB5"

# Определение платформы и архитектуры
PLATFORM="linux"
if [ "$(uname -m)" = "x86_64" ]; then
    CPU_ARCH="x86_64"
elif [ "$(uname -m)" = "aarch64" ]; then
    CPU_ARCH="arm64"
elif [ "$(uname -m)" = "armv7l" ]; then
    CPU_ARCH="arm"
else
    CPU_ARCH="x86_64" # Предполагаем x86_64 как наиболее распространенный вариант
    log "WARN" "Не удалось точно определить архитектуру процессора, используем x86_64 по умолчанию"
fi

# Переменные для системы отката
ROLLBACK_NEEDED=false
ROLLBACK_ACTIONS=()  # Массив для хранения действий отката
TEMP_BACKUP_DIR="/tmp/dnscrypt_rollback_$(date +%s)"

# Функция для отката изменений
rollback_changes() {
    if [ "$ROLLBACK_NEEDED" = false ]; then
        return 0
    fi
    
    log "WARN" "Запуск процедуры отката изменений..."
    
    # Обрабатываем действия отката в обратном порядке
    for ((i=${#ROLLBACK_ACTIONS[@]}-1; i>=0; i--)); do
        action="${ROLLBACK_ACTIONS[$i]}"
        log "INFO" "Выполнение действия отката: $action"
        
        case "$action" in
            "restore_resolv")
                log "INFO" "Восстановление resolv.conf из резервной копии"
                if [ -f "${TEMP_BACKUP_DIR}/resolv.conf" ]; then
                    chattr -i /etc/resolv.conf 2>/dev/null || true
                    cp "${TEMP_BACKUP_DIR}/resolv.conf" /etc/resolv.conf
                    log "SUCCESS" "resolv.conf восстановлен"
                else
                    log "WARN" "Резервная копия resolv.conf не найдена"
                fi
                ;;
                
            "restore_dnscrypt_config")
                log "INFO" "Восстановление конфигурации DNSCrypt из резервной копии"
                if [ -f "${TEMP_BACKUP_DIR}/dnscrypt-proxy.toml" ]; then
                    cp "${TEMP_BACKUP_DIR}/dnscrypt-proxy.toml" "$CONFIG_FILE"
                    log "SUCCESS" "Конфигурация DNSCrypt восстановлена"
                else
                    log "WARN" "Резервная копия конфигурации DNSCrypt не найдена"
                fi
                ;;
                
            "restore_systemd_resolved")
                log "INFO" "Восстановление systemd-resolved"
                systemctl enable systemd-resolved
                systemctl start systemd-resolved
                log "SUCCESS" "systemd-resolved восстановлен"
                ;;
                
            "remove_service")
                log "INFO" "Удаление службы DNSCrypt"
                systemctl disable dnscrypt-proxy 2>/dev/null
                systemctl stop dnscrypt-proxy 2>/dev/null
                rm -f /etc/systemd/system/dnscrypt-proxy.service
                systemctl daemon-reload
                log "SUCCESS" "Служба DNSCrypt удалена"
                ;;
                
            "remove_files")
                log "INFO" "Удаление установленных файлов DNSCrypt"
                rm -rf "$INSTALL_DIR"
                log "SUCCESS" "Файлы DNSCrypt удалены"
                ;;
                
            "remove_user")
                log "INFO" "Удаление пользователя DNSCrypt"
                id -u "$DNSCRYPT_USER" &>/dev/null && userdel "$DNSCRYPT_USER"
                log "SUCCESS" "Пользователь DNSCrypt удален"
                ;;
                
            "restart_other_dns")
                # Перезапуск других DNS-сервисов, которые были отключены
                if [ -f "${TEMP_BACKUP_DIR}/stopped_services.txt" ]; then
                    while read -r service; do
                        log "INFO" "Перезапуск сервиса $service"
                        systemctl enable "$service"
                        systemctl start "$service"
                    done < "${TEMP_BACKUP_DIR}/stopped_services.txt"
                fi
                ;;
        esac
    done
    
    log "SUCCESS" "Процедура отката завершена"
    
    # Очистка временных файлов
    rm -rf "${TEMP_BACKUP_DIR}"
    
    return 0
}

# Загрузка последней версии DNSCrypt-proxy с GitHub
download_latest_release() {
    log "INFO" "Загрузка последней версии DNSCrypt-proxy"
    
    # Создаем временный каталог
    workdir="$(mktemp -d)"
    
    # Получаем URL последней версии
    log "INFO" "Получение информации о последней версии"
    download_url="$(curl -sL "$LATEST_URL" | grep "dnscrypt-proxy-${PLATFORM}_${CPU_ARCH}-" | grep "browser_download_url" | head -1 | cut -d \" -f 4)"
    
    if [ -z "$download_url" ]; then
        log "ERROR" "Не удалось получить URL для загрузки DNSCrypt-proxy"
        rm -rf "$workdir"
        return 1
    fi
    
    # Получаем версию
    remote_version=$(curl -sL "$LATEST_URL" | grep "tag_name" | head -1 | cut -d \" -f 4)
    log "INFO" "Найдена последняя версия DNSCrypt-proxy: $remote_version"
    
    # Загружаем архив
    download_file="dnscrypt-proxy-update.tar.gz"
    log "INFO" "Загрузка DNSCrypt-proxy с $download_url"
    if ! curl --request GET -sL --url "$download_url" --output "$workdir/$download_file"; then
        log "ERROR" "Ошибка загрузки DNSCrypt-proxy"
        rm -rf "$workdir"
        return 1
    fi
    
    # Проверка подписи, если установлен minisign
    if [ -x "$(command -v minisign)" ]; then
        log "INFO" "Проверка цифровой подписи"
        if ! curl --request GET -sL --url "${download_url}.minisig" --output "$workdir/${download_file}.minisig"; then
            log "WARN" "Не удалось загрузить файл подписи"
        else
            if ! minisign -Vm "$workdir/$download_file" -P "$DNSCRYPT_PUBLIC_KEY"; then
                log "ERROR" "Проверка цифровой подписи не удалась. Установка прервана"
                rm -rf "$workdir"
                return 1
            else
                log "SUCCESS" "Цифровая подпись проверена успешно"
            fi
        fi
    else
        log "WARN" "minisign не установлен, проверка цифровой подписи не выполнена"
    fi
    
    log "SUCCESS" "DNSCrypt-proxy успешно загружен"
    echo "$workdir/$download_file"
    return 0
}

# Установка DNSCrypt-proxy из архива
install_from_archive() {
    local archive_file="$1"
    log "INFO" "Установка DNSCrypt-proxy из архива $archive_file"
    
    # Создаем директорию для установки
    mkdir -p "$INSTALL_DIR"
    
    # Создаем временную директорию для распаковки
    local extract_dir="$(mktemp -d)"
    
    # Распаковываем архив
    if ! tar xz -C "$extract_dir" -f "$archive_file"; then
        log "ERROR" "Ошибка распаковки архива $archive_file"
        rm -rf "$extract_dir"
        return 1
    fi
    
    # Копируем бинарный файл
    if ! cp -f "$extract_dir/${PLATFORM}-${CPU_ARCH}/dnscrypt-proxy" "$INSTALL_DIR/"; then
        log "ERROR" "Ошибка копирования файла dnscrypt-proxy"
        rm -rf "$extract_dir"
        return 1
    fi
    
    # Копируем пример конфигурации, если он отсутствует
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$CONFIG_FILE" ]; then
        if [ -f "$extract_dir/${PLATFORM}-${CPU_ARCH}/example-dnscrypt-proxy.toml" ]; then
            cp "$extract_dir/${PLATFORM}-${CPU_ARCH}/example-dnscrypt-proxy.toml" "$CONFIG_FILE"
        fi
    fi
    
    # Устанавливаем права на исполнение
    chmod +x "$INSTALL_DIR/dnscrypt-proxy"
    
    # Очистка
    rm -rf "$extract_dir"
    
    log "SUCCESS" "DNSCrypt-proxy установлен в $INSTALL_DIR"
    return 0
}

# Создание пользователя и группы
create_user() {
    log "INFO" "Создание пользователя и группы для DNSCrypt"
    
    # Проверяем, существует ли уже пользователь
    if id -u "$DNSCRYPT_USER" >/dev/null 2>&1; then
        log "INFO" "Пользователь $DNSCRYPT_USER уже существует"
        return 0
    fi
    
    # Создаем группу
    if ! getent group "$DNSCRYPT_GROUP" >/dev/null; then
        if ! groupadd --system "$DNSCRYPT_GROUP"; then
            log "ERROR" "Ошибка создания группы $DNSCRYPT_GROUP"
            return 1
        fi
    fi
    
    # Создаем пользователя
    if ! useradd --system --no-create-home -g "$DNSCRYPT_GROUP" -s /bin/false "$DNSCRYPT_USER"; then
        log "ERROR" "Ошибка создания пользователя $DNSCRYPT_USER"
        return 1
    fi
    
    log "SUCCESS" "Пользователь и группа $DNSCRYPT_USER созданы"
    
    # Добавляем действие отката
    ROLLBACK_NEEDED=true
    ROLLBACK_ACTIONS+=("remove_user")
    
    return 0
}

# Создание службы systemd
create_service() {
    log "INFO" "Создание службы systemd для DNSCrypt-proxy"
    
    # Создаем файл службы
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=DNSCrypt client proxy
Documentation=https://github.com/DNSCrypt/dnscrypt-proxy/wiki
After=network.target
Before=nss-lookup.target
Wants=network-online.target

[Service]
ExecStart=$INSTALL_DIR/dnscrypt-proxy -config $CONFIG_FILE
NonBlocking=true
User=$DNSCRYPT_USER
Group=$DNSCRYPT_GROUP
Restart=on-failure
RestartSec=10
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETGID CAP_SETUID
MemoryDenyWriteExecute=true
NoNewPrivileges=true
ProtectControlGroups=true
ProtectHome=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectSystem=strict
ReadWritePaths=$CONFIG_DIR
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
SystemCallArchitectures=native
SystemCallFilter=~@clock @cpu-emulation @debug @keyring @module @mount @obsolete @resources

[Install]
WantedBy=multi-user.target
EOF
    
    # Перезагружаем конфигурацию systemd
    systemctl daemon-reload
    
    # Добавляем действие отката
    ROLLBACK_NEEDED=true
    ROLLBACK_ACTIONS+=("remove_service")
    
    log "SUCCESS" "Служба systemd для DNSCrypt-proxy создана"
    return 0
}

# Настройка конфигурации
configure_dnscrypt() {
    log "INFO" "Настройка конфигурации DNSCrypt"
    
    # Создание директории конфигурации
    mkdir -p "$CONFIG_DIR"
    
    # Создание резервной копии, если файл уже существует
    if [[ -f "$CONFIG_FILE" ]]; then
        # Копируем во временный каталог для возможного отката
        mkdir -p "${TEMP_BACKUP_DIR}"
        cp "$CONFIG_FILE" "${TEMP_BACKUP_DIR}/dnscrypt-proxy.toml"
        ROLLBACK_ACTIONS+=("restore_dnscrypt_config")
        
        # Также создаем обычную резервную копию
        backup_config "$CONFIG_FILE" "dnscrypt-proxy"
    fi
    
    # Загрузка предварительно настроенного конфигурационного файла
    log "INFO" "Загрузка предварительно настроенного конфигурационного файла"
    
    PRECONFIGURED_CONFIG_URL="https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/lib/dnscrypt-proxy.toml"
    
    if ! wget -q -O "${CONFIG_FILE}.tmp" "$PRECONFIGURED_CONFIG_URL"; then
        log "WARN" "Ошибка загрузки предварительно настроенного конфигурационного файла"
        log "INFO" "Используем стандартный файл конфигурации"
        
        # Загрузка стандартного примера конфигурации в качестве запасного варианта
        if ! wget -q -O "${CONFIG_FILE}.tmp" "$EXAMPLE_CONFIG_URL"; then
            log "ERROR" "Ошибка загрузки примера конфигурации"
            return 1
        fi
        
        # Базовые настройки
        log "INFO" "Применение базовых настроек"
        sed -i "s/^listen_addresses = .*/listen_addresses = ['127.0.0.1:53']/" "${CONFIG_FILE}.tmp"
        sed -i "s/^server_names = .*/server_names = ['adguard-dns', 'quad9-dnscrypt-ip4-filter-ecs-pri']/" "${CONFIG_FILE}.tmp"
        sed -i "s/^require_dnssec = .*/require_dnssec = false/" "${CONFIG_FILE}.tmp"
    else
        log "SUCCESS" "Предварительно настроенный конфигурационный файл успешно загружен"
    fi
    
    # Адаптация для текущей версии DNSCrypt-proxy
    log "INFO" "Адаптация конфигурации для текущей версии DNSCrypt-proxy"
    
    # Проверка версии DNSCrypt-proxy
    local dnscrypt_version=$("$INSTALL_DIR/dnscrypt-proxy" -version 2>/dev/null | head -n 1 || echo "unknown")
    log "INFO" "Версия DNSCrypt-proxy: $dnscrypt_version"
    
    # Список известных несовместимых параметров для старых версий
    local known_issues=(
        "odoh_servers"       # Поддержка Oblivious DoH (может отсутствовать в старых версиях)
        "monitoring_ui"      # Мониторинг UI (добавлен в новых версиях)
        "http3_probe"        # HTTP3 параметры (могут отсутствовать в старых версиях)
        "cloak_ptr"          # PTR cloaking (может отсутствовать в старых версиях)
    )
    
    # Проверка и комментирование несовместимых параметров
    for issue in "${known_issues[@]}"; do
        if grep -q "^${issue}\s*=" "${CONFIG_FILE}.tmp" || grep -q "^\[${issue}\]" "${CONFIG_FILE}.tmp"; then
            log "INFO" "Комментирование потенциально несовместимого параметра: $issue"
            # Комментирование параметра и его значения
            sed -i "s/^${issue}\s*=/#${issue} =/g" "${CONFIG_FILE}.tmp"
            # Комментирование секций
            sed -i "s/^\[${issue}\]/#[${issue}]/g" "${CONFIG_FILE}.tmp"
        fi
    done
    
    # Особые случаи секций с вложенными параметрами
    if grep -q -E "^\[odoh_servers\]|^\[odoh-servers\]" "${CONFIG_FILE}.tmp"; then
        log "INFO" "Комментирование секции odoh_servers"
        sed -i '/^\[odoh_servers\]/,/^\[/s/^/#/' "${CONFIG_FILE}.tmp"
    fi
    
    if grep -q -E "^\[monitoring_ui\]" "${CONFIG_FILE}.tmp"; then
        log "INFO" "Комментирование секции monitoring_ui"
        sed -i '/^\[monitoring_ui\]/,/^\[/s/^/#/' "${CONFIG_FILE}.tmp"
    fi
    
    # Перемещаем временный файл в основной
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    # Установка прав доступа
    chmod 644 "$CONFIG_FILE"
    chmod 755 "$CONFIG_DIR"
    
    # Устанавливаем владельца
    chown -R "${DNSCRYPT_USER}:${DNSCRYPT_GROUP}" "$CONFIG_DIR"
    
    # Проверка конфигурации
    log "INFO" "Проверка конфигурации"
    if ! "$INSTALL_DIR/dnscrypt-proxy" -check -config="$CONFIG_FILE"; then
        log "ERROR" "Ошибка в конфигурации. Попытка исправления..."
        
        # Резервное копирование проблемной конфигурации
        cp "$CONFIG_FILE" "${CONFIG_FILE}.error"
        
        # Использование минимальной конфигурации
        cat > "$CONFIG_FILE" << EOF
# Минимальная конфигурация DNSCrypt-proxy, созданная автоматически

listen_addresses = ['127.0.0.1:53']
server_names = ['adguard-dns', 'quad9-dnscrypt-ip4-filter-ecs-pri']
require_dnssec = false
require_nolog = true
require_nofilter = false
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = true
doh_servers = true
odoh_servers = false
force_tcp = false
timeout = 5000
keepalive = 30
cert_refresh_delay = 240
bootstrap_resolvers = ['9.9.9.11:53', '8.8.8.8:53']
ignore_system_dns = true
netprobe_timeout = 60
netprobe_address = '9.9.9.9:53'
# cache
cache = true
cache_size = 4096
cache_min_ttl = 2400
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600

[sources]
[sources.public-resolvers]
urls = [
  'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md',
  'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md',
]
cache_file = 'public-resolvers.md'
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
refresh_delay = 73
prefix = ''

[sources.relays]
urls = [
  'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/relays.md',
  'https://download.dnscrypt.info/resolvers-list/v3/relays.md',
]
cache_file = 'relays.md'
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
refresh_delay = 73
prefix = ''
EOF
        
        # Повторная проверка
        if ! "$INSTALL_DIR/dnscrypt-proxy" -check -config="$CONFIG_FILE"; then
            log "ERROR" "Не удалось создать рабочую конфигурацию"
            return 1
        else
            log "SUCCESS" "Создана минимальная рабочая конфигурация"
        fi
    else
        log "SUCCESS" "Конфигурация проверена и работает корректно"
    fi
    
    log "SUCCESS" "Конфигурация DNSCrypt успешно настроена"
    return 0
}

# Настройка systemd-resolved
configure_resolved() {
    log "INFO" "Проверка и настройка systemd-resolved"
    
    # Проверка наличия systemd-resolved
    if ! systemctl is-enabled systemd-resolved &>/dev/null; then
        log "INFO" "systemd-resolved не установлен или отключен, пропускаем настройку"
        return 0
    fi
    
    log "INFO" "Настройка systemd-resolved"
    
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/dnscrypt.conf << EOF
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
EOF
    
    # Проверяем, использует ли systemd-resolved порт 53
    if lsof -i :53 | grep -q systemd-resolved; then
        log "WARN" "systemd-resolved занимает порт 53, отключаем службу"
        
        # Добавляем действие отката
        ROLLBACK_NEEDED=true
        ROLLBACK_ACTIONS+=("restore_systemd_resolved")
        
        # Создаем файл для хранения остановленных сервисов
        mkdir -p "${TEMP_BACKUP_DIR}"
        echo "systemd-resolved" >> "${TEMP_BACKUP_DIR}/stopped_services.txt"
        
        # Проверяем, настроен ли DNS-резолвинг с помощью backup_dns_server
        if [ -n "${BACKUP_DNS_SERVER}" ]; then
            log "INFO" "Используем резервный DNS-сервер: ${BACKUP_DNS_SERVER}"
        else
            log "WARN" "Резервный DNS не настроен перед отключением systemd-resolved"
            log "INFO" "Устанавливаем временный DNS-сервер 8.8.8.8 для сохранения сетевого подключения"
            export BACKUP_DNS_SERVER="8.8.8.8"
            
            chattr -i /etc/resolv.conf 2>/dev/null || true
            cat > /etc/resolv.conf << EOF
# Temporary resolv.conf by DNSCrypt installer
nameserver 8.8.8.8
options timeout:2 attempts:3
EOF
        fi
        
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        log "INFO" "systemd-resolved остановлен и отключен"
    else
        # Перезапуск службы
        if systemctl is-active --quiet systemd-resolved; then
            if ! systemctl restart systemd-resolved; then
                log "WARN" "Не удалось перезапустить systemd-resolved"
                return 1
            fi
        fi
    fi
    
    log "SUCCESS" "systemd-resolved успешно настроен"
    return 0
}

# Настройка resolv.conf
configure_resolv() {
    log "INFO" "Настройка resolv.conf"
    
    # Создание резервной копии
    if [[ -f /etc/resolv.conf ]]; then
        # Копируем во временный каталог для возможного отката
        mkdir -p "${TEMP_BACKUP_DIR}"
        cp /etc/resolv.conf "${TEMP_BACKUP_DIR}/resolv.conf"
        ROLLBACK_ACTIONS+=("restore_resolv")
        
        # Также создаем обычную резервную копию
        backup_config "/etc/resolv.conf" "resolv.conf"
    fi
    
    # Снимаем защиту от изменений
    chattr -i /etc/resolv.conf 2>/dev/null || log "INFO" "Атрибут immutable не установлен на resolv.conf"
    
    # Создаем новый resolv.conf
    cat > /etc/resolv.conf << EOF
# Generated by DNSCrypt Manager
nameserver 127.0.0.1
options edns0
EOF
    
    # Защищаем от изменений
    chattr +i /etc/resolv.conf 2>/dev/null || log "WARN" "Не удалось установить атрибут immutable на resolv.conf"
    
    log "SUCCESS" "resolv.conf успешно настроен"
    return 0
}

# Проверка доступности нужных портов
check_required_ports() {
    log "INFO" "Проверка доступности порта 53"
    
    local port_busy=false
    
    # Проверяем, занят ли порт
    if lsof -i :53 >/dev/null 2>&1; then
        port_busy=true
        log "WARN" "Порт 53 занят другим процессом"
        
        # Сохраняем текущие DNS-серверы для использования после установки
        local current_dns=$(grep "nameserver" /etc/resolv.conf | grep -v "127.0.0." | head -1 | awk '{print $2}')
        if [ -z "$current_dns" ]; then
            current_dns="8.8.8.8"
        fi
        export BACKUP_DNS_SERVER="$current_dns"
        log "INFO" "Сохранён резервный DNS-сервер: $BACKUP_DNS_SERVER"
        
        # Создаем файл для хранения остановленных сервисов
        mkdir -p "${TEMP_BACKUP_DIR}"
        
        # Определяем процесс, занимающий порт
        local process_info=$(lsof -i :53 | grep -v "^COMMAND" | head -1)
        local process=$(echo "$process_info" | awk '{print $1}')
        local process_pid=$(echo "$process_info" | awk '{print $2}')
        
        # Обработка известных служб DNS
        case "$process" in
            systemd-resolve*)
                log "INFO" "Порт занят системной службой systemd-resolved"
                ;;
            named|bind*)
                log "INFO" "Порт занят сервером BIND"
                echo "named bind9" >> "${TEMP_BACKUP_DIR}/stopped_services.txt"
                ROLLBACK_ACTIONS+=("restart_other_dns")
                systemctl stop named bind9 2>/dev/null
                systemctl disable named bind9 2>/dev/null
                log "INFO" "named/bind остановлен и отключен"
                ;;
            dnsmasq)
                log "INFO" "Порт занят DNSMasq"
                echo "dnsmasq" >> "${TEMP_BACKUP_DIR}/stopped_services.txt"
                ROLLBACK_ACTIONS+=("restart_other_dns")
                systemctl stop dnsmasq
                systemctl disable dnsmasq
                log "INFO" "dnsmasq остановлен и отключен"
                ;;
            *)
                log "WARN" "Неизвестный процесс $process (PID: $process_pid) занимает порт 53"
                ;;
        esac
        
        # Проверяем, освободился ли порт
        if lsof -i :53 >/dev/null 2>&1; then
            log "WARN" "Порт 53 всё ещё занят после попытки остановить службы"
            return 1
        else
            log "SUCCESS" "Порт 53 освобожден"
        fi
    else
        log "INFO" "Порт 53 свободен"
    fi
    
    return 0
}

# Установка необходимых зависимостей
install_dependencies() {
    log "INFO" "Установка необходимых зависимостей"
    
    # Список необходимых пакетов
    local packages=(
        "curl"
        "wget"
        "tar"
        "lsof"
        "ca-certificates"
    )
    
    # Устанавливаем minisign, если доступен
    if apt-cache show minisign &>/dev/null; then
        packages+=("minisign")
    fi
    
    # Установка пакетов
    apt-get update && apt-get install -y "${packages[@]}" || {
        log "WARN" "Не удалось установить все зависимости"
        return 1
    }
    
    log "SUCCESS" "Зависимости успешно установлены"
    return 0
}

# Главная функция установки
install_dnscrypt() {
    print_header "УСТАНОВКА DNSCRYPT-PROXY ИЗ GITHUB"
    
    # Создаем директорию для временных бэкапов
    mkdir -p "${TEMP_BACKUP_DIR}"
    
    # Проверка подключения к интернету
    if ! check_internet; then
        log "ERROR" "Отсутствует подключение к интернету. Необходимо для загрузки DNSCrypt"
        return 1
    fi
    
    # Проверка root-прав (импортируется из common.sh)
    if [ "$(id -u)" -ne 0 ]; then
        log "ERROR" "Этот скрипт должен быть запущен от имени root"
        return 1
    fi
    
    # Устанавливаем зависимости
    install_dependencies || {
        log "WARN" "Проблемы с установкой зависимостей. Продолжаем установку..."
    }
    
    # Проверка доступности портов
    check_required_ports || {
        log "WARN" "Проблемы с освобождением порта 53. Продолжение может привести к ошибкам"
        read -p "Продолжить установку несмотря на проблемы с портом? (y/n): " continue_install
        if [[ "${continue_install,,}" != "y" ]]; then
            log "INFO" "Установка прервана пользователем"
            return 1
        fi
    }
    
    # Создание пользователя
    create_user || {
        log "ERROR" "Ошибка создания пользователя"
        rollback_changes
        return 1
    }
    
    # Загрузка последней версии
    local archive_file
    archive_file=$(download_latest_release) || {
        log "ERROR" "Ошибка загрузки DNSCrypt-proxy"
        rollback_changes
        return 1
    }
    
    # Устанавливаем DNSCrypt из архива
    install_from_archive "$archive_file" || {
        log "ERROR" "Ошибка установки DNSCrypt-proxy из архива"
        rollback_changes
        return 1
    }
    
    # Добавляем действие отката
    ROLLBACK_NEEDED=true
    ROLLBACK_ACTIONS+=("remove_files")
    
    # Настройка конфигурации
    configure_dnscrypt || {
        log "ERROR" "Ошибка настройки конфигурации DNSCrypt"
        rollback_changes
        return 1
    }
    
    # Создание службы systemd
    create_service || {
        log "ERROR" "Ошибка создания службы systemd"
        rollback_changes
        return 1
    }
    
    # Настройка DNS
    configure_resolved || {
        log "ERROR" "Ошибка настройки systemd-resolved"
        rollback_changes
        return 1
    }
    
    configure_resolv || {
        log "ERROR" "Ошибка настройки resolv.conf"
        rollback_changes
        return 1
    }
    
    # Запуск службы
    log "INFO" "Запуск службы DNSCrypt"
    systemctl enable dnscrypt-proxy || log "WARN" "Не удалось включить автозапуск службы"
    
    if ! systemctl restart dnscrypt-proxy; then
        log "ERROR" "Не удалось запустить службу DNSCrypt"
        log "INFO" "Проверка логов службы:"
        journalctl -u dnscrypt-proxy -n 10 --no-pager
        
        rollback_changes
        return 1
    fi
    
    # Проверка работы с использованием verify_settings из common.sh
    log "INFO" "Проверка правильности работы DNSCrypt..."
    sleep 3 # Даем время на инициализацию
    
    if verify_settings ""; then
        log "SUCCESS" "DNSCrypt успешно установлен и работает!"
        # Очищаем временные файлы для отката, так как установка успешна
        rm -rf "${TEMP_BACKUP_DIR}"
        ROLLBACK_NEEDED=false
    else
        log "WARN" "DNSCrypt установлен, но есть проблемы с работой службы"
        
        # Запускаем расширенную диагностику, если доступна функция
        if type diagnose_dns_issues &>/dev/null; then
            log "INFO" "Запуск расширенной диагностики..."
            diagnose_dns_issues
        fi
        
        # Спрашиваем пользователя, нужно ли откатить изменения
        read -p "Обнаружены проблемы с работой DNSCrypt. Хотите откатить установку? (y/n): " rollback_choice
        if [[ "${rollback_choice,,}" == "y" ]]; then
            log "INFO" "Откат установки по запросу пользователя"
            rollback_changes
            return 1
        else
            log "WARN" "Пользователь решил продолжить несмотря на проблемы"
            # Очищаем временные файлы для отката
            rm -rf "${TEMP_BACKUP_DIR}"
            ROLLBACK_NEEDED=false
        fi
    fi
    
    # Информация о текущих настройках
    print_header "ИНФОРМАЦИЯ ОБ УСТАНОВКЕ"
    
    log "INFO" "Версия DNSCrypt-proxy: $("$INSTALL_DIR/dnscrypt-proxy" -version)"
    
    # Проверка текущих настроек
    if type check_current_settings &>/dev/null; then
        check_current_settings
    else
        log "INFO" "DNSCrypt-proxy установлен в $INSTALL_DIR"
        log "INFO" "Конфигурационный файл: $CONFIG_FILE"
        log "INFO" "Служба: $SERVICE_NAME"
    fi
    
    # Финал
    print_header "УСТАНОВКА ЗАВЕРШЕНА"
    echo -e "\n${GREEN}Установка DNSCrypt-proxy завершена успешно!${NC}"
    echo -e "Для проверки выполните: ${YELLOW}dig @127.0.0.1 google.com${NC}"
    echo -e "Для управления и дополнительной настройки используйте DNSCrypt Manager\n"

    # Проверка наличия потенциальных проблем
    if systemctl is-active --quiet systemd-resolved; then
        echo -e "${YELLOW}ВНИМАНИЕ:${NC} systemd-resolved всё еще активен, что может вызвать конфликты"
        echo -e "Рекомендуется выполнить: ${CYAN}sudo systemctl disable --now systemd-resolved${NC}\n"
    fi

    echo -e "После установки рекомендуется перезагрузить систему:"
    echo -e "${CYAN}sudo reboot${NC}\n"
    
    return 0
}

# Перехват сигналов для выполнения отката при прерывании
trap 'echo ""; log "WARN" "Установка прервана. Выполняем откат изменений..."; rollback_changes; exit 1' INT TERM

# Вызов главной функции
if ! install_dnscrypt; then
    log "ERROR" "Установка DNSCrypt завершилась с ошибками"
    exit 1
fi

exit 0