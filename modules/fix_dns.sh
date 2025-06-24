#!/bin/bash
# modules/fix_dns.sh - Модуль исправления DNS резолвинга
# Создано: 2025-06-24
# Автор: gopnikgame

# Подключение общей библиотеки
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Функция для проверки проблем с DNS
diagnose_dns_issues() {
    print_header "ДИАГНОСТИКА DNS-ПРОБЛЕМ"
    log "INFO" "Проверка DNS-конфигурации..."
    
    # Проверка наличия DNSCrypt
    if ! command -v dnscrypt-proxy &>/dev/null; then
        log "ERROR" "DNSCrypt-proxy не установлен"
        echo -e "${YELLOW}Сначала нужно установить DNSCrypt-proxy.${NC}"
        echo -e "Используйте пункт меню 'Установить DNSCrypt'"
        return 1
    fi
    
    # Проверка конфигурационного файла
    if [ ! -f "$DNSCRYPT_CONFIG" ]; then
        log "ERROR" "Файл конфигурации DNSCrypt не найден: $DNSCRYPT_CONFIG"
        echo -e "${YELLOW}Возможно, DNSCrypt установлен с нестандартным путем конфигурации.${NC}"
        return 1
    fi
    
    echo -e "\n${BLUE}Проверка состояния службы DNSCrypt-proxy:${NC}"
    systemctl status "$DNSCRYPT_SERVICE" --no-pager
    
    echo -e "\n${BLUE}Проверка занятости порта DNS (53):${NC}"
    check_port_usage 53
    
    echo -e "\n${BLUE}Проверка resolv.conf:${NC}"
    cat "$RESOLV_CONF" | grep -v "^#"
    
    echo -e "\n${BLUE}Проверка настройки слушателя в DNSCrypt:${NC}"
    grep "listen_addresses" "$DNSCRYPT_CONFIG" | sed 's/listen_addresses = //'
    
    echo -e "\n${BLUE}Последние записи журнала службы:${NC}"
    journalctl -u "$DNSCRYPT_SERVICE" -n 10 --no-pager
    
    echo -e "\n${BLUE}Тестирование DNS-запросов:${NC}"
    dig @127.0.0.1 example.com | grep -E "^;; (Query time|SERVER)|^example.com"
    
    return 0
}

# Функция для исправления проблем с DNS
fix_dns_issues() {
    print_header "ИСПРАВЛЕНИЕ DNS-ПРОБЛЕМ"
    log "INFO" "Исправление проблем с DNS..."
    
    # Создание резервной копии перед исправлением
    backup_config "$DNSCRYPT_CONFIG" "dnscrypt-config"
    
    # Проверка порта DNS (53)
    echo -e "\n${BLUE}Проверка занятости порта DNS (53):${NC}"
    local port53_status=$(check_port_usage 53 || echo "busy")
    
    if [[ "$port53_status" == "busy" ]]; then
        echo -e "${YELLOW}Порт 53 занят другим процессом. Попытка решения проблемы...${NC}"
        
        # Проверка systemd-resolved
        if systemctl is-active --quiet systemd-resolved; then
            echo -e "${YELLOW}Служба systemd-resolved активна и может блокировать порт 53.${NC}"
            echo "Варианты решения:"
            echo "1) Отключить systemd-resolved и перенастроить resolv.conf"
            echo "2) Изменить порт прослушивания DNSCrypt-proxy (не 53)"
            echo "0) Отмена"
            
            read -p "Выберите опцию (0-2): " resolve_choice
            
            case $resolve_choice in
                1)
                    # Отключение systemd-resolved
                    log "INFO" "Отключение systemd-resolved..."
                    systemctl stop systemd-resolved
                    systemctl disable systemd-resolved
                    
                    # Настройка resolv.conf
                    echo -e "nameserver 127.0.0.1\n" > "$RESOLV_CONF"
                    
                    log "SUCCESS" "systemd-resolved отключен"
                    ;;
                2)
                    # Изменение порта DNSCrypt
                    log "INFO" "Настройка DNSCrypt на использование альтернативного порта..."
                    
                    sed -i "s/listen_addresses = .*/listen_addresses = ['127.0.0.1:5353']/" "$DNSCRYPT_CONFIG"
                    
                    echo -e "${YELLOW}DNSCrypt настроен на порт 5353. Необходимо обновить resolv.conf${NC}"
                    echo "nameserver 127.0.0.1" > "$RESOLV_CONF"
                    
                    log "SUCCESS" "DNSCrypt настроен на альтернативный порт"
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
        else
            # Другой процесс занимает порт 53
            echo -e "${YELLOW}Другой процесс занимает порт 53. Определение...${NC}"
            lsof -i :53
            
            echo -e "\nВарианты решения:"
            echo "1) Остановить другой процесс (может повлиять на работу системы)"
            echo "2) Изменить порт прослушивания DNSCrypt-proxy (не 53)"
            echo "0) Отмена"
            
            read -p "Выберите опцию (0-2): " process_choice
            
            case $process_choice in
                1)
                    # Попытка остановить процесс
                    log "WARN" "Внимание! Остановка процессов может повлиять на работу системы!"
                    echo -e "${RED}Эта операция может быть опасной. Вы уверены?${NC}"
                    read -p "Продолжить? (y/n): " confirm
                    
                    if [[ "${confirm,,}" == "y" ]]; then
                        local process_id=$(lsof -i :53 -t)
                        if [ -n "$process_id" ]; then
                            kill -15 $process_id
                            log "SUCCESS" "Процесс остановлен"
                        else
                            log "ERROR" "Не удалось определить PID процесса"
                        fi
                    else
                        log "INFO" "Операция отменена"
                    fi
                    ;;
                2)
                    # Изменение порта DNSCrypt
                    log "INFO" "Настройка DNSCrypt на использование альтернативного порта..."
                    
                    sed -i "s/listen_addresses = .*/listen_addresses = ['127.0.0.1:5353']/" "$DNSCRYPT_CONFIG"
                    
                    # Обновление resolv.conf для использования порта 5353
                    echo -e "${YELLOW}DNSCrypt настроен на порт 5353. Обновление настроек системы...${NC}"
                    echo "nameserver 127.0.0.1" > "$RESOLV_CONF"
                    
                    log "SUCCESS" "DNSCrypt настроен на альтернативный порт"
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
        fi
    fi
    
    # Проверка и перезапуск службы DNSCrypt
    echo -e "\n${BLUE}Проверка и перезапуск службы DNSCrypt-proxy:${NC}"
    systemctl restart "$DNSCRYPT_SERVICE"
    
    echo -e "\n${BLUE}Проверка настроек после исправления:${NC}"
    verify_settings
    
    return 0
}

# Функция для проверки и настройки анонимного DNS
check_and_configure_anonymized_dns() {
    print_header "АНОНИМНЫЙ DNS"
    log "INFO" "Проверка и настройка анонимного DNS..."
    
    # Проверка текущих настроек анонимизации
    check_anonymized_dns
    
    echo -e "\n${BLUE}Управление анонимным DNS:${NC}"
    echo "1) Запустить модуль управления анонимным DNS"
    echo "0) Назад"
    
    read -p "Выберите опцию (0-1): " anon_choice
    
    case $anon_choice in
        1)
            # Запуск модуля управления анонимным DNS
            "$SCRIPT_DIR/modules/manage_anonymized_dns.sh"
            ;;
        0)
            return 0
            ;;
        *)
            log "ERROR" "Неверный выбор"
            return 1
            ;;
    esac
    
    return 0
}

# Основное меню модуля
main_menu() {
    while true; do
        print_header "ИСПРАВЛЕНИЕ DNS"
        echo "1) Диагностировать проблемы с DNS"
        echo "2) Исправить проблемы с DNS"
        echo "3) Настройка анонимного DNS"
        echo "4) Очистить DNS-кэш"
        echo "0) Выход"
        
        read -p "Выберите опцию (0-4): " option
        
        case $option in
            1)
                diagnose_dns_issues
                ;;
            2)
                fix_dns_issues
                ;;
            3)
                check_and_configure_anonymized_dns
                ;;
            4)
                clear_dns_cache
                ;;
            0)
                log "INFO" "Выход из модуля исправления DNS"
                exit 0
                ;;
            *)
                log "ERROR" "Неверный выбор"
                ;;
        esac
        
        echo
        read -p "Нажмите Enter для продолжения..."
    done
}

# Проверка root-прав
check_root

# Проверка зависимостей
check_dependencies "dnscrypt-proxy" "dig" "lsof" "sed" "grep"

# Запуск основного меню
log "INFO" "Запуск модуля исправления DNS..."
main_menu