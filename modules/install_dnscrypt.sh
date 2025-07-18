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
elif [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "armv8" ]; then
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
                    # Не ставим атрибут +i обратно, так как система может им управлять
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
    log "INFO" "Получение информации о последней версии через API GitHub"
    
    # Проверяем наличие jq
    if ! command -v jq &> /dev/null; then
        log "INFO" "Утилита jq не найдена, попытка установки..."
        install_package "jq" || log "WARN" "Не удалось установить jq. Возвращаемся к старому методу."
    fi

    if command -v jq &> /dev/null; then
        download_url=$(curl -sL "$LATEST_URL" | jq -r ".assets[] | select(.name | test(\"dnscrypt-proxy-${PLATFORM}_${CPU_ARCH}.*tar.gz$\")) | .browser_download_url" | head -n 1)
    else
        download_url="$(curl -sL "$LATEST_URL" | grep "dnscrypt-proxy-${PLATFORM}_${CPU_ARCH}-" | grep "browser_download_url" | head -1 | cut -d \" -f 4)"
    fi
    
    if [ -z "$download_url" ]; then
        log "WARN" "Не удалось получить URL через API. Попытка загрузки резервной версии."
        
        local fallback_version="2.1.12"
        local fallback_base_url="https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${fallback_version}"
        local fallback_file="dnscrypt-proxy-${PLATFORM}_${CPU_ARCH}-${fallback_version}.tar.gz"
        
        download_url="${fallback_base_url}/${fallback_file}"
        
        log "INFO" "Используем резервный URL: $download_url"
        
        # Проверяем доступность резервного URL
        if ! curl -s --head "$download_url" | head -n 1 | grep -E "HTTP/(1.1|2) 302" > /dev/null; then
            log "ERROR" "Резервный URL также недоступен. Не удалось получить URL для загрузки DNSCrypt-proxy."
            rm -rf "$workdir"
            return 1
        fi
        remote_version=$fallback_version
    else
        # Получаем версию
        remote_version=$(curl -sL "$LATEST_URL" | grep "tag_name" | head -1 | cut -d \" -f 4)
    fi

    log "INFO" "Найдена версия DNSCrypt-proxy: $remote_version"
    
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
        local minisig_url="${download_url}.minisig"
        if ! curl --request GET -sL --url "$minisig_url" --output "$workdir/${download_file}.minisig"; then
            log "WARN" "Не удалось загрузить файл подписи с ${minisig_url}"
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
    
    # Вместо возврата пути через echo, сохраняем в глобальной переменной
    DOWNLOADED_ARCHIVE_PATH="$workdir/$download_file"
    return 0
}

# Установка DNSCrypt-proxy из архива
install_from_archive() {
    local archive_file="$1"
    log "INFO" "Установка DNSCrypt-proxy из архива $archive_file"
    
    # Проверка существования архива
    if [ ! -f "$archive_file" ]; then
        log "ERROR" "Архив не найден: $archive_file"
        return 1
    fi
    
    # Создаем директорию для установки
    mkdir -p "$INSTALL_DIR"
    
    # Создаем временную директорию для распаковки
    local extract_dir="$(mktemp -d)"
    
    # Распаковываем архив
    log "INFO" "Распаковка архива $archive_file"
    if ! tar -xzf "$archive_file" -C "$extract_dir"; then
        log "ERROR" "Ошибка распаковки архива $archive_file"
        rm -rf "$extract_dir"
        return 1
    fi
    
    # Проверяем содержимое архива
    if [ ! -f "$extract_dir/${PLATFORM}-${CPU_ARCH}/dnscrypt-proxy" ]; then
        log "ERROR" "Архив не содержит ожидаемого файла dnscrypt-proxy для $PLATFORM-$CPU_ARCH"
        ls -la "$extract_dir" # Показываем содержимое для диагностики
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
        else
            log "WARN" "Пример конфигурации не найден в архиве"
        fi
    fi
    
    # Устанавливаем права на исполнение
    chmod +x "$INSTALL_DIR/dnscrypt-proxy"
    
    # Очистка
    rm -rf "$extract_dir"
    
    # Проверяем успешность установки
    if [ ! -x "$INSTALL_DIR/dnscrypt-proxy" ]; then
        log "ERROR" "DNSCrypt-proxy не был корректно установлен"
        return 1
    fi
    
    log "SUCCESS" "DNSCrypt-proxy установлен в $INSTALL_DIR"
    return 0
}

# Установка через пакетный менеджер
install_from_package_manager() {
    log "INFO" "Попытка установки dnscrypt-proxy через пакетный менеджер (apt)"
    
    if ! command -v apt-get &>/dev/null; then
        log "ERROR" "apt не найден. Установка через пакетный менеджер невозможна."
        return 1
    fi
    
    if ! apt-get install -y dnscrypt-proxy; then
        log "ERROR" "Не удалось установить dnscrypt-proxy через apt."
        return 1
    fi
    
    # Определяем, куда был установлен бинарный файл
    local installed_path=$(command -v dnscrypt-proxy)
    if [ -z "$installed_path" ]; then
        log "ERROR" "Не удалось найти бинарный файл dnscrypt-proxy после установки."
        return 1
    fi
    
    # Адаптируем переменные для дальнейшей настройки
    # Вместо копирования в /opt, мы будем использовать путь из apt
    local real_install_dir=$(dirname "$installed_path")
    # Создаем символическую ссылку для совместимости с остальной частью скрипта
    if [ "$real_install_dir" != "$INSTALL_DIR" ]; then
        ln -sfn "$real_install_dir" "$INSTALL_DIR"
    fi
    
    # Проверяем, что конфигурационная директория существует
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
    fi
    
    log "SUCCESS" "dnscrypt-proxy успешно установлен через apt."
    log "INFO" "Путь установки: $real_install_dir"
    
    # Устанавливаем флаг, что установка была из пакета
    INSTALL_FROM_PACKAGE=true
    
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
    
    # Создаем файл службы с правильными capabilities
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=DNSCrypt client proxy
Documentation=https://github.com/DNSCrypt/dnscrypt-proxy/wiki
After=network.target
Before=nss-lookup.target
Wants=network-online.target

[Service]
ExecStart=$INSTALL_DIR/dnscrypt-proxy -config $CONFIG_FILE
Type=simple
User=$DNSCRYPT_USER
Group=$DNSCRYPT_GROUP
Restart=on-failure
RestartSec=10

# Capabilities для привязки к порту 53
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETGID CAP_SETUID CAP_DAC_OVERRIDE
NoNewPrivileges=false

# Безопасность
MemoryDenyWriteExecute=true
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

# Проверка и установка необходимых capabilities
setup_capabilities() {
    log "INFO" "Настройка capabilities для DNSCrypt-proxy"
    
    # Проверяем, поддерживает ли система capabilities
    if ! command -v setcap &>/dev/null; then
        log "WARN" "Утилита setcap не найдена, устанавливаем..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y libcap2-bin
        elif command -v yum &>/dev/null; then
            yum install -y libcap
        elif command -v dnf &>/dev/null; then
            dnf install -y libcap
        else
            log "WARN" "Не удалось установить пакет capabilities"
        fi
    fi
    
    # Устанавливаем capability для привязки к привилегированным портам
    if command -v setcap &>/dev/null; then
        log "INFO" "Установка capability CAP_NET_BIND_SERVICE для dnscrypt-proxy"
        if setcap 'cap_net_bind_service=+ep' "$INSTALL_DIR/dnscrypt-proxy"; then
            log "SUCCESS" "Capability CAP_NET_BIND_SERVICE установлен"
        else
            log "WARN" "Не удалось установить capability, будем полагаться на systemd"
        fi
    fi
    
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
        "dns64"              # DNS64 (новый параметр, может быть несовместим)
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
    
    # Комментирование проблемных DNS64 настроек
    if grep -q -E "^\[dns64\]" "${CONFIG_FILE}.tmp"; then
        log "INFO" "Комментирование секции dns64"
        sed -i '/^\[dns64\]/,/^\[/s/^/#/' "${CONFIG_FILE}.tmp"
    fi
    
    # Перемещаем временный файл в основной
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    # Установка прав доступа (ИСПРАВЛЕННАЯ)
    chmod 644 "$CONFIG_FILE"
    chmod 755 "$CONFIG_DIR"
    
    # Устанавливаем владельца и права для пользователя dnscrypt-proxy
    chown -R "${DNSCRYPT_USER}:${DNSCRYPT_GROUP}" "$CONFIG_DIR"
    chown "${DNSCRYPT_USER}:${DNSCRYPT_GROUP}" "$CONFIG_FILE"
    
    # Убеждаемся, что директория установки доступна для чтения
    chmod 755 "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR/dnscrypt-proxy"
    
    # Проверка конфигурации
    log "INFO" "Проверка конфигурации"
    if ! "$INSTALL_DIR/dnscrypt-proxy" -check -config="$CONFIG_FILE"; then
        log "ERROR" "Ошибка в конфигурации. Попытка исправления..."
        
        # Резервное копирование проблемной конфигурации
        cp "$CONFIG_FILE" "${CONFIG_FILE}.error"
        
        # Использование минимальной конфигурации (исправленной)
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
force_tcp = false
timeout = 5000
keepalive = 30
cert_refresh_delay = 240
bootstrap_resolvers = ['9.9.9.11:53', '8.8.8.8:53']
ignore_system_dns = true
netprobe_timeout = 60
netprobe_address = '9.9.9.9:53'

# Cache settings
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
        
        # Устанавливаем правильные права доступа для минимальной конфигурации
        chmod 644 "$CONFIG_FILE"
        chown "${DNSCRYPT_USER}:${DNSCRYPT_GROUP}" "$CONFIG_FILE"
        
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
    if ! systemctl list-unit-files | grep -q systemd-resolved; then
        log "INFO" "systemd-resolved не установлен, пропускаем настройку"
        return 0
    fi
    
    # Если systemd-resolved уже отключен, пропускаем
    if ! systemctl is-enabled systemd-resolved &>/dev/null; then
        log "INFO" "systemd-resolved уже отключен"
        return 0
    fi
    
    log "INFO" "Отключение systemd-resolved для освобождения порта 53"
    
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
    
    # Останавливаем и отключаем systemd-resolved
    systemctl stop systemd-resolved.service 2>/dev/null || true
    systemctl disable systemd-resolved.service 2>/dev/null || true
    
    # Убираем символические ссылки
    rm -f /etc/resolv.conf
    
    log "SUCCESS" "systemd-resolved успешно отключен"
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
    
    # Проверяем, занят ли порт, предпочитая ss, если доступен
    if command -v ss &>/dev/null; then
        if ss -tuln | grep -q ":53\s"; then
            port_busy=true
        fi
    elif command -v lsof &>/dev/null; then
        if lsof -i :53 >/dev/null 2>&1; then
            port_busy=true
        fi
    else
        log "WARN" "Команды lsof и ss не найдены, устанавливаем lsof..."
        if ! install_package "lsof"; then
            log "ERROR" "Не удалось установить lsof, пропускаем проверку портов"
            return 0 # Возвращаем успех, чтобы не прерывать установку
        fi
        if lsof -i :53 >/dev/null 2>&1; then
            port_busy=true
        fi
    fi
    
    if [ "$port_busy" = true ]; then
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
        
        # Показываем процессы, использующие порт 53
        log "INFO" "Процессы, использующие порт 53:"
        lsof -i :53 | grep -v "^COMMAND" | tee /tmp/port53_processes.txt
        
        # Определяем процесс, занимающий порт
        local process_info=$(head -1 /tmp/port53_processes.txt)
        local process=$(echo "$process_info" | awk '{print $1}')
        local process_pid=$(echo "$process_info" | awk '{print $2}')
        
        # Обработка известных служб DNS
        case "$process" in
            systemd-r*|systemd-resolve*)
                log "INFO" "Порт занят системной службой systemd-resolved"
                echo "systemd-resolved" >> "${TEMP_BACKUP_DIR}/stopped_services.txt"
                
                # Правильно останавливаем systemd-resolved
                log "INFO" "Останавливаем и отключаем systemd-resolved..."
                systemctl stop systemd-resolved.service 2>/dev/null || true
                systemctl disable systemd-resolved.service 2>/dev/null || true
                
                # Дополнительно убиваем процесс, если он все еще работает
                if [ -n "$process_pid" ]; then
                    kill -15 "$process_pid" 2>/dev/null || true
                    sleep 2
                    kill -9 "$process_pid" 2>/dev/null || true
                fi
                
                log "INFO" "systemd-resolved остановлен"
                ;;
            named|bind*)
                log "INFO" "Порт занят сервером BIND"
                echo "named bind9" >> "${TEMP_BACKUP_DIR}/stopped_services.txt"
                ROLLBACK_ACTIONS+=("restart_other_dns")
                
                log "INFO" "Остановка named/bind..."
                systemctl stop named bind9 2>/dev/null || {
                    log "WARN" "Не удалось остановить named/bind через systemctl"
                    if command -v service &>/dev/null; then
                        service named stop 2>/dev/null || service bind9 stop 2>/dev/null
                    fi
                }
                systemctl disable named bind9 2>/dev/null || true
                log "INFO" "named/bind остановлен и отключен"
                ;;
            dnsmasq)
                log "INFO" "Порт занят DNSMasq"
                echo "dnsmasq" >> "${TEMP_BACKUP_DIR}/stopped_services.txt"
                ROLLBACK_ACTIONS+=("restart_other_dns")
                
                log "INFO" "Остановка dnsmasq..."
                systemctl stop dnsmasq || {
                    log "WARN" "Не удалось остановить dnsmasq через systemctl"
                    if command -v service &>/dev/null; then
                        service dnsmasq stop 2>/dev/null
                    fi
                }
                systemctl disable dnsmasq || true
                log "INFO" "dnsmasq остановлен и отключен"
                ;;
            unbound)
                log "INFO" "Порт занят Unbound DNS"
                echo "unbound" >> "${TEMP_BACKUP_DIR}/stopped_services.txt"
                ROLLBACK_ACTIONS+=("restart_other_dns")
                
                log "INFO" "Остановка unbound..."
                systemctl stop unbound || {
                    log "WARN" "Не удалось остановить unbound через systemctl"
                    if command -v service &>/dev/null; then
                        service unbound stop 2>/dev/null
                    fi
                }
                systemctl disable unbound || true
                log "INFO" "unbound остановлен и отключен"
                ;;
            *)
                log "WARN" "Неизвестный процесс $process (PID: $process_pid) занимает порт 53"
                # Автоматически завершаем процесс для systemd-resolved
                if [[ "$process" == "systemd-r"* ]]; then
                    log "INFO" "Автоматическое завершение процесса systemd-resolved (PID: $process_pid)..."
                    systemctl stop systemd-resolved.service 2>/dev/null || true
                    systemctl disable systemd-resolved.service 2>/dev/null || true
                    kill -15 "$process_pid" 2>/dev/null || true
                    sleep 2
                    kill -9 "$process_pid" 2>/dev/null || true
                else
                    echo "$process (PID: $process_pid)" >> "${TEMP_BACKUP_DIR}/unknown_processes.txt"
                    
                    local kill_process="n"
                    # Спрашиваем пользователя, если терминал интерактивный
                    if [ -t 1 ]; then
                        read -p "Хотите завершить процесс $process (PID: $process_pid), занимающий порт 53? (y/n): " kill_process
                    else
                        log "WARN" "Неинтерактивный режим, процесс $process не будет завершен автоматически."
                    fi
                    
                    if [[ "${kill_process,,}" == "y" ]]; then
                        log "INFO" "Завершение процесса $process (PID: $process_pid)..."
                        kill -15 "$process_pid" || {
                            log "WARN" "Не удалось корректно завершить процесс, пробуем принудительно"
                            kill -9 "$process_pid" || log "ERROR" "Не удалось завершить процесс"
                        }
                    fi
                fi
                ;;
        esac
        
        # Проверяем, освободился ли порт
        sleep 3 # Даем больше времени на остановку процессов
        if lsof -i :53 >/dev/null 2>&1; then
            log "WARN" "Порт 53 всё ещё занят после попытки остановить службы"
            log "INFO" "Попытка принудительного освобождения порта..."
            
            # Получаем новый список процессов
            local remaining_pids=$(lsof -t -i :53 2>/dev/null)
            if [ -n "$remaining_pids" ]; then
                for pid in $remaining_pids; do
                    log "INFO" "Принудительное завершение процесса PID: $pid"
                    kill -9 "$pid" 2>/dev/null || true
                done
                sleep 2
            fi
            
            # Финальная проверка
            if lsof -i :53 >/dev/null 2>&1; then
                log "WARN" "Порт 53 всё ещё занят. Показываем оставшиеся процессы:"
                lsof -i :53
                return 1
            else
                log "SUCCESS" "Порт 53 успешно освобожден принудительно"
            fi
        else
            log "SUCCESS" "Порт 53 освобожден"
        fi
    else
        log "INFO" "Порт 53 свободен"
    fi
    
    # Очистка временных файлов
    rm -f /tmp/port53_processes.txt
    
    return 0
}

# Вспомогательная функция для установки пакетов
install_package() {
    local package="$1"
    
    if command -v apt-get &>/dev/null; then
        apt-get update && apt-get install -y "$package"
    elif command -v yum &>/dev/null; then
        yum install -y "$package"
    elif command -v dnf &>/dev/null; then
        dnf install -y "$package"
    else
        return 1
    fi
    return $?
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
    
    # Проверка доступности менеджера пакетов
    local pkg_manager=""
    if command -v apt-get &>/dev/null; then
        pkg_manager="apt"
        packages+=("dnsutils") # для dig
        packages+=("libcap2-bin") # для setcap
    elif command -v yum &>/dev/null; then
        pkg_manager="yum"
        packages+=("bind-utils") # для dig
        packages+=("libcap") # для setcap
    elif command -v dnf &>/dev/null; then
        pkg_manager="dnf"
        packages+=("bind-utils") # для dig
        packages+=("libcap") # для setcap
    else
        log "WARN" "Неизвестный менеджер пакетов, пропускаем установку зависимостей"
        return 1
    fi
    
    # Проверка наличия пакетов
    local missing_packages=()
    for pkg in "${packages[@]}"; do
        # Проверяем исполняемые файлы для некоторых пакетов
        local cmd_to_check="$pkg"
        case "$pkg" in
            "dnsutils"|"bind-utils") cmd_to_check="dig" ;;
            "libcap2-bin"|"libcap") cmd_to_check="setcap" ;;
            "ca-certificates") cmd_to_check="update-ca-certificates" ;;
        esac

        if ! command -v "$cmd_to_check" &>/dev/null; then
             # Для Debian/Ubuntu проверяем статус пакета, для других - просто добавляем
            if [ "$pkg_manager" = "apt" ]; then
                if ! dpkg -s "$pkg" &>/dev/null 2>&1; then
                    missing_packages+=("$pkg")
                fi
            else
                 missing_packages+=("$pkg")
            fi
        fi
    done
    
    # Установка отсутствующих пакетов
    if [ ${#missing_packages[@]} -gt 0 ]; then
        log "INFO" "Установка отсутствующих пакетов: ${missing_packages[*]}"
        
        case $pkg_manager in
            apt)
                apt-get update && apt-get install -y "${missing_packages[@]}" || {
                    log "WARN" "Не удалось установить все зависимости"
                    return 1
                }
                ;;
            yum|dnf)
                $pkg_manager install -y "${missing_packages[@]}" || {
                    log "WARN" "Не удалось установить все зависимости"
                    return 1
                }
                ;;
        esac
    else
        log "INFO" "Все необходимые пакеты уже установлены"
    fi
    
    # Устанавливаем minisign, если доступен
    if [ "$pkg_manager" = "apt" ]; then
        if apt-cache show minisign &>/dev/null; then
            if ! command -v minisign &>/dev/null; then
                log "INFO" "Установка minisign для проверки подписи"
                apt-get install -y minisign || log "WARN" "Не удалось установить minisign"
            fi
        fi
    elif [ "$pkg_manager" = "yum" ] || [ "$pkg_manager" = "dnf" ]; then
        # Проверка наличия EPEL для minisign
        if $pkg_manager list minisign &>/dev/null; then
            if ! command -v minisign &>/dev/null; then
                log "INFO" "Установка minisign для проверки подписи"
                $pkg_manager install -y minisign || log "WARN" "Не удалось установить minisign"
            fi
        fi
    fi
    
    log "SUCCESS" "Зависимости успешно установлены"
    return 0
}

# Главная функция установки
install_dnscrypt() {
    print_header "УСТАНОВКА DNSCRYPT-PROXY"
    
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
    
    # Очищаем глобальную переменную перед использованием
    DOWNLOADED_ARCHIVE_PATH=""
    INSTALL_FROM_PACKAGE=false

    # Загрузка последней версии
    if ! download_latest_release; then
        log "WARN" "Не удалось загрузить DNSCrypt-proxy из GitHub. Попытка установки из пакетного менеджера..."
        if ! install_from_package_manager; then
            log "ERROR" "Все способы установки не удались."
            rollback_changes
            return 1
        fi
    else
        # Проверка получения пути к архиву
        if [ -z "$DOWNLOADED_ARCHIVE_PATH" ] || [ ! -f "$DOWNLOADED_ARCHIVE_PATH" ]; then
            log "ERROR" "Не удалось получить доступ к загруженному архиву"
            rollback_changes
            return 1
        fi
        
        # Устанавливаем DNSCrypt из архива
        if ! install_from_archive "$DOWNLOADED_ARCHIVE_PATH"; then
            log "ERROR" "Ошибка установки DNSCrypt-proxy из архива"
            rollback_changes
            return 1
        fi
        
        # Добавляем действие отката
        ROLLBACK_NEEDED=true
        ROLLBACK_ACTIONS+=("remove_files")
        
        # Настройка capabilities (НОВАЯ ФУНКЦИЯ)
        setup_capabilities || {
            log "WARN" "Проблемы с настройкой capabilities, продолжаем..."
        }
    fi

    # Настройка конфигурации
    configure_dnscrypt || {
        log "ERROR" "Ошибка настройки конфигурации DNSCrypt"
        rollback_changes
        return 1
    }
    
    # Создание службы systemd (пропускаем, если установка была из пакета, т.к. он создает свою службу)
    if [ "$INSTALL_FROM_PACKAGE" = false ]; then
        create_service || {
            log "ERROR" "Ошибка создания службы systemd"
            rollback_changes
            return 1
        }
    else
        log "INFO" "Пропускаем создание службы systemd, так как установка была из пакета."
    fi
    
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
    
    # Запуск службы (ИСПРАВЛЕННАЯ СЕКЦИЯ)
    log "INFO" "Запуск службы DNSCrypt"
    systemctl enable dnscrypt-proxy || log "WARN" "Не удалось включить автозапуск службы"
    
    # Первая попытка запуска
    if ! systemctl start dnscrypt-proxy; then
        log "WARN" "Первая попытка запуска службы не удалась, проверяем причину..."
        
        # Проверяем логи для диагностики
        local error_logs=$(journalctl -u dnscrypt-proxy -n 5 --no-pager | grep -i "permission denied\|bind")
        
        if [[ -n "$error_logs" ]]; then
            log "INFO" "Обнаружена проблема с правами доступа, применяем дополнительные исправления..."
            
            # Дополнительные меры для решения проблем с правами
            
            # 1. Убеждаемся, что пользователь dnscrypt-proxy существует
            if ! id "$DNSCRYPT_USER" &>/dev/null; then
                log "ERROR" "Пользователь $DNSCRYPT_USER не существует"
                rollback_changes
                return 1
            fi
            
            # 2. Проверяем и исправляем права на файлы
            log "INFO" "Исправление прав доступа к файлам"
            chmod 755 "$INSTALL_DIR"
            chmod 755 "$INSTALL_DIR/dnscrypt-proxy"
            chmod 755 "$CONFIG_DIR"
            chmod 644 "$CONFIG_FILE"
            chown -R "${DNSCRYPT_USER}:${DNSCRYPT_GROUP}" "$CONFIG_DIR"
            
            # 3. Устанавливаем capabilities еще раз
            if command -v setcap &>/dev/null; then
                setcap 'cap_net_bind_service=+ep' "$INSTALL_DIR/dnscrypt-proxy" || {
                    log "WARN" "Не удалось установить capability"
                }
            fi
            
            # 4. Альтернативная служба с root правами в случае критической проблемы
            if systemctl status dnscrypt-proxy | grep -i "permission denied"; then
                log "WARN" "Создание альтернативной службы с root правами..."
                
                # Создаем временную службу с root правами
                cat > "$SERVICE_FILE" << EOF
[Unit]
Description=DNSCrypt client proxy (root fallback)
Documentation=https://github.com/DNSCrypt/dnscrypt-proxy/wiki
After=network.target
Before=nss-lookup.target
Wants=network-online.target

[Service]
ExecStart=$INSTALL_DIR/dnscrypt-proxy -config $CONFIG_FILE
Type=simple
User=root
Group=root
Restart=on-failure
RestartSec=10

# Минимальные ограничения безопасности
MemoryDenyWriteExecute=false
ProtectSystem=false
ReadWritePaths=$CONFIG_DIR

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                log "WARN" "Служба изменена для работы с root правами (временное решение)"
            fi
            
            # Вторая попытка запуска после исправлений
            systemctl daemon-reload
            sleep 2
            
            if ! systemctl start dnscrypt-proxy; then
                log "ERROR" "Не удалось запустить службу DNSCrypt после применения исправлений"
                log "INFO" "Детальная информация об ошибке:"
                journalctl -u dnscrypt-proxy -n 10 --no-pager
                
                # Предложение альтернативного порта
                log "INFO" "Попытка настройки на альтернативном порту 5353..."
                
                # Изменяем конфигурацию на непривилегированный порт
                sed -i "s/listen_addresses = \['127.0.0.1:53'\]/listen_addresses = ['127.0.0.1:5353']/" "$CONFIG_FILE"
                
                # Обновляем resolv.conf для работы с портом 5353
                chattr -i /etc/resolv.conf 2>/dev/null || true
                cat > /etc/resolv.conf << EOF
# Generated by DNSCrypt Manager (port 5353)
nameserver 127.0.0.1
# port 5353 - 'port' is not a standard option, resolver should handle it
options edns0
EOF
                chattr +i /etc/resolv.conf 2>/dev/null || true
                
                # Третья попытка с альтернативным портом
                if systemctl restart dnscrypt-proxy; then
                    log "SUCCESS" "DNSCrypt запущен на порту 5353"
                    safe_echo "${YELLOW}ВНИМАНИЕ: DNSCrypt работает на порту 5353 вместо стандартного 53${NC}"
                    safe_echo "Это решение проблемы с правами доступа."
                else
                    log "ERROR" "Не удалось запустить службу даже на альтернативном порту"
                    rollback_changes
                    return 1
                fi
            else
                log "SUCCESS" "Служба DNSCrypt запущена после применения исправлений"
            fi
        else
            log "ERROR" "Неизвестная ошибка запуска службы DNSCrypt"
            log "INFO" "Проверка логов службы:"
            journalctl -u dnscrypt-proxy -n 15 --no-pager
            rollback_changes
            return 1
        fi
    else
        log "SUCCESS" "Служба DNSCrypt запущена с первой попытки"
    fi
    
    # Проверка работы с использованием verify_settings из common.sh
    log "INFO" "Проверка правильности работы DNSCrypt..."
    sleep 5 # Даем время на инициализацию
    
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
    safe_echo "\n${GREEN}Установка DNSCrypt-proxy завершена успешно!${NC}"
    safe_echo "Для проверки выполните: ${YELLOW}dig @127.0.0.1 google.com${NC}"
    safe_echo "Для управления и дополнительной настройки используйте DNSCrypt Manager\n"

    # Проверка наличия потенциальных проблем
    if systemctl is-active --quiet systemd-resolved; then
        safe_echo "${YELLOW}ВНИМАНИЕ:${NC} systemd-resolved всё еще активен, что может вызвать конфликты"
        safe_echo "Рекомендуется выполнить: ${CYAN}sudo systemctl disable --now systemd-resolved${NC}\n"
    fi

    # Проверка порта
    local current_port=$(grep "listen_addresses" "$CONFIG_FILE" | grep -o ":[0-9]*" | tr -d ':')
    if [ "$current_port" != "53" ]; then
        safe_echo "${YELLOW}ВНИМАНИЕ:${NC} DNSCrypt работает на порту $current_port вместо стандартного 53"
        safe_echo "Это нормально для решения проблем с правами доступа.\n"
    fi

    safe_echo "После установки рекомендуется перезагрузить систему:"
    safe_echo "${CYAN}sudo reboot${NC}\n"
    
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