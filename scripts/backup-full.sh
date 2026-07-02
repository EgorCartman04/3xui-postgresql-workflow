#!/usr/bin/env bash
# Полный бэкап VPN-сервера (3x-ui + SNI Manager + PostgreSQL) в локальную репу.
#
# Архив шифруется симметричным GPG-шифром и сохраняется в vpnServerFullBackups/.
# Каталог vpnServerFullBackups/ в .gitignore — НИКОГДА не коммить его.
#
# Что попадает в бэкап:
#   - pg_dump БД xui (custom format) — пользователи, inbound'ы, Reality-ключи
#   - Конфиг 3x-ui (/etc/x-ui/, /usr/local/x-ui/bin/config.json)
#   - SNI Manager: config + reality-sni.txt (/etc/3x-ui-manager/)
#   - SNI Manager state (/var/lib/3x-ui-manager/state.json)
#   - Runtime override fail2ban (/etc/fail2ban/jail.d/zz-3x-ui-manager.local)
#   - Аудит расписания: systemd list-timers, crontab, ufw status
#
# Что НЕ бэкапится (развёртывается ansible-playbook site.yml):
#   сертификаты TLS и acme.sh (выпускаются заново), бинарник 3x-ui, пакеты,
#   sysctl, UFW, jail-шаблоны, server-side скрипты.
#
# Использование:
#   ./scripts/backup-full.sh                  — интерактивный ввод пароля GPG
#   ./scripts/backup-full.sh --keep 10        — хранить последние 10 архивов
#   XUI_BACKUP_GPG_PASSPHRASE=... ./scripts/backup-full.sh
#   ./scripts/backup-full.sh --no-encrypt     — БЕЗ шифрования (только отладка)
#   ./scripts/backup-full.sh --list           — показать имеющиеся бэкапы
#   ./scripts/backup-full.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
INVENTORY_FILE="${REPO_ROOT}/inventories/prod/group_vars/all.yml"
BACKUP_DIR="${REPO_ROOT}/vpnServerFullBackups"
DEFAULT_KEEP=14

CLI_KEEP=""
CLI_NO_ENCRYPT=0
CLI_LIST=0
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
Полный бэкап VPN-сервера (3x-ui + SNI Manager + PostgreSQL)

Использование:
  ./scripts/backup-full.sh [опции]

Опции:
  --keep N        Хранить последние N архивов (по умолчанию ${DEFAULT_KEEP})
  --no-encrypt    НЕ шифровать архив (ОПАСНО — только для отладки)
  --list          Показать имеющиеся бэкапы и выйти
  --host IP       Переопределить IP сервера (иначе из inventory)
  --user USER     SSH-пользователь (по умолчанию root)
  -h, --help      Эта справка

Переменные окружения:
  XUI_BACKUP_GPG_PASSPHRASE  Пароль GPG (иначе запрашивается интерактивно)
  XUI_TUNNEL_HOST            IP сервера (иначе из inventory)
  XUI_TUNNEL_USER            SSH-пользователь (по умолчанию root)
  XUI_TUNNEL_KEY_FILE        Путь к приватному SSH-ключу
  ANSIBLE_DEPLOY_KEY_FILE    Fallback пути к ключу
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep)
                [[ $# -lt 2 ]] && die "Для --keep нужно число"
                CLI_KEEP="$2"; shift 2 ;;
            --no-encrypt) CLI_NO_ENCRYPT=1; shift ;;
            --list)       CLI_LIST=1; shift ;;
            --host)       [[ $# -lt 2 ]] && die "Для --host нужен IP"; REMOTE_HOST="$2"; shift 2 ;;
            --user)       [[ $# -lt 2 ]] && die "Для --user нужно имя"; REMOTE_USER="$2"; shift 2 ;;
            -h|--help)    CLI_HELP=1; shift ;;
            *)            die "Неизвестный аргумент: $1 (см. --help)" ;;
        esac
    done
}

# Извлекает скаляр из inventory YAML. Jinja-выражения игнорируются.
read_inventory_value() {
    local key="$1"
    [[ -f "${INVENTORY_FILE}" ]] || return 1
    python3 - "$INVENTORY_FILE" "$key" <<'PY' 2>/dev/null || true
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

resolve_config() {
    if [[ -z "${REMOTE_HOST}" ]]; then
        REMOTE_HOST="$(read_inventory_value xui_server_ip || true)"
    fi
    [[ -n "${REMOTE_HOST}" ]] || die "Не удалось определить IP сервера (--host или inventory)."

    # Домен нужен только для справочного поля manifest (сертификаты выпускает Ansible).
    DOMAIN="$(read_inventory_value xui_domain || true)"

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
}

check_ssh() {
    log_info "Проверка SSH-доступа к ${SSH_TARGET}..."
    if ! ssh_exec "exit 0" 2>/dev/null; then
        die "SSH-доступ к ${SSH_TARGET} не работает. Проверь ключ, пользователя и сервер."
    fi
    log_info "SSH-доступ OK"
}

list_local_backups() {
    log_info "Локальные бэкапы в ${BACKUP_DIR}:"
    if [[ ! -d "${BACKUP_DIR}" ]]; then
        log_warn "Каталог не существует: ${BACKUP_DIR}"
        return
    fi
    local found=0
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        found=1
        printf '  %s  %s\n' "$(du -h "${f}" | cut -f1)" "$(basename "${f}")"
    done < <(ls -1t "${BACKUP_DIR}"/3xui-full-*.tar.gz.gpg "${BACKUP_DIR}"/3xui-full-*.tar.gz 2>/dev/null || true)
    (( found == 1 )) || log_warn "Бэкапов не найдено."
}

# Удалённый сборщик. Работает на сервере под root. Аргумент: $1 = DOMAIN
run_remote_collection() {
    local domain="$1"
    ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" "bash -s -- '${domain}'" <<'REMOTE_SCRIPT'
set -euo pipefail

DOMAIN="$1"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
WORKDIR="$(mktemp -d /tmp/3xui-full-backup.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

echo "TIMESTAMP=${TIMESTAMP}"

ENV_FILE="/etc/default/x-ui"
if [[ ! -f "${ENV_FILE}" ]]; then
    echo "ERROR: ${ENV_FILE} не найден — сервер не развёрнут через Ansible" >&2
    exit 1
fi

DB_DSN="$(grep -E '^XUI_DB_DSN=' "${ENV_FILE}" | head -n1 | sed -E 's/^XUI_DB_DSN=//' || true)"
if [[ -z "${DB_DSN}" ]]; then
    echo "ERROR: XUI_DB_DSN пустой в ${ENV_FILE}" >&2
    exit 1
fi

# Парсим DSN: postgres://user:pass@host:port/dbname?sslmode=disable
DB_USER="$(printf '%s' "${DB_DSN}" | sed -E 's#postgres://([^:]+):.*#\1#')"
DB_PASS="$(printf '%s' "${DB_DSN}" | sed -E 's#postgres://[^:]+:([^@]+)@.*#\1#' | python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))')"
DB_HOST="$(printf '%s' "${DB_DSN}" | sed -E 's#.*@([^:/]+).*#\1#')"
DB_PORT="$(printf '%s' "${DB_DSN}" | sed -E 's#.*:([0-9]+)/.*#\1#')"
DB_NAME="$(printf '%s' "${DB_DSN}" | sed -E 's#.*/([^?]+)(\?.*)?#\1#')"

export PGPASSWORD="${DB_PASS}"
echo "Выполняю pg_dump базы ${DB_NAME}..."
pg_dump -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" \
    -Fc --no-owner --no-acl -f "${WORKDIR}/xui-db.dump"
echo "DB_DUMP_SIZE=$(du -h "${WORKDIR}/xui-db.dump" | cut -f1)"
unset PGPASSWORD

# Сбор артефактов
COLLECT="${WORKDIR}/collect"
mkdir -p "${COLLECT}"

copy_path() {
    local src="$1" dst="$2"
    if [[ -e "${src}" ]]; then
        mkdir -p "$(dirname "${dst}")"
        cp -a "${src}" "${dst}" 2>/dev/null || true
        echo "collected: ${src}"
    else
        echo "skipped (missing): ${src}"
    fi
}

copy_path "/etc/x-ui"                         "${COLLECT}/etc/x-ui"
copy_path "/usr/local/x-ui/bin/config.json"   "${COLLECT}/usr/local/x-ui/bin/config.json"
copy_path "/etc/3x-ui-manager"                "${COLLECT}/etc/3x-ui-manager"
copy_path "/var/lib/3x-ui-manager/state.json" "${COLLECT}/var/lib/3x-ui-manager/state.json"
copy_path "/etc/fail2ban/jail.d/zz-3x-ui-manager.local" "${COLLECT}/etc/fail2ban/jail.d/zz-3x-ui-manager.local"

# Аудит расписания (systemd timers + cron) — для документации/проверки
AUDIT="${COLLECT}/audit"
mkdir -p "${AUDIT}"
systemctl list-timers --all --no-pager >"${AUDIT}/systemd-timers.txt" 2>&1 || true
crontab -l >"${AUDIT}/root-crontab.txt" 2>&1 || echo "(нет crontab)" >"${AUDIT}/root-crontab.txt"
ufw status numbered >"${AUDIT}/ufw-status.txt" 2>&1 || true
systemctl is-active x-ui 3x-ui-manager fail2ban postgresql >"${AUDIT}/services-active.txt" 2>&1 || true
/usr/local/x-ui/x-ui -v >"${AUDIT}/xui-version.txt" 2>&1 || true

# Манифест (без секретов)
cat >"${WORKDIR}/manifest.json" <<MJSON
{
  "backup_type": "3xui-full",
  "created_at": "$(date -Iseconds)",
  "created_at_local": "$(date)",
  "hostname": "$(hostname)",
  "server_ip": "$(hostname -I 2>/dev/null | awk '{print $1}' || echo unknown)",
  "domain": "${DOMAIN}",
  "db_name": "${DB_NAME}",
  "db_user": "${DB_USER}",
  "db_host": "${DB_HOST}",
  "db_port": "${DB_PORT}",
  "components": [
    "postgresql-dump", "xui-config",
    "xui-bin-config", "sni-manager-config", "sni-manager-state",
    "fail2ban-runtime-override", "schedule-audit"
  ]
}
MJSON

# Упаковка
ARCHIVE="/tmp/3xui-full-${TIMESTAMP}.tar.gz"
tar -czf "${ARCHIVE}" -C "${WORKDIR}" manifest.json collect xui-db.dump
echo "ARCHIVE=${ARCHIVE}"
echo "ARCHIVE_SIZE=$(du -h "${ARCHIVE}" | cut -f1)"
REMOTE_SCRIPT
}

collect_passphrase() {
    if (( CLI_NO_ENCRYPT == 1 )); then
        log_warn "Шифрование отключено (--no-encrypt). Архив содержит секреты в открытом виде!"
        return 0
    fi
    if [[ -n "${GPG_PASSPHRASE}" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "Нет интерактивного терминала и не задана XUI_BACKUP_GPG_PASSPHRASE."
    fi
    local pass1 pass2
    read -r -s -p "Пароль GPG для архива: " pass1; echo
    read -r -s -p "Повтор пароля: " pass2; echo
    [[ "${pass1}" == "${pass2}" ]] || die "Пароли не совпадают."
    [[ -n "${pass1}" ]] || die "Пустой пароль недопустим."
    GPG_PASSPHRASE="${pass1}"
}

run_backup() {
    mkdir -p "${BACKUP_DIR}"

    local remote_out archive_remote timestamp
    remote_out="$(run_remote_collection "${DOMAIN}")"
    archive_remote="$(printf '%s\n' "${remote_out}" | sed -n 's/^ARCHIVE=//p' | head -n1)"
    timestamp="$(printf '%s\n' "${remote_out}" | sed -n 's/^TIMESTAMP=//p' | head -n1)"
    printf '%s\n' "${remote_out}" | sed -n 's/^DB_DUMP_SIZE=/  [remote] DB dump: /p'
    printf '%s\n' "${remote_out}" | sed -n 's/^ARCHIVE_SIZE=/  [remote] Archive:  /p'

    [[ -n "${archive_remote}" ]] || die "Не удалось получить путь к архиву с сервера."

    local workdir plain_archive
    workdir="$(mktemp -d /tmp/3xui-full-local.XXXXXX)"
    plain_archive="${workdir}/3xui-full-${timestamp}.tar.gz"

    log_info "Скачивание архива с сервера..."
    scp -q "${SSH_OPTIONS[@]}" "${SSH_TARGET}:${archive_remote}" "${plain_archive}"

    # Чистим временный архив на сервере
    ssh_exec "rm -f '${archive_remote}'" 2>/dev/null || true

    # Сохраняем sidecar-манифест (без секретов) для listing без расшифровки
    tar -xOf "${plain_archive}" manifest.json >"${BACKUP_DIR}/3xui-full-${timestamp}.meta.json" 2>/dev/null || true

    if (( CLI_NO_ENCRYPT == 1 )); then
        mv "${plain_archive}" "${BACKUP_DIR}/3xui-full-${timestamp}.tar.gz"
        local final_path="${BACKUP_DIR}/3xui-full-${timestamp}.tar.gz"
        log_warn "Архив НЕ зашифрован: ${final_path}"
    else
        local final_path="${BACKUP_DIR}/3xui-full-${timestamp}.tar.gz.gpg"
        log_info "Шифрование архива (GPG AES-256)..."
        gpg --batch --yes \
            --passphrase-fd 0 \
            --pinentry-mode loopback \
            -c --cipher-algo AES256 \
            -o "${final_path}" "${plain_archive}" \
            <<<"${GPG_PASSPHRASE}"
        # Удаляем незашифрованную копию
        rm -f "${plain_archive}"
    fi

    rm -rf "${workdir}"

    local size
    size="$(du -h "${final_path}" | cut -f1)"
    log_success "Бэкап создан: ${final_path} (${size})"

    apply_retention
}

apply_retention() {
    local keep="${CLI_KEEP:-${DEFAULT_KEEP}}"
    [[ "${keep}" =~ ^[0-9]+$ ]] || return 0
    (( keep > 0 )) || return 0

    local count deleted=0
    count=$(ls -1 "${BACKUP_DIR}"/3xui-full-*.tar.gz.gpg 2>/dev/null | wc -l | tr -d ' ')
    if (( count > keep )); then
        log_info "Retention: оставляю последние ${keep} из ${count} архивов..."
        while IFS= read -r old; do
            local base
            base="$(basename "${old}")"
            base="${base%.tar.gz.gpg}"
            base="${base%.tar.gz}"
            rm -f "${old}" "${BACKUP_DIR}/${base}.meta.json"
            log_info "  удалён: $(basename "${old}")"
            deleted=$((deleted + 1))
        done < <(ls -1t "${BACKUP_DIR}"/3xui-full-*.tar.gz.gpg 2>/dev/null | tail -n +"$((keep + 1))" || true)
        (( deleted > 0 )) && log_info "Удалено старых архивов: ${deleted}"
    fi
}

main() {
    parse_args "$@"

    if (( CLI_HELP == 1 )); then
        print_help
        exit 0
    fi

    check_requirements

    if (( CLI_LIST == 1 )); then
        list_local_backups
        exit 0
    fi

    resolve_config
    check_ssh
    collect_passphrase
    run_backup
}

main "$@"
