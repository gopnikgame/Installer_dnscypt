#!/bin/bash
# modules/manage_service.sh

# Константы
DNSCRYPT_SERVICE="dnscrypt-proxy"
DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"

# Функция логирования
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$timestamp [$1] $2"
}

manage_service() {
    while true; do
        clear
        log "INFO" "=== Управление службой DNSCrypt ==="
        echo
        echo "1) Показать статус службы"
        echo "2) Запустить службу"
        echo "3) Остановить службу"
        echo "4) Перезапустить службу"
        echo "5) Показать логи"
        echo "0) Вернуться в главное меню"
        
        read -p "Выберите действие (0-5): " choice
        echo
        
        case $choice in
            1)
                log "INFO" "Статус службы DNSCrypt:"
                systemctl status $DNSCRYPT_SERVICE --no-pager
                ;;
            2)
                log "INFO" "Запуск службы..."
                systemctl start $DNSCRYPT_SERVICE
                sleep 2
                if systemctl is-active --quiet $DNSCRYPT_SERVICE; then
                    log "SUCCESS" "Служба успешно запущена"
                else
                    log "ERROR" "Не удалось запустить службу"
                    systemctl status $DNSCRYPT_SERVICE --no-pager
                fi
                ;;
            3)
                log "INFO" "Остановка службы..."
                systemctl stop $DNSCRYPT_SERVICE
                if ! systemctl is-active --quiet $DNSCRYPT_SERVICE; then
                    log "SUCCESS" "Служба остановлена"
                else
                    log "ERROR" "Не удалось остановить службу"
                fi
                ;;
            4)
                log "INFO" "Перезапуск службы..."
                systemctl restart $DNSCRYPT_SERVICE
                sleep 2
                if systemctl is-active --quiet $DNSCRYPT_SERVICE; then
                    log "SUCCESS" "Служба успешно перезапущена"
                else
                    log "ERROR" "Не удалось перезапустить службу"
                    systemctl status $DNSCRYPT_SERVICE --no-pager
                fi
                ;;
            5)
                log "INFO" "Последние записи журнала:"
                journalctl -u $DNSCRYPT_SERVICE -n 50 --no-pager
                ;;
            0)
                return 0
                ;;
            *)
                log "ERROR" "Неверный выбор"
                ;;
        esac
        
        echo
        read -p "Нажмите Enter для продолжения..."
    done
}

# Запуск управления службой
manage_service