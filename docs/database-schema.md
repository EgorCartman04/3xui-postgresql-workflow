# Схема базы данных 3x-ui (PostgreSQL)

Версия: v3.4.1 | СУБД: PostgreSQL | ORM: GORM

---

## Таблицы (19)

### 1. `users` — Пользователи панели

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `username` | TEXT | |
| `password` | TEXT | bcrypt hash |
| `login_epoch` | BIGINT | DEFAULT 0 |

### 2. `inbounds` — Xray inbound-подключения

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `user_id` | BIGINT | |
| `up` | BIGINT | трафик вверх |
| `down` | BIGINT | трафик вниз |
| `total` | BIGINT | лимит (0 = безлимит) |
| `remark` | TEXT | |
| `sub_sort_index` | BIGINT | DEFAULT 1 |
| `enable` | BOOLEAN | INDEX |
| `expiry_time` | BIGINT | unix ms |
| `traffic_reset` | TEXT | DEFAULT 'never' (never/hourly/daily/weekly/monthly) |
| `last_traffic_reset_time` | BIGINT | DEFAULT 0 |
| `listen` | TEXT | |
| `port` | INTEGER | 0-65535 |
| `protocol` | TEXT | vmess/vless/trojan/shadowsocks/wireguard/hysteria/http/mixed/tunnel/tun/mtproto |
| `settings` | TEXT | JSON |
| `stream_settings` | TEXT | JSON |
| `tag` | TEXT | UNIQUE |
| `sniffing` | TEXT | JSON |
| `node_id` | BIGINT | INDEX, nullable |
| `share_addr_strategy` | TEXT | DEFAULT 'node' |
| `share_addr` | TEXT | |
| `origin_node_guid` | TEXT | INDEX |

### 3. `client_traffics` — Статистика трафика клиентов

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `inbound_id` | BIGINT | INDEX |
| `enable` | BOOLEAN | |
| `email` | TEXT | UNIQUE |
| `up` | BIGINT | |
| `down` | BIGINT | |
| `expiry_time` | BIGINT | INDEX |
| `total` | BIGINT | |
| `reset` | BIGINT | DEFAULT 0, INDEX |
| `last_online` | BIGINT | DEFAULT 0 |

### 4. `clients` — Записи клиентов

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `email` | TEXT | UNIQUE, NOT NULL |
| `sub_id` | TEXT | INDEX |
| `uuid` | TEXT | |
| `password` | TEXT | |
| `auth` | TEXT | |
| `flow` | TEXT | |
| `security` | TEXT | |
| `reverse` | TEXT | JSON |
| `limit_ip` | INTEGER | |
| `total_gb` | BIGINT | |
| `expiry_time` | BIGINT | |
| `enable` | BOOLEAN | DEFAULT true |
| `tg_id` | BIGINT | |
| `group_name` | TEXT | DEFAULT '', INDEX |
| `comment` | TEXT | |
| `reset` | INTEGER | DEFAULT 0 |
| `created_at` | BIGINT | autoCreateTime (ms) |
| `updated_at` | BIGINT | autoUpdateTime (ms) |

### 5. `client_inbounds` — Связь клиентов с inbound

| Колонка | Тип | Ограничения |
|---|---|---|
| `client_id` | BIGINT | PK (composite), INDEX |
| `inbound_id` | BIGINT | PK (composite), INDEX |
| `flow_override` | TEXT | |
| `created_at` | BIGINT | autoCreateTime (ms) |

FK: `client_id` → `clients.id`, `inbound_id` → `inbounds.id`

### 6. `client_groups` — Группы клиентов

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `name` | TEXT | UNIQUE, NOT NULL |
| `created_at` | BIGINT | autoCreateTime (ms) |
| `updated_at` | BIGINT | autoUpdateTime (ms) |

### 7. `client_external_links` — Внешние ссылки клиента

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `client_id` | BIGINT | INDEX |
| `kind` | TEXT | 'link' или 'subscription' |
| `value` | TEXT | |
| `remark` | TEXT | |
| `sort_index` | BIGINT | |
| `created_at` | BIGINT | autoCreateTime (ms) |

FK: `client_id` → `clients.id`

### 8. `client_global_traffics` — Трафик с мастер-панели

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `master_guid` | TEXT | UNIQUE (composite), NOT NULL |
| `email` | TEXT | UNIQUE (composite), INDEX |
| `up` | BIGINT | |
| `down` | BIGINT | |
| `updated_at` | BIGINT | autoUpdateTime (ms) |

### 9. `hosts` — Оверрайды inbound для подписок

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `inbound_id` | BIGINT | INDEX, NOT NULL |
| `sort_order` | INTEGER | DEFAULT 0 |
| `remark` | TEXT | max 256 |
| `server_description` | TEXT | max 64, nullable |
| `is_disabled` | BOOLEAN | DEFAULT false |
| `is_hidden` | BOOLEAN | DEFAULT false |
| `tags` | TEXT | JSON array |
| `address` | TEXT | |
| `port` | INTEGER | DEFAULT 0 |
| `security` | TEXT | DEFAULT 'same' (same/tls/none/reality) |
| `sni` | TEXT | |
| `host_header` | TEXT | |
| `path` | TEXT | |
| `alpn` | TEXT | JSON array |
| `fingerprint` | TEXT | |
| `override_sni_from_address` | BOOLEAN | |
| `keep_sni_blank` | BOOLEAN | |
| `pinned_peer_cert_sha256` | TEXT | JSON array |
| `verify_peer_cert_by_name` | TEXT | |
| `allow_insecure` | BOOLEAN | |
| `ech_config_list` | TEXT | |
| `mux_params` | TEXT | JSON |
| `sockopt_params` | TEXT | JSON |
| `final_mask` | TEXT | JSON |
| `vless_route` | TEXT | |
| `exclude_from_sub_types` | TEXT | JSON array |
| `mihomo_ip_version` | TEXT | dual/ipv4/ipv6/ipv4-prefer/ipv6-prefer |
| `mihomo_x25519` | BOOLEAN | |
| `shuffle_host` | BOOLEAN | |
| `node_guids` | TEXT | JSON array |
| `created_at` | BIGINT | autoCreateTime (ms) |
| `updated_at` | BIGINT | autoUpdateTime (ms) |

FK: `inbound_id` → `inbounds.id`

### 10. `inbound_fallbacks` — VLESS/Trojan fallback

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `master_id` | BIGINT | INDEX, NOT NULL |
| `child_id` | BIGINT | INDEX, NOT NULL |
| `name` | TEXT | |
| `alpn` | TEXT | |
| `path` | TEXT | |
| `dest` | TEXT | |
| `xver` | INTEGER | |
| `sort_order` | INTEGER | DEFAULT 0 |

FK: `master_id` → `inbounds.id`, `child_id` → `inbounds.id`

### 11. `outbound_traffics` — Статистика outbound

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `tag` | TEXT | UNIQUE |
| `up` | BIGINT | DEFAULT 0 |
| `down` | BIGINT | DEFAULT 0 |
| `total` | BIGINT | DEFAULT 0 |

### 12. `outbound_subscriptions` — Внешние outbound-подписки

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `remark` | TEXT | |
| `url` | TEXT | |
| `enabled` | BOOLEAN | DEFAULT true |
| `allow_private` | BOOLEAN | DEFAULT false |
| `tag_prefix` | TEXT | |
| `update_interval` | INTEGER | DEFAULT 600 |
| `priority` | INTEGER | DEFAULT 0 |
| `prepend` | BOOLEAN | DEFAULT false |
| `last_updated` | BIGINT | |
| `last_error` | TEXT | |
| `last_fetched_outbounds` | TEXT | |
| `link_identities` | TEXT | |
| `created_at` | BIGINT | autoCreateTime (ms) |
| `updated_at` | BIGINT | autoUpdateTime (ms) |

### 13. `inbound_client_ips` — IP клиентов

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `client_email` | TEXT | UNIQUE |
| `ips` | TEXT | JSON array |

### 14. `node_client_ips` — IP клиентов по узлам

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `node_guid` | TEXT | UNIQUE (composite), NOT NULL |
| `email` | TEXT | UNIQUE (composite), NOT NULL |
| `ips` | TEXT | JSON |

### 15. `node_client_traffics` — Трафик клиентов по узлам

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `node_id` | BIGINT | UNIQUE (composite), NOT NULL |
| `email` | TEXT | UNIQUE (composite), NOT NULL |
| `up` | BIGINT | |
| `down` | BIGINT | |

FK: `node_id` → `nodes.id`

### 16. `nodes` — Удалённые узлы

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `name` | TEXT | UNIQUE |
| `remark` | TEXT | |
| `scheme` | TEXT | http/https |
| `address` | TEXT | |
| `port` | INTEGER | 1-65535 |
| `base_path` | TEXT | |
| `api_token` | TEXT | |
| `enable` | BOOLEAN | DEFAULT true |
| `allow_private_address` | BOOLEAN | DEFAULT false |
| `tls_verify_mode` | TEXT | DEFAULT 'verify' |
| `pinned_cert_sha256` | TEXT | |
| `inbound_sync_mode` | TEXT | DEFAULT 'all' |
| `inbound_tags` | TEXT | JSON array |
| `outbound_tag` | TEXT | |
| `guid` | TEXT | INDEX |
| `status` | TEXT | DEFAULT 'unknown' (online/offline/unknown) |
| `last_heartbeat` | BIGINT | unix s |
| `latency_ms` | BIGINT | |
| `xray_version` | TEXT | |
| `panel_version` | TEXT | |
| `cpu_pct` | REAL | |
| `mem_pct` | REAL | |
| `uptime_secs` | BIGINT | |
| `net_up` | BIGINT | |
| `net_down` | BIGINT | |
| `last_error` | TEXT | |
| `xray_state` | TEXT | |
| `xray_error` | TEXT | |
| `config_dirty` | BOOLEAN | DEFAULT false |
| `config_dirty_at` | BIGINT | |
| `created_at` | BIGINT | autoCreateTime (ms) |
| `updated_at` | BIGINT | autoUpdateTime (ms) |

### 17. `settings` — Key-value настройки

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `key` | TEXT | INDEX |
| `value` | TEXT | |

Ключи из деплоя: `webDomain`, `subEnable`, `subListen`, `subPort`, `subDomain`, `subCertFile`, `subKeyFile`

### 18. `api_tokens` — API токены

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `name` | TEXT | UNIQUE, NOT NULL |
| `token` | TEXT | NOT NULL (SHA-256) |
| `enabled` | BOOLEAN | DEFAULT true |
| `created_at` | BIGINT | autoCreateTime (ms) |

### 19. `history_of_seeders` — Журнал сидеров

| Колонка | Тип | Ограничения |
|---|---|---|
| `id` | SERIAL | PK |
| `seeder_name` | TEXT | |

---

## ER-диаграмма

```
inbounds ──< client_traffics     (inbound_id)
inbounds ──< hosts               (inbound_id)
inbounds ──< inbound_fallbacks   (master_id, child_id)
inbounds ──< client_inbounds     (inbound_id)
clients  ──< client_inbounds     (client_id)
clients  ──< client_external_links (client_id)
nodes    ──< node_client_traffics  (node_id)
```

---

## Примечания

- **PK**: `SERIAL` (PostgreSQL), `INTEGER AUTOINCREMENT` (SQLite)
- **Timestamps**: миллисекунды Unix (GORM autoCreateTime/autoUpdateTime)
- **JSON поля**: хранятся как TEXT, сериализация стандартной JSON-библиотекой
- **Boolean**: PostgreSQL `BOOLEAN`, SQLite `NUMERIC`
- **FK**: управляются на уровне приложения (GORM `DisableForeignKeyConstraintWhenMigrating: true`)
