#!/bin/bash
# modules/clear_cache.sh - Модуль очистки кэша DNSCrypt
# Создано: 2025-06-24
# Автор: gopnikgame

# Подключаем общую библиотеку
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Подключаем библиотеку диагностики
source "${SCRIPT_DIR}/lib/diagnostic.sh" 2>/dev/null || {
    log "WARN" "Библиотека diagnostic.sh не найдена. Некоторые функции диагностики будут недоступны."
    log "INFO" "Продолжение работы с базовой функциональностью..."
}

# Константы
DNSCRYPT_CACHE_DIR="/var/cache/dnscrypt-proxy"

# Функция очистки кэша файловой системы
clear_fs_cache() {
    log "INFO" "Очистка файлового кэша DNSCrypt..."
    
    # Проверка директории кэша
    if [ ! -d "$DNSCRYPT_CACHE_DIR" ]; then
        log "WARN" "Директория кэша не найдена: $DNSCRYPT_CACHE_DIR"
        
        # Создаем директорию, если она не существует
        mkdir -p "$DNSCRYPT_CACHE_DIR" 2>/dev/null || {
            log "ERROR" "Не удалось создать директорию кэша: $DNSCRYPT_CACHE_DIR"
            return 1
        }
    fi
    
    # Получаем пользователя DNSCrypt из общей библиотеки
    local dnscrypt_user=$(get_dnscrypt_user)
    
    # Останавливаем службу
    log "INFO" "Остановка DNSCrypt для очистки файлового кэша..."
    systemctl stop $DNSCRYPT_SERVICE
    
    # Очистка кэша
    log "INFO" "Удаление файлов кэша из $DNSCRYPT_CACHE_DIR..."
    rm -f "$DNSCRYPT_CACHE_DIR"/* 2>/dev/null
    
    # Установка прав
    chown "${dnscrypt_user}:${dnscrypt_user}" "$DNSCRYPT_CACHE_DIR" 2>/dev/null || log "WARN" "Не удалось изменить владельца директории кэша"
    chmod 700 "$DNSCRYPT_CACHE_DIR"
    
    # Запуск службы
    log "INFO" "Запуск DNSCrypt..."
    if ! systemctl start $DNSCRYPT_SERVICE; then
        log "ERROR" "Ошибка при запуске службы DNSCrypt"
        systemctl status $DNSCRYPT_SERVICE --no-pager
        return 1
    fi
    
    log "SUCCESS" "Файловый кэш DNSCrypt очищен"
    return 0
}

# Расширенная функция очистки кэша с дополнительными опциями
clear_cache_extended() {
    # Используем print_header из common.sh для заголовка
    print_header "ОЧИСТКА КЭША DNSCRYPT"
    
    # Проверка root-прав
    check_root
    
    # Проверка зависимостей
    check_dependencies "systemctl" "rm" "chown" "chmod"
    
    # Проверка наличия DNSCrypt
    if ! check_dnscrypt_installed; then
        log "ERROR" "DNSCrypt не установлен. Очистка кэша невозможна."
        return 1
    fi
    
    # Проверка настроек кэширования в конфигурации
    if [ -f "$DNSCRYPT_CONFIG" ] && grep -q "cache = true" "$DNSCRYPT_CONFIG"; then
        log "INFO" "Кэширование включено в конфигурации DNSCrypt"
        
        # Показываем текущие настройки кэша
        echo -e "\n${BLUE}Текущие настройки кэша:${NC}"
        cache_size=$(grep "cache_size" "$DNSCRYPT_CONFIG" | sed 's/cache_size = //')
        echo "Размер кэша: $cache_size"
        
        cache_min_ttl=$(grep "cache_min_ttl" "$DNSCRYPT_CONFIG" | sed 's/cache_min_ttl = //')
        echo "Минимальное TTL: $cache_min_ttl"
        
        cache_max_ttl=$(grep "cache_max_ttl" "$DNSCRYPT_CONFIG" | sed 's/cache_max_ttl = //')
        echo "Максимальное TTL: $cache_max_ttl"
    else
        log "WARN" "Кэширование отключено в конфигурации DNSCrypt или конфигурация не найдена"
    fi
    
    echo -e "\n${BLUE}Выберите тип очистки:${NC}"
    echo "1) Полная очистка DNS кэша (системный + DNSCrypt)"
    echo "2) Очистка только файлового кэша DNSCrypt"
    echo "3) Очистка только системного DNS кэша"
    echo "0) Отмена"
    
    local choice
    read -p "Выберите опцию (0-3): " choice
    
    case "$choice" in
        1)
            # Используем функцию из common.sh
            clear_dns_cache
            # И дополнительно очищаем файловый кэш
            clear_fs_cache
            ;;
        2)
            # Очистка только файлового кэша
            clear_fs_cache
            ;;
        3)
            # Используем функцию из common.sh
            clear_dns_cache
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
    
    # Проверка состояния службы с использованием функции из common.sh
    if check_service_status $DNSCRYPT_SERVICE; then
        log "SUCCESS" "Кэш успешно очищен, служба DNSCrypt работает"
        
        # Предлагаем проверить работу DNS
        echo -e "\n${BLUE}Хотите проверить работу DNS после очистки кэша?${NC}"
        read -p "Проверить? (y/n): " check_dns
        
        if [[ "${check_dns,,}" == "y" ]]; then
            if type verify_settings &>/dev/null; then
                verify_settings ""
            else
                # Простая проверка, если недоступна функция из библиотеки
                dig @127.0.0.1 example.com +short
                echo "Время ответа: $(dig @127.0.0.1 example.com +noall +stats | grep 'Query time' | awk '{print $4}') мс"
            fi
        fi
    else
        log "ERROR" "Служба DNSCrypt не запустилась после очистки кэша"
        systemctl status $DNSCRYPT_SERVICE --no-pager
        return 1
    fi
    
    return 0
}

# Проверяем, запущен ли скрипт напрямую или как модуль
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Запускаем функцию очистки кэша, если скрипт запущен напрямую
    clear_cache_extended
fi