# Deployment Guide

## GitHub Secrets

Для работы пайплайна необходимо добавить следующие секреты в репозиторий (Settings → Secrets and variables → Actions):

| Secret | Описание |
|---|---|
| `ANSIBLE_DEPLOY_KEY` | Приватный SSH-ключ для доступа к серверу |
| `XUI_ADMIN_USERNAME` | Логин администратора панели 3x-ui |
| `XUI_ADMIN_PASSWORD` | Пароль администратора (≥16 символов) |
| `XUI_PANEL_BASE_PATH` | Базовый URL-путь панели (≥16 символов) |
| `XUI_DB_PASSWORD` | Пароль пользователя PostgreSQL `xui` |

## Порядок деплоя

### Первичная установка (full)

1. Убедиться, что DNS `adv.randomain.space` указывает на `2.26.230.90`
2. Запустить workflow в режиме `full`
3. Дождаться успешного завершения всех шагов

### Обновление существующей установки (update)

1. Запустить workflow в режиме `update`
2. При необходимости указать конкретную версию 3x-ui

## Доступ к панели

Панель 3x-ui слушает только на `127.0.0.1:24443`. Доступ через SSH-туннель:

```bash
./scripts/tunnel.sh
```

После запуска будут напечатаны URL для доступа к панели и SNI Manager.

## PostgreSQL

- Пользователь БД: `xui`
- База данных: `xui`
- Подключение: `localhost:5432`
- Пароль хранится в GitHub Secrets (`XUI_DB_PASSWORD`)

### Ручное подключение к БД

```bash
ssh -i ./.secrets/ssh/ansible_deploy_key root@2.26.230.90
sudo -u postgres psql -d xui
```

## Откат

1. Запустить workflow с указанием предыдущей версии 3x-ui в поле `xui_version`
2. Или восстановить из backup:
   ```bash
   ssh -i ./.secrets/ssh/ansible_deploy_key root@2.26.230.90
   ls /var/backups/3x-ui/
   # Восстановить нужный архив вручную
   ```
