# 3xui-postgresql-workflow

Ansible-пайплайн для деплоя 3x-ui с PostgreSQL и fail2ban на production-сервере.

- Домен: `power.randomain.space`
- IP: `2.27.23.76`
- СУБД: PostgreSQL (вместо SQLite)
- CI/CD: GitHub Actions (manual workflow_dispatch)

## Быстрый старт

### Локальный деплой

```bash
# Установить зависимости
pip install ansible

# Деплой (полный)
XUI_ADMIN_USERNAME=... XUI_ADMIN_PASSWORD=... XUI_PANEL_BASE_PATH=... XUI_DB_PASSWORD=... \
  ansible-playbook playbooks/site.yml

# Только обновление
ansible-playbook playbooks/site.yml --tags update

# Проверка синтаксиса
ansible-playbook --syntax-check playbooks/site.yml
```

### GitHub Actions

1. Добавить Secrets в репозиторий:
   - `ANSIBLE_DEPLOY_KEY` — приватный SSH-ключ
   - `XUI_ADMIN_USERNAME` — логин панели
   - `XUI_ADMIN_PASSWORD` — пароль панели (≥16 символов)
   - `XUI_PANEL_BASE_PATH` — базовый путь панели (≥16 символов)
   - `XUI_DB_PASSWORD` — пароль БД PostgreSQL

2. Запустить workflow: Actions → Deploy 3x-ui + PostgreSQL → Run workflow

## SSH-подключение к серверу

```bash
ssh -i ./.secrets/ssh/ansible_deploy_key root@2.27.23.76
```

Системные таймауты:

```bash
ssh -i ./.secrets/ssh/ansible_deploy_key \
    -o ConnectTimeout=8 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    root@2.27.23.76
```

## Скрипты

### SSH-туннель к панели

```bash
./scripts/tunnel.sh
./scripts/tunnel.sh start
./scripts/tunnel.sh status
./scripts/tunnel.sh stop
```

### Обновление 3x-ui

```bash
./scripts/update-3x-ui.sh
./scripts/update-3x-ui.sh --latest
./scripts/update-3x-ui.sh --version 3.2.0 --yes
```

### Полный бэкап и восстановление (DR)

Подробно: [docs/backup-restore.md](docs/backup-restore.md).

```bash
# Создать полный бэкап (3x-ui + SNI Manager + PostgreSQL) в vpnServerFullBackups/
./scripts/backup-full.sh
./scripts/backup-full.sh --keep 10          # хранить последние 10
./scripts/backup-full.sh --list             # показать бэкапы

# Восстановить из бэкапа (поверх развёрнутого через Ansible сервера)
./scripts/restore-full.sh vpnServerFullBackups/3xui-full-<timestamp>.tar.gz.gpg
./scripts/restore-full.sh <archive> --host NEW_IP   # на новый сервер
./scripts/restore-full.sh <archive> --show-manifest # посмотреть содержимое
```

Архивы шифруются GPG (AES-256). Каталог `vpnServerFullBackups/` в `.gitignore`.

### Переключение режима доступа панели (server-side)

```bash
ssh -i ./.secrets/ssh/ansible_deploy_key root@2.27.23.76 "/usr/local/sbin/3xui-panel-access-switch.sh"
ssh -i ./.secrets/ssh/ansible_deploy_key root@2.27.23.76 "/usr/local/sbin/3xui-panel-access-switch.sh --mode tunnel"
ssh -i ./.secrets/ssh/ansible_deploy_key root@2.27.23.76 "/usr/local/sbin/3xui-panel-access-switch.sh --mode direct"
```

## Архитектура

### Роли Ansible

| Роль | Назначение |
|---|---|
| `system` | Hardening ОС: пакеты, sysctl, UFW, chrony, SSH, unattended-upgrades |
| `postgresql` | Установка PostgreSQL, создание БД `xui` и пользователя |
| `xui` | 3x-ui с PostgreSQL: установка, сертификаты, backup, port-sync |
| `fail2ban` | fail2ban через 3x-ui CLI: sshd, recidive, панель |
| `sni_manager` | SNI Manager для ротации REALITY |

### PostgreSQL вместо SQLite

- 3x-ui настраивается на PostgreSQL через CLI: `x-ui setting -dbType postgres -dbHost 127.0.0.1 -dbPort 5432 -dbName xui -dbUser xui -dbPassword ...`
- Backup включает `pg_dump` (custom format)
- Скрипт переключения режима доступа использует `psql` вместо `sqlite3`
- XRAY-policy применяется через `psql`

### Компоненты безопасности

- UFW с минимальным набором открытых TCP-портов
- Fail2ban для sshd, recidive и логов панели 3x-ui
- Unattended-upgrades, apt-listchanges и needrestart
- Chrony для синхронизации времени
- TCP-оптимизация: BBR + fq + расширенные буферы
- Панель слушает только 127.0.0.1, доступ через SSH-туннель
- PostgreSQL как основная СУБД
- Ежедневный backup с retention 14 дней

## Структура проекта

```
3xui-postgresql-workflow/
├── .github/workflows/deploy.yml    # GitHub Actions workflow
├── .secrets/ssh/                    # SSH-ключи (gitignored)
├── ansible.cfg
├── inventories/prod/
│   ├── hosts.yml
│   └── group_vars/all.yml
├── playbooks/site.yml               # Основной playbook
├── roles/
│   ├── system/                      # Hardening ОС
│   ├── postgresql/                  # PostgreSQL
│   ├── xui/                         # 3x-ui
│   ├── fail2ban/                    # fail2ban
│   └── sni_manager/                # SNI Manager
├── scripts/
│   ├── tunnel.sh
│   ├── check-dns.sh
│   ├── update-3x-ui.sh
│   ├── backup-full.sh                   # Полный бэкап сервера (GPG-шифрование)
│   └── restore-full.sh                  # Восстановление из бэкапа (DR)
├── vpnServerFullBackups/              # Архивы бэкапов (gitignored, НЕ коммитить)
└── data/sni/reality-sni.txt
```
