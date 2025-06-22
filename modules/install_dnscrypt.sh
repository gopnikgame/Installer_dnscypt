#!/bin/bash

# Цветовые коды
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Константы
DNSCRYPT_CONFIG_DIR="/etc/dnscrypt-proxy"
DNSCRYPT_CONFIG="${DNSCRYPT_CONFIG_DIR}/dnscrypt-proxy.toml"
DNSCRYPT_USER="_dnscrypt-proxy"

# Функция логирования
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "$timestamp [$1] $2"
}

# Определение дистрибутива
detect_distro() {
    if [ -f /etc/debian_version ]; then
        if [ -f /etc/lsb-release ]; then
            . /etc/lsb-release
            if [ "${DISTRIB_ID}" = "Ubuntu" ]; then
                echo "ubuntu"
                return 0
            fi
        fi
        echo "debian"
        return 0
    fi
    
    log "ERROR" "${RED}Не поддерживаемый дистрибутив. Скрипт работает только на Debian и Ubuntu.${NC}"
    return 1
}

# Определение версии дистрибутива
get_debian_version() {
    if [ -f /etc/debian_version ]; then
        local version=$(cat /etc/debian_version | cut -d'.' -f1)
        if [ "$version" -ge 12 ]; then
            echo "bookworm"
        elif [ "$version" -ge 11 ]; then
            echo "bullseye"
        else
            echo "testing"
        fi
    else
        echo "testing"
    fi
}

# Установка DNSCrypt через apt
install_via_apt() {
    local distro=$(detect_distro)
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    log "INFO" "Установка DNSCrypt-proxy через пакетный менеджер..."
    
    if [ "$distro" = "ubuntu" ]; then
        log "INFO" "Обновление списка пакетов..."
        apt update
        
        log "INFO" "Установка DNSCrypt-proxy..."
        apt install -y dnscrypt-proxy
        
        if [ $? -ne 0 ]; then
            log "ERROR" "${RED}Ошибка при установке пакета dnscrypt-proxy${NC}"
            return 1
        fi
    elif [ "$distro" = "debian" ]; then
        local debian_version=$(get_debian_version)
        
        log "INFO" "Обновление списка пакетов..."
        apt update
        
        if [ "$debian_version" = "testing" ]; then
            log "INFO" "Установка DNSCrypt-proxy из репозитория testing..."
            apt install -y -t testing dnscrypt-proxy
        else
            log "INFO" "Установка DNSCrypt-proxy из стандартного репозитория..."
            apt install -y dnscrypt-proxy
        fi
        
        if [ $? -ne 0 ]; then
            log "ERROR" "${RED}Ошибка при установке пакета dnscrypt-proxy${NC}"
            return 1
        fi
    fi
    
    log "SUCCESS" "${GREEN}DNSCrypt-proxy успешно установлен через пакетный менеджер${NC}"
    return 0
}

# Настройка DNSCrypt
configure_dnscrypt() {
    log "INFO" "Настройка DNSCrypt-proxy..."
    
    # Остановка и удаление предыдущих сервисов
    if command -v dnscrypt-proxy &>/dev/null; then
        log "INFO" "Остановка предыдущего сервиса DNSCrypt (если запущен)..."
        dnscrypt-proxy -service stop 2>/dev/null || true
        dnscrypt-proxy -service uninstall 2>/dev/null || true
    fi
    
    # Создание директории конфигурации
    mkdir -p "${DNSCRYPT_CONFIG_DIR}"
    
    # Копирование примеров конфигурации
    if [ -d "/usr/share/doc/dnscrypt-proxy/examples" ]; then
        log "INFO" "Копирование примеров конфигурации..."
        cp -r /usr/share/doc/dnscrypt-proxy/examples/* "${DNSCRYPT_CONFIG_DIR}/" 2>/dev/null || true
    elif [ -d "/usr/share/doc/dnscrypt-proxy" ]; then
        # На некоторых системах примеры могут быть в другом месте или сжаты
        log "INFO" "Поиск примеров конфигурации..."
        if [ -f "/usr/share/doc/dnscrypt-proxy/examples.tar.gz" ]; then
            tar -xzf /usr/share/doc/dnscrypt-proxy/examples.tar.gz -C "${DNSCRYPT_CONFIG_DIR}/"
        elif [ -f "/usr/share/doc/dnscrypt-proxy/examples.tar.xz" ]; then
            tar -xJf /usr/share/doc/dnscrypt-proxy/examples.tar.xz -C "${DNSCRYPT_CONFIG_DIR}/"
        fi
    fi
    
    # Копирование примера конфигурации как основного файла
    if [ -f "${DNSCRYPT_CONFIG_DIR}/example-dnscrypt-proxy.toml" ]; then
        log "INFO" "Настройка файла конфигурации..."
        cp "${DNSCRYPT_CONFIG_DIR}/example-dnscrypt-proxy.toml" "${DNSCRYPT_CONFIG}"
        log "SUCCESS" "${GREEN}Файл конфигурации успешно настроен${NC}"
    else
        log "WARNING" "${YELLOW}Не найден пример файла конфигурации${NC}"
        
        # Создание базового файла конфигурации
        cat > "${DNSCRYPT_CONFIG}" << EOL
# Основная конфигурация DNSCrypt-proxy
server_names = ['cloudflare', 'google']
listen_addresses = ['127.0.0.1:53']
max_clients = 250
user_name = '${DNSCRYPT_USER}'
ipv4_servers = true
ipv6_servers = true
dnscrypt_servers = true
doh_servers = true
require_dnssec = true
require_nolog = true
require_nofilter = true
force_tcp = false
timeout = 2500
keepalive = 30
cert_refresh_delay = 240
bootstrap_resolvers = ['1.1.1.1:53', '8.8.8.8:53']
ignore_system_dns = true
netprobe_timeout = 30
cache = true
cache_size = 4096
cache_min_ttl = 600
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600
EOL
        log "INFO" "Создан базовый файл конфигурации"
    fi
    
    # Проверка конфигурации
    log "INFO" "Проверка конфигурации DNSCrypt-proxy..."
    pushd "${DNSCRYPT_CONFIG_DIR}" > /dev/null
    if dnscrypt-proxy -check; then
        log "SUCCESS" "${GREEN}Конфигурация успешно проверена${NC}"
    else
        log "ERROR" "${RED}Ошибка в конфигурации. Проверьте файл ${DNSCRYPT_CONFIG}${NC}"
        return 1
    fi
    popd > /dev/null
    
    return 0
}

# Установка системного сервиса
install_service() {
    log "INFO" "Установка системного сервиса DNSCrypt-proxy..."
    
    pushd "${DNSCRYPT_CONFIG_DIR}" > /dev/null
    
    # Установка сервиса
    if dnscrypt-proxy -service install; then
        log "SUCCESS" "${GREEN}Сервис DNSCrypt-proxy успешно установлен${NC}"
        
        # Запуск сервиса
        log "INFO" "Запуск сервиса DNSCrypt-proxy..."
        if dnscrypt-proxy -service start; then
            log "SUCCESS" "${GREEN}Сервис DNSCrypt-proxy успешно запущен${NC}"
        else
            log "ERROR" "${RED}Не удалось запустить сервис DNSCrypt-proxy${NC}"
            return 1
        fi
    else
        log "ERROR" "${RED}Не удалось установить сервис DNSCrypt-proxy${NC}"
        return 1
    fi
    
    popd > /dev/null
    return 0
}

# Настройка systemd-resolved
configure_systemd_resolved() {
    log "INFO" "Настройка systemd-resolved для использования DNSCrypt-proxy..."
    
    if [ ! -f "/etc/systemd/resolved.conf" ]; then
        log "ERROR" "${RED}Файл конфигурации systemd-resolved не найден${NC}"
        return 1
    fi
    
    # Создание резервной копии
    cp "/etc/systemd/resolved.conf" "/etc/systemd/resolved.conf.backup"
    
    # Поиск и замена строки DNS=
    if grep -q "^#DNS=" "/etc/systemd/resolved.conf"; then
        sed -i 's/^#DNS=.*/DNS=127.0.0.1/' "/etc/systemd/resolved.conf"
    elif grep -q "^DNS=" "/etc/systemd/resolved.conf"; then
        sed -i 's/^DNS=.*/DNS=127.0.0.1/' "/etc/systemd/resolved.conf"
    else
        # Если строка не найдена, добавляем её в секцию [Resolve]
        if grep -q "\[Resolve\]" "/etc/systemd/resolved.conf"; then
            sed -i '/\[Resolve\]/a DNS=127.0.0.1' "/etc/systemd/resolved.conf"
        else
            # Если секция [Resolve] отсутствует, добавляем её
            echo -e "\n[Resolve]\nDNS=127.0.0.1" >> "/etc/systemd/resolved.conf"
        fi
    fi
    
    # Перезапуск systemd-resolved
    log "INFO" "Перезапуск systemd-resolved..."
    if systemctl restart systemd-resolved; then
        log "SUCCESS" "${GREEN}systemd-resolved успешно настроен и перезапущен${NC}"
        return 0
    else
        log "ERROR" "${RED}Не удалось перезапустить systemd-resolved${NC}"
        return 1
    fi
}

# Проверка наличия и настройка dnsmasq (если установлен)
check_and_configure_dnsmasq() {
    if ! command -v dnsmasq &>/dev/null; then
        log "INFO" "dnsmasq не установлен, пропускаем..."
        return 0
    fi
    
    log "INFO" "Обнаружен dnsmasq, настраиваем его использование с DNSCrypt-proxy..."
    
    # Предлагаем пользователю выбрать опцию
    echo
    echo "dnsmasq обнаружен на вашей системе. Выберите опцию:"
    echo "1) Отключить dnsmasq (рекомендуется для большинства случаев)"
    echo "2) Настроить dnsmasq для работы с DNSCrypt-proxy"
    echo
    read -p "Выберите опцию [1/2]: " dnsmasq_option
    
    case $dnsmasq_option in
        1)
            log "INFO" "Отключение dnsmasq..."
            
            # Проверка на наличие NetworkManager.conf
            if [ -f "/etc/NetworkManager/NetworkManager.conf" ]; then
                # Создание резервной копии
                cp "/etc/NetworkManager/NetworkManager.conf" "/etc/NetworkManager/NetworkManager.conf.backup"
                
                # Отключение dnsmasq в NetworkManager
                if grep -q "dns=dnsmasq" "/etc/NetworkManager/NetworkManager.conf"; then
                    sed -i 's/dns=dnsmasq/#dns=dnsmasq/' "/etc/NetworkManager/NetworkManager.conf"
                    log "SUCCESS" "${GREEN}dnsmasq отключен в NetworkManager${NC}"
                fi
            fi
            
            # Остановка службы dnsmasq
            systemctl stop dnsmasq &>/dev/null || true
            systemctl disable dnsmasq &>/dev/null || true
            
            log "SUCCESS" "${GREEN}dnsmasq успешно отключен${NC}"
            ;;
            
        2)
            log "INFO" "Настройка dnsmasq для работы с DNSCrypt-proxy..."
            
            # Изменение порта DNSCrypt-proxy
            if [ -f "${DNSCRYPT_CONFIG}" ]; then
                # Резервная копия
                cp "${DNSCRYPT_CONFIG}" "${DNSCRYPT_CONFIG}.backup"
                
                # Изменение адреса прослушивания
                sed -i 's/listen_addresses = \[.*\]/listen_addresses = \['\''127.0.2.1:53'\''\]/' "${DNSCRYPT_CONFIG}"
                
                log "INFO" "DNSCrypt-proxy настроен на прослушивание адреса 127.0.2.1:53"
            fi
            
            # Создание конфигурации dnsmasq
            mkdir -p "/etc/dnsmasq.d"
            cat > "/etc/dnsmasq.d/dnscrypt-proxy" << EOF
# Перенаправление запросов на DNSCrypt-proxy
server=127.0.2.1
no-resolv
proxy-dnssec
EOF
            
            # Перезапуск служб
            log "INFO" "Перезапуск служб DNSCrypt-proxy и dnsmasq..."
            dnscrypt-proxy -service restart
            systemctl restart dnsmasq
            
            log "SUCCESS" "${GREEN}dnsmasq успешно настроен для работы с DNSCrypt-proxy${NC}"
            ;;
            
        *)
            log "ERROR" "${RED}Неверный выбор, пропускаем настройку dnsmasq${NC}"
            return 1
            ;;
    esac
    
    return 0
}

# Настройка автоматического обновления
setup_auto_update() {
    log "INFO" "Настройка автоматического обновления DNSCrypt-proxy..."
    
    # Создание директории для установки (если используется другой метод)
    local install_dir="/opt/dnscrypt-proxy"
    mkdir -p "$install_dir"
    
    # Проверка, установлен ли DNSCrypt в этой директории
    if [ ! -x "$install_dir/dnscrypt-proxy" ] && [ -x "$DNSCRYPT_BIN_PATH" ]; then
        log "INFO" "Копирование DNSCrypt-proxy в директорию для автообновления..."
        cp "$DNSCRYPT_BIN_PATH" "$install_dir/"
        chmod +x "$install_dir/dnscrypt-proxy"
    fi
    
    # Создание скрипта обновления
    local update_script="/usr/local/bin/dnscrypt-proxy-update.sh"
    
    cat > "$update_script" << 'EOL'
#! /bin/sh

INSTALL_DIR="/opt/dnscrypt-proxy"
LATEST_URL="https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest"
DNSCRYPT_PUBLIC_KEY="RWTk1xXqcTODeYttYMCMLo0YJHaFEHn7a3akqHlb/7QvIQXHVPxKbjB5"
PLATFORM="linux"
CPU_ARCH="x86_64"

# Определение архитектуры системы
detect_cpu_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
            CPU_ARCH="x86_64"
            ;;
        i*86)
            CPU_ARCH="i386"
            ;;
        aarch64)
            CPU_ARCH="arm64"
            ;;
        armv7*)
            CPU_ARCH="arm"
            ;;
        *)
            echo "[WARN] Неизвестная архитектура: $arch, используется x86_64 по умолчанию"
            ;;
    esac
    echo "[INFO] Определена архитектура: $CPU_ARCH"
}

Update() {
  workdir="$(mktemp -d)"
  download_url="$(curl -sL "$LATEST_URL" | grep dnscrypt-proxy-${PLATFORM}_${CPU_ARCH}- | grep browser_download_url | head -1 | cut -d \" -f 4)"
  echo "[INFO] Downloading update from '$download_url'..."
  download_file="dnscrypt-proxy-update.tar.gz"
  curl --request GET -sL --url "$download_url" --output "$workdir/$download_file"
  response=$?

  if [ $response -ne 0 ]; then
    echo "[ERROR] Could not download file from '$download_url'" >&2
    rm -Rf "$workdir"
    return 1
  fi

  if [ -x "$(command -v minisign)" ]; then
    curl --request GET -sL --url "${download_url}.minisig" --output "$workdir/${download_file}.minisig"
    minisign -Vm "$workdir/$download_file" -P "$DNSCRYPT_PUBLIC_KEY"
    valid_file=$?

    if [ $valid_file -ne 0 ]; then
      echo "[ERROR] Downloaded file has failed signature verification. Update aborted." >&2
      rm -Rf "$workdir"
      return 1
    fi
  else
    echo '[WARN] minisign is not installed, downloaded file signature could not be verified.'
  fi

  echo '[INFO] Initiating update of DNSCrypt-proxy'

  tar xz -C "$workdir" -f "$workdir/$download_file" ${PLATFORM}-${CPU_ARCH}/dnscrypt-proxy &&
    mv -f "${INSTALL_DIR}/dnscrypt-proxy" "${INSTALL_DIR}/dnscrypt-proxy.old" &&
    mv -f "${workdir}/${PLATFORM}-${CPU_ARCH}/dnscrypt-proxy" "${INSTALL_DIR}/" &&
    chmod u+x "${INSTALL_DIR}/dnscrypt-proxy" &&
    cd "$INSTALL_DIR" &&
    ./dnscrypt-proxy -check && ./dnscrypt-proxy -service install 2>/dev/null || : &&
    ./dnscrypt-proxy -service restart || ./dnscrypt-proxy -service start

  updated_successfully=$?

  rm -Rf "$workdir"
  if [ $updated_successfully -eq 0 ]; then
    echo '[INFO] DNSCrypt-proxy has been successfully updated!'
    return 0
  else
    echo '[ERROR] Unable to complete DNSCrypt-proxy update. Update has been aborted.' >&2
    return 1
  fi
}

# Определение архитектуры системы
detect_cpu_arch

if [ ! -f "${INSTALL_DIR}/dnscrypt-proxy" ]; then
  echo "[ERROR] DNSCrypt-proxy is not installed in '${INSTALL_DIR}/dnscrypt-proxy'. Update aborted..." >&2
  exit 1
fi

local_version=$("${INSTALL_DIR}/dnscrypt-proxy" -version)
remote_version=$(curl -sL "$LATEST_URL" | grep "tag_name" | head -1 | cut -d \" -f 4)

if [ -z "$local_version" ] || [ -z "$remote_version" ]; then
  echo "[ERROR] Could not retrieve DNSCrypt-proxy version. Update aborted... " >&2
  exit 1
else
  echo "[INFO] local_version=$local_version, remote_version=$remote_version"
fi

if [ "$local_version" != "$remote_version" ]; then
  echo "[INFO] local_version not synced with remote_version, initiating update..."
  Update
  exit $?
else
  echo "[INFO] No updated needed."
  exit 0
fi
EOL

    # Установка прав доступа и проверка скрипта
    chmod +x "$update_script"
    
    log "INFO" "Создание задания cron для автоматического обновления..."
    
    # Создание временного cron-файла
    local temp_cron=$(mktemp)
    
    # Получение текущего crontab
    crontab -l > "$temp_cron" 2>/dev/null || echo "" > "$temp_cron"
    
    # Проверка, существует ли уже задание
    if ! grep -q "dnscrypt-proxy-update.sh" "$temp_cron"; then
        # Добавление задания (каждые 12 часов)
        echo "0 */12 * * * $update_script >> /var/log/dnscrypt-update.log 2>&1" >> "$temp_cron"
        
        # Установка нового crontab
        crontab "$temp_cron"
        log "SUCCESS" "${GREEN}Задание cron для автоматического обновления успешно добавлено${NC}"
    else
        log "INFO" "Задание cron для автоматического обновления уже существует"
    fi
    
    # Удаление временного файла
    rm -f "$temp_cron"
    
    # Опционально: предложение установить minisign
    if ! command -v minisign &>/dev/null; then
        log "INFO" "Для проверки подписи обновлений рекомендуется установить minisign:"
        
        local distro=$(detect_distro)
        if [ "$distro" = "ubuntu" ] || [ "$distro" = "debian" ]; then
            log "INFO" "sudo apt install -y minisign"
        else
            log "INFO" "Установите minisign согласно документации вашего дистрибутива"
        fi
    else
        log "SUCCESS" "${GREEN}minisign уже установлен для проверки подписей${NC}"
    fi
    
    # Запуск скрипта обновления для проверки
    log "INFO" "Проверка работы скрипта обновления..."
    $update_script
    
    log "SUCCESS" "${GREEN}Автоматическое обновление DNSCrypt-proxy настроено${NC}"
    return 0
}

# Проверка работы DNSCrypt
test_dnscrypt() {
    log "INFO" "Проверка работы DNSCrypt-proxy..."
    
    # Даем немного времени для запуска сервиса
    sleep 2
    
    pushd "${DNSCRYPT_CONFIG_DIR}" > /dev/null
    
    # Тест резолвинга
    if dnscrypt-proxy -resolve example.com; then
        log "SUCCESS" "${GREEN}DNSCrypt-proxy успешно разрешает имена${NC}"
        
        # Проверка доступных резолверов
        log "INFO" "Список доступных резолверов:"
        dnscrypt-proxy -list
        
        popd > /dev/null
        return 0
    else
        log "ERROR" "${RED}DNSCrypt-proxy не может разрешать имена${NC}"
        
        # Проверка статуса службы
        log "INFO" "Статус службы DNSCrypt-proxy:"
        systemctl status dnscrypt-proxy
        
        popd > /dev/null
        return 1
    fi
}

# Главная функция установки DNSCrypt
install_dnscrypt() {
    log "INFO" "${BLUE}Начало установки DNSCrypt-proxy...${NC}"
    
    # Проверка root прав
    if [ "$EUID" -ne 0 ]; then
        log "ERROR" "${RED}Этот скрипт должен быть запущен с правами root${NC}"
        return 1
    fi
    
    # Установка через apt
    if ! install_via_apt; then
        log "ERROR" "${RED}Не удалось установить DNSCrypt-proxy через apt${NC}"
        return 1
    fi
    
    # Настройка DNSCrypt
    if ! configure_dnscrypt; then
        log "ERROR" "${RED}Не удалось настроить DNSCrypt-proxy${NC}"
        return 1
    fi
    
    # Установка системного сервиса
    if ! install_service; then
        log "ERROR" "${RED}Не удалось установить системный сервис DNSCrypt-proxy${NC}"
        return 1
    fi
    
    # Настройка systemd-resolved
    if command -v systemctl &>/dev/null && systemctl is-active systemd-resolved >/dev/null 2>&1; then
        if ! configure_systemd_resolved; then
            log "WARNING" "${YELLOW}Не удалось настроить systemd-resolved${NC}"
        fi
    else
        log "INFO" "systemd-resolved не активен, пропускаем настройку"
    fi
    
    # Проверка и настройка dnsmasq
    check_and_configure_dnsmasq
    
    # Настройка автоматического обновления
    setup_auto_update
    
    # Тестирование установки
    if test_dnscrypt; then
        log "SUCCESS" "${GREEN}DNSCrypt-proxy успешно установлен и настроен!${NC}"
    else
        log "WARNING" "${YELLOW}DNSCrypt-proxy установлен, но есть проблемы с его работой${NC}"
    fi
    
    log "INFO" "Для проверки локального DNS: dig @127.0.0.1 example.com"
    log "INFO" "Для перезапуска DNSCrypt-proxy: sudo dnscrypt-proxy -service restart"
    log "INFO" "Для ручного запуска обновления: sudo /usr/local/bin/dnscrypt-proxy-update.sh"
    
    return 0
}

# Запуск установки
install_dnscrypt