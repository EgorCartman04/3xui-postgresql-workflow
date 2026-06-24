#!/usr/bin/env bash
# Обновление 3x-ui на сервере с выбором версии
#
# Использование:
#   ./scripts/update-3x-ui.sh                 — интерактивный выбор режима
#   ./scripts/update-3x-ui.sh --latest        — обновить до последнего релиза (stable/prerelease)
#   ./scripts/update-3x-ui.sh --version 3.0.2 — обновить до указанной версии
#   ./scripts/update-3x-ui.sh --version v3.0.2 --yes

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

REMOTE_HOST="${XUI_TUNNEL_HOST:-2.26.230.90}"
REMOTE_USER="${XUI_TUNNEL_USER:-root}"
SSH_CONNECT_TIMEOUT="${XUI_TUNNEL_CONNECT_TIMEOUT:-8}"
SERVICE_NAME="${XUI_SERVICE_NAME:-x-ui}"
CERT_DOMAIN="${XUI_DOMAIN:-adv.randomain.space}"
BACKUP_PREFIX="${XUI_UPDATE_BACKUP_PREFIX:-manual-pre-update-3x-ui}"

DEFAULT_KEY_FILE="${REPO_ROOT}/.secrets/ssh/ansible_deploy_key"
SSH_KEY_FILE="${XUI_TUNNEL_KEY_FILE:-${ANSIBLE_DEPLOY_KEY_FILE:-${DEFAULT_KEY_FILE}}}"
SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"

RELEASE_OWNER="MHSanaei"
RELEASE_REPO="3x-ui"

CLI_USE_LATEST=0
CLI_TARGET_VERSION=""
CLI_ASSUME_YES=0

TARGET_VERSION=""
TARGET_SOURCE=""
TARGET_STATUS=""
REMOTE_ARCH=""
REMOTE_RELEASE_ARCH=""
CURRENT_VERSION=""

SSH_OPTIONS=(
    -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
    -o "ServerAliveInterval=30"
    -o "ServerAliveCountMax=3"
    -o "BatchMode=yes"
)

if [[ -n "${SSH_KEY_FILE}" ]]; then
    if [[ ! -f "${SSH_KEY_FILE}" ]]; then
        echo "ОШИБКА: не найден SSH-ключ: ${SSH_KEY_FILE}" >&2
        exit 1
    fi
    SSH_OPTIONS=(-i "${SSH_KEY_FILE}" "${SSH_OPTIONS[@]}")
fi

log_info() {
    echo "[INFO] $*"
}

log_warn() {
    echo "[WARN] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

print_help() {
    cat << 'EOF'
Обновление 3x-ui на сервере

Использование:
  ./scripts/update-3x-ui.sh
    Интерактивный режим с выбором:
      1) до последнего доступного релиза (stable/prerelease)
      2) до версии, введенной вручную

  ./scripts/update-3x-ui.sh --latest
    Обновить до последнего доступного релиза (stable/prerelease)

  ./scripts/update-3x-ui.sh --version <версия>
    Обновить до указанной версии (можно с 'v' и без)
    Примеры: --version 3.0.2, --version v3.0.2

  ./scripts/update-3x-ui.sh --yes
    Не задавать интерактивное подтверждение перед применением

Переменные окружения:
  XUI_TUNNEL_HOST              SSH-хост сервера (по умолчанию: 2.26.230.90)
  XUI_TUNNEL_USER              SSH-пользователь (по умолчанию: root)
  XUI_TUNNEL_CONNECT_TIMEOUT   Таймаут подключения в секундах (по умолчанию: 8)
  XUI_TUNNEL_KEY_FILE          Явный путь к приватному SSH-ключу
  ANSIBLE_DEPLOY_KEY_FILE      Fallback-путь к ключу
  XUI_SERVICE_NAME             Имя systemd unit (по умолчанию: x-ui)
  XUI_DOMAIN                   Домен сертификатов для backup (по умолчанию: adv.randomain.space)
  XUI_UPDATE_BACKUP_PREFIX     Префикс имени backup-файла на сервере
EOF
}

ssh_exec() {
    ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" "$@"
}

require_cmd() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        log_error "Не найдена обязательная команда: ${cmd}"
        exit 1
    fi
}

normalize_version_tag() {
    local raw="$1"
    raw="${raw#v}"
    raw="${raw//[[:space:]]/}"

    if [[ -z "${raw}" ]]; then
        log_error "Пустая версия"
        exit 1
    fi

    printf 'v%s' "${raw}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                print_help
                exit 0
                ;;
            --latest)
                CLI_USE_LATEST=1
                shift
                ;;
            --version)
                if [[ $# -lt 2 ]]; then
                    log_error "Для --version нужно указать значение"
                    exit 1
                fi
                CLI_TARGET_VERSION="$(normalize_version_tag "$2")"
                shift 2
                ;;
            --yes|-y)
                CLI_ASSUME_YES=1
                shift
                ;;
            *)
                log_error "Неизвестный аргумент: $1"
                print_help
                exit 1
                ;;
        esac
    done

    if [[ ${CLI_USE_LATEST} -eq 1 && -n "${CLI_TARGET_VERSION}" ]]; then
        log_error "Нельзя одновременно использовать --latest и --version"
        exit 1
    fi
}

check_local_requirements() {
    require_cmd ssh
    require_cmd curl
}

check_ssh_access() {
    log_info "Проверка SSH доступа к ${SSH_TARGET}..."
    if ! ssh_exec "exit 0" 2>/dev/null; then
        log_error "Не удается подключиться к ${SSH_TARGET}"
        exit 1
    fi
    log_info "SSH доступ OK"
}

detect_remote_arch_and_version() {
    local remote_info

    remote_info="$(ssh_exec '
        set -euo pipefail
        arch="$(uname -m)"
        current="$(/usr/local/x-ui/x-ui -v 2>/dev/null || true)"
        printf "ARCH=%s\n" "$arch"
        printf "CURRENT=%s\n" "$current"
    ')"

    REMOTE_ARCH="$(printf '%s\n' "${remote_info}" | sed -n 's/^ARCH=//p' | head -n1)"
    CURRENT_VERSION="$(printf '%s\n' "${remote_info}" | sed -n 's/^CURRENT=//p' | head -n1)"

    case "${REMOTE_ARCH}" in
        x86_64)
            REMOTE_RELEASE_ARCH="amd64"
            ;;
        aarch64)
            REMOTE_RELEASE_ARCH="arm64"
            ;;
        *)
            log_error "Неподдерживаемая архитектура сервера: ${REMOTE_ARCH}"
            exit 1
            ;;
    esac

    if [[ -n "${CURRENT_VERSION}" ]]; then
        log_info "Текущая версия на сервере: ${CURRENT_VERSION}"
    else
        log_warn "Текущая версия не определена (возможно, 3x-ui еще не установлен)"
    fi
}

resolve_latest_release_tag() {
    require_cmd python3

    local api_url
    local parsed

    api_url="https://api.github.com/repos/${RELEASE_OWNER}/${RELEASE_REPO}/releases?per_page=20"

    parsed="$(curl -fsSL --connect-timeout 10 --max-time 30 "${api_url}" | python3 -c '
import json
import sys

releases = json.load(sys.stdin)
if not releases:
    raise SystemExit("NO_RELEASES")

latest = next((r for r in releases if r.get("tag_name")), None)
if latest is None:
    raise SystemExit("NO_TAG")

if latest.get("draft"):
    status = "draft"
elif latest.get("prerelease"):
    status = "prerelease"
else:
    status = "stable"

print(latest["tag_name"])
print(status)
')" || {
        log_error "Не удалось определить последний релиз 3x-ui через GitHub API"
        exit 1
    }

    TARGET_VERSION="$(printf '%s\n' "${parsed}" | sed -n '1p')"
    TARGET_STATUS="$(printf '%s\n' "${parsed}" | sed -n '2p')"
    TARGET_SOURCE="latest"

    if [[ -z "${TARGET_VERSION}" ]]; then
        log_error "GitHub API не вернул tag_name"
        exit 1
    fi
}

choose_target_version() {
    if [[ ${CLI_USE_LATEST} -eq 1 ]]; then
        resolve_latest_release_tag
        return
    fi

    if [[ -n "${CLI_TARGET_VERSION}" ]]; then
        TARGET_VERSION="${CLI_TARGET_VERSION}"
        TARGET_SOURCE="manual"
        TARGET_STATUS="custom"
        return
    fi

    echo
    echo "Выбери режим обновления 3x-ui:"
    echo "  1) До последнего доступного релиза (любой статус: stable/prerelease)"
    echo "  2) Указать версию вручную"

    local choice=""
    while true; do
        read -r -p "Ввод [1/2]: " choice
        case "${choice}" in
            1)
                resolve_latest_release_tag
                return
                ;;
            2)
                read -r -p "Укажи версию (например 3.0.2 или v3.0.2): " choice
                TARGET_VERSION="$(normalize_version_tag "${choice}")"
                TARGET_SOURCE="manual"
                TARGET_STATUS="custom"
                return
                ;;
            *)
                echo "Неверный выбор, введи 1 или 2."
                ;;
        esac
    done
}

asset_url_for_version() {
    local version_tag="$1"
    printf 'https://github.com/%s/%s/releases/download/%s/x-ui-linux-%s.tar.gz' \
        "${RELEASE_OWNER}" "${RELEASE_REPO}" "${version_tag}" "${REMOTE_RELEASE_ARCH}"
}

validate_target_release_asset() {
    local url

    url="$(asset_url_for_version "${TARGET_VERSION}")"

    log_info "Проверка доступности релиза: ${TARGET_VERSION} (${REMOTE_RELEASE_ARCH})"
    if ! curl -fsSIL --connect-timeout 10 --max-time 30 "${url}" >/dev/null; then
        log_error "Не найден release-asset для ${TARGET_VERSION} (${REMOTE_RELEASE_ARCH})"
        log_error "URL: ${url}"
        exit 1
    fi
}

confirm_plan() {
    if [[ ${CLI_ASSUME_YES} -eq 1 ]]; then
        return
    fi

    local answer=""

    echo
    echo "План обновления:"
    echo "  Сервер:            ${SSH_TARGET}"
    echo "  Сервис:            ${SERVICE_NAME}"
    echo "  Архитектура:       ${REMOTE_ARCH} -> ${REMOTE_RELEASE_ARCH}"
    if [[ -n "${CURRENT_VERSION}" ]]; then
        echo "  Текущая версия:    ${CURRENT_VERSION}"
    else
        echo "  Текущая версия:    (не определена)"
    fi
    echo "  Целевая версия:    ${TARGET_VERSION}"
    if [[ "${TARGET_SOURCE}" == "latest" ]]; then
        echo "  Источник версии:   latest (${TARGET_STATUS})"
    else
        echo "  Источник версии:   manual"
    fi
    echo "  Backup перед апдейтом: /var/backups/3x-ui/${BACKUP_PREFIX}-<version>-<timestamp>.tar.gz"

    read -r -p "Продолжить? [y/N]: " answer
    case "${answer}" in
        y|Y|yes|YES)
            ;;
        *)
            echo "Отменено пользователем."
            exit 0
            ;;
    esac
}

run_remote_update() {
    log_info "Запуск обновления 3x-ui до ${TARGET_VERSION}..."

    ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
        "bash -s -- '${TARGET_VERSION}' '${REMOTE_RELEASE_ARCH}' '${SERVICE_NAME}' '${CERT_DOMAIN}' '${BACKUP_PREFIX}'" <<'REMOTE_SCRIPT'
set -euo pipefail

target_version="$1"
release_arch="$2"
service_name="$3"
cert_domain="$4"
backup_prefix="$5"

install_dir="/usr/local/x-ui"
backup_dir="/var/backups/3x-ui"
asset_name="x-ui-linux-${release_arch}.tar.gz"
asset_url="https://github.com/MHSanaei/3x-ui/releases/download/${target_version}/${asset_name}"
tmp_archive="/tmp/${asset_name}"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_file="${backup_dir}/${backup_prefix}-${target_version#v}-${timestamp}.tar.gz"

mkdir -p "${backup_dir}"

backup_sources=()
[[ -d "${install_dir}" ]] && backup_sources+=("${install_dir}")
[[ -d "/etc/x-ui" ]] && backup_sources+=("/etc/x-ui")
[[ -n "${cert_domain}" && -d "/root/cert/${cert_domain}" ]] && backup_sources+=("/root/cert/${cert_domain}")

if (( ${#backup_sources[@]} > 0 )); then
    tar -czf "${backup_file}" "${backup_sources[@]}"
    echo "BACKUP_PATH=${backup_file}"
else
    echo "BACKUP_PATH=SKIPPED(no-sources-found)"
fi

curl -fL --connect-timeout 10 --max-time 300 "${asset_url}" -o "${tmp_archive}"

systemctl stop "${service_name}" || true
rm -rf "${install_dir}"
tar -xzf "${tmp_archive}" -C /usr/local

chown -R root:root "${install_dir}"
chmod 0755 "${install_dir}/x-ui" "${install_dir}/x-ui.sh"
cp -f "${install_dir}/x-ui.sh" /usr/bin/x-ui
chmod 0755 /usr/bin/x-ui

if [[ -f "${install_dir}/x-ui.service.debian" ]]; then
    cp -f "${install_dir}/x-ui.service.debian" "/etc/systemd/system/${service_name}.service"
fi

systemctl daemon-reload
systemctl enable "${service_name}"
"${install_dir}/x-ui" migrate

systemctl restart "${service_name}"

new_version="$("${install_dir}/x-ui" -v 2>/dev/null || true)"
service_state="$(systemctl is-active "${service_name}" || true)"

rm -f "${tmp_archive}" || true

echo "UPDATED_TO=${new_version}"
echo "SERVICE_STATE=${service_state}"
REMOTE_SCRIPT
}

post_checks() {
    local state

    state="$(ssh_exec "systemctl is-active ${SERVICE_NAME}" || true)"
    if [[ "${state}" != "active" ]]; then
        log_error "Сервис ${SERVICE_NAME} не active после обновления"
        ssh_exec "journalctl -u ${SERVICE_NAME} --no-pager -n 40" || true
        exit 1
    fi

    log_info "Обновление завершено успешно."
    log_info "Проверка версии на сервере:"
    ssh_exec "${SERVICE_NAME} status >/dev/null 2>&1 || true; /usr/local/x-ui/x-ui -v || true"
}

main() {
    parse_args "$@"
    check_local_requirements
    check_ssh_access
    detect_remote_arch_and_version
    choose_target_version
    validate_target_release_asset
    confirm_plan
    run_remote_update
    post_checks
}

main "$@"
