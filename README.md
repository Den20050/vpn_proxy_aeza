# vpn_proxy_aeza

Production VPN-сервер: **Sing-box + VLESS + Reality** на Ubuntu 22.04.  
Устойчив к блокировкам РКН/ТСПУ. Один скрипт — полный деплой.

## Быстрый старт

```bash
# На сервере (root):
git clone https://github.com/Den20050/vpn_proxy_aeza /opt/vpn_proxy_aeza
cd /opt/vpn_proxy_aeza
bash scripts/deploy.sh
```

## Структура

```
├── config/
│   ├── config.json.template     # Шаблон конфига Sing-box
│   └── failover-endpoints.json    # SNI + порты для failover
├── systemd/
│   └── singbox.service          # systemd unit
├── scripts/
│   ├── deploy.sh                # Полный деплой с нуля
│   ├── install-singbox.sh       # Установка / обновление бинарника
│   ├── generate-keys.sh         # Генерация ключей + создание config.json
│   ├── add-user.sh              # Добавить пользователя
│   ├── show-links.sh            # Показать vless:// ссылки + QR
│   ├── rotate.sh                # Ротация short_id / server_name
│   ├── enable-failover.sh       # Multi-SNI failover на существующем сервере
│   ├── generate-client-config.sh # Клиентский sing-box с urltest
│   ├── backup.sh                # Резервное копирование
│   ├── update-singbox.sh        # Обновить sing-box до latest
│   └── lib/
│       └── failover-common.sh   # Общая логика failover
└── docs/
    └── VPN_Singbox_Deployment_Guide.md  # Полная документация
```

## Требования

- Ubuntu 22.04 LTS
- 1+ ядро CPU, 512 МБ+ RAM (оптимально: 1 ядро / 2 ГБ)
- Root-доступ

## Параметры деплоя

```bash
NUM_USERS=5 \
USER_NAMES="alice,bob,carol,dave,eve" \
SERVER_NAME="www.apple.com" \
bash scripts/deploy.sh
```

| Переменная | По умолчанию | Описание |
|-----------|--------------|---------|
| `NUM_USERS` | `3` | Количество пользователей |
| `USER_NAMES` | `user1,user2,...` | Имена через запятую |
| `SERVER_NAME` | `www.debian.org` | Primary SNI (при failover берётся из endpoints[0]) |
| `ENABLE_FAILOVER` | `1` | 6 SNI (debian primary + RF-friendly + microsoft backup) |

## Failover (автосмена SNI)

```bash
bash scripts/enable-failover.sh              # на уже работающем сервере
bash scripts/generate-client-config.sh user1 # конфиг для sing-box / Hiddify
```

## Управление пользователями

```bash
bash scripts/add-user.sh <name>    # добавить
bash scripts/show-links.sh         # показать ссылки + QR
bash scripts/rotate.sh --all       # сменить short_id и server_name
```

## Документация

Полная инструкция по установке, конфигурации, мониторингу и runbook на случай блокировок:  
[docs/VPN_Singbox_Deployment_Guide.md](docs/VPN_Singbox_Deployment_Guide.md)
