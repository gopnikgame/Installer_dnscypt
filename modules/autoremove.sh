#!/bin/bash
# modules/autoremove.sh - Модуль для полного удаления DNSCrypt и всех компонентов
# Created: 2025-06-26
# Author: gopnikgame

# Подключение общей библиотеки
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Функция для полного удаления DNSCrypt и восстановления стандартных параметров системы
uninstall_dnscrypt() {
    print_header "ПОЛНОЕ УДАЛЕНИЕ DNSCRYPT"
    
    # Проверка root-прав
    check_root
    
    # Запрос подтверждения
    safe_echo "${RED}ВНИМАНИЕ: Это действие полностью удалит DNSCrypt и вернет системные настройки DNS в исходное состояние.${NC}"
    safe_echo "${RED}Все файлы конфигурации, логи и компоненты DNSCrypt будут удалены.${NC}"
    echo
    read -p "Вы уверены, что хотите продолжить? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "Удаление отменено"
        return 0
    fi
    
    echo
    safe_echo "${YELLOW}Выполняется удаление...${NC}"
    
    # 1. Остановка и отключение службы DNSCrypt
    log "INFO" "Остановка и отключение службы DNSCrypt..."
    systemctl stop $DNSCRYPT_SERVICE 2>/dev/null
    systemctl disable $DNSCRYPT_SERVICE 2>/dev/null
    log "SUCCESS" "Служба DNSCrypt остановлена и отключена"
    
    # 2. Восстановление оригинального resolv.conf из бэкапа
    log "INFO" "Восстановление оригинального resolv.conf..."
    
    # Проверка наличия бэкапов resolv.conf
    local resolv_backup=""
    # Ищем самый старый бэкап resolv.conf (вероятно, оригинальный)
    if [ -d "$BACKUP_DIR" ]; then
        resolv_backup=$(find "$BACKUP_DIR" -name "resolv.conf_*.bak" | sort | head -n 1)
    fi
    
    # Снимаем защиту от изменений, если она установлена
    chattr -i /etc/resolv.conf 2>/dev/null
    
    if [ -n "$resolv_backup" ] && [ -f "$resolv_backup" ]; then
        # Восстанавливаем из бэкапа
        cp "$resolv_backup" "$RESOLV_CONF"
        log "SUCCESS" "Восстановлен оригинальный resolv.conf из бэкапа"
    else
        # Создаем типовой resolv.conf
        cat > /etc/resolv.conf << EOF
# Generated by DNSCrypt uninstaller - default configuration
nameserver 8.8.8.8
nameserver 1.1.1.1
options edns0
EOF
        log "SUCCESS" "Создан стандартный resolv.conf с публичными DNS серверами"
    fi
    
    # 3. Включение systemd-resolved, если он был отключен
    if systemctl is-enabled systemd-resolved 2>/dev/null | grep -q "disabled"; then
        log "INFO" "Включение systemd-resolved..."
        systemctl enable systemd-resolved
        systemctl start systemd-resolved
        
        # Настройка systemd-resolved, если он включен
        if [ -f "/etc/systemd/resolved.conf.d/dnscrypt.conf" ]; then
            rm -f "/etc/systemd/resolved.conf.d/dnscrypt.conf"
        fi
        
        log "SUCCESS" "systemd-resolved включен и настроен"
    fi
    
    # 4. Удаление пакета dnscrypt-proxy через менеджер пакетов
    log "INFO" "Удаление пакета DNSCrypt-proxy..."
    
    if command -v apt-get &>/dev/null; then
        apt-get remove --purge -y dnscrypt-proxy
        apt-get autoremove -y
    elif command -v yum &>/dev/null; then
        yum remove -y dnscrypt-proxy
    elif command -v pacman &>/dev/null; then
        pacman -R --noconfirm dnscrypt-proxy
    fi
    
    log "SUCCESS" "Пакет DNSCrypt-proxy удален"
    
    # 5. Удаление файлов и директорий DNSCrypt
    log "INFO" "Удаление файлов конфигурации и служебных директорий..."
    
    # Удаляем конфигурацию
    rm -rf /etc/dnscrypt-proxy 2>/dev/null
    
    # Удаляем файл службы
    rm -f /etc/systemd/system/dnscrypt-proxy.service 2>/dev/null
    systemctl daemon-reload
    
    # 6. Удаление бэкапов, логов и прочих файлов
    log "INFO" "Удаление бэкапов и логов..."
    
    # Бэкапы
    if [ -d "$BACKUP_DIR" ]; then
        rm -rf "$BACKUP_DIR"
        log "SUCCESS" "Удалены бэкапы DNSCrypt"
    fi
    
    # Логи
    if [ -d "$LOG_DIR" ]; then
        rm -rf "$LOG_DIR"
        log "SUCCESS" "Удалены логи DNSCrypt"
    fi
    
    # 7. Удаление пользователя DNSCrypt, если он существует
    if id "_dnscrypt-proxy" &>/dev/null; then
        userdel -r "_dnscrypt-proxy" 2>/dev/null
        log "SUCCESS" "Удален пользователь _dnscrypt-proxy"
    elif id "dnscrypt-proxy" &>/dev/null; then
        userdel -r "dnscrypt-proxy" 2>/dev/null
        log "SUCCESS" "Удален пользователь dnscrypt-proxy"
    fi
    
    # 8. Очистка системного кэша DNS
    log "INFO" "Очистка системного DNS кэша..."
    
    # Очистка кэша systemd-resolved (если используется)
    if systemctl is-active --quiet systemd-resolved; then
        systemd-resolve --flush-caches 2>/dev/null
    fi
    
    # Очистка кэша nscd (если установлен)
    if command -v nscd &>/dev/null && systemctl is-active --quiet nscd; then
        systemctl restart nscd 2>/dev/null
    fi
    
    # 9. Удаление директории скрипта DNSCrypt Manager, если скрипт запущен как самостоятельный
    log "INFO" "Проверка наличия директории с установщиком DNSCrypt..."
    
    # Спрашиваем, нужно ли удалить скрипты DNSCrypt Manager
    echo
    read -p "Удалить все скрипты DNSCrypt Manager (y/n): " remove_scripts
    if [[ "$remove_scripts" =~ ^[Yy]$ ]]; then
        # Получаем абсолютный путь к директории скрипта
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        
        if [ -d "$script_dir" ] && [[ "$script_dir" != "/" ]]; then
            cd /
            rm -rf "$script_dir"
            log "SUCCESS" "Удалены все скрипты DNSCrypt Manager"
        else
            log "WARN" "Не удалось определить директорию скриптов для удаления"
        fi
    else
        log "INFO" "Скрипты DNSCrypt Manager сохранены"
    fi
    
    print_header "УДАЛЕНИЕ ЗАВЕРШЕНО"
    safe_echo "${GREEN}DNSCrypt успешно удален из системы${NC}"
    safe_echo "${GREEN}DNS резолвер восстановлен в стандартное состояние${NC}"
    echo
    safe_echo "${YELLOW}Рекомендуется перезагрузить систему:${NC}"
    safe_echo "${CYAN}sudo reboot${NC}"
    
    return 0
}

# Запуск основной функции
uninstall_dnscrypt