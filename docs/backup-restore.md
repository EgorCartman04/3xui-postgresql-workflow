# Резервное копирование и восстановление VPN-сервера

Полный DR (Disaster Recovery) для инфраструктуры 3x-ui + SNI Manager + PostgreSQL.

## Обзор

Два локальных скрипта управляют полным бэкапом и восстановлением сервера:

| Скрипт | Назначение |
|---|---|
| `scripts/backup-full.sh` | Собирает все stateful-данные с сервера, шифрует GPG, сохраняет локально |
| `scripts/restore-full.sh` | Восстанавливает сервер из бэкапа (DR на новый или переустановленный сервер) |

Архивы сохраняются в `vpnServerFullBackups/` (в `.gitignore`, **не коммитить**).

## Что входит в полный бэкап

| Компонент | Путь на сервере | Зачем нужно |
|---|---|---|
| **Дамп БД xui** | `pg_dump -Fc` | Пользователи VPN, inbound'ы, Reality-ключи, настройки панели, подписки |
| **Конфиг 3x-ui** | `/etc/x-ui/` | Бинарные настройки панели (если есть) |
| **config.json панели** | `/usr/local/x-ui/bin/config.json` | Runtime-конфиг панели |
| **SNI Manager config** | `/etc/3x-ui-manager/` | `config.json`, `reality-sni.txt` |
| **SNI Manager state** | `/var/lib/3x-ui-manager/state.json` | История ротации Reality SNI |
| **Override fail2ban** | `/etc/fail2ban/jail.d/zz-3x-ui-manager.local` | Runtime jail-настройки из UI менеджера |
| **Аудит расписания** | (внутри архива) | `systemctl list-timers`, `crontab -l`, `ufw status`, версии сервисов |

### Что НЕ входит в бэкап (развёртывается Ansible)

Эти компоненты выпускаются/устанавливаются заново через `ansible-playbook playbooks/site.yml` и в бэкап не попадают:

- **Сертификаты TLS и acme.sh** — выпускаются заново через acme.sh при деплое
- Бинарник 3x-ui (скачивается из GitHub-релиза)
- Системные пакеты (postgresql, fail2ban, ufw, chrony, ...)
- sysctl/UFW/SSH hardening-конфиги
- Базовые jail-шаблоны fail2ban
- systemd unit-файлы и timers
- Server-side скрипты (`3x-ui-backup.sh`, `3xui-panel-access-switch.sh`, ...)

## Безопасность

Архив содержит **критичные секреты**: дамп всех VPN-пользователей с Reality-ключами, пароль PostgreSQL.

- **Шифрование**: по умолчанию архив шифруется симметричным GPG (AES-256).
- **Каталог в .gitignore**: `vpnServerFullBackups/` никогда не попадёт в git.
- **Пароль БД не нужен локально**: backup-скрипт извлекает его с сервера из `/etc/default/xui`.
- **Пароль GPG**: задаётся через `XUI_BACKUP_GPG_PASSPHRASE` или вводится интерактивно.

## Использование

### Создание бэкапа

```bash
# Интерактивный ввод пароля GPG
./scripts/backup-full.sh

# Пароль через env (для автоматизации)
XUI_BACKUP_GPG_PASSPHRASE="секрет" ./scripts/backup-full.sh

# Хранить только последние 10 архивов
./scripts/backup-full.sh --keep 10

# Посмотреть имеющиеся бэкапы
./scripts/backup-full.sh --list

# Без шифрования (ТОЛЬКО отладка, ОПАСНО)
./scripts/backup-full.sh --no-encrypt
```

**Результат**: `vpnServerFullBackups/3xui-full-<timestamp>.tar.gz.gpg` + sidecar `.meta.json` (без секретов, для listing).

### Просмотр содержимого архива (без распаковки на сервер)

```bash
# Показать манифест
./scripts/restore-full.sh vpnServerFullBackups/3xui-full-20260702-120000.tar.gz.gpg --show-manifest

# Список файлов внутри (после ввода пароля)
XUI_BACKUP_GPG_PASSPHRASE="..." gpg -d vpnServerFullBackups/3xui-full-*.tar.gz.gpg | tar -tzf -
```

## Восстановление (Disaster Recovery)

### Сценарий A: тот же сервер (данные повреждены/утеряны)

```bash
# 1. Сервер уже развёрнут через Ansible (чистая установка)
#    Если нет — разверни:
XUI_ADMIN_USERNAME=... XUI_ADMIN_PASSWORD=... \
  XUI_PANEL_BASE_PATH=... XUI_DB_PASSWORD=... \
  ansible-playbook playbooks/site.yml

# 2. Восстанови данные из бэкапа
./scripts/restore-full.sh vpnServerFullBackups/3xui-full-<timestamp>.tar.gz.gpg

# 3. Проверь панель
./scripts/tunnel.sh status
```

### Сценарий B: новый сервер (IP сменился)

```bash
# 1. Обнови IP и/или домен в inventory
#    inventories/prod/group_vars/all.yml:
#      xui_server_ip: "НОВЫЙ_IP"
#      xui_domain: "новый.домен"   # если сменился

# 2. Настрой DNS: домен должен резолвиться в новый IP

# 3. Разверни сервер с нуля
XUI_ADMIN_USERNAME=... XUI_ADMIN_PASSWORD=... \
  XUI_PANEL_BASE_PATH=... XUI_DB_PASSWORD=... \
  ansible-playbook playbooks/site.yml

# 4. Восстанови данные, указав новый IP
./scripts/restore-full.sh vpnServerFullBackups/3xui-full-<timestamp>.tar.gz.gpg \
  --host "НОВЫЙ_IP"

# Сертификаты TLS и acme.sh восстанавливать из бэкапа не нужно —
# они выпускаются заново через Ansible на шаге 3.
```

### Что делает restore-скрипт

1. **Расшифровывает** архив локально (GPG).
2. **Загружает** архив на сервер по SCP.
3. **Останавливает** `x-ui` и `3x-ui-manager`.
4. **Пересоздаёт БД**: `DROP DATABASE xui; CREATE DATABASE xui;` затем `pg_restore`.
5. **Распаковывает**: config 3x-ui, config/state SNI Manager, override fail2ban.
6. **Восстанавливает права** (owner root, корректные mode).
7. **Перезапускает** сервисы и проверяет здоровье (`systemctl is-active`).

### Предварительные проверки restore-скрипта

Скрипт откажется работать, если на сервере не выполнен Ansible-деплой:
- `/etc/default/x-ui` существует (env-файл панели)
- `/usr/local/x-ui/x-ui` исполняемый
- `x-ui.service` и `3x-ui-manager.service` зарегистрированы в systemd
- PostgreSQL установлен и готов (`pg_isready`)
- `psql` доступен

## Рекомендации

### Частота бэкапов

- **Ручной полный бэкап** перед любыми рискованными операциями (обновление 3x-ui, миграции).
- **Регулярный бэкап**: сервер уже имеет ежедневный `3x-ui-backup.timer` (на самом сервере, retention 14 дней), но он хранит бэкапы локально на сервере и теряется вместе с ним.
- Полный локальный бэкап (`backup-full.sh`) рекомендуется делать **не реже раза в неделю** и обязательно перед обновлениями.

### Хранение пароля GPG

Пароль GPG — единственное, что отделяет архив от компрометации всех VPN-пользователей. Рекомендации:
- Храни пароль в менеджере паролей (1Password, Bitwarden, KeePassXC).
- **Не храни** пароль в том же репозитории или на том же диске, что и архивы.
- Сделай тестовое восстановление на пустой сервер хотя бы раз — чтобы убедиться, что связка «архив + пароль» рабочая.

### Тестирование восстановления

Рекомендуется периодически (раз в квартал) выполнять восстановление на тестовый сервер для проверки целостности бэкапов.

### Retention

По умолчанию хранится 14 последних архивов (`--keep 14`). Каждый архив содержит полный дамп, поэтому 14 копий ≈ 14 дней ежедневных бэкапов при ручном запуске.
