#!/usr/bin/env bash
# lib/db.sh - MariaDB installation, hardening, RAM/disk based tuning with health
#             check + rollback, per-domain databases ("db" command); Redis setup.

DB_SOCKET="/run/mysqld/mysqld.sock"
DB_APT_LIST="/etc/apt/sources.list.d/mariadb.list"
DB_SLOW_LOG="/var/log/mysql/mariadb-slow.log"
DBI_NAME="" DBI_USER="" DBI_PASS="" DBI_HOST="localhost"

REDIS_CONF="/etc/redis/redis.conf"
REDIS_INCLUDE="/etc/redis/server-setup.conf"
REDIS_INFO="${STATE_DIR}/redis.info"
REDIS_SERVICE="redis-server"

# =============================================================================
#  MariaDB helpers
# =============================================================================
lib_db_client()  { if lib_have mariadb; then printf 'mariadb'; else printf 'mysql'; fi; }
lib_db_admin()   { if lib_have mariadb-admin; then printf 'mariadb-admin'; else printf 'mysqladmin'; fi; }
lib_db_dumper()  { if lib_have mariadb-dump; then printf 'mariadb-dump'; else printf 'mysqldump'; fi; }
lib_db_installed() { lib_pkg_installed mariadb-server || lib_have mariadbd; }
lib_db_version() {
  lib_have mariadbd && mariadbd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 && return 0
  lib_have mysqld && mysqld --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 && return 0
  printf ''
}
lib_db_ping() { "$(lib_db_admin)" --protocol=socket --socket="$DB_SOCKET" ping >/dev/null 2>&1; }

lib_db_wait_ready() {
  local i=""
  for (( i = 0; i < "${1:-30}"; i++ )); do lib_db_ping && return 0; sleep 1; done
  return 1
}

# lib_db_sql "SQL"  -> result rows (tab separated). Runs as root through the unix socket.
lib_db_sql() { "$(lib_db_client)" --protocol=socket --socket="$DB_SOCKET" -N -B -e "$1"; }

# Execute SQL that contains secrets: only the description is logged.
lib_db_sql_secret() {   # description sql
  local desc="$1" sql="$2" rc=0 out=""
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] SQL: ${desc}"; return 0; fi
  lib_log_write CMD "SQL: ${desc}"
  out="$(printf '%s\n' "$sql" | "$(lib_db_client)" --protocol=socket --socket="$DB_SOCKET" -N -B 2>&1)" || rc=$?
  if (( rc != 0 )); then
    lib_log_write ERROR "SQL failed (${desc}): $(printf '%s' "$out" | lib_mask_secrets | head -n 3)"
  fi
  return "$rc"
}

lib_db_exists()      { [[ -n "$(lib_db_sql "SHOW DATABASES LIKE '${1//_/\\_}'" 2>/dev/null)" ]]; }
lib_db_user_exists() { [[ "$(lib_db_sql "SELECT COUNT(*) FROM mysql.user WHERE User='${1}' AND Host='localhost'" 2>/dev/null)" == "1" ]]; }

# =============================================================================
#  Installation
# =============================================================================
lib_db_repo_setup() {   # version e.g. 11.4
  local ver="$1"
  [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]] || lib_die "Invalid MariaDB version '${ver}'" "expected e.g. 10.11 or 11.4" "use --mariadb 11.4"
  lib_apt_key_install "https://mariadb.org/mariadb_release_signing_key.pgp" /etc/apt/keyrings/mariadb-keyring.gpg
  printf 'deb [signed-by=/etc/apt/keyrings/mariadb-keyring.gpg] https://deb.mariadb.org/%s/ubuntu %s main\n' "$ver" "$OS_CODENAME" \
    | lib_write_file "$DB_APT_LIST" 0644 root:root
  (( LIB_FILE_CHANGED )) && LIB_APT_UPDATED=0
  lib_ok "MariaDB ${ver} repository configured"
}

lib_db_full_dump() {   # path.gz  (all databases, for pre-upgrade safety)
  local out="$1"
  (( OPT_DRY_RUN )) && return 0
  mkdir -p "$(dirname "$out")"
  if ! "$(lib_db_dumper)" --protocol=socket --socket="$DB_SOCKET" --all-databases --single-transaction --quick \
        --routines --events --triggers 2>>"$LOG_FILE" | gzip -c >"$out"; then
    rm -f "$out"; return 1
  fi
  chmod 0600 "$out"
}

# lib_db_install [version]
lib_db_install() {
  local want="${1:-}" cur="" major_cur="" major_want="" dump=""
  cur="$(lib_db_version)"
  if [[ -n "$want" ]]; then
    major_want="${want%%.*}.${want#*.}"; major_want="${major_want%%.*}"
    major_cur="${cur%%.*}"
    if [[ -n "$cur" ]] && [[ "${cur%.*}" != "$want" ]]; then
      lib_warn "MariaDB ${cur} is installed; requested ${want} from the official repository."
      if [[ "$major_cur" != "$major_want" ]]; then
        lib_warn "This is a MAJOR version change (${major_cur} -> ${major_want}). A full dump is taken first."
        lib_confirm "Continue with the MariaDB major upgrade?" n || lib_die "MariaDB upgrade cancelled" "user declined" "re-run without --mariadb or accept the upgrade"
      fi
      dump="${BACKUP_ROOT}/mariadb-pre-upgrade-$(lib_ts).sql.gz"
      lib_info "Dumping all databases to ${dump}"
      lib_db_full_dump "$dump" || lib_die "Pre-upgrade dump failed" "mariadb-dump error" "check disk space and the log"
    fi
    lib_db_repo_setup "$want"
    lib_apt_update
    lib_apt_install mariadb-server mariadb-client || lib_die "MariaDB installation failed" "apt error" "check the log"
    if (( ! OPT_DRY_RUN )); then
      lib_run apt-get install -y -q --only-upgrade mariadb-server mariadb-client || true
    fi
  else
    if lib_db_installed; then
      lib_ok "MariaDB already installed (${cur})"
    else
      lib_apt_install mariadb-server mariadb-client || lib_die "MariaDB installation failed" "apt error" "check the log"
      lib_ok "MariaDB installed ($( (( OPT_DRY_RUN )) && printf 'dry-run' || lib_db_version))"
    fi
  fi
  lib_systemd_override mariadb "LimitNOFILE=65535"
  lib_systemctl enable mariadb >/dev/null 2>&1 || true
  if (( ! OPT_DRY_RUN )); then
    lib_service_active mariadb || lib_systemctl start mariadb
    lib_db_wait_ready 30 || lib_die "MariaDB is not answering on ${DB_SOCKET}" "service failed to start" "journalctl -u mariadb"
    if [[ -n "$dump" && -f "$dump" ]] && lib_have mariadb-upgrade; then lib_run mariadb-upgrade --protocol=socket --socket="$DB_SOCKET" || true; fi
  fi
  lib_manifest_set '.components.mariadb' "$(lib_db_version)"
}

# Equivalent of mysql_secure_installation (idempotent; root keeps unix_socket auth).
lib_db_secure() {
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would remove anonymous users, test database and remote root"; return 0; fi
  lib_db_wait_ready 10 || lib_die "MariaDB not reachable" "service down" "systemctl status mariadb"
  local sql=""
  sql="DELETE FROM mysql.global_priv WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
FLUSH PRIVILEGES;"
  lib_db_sql_secret "secure installation (anonymous users, test db, remote root)" "$sql" \
    || lib_die "MariaDB hardening failed" "SQL error (see log)" "run mysql_secure_installation manually"
  lib_ok "MariaDB hardened (no anonymous users, no test db, root local-only via unix_socket)"
}

# =============================================================================
#  Tuning
# =============================================================================
lib_db_render_tuning() {
  lib_system_profile
  cat <<EOF
# Managed by lompstack - regenerated by "setup.sh install" and "setup.sh optimize"
# Profile: ${SYS_RAM_MB} MB RAM, ${SYS_CPU_CORES} CPU, disk ${SYS_DISK_TYPE}; buffer pool ${CALC_DB_BUFFER_PCT}% of RAM
[mysqld]
bind-address                    = 127.0.0.1
skip-name-resolve               = 1
character-set-server            = utf8mb4
collation-server                = utf8mb4_unicode_ci
max_connections                 = ${CALC_DB_MAX_CONN}
max_allowed_packet              = 64M
thread_cache_size               = ${CALC_DB_THREAD_CACHE}
table_open_cache                = ${CALC_DB_TABLE_CACHE}
table_definition_cache          = $(( CALC_DB_TABLE_CACHE / 2 ))
open_files_limit                = 65535
tmp_table_size                  = ${CALC_DB_TMP_MB}M
max_heap_table_size             = ${CALC_DB_TMP_MB}M
sort_buffer_size                = 2M
join_buffer_size                = 2M
read_rnd_buffer_size            = 1M
innodb_buffer_pool_size         = ${CALC_DB_BUFFER_MB}M
innodb_log_file_size            = ${CALC_DB_LOG_MB}M
innodb_log_buffer_size          = 32M
innodb_flush_method             = O_DIRECT
innodb_flush_log_at_trx_commit  = 1
innodb_file_per_table           = 1
innodb_io_capacity              = ${CALC_DB_IO_CAP}
innodb_io_capacity_max          = ${CALC_DB_IO_CAP_MAX}
innodb_read_io_threads          = ${CALC_DB_IO_THREADS}
innodb_write_io_threads         = ${CALC_DB_IO_THREADS}
innodb_stats_on_metadata        = 0
slow_query_log                  = 1
slow_query_log_file             = ${DB_SLOW_LOG}
long_query_time                 = 1
log_slow_verbosity              = query_plan,explain
performance_schema              = OFF
EOF
}

# Write the tuning file; on change restart MariaDB and verify with a ping, else roll back.
lib_db_apply_tuning() {
  local prev=""
  lib_db_installed || { lib_info "MariaDB not installed; tuning skipped"; return 0; }
  if [[ -f "$MARIADB_TUNED_FILE" ]]; then prev="$(lib_mktemp)"; cp "$MARIADB_TUNED_FILE" "$prev"; fi
  lib_db_render_tuning | lib_write_file "$MARIADB_TUNED_FILE" 0644 root:root
  if (( ! LIB_FILE_CHANGED )); then lib_ok "MariaDB tuning already up to date"; return 0; fi
  (( OPT_DRY_RUN )) && return 0
  lib_info "Restarting MariaDB with the new tuning..."
  if lib_systemctl restart mariadb && lib_db_wait_ready 60; then
    lib_ok "MariaDB tuned and healthy (${MARIADB_TUNED_FILE})"
    return 0
  fi
  lib_error "MariaDB did not come back with the new tuning; restoring the previous configuration"
  if [[ -n "$prev" ]]; then cp "$prev" "$MARIADB_TUNED_FILE"; else rm -f "$MARIADB_TUNED_FILE"; fi
  lib_systemctl restart mariadb || true
  if lib_db_wait_ready 60; then
    lib_die "MariaDB rejected the tuning (previous settings restored, service is up)" \
      "innodb_buffer_pool_size / innodb_log_file_size too large for this host, or an unsupported option" \
      "journalctl -u mariadb; set DB_BUFFER_PERCENT lower and re-run"
  fi
  lib_die "MariaDB is DOWN even after restoring the previous configuration" "see journalctl -u mariadb" "fix the service manually"
}

# =============================================================================
#  Per-domain databases
# =============================================================================
lib_db_info_file() { printf '%s/db.info' "$(lib_domain_state_dir "$1")"; }

lib_db_info_load() {   # domain -> DBI_* ; returns 1 when missing
  local f=""; f="$(lib_db_info_file "$1")"
  DBI_NAME=""; DBI_USER=""; DBI_PASS=""; DBI_HOST="localhost"
  [[ -s "$f" ]] || return 1
  DBI_NAME="$(awk -F= '$1=="DB_NAME"{sub(/^[^=]*=/,""); print; exit}' "$f")"
  DBI_USER="$(awk -F= '$1=="DB_USER"{sub(/^[^=]*=/,""); print; exit}' "$f")"
  DBI_PASS="$(awk -F= '$1=="DB_PASS"{sub(/^[^=]*=/,""); print; exit}' "$f")"
  [[ -n "$DBI_NAME" ]]
}

_db_unique_name() {   # base kind(db|user) maxlen -> unique identifier
  local base="$1" kind="$2" max="$3" cand="" i=""
  cand="${base:0:$max}"
  for (( i = 2; i < 100; i++ )); do
    if [[ "$kind" == "db" ]]; then lib_db_exists "$cand" || { printf '%s' "$cand"; return 0; }
    else lib_db_user_exists "$cand" || { printf '%s' "$cand"; return 0; }; fi
    cand="${base:0:$(( max - 3 ))}_${i}"
  done
  return 1
}

# Base name for a site's database or user: the domain's FIRST label plus a suffix, so
# example.com becomes example_db and example_user. The label is truncated BEFORE the suffix
# is appended - doing it afterwards would eat the suffix on a long domain (MySQL caps user
# names at 32) and leave two names that no longer say which is which. Collisions between
# example.com and example.net are resolved afterwards by _db_unique_name, which appends _2.
_db_name_base() {   # domain suffix maxlen -> base
  local suffix="$2" max="$3" label="" id=""
  label="${1%%.*}"
  id="$(printf '%s' "${label,,}" | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')"
  [[ "$id" =~ ^[a-z] ]] || id="s_${id}"
  id="${id:0:$(( max - ${#suffix} - 1 ))}"
  printf '%s_%s' "$id" "$suffix"
}

# Create DB + user for a registered domain, store credentials (600).
lib_db_create_for_domain() {
  local domain="$1" dbbase="" userbase="" dbname="" dbuser="" dbpass="" info="" sql=""
  info="$(lib_db_info_file "$domain")"
  if lib_db_info_load "$domain"; then lib_ok "Database already exists for ${domain} (${DBI_NAME})"; return 0; fi
  lib_db_installed || lib_die "MariaDB is not installed" "run install first" "sudo ./setup.sh install"
  dbbase="$(_db_name_base "$domain" db 60)"
  userbase="$(_db_name_base "$domain" user 32)"
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would create database ${dbbase} with user ${userbase} and store ${info}"; return 0; fi
  lib_db_wait_ready 10 || lib_die "MariaDB not reachable" "service down" "systemctl status mariadb"
  dbname="$(_db_unique_name "$dbbase" db 60)"     || lib_die "Could not find a free database name" "too many collisions" "clean up old databases"
  dbuser="$(_db_unique_name "$userbase" user 32)" || lib_die "Could not find a free database user name" "too many collisions" "clean up old users"
  dbpass="$(lib_random_password 32)"
  sql="CREATE DATABASE \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '${dbuser}'@'localhost' IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'localhost';
FLUSH PRIVILEGES;"
  lib_db_sql_secret "create database ${dbname} and user ${dbuser}@localhost" "$sql" \
    || lib_die "Database creation failed for ${domain}" "SQL error (see log)" "check MariaDB state; re-run 'setup.sh db ${domain}'"
  lib_rollback_push "lib_db_drop_for_domain '${domain}' force"
  mkdir -p "$(dirname "$info")" && chmod 0700 "$(dirname "$info")"
  {
    printf '# MariaDB credentials for %s - created %s\n' "$domain" "$(lib_iso_now)"
    printf 'DB_NAME=%s\nDB_USER=%s\nDB_PASS=%s\nDB_HOST=localhost\nDB_SOCKET=%s\nDB_CHARSET=utf8mb4\n' "$dbname" "$dbuser" "$dbpass" "$DB_SOCKET"
  } >"$info"
  chmod 0600 "$info"
  lib_json_set "$(lib_domain_json "$domain")" '.db = {name:$n, user:$u, created_at:$ts}' --arg n "$dbname" --arg u "$dbuser" --arg ts "$(lib_iso_now)"
  lib_log_write INFO "database ${dbname} / user ${dbuser} created for ${domain}"
  lib_ok "Database ${dbname} with user ${dbuser}@localhost created"
  DBI_NAME="$dbname"; DBI_USER="$dbuser"; DBI_PASS="$dbpass"
}

lib_db_show() {   # print credentials (never logged)
  local domain="$1"
  lib_db_info_load "$domain" || { lib_info "No database registered for ${domain}"; return 0; }
  printf '\n%sDatabase credentials for %s%s\n' "$C_BLD" "$domain" "$C_RST"
  lib_print_kv "Database" "$DBI_NAME"
  lib_print_kv "User"     "$DBI_USER"
  lib_print_kv "Password" "$DBI_PASS"
  lib_print_kv "Host"     "localhost (socket ${DB_SOCKET})"
  lib_print_kv "Charset"  "utf8mb4 / utf8mb4_unicode_ci"
  printf '\n'
}

lib_db_drop_for_domain() {   # domain [force]
  local domain="$1" info=""
  info="$(lib_db_info_file "$domain")"
  lib_db_info_load "$domain" || return 0
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would drop database ${DBI_NAME} and user ${DBI_USER}"; return 0; fi
  lib_db_sql_secret "drop database ${DBI_NAME} and user ${DBI_USER}" \
    "DROP DATABASE IF EXISTS \`${DBI_NAME}\`; DROP USER IF EXISTS '${DBI_USER}'@'localhost'; FLUSH PRIVILEGES;" \
    || lib_warn "could not drop database ${DBI_NAME} (see log)"
  rm -f "$info"
  [[ -s "$(lib_domain_json "$domain")" ]] && lib_json_set "$(lib_domain_json "$domain")" 'del(.db)'
  lib_ok "Database ${DBI_NAME} and user ${DBI_USER} removed"
}

lib_db_dump_domain() {   # domain outfile.gz
  local domain="$1" out="$2"
  lib_db_info_load "$domain" || return 1
  (( OPT_DRY_RUN )) && return 0
  if ! "$(lib_db_dumper)" --protocol=socket --socket="$DB_SOCKET" --single-transaction --quick --routines --triggers --events \
        --default-character-set=utf8mb4 "$DBI_NAME" 2>>"$LOG_FILE" | gzip -c >"$out"; then
    rm -f "$out"; return 1
  fi
  chmod 0600 "$out"
}

lib_db_restore_domain() {   # domain dump.sql(.gz)
  local domain="$1" dump="$2"
  lib_db_info_load "$domain" || return 1
  (( OPT_DRY_RUN )) && return 0
  if [[ "$dump" == *.gz ]]; then
    gzip -dc "$dump" | "$(lib_db_client)" --protocol=socket --socket="$DB_SOCKET" "$DBI_NAME" 2>>"$LOG_FILE"
  else
    "$(lib_db_client)" --protocol=socket --socket="$DB_SOCKET" "$DBI_NAME" <"$dump" 2>>"$LOG_FILE"
  fi
}

# Recreate a DB/user from an archived db.info (restore on a fresh server).
lib_db_recreate_from_info() {   # domain infofile
  local domain="$1" src="$2" name="" user="" pass="" dest=""
  name="$(awk -F= '$1=="DB_NAME"{sub(/^[^=]*=/,""); print; exit}' "$src")"
  user="$(awk -F= '$1=="DB_USER"{sub(/^[^=]*=/,""); print; exit}' "$src")"
  pass="$(awk -F= '$1=="DB_PASS"{sub(/^[^=]*=/,""); print; exit}' "$src")"
  [[ -n "$name" && -n "$user" && -n "$pass" ]] || return 1
  (( OPT_DRY_RUN )) && return 0
  lib_db_sql_secret "recreate database ${name} and user ${user}" \
    "CREATE DATABASE IF NOT EXISTS \`${name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pass}';
ALTER USER '${user}'@'localhost' IDENTIFIED BY '${pass}';
GRANT ALL PRIVILEGES ON \`${name}\`.* TO '${user}'@'localhost';
FLUSH PRIVILEGES;" || return 1
  dest="$(lib_db_info_file "$domain")"
  mkdir -p "$(dirname "$dest")" && chmod 0700 "$(dirname "$dest")"
  cp "$src" "$dest" && chmod 0600 "$dest"
  lib_json_set "$(lib_domain_json "$domain")" '.db = {name:$n, user:$u, created_at:$ts}' --arg n "$name" --arg u "$user" --arg ts "$(lib_iso_now)"
}

# "db <domain>" command
# Every site's database, with sizes but WITHOUT passwords - those stay behind
# "credentials <domain>", which is the command that says out loud what it is printing.
lib_db_list() {
  local d="" size="" n=0
  lib_db_installed || { lib_note "MariaDB is not installed"; return 0; }
  printf '\n%s%-28s %-26s %-26s %9s%s\n' "$C_BLD" "SITE" "DATABASE" "USER" "SIZE" "$C_RST"
  while read -r d; do
    [[ -n "$d" ]] || continue
    n=$((n + 1))
    if lib_db_info_load "$d"; then
      size="$(lib_db_sql "SELECT IFNULL(ROUND(SUM(data_length+index_length)/1048576,1),0) FROM information_schema.tables WHERE table_schema='${DBI_NAME}'" 2>/dev/null || true)"
      printf '%-28s %-26s %-26s %6s MB\n' "$d" "$DBI_NAME" "$DBI_USER" "${size:-?}"
    else
      printf '%-28s %-26s %-26s %9s\n' "$d" "-" "-" "-"
    fi
  done < <(lib_domains_list)
  if (( n == 0 )); then lib_note "no sites registered yet (setup.sh add example.com)"; fi
  printf '\n'
  lib_note "passwords: setup.sh credentials <domain>"
  return 0
}

lib_db_main() {
  local domain="${1:-}"
  if [[ "$domain" == "list" || "$domain" == "--list" ]]; then
    lib_require_tools; lib_require_installed; lib_db_list; return 0
  fi
  [[ -n "$domain" ]] || lib_die "Usage: setup.sh db <domain>|list" "domain missing" "setup.sh db example.com"
  domain="${domain,,}"
  lib_domain_valid "$domain" || lib_die "Invalid domain name '${domain}'" "not a valid FQDN" "use e.g. example.com"
  lib_require_tools
  lib_domain_registered "$domain" || lib_die "Site ${domain} does not exist" "not registered in ${STATE_DIR}/domains" "add it first: setup.sh add ${domain}"
  lib_rollback_clear
  lib_db_create_for_domain "$domain"
  lib_rollback_clear
  lib_db_show "$domain"
}

# =============================================================================
#  Redis
# =============================================================================
lib_redis_installed() { lib_pkg_installed redis-server || lib_have redis-server; }
lib_redis_version()   { redis-server --version 2>/dev/null | grep -oE 'v=[0-9.]+' | cut -d= -f2 || true; }

lib_redis_password() {
  [[ -s "$REDIS_INFO" ]] || { printf ''; return 0; }
  awk -F= '$1=="PASSWORD"{sub(/^[^=]*=/,""); print; exit}' "$REDIS_INFO"
}

lib_redis_ping() {
  local pass=""; pass="$(lib_redis_password)"
  [[ "$(REDISCLI_AUTH="$pass" redis-cli -h 127.0.0.1 ping 2>/dev/null)" == "PONG" ]]
}

lib_redis_render_conf() {   # password persist(0/1)
  local pass="$1" persist="${2:-0}" bind="127.0.0.1"
  lib_system_profile
  if ip -6 addr show dev lo 2>/dev/null | grep -q '::1'; then bind="127.0.0.1 ::1"; fi
  cat <<EOF
# Managed by lompstack - included from ${REDIS_CONF} (regenerated by install/optimize)
bind ${bind}
protected-mode yes
port 6379
tcp-backlog 511
timeout 0
tcp-keepalive 300
requirepass ${pass}
maxmemory ${CALC_REDIS_MB}mb
maxmemory-policy allkeys-lru
EOF
  if (( persist )); then
    printf 'save 900 1\nsave 300 10\nsave 60 10000\nappendonly yes\nappendfsync everysec\n'
  else
    printf 'save ""\nappendonly no\n'
  fi
}

# lib_redis_install [persist(0/1)]
lib_redis_install() {
  local persist="${1:-0}" pass="" prev=""
  if lib_redis_installed; then lib_ok "Redis already installed ($(lib_redis_version))"
  else
    lib_apt_install redis-server redis-tools || lib_die "Redis installation failed" "apt error" "check the log"
    lib_ok "Redis installed ($( (( OPT_DRY_RUN )) && printf 'dry-run' || lib_redis_version))"
  fi
  pass="$(lib_redis_password)"
  if [[ -z "$pass" ]]; then
    pass="$(lib_random_password 32)"
    if (( ! OPT_DRY_RUN )); then
      mkdir -p "$STATE_DIR" && chmod 0700 "$STATE_DIR"
      printf '# Redis credentials - generated %s\nHOST=127.0.0.1\nPORT=6379\nPASSWORD=%s\n' "$(lib_iso_now)" "$pass" >"$REDIS_INFO"
      chmod 0600 "$REDIS_INFO"
      lib_ok "Redis password generated and stored in ${REDIS_INFO}"
    else
      lib_info "[dry-run] would generate the Redis password into ${REDIS_INFO}"
    fi
  fi
  if (( OPT_DRY_RUN )) && [[ ! -f "$REDIS_CONF" ]]; then lib_info "[dry-run] would configure ${REDIS_INCLUDE}"; return 0; fi
  [[ -f "$REDIS_CONF" ]] || lib_die "Redis configuration ${REDIS_CONF} missing" "unexpected package layout" "reinstall redis-server"

  [[ -f "$REDIS_INCLUDE" ]] && { prev="$(lib_mktemp)"; cp "$REDIS_INCLUDE" "$prev"; }
  lib_redis_render_conf "$pass" "$persist" | lib_write_file "$REDIS_INCLUDE" 0640 redis:redis
  local changed="$LIB_FILE_CHANGED"
  lib_append_line_once "$REDIS_CONF" "include ${REDIS_INCLUDE}"
  (( LIB_FILE_CHANGED )) && changed=1
  lib_systemd_override "$REDIS_SERVICE" "LimitNOFILE=65535"
  lib_systemctl enable "$REDIS_SERVICE" >/dev/null 2>&1 || true
  (( OPT_DRY_RUN )) && return 0
  if (( changed )) || ! lib_service_active "$REDIS_SERVICE"; then
    lib_systemctl restart "$REDIS_SERVICE" || true
    sleep 1
    if ! lib_redis_ping; then
      lib_error "Redis did not come up with the new configuration; restoring"
      if [[ -n "$prev" ]]; then cp "$prev" "$REDIS_INCLUDE"; else rm -f "$REDIS_INCLUDE"; sed -i "\#^include ${REDIS_INCLUDE}\$#d" "$REDIS_CONF"; fi
      lib_systemctl restart "$REDIS_SERVICE" || true
      lib_die "Redis rejected the generated configuration (previous state restored)" "unsupported directive or bind address" "journalctl -u redis-server"
    fi
    lib_ok "Redis configured: 127.0.0.1 only, auth enabled, maxmemory ${CALC_REDIS_MB} MB, persistence $( (( persist )) && printf 'on' || printf 'off (cache mode)')"
  else
    lib_redis_ping && lib_ok "Redis already configured and healthy" || lib_warn "Redis is running but did not answer PONG (check the password in ${REDIS_INFO})"
  fi
  lib_manifest_set '.components.redis' "$(lib_redis_version)"
  lib_manifest_set_json '.params.redis_persist' "$( (( persist )) && printf 'true' || printf 'false')"
}

lib_redis_show() {
  local pass=""; pass="$(lib_redis_password)"
  [[ -n "$pass" ]] || { lib_info "Redis is not configured"; return 0; }
  printf '\n%sRedis credentials%s\n' "$C_BLD" "$C_RST"
  lib_print_kv "Host / port" "127.0.0.1 / 6379"
  lib_print_kv "Password"    "$pass"
  printf '\n'
}
