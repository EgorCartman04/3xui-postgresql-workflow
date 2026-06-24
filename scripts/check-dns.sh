#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Использование: $0 <dns_name> <required_ipv4>" >&2
    exit 64
fi

domain="$1"
expected_ip="$2"
resolvers=("system" "1.1.1.1" "8.8.8.8")
checked=0
matched=0

resolve_with_system() {
    getent ahostsv4 "$domain" | awk '{print $1}' | sort -u
}

resolve_with_dig() {
    local resolver="$1"
    dig +short A "$domain" @"$resolver" | sort -u
}

for resolver in "${resolvers[@]}"; do
    if [[ "$resolver" == "system" ]]; then
        if ! command -v getent > /dev/null 2>&1; then
            continue
        fi
        result="$(resolve_with_system || true)"
    else
        if ! command -v dig > /dev/null 2>&1; then
            continue
        fi
        result="$(resolve_with_dig "$resolver" || true)"
    fi

    checked=$((checked + 1))

    if [[ -z "$result" ]]; then
        echo "Проверка DNS: ${domain} не вернул A-записи через ${resolver}." >&2
        continue
    fi

    if grep -Fxq "$expected_ip" <<< "$result"; then
        matched=$((matched + 1))
        continue
    fi

    echo "Проверка DNS провалена: ${domain} через ${resolver} резолвится в: $(tr '\n' ' ' <<< "$result" | xargs), ожидался ${expected_ip}." >&2
    exit 1
done

if [[ "$checked" -eq 0 ]]; then
    echo "Проверка DNS не выполнена: на runner отсутствуют getent и dig." >&2
    exit 1
fi

if [[ "$matched" -eq 0 ]]; then
    echo "Проверка DNS провалена: ${domain} ни через один доступный резолвер не указывает на ${expected_ip}." >&2
    exit 1
fi

echo "DNS-проверка успешна: ${domain} указывает на ${expected_ip}."