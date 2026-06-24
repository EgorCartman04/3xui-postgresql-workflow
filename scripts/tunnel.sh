#!/usr/bin/env bash
# Персистентный SSH-туннель через autossh
#
# Использование:
#   ./scripts/tunnel.sh         — открыть туннель
#   ./scripts/tunnel.sh stop    — закрыть туннель
#   ./scripts/tunnel.sh status  — проверить состояние
#   ./scripts/tunnel.sh open-domain — открыть панель по доменному имени в Chrome поверх локального туннеля

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

SCRIPT_NAME="${XUI_TUNNEL_COMMAND_NAME:-$0}"
TUNNEL_NAME="${XUI_TUNNEL_NAME:-панели 3x-ui}"
TUNNEL_APP_KIND="${XUI_TUNNEL_APP_KIND:-x-ui}"
XUI_DB_USER="${XUI_TUNNEL_DB_USER:-xui}"
XUI_DB_NAME="${XUI_TUNNEL_DB_NAME:-xui}"
XUI_DB_HOST="${XUI_TUNNEL_DB_HOST:-127.0.0.1}"
REMOTE_HOST="${XUI_TUNNEL_HOST:-2.26.230.90}"
REMOTE_USER="${XUI_TUNNEL_USER:-root}"
LOCAL_PORT="${XUI_TUNNEL_LOCAL_PORT:-24443}"
REMOTE_PORT="${XUI_TUNNEL_REMOTE_PORT:-24443}"
PANEL_BASE_PATH="${XUI_TUNNEL_BASE_PATH:-}"
TUNNEL_SCHEME="${XUI_TUNNEL_SCHEME:-https}"
SSH_CONNECT_TIMEOUT="${XUI_TUNNEL_CONNECT_TIMEOUT:-8}"
SSH_CHECK_RETRIES="${XUI_TUNNEL_SSH_CHECK_RETRIES:-3}"
SSH_CHECK_RETRY_DELAY="${XUI_TUNNEL_SSH_CHECK_RETRY_DELAY:-1}"
START_WAIT_SECONDS="${XUI_TUNNEL_START_WAIT_SECONDS:-5}"
AUTOSSH_PIDFILE="${XUI_TUNNEL_PIDFILE:-/tmp/3x-ui-tunnel.pid}"
HEALTHCHECK_ENABLED="${XUI_TUNNEL_HEALTHCHECK_ENABLED:-1}"
HEALTHCHECK_TIMEOUT="${XUI_TUNNEL_HEALTHCHECK_TIMEOUT:-10}"
HEALTHCHECK_PATH="${XUI_TUNNEL_HEALTHCHECK_PATH:-}"
HEALTHCHECK_CURL_CIPHERS="${XUI_TUNNEL_HEALTHCHECK_CURL_CIPHERS:-}"
SERVICE_NAME="${XUI_TUNNEL_SERVICE_NAME:-}"
BROWSER_HOST="${XUI_TUNNEL_BROWSER_HOST:-}"
WITH_SNI_MANAGER="${XUI_TUNNEL_WITH_SNI_MANAGER:-1}"
DISABLE_COMPANION="${XUI_TUNNEL_DISABLE_COMPANION:-0}"

SCRIPT_SELF="${SCRIPT_DIR}/tunnel.sh"
SNI_MANAGER_COMMAND_NAME="./scripts/tunnel-sni-manager.sh"
SNI_MANAGER_NAME="SNI Manager"
SNI_MANAGER_LOCAL_PORT="${XUI_SNI_MANAGER_TUNNEL_LOCAL_PORT:-24880}"
SNI_MANAGER_REMOTE_PORT="${XUI_SNI_MANAGER_TUNNEL_REMOTE_PORT:-24880}"
SNI_MANAGER_PIDFILE="${XUI_SNI_MANAGER_TUNNEL_PIDFILE:-/tmp/3x-ui-sni-manager-tunnel.pid}"

DEFAULT_KEY_FILE="${REPO_ROOT}/.secrets/ssh/ansible_deploy_key"
SSH_KEY_FILE="${XUI_TUNNEL_KEY_FILE:-${ANSIBLE_DEPLOY_KEY_FILE:-${DEFAULT_KEY_FILE}}}"
SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
SSH_CHECK_OUTPUT=""

SSH_OPTIONS=(
    -o "ServerAliveInterval=30"
    -o "ServerAliveCountMax=3"
    -o "ExitOnForwardFailure=yes"
    -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
    -o "BatchMode=yes"
)

if [[ -n "${SSH_KEY_FILE}" ]]; then
    if [[ ! -f "${SSH_KEY_FILE}" ]]; then
        echo "ОШИБКА: не найден SSH-ключ: ${SSH_KEY_FILE}" >&2
        exit 1
    fi
    SSH_OPTIONS=(-i "${SSH_KEY_FILE}" "${SSH_OPTIONS[@]}")
fi

normalize_base_path() {
    local raw_path="${1:-}"

    raw_path="${raw_path//$'\r'/}"
    raw_path="${raw_path//$'\n'/}"
    raw_path="${raw_path#/}"
    raw_path="${raw_path%/}"
    printf '%s' "${raw_path}"
}

sanitize_path_fragment() {
    local raw_value="${1:-}"

    raw_value="${raw_value//[^[:alnum:]._-]/_}"
    printf '%s' "${raw_value}"
}

panel_url() {
    local normalized_path

    normalized_path="$(normalize_base_path "${PANEL_BASE_PATH}")"

    if [[ -n "${normalized_path}" ]]; then
        printf '%s://127.0.0.1:%s/%s/\n' "${TUNNEL_SCHEME}" "${LOCAL_PORT}" "${normalized_path}"
    else
        printf '%s://127.0.0.1:%s/\n' "${TUNNEL_SCHEME}" "${LOCAL_PORT}"
    fi
}

companion_enabled() {
    [[ "${DISABLE_COMPANION}" != "1" && "${WITH_SNI_MANAGER}" == "1" && "${TUNNEL_APP_KIND}" == "x-ui" ]]
}

run_companion_command() {
    local subcommand="${1:-status}"
    local quiet="${2:-0}"
    local output=""
    local status=0

    if ! companion_enabled; then
        return 0
    fi

    set +e
    output="$(
        XUI_TUNNEL_DISABLE_COMPANION=1 \
        XUI_TUNNEL_WITH_SNI_MANAGER=0 \
        XUI_TUNNEL_COMMAND_NAME="${SNI_MANAGER_COMMAND_NAME}" \
        XUI_TUNNEL_NAME="${SNI_MANAGER_NAME}" \
        XUI_TUNNEL_APP_KIND="https" \
        XUI_TUNNEL_LOCAL_PORT="${SNI_MANAGER_LOCAL_PORT}" \
        XUI_TUNNEL_REMOTE_PORT="${SNI_MANAGER_REMOTE_PORT}" \
        XUI_TUNNEL_SCHEME="https" \
        XUI_TUNNEL_HEALTHCHECK_PATH="healthz" \
        XUI_TUNNEL_PIDFILE="${SNI_MANAGER_PIDFILE}" \
        XUI_TUNNEL_SERVICE_NAME="3x-ui-manager" \
        "${SCRIPT_SELF}" "${subcommand}" 2>&1
    )"
    status=$?
    set -e

    if (( status == 0 )); then
        if [[ "${quiet}" != "1" && -n "${output}" ]]; then
            printf '%s\n' "${output}"
        fi
        return 0
    fi

    if [[ -n "${output}" ]]; then
        printf '%s\n' "${output}" >&2
    fi
    return "${status}"
}

is_running() {
    lsof -i "TCP:${LOCAL_PORT}" -sTCP:LISTEN > /dev/null 2>&1
}

active_autossh_pid() {
    local pid=""

    if [[ -f "${AUTOSSH_PIDFILE}" ]]; then
        pid="$(tr -d '[:space:]' < "${AUTOSSH_PIDFILE}")"
        if [[ -n "${pid}" ]] && ps -p "${pid}" > /dev/null 2>&1; then
            printf '%s' "${pid}"
            return 0
        fi
    fi

    pid="$(pgrep -f "autossh.*${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" | head -n 1 || true)"
    if [[ -n "${pid}" ]]; then
        printf '%s' "${pid}"
        return 0
    fi

    return 1
}

active_ssh_command() {
    local autossh_pid="${1:-}"
    local ssh_pid=""

    if [[ -z "${autossh_pid}" ]]; then
        return 1
    fi

    ssh_pid="$(pgrep -P "${autossh_pid}" | head -n 1 || true)"
    if [[ -z "${ssh_pid}" ]]; then
        return 1
    fi

    ps -o command= -p "${ssh_pid}" 2>/dev/null || true
}

tunnel_matches_target() {
    local autossh_pid
    local ssh_command

    autossh_pid="$(active_autossh_pid || true)"
    if [[ -z "${autossh_pid}" ]]; then
        return 1
    fi

    ssh_command="$(active_ssh_command "${autossh_pid}")"
    if [[ -z "${ssh_command}" ]]; then
        return 1
    fi

    [[ "${ssh_command}" == *"-L ${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}"* && "${ssh_command}" == *"${SSH_TARGET}"* ]]
}

stop_tunnel_processes() {
    pkill -f "autossh.*${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" 2>/dev/null || true
    pkill -f "ssh.*${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" 2>/dev/null || true
    rm -f "${AUTOSSH_PIDFILE}"
}

refresh_stale_tunnel_if_needed() {
    local autossh_pid
    local ssh_command

    if ! is_running; then
        return 0
    fi

    if tunnel_matches_target; then
        return 0
    fi

    autossh_pid="$(active_autossh_pid || true)"
    ssh_command="$(active_ssh_command "${autossh_pid}")"

    echo "Найден stale туннель на локальном порту ${LOCAL_PORT}. Пересоздаю его для ${SSH_TARGET}." >&2
    if [[ -n "${ssh_command}" ]]; then
        echo "Текущий ssh-командный target: ${ssh_command}" >&2
    fi

    stop_tunnel_processes
}

check_ssh_access() {
    local output
    local attempt
    local max_attempts

    max_attempts="${SSH_CHECK_RETRIES}"
    if ! [[ "${max_attempts}" =~ ^[0-9]+$ ]] || (( max_attempts < 1 )); then
        max_attempts=1
    fi

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if output="$(ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" exit 2>&1)"; then
            SSH_CHECK_OUTPUT=""
            return 0
        fi

        SSH_CHECK_OUTPUT="${output}"
        if (( attempt < max_attempts )); then
            echo "SSH preflight не прошёл с попытки ${attempt}/${max_attempts}, повторяю через ${SSH_CHECK_RETRY_DELAY}с..." >&2
            sleep "${SSH_CHECK_RETRY_DELAY}"
        fi
    done

    return 1
}

discover_browser_host() {
    local inventory_file="${REPO_ROOT}/inventories/prod/group_vars/all.yml"
    local discovered_host=""

    if [[ -n "${BROWSER_HOST}" ]]; then
        printf '%s' "${BROWSER_HOST}"
        return 0
    fi

    if [[ -f "${inventory_file}" ]]; then
        discovered_host="$(awk -F':' '/^xui_domain:/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/"/, "", $2); print $2; exit}' "${inventory_file}")"
    fi

    printf '%s' "${discovered_host}"
}

domain_panel_url() {
    local normalized_path
    local browser_host

    browser_host="$(discover_browser_host)"
    if [[ -z "${browser_host}" ]]; then
        return 1
    fi

    normalized_path="$(normalize_base_path "${PANEL_BASE_PATH}")"

    if [[ -n "${normalized_path}" ]]; then
        printf '%s://%s:%s/%s/\n' "${TUNNEL_SCHEME}" "${browser_host}" "${LOCAL_PORT}" "${normalized_path}"
    else
        printf '%s://%s:%s/\n' "${TUNNEL_SCHEME}" "${browser_host}" "${LOCAL_PORT}"
    fi
}

print_domain_url_hint() {
    local browser_host
    local browser_url

    if [[ "${TUNNEL_APP_KIND}" != "x-ui" ]]; then
        return 0
    fi

    browser_host="$(discover_browser_host)"
    if [[ -z "${browser_host}" || "${browser_host}" == "127.0.0.1" || "${browser_host}" == "localhost" ]]; then
        return 0
    fi

    browser_url="$(domain_panel_url || true)"
    if [[ -z "${browser_url}" ]]; then
        return 0
    fi

    echo "Панель также доступна по доменному имени поверх этого же туннеля: ${browser_url}"
    echo "Если понадобится генерировать ручные share-ссылки из UI, открывай именно доменный адрес; без /etc/hosts можно использовать ${SCRIPT_NAME} open-domain"
}

detect_chrome_binary() {
    local candidate

    for candidate in \
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
        "/Applications/Chromium.app/Contents/MacOS/Chromium" \
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
        if [[ -x "${candidate}" ]]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done

    return 1
}

open_domain_url_in_chrome() {
    local browser_url
    local browser_host
    local chrome_binary
    local profile_dir

    refresh_stale_tunnel_if_needed

    if ! is_running; then
        echo "ОШИБКА: сначала подними SSH-туннель командой ${SCRIPT_NAME} start" >&2
        return 1
    fi

    detect_xui_base_path
    browser_url="$(domain_panel_url || true)"
    browser_host="$(discover_browser_host)"

    if [[ -z "${browser_url}" || -z "${browser_host}" ]]; then
        echo "ОШИБКА: не удалось определить доменный URL панели" >&2
        return 1
    fi

    chrome_binary="$(detect_chrome_binary || true)"
    if [[ -z "${chrome_binary}" ]]; then
        echo "ОШИБКА: не найден Chrome/Chromium-совместимый браузер в /Applications" >&2
        return 1
    fi

    profile_dir="${XUI_TUNNEL_CHROME_PROFILE_DIR:-/tmp/3x-ui-domain-browser-$(sanitize_path_fragment "${browser_host}")}"
    mkdir -p "${profile_dir}"

    nohup "${chrome_binary}" \
        --user-data-dir="${profile_dir}" \
        --host-resolver-rules="MAP ${browser_host} 127.0.0.1, EXCLUDE localhost" \
        --new-window \
        "${browser_url}" \
        >/tmp/3x-ui-domain-browser.log 2>&1 &

    echo "Открываю панель по доменному имени в Chrome: ${browser_url}"
}

ssh_run() {
    ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" "$@"
}

detect_xui_base_path() {
    local detected_path

    if [[ -n "$(normalize_base_path "${PANEL_BASE_PATH}")" ]]; then
        PANEL_BASE_PATH="$(normalize_base_path "${PANEL_BASE_PATH}")"
        return 0
    fi

    if [[ "${TUNNEL_APP_KIND}" != "x-ui" ]]; then
        return 0
    fi

    detected_path="$(ssh_run "PGPASSWORD=\${XUI_TUNNEL_DB_PASSWORD:-} psql -U ${XUI_DB_USER} -d ${XUI_DB_NAME} -h ${XUI_DB_HOST} -tA -c \"SELECT value FROM settings WHERE key='webBasePath' LIMIT 1;\" 2>/dev/null" || true)"
    detected_path="$(normalize_base_path "${detected_path}")"
    if [[ -n "${detected_path}" ]]; then
        PANEL_BASE_PATH="${detected_path}"
    fi
}

healthcheck_url() {
    local path

    path="$(normalize_base_path "${HEALTHCHECK_PATH}")"
    if [[ -n "${path}" ]]; then
        printf '%s://127.0.0.1:%s/%s\n' "${TUNNEL_SCHEME}" "${LOCAL_PORT}" "${path}"
        return
    fi

    printf '%s' "$(panel_url)"
}

print_service_context() {
    if [[ -z "${SERVICE_NAME}" ]]; then
        return
    fi

    echo "Состояние systemd unit ${SERVICE_NAME}:" >&2
    ssh_run "systemctl is-active ${SERVICE_NAME} 2>&1 || true" >&2 || true
    echo "Последние строки журнала ${SERVICE_NAME}:" >&2
    ssh_run "journalctl -u ${SERVICE_NAME} -n 20 --no-pager 2>&1 || true" >&2 || true
}

run_healthcheck() {
    local url
    local http_code
    local browser_host
    local -a curl_args

    if [[ "${HEALTHCHECK_ENABLED}" != "1" ]]; then
        return 0
    fi

    detect_xui_base_path
    url="$(healthcheck_url)"
    browser_host="$(discover_browser_host)"
    curl_args=( -k -L -s -o /dev/null -w '%{http_code}' --max-time "${HEALTHCHECK_TIMEOUT}" )
    
    # Добавляем явные ciphers для Termux/старых OpenSSL версий
    if [[ -n "${HEALTHCHECK_CURL_CIPHERS}" ]]; then
        curl_args+=( --ciphers "${HEALTHCHECK_CURL_CIPHERS}" )
    fi
    
    if [[ -n "${browser_host}" ]]; then
        curl_args+=( -H "Host: ${browser_host}" )
    fi
    http_code="$(curl "${curl_args[@]}" "${url}" || true)"

    case "${http_code}" in
        200|301|302|303|307|308)
            echo "Healthcheck OK -> ${url} (HTTP ${http_code})"
            return 0
            ;;
        *)
            echo "ОШИБКА: healthcheck для ${TUNNEL_NAME} не прошёл -> ${url} (HTTP ${http_code:-curl-failed})" >&2
            print_tunnel_context
            print_service_context
            
            # Рекомендация для Termux
            if [[ -n "${TERMUX_VERSION:-}" ]] || [[ -d "${TERMUX_PREFIX:-}" ]] || [[ "${http_code}" == "curl-failed" ]]; then
                echo "" >&2
                echo "Совет для Termux/Android: если это ошибка TLS, попробуй:" >&2
                echo "  XUI_TUNNEL_HEALTHCHECK_CURL_CIPHERS='DEFAULT' ${SCRIPT_NAME} start" >&2
                echo "или отключи healthcheck:" >&2
                echo "  XUI_TUNNEL_HEALTHCHECK_ENABLED=0 ${SCRIPT_NAME} start" >&2
            fi
            return 1
            ;;
    esac
}

print_tunnel_context() {
    echo "Контур: ${TUNNEL_NAME}" >&2
    echo "SSH target: ${SSH_TARGET}" >&2
    echo "Локальный порт: ${LOCAL_PORT}" >&2
    echo "Удалённый порт: 127.0.0.1:${REMOTE_PORT}" >&2
    echo "SSH-ключ: ${SSH_KEY_FILE}" >&2
    if [[ -n "$(normalize_base_path "${PANEL_BASE_PATH}")" ]]; then
        echo "Base path: /$(normalize_base_path "${PANEL_BASE_PATH}")/" >&2
    fi
}

print_local_port_context() {
    local port_output

    if port_output="$(lsof -nP -i "TCP:${LOCAL_PORT}" 2>/dev/null)" && [[ -n "${port_output}" ]]; then
        echo "Локальный порт ${LOCAL_PORT} уже используется:" >&2
        echo "${port_output}" >&2
    fi
}

case "${1:-start}" in
    start)
        refresh_stale_tunnel_if_needed
        if is_running; then
            echo "Туннель к ${TUNNEL_NAME} уже активен -> $(panel_url)"
            print_domain_url_hint
            if ! run_companion_command start; then
                echo "ОШИБКА: дополнительный туннель к ${SNI_MANAGER_NAME} не запустился. Туннель панели оставлен активным." >&2
                exit 1
            fi
            exit 0
        fi
        if ! check_ssh_access; then
            echo "ОШИБКА: SSH-доступ к ${SSH_TARGET} не работает. Проверь пользователя, ключ и доступность сервера." >&2
            print_tunnel_context
            if [[ -n "${SSH_CHECK_OUTPUT}" ]]; then
                echo "Ответ SSH:" >&2
                echo "${SSH_CHECK_OUTPUT}" >&2
            fi
            exit 1
        fi
        detect_xui_base_path
        AUTOSSH_PIDFILE="${AUTOSSH_PIDFILE}" \
        AUTOSSH_POLL=30 \
        AUTOSSH_GATETIME=0 \
        autossh -M 0 \
            -L "${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" \
            "${SSH_OPTIONS[@]}" \
            -fNT "${SSH_TARGET}" 2>/dev/null &
        
        # Даём autossh время на поднятие туннеля
        autossh_attempt=0
        while (( autossh_attempt < 10 )); do
            if is_running; then
                break
            fi
            sleep 0.3
            (( autossh_attempt++ ))
        done
        
        # Если autossh не поднял туннель, пробуем обычный ssh (для Termux на Android)
        if ! is_running; then
            pkill -f "autossh.*${LOCAL_PORT}" 2>/dev/null || true
            sleep 0.5
            
            # Fallback на обычный ssh для Termux
            nohup ssh \
                -L "${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" \
                "${SSH_OPTIONS[@]}" \
                -NfT "${SSH_TARGET}" >/dev/null 2>&1 &
            
            # Ждём, пока ssh поднимет туннель
            for ((attempt = 0; attempt < 20; attempt++)); do
                if is_running; then
                    break
                fi
                sleep 0.1
            done
        fi
        
        for ((attempt = 0; attempt < START_WAIT_SECONDS * 10; attempt++)); do
            if is_running; then
                if run_healthcheck; then
                    echo "Туннель к ${TUNNEL_NAME} открыт (персистентный) -> $(panel_url)"
                    print_domain_url_hint
                    if ! run_companion_command start; then
                        echo "ОШИБКА: дополнительный туннель к ${SNI_MANAGER_NAME} не запустился. Туннель панели оставлен активным." >&2
                        exit 1
                    fi
                    exit 0
                fi
                stop_tunnel_processes
                exit 1
            fi
            sleep 0.1
        done
        if is_running; then
            if run_healthcheck; then
                echo "Туннель к ${TUNNEL_NAME} открыт (персистентный) -> $(panel_url)"
                print_domain_url_hint
                if ! run_companion_command start; then
                    echo "ОШИБКА: дополнительный туннель к ${SNI_MANAGER_NAME} не запустился. Туннель панели оставлен активным." >&2
                    exit 1
                fi
            else
                stop_tunnel_processes
                exit 1
            fi
        else
            echo "ОШИБКА: туннель к ${TUNNEL_NAME} не запустился" >&2
            print_tunnel_context
            print_local_port_context
            exit 1
        fi
        ;;
    stop)
        run_companion_command stop 1 || true
        stop_tunnel_processes
        echo "Туннель закрыт"
        ;;
    status)
        refresh_stale_tunnel_if_needed
        if is_running; then
            detect_xui_base_path
            pid="$(active_autossh_pid || echo "ssh")"
            echo "Туннель к ${TUNNEL_NAME} АКТИВЕН (PID autossh: ${pid}) -> $(panel_url)"
            print_domain_url_hint
            run_healthcheck || exit 1
            run_companion_command status || exit 1
        else
            echo "Туннель к ${TUNNEL_NAME} НЕ активен"
        fi
        ;;
    open-domain)
        open_domain_url_in_chrome
        ;;
    *)
        echo "Использование: ${SCRIPT_NAME} [start|stop|status|open-domain]"
        exit 1
        ;;
esac