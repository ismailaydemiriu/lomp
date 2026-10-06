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

# ---- more than one database for a site --------------------------------------------------
# A site has one database, made with it and named in db.info. An application may keep a
# second one (a forum beside the shop, a WordPress in a directory of its own), and "import"
# brings those along: each is a database of its own here, opened by the site's ONE database
# user with the site's one password. They are listed in db.extra beside db.info - "the name
# here<TAB>the name it had where it came from" - and whatever dumps, restores, grants or drops
# the site's database does the same for them.
lib_db_extra_file() { printf '%s/db.extra' "$(lib_domain_state_dir "$1")"; }

lib_db_extras() {   # domain -> "name here<TAB>name it came from", one a line
  local f=""
  f="$(lib_db_extra_file "$1")"
  [[ -s "$f" ]] || return 0
  awk -F'\t' '$1 ~ /^[A-Za-z0-9_]+$/ { print $1 "\t" $2 }' "$f" || true
  return 0
}

lib_db_extra_names() { lib_db_extras "$1" | cut -f1; }   # domain -> the names here

lib_db_extra_of() {   # domain, the name it came from -> its name here, or status 1
  local n=""
  n="$(lib_db_extras "$1" | awk -F'\t' -v o="$2" '$2 == o { print $1; exit }')"
  [[ -n "$n" ]] || return 1
  printf '%s' "$n"
}

# The site's database user on one more database - on the socket, and over TCP where the site
# has that login too (a Node.js application's).
_db_extra_grant() {   # database  (the site's login in DBI_*)
  local sql=""
  sql="CREATE DATABASE IF NOT EXISTS \`${1}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`${1}\`.* TO '${DBI_USER}'@'localhost';"
  if [[ "$(lib_db_sql "SELECT COUNT(*) FROM mysql.user WHERE User='${DBI_USER}' AND Host='127.0.0.1'" 2>/dev/null || true)" == "1" ]]; then
    sql+="
GRANT ALL PRIVILEGES ON \`${1}\`.* TO '${DBI_USER}'@'127.0.0.1';"
  fi
  lib_db_sql "${sql}
FLUSH PRIVILEGES;" >/dev/null
}

# One more database for a site: made, opened to the site's user, and written down. The name
# is the site's own with a number, as a second site of the same name would get. DBX_NAME.
DBX_NAME=""
lib_db_extra_add() {   # domain, the name it came from
  local domain="$1" origin="$2" name="" f=""
  DBX_NAME=""
  lib_db_info_load "$domain" || return 1
  if name="$(lib_db_extra_of "$domain" "$origin")"; then
    DBX_NAME="$name"
    lib_db_exists "$name" || _db_extra_grant "$name" || return 1
    return 0
  fi
  name="$(_db_unique_name "$(_db_name_base "$domain" db 60)" db 60)" || return 1
  [[ "$name" =~ ^[A-Za-z0-9_]+$ && "$origin" != *$'\t'* && "$origin" != *$'\n'* ]] || return 1
  _db_extra_grant "$name" || return 1
  f="$(lib_db_extra_file "$domain")"
  printf '%s\t%s\n' "$name" "$origin" >>"$f" && chmod 0600 "$f" || return 1
  lib_json_set "$(lib_domain_json "$domain")" '.db.extra = ((.db.extra // []) + [$n] | unique)' --arg n "$name"
  lib_log_write INFO "database ${name} added to ${domain} (it was ${origin} where it came from)"
  DBX_NAME="$name"
}

lib_db_dump_name() {   # database, outfile.gz
  (( OPT_DRY_RUN )) && return 0
  if ! "$(lib_db_dumper)" --protocol=socket --socket="$DB_SOCKET" --single-transaction --quick --routines --triggers --events \
        --default-character-set=utf8mb4 "$1" 2>>"$LOG_FILE" | gzip -c >"$2"; then
    rm -f "$2"; return 1
  fi
  chmod 0600 "$2"
}

lib_db_restore_name() {   # database, dump.sql.gz
  (( OPT_DRY_RUN )) && return 0
  gzip -dc "$2" | "$(lib_db_client)" --protocol=socket --socket="$DB_SOCKET" "$1" 2>>"$LOG_FILE"
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
  local x="" o=""
  while IFS=$'\t' read -r x o; do
    [[ -n "$x" ]] || continue
    lib_print_kv "One more database" "${x} (the same user and password)${o:+; it was ${o} where it came from}"
  done < <(lib_db_extras "$domain")
  printf '\n'
}

# Let the site's database user log in over TCP from 127.0.0.1 too. Node.js drivers and ORMs
# connect to host:port, and with skip-name-resolve a 'localhost' account only matches
# connections through the socket. MariaDB itself listens on 127.0.0.1 only.
lib_db_tcp_account_ensure() {   # domain
  lib_db_info_load "$1" || return 1
  lib_db_sql_secret "allow ${DBI_USER} to log in from 127.0.0.1" \
    "CREATE USER IF NOT EXISTS '${DBI_USER}'@'127.0.0.1' IDENTIFIED BY '${DBI_PASS}';
ALTER USER '${DBI_USER}'@'127.0.0.1' IDENTIFIED BY '${DBI_PASS}';
GRANT ALL PRIVILEGES ON \`${DBI_NAME}\`.* TO '${DBI_USER}'@'127.0.0.1';
$(lib_db_extra_names "$1" | sed -e "s/.*/GRANT ALL PRIVILEGES ON \`&\`.* TO '${DBI_USER}'@'127.0.0.1';/")
FLUSH PRIVILEGES;"
}

lib_db_drop_for_domain() {   # domain [force]
  local domain="$1" info=""
  info="$(lib_db_info_file "$domain")"
  lib_db_info_load "$domain" || return 0
  local more=""
  more="$(lib_db_extra_names "$domain" | tr '\n' ' ')"
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would drop database ${DBI_NAME}${more:+ and ${more% }} and user ${DBI_USER}"; return 0; fi
  lib_db_sql_secret "drop database ${DBI_NAME} and user ${DBI_USER}" \
    "$(lib_db_extra_names "$domain" | sed -e 's/.*/DROP DATABASE IF EXISTS `&`;/') DROP DATABASE IF EXISTS \`${DBI_NAME}\`; DROP USER IF EXISTS '${DBI_USER}'@'localhost'; DROP USER IF EXISTS '${DBI_USER}'@'127.0.0.1'; FLUSH PRIVILEGES;" \
    || lib_warn "could not drop database ${DBI_NAME} (see log)"
  rm -f "$info" "$(lib_db_extra_file "$domain")"
  [[ -s "$(lib_domain_json "$domain")" ]] && lib_json_set "$(lib_domain_json "$domain")" 'del(.db)'
  lib_ok "Database ${DBI_NAME}${more:+ and ${more% }} and user ${DBI_USER} removed"
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
  # A real run gets DBI_* from the db.info this copies into place, by way of the
  # lib_db_info_load inside lib_db_restore_domain. A dry run copies nothing and stops here,
  # so it names the database itself - "would import db-x.sql.gz into " read as if the dump
  # were going nowhere. The password is left out: nothing in a dry run has a use for it.
  if (( OPT_DRY_RUN )); then DBI_NAME="$name"; DBI_USER="$user"; return 0; fi
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
  lib_tprintf '\n%s%-28s %-26s %-26s %9s%s\n' "$C_BLD" "SITE" "DATABASE" "USER" "SIZE" "$C_RST"
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

# Put a new password into the site's db.info. It travels in the environment: awk's -v would
# interpret backslashes, and a command line can be read by every user on the machine.
_db_info_set_pass() {   # domain password
  local f=""
  f="$(lib_db_info_file "$1")"
  LOMP_DB_NEW_PASS="$2" awk -F= '$1 == "DB_PASS" { print "DB_PASS=" ENVIRON["LOMP_DB_NEW_PASS"]; done = 1; next }
    { print }
    END { if (!done) print "DB_PASS=" ENVIRON["LOMP_DB_NEW_PASS"] }' "$f" | lib_write_file "$f" 0600 "" secret
}

# The Node.js application of a site reads the database login from its environment
# ("app env import-db" puts it there, as DB_PASSWORD and inside DATABASE_URL). Wherever the old
# password stands in a value, the new one takes its place. Status 1 when nothing held it.
_db_passwd_app_env() {   # domain old new
  local f=""
  f="$(lib_app_env_file "$1")"
  [[ -s "$f" && -n "$2" ]] || return 1
  LOMP_DB_OLD_PASS="$2" jq -e 'type == "object" and any(.[]; type == "string" and contains($ENV.LOMP_DB_OLD_PASS))' "$f" >/dev/null 2>&1 || return 1
  export LOMP_DB_OLD_PASS="$2" LOMP_DB_NEW_PASS="$3"
  lib_json_set "$f" 'map_values(if type == "string" then split($ENV.LOMP_DB_OLD_PASS) | join($ENV.LOMP_DB_NEW_PASS) else . end)'
  unset LOMP_DB_OLD_PASS LOMP_DB_NEW_PASS
}

# "db passwd <domain>": a new random password for the site's database user. MariaDB, db.info
# and the two places lompstack itself wrote the old one into (the environment of a Node.js
# application, the wp-config.php of a WordPress) all get it. A configuration file somebody
# wrote by hand is not ours to edit, so the command ends by printing the new login.
lib_db_passwd() {   # domain
  local domain="$1" old="" new=""
  lib_db_info_load "$domain" || lib_die "${domain} has no database" "no db.info for this site" "create one with: setup.sh db ${domain}"
  lib_db_installed || lib_die "MariaDB is not installed" "run install first" "sudo ./setup.sh install"
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would give ${DBI_USER} (database ${DBI_NAME}) a new random password"; return 0; fi
  lib_confirm "Give ${DBI_USER} a new random password? A site that keeps the old one in its own config file cannot connect until it has the new one." n \
    || lib_die "Password of ${DBI_USER} left as it was" "not confirmed" "answer y, or add --yes"
  lib_db_wait_ready 10 || lib_die "MariaDB not reachable" "service down" "systemctl status mariadb"
  old="$DBI_PASS"
  new="$(lib_random_password 32)"
  # the 127.0.0.1 account exists only where a Node.js application asked for it
  lib_db_sql_secret "new password for ${DBI_USER}" \
    "ALTER USER '${DBI_USER}'@'localhost' IDENTIFIED BY '${new}';
ALTER USER IF EXISTS '${DBI_USER}'@'127.0.0.1' IDENTIFIED BY '${new}';
FLUSH PRIVILEGES;" \
    || lib_die "Could not change the password of ${DBI_USER}" "SQL error (see log)" "check MariaDB state; the old password still works"
  _db_info_set_pass "$domain" "$new"
  lib_log_write INFO "database user ${DBI_USER} of ${domain} got a new password (value not logged)"
  lib_ok "${DBI_USER} has a new password"

  lib_domain_state_load "$domain" || true
  if _db_passwd_app_env "$domain" "$old" "$new"; then
    lib_ok "the application's environment variables carry the new password"
    if lib_app_state_load "$domain"; then
      _app_site_lock "$domain"
      lib_app_apply restart
      _app_report soft
    fi
  fi
  if (( D_WP )); then
    # --quiet: wp-cli's "Success" line repeats the value, and that output goes to the log
    if [[ -x "$WPCLI_BIN" ]] && lib_run_secret "wp config set DB_PASSWORD (${domain})" _wp config set DB_PASSWORD "$new" --type=constant --quiet; then
      lib_ok "wp-config.php carries the new password"
    else
      lib_warn "could not write the new password into ${D_HOME}/public_html/wp-config.php; set DB_PASSWORD there by hand"
    fi
  fi
  lib_db_show "$domain"
  lib_note "a site with its own config file (config.php, .env ...) needs this password put into it"
}

lib_db_main() {
  local domain="${1:-}"
  if [[ "$domain" == "list" || "$domain" == "--list" ]]; then
    lib_require_tools; lib_require_installed; lib_db_list; return 0
  fi
  if [[ "$domain" == "passwd" ]]; then
    domain="${2:-}"; domain="${domain,,}"
    [[ -n "$domain" ]] || lib_die "Usage: setup.sh db passwd <domain>" "domain missing" "setup.sh db passwd example.com"
    lib_domain_valid "$domain" || lib_die "Invalid domain name '${domain}'" "not a valid FQDN" "use e.g. example.com"
    lib_require_tools
    lib_domain_registered "$domain" || lib_die "Site ${domain} does not exist" "not registered in ${STATE_DIR}/domains" "setup.sh list"
    lib_db_passwd "$domain"
    return 0
  fi
  [[ -n "$domain" ]] || lib_die "Usage: setup.sh db <domain>|list|passwd <domain>" "domain missing" "setup.sh db example.com"
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
