#!/bin/bash

# Цветовые коды
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Константы
XRAY_CONFIG="/usr/local/x-ui/bin/config.json"
UI_CONFIG="/usr/local/x-ui/config.json"
SERVICE_NAME="x-ui"

# Функция логирования
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "${timestamp} [$1] $2"
}

# Функция проверки установки 3x-ui
check_3xui_installation() {
    if ! systemctl is-active --quiet $SERVICE_NAME; then
        log "ERROR" "${RED}3x-ui не установлен или не запущен${NC}"
        log "INFO" "${YELLOW}Сначала установите 3x-ui${NC}"
        return 1
    fi
    
    if [ ! -f "$UI_CONFIG" ]; then
        log "ERROR" "${RED}Конфигурационный файл 3x-ui не найден${NC}"
        return 1
    }
    
    return 0
}

# Функция получения текущих DNS настроек
get_current_dns_settings() {
    local dns_settings=""
    
    if [ -f "$XRAY_CONFIG" ]; then
        if grep -q "dns" "$XRAY_CONFIG"; then
            dns_settings=$(grep -A 10 "dns" "$XRAY_CONFIG")
            log "INFO" "${BLUE}Текущие настройки DNS в 3x-ui:${NC}"
            echo -e "${YELLOW}$dns_settings${NC}"
        else
            log "INFO" "${YELLOW}DNS не настроен в 3x-ui${NC}"
        fi
    else
        log "ERROR" "${RED}Конфигурационный файл Xray не найден${NC}"
    fi
}

# Функция настройки DNS
configure_dns() {
    log "INFO" "Настройка DNS для 3x-ui..."
    
    # Создаем бэкап текущего конфига
    if [ -f "$XRAY_CONFIG" ]; then
        cp "$XRAY_CONFIG" "${XRAY_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
        log "INFO" "Создана резервная копия конфигурации Xray"
    fi
    
    # Конфигурация DNS
    local dns_config='{
  "dns": {
    "servers": [
      "127.0.0.1:53",
      "localhost"
    ],
    "queryStrategy": "UseIPv4"
  }'
    
    # Проверяем существует ли секция dns
    if grep -q "dns" "$XRAY_CONFIG"; then
        # Заменяем существующую конфигурацию
        sed -i '/\"dns\":/,/}/c\'"$dns_config" "$XRAY_CONFIG"
    else
        # Добавляем новую конфигурацию после первой фигурной скобки
        sed -i '1s/{/{\'$'\n'"$dns_config"'/' "$XRAY_CONFIG"
    fi
    
    # Перезапускаем службу
    systemctl restart $SERVICE_NAME
    
    # Проверяем статус службы
    if systemctl is-active --quiet $SERVICE_NAME; then
        log "SUCCESS" "${GREEN}DNS успешно настроен в 3x-ui${NC}"
        log "INFO" "Новые настройки DNS:"
        get_current_dns_settings
    else
        log "ERROR" "${RED}Ошибка при перезапуске службы 3x-ui${NC}"
        log "INFO" "${YELLOW}Восстанавливаем конфигурацию из резервной копии...${NC}"
        cp "${XRAY_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)" "$XRAY_CONFIG"
        systemctl restart $SERVICE_NAME
        return 1
    fi
}

# Основная функция
main() {
    log "INFO" "Запуск модуля настройки DNS для 3x-ui..."
    
    # Проверяем установку 3x-ui
    if ! check_3xui_installation; then
        read -p "Нажмите Enter для возврата в главное меню..."
        return 1
    fi
    
    # Показываем текущие настройки
    get_current_dns_settings
    
    # Спрашиваем о продолжении
    echo -e "\n${YELLOW}Хотите настроить DNS для 3x-ui? (y/n):${NC} "
    read -r answer
    
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        configure_dns
        if [ $? -eq 0 ]; then
            log "SUCCESS" "${GREEN}Настройка DNS для 3x-ui завершена успешно${NC}"
        else
            log "ERROR" "${RED}Произошла ошибка при настройке DNS${NC}"
        fi
    else
        log "INFO" "Операция отменена пользователем"
    fi
    
    read -p "Нажмите Enter для возврата в главное меню..."
    return 0
}

# Запуск модуля
main