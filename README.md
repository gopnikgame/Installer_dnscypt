# DNSCrypt Installer and Manager

![DNSCrypt](https://raw.githubusercontent.com/DNSCrypt/dnscrypt-proxy/master/logo.png)

Скрипт для автоматической установки и управления DNSCrypt-proxy на Linux системах.

## 🚀 Быстрая установка

```bash
wget -O - https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/quick_install.sh | sudo bash
```

Или пошагово:

```bash
# Скачивание скрипта
sudo wget -O /usr/local/bin/dnscrypt_manager https://raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/main.sh

# Установка прав на выполнение
sudo chmod +x /usr/local/bin/dnscrypt_manager

# Создание директории для модулей
sudo mkdir -p /usr/local/dnscrypt-scripts/modules/

# Запуск
sudo dnscrypt_manager
```

## 💻 Совместимость

Протестировано на:
- ✅ Ubuntu 24.04 LTS
- ✅ Ubuntu 22.04 LTS
- ⚠️ Другие системы на базе Debian (требуется тестирование)

[Остальная часть README остаётся без изменений...]