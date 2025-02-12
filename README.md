
```markdown
# DNS Crypt-Proxy Auto Installer

Автоматизированная установка и настройка DNSCrypt-Proxy с поддержкой DoH/DoT для Ubuntu Server

## Особенности
- Настраивает DNS-over-HTTPS (DoH) и DNS-over-TLS (DoT)
- Основные серверы: Google DNS
- Резервные серверы: Quad9 и Cloudflare
- Встроенная защита DNSSEC
- Локальное кэширование DNS
- Автоматическая настройка фаервола (UFW)
- Подробное логирование
- Резервное копирование конфигурации
```

## Требования
- Ubuntu Server 20.04 LTS или новее
- Доступ с правами `sudo`
- Интернет-соединение

## Быстрая установка (без сохранения скрипта на сервер)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/setup_doh_dot.sh)"
```

Или с использованием `wget`:

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/setup_doh_dot.sh)"
```

## Что делает скрипт:
1. Создает резервные копии текущих настроек
2. Устанавливает и настраивает DNSCrypt-Proxy
3. Настраивает systemd-resolved
4. Открывает порт 53 для локального использования
5. Включает DNS-over-TLS и DNSSEC
6. Проверяет корректность установки
7. Предоставляет отчет об изменениях

## После установки
Проверьте работу системы:
```bash
# Статус службы
systemctl status dnscrypt-proxy

# Просмотр логов
journalctl -u dnscrypt-proxy -f

# Проверка DNS
dig google.com @127.0.0.53 +short
```

## Логирование
Все действия скрипта записываются в файл:
`/tmp/dnscrypt_setup.log`

## Безопасность
Перед запуском рекомендуется просмотреть исходный код скрипта:
```bash
curl -sSL https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/setup_doh_dot.sh | less
```

## Внесение изменений
Если вы хотите модифицировать скрипт:
1. Клонируйте репозиторий:
```bash
git clone https://github.com/gopnikgame/Installer_dnscypt.git
```
2. Редактируйте файл `setup_doh_dot.sh`
3. Запустите локальную версию:
```bash
sudo ./Installer_dnscypt/setup_doh_dot.sh
```

---

**Репозиторий проекта**:  
[https://github.com/gopnikgame/Installer_dnscypt](https://github.com/gopnikgame/Installer_dnscypt)

**Файл скрипта**:  
[setup_doh_dot.sh](https://github.com/gopnikgame/Installer_dnscypt/blob/main/setup_doh_dot.sh)
