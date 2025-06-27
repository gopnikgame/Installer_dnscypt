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
# Полная установка DNSCrypt-proxy с автоматической настройкой для Debian/Ubuntu.
# Поддерживает только системы на базе Debian и Ubuntu.

# Константы
DNSCRYPT_USER="_dnscrypt-proxy"
CONFIG_DIR="/etc/dnscrypt-proxy"
CONFIG_FILE="${CONFIG_DIR}/dnscrypt-proxy.toml"
SERVICE_NAME="dnscrypt-proxy"
EXAMPLE_CONFIG_URL="https://raw.githubusercontent.com/DNSCrypt/dnscrypt-proxy/master/dnscrypt-proxy/example-dnscrypt-proxy.toml"

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
                
            "uninstall_package")
                log "INFO" "Удаление пакета dnscrypt-proxy"
                apt-get purge -y dnscrypt-proxy || log "WARN" "Не удалось удалить пакет dnscrypt-proxy"
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

# Определение дистрибутива
detect_distro() {
    if [[ -f /etc/debian_version ]]; then
        echo "debian"
    else
        log "ERROR" "Неподдерживаемый дистрибутив Linux. Скрипт работает только с Debian/Ubuntu."
        return 1
    fi
}

# Установка для Debian/Ubuntu
install_debian() {
    log "INFO" "Установка для Debian/Ubuntu"
    
    if ! apt-get update; then
        log "ERROR" "Ошибка обновления списка пакетов"
        return 1
    fi
    
    if ! apt-get install -y dnscrypt-proxy; then
        log "ERROR" "Ошибка установки пакета dnscrypt-proxy"
        return 1
    fi
    
    # Добавляем действие отката
    ROLLBACK_NEEDED=true
    ROLLBACK_ACTIONS+=("uninstall_package")
    
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
    
    if ! wget -q -O "$CONFIG_FILE" "$PRECONFIGURED_CONFIG_URL"; then
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
        
        # Перемещаем временный файл в основной
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    else
        log "SUCCESS" "Предварительно настроенный конфигурационный файл успешно загружен"
    fi
    
    # Установка прав на директорию
    chmod 755 "$CONFIG_DIR" || {
        log "WARN" "Не удалось изменить права доступа для директории $CONFIG_DIR"
    }
    
    # Установка прав на файл конфигурации
    chmod 644 "$CONFIG_FILE" || {
        log "WARN" "Не удалось изменить права доступа для файла $CONFIG_FILE"
    }
    
    # Изменение владельца директории и файлов
    if getent passwd "$DNSCRYPT_USER" >/dev/null; then
        log "INFO" "Установка владельца $DNSCRYPT_USER для конфигурационных файлов"
        chown -R "$DNSCRYPT_USER":"$DNSCRYPT_USER" "$CONFIG_DIR" || {
            log "WARN" "Не удалось изменить владельца $CONFIG_DIR на $DNSCRYPT_USER"
            log "INFO" "Пробуем альтернативный метод с использованием find..."
            
            # Альтернативный метод установки прав с помощью find
            find "$CONFIG_DIR" -type f -exec chmod 644 {} \;
            find "$CONFIG_DIR" -type d -exec chmod 755 {} \;
            find "$CONFIG_DIR" -exec chown "$DNSCRYPT_USER":"$DNSCRYPT_USER" {} \;
        }
    else
        log "WARN" "Пользователь $DNSCRYPT_USER не найден в системе"
        log "INFO" "Установка общедоступных прав чтения для конфигурационных файлов"
        chmod -R a+r "$CONFIG_DIR"
    fi
    
    log "SUCCESS" "Конфигурация успешно настроена"
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
    
    # Используем функцию из библиотеки
    if ! check_port_usage 53; then
        log "WARN" "Порт 53 занят другим процессом. Сохраняем текущий DNS-резолвер перед изменениями"
        
        # Сохраняем текущие DNS-серверы для использования после установки
        local current_dns=$(grep "nameserver" /etc/resolv.conf | grep -v "127.0.0." | head -1 | awk '{print $2}')
        if [ -z "$current_dns" ]; then
            # Если не нашли нелокальный DNS, используем Google DNS как резервный
            current_dns="8.8.8.8"
        fi
        export BACKUP_DNS_SERVER="$current_dns"
        log "INFO" "Сохранён резервный DNS-сервер: $BACKUP_DNS_SERVER"
        
        # Создаем файл для хранения остановленных сервисов
        mkdir -p "${TEMP_BACKUP_DIR}"
        
        # Проверяем наличие systemd-resolved через PID файл и службу
        if systemctl is-active --quiet systemd-resolved || pgrep -f systemd-resolved >/dev/null; then
            log "INFO" "Обнаружена активная служба systemd-resolved. Настраиваем временный DNS перед отключением"
            
            # Добавляем в список для отката
            echo "systemd-resolved" >> "${TEMP_BACKUP_DIR}/stopped_services.txt"
            ROLLBACK_ACTIONS+=("restart_other_dns")
            
            # Создаём временный resolv.conf с внешним DNS перед остановкой системного резолвера
            chattr -i /etc/resolv.conf 2>/dev/null || true
            cat > /etc/resolv.conf.dnscrypt.tmp << EOF
# Temporary resolv.conf by DNSCrypt installer
nameserver $BACKUP_DNS_SERVER
options timeout:2 attempts:3
EOF
            # Сохраняем права доступа
            cp /etc/resolv.conf.dnscrypt.tmp /etc/resolv.conf
            rm -f /etc/resolv.conf.dnscrypt.tmp
            
            # Проверяем, что резолвинг работает с временным DNS
            if ! ping -c 1 -W 3 google.com >/dev/null 2>&1; then
                log "WARN" "Временный DNS не работает, пробуем альтернативный вариант"
                cat > /etc/resolv.conf << EOF
# Temporary resolv.conf by DNSCrypt installer
nameserver 8.8.8.8
nameserver 1.1.1.1
options timeout:2 attempts:3
EOF
            fi
            
            # Теперь останавливаем systemd-resolved
            systemctl stop systemd-resolved
            systemctl disable systemd-resolved
            log "INFO" "systemd-resolved остановлен и отключен"
            
            # Проверяем, освободился ли порт после остановки процесса
            sleep 2
            if ! check_port_usage 53; then
                log "ERROR" "Не удалось освободить порт 53 после остановки systemd-resolved"
                return 1
            fi
        else
            # Пытаемся определить процесс через lsof
            local process_info=$(lsof -i :53 | grep -v "^COMMAND" | head -1)
            local process=$(echo "$process_info" | awk '{print $1}')
            local process_pid=$(echo "$process_info" | awk '{print $2}')
            
            # Дополнительная проверка для усеченных имен процессов (например, systemd-r вместо systemd-resolved)
            if [[ "$process" == "systemd-r"* ]]; then
                process="systemd-resolved"
            fi
            
            log "INFO" "Порт 53 занят процессом $process (PID: $process_pid). Пытаемся остановить"
            
            case "$process" in
                systemd-resolved|systemd-r*)
                    # Добавляем в список для отката
                    echo "systemd-resolved" >> "${TEMP_BACKUP_DIR}/stopped_services.txt"
                    ROLLBACK_ACTIONS+=("restart_other_dns")
                    
                    # Создаём временный resolv.conf с внешним DNS перед остановкой системного резолвера
                    log "INFO" "Настройка внешнего DNS ($BACKUP_DNS_SERVER) перед отключением systemd-resolved"
                    chattr -i /etc/resolv.conf 2>/dev/null || true
                    cat > /etc/resolv.conf << EOF
# Temporary resolv.conf by DNSCrypt installer
nameserver $BACKUP_DNS_SERVER
options timeout:2 attempts:3
EOF
                    
                    # Проверяем, что резолвинг работает с временным DNS
                    if ! ping -c 1 -W 3 google.com >/dev/null 2>&1; then
                        log "WARN" "Временный DNS не работает, пробуем альтернативный вариант"
                        cat > /etc/resolv.conf << EOF
# Temporary resolv.conf by DNSCrypt installer
nameserver 8.8.8.8
nameserver 1.1.1.1
options timeout:2 attempts:3
EOF
                    fi
                    
                    # Теперь останавливаем systemd-resolved
                    systemctl stop systemd-resolved
                    systemctl disable systemd-resolved
                    log "INFO" "systemd-resolved остановлен и отключен"
                    ;;
                named|bind)
                    # Добавляем в список для отката
                    echo "named bind9" >> "${TEMP_BACKUP_DIR}/stopped_services.txt"
                    ROLLBACK_ACTIONS+=("restart_other_dns")
                    
                    systemctl stop named bind9
                    systemctl disable named bind9
                    log "INFO" "named/bind остановлен и отключен"
                    ;;
                dnsmasq)
                    # Добавляем в список для отката
                    echo "dnsmasq" >> "${TEMP_BACKUP_DIR}/stopped_services.txt"
                    ROLLBACK_ACTIONS+=("restart_other_dns")
                    
                    systemctl stop dnsmasq
                    systemctl disable dnsmasq
                    log "INFO" "dnsmasq остановлен и отключен"
                    ;;
                *)
                    # Последняя попытка: проверяем, является ли процесс экземпляром systemd-resolved
                    if ps -p "$process_pid" -o cmd= | grep -q "systemd-resolve"; then
                        log "INFO" "Определен процесс systemd-resolved по PID $process_pid"
                        
                        # Добавляем в список для отката
                        echo "systemd-resolved" >> "${TEMP_BACKUP_DIR}/stopped_services.txt"
                        ROLLBACK_ACTIONS+=("restart_other_dns")
                        
                        # Настраиваем временный DNS
                        chattr -i /etc/resolv.conf 2>/dev/null || true
                        cat > /etc/resolv.conf << EOF
# Temporary resolv.conf by DNSCrypt installer
nameserver $BACKUP_DNS_SERVER
options timeout:2 attempts:3
EOF
                        
                        # Останавливаем systemd-resolved
                        systemctl stop systemd-resolved
                        systemctl disable systemd-resolved
                        log "INFO" "systemd-resolved остановлен и отключен"
                    else
                        log "WARN" "Неизвестный процесс $process занимает порт 53. Попробуйте остановить его вручную"
                        return 1
                    fi
                    ;;
            esac
            
            # Проверяем, освободился ли порт после остановки процесса
            sleep 2
            if ! check_port_usage 53; then
                log "ERROR" "Не удалось освободить порт 53. Установка может завершиться некорректно"
                return 1
            fi
        fi
        
        # Проверяем, работает ли интернет после остановки системного резолвера
        if ! ping -c 1 -W 3 google.com >/dev/null 2>&1 && ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
            log "ERROR" "Потеряно соединение с интернетом после отключения DNS-резолвера"
            log "INFO" "Восстанавливаем предыдущие настройки DNS"
            
            # Восстанавливаем системный резолвер
            systemctl enable systemd-resolved
            systemctl start systemd-resolved
            
            log "ERROR" "Не удалось безопасно отключить системный DNS. Рекомендуется ручная настройка"
            return 1
        fi
    fi
    
    return 0
}

# Главная функция установки
install_dnscrypt() {
    print_header "УСТАНОВКА DNSCRYPT-PROXY"
    
    # Создаем директорию для временных бэкапов
    mkdir -p "${TEMP_BACKUP_DIR}"
    
    # Проверка подключения к интернету
    if ! check_internet; then
        log "ERROR" "Отсутствует подключение к интернету. Необходимо для загрузки пакетов и конфигурации"
        return 1
    fi
    
    # Проверка зависимостей
    log "INFO" "Проверка необходимых зависимостей"
    check_dependencies wget curl lsof sed systemctl
    
    # Определяем дистрибутив
    local distro
    distro=$(detect_distro) || return 1
    
    # Проверка доступности портов перед установкой
    check_required_ports || {
        log "WARN" "Проблемы с доступностью порта 53. Продолжение может привести к ошибкам"
        read -p "Продолжить установку несмотря на проблемы с портом? (y/n): " continue_install
        if [[ "${continue_install,,}" != "y" ]]; then
            log "INFO" "Установка прервана пользователем"
            return 1
        fi
    }
    
    # Установка пакета - только для Debian/Ubuntu
    install_debian || {
        log "ERROR" "Ошибка установки пакета DNSCrypt-proxy"
        rollback_changes
        return 1
    }
    
    # Настройка конфигурации
    configure_dnscrypt || {
        log "ERROR" "Ошибка настройки конфигурации DNSCrypt"
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
    
    # Включение и запуск службы
    log "INFO" "Настройка автозапуска и запуск службы DNSCrypt"
    systemctl enable "$SERVICE_NAME" || log "WARN" "Не удалось включить автозапуск службы"
    
    if ! restart_service "$SERVICE_NAME"; then
        log "ERROR" "Не удалось запустить службу DNSCrypt"
        
        # Выводим информацию о возможных причинах ошибки
        log "INFO" "Проверка возможных причин проблем запуска службы:"
        
        # Проверка занятости порта 53
        check_port_usage 53
        
        # Проверка конфигурации
        if [ -f "$CONFIG_FILE" ]; then
            cd "$(dirname "$CONFIG_FILE")" && dnscrypt-proxy -check -config="$CONFIG_FILE" && \
                log "INFO" "Конфигурация корректна" || \
                log "ERROR" "Ошибка в файле конфигурации"
        fi
        
        # Проверка логов службы
        log "INFO" "Последние записи журнала службы:"
        journalctl -u "$SERVICE_NAME" -n 10 --no-pager
        
        # Выполняем откат изменений
        log "WARN" "Запуск процедуры отката из-за ошибки запуска службы DNSCrypt"
        rollback_changes
        
        return 1
    fi
    
    # Проверка работы с использованием verify_settings из common.sh
    log "INFO" "Проверка правильности работы DNSCrypt..."
    sleep 2 # Даем время на инициализацию
    
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
    check_current_settings
    
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

# Проверка root-прав (импортируется из common.sh)
check_root

# Вызов главной функции
if ! install_dnscrypt; then
    log "ERROR" "Установка DNSCrypt завершилась с ошибками"
    exit 1
fi

exit 0