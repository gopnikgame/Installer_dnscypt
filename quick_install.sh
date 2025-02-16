#!/bin/bash

# Цветовые коды
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Функция логирования
log() {
    printf "%s [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"
}

# Проверка root прав
if [ "$EUID" -ne 0 ]; then
    log "ERROR" "${RED}Этот скрипт должен быть запущен с правами root${NC}"
    exit 1
fi

# Проверка наличия необходимых утилит
for cmd in wget systemctl; do
    if ! command -v $cmd &> /dev/null; then
        log "ERROR" "${RED}Команда $cmd не найдена. Установите необходимые зависимости.${NC}"
        exit 1
    fi
done

# Создание директорий
log "INFO" "${BLUE}Создание необходимых директорий...${NC}"
mkdir -p /usr/local/dnscrypt-scripts/modules/
mkdir -p /var/log/dnscrypt/

# Загрузка главного скрипта
log "INFO" "${BLUE}Загрузка основного скрипта...${NC}"
wget -q -O /usr/local/bin/dnscrypt_manager https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/main.sh

if [ $? -eq 0 ]; then
    chmod +x /usr/local/bin/dnscrypt_manager
    log "SUCCESS" "${GREEN}Основной скрипт успешно установлен${NC}"
else
    log "ERROR" "${RED}Ошибка при загрузке основного скрипта${NC}"
    exit 1
fi

# Создание символической ссылки
ln -sf /usr/local/bin/dnscrypt_manager /usr/local/bin/dnscrypt-manager

# Вывод информации об успешной установке
printf "\n${GREEN}=== DNSCrypt Manager успешно установлен ===${NC}\n"
printf "Для запуска используйте команду: ${YELLOW}sudo dnscrypt_manager${NC} или ${YELLOW}sudo dnscrypt-manager${NC}\n"
printf "Все модули будут автоматически загружены при первом запуске\n\n"

# Предложение запустить скрипт
printf "Запустить DNSCrypt Manager сейчас? (y/n): "
read answer
if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    /usr/local/bin/dnscrypt_manager
fi