# VPN Sing-box Deployment Guide
**VLESS + Reality | Ubuntu 22.04 | Aeza NLs-1**

> Версия: 1.0 | Дата: апрель 2026

---

## Содержание

1. [Введение и цели](#1-введение-и-цели)
2. [Предварительные требования](#2-предварительные-требования)
3. [Пошаговая установка](#3-пошаговая-установка)
4. [Конфигурационные файлы](#4-конфигурационные-файлы)
5. [Развёртывание и запуск](#5-развёртывание-и-запуск)
6. [Раздача доступа пользователям](#6-раздача-доступа-пользователям)
7. [Интеграция с Telegram-ботом](#7-интеграция-с-telegram-ботом)
8. [Ротация ключей](#8-ротация-ключей)
9. [Резервное копирование и восстановление](#9-резервное-копирование-и-восстановление)
10. [Мониторинг, обслуживание и безопасность](#10-мониторинг-обслуживание-и-безопасность)
11. [Runbook: действия при блокировках](#11-runbook-действия-при-блокировках)
12. [Список полезных команд](#12-список-полезных-команд)

---

## 1. Введение и цели

### Что развёртывается

Sing-box — современный прокси-тулкит с поддержкой протокола **VLESS + Reality**. Reality — улучшение TLS, при котором сервер «притворяется» легитимным сайтом (например, `www.microsoft.com`) на уровне TLS-рукопожатия. ТСПУ/DPI видит обычный TLS-трафик к известному домену и не может отличить его от реального.

### Архитектура

```
Клиент (Hiddify / v2rayN)
   │
   │  VLESS+Reality :443 (TCP)
   ▼
┌─────────────────────────────────────────────────────┐
│  VPS NLs-1  77.73.135.202  (Ubuntu 22.04, 1 core)  │
│                                                     │
│  sing-box                                           │
│  ├─ inbound  vless-in      ::443     (пользователи) │
│  └─ inbound  socks-bot  127.0.0.1:1080 (Telegram-бот)│
│                                                     │
│  Silent Couple Bot (aiogram 3 + arq + Redis)        │
└─────────────────────────────────────────────────────┘
   │
   │  Прямой выход в интернет
   ▼
```

### Цели

- Устойчивость к блокировкам РКН/ТСПУ
- Обслуживание 10–15 пользователей + Telegram-бот на 1 core / 2 ГБ RAM
- Полное восстановление с нуля за ≤ 20 минут

---

## 2. Предварительные требования

### Сервер

| Параметр | Значение |
|----------|---------|
| Провайдер | Aeza, тариф NLs-1 |
| IP | 77.73.135.202 |
| ОС | Ubuntu 22.04 LTS |
| CPU / RAM | 1 ядро / 2 ГБ |
| Диск | 30 ГБ NVMe |
| SSH-пользователь | `user_vpn` |

### На сервере

```bash
# Обновить ОС
apt update && apt upgrade -y

# Установить git (может отсутствовать)
apt install -y git
```

### Клиентские приложения (для тестирования)

| ОС | Приложение |
|----|-----------|
| Android | Hiddify, v2rayNG |
| iOS | Streisand, Shadowrocket |
| Windows | Hiddify, v2rayN |
| macOS | Hiddify, Clash Verge |
| Linux | sing-box CLI |

---

## 3. Пошаговая установка

### 3.1. Клонировать репозиторий

```bash
# Войти на сервер
ssh user_vpn@77.73.135.202

# Переключиться в root
sudo -i

# Клонировать репозиторий
git clone https://github.com/Den20050/vpn_proxy_aeza /opt/vpn_proxy_aeza
cd /opt/vpn_proxy_aeza
```

### 3.2. Один-командный деплой

```bash
# Стандартный запуск (3 пользователя, server_name = www.microsoft.com)
bash scripts/deploy.sh

# С кастомными параметрами
NUM_USERS=5 \
USER_NAMES="ivan,olga,sergey,maria,alex" \
SERVER_NAME="www.apple.com" \
bash scripts/deploy.sh
```

Скрипт выполняет все шаги автоматически:
1. Устанавливает зависимости
2. Устанавливает последнюю версию Sing-box
3. Генерирует ключи и UUID
4. Создаёт `/etc/sing-box/config.json`
5. Устанавливает systemd-сервис
6. Настраивает UFW (разрешены только порты 22 и 443)
7. Добавляет cron для ежедневного бэкапа
8. Выводит vless:// ссылки и QR-коды

---

## 4. Конфигурационные файлы

### 4.1. config.json

Шаблон: [`config/config.json.template`](../config/config.json.template)  
Реальный файл создаётся скриптом `generate-keys.sh` и сохраняется в `/etc/sing-box/config.json`.

#### Блок `log`

```json
"log": {
  "level": "info",       // debug | info | warn | error
  "timestamp": true,     // добавлять метку времени в каждую строку
  "output": "/var/log/sing-box/sing-box.log"
}
```

#### Блок `inbounds[0]` — VLESS + Reality

```json
{
  "type": "vless",
  "tag": "vless-in",
  "listen": "::",        // слушать на всех IPv4 и IPv6 интерфейсах
  "listen_port": 443,    // только 443 — HTTPS-порт маскировки

  "users": [
    {
      "name": "user1",
      "uuid": "<uuid-v4>",          // уникальный для каждого пользователя
      "flow": "xtls-rprx-vision"    // рекомендуется для Reality — лучший обход DPI
    }
  ],

  "tls": {
    "enabled": true,
    "server_name": "www.microsoft.com",  // SNI — под что маскируемся
    "reality": {
      "enabled": true,
      "handshake": {
        "server": "www.microsoft.com",   // реальный сервер, которому проксируется хендшейк
        "server_port": 443
      },
      "private_key": "<x25519-private>", // секретный ключ сервера, НЕ передаётся клиентам
      "short_id": [                      // список допустимых short_id клиентов
        "a1b2c3d4e5f6a7b8",              // основной (8 байт)
        "a1b2c3d4",                      // короткий (4 байта)
        "a1b2c3d4e5f6"                   // средний (6 байт)
      ]
    }
  }
}
```

> **Заметка о mux и xtls-rprx-vision**: эти два режима **несовместимы**. Vision-flow клиенты не используют multiplex. Если нужен mux (для клиентов без flow), добавьте отдельный inbound на другом порту без vision flow.

#### Блок `inbounds[1]` — SOCKS5 для бота

```json
{
  "type": "socks",
  "tag": "socks-bot",
  "listen": "127.0.0.1",  // только локально — снаружи недоступен
  "listen_port": 1080
}
```

#### Блок `route`

```json
"route": {
  "rules": [
    {
      "ip_is_private": true,  // блокировать запросы в приватные сети (SSRF-защита)
      "outbound": "block"
    }
  ],
  "final": "direct"           // всё остальное — напрямую в интернет
}
```

### 4.2. singbox.service

Файл: [`systemd/singbox.service`](../systemd/singbox.service)

```ini
[Unit]
Description=Sing-box VPN Service (VLESS+Reality)
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID  # graceful reload без обрыва соединений
Restart=on-failure
RestartSec=5s
LimitNOFILE=524288   # поднятые лимиты для множества одновременных соединений

[Install]
WantedBy=multi-user.target
```

### 4.3. Варианты server_name

| server_name | Оценка | Комментарий |
|-------------|--------|-------------|
| `www.microsoft.com` | ⭐⭐⭐⭐⭐ | Топ-1 по трафику, высокое доверие, стабильный TLS |
| `www.apple.com` | ⭐⭐⭐⭐⭐ | Чистый TLS fingerprint, высокое доверие |
| `www.amazon.com` | ⭐⭐⭐⭐ | Огромный трафик, редко под подозрением |
| `addons.mozilla.org` | ⭐⭐⭐⭐ | Надёжный, умеренный трафик |
| `www.lovelive-anime.jp` | ⭐⭐⭐ | Популярен в сообществе, но нишевый |

---

## 5. Развёртывание и запуск

### Проверка статуса

```bash
systemctl status singbox
journalctl -u singbox -f
```

### Ручная установка без deploy.sh

```bash
# 1. Установить sing-box
bash scripts/install-singbox.sh

# 2. Сгенерировать ключи и конфиг
bash scripts/generate-keys.sh

# 3. Проверить конфиг
sing-box check -c /etc/sing-box/config.json

# 4. Установить systemd-сервис
cp systemd/singbox.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now singbox

# 5. Настроить firewall
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 443/tcp
ufw --force enable
```

### Проверка соединения с клиента

1. Импортировать vless:// ссылку в Hiddify или v2rayN
2. Подключиться
3. Открыть `https://2ip.ru` — должен показывать IP сервера `77.73.135.202`

---

## 6. Раздача доступа пользователям

### Показать ссылки и QR-коды

```bash
bash /opt/vpn_proxy_aeza/scripts/show-links.sh
```

### Добавить нового пользователя

```bash
bash /opt/vpn_proxy_aeza/scripts/add-user.sh <имя>

# Пример:
bash /opt/vpn_proxy_aeza/scripts/add-user.sh katya
```

Скрипт:
- Генерирует новый UUID
- Добавляет пользователя в `/etc/sing-box/config.json`
- Делает `systemctl reload singbox` без обрыва соединений
- Показывает vless:// ссылку и QR-код

### Формат vless:// ссылки

```
vless://<UUID>@77.73.135.202:443
  ?security=reality
  &sni=www.microsoft.com       ← server_name (SNI)
  &fp=chrome                   ← uTLS fingerprint Chrome
  &pbk=<PUBLIC_KEY>            ← public key (не секрет)
  &sid=<SHORT_ID>              ← short ID (8 hex-символов)
  &flow=xtls-rprx-vision       ← flow для лучшего обхода DPI
  &type=tcp
  #VPN-username                ← отображаемое имя
```

### Удалить пользователя

```bash
jq 'del(.inbounds[0].users[] | select(.name == "username"))' \
    /etc/sing-box/config.json > /tmp/cfg.json \
    && mv /tmp/cfg.json /etc/sing-box/config.json

systemctl reload singbox
```

---

## 7. Интеграция с Telegram-ботом

### Вариант A: бот на том же VPS (рекомендуется)

Бот использует `127.0.0.1:1080` (SOCKS5) напрямую.

```bash
# Установить зависимости бота
apt install -y python3 python3-pip redis-server
pip3 install aiogram arq aiohttp-socks

# Запустить Redis
systemctl enable --now redis-server
```

Переменные окружения бота:

```bash
# /etc/bot/.env
PROXY_URL=socks5://127.0.0.1:1080
REDIS_URL=redis://127.0.0.1:6379
```

Настройка aiohttp-сессии в боте:

```python
from aiohttp_socks import ProxyConnector

connector = ProxyConnector.from_url("socks5://127.0.0.1:1080")
session = aiohttp.ClientSession(connector=connector)
```

Проверка SOCKS5:

```bash
curl --socks5 127.0.0.1:1080 https://api.telegram.org
# Ожидаемый ответ: {"ok":false,"error_code":404,...}  (это нормально — значит доступен)
```

Systemd-сервис для бота:

```ini
# /etc/systemd/system/bot.service
[Unit]
Description=Silent Couple Bot
After=network.target singbox.service redis.service

[Service]
User=bot
WorkingDirectory=/opt/silent-couple-bot
EnvironmentFile=/etc/bot/.env
ExecStart=/usr/bin/python3 -m bot
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

### Вариант B: бот на Timeweb, selective routing

На сервере Timeweb установить sing-box как **клиент** с маршрутизацией только для `api.telegram.org` и `*.telegram.org` через VPS.

```json
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "vpn-out",
      "server": "77.73.135.202",
      "server_port": 443,
      "uuid": "<UUID бота>",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {
          "enabled": true,
          "public_key": "<PUBLIC_KEY>",
          "short_id": "<SHORT_ID>"
        }
      }
    },
    {"type": "direct", "tag": "direct"}
  ],
  "route": {
    "rules": [
      {
        "domain_suffix": [".telegram.org", "telegram.org"],
        "outbound": "vpn-out"
      }
    ],
    "final": "direct"
  }
}
```

---

## 8. Ротация ключей

### Плановая ротация (раз в 3 месяца)

```bash
# Ротация short_id
bash /opt/vpn_proxy_aeza/scripts/rotate.sh --short-id

# Смена server_name
bash /opt/vpn_proxy_aeza/scripts/rotate.sh --server-name www.apple.com

# Всё сразу
bash /opt/vpn_proxy_aeza/scripts/rotate.sh --all
```

### Когда менять

| Событие | Действие |
|---------|---------|
| Замедление соединений | Сменить `server_name` |
| Сброс соединений / ошибки TLS | Сменить `short_id` |
| Жалобы нескольких пользователей | Сменить оба |
| Компрометация UUID пользователя | Удалить пользователя, создать нового |
| Плановая ротация | Каждые 3 месяца: `--all` |

### Что сделать после ротации short_id

Разослать пользователям новые ссылки:
```bash
bash /opt/vpn_proxy_aeza/scripts/show-links.sh
# Скопировать ссылки из /root/vpn-backup/vless-links.txt
cat /root/vpn-backup/vless-links.txt
```

---

## 9. Резервное копирование и восстановление

### Что сохраняется

| Что | Путь |
|-----|------|
| Конфиг Sing-box | `/etc/sing-box/config.json` |
| Ключи, UUID, ссылки | `/root/vpn-backup/credentials.json` |
| QR-коды пользователей | `/root/vpn-backup/qr-*.png` |
| vless:// ссылки | `/root/vpn-backup/vless-links.txt` |
| Redis dump (если есть) | `/var/lib/redis/dump.rdb` |

### Ручной бэкап

```bash
bash /opt/vpn_proxy_aeza/scripts/backup.sh
ls /root/backups/daily/
```

### Автобэкап (настраивается в deploy.sh)

```
0 2 * * * bash /opt/vpn_proxy_aeza/scripts/backup.sh >> /var/log/vpn-backup.log 2>&1
```

Ретенция: **7 ежедневных** + **4 еженедельных** бэкапа.

### Полное восстановление с нуля (≤ 20 минут)

```bash
# 1. Войти на новый сервер
ssh root@<NEW_IP>

# 2. Установить git
apt update && apt install -y git

# 3. Клонировать репозиторий
git clone https://github.com/Den20050/vpn_proxy_aeza /opt/vpn_proxy_aeza

# 4. Скопировать бэкап с локальной машины или старого сервера
scp /root/backups/daily/YYYY-MM-DD/vpn-backup-YYYY-MM-DD.tar.gz root@<NEW_IP>:/root/
ssh root@<NEW_IP> "tar -xzf /root/vpn-backup-*.tar.gz -C /"

# 5. Запустить деплой (ключи уже восстановлены из бэкапа)
cd /opt/vpn_proxy_aeza
bash scripts/install-singbox.sh
cp systemd/singbox.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now singbox

# 6. Настроить firewall
ufw default deny incoming && ufw allow 22/tcp && ufw allow 443/tcp && ufw --force enable

# 7. Проверить
systemctl status singbox
bash scripts/show-links.sh
```

> Если IP изменился — запустить `generate-keys.sh` повторно (ссылки изменятся) или обновить IP вручную в `/root/vpn-backup/credentials.json`.

---

## 10. Мониторинг, обслуживание и безопасность

### Метрики и целевые показатели

| Метрика | Цель | Критический порог |
|---------|------|-------------------|
| Uptime | ≥ 99% | < 95% → расследование |
| RTT (клиент → сервер) | ≤ 80 мс | > 200 мс → смена `server_name` |
| RAM (sing-box + бот + Redis) | ≤ 1.5 ГБ | > 1.8 ГБ → оптимизация |
| CPU idle в покое | ≥ 60% | < 30% → расследование |

### Команды мониторинга

```bash
# Статус сервиса
systemctl status singbox

# Логи в реальном времени
journalctl -u singbox -f

# Последние 100 строк логов
journalctl -u singbox -n 100 --no-pager

# RAM и CPU
htop
free -h

# Текущие соединения
ss -tnp | grep sing-box

# Трафик в реальном времени (установить: apt install iftop)
iftop -i ens3

# Статистика трафика по дням (установить: apt install vnstat)
vnstat
vnstat -d
```

### Безопасность

```bash
# Проверить открытые порты
ufw status verbose
ss -tlnp

# Проверить логи входа
journalctl _SYSTEMD_UNIT=ssh.service -n 50

# Отключить авторизацию по паролю (только ключи)
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl reload sshd

# Автоматические security-обновления
dpkg -l | grep unattended-upgrades
systemctl status unattended-upgrades
```

### Управление пользователями

```bash
# Список пользователей в конфиге
jq '.inbounds[0].users[] | {name, uuid}' /etc/sing-box/config.json

# Добавить пользователя
bash /opt/vpn_proxy_aeza/scripts/add-user.sh <name>

# Удалить пользователя (имя точное)
jq 'del(.inbounds[0].users[] | select(.name == "name"))' \
    /etc/sing-box/config.json | sponge /etc/sing-box/config.json
systemctl reload singbox
```

### Обновление Sing-box

```bash
# Проверить, есть ли обновление, и установить
bash /opt/vpn_proxy_aeza/scripts/update-singbox.sh
```

### План апгрейда при росте пользователей

| Пользователей | Действие |
|--------------|---------|
| 10–15 | Текущая конфигурация |
| 15–25 | Мониторить RAM; перейти на тариф с 4 ГБ RAM если > 1.8 ГБ |
| 25–50 | Апгрейд до 2 ядер / 4 ГБ; рассмотреть выделенный VPS для бота |
| 50+ | Несколько серверов + балансировка нагрузки |

---

## 11. Runbook: действия при блокировках

### Сценарий 1: Замедление / нестабильные соединения

```bash
# 1. Проверить логи
journalctl -u singbox -n 100

# 2. Проверить RTT
ping -c 10 www.microsoft.com
mtr --report 77.73.135.202

# 3. Сменить server_name на резервный
bash /opt/vpn_proxy_aeza/scripts/rotate.sh --server-name www.apple.com

# 4. Если не помогло — сменить оба
bash /opt/vpn_proxy_aeza/scripts/rotate.sh --all
# Разослать пользователям новые ссылки из /root/vpn-backup/vless-links.txt
```

### Сценарий 2: Полная недоступность (IP заблокирован)

```bash
# 1. Подтвердить блокировку с другой машины
curl -m 5 https://77.73.135.202:443  # должен timeout

# 2. Уведомить пользователей по резервному каналу (email / другой мессенджер)

# 3. Поднять новый VPS у Aeza (другой IP)

# 4. Восстановить из бэкапа (см. раздел 9)

# 5. Разослать новые vless:// ссылки (IP в ссылке изменится)
bash /opt/vpn_proxy_aeza/scripts/generate-keys.sh  # пересоздаст ссылки с новым IP
bash /opt/vpn_proxy_aeza/scripts/show-links.sh
```

### Сценарий 3: Перегрузка сервера (OOM / CPU 100%)

```bash
# 1. Найти источник нагрузки
htop
journalctl -u singbox -n 50

# 2. Проверить количество соединений
ss -tnp | grep sing-box | wc -l

# 3. Мягкий перезапуск
systemctl reload singbox

# 4. Если не помогло — жёсткий перезапуск
systemctl restart singbox

# 5. Долгосрочно: апгрейд тарифа
```

### Сценарий 4: Telegram-бот не отправляет сообщения

```bash
# 1. Проверить доступность SOCKS5
curl --socks5 127.0.0.1:1080 --max-time 5 https://api.telegram.org
# Ожидаемый HTTP-код: 400 или 404 (не timeout!)

# 2. Проверить sing-box
systemctl status singbox
journalctl -u singbox -n 20

# 3. Проверить Redis
redis-cli ping  # должен ответить: PONG

# 4. Проверить arq worker
systemctl status bot-worker
journalctl -u bot-worker -n 20

# 5. Проверить, что бот использует SOCKS5
grep -r "PROXY_URL\|socks5" /opt/silent-couple-bot/
```

---

## 12. Список полезных команд

### Управление сервисом

```bash
systemctl start singbox          # запустить
systemctl stop singbox           # остановить
systemctl restart singbox        # перезапустить (обрывает соединения)
systemctl reload singbox         # graceful reload (без обрыва)
systemctl status singbox         # статус
systemctl is-active singbox      # active / inactive
journalctl -u singbox -f         # логи в реальном времени
journalctl -u singbox -n 100     # последние 100 строк
```

### Конфиг

```bash
sing-box version                                    # версия
sing-box check -c /etc/sing-box/config.json         # проверить конфиг
cat /etc/sing-box/config.json | jq .                # посмотреть конфиг
jq '.inbounds[0].users' /etc/sing-box/config.json  # список пользователей
```

### Пользователи

```bash
bash scripts/show-links.sh           # показать все ссылки + QR
bash scripts/add-user.sh <name>      # добавить пользователя
bash scripts/rotate.sh --short-id    # ротация short_id
bash scripts/rotate.sh --all         # ротация short_id + server_name
cat /root/vpn-backup/vless-links.txt # все ссылки текстом
cat /root/vpn-backup/credentials.json | jq .  # полные credentials
```

### Обслуживание

```bash
bash scripts/update-singbox.sh    # обновить sing-box
bash scripts/backup.sh            # ручной бэкап
ls /root/backups/daily/           # список бэкапов
```

### Сеть и мониторинг

```bash
ufw status verbose                # статус firewall
ss -tnp | grep sing-box           # текущие соединения
htop                              # CPU/RAM в реальном времени
free -h                           # память
df -h                             # диск
vnstat -d                         # трафик по дням
iftop -i ens3                     # трафик в реальном времени
```

### Диагностика

```bash
# Проверить доступность SOCKS5 локально
curl --socks5 127.0.0.1:1080 https://api.telegram.org

# Проверить ping до server_name
ping -c 5 www.microsoft.com

# Проверить трассировку
mtr --report 8.8.8.8

# Проверить SSL на server_name
openssl s_client -connect www.microsoft.com:443 -servername www.microsoft.com </dev/null 2>&1 | head -20
```

---

*Документ сгенерирован автоматически. Версия 1.0, апрель 2026.*
