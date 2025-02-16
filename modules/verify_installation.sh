#!/bin/bash

# Константы
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
DNSCRYPT_BINARY="/usr/sbin/dnscrypt-proxy"
RESOLVED_CONFIG="/etc/systemd/resolved.conf"

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

# Функция проверки и исправления systemd-resolved
check_and_fix_resolved() {
    if systemctl is-active --quiet systemd-resolved; then
        log "INFO" "Обнаружен активный systemd-resolved"
        
        # Проверяем настройки resolved.conf
        if ! grep -q "DNSStubListener=no" "$RESOLVED_CONFIG"; then
            log "INFO" "Отключаем DNSStubListener в systemd-resolved..."
            echo "DNSStubListener=no" >> "$RESOLVED_CONFIG"
            
            # Перезапускаем службу
            systemctl restart systemd-resolved
            sleep 2
        fi
        
        # Проверяем, освободился ли порт 53
        if ! lsof -i :53 | grep -q "systemd-r"; then
            log "SUCCESS" "Порт 53 освобожден от systemd-resolved"
        else
            log "ERROR" "Не удалось освободить порт 53"
            return 1
        fi
    fi
    return 0
}

# Функция проверки конфигурации DNSCrypt
check_dnscrypt_config() {
    local listen_address
    listen_address=$(grep "listen_addresses" "$DNSCRYPT_CONFIG" | grep -o "'.*'" | tr -d "'")
    
    if [[ ! "$listen_address" =~ "127.0.0.1:53" ]]; then
        log "INFO" "Настраиваем DNSCrypt для прослушивания порта 53..."
        sed -i "s/listen_addresses = .*/listen_addresses = ['127.0.0.1:53']/" "$DNSCRYPT_CONFIG"
        systemctl restart dnscrypt-proxy
        sleep 2
    fi
}

# Основная функция проверки
verify_installation() {
    log "INFO" "Начало проверки установки DNSCrypt..."
    local errors=0

    # Проверка бинарного файла
    if [ -f "$DNSCRYPT_BINARY" ]; then
        log "SUCCESS" "DNSCrypt бинарный файл найден"
        if [ -x "$DNSCRYPT_BINARY" ]; then
            log "SUCCESS" "DNSCrypt бинарный файл имеет права на выполнение"
        else
            log "ERROR" "DNSCrypt бинарный файл не имеет прав на выполнение"
            ((errors++))
        fi
    else
        log "ERROR" "DNSCrypt бинарный файл не найден"
        ((errors++))
    fi

    # Проверка конфигурационного файла
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        log "SUCCESS" "Конфигурационный файл найден"
    else
        log "ERROR" "Конфигурационный файл не найден"
        ((errors++))
    fi

    # Проверка статуса службы
    if systemctl is-active --quiet dnscrypt-proxy; then
        log "SUCCESS" "Служба DNSCrypt активна"
    else
        log "ERROR" "Служба DNSCrypt не активна"
        ((errors++))
    fi

    # Проверка порта 53
    if ! lsof -i :53 >/dev/null 2>&1; then
        log "INFO" "Порт 53 свободен, настраиваем DNSCrypt..."
        check_dnscrypt_config
    elif lsof -i :53 | grep -q "dnscrypt"; then
        log "SUCCESS" "DNSCrypt слушает порт 53"
    else
        log "ERROR" "DNSCrypt не слушает порт 53"
        
        # Предлагаем исправить
        echo -e "\n${YELLOW}Обнаружена проблема с портом 53. Хотите попытаться исправить? (y/n)${NC}"
        read -r fix_choice
        if [[ "${fix_choice,,}" == "y" ]]; then
            if check_and_fix_resolved && check_dnscrypt_config; then
                log "SUCCESS" "Настройки применены, проверяем результат..."
                systemctl restart dnscrypt-proxy
                sleep 2
                if lsof -i :53 | grep -q "dnscrypt"; then
                    log "SUCCESS" "DNSCrypt теперь слушает порт 53"
                else
                    log "ERROR" "Не удалось настроить прослушивание порта 53"
                    ((errors++))
                fi
            else
                ((errors++))
            fi
        else
            ((errors++))
        fi
    fi

    # Проверка DNS резолвинга
    if dig @127.0.0.1 google.com +short +timeout=5 >/dev/null 2>&1; then
        log "SUCCESS" "DNS резолвинг работает"
        
        # Дополнительная информация о резолвинге
        echo -e "\n${BLUE}Информация о DNS резолвинге:${NC}"
        echo "Текущий DNS сервер:"
        dig +short resolver.dnscrypt.info TXT | sed 's/"//g'
        
        echo -e "\nВремя отклика для популярных доменов:"
        for domain in google.com cloudflare.com github.com; do
            local resolve_time=$(dig @127.0.0.1 "$domain" +noall +stats 2>/dev/null | grep "Query time" | awk '{print $4}')
            echo "$domain: ${resolve_time}ms"
        done
    else
        log "ERROR" "DNS резолвинг не работает"
        ((errors++))
    fi

    # Итоговый результат
    if [ $errors -eq 0 ]; then
        log "SUCCESS" "Проверка завершена успешно. Ошибок не найдено"
        return 0
    else
        log "ERROR" "Проверка завершена. Найдено ошибок: $errors"
        return 1
    fi
}

# Запуск проверки
verify_installation