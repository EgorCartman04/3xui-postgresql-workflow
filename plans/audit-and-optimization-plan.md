# План: Аудит и оптимизация 3xui-postgresql-workflow

Статус: готов к реализации
Дата аудита: 2026-06-24
Полный объём аудита: CRITICAL + HIGH + MEDIUM + LOW
**Текущая реализация (этот заход): только CRITICAL + HIGH = задачи 1–5.**
Задачи 6–11 (MEDIUM/LOW) — вне текущего захода, остаются в плане на будущее.

## Контекст

Аудит production-репозитория Ansible-деплоя 3x-ui с PostgreSQL, fail2ban и SNI Manager.
Проект деплоит панель 3x-ui с hardening ОС, PostgreSQL (вместо SQLite), fail2ban и
SNI Manager для ротации REALITY. Найдены: критический баг импорта, утечки секретов,
мёртвый код, пробелы в CI/CD-харденинге и idempotency.

Положительные находки (не требуют правок): pg_hba настроен на scram-sha-256, панель
слушает только loopback, atomic write state.json через os.replace, timing-safe сравнение
пароля в SNI Manager, защита от неявного downgrade 3x-ui.

## Задачи

### CRITICAL

#### 1. Добавить `import sqlite3` в SNI Manager (чтение родной БД fail2ban)
- **Файл:** `roles/sni_manager/templates/3x-ui-manager.py.j2`
- **Суть:** В проекте две разные БД, их нельзя путать:
  - **Панель 3x-ui** (users, inbounds, settings) → **PostgreSQL** — основная СУБД, тут sqlite3 не нужен.
  - **Родной бэкенд fail2ban** (таблица `bips`, баны) → **sqlite3** по пути
    `/var/lib/fail2ban/fail2ban.sqlite3` (см. `all.yml:81`, комментарий автора:
    «fail2ban родная БД — sqlite3»). Это нативное хранилище fail2ban, его нельзя
    переключить на PostgreSQL.
- **Баг:** Функция `load_fail2ban_bans()` (строка 831) читает именно родную БД fail2ban
  через `sqlite3.connect(path)` (строка 835), но `import sqlite3` отсутствует в блоке
  импортов (строки 2-20). Функция вызывается из `build_status()` (строка 987) при каждом
  запросе `/` и `/api/status`. Поскольку fail2ban запущен, файл `.sqlite3` существует →
  выполнение доходит до `sqlite3.connect()` → `NameError`, UI SNI Manager падает.
- **Правка:** Добавить `import sqlite3` в блок импортов (строки 2-14), рядом с `import re`.
- **Валидация:** Рендер шаблона + `python3 -c "import ast; ast.parse(open('...').read())"` +
  проверка `python3 -c "import sqlite3"` на целевом хосте.

#### 1b. Миграция БД-ключей в runtime config.json SNI Manager (KeyError `'xui_db_name'` при логине)
- **Файл:** `roles/sni_manager/tasks/main.yml` (задача "Обновить путь runtime override fail2ban
  в существующем config.json", строки 135-142)
- **Симптом:** При логине в SNI Manager браузер выдаёт `{"error": "'xui_db_name'"}`.
- **Корневая причина (доказано git-историей):** Баг неполной миграции данных.
  - До коммита `ad36708` runtime `config.json` хранил один ключ `xui_db_path` (SQLite-файл).
  - Коммит `ad36708` заменил в **шаблоне** конфига `xui_db_path` на 6 PostgreSQL-ключей
    (`xui_db_type/host/port/name/user/password`) и обновил Python-код (`pg_connect` в
    `3x-ui-manager.py.j2:34` читает `config["xui_db_name"]`).
  - НО задача миграции runtime-конфига (`combine`, `main.yml:135-142`) переносит только
    `fail2ban_override_path`, `slots`, `tls`, `auth` — **БД-ключи в combine отсутствуют**.
  - Задача первичной инициализации шаблона (`:162`) имеет `when: not xui_manager_config_stat.stat.exists`
    и не запускается для уже существующего config.json.
  - → На production config.json остался в старом формате (с `xui_db_path`, **без** `xui_db_name`)
    → при логине `verify_xui_user_credentials` → `pg_connect` → `config["xui_db_name"]` →
    **KeyError `'xui_db_name'`**, который обработчик отдаёт как `{"error": "'xui_db_name'"}`.
  - Эта ошибка возникает **раньше** задачи 1: при попытке входа (auth), до загрузки статуса.
- **Правка:** Добавить 6 БД-ключей в combine-задачу миграции (`main.yml:135-142`), чтобы
  существующий config.json гарантированно получил PostgreSQL-ключи из inventory:
  ```yaml
  content: "{{ (xui_manager_runtime_config_raw.content | b64decode | from_json | combine({
    'fail2ban_override_path': xui_manager_fail2ban_override_path,
    'slots': {'ports': xui_manager_slot_ports, 'auto_provision': xui_manager_slot_auto_provision},
    'tls': {'enabled': true, 'cert_path': xui_panel_cert_dir ~ '/fullchain.pem', 'key_path': xui_panel_cert_dir ~ '/privkey.pem'},
    'auth': {'realm': '3x-ui SNI Manager', 'source': 'x-ui-users-db'},
    'xui_db_type': xui_db_type,
    'xui_db_host': xui_db_host,
    'xui_db_port': xui_db_port,
    'xui_db_name': xui_db_name,
    'xui_db_user': xui_db_user,
    'xui_db_password': xui_db_password
  }, recursive=True)) | to_nice_json }}\n"
  ```
- **Безопасность (связано с задачей 3):** Эта задача combine теперь содержит `xui_db_password`
  в content → обязательно `no_log: true` (входит в задачу 3).
- **Мёртвый ключ `xui_db_path`:** После миграции в config.json останется устаревший
  `xui_db_path` (combine не удаляет ключи). Python-код его не использует → безвредно.
  Удаление потребовало бы отдельной задачи; **не трогать** (YAGNI).
- **Валидация:** После деплоя — логин в SNI Manager через туннель работает (нет `KeyError`);
  на сервере `cat /etc/3x-ui-manager/config.json | jq .xui_db_name` возвращает `xui`.

### HIGH

#### 2. Исправить неверный IP в update-3x-ui.sh
- **Файл:** `scripts/update-3x-ui.sh`
- **Суть:** Строки 15 и 88 содержат `2.26.101.31` — устаревший/неверный IP. Корректный
  IP во всём проекте: `2.26.230.90` (inventories, README, tunnel.sh, CI). Ручное
  обновление 3x-ui ломается.
- **Правка:** Заменить `2.26.101.31` → `2.26.230.90` в строках 15 и 88.
- **Валидация:** `grep -rn "2.26.101.31" .` должен вернуть 0 совпадений (вне .git/.kilo).

#### 3. Добавить `no_log` на задачи с секретами
- **Файлы:**
  - `roles/postgresql/tasks/main.yml` (CREATE USER строка 87, ALTER USER строка 128)
  - `roles/xui/tasks/main.yml` (x-ui setting строки 147-163, PGPASSWORD строка 408)
  - `roles/xui/tasks/xray-policy.yml` (PGPASSWORD строка 10)
  - `roles/sni_manager/tasks/main.yml` (pg_dump с PGPASSWORD строка 56)
- **Суть:** Пароли БД и админ-пароль 3x-ui попадают в stdout Ansible и логи GitHub Actions.
- **Правка:** Добавить `no_log: true` на перечисленные задачи (shell/command, где в командной
  строке/окружении фигурируют `xui_db_password`, `xui_admin_password`).
- **Валидация:** Локальный прогон `ansible-playbook playbooks/site.yml --tags update --check`
  не должен выводить значения секретов.

#### 4. Проверка целостности acme.sh при установке (pin к тегу через переменную)
- **Файлы:**
  - `roles/xui/tasks/main.yml` (задача "Установить acme.sh на сервере", строка 278)
  - `inventories/prod/group_vars/all.yml` (добавить переменную)
- **Суть:** `xui/tasks/main.yml:278` качает
  `https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh` (ветка
  `master`) и выполняет `sh ./acme.sh --install --force` — RCE при компрометации
  upstream или MITM. Решение (выбрано пользователем): **pin к тегу релиза через переменную**.
- **Правка 1 — `inventories/prod/group_vars/all.yml`:** добавить переменную рядом с
  `xui_version` (строка ~14):
  ```yaml
  xui_acme_sh_version: "3.1.0"   # pinned тег acme.sh вместо ветки master
  ```
  (Реализатор: сверить актуальный стабильный тег на https://github.com/acmesh-official/acme.sh/releases
  и при необходимости заменить значение.)
- **Правка 2 — `roles/xui/tasks/main.yml:278`:** заменить `master` на тег из переменной:
  ```yaml
  curl -fSL https://raw.githubusercontent.com/acmesh-official/acme.sh/{{ xui_acme_sh_version }}/acme.sh -o "${tmp_acme_install_dir}/acme.sh"
  ```
- **Валидация:** Прогон задачи; убедиться, что URL содержит тег, а не `master`
  (`grep -n "acmesh-official/acme.sh" roles/xui/tasks/main.yml`); проверка существования
  URL: `curl -fsSIL .../<tag>/acme.sh` → 200.

#### 5. Добавить `timeout` в subprocess.run SNI Manager
- **Файл:** `roles/sni_manager/templates/3x-ui-manager.py.j2` (строка 196, `run_command`)
- **Суть:** `subprocess.run(args, capture_output=True, text=True, env=env)` без `timeout`
  → зависший `systemctl restart` / `fail2ban-client` / `pg_dump` вешает HTTP-поток навсегда.
- **Правка:** Добавить параметр `timeout=` (например 30) с обработкой
  `subprocess.TimeoutExpired` → raise RuntimeError. Опционально: принимать timeout
  аргументом в `run_command(args, check=True, env=None, timeout=30)`.
- **Валидация:** Рендер + `ast.parse`; unit-проверка что timeout передаётся.

### MEDIUM

#### 6. Удалить мёртвый дублированный код шаблонов fail2ban из роли xui
- **Файлы (удалить):**
  - `roles/xui/templates/jail-sshd.local.j2`
  - `roles/xui/templates/jail-recidive.local.j2`
  - `roles/xui/templates/jail-x-ui-admin.local.j2`
  - `roles/xui/templates/filter-x-ui-admin.conf.j2`
- **Суть:** 4 шаблона побайтово идентичны шаблонам роли `fail2ban/` и нигде не
  используются (роль `xui` не ссылается на них в tasks). Источник истины — роль `fail2ban`.
- **Правка:** Удалить 4 файла. Подтвердить отсутствие ссылок grep'ом перед удалением.
- **Валидация:** `grep -rn "jail-sshd\|jail-recidive\|jail-x-ui-admin\|filter-x-ui-admin" roles/xui/tasks/` → пусто.

#### 7. Ограничить размер `_read_json` в SNI Manager
- **Файл:** `roles/sni_manager/templates/3x-ui-manager.py.j2` (строки 1361-1364, `_read_json`)
- **Суть:** `Content-Length` читается без верхнего предела → DoS через огромный POST-body.
- **Правка:** Ввести константу `MAX_JSON_BODY` (например 1 MB = 1048576); если
  `length > MAX_JSON_BODY` — отвечать 413 и не читать тело.
- **Валидация:** Рендер + ast.parse.

#### 8. Расширить .gitignore для защиты секретов
- **Файл:** `.gitignore`
- **Суть:** Игнорируется только конкретный ключ `.secrets/ssh/ansible_deploy_key`. Любой
  новый секрет в `.secrets/` попадёт в коммит.
- **Правка:** Заменить узкое правило на `.secrets/` (игнорировать всю папку целиком).
  Добавить `vault-password.txt`, `*.vault`, `.vault` для надёжности.
- **Валидация:** `git check-ignore .secrets/ssh/ansible_deploy_key.pub` и тестовый файл
  в `.secrets/` должны игнорироваться.

#### 9. CI/CD hardening (deploy.yml)
- **Файл:** `.github/workflows/deploy.yml`
- **Суть:** actions не pinned по SHA; `ssh-keyscan` без проверки fingerprint (TOFU/MITM);
  нет `ansible-lint`; `pip install ansible` без версии.
- **Правки:**
  - Pin `actions/checkout@<sha>` вместо `@v4`.
  - Заменить `ssh-keyscan -H 2.26.230.90` на использование предзаписанного known_hosts
    через секрет `SSH_KNOWN_HOSTS` (ssh-keyscan -t ed25519 локально → GitHub Secret),
    либо pin публикного ключа. Минимум: добавить комментарий про риск TOFU.
  - Пиннинг версии ansible: `pip install ansible==<X.Y.Z>` (вынести версию в переменную).
  - Добавить шаг `ansible-lint` (с установкой) перед syntax-check.
- **Валидация:** Прогон workflow на ветке; проверка, что pinned SHA соответствует тегу.

### LOW

#### 10. Idempotency задачи `x-ui setting`
- **Файл:** `roles/xui/tasks/main.yml` (строки 146-163)
- **Суть:** `changed_when: true` → задача всегда «changed», даже если значения не изменились.
- **Правка:** Сравнивать текущие значения настроек (читать из БД/CLI) с целевыми и ставить
  `changed_when` на факт изменения. Альтернатива (проще): `changed_when: false` + rely на
  notify Restart x-ui (хотя restart нужен при изменении). Рекомендация: оставить notify,
  но изменить changed_when на условие проверки diff.
- **Валидация:** Двойной прогон `--check`; второй прогон должен показать changed=0 для этой задачи.

#### 11. PostgreSQL: sed → lineinfile/модули postgresql_*
- **Файлы:** `roles/postgresql/tasks/main.yml` (строки 33-55 — port, 100-114 — pg_hba,
  82-96 — CREATE USER/DB)
- **Суть:** `sed -i` правит postgresql.conf и pg_hba.conf хрупко; CREATE USER/DB через
  shell вместо модулей.
- **Правка (опционально, низкий приоритет):**
  - port: `ansible.builtin.lineinfile` с regexp вместо sed.
  - CREATE USER/DB: `community.postgresql.postgresql_user` / `postgresql_db` (требует
    коллекции). Либо оставить shell, но улучшить idempotency.
  - pg_hba: блок `lineinfile` или template для управляемой секции.
- **Примечание:** scram-sha-256 и логика ALTER USER после reload pg_hba реализованы корректно
  — не трогать порядок этих задач.
- **Валидация:** Двойной прогон; проверка idempotency.

## Риски и откат

- **Риск:** Правка шаблонов SNI Manager (задачи 1, 5, 7) меняет рендеримый Python на сервере.
  - **Митигация:** Перед деплоем — `ast.parse` рендера; staging-прогон; сохранение
    rollout-backup (роль sni_manager уже создаёт `xui_manager_rollout_backup_dir`).
- **Риск:** Удаление шаблонов fail2ban из роли xui (задача 6) может затронуть ссылки.
  - **Митигация:** grep перед удалением; роль fail2ban идёт после роли xui в site.yml и
    перезаписывает те же dest-пути — дубликат безопасно удаляется.
- **Откат:** Все правки — точечные коммиты по задачам. Откатить через `git revert <commit>`.
  БД не модифицируется правками (кроме деплоя). Перед каждым деплоем роль sni_manager
  делает pg_dump + rollout-backup артефактов.

## Порядок выполнения

### Текущий заход: CRITICAL + HIGH (задачи 1–5)

Рекомендуемая последовательность (атомарные коммиты по задачам):
1. Задачи 1 и 1b (CRITICAL — оба блокера UI SNI Manager: import sqlite3 + миграция БД-ключей).
2. Задача 2 (неверный IP — две строки в update-3x-ui.sh).
3. Задача 3 (no_log — безопасность, 4 файла; включает combine-задачу из 1b).
4. Задача 5 (subprocess timeout в SNI Manager).
5. Задача 4 (acme.sh pin через переменную `xui_acme_sh_version`).

### Будущее (вне текущего захода): MEDIUM + LOW (задачи 6–11)

6. Задачи 6, 8 (удаление мёртвого кода + .gitignore — тривиальные).
7. Задача 7 (JSON body limit).
8. Задача 9 (CI/CD hardening).
9. Задачи 10, 11 (LOW — по желанию).

## Реализация + деплой (текущий заход: задачи 1–5)

Порядок для implementation-агента:

1. **Ветвь:** от текущего default-бранча создать
   `git checkout -b fix/critical-high-hardening`.

2. **Правки (по списку выше):** задачи 1, 2, 3, 5, 4 — точечные правки в файлах.

3. **Локальная валидация перед деплоем (обязательно):**
   - `ansible-playbook --syntax-check playbooks/site.yml`
   - Рендер Python-шаблона и `python3 -m py_compile` / `ast.parse` (задачи 1, 5):
     `python3 -c "import jinja2 ..."` либо временно отрендерить и проверить синтаксис.
   - `grep -rn "2.26.101.31" .` → 0 (задача 2).
   - `grep -n "acmesh-official/acme.sh" roles/xui/tasks/main.yml` → тег, не `master` (задача 4).

4. **Коммит** с осмысленным сообщением (по конвенции репо).

5. **Деплой (production):**
   ```bash
   XUI_ADMIN_USERNAME=... XUI_ADMIN_PASSWORD=... XUI_PANEL_BASE_PATH=... XUI_DB_PASSWORD=... \
     ansible-playbook playbooks/site.yml --tags update
   ```
   Секреты передавать через env (локально) или GitHub Secrets (CI). Не коммитить секреты.

6. **Постдеплой-проверки:**
   - SNI Manager логин работает (задача 1b): через туннель вход в UI без `{"error": "'xui_db_name'"}`.
   - SNI Manager UI жив после логина (задача 1): `GET /api/status` не падает с NameError sqlite3.
     Локально: `./scripts/tunnel.sh status`.
   - На сервере: `cat /etc/3x-ui-manager/config.json | jq .xui_db_name` → `xui` (миграция 1b применилась).
   - Секреты скрыты в выводе (задача 3): повторный прогон не светит пароли.
   - x-ui active, fail2ban работает, PostgreSQL готов (post_tasks site.yml уже это проверяют).

7. **Откат при сбое:** `git revert <commit>`; restore из rollout-backup роли sni_manager
   (роль сама делает pg_dump + backup артефактов перед обновлением менеджера).

## Валидация общая

После правок:
- `ansible-playbook --syntax-check playbooks/site.yml`
- `ansible-lint` (после добавления шага).
- Рендер Python-шаблона + `python3 -m py_compile` / `ast.parse`.
- `grep -rn "2.26.101.31" .` → 0.
- Двойной прогон `--check` для проверки idempotency.
- Демонстрация, что секреты не попадают в вывод (no_log).

## Open questions

- ~~Задача 4: зафиксировать ли конкретный тег acme.sh сейчас, или вынести в переменную?~~
  **Решено:** вынести в переменную `xui_acme_sh_version` (значение по умолчанию `3.1.0`,
  реализатор сверяет актуальный тег).
- Задача 9 (вне текущего захода): известен ли публичный SSH host-key сервера для pinning
  в CI? Если нет — оставить ssh-keyscan с явным комментарием о риске TOFU.
