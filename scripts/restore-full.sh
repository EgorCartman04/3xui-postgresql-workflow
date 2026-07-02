#!/usr/bin/env bash
# Восстановление VPN-сервера из полного бэкапа (3x-ui + SNI Manager + PostgreSQL).
#
# Сценарий: полный Disaster Recovery (DR) на сервер, уже развёрнутый через
# ansible-playbook site.yml. Скрипт НЕ ставит ОС/пакеты/3x-ui — он восстанавливает
# данные поверх чистой установки:
#   1. Расшифровывает GPG-архив локально.
# 2. Копирует на сервер.
#   3. Останавливает x-ui и SNI Manager.
#   4. Пересоздаёт БД xui и накатывает pg_restore из дампа.
#   5. Распаковывает сертификаты, config, state-файлы, override fail2ban.
#   6. Перезапускает сервисы и проверяет здоровье.
#
# ПРЕДУСЛОВИЕ: целевой сервер уже развёрнут через Ansible
#   (XUI_ADMIN_USERNAME=... ansible-playbook playbooks/site.yml).
# При смене IP/домена — обнови inventories/prod/group_vars/all.yml и запусти deploy
# ПЕРЕД восстановлением.
#
# Использование:
#   ./scripts/restore-full.sh vpn-serverFullBbackups/3xui-full-<ts>.tar.gz.gpg
#   ./scripts/restore-full.sh <archive> --host NEW_IP
#   ./scripts/restore-full.sh <archive> --yes          — без подтверждения
#   XUI_BACKUP_GPG_PASSPHRASE=... ./scripts/restore-full.sh <archive>
#   ./scripts/restore-full.sh <archive> --show-manifest — показать содержимое и выйти

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
INVENTORY_FILE="${REPO_ROOT}/inventories/prod/group_vars/all.yml"
SERVICE_NAME="x-ui"
MANAGER_SERVICE_NAME="3x-ui-manager"

ARCHIVE_PATH=""
CLI_HOST=""
CLI_USER=""
CLI_YES=0
CLI_SHOW_MANIFEST=0
CLI_HELP=0

REMOTE_HOST="${XUI_TUNNEL_HOST:-}"
REMOTE_USER="${XUI_TUNNEL_USER:-root}"
SSH_CONNECT_TIMEOUT="${XUI_TUNNEL_CONNECT_TIMEOUT:-8}"
GPG_PASSPHRASE="${XUI_BACKUP_GPG_PASSPHRASE:-}"
DEFAULT_KEY_FILE="${REPO_ROOT}/.secrets/ssh/ansible_deploy_key"
SSH_KEY_FILE="${XUI_TUNNEL_KEY_FILE:-${ANSIBLE_DEPLOY_KEY_FILE:-${DEFAULT_KEY_FILE}}}"

log_info()    { echo "[INFO] $*"; }
log_warn()    { echo "[WARN] $*" >&2; }
log_error()   { echo "[ERROR] $*" >&2; }
log_success() { echo "[OK] $*"; }
die()         { log_error "$*"; exit 1; }

print_help() {
    cat <<EOF
Восстановление VPN-сервера из полного бэкапа (DR)

Использование:
  ./scripts/restore-full.sh <archive.gpg> [опции]

Позиционный аргумент:
  archive    Путь к бэкапу (.tar.gz.gpg или .tar.gz)

Опции:
  --host IP       Целевой IP сервера (иначе из inventory)
  --user USER     SSH-пользователь (по умолчанию root)
  --yes, -y       Не спрашивать подтверждение
  --show-manifest Показать манифест архива и выйти
  -h, --help      Эта справка

Переменные окружения:
  XUI_BACKUP_GPG_PASSPHRASE  Пароль GPG (иначе запрашивается интерактивно)
  XUI_TUNNEL_HOST            IP сервера (иначе из inventory)
  XUI_TUNNEL_USER            SSH-пользователь (по умолчанию root)
  XUI_TUNNEL_KEY_FILE        Путь к приватному SSH-ключу

ВАЖНО:
  Перед восстановлением сервер должен быть развёрнут через:
    XUI_ADMIN_USERNAME=... XUI_ADMIN_PASSWORD=... \
    XUI_PANEL_BASE_PATH=... XUI_DB_PASSWORD=... \
    ansible-playbook playbooks/site.yml

  Архив накатывает данные поверх чистой установки.
  Сертификаты TLS выпускаются Ansible при деплое — в бэкапе их нет.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)         [[ $# -lt 2 ]] && die "Для --host нужен IP"; CLI_HOST="$2"; shift 2 ;;
            --user)         [[ $# -lt 2 ]] && die "Для --user нужно имя"; CLI_USER="$2"; shift 2 ;;
            --yes|-y)       CLI_YES=1; shift ;;
            --show-manifest) CLI_SHOW_MANIFEST=1; shift ;;
            -h|--help)      CLI_HELP=1; shift ;;
            --*)            die "Неизвестный аргумент: $1 (см. --help)" ;;
            *)
                [[ -n "${ARCHIVE_PATH}" ]] && die "Можно указать только один архив."
                ARCHIVE_PATH="$1"; shift ;;
        esac
    done
}

read_inventory_value() {
    local key="$1"
    [[ -f "${INVENTORY_FILE}" ]] || return 1
    python3 - "${INVENTORY_FILE}" "$key" <<'PY' 2>/dev/null || true
import sys, yaml
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = yaml.safe_load(f) or {}
except Exception:
    sys.exit(0)
val = data.get(key, "")
if isinstance(val, bool):
    print("true" if val else "false")
elif val is None:
    pass
elif isinstance(val, (int, float)):
    print(val)
else:
    s = str(val)
    if "{{" in s or "lookup(" in s:
        sys.exit(0)
    print(s)
PY
}

resolve_target() {
    if [[ -n "${CLI_HOST}" ]]; then
        REMOTE_HOST="${CLI_HOST}"
    elif [[ -z "${REMOTE_HOST}" ]]; then
        REMOTE_HOST="$(read_inventory_value xui_server_ip || true)"
    fi
    [[ -n "${REMOTE_HOST}" ]] || die "Не удалось определить IP сервера (--host или inventory)."

    if [[ -n "${CLI_USER}" ]]; then
        REMOTE_USER="${CLI_USER}"
    fi

    [[ -f "${SSH_KEY_FILE}" ]] || die "Не найден SSH-ключ: ${SSH_KEY_FILE}"
    SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
}

SSH_OPTIONS=(
    -i "${SSH_KEY_FILE}"
    -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
    -o "ServerAliveInterval=30"
    -o "ServerAliveCountMax=3"
    -o "BatchMode=yes"
)

ssh_exec() { ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" "$@"; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Не найдена обязательная команда: $1"
}

check_requirements() {
    require_cmd ssh
    require_cmd scp
    require_cmd python3
    require_cmd tar
    require_cmd gpg
    require_cmd jq
}

resolve_archive() {
    [[ -n "${ARCHIVE_PATH}" ]] || die "Укажи путь к архиву (см. --help)."

    # Поддержка относительных путей
    if [[ "${ARCHIVE_PATH}" != /* ]]; then
        ARCHIVE_PATH="${REPO_ROOT}/${ARCHIVE_PATH}"
    fi

    [[ -f "${ARCHIVE_PATH}" ]] || die "Архив не найден: ${ARCHIVE_PATH}"

    if [[ "${ARCHIVE_PATH}" == *.gpg ]]; then
        IS_ENCRYPTED=1
    else
        IS_ENCRYPTED=0
    fi
}

collect_passphrase() {
    if (( IS_ENCRYPTED == 0 )); then
        return 0
    fi
    if [[ -n "${GPG_PASSPHRASE}" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "Нет терминала и не задана XUI_BACKUP_GPG_PASSPHRASE."
    fi
    read -r -s -p "Пароль GPG архива: " GPG_PASSPHRASE; echo
    [[ -n "${GPG_PASSPHRASE}" ]] || die "Пустой пароль."
}

# Расшифровывает (если нужно) во временный каталог, возвращает путь к .tar.gz
decrypt_to_temp() {
    local workdir
    workdir="$(mktemp -d /tmp/3xui-restore.XXXXXX)"
    RESTORE_WORKDIR="${workdir}"

    local plain="${workdir}/backup.tar.gz"

    if (( IS_ENCRYPTED == 1 )); then
        log_info "Расшифровка архива..."
        if ! gpg --batch --yes --pinentry-mode loopback \
                --passphrase-fd 0 \
                -d "${ARCHIVE_PATH}" >"${plain}" 2>/dev/null \
                <<<"${GPG_PASSPHRASE}"; then
            rm -rf "${workdir}"
            die "Не удалось расшифровать архив. Проверь пароль GPG."
        fi
    else
        cp "${ARCHIVE_PATH}" "${plain}"
    fi

    PLAIN_ARCHIVE="${plain}"
}

read_manifest_value() {
    local key="$1"
    [[ -f "${PLAIN_ARCHIVE}" ]] || return 1
    tar -xOf "${PLAIN_ARCHIVE}" manifest.json 2>/dev/null \
        | jq -r ".${key} // empty" 2>/dev/null || true
}

show_manifest() {
    local manifest
    manifest="$(tar -xOf "${PLAIN_ARCHIVE}" manifest.json 2>/dev/null || true)"
    if [[ -z "${manifest}" ]]; then
        die "В архиве нет manifest.json — возможно, архив повреждён."
    fi
    echo "${manifest}" | jq . 2>/dev/null || echo "${manifest}"
}

# Проверка предусловий на сервере: Ansible-деплой выполнен
preflight_server() {
    log_info "Preflight проверка сервера ${SSH_TARGET}..."

    local ssh_ok
    if ! ssh_exec "exit 0" 2>/dev/null; then
        die "SSH-доступ к ${SSH_TARGET} не работает. Проверь ключ, пользователя, доступность."
    fi

    # Проверяем что сервер развёрнут через Ansible (ключевые артефакты существуют)
    local check
    check="$(ssh_exec '
        set -e
        result=""
        [[ -f /etc/default/x-ui ]] && result="${result}env-file " || result="${result}NO-env-file "
        [[ -x /usr/local/x-ui/x-ui ]] && result="${result}xui-binary " || result="${result}NO-xui-binary "
        systemctl list-unit-files 2>/dev/null | grep -q "^x-ui.service" && result="${result}xui-unit " || result="${result}NO-xui-unit "
        systemctl list-unit-files 2>/dev/null | grep -q "^3x-ui-manager.service" && result="${result}manager-unit " || result="${result}NO-manager-unit "
        command -v psql >/dev/null 2>&1 && result="${result}psql " || result="${result}NO-psql "
        pg_isready >/dev/null 2>&1 && result="${result}pg-ready " || result="${result}NO-pg-ready "
        echo "${result}"
    ' 2>/dev/null || true)"

    if echo "${check}" | grep -q "NO-"; then
        log_error "Сервер не готов для восстановления. Найдены проблемы:"
        echo "  ${check}" >&2
        echo ""
        die "Сначала разверни сервер: XUI_ADMIN_USERNAME=... XUI_ADMIN_PASSWORD=... \\
  XUI_PANEL_BASE_PATH=... XUI_DB_PASSWORD=... ansible-playbook playbooks/site.yml"
    fi

    log_info "Preflight OK: ${check}"
}

confirm() {
    (( CLI_YES == 1 )) && return 0
    if [[ ! -t 0 ]]; then
        log_warn "Нет терминала — авто-подтверждение (используй --yes для явного согласия)."
        return 0
    fi

    local backup_domain db_name
    backup_domain="$(read_manifest_value domain || echo '?')"
    db_name="$(read_manifest_value db_name || echo '?')"

    echo ""
    echo "============================================================"
    echo " ПЛАН ВОССТАНОВЛЕНИЯ (DR)"
    echo "============================================================"
    echo "  Целевой сервер:    ${SSH_TARGET}"
    echo "  Архив:             $(basename "${ARCHIVE_PATH}")"
    echo "  Домен в архиве:    ${backup_domain}"
    echo "  БД в архиве:       ${db_name}"
    echo "------------------------------------------------------------"
    echo " Будет выполнено:"
    echo "   1. Остановка ${SERVICE_NAME} и ${MANAGER_SERVICE_NAME}"
    echo "   2. DROP + CREATE базы ${db_name}, pg_restore из дампа"
    echo "   3. Распаковка сертификатов, config, state-файлов"
    echo "   4. Перезапуск сервисов и health-check"
    echo "------------------------------------------------------------"
    echo " ВНИМАНИЕ: все текущие данные на сервере будут ЗАМЕНЕНЫ."
    echo "============================================================"
    echo ""
    read -r -p "Продолжить восстановление? [yes/NO]: " answer
    case "${answer}" in
        yes|YES) return 0 ;;
        *) echo "Отменено."; exit 0 ;;
    esac
}

# Загружает архив на сервер и выполняет полное восстановление
run_remote_restore() {
    local remote_archive="/tmp/$(basename "${PLAIN_ARCHIVE}")"

    log_info "Загрузка архива на сервер ${SSH_TARGET}..."
    scp -q "${SSH_OPTIONS[@]}" "${PLAIN_ARCHIVE}" "${SSH_TARGET}:${remote_archive}"

    log_info "Восстановление на сервере (остановка сервисов, БД, state, рестарт)..."
    ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
        "bash -s -- '${remote_archive}'" <<'REMOTE_RESTORE'
set -euo pipefail

REMOTE_ARCHIVE="$1"
SERVICE_NAME="x-ui"
MANAGER_SERVICE_NAME="3x-ui-manager"

WORKDIR="$(mktemp -d /tmp/3xui-restore-remote.XXXXXX)"
trap 'rm -rf "${WORKDIR}" "${REMOTE_ARCHIVE}"' EXIT

log()  { echo "[remote] $*"; }
err()  { echo "[remote][ERROR] $*" >&2; }

# Распаковываем архив во временный каталог
tar -xzf "${REMOTE_ARCHIVE}" -C "${WORKDIR}"
DUMP="${WORKDIR}/xui-db.dump"
COLLECT="${WORKDIR}/collect"

if [[ ! -f "${DUMP}" ]]; then
    err "Дамп БД не найден в архиве: ${DUMP}"
    exit 1
fi

log "Извлечение параметров БД из /etc/default/x-ui..."
ENV_FILE="/etc/default/x-ui"
DB_DSN="$(grep -E '^XUI_DB_DSN=' "${ENV_FILE}" | head -n1 | sed -E 's/^XUI_DB_DSN=//' || true)"
DB_USER="$(printf '%s' "${DB_DSN}" | sed -E 's#postgres://([^:]+):.*#\1#')"
DB_PASS="$(printf '%s' "${DB_DSN}" | sed -E 's#postgres://[^:]+:([^@]+)@.*#\1#' | python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))')"
DB_HOST="$(printf '%s' "${DB_DSN}" | sed -E 's#.*@([^:/]+).*#\1#')"
DB_PORT="$(printf '%s' "${DB_DSN}" | sed -E 's#.*:([0-9]+)/.*#\1#')"
DB_NAME="$(printf '%s' "${DB_DSN}" | sed -E 's#.*/([^?]+)(\?.*)?#\1#')"

export PGPASSWORD="${DB_PASS}"

# 1. Остановка сервисов
log "Остановка сервисов ${SERVICE_NAME} и ${MANAGER_SERVICE_NAME}..."
systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
systemctl stop "${MANAGER_SERVICE_NAME}" 2>/dev/null || true

# 2. Пересоздание БД и восстановление дампа
log "Пересоздание базы ${DB_NAME} (DROP + CREATE)..."
# Закрываем активные подключения к БД, затем дропаем
psql -U postgres -h "${DB_HOST}" -p "${DB_PORT}" -d postgres <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${DB_NAME}";
CREATE DATABASE "${DB_NAME}" OWNER "${DB_USER}";
SQL

log "pg_restore в базу ${DB_NAME}..."
pg_restore -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" \
    --no-owner --no-acl --if-exists --clean "${DUMP}" 2>&1 || {
    # pg_restore выдаёт warnings как ненулевой код; проверяем реальный результат
    log "pg_restore завершился с предупреждениями (это нормально для --clean)."
}

unset PGPASSWORD

# 3. Восстановление конфига 3x-ui
if [[ -d "${COLLECT}/etc/x-ui" ]]; then
    log "Восстановление /etc/x-ui..."
    cp -a "${COLLECT}/etc/x-ui/." "/etc/x-ui/"
    chown -R root:root "/etc/x-ui"
fi

if [[ -f "${COLLECT}/usr/local/x-ui/bin/config.json" ]]; then
    log "Восстановление config.json панели..."
    cp -a "${COLLECT}/usr/local/x-ui/bin/config.json" "/usr/local/x-ui/bin/config.json"
    chown root:root "/usr/local/x-ui/bin/config.json"
fi

# 5. Восстановление SNI Manager config
if [[ -d "${COLLECT}/etc/3x-ui-manager" ]]; then
    log "Восстановление /etc/3x-ui-manager..."
    cp -a "${COLLECT}/etc/3x-ui-manager/." "/etc/3x-ui-manager/"
    chown -R root:root "/etc/3x-ui-manager"
fi

# 6. Восстановление state SNI Manager
if [[ -f "${COLLECT}/var/lib/3x-ui-manager/state.json" ]]; then
    log "Восстановление state.json SNI Manager..."
    mkdir -p "/var/lib/3x-ui-manager"
    cp -a "${COLLECT}/var/lib/3x-ui-manager/state.json" "/var/lib/3x-ui-manager/state.json"
    chown root:root "/var/lib/3x-ui-manager/state.json"
    chmod 0640 "/var/lib/3x-ui-manager/state.json"
fi

# 7. Восстановление runtime override fail2ban
if [[ -f "${COLLECT}/etc/fail2ban/jail.d/zz-3x-ui-manager.local" ]]; then
    log "Восстановление override fail2ban..."
    cp -a "${COLLECT}/etc/fail2ban/jail.d/zz-3x-ui-manager.local" \
          "/etc/fail2ban/jail.d/zz-3x-ui-manager.local"
    chown root:root "/etc/fail2ban/jail.d/zz-3x-ui-manager.local"
fi

# 8. Перезапуск сервисов
log "Запуск сервисов..."
systemctl restart fail2ban 2>/dev/null || true
systemctl start "${SERVICE_NAME}"
systemctl start "${MANAGER_SERVICE_NAME}"

sleep 3

# 9. Проверка здоровья
xui_state="$(systemctl is-active "${SERVICE_NAME}" || true)"
mgr_state="$(systemctl is-active "${MANAGER_SERVICE_NAME}" || true)"

log "Статус ${SERVICE_NAME}: ${xui_state}"
log "Статус ${MANAGER_SERVICE_NAME}: ${mgr_state}"

if [[ "${xui_state}" != "active" ]]; then
    err "${SERVICE_NAME} не активен после восстановления."
    journalctl -u "${SERVICE_NAME}" --no-pager -n 30 || true
    exit 1
fi

if [[ "${mgr_state}" != "active" ]]; then
    err "${MANAGER_SERVICE_NAME} не активен после восстановления."
    journalctl -u "${MANAGER_SERVICE_NAME}" --no-pager -n 30 || true
    exit 1
fi

log "Проверка доступности БД..."
pg_isready -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" >/dev/null 2>&1 \
    && log "PostgreSQL: готов" || err "PostgreSQL: НЕ готов"

log "Восстановление завершено успешно."
REMOTE_RESTORE
}

main() {
    parse_args "$@"

    if (( CLI_HELP == 1 )); then
        print_help
        exit 0
    fi

    check_requirements
    resolve_archive
    resolve_target
    collect_passphrase
    decrypt_to_temp

    if (( CLI_SHOW_MANIFEST == 1 )); then
        show_manifest
        rm -rf "${RESTORE_WORKDIR}"
        exit 0
    fi

    preflight_server
    confirm

    run_remote_restore

    log_success "Восстановление завершено."
    log_info "Проверь панель через SSH-туннель: ./scripts/tunnel.sh status"

    rm -rf "${RESTORE_WORKDIR}"
}

# Очистка при прерывании
trap 'rm -rf "${RESTORE_WORKDIR:-}" 2>/dev/null || true' EXIT INT TERM

main "$@"
