#!/usr/bin/env bash
# tests/unit.sh - offline unit tests for the pure bash/awk logic of setup.sh.
# Runs without root and without network on any machine with bash 5, awk, jq, openssl.
#   bash tests/unit.sh
set -Eeuo pipefail
shopt -s lastpipe
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(dirname "$HERE")"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ss-unit.XXXXXX")"
cleanup() { rm -rf "$TMP"; }

# ---- globals normally provided by setup.sh (all paths redirected into TMP) --
SCRIPT_VERSION="test"
TIMEZONE="Europe/Istanbul"; ADMIN_PORT="7574"; PHP_VERSION="8.3"; ADMIN_ACCESS="tunnel"; ADMIN_ALLOWED_IP=""; DEFAULT_EMAIL=""; SSH_PORT=""
DB_BUFFER_PERCENT=""; REDIS_MAX_PERCENT=""; BACKUP_KEEP="7"; BACKUP_SCHEDULE=""; FAIL2BAN_IGNORE_IP=""
STATE_DIR="$TMP/state"; SITES_ROOT="$TMP/home"; LSWS_HOME="$TMP/lsws"; LOG_FILE="$TMP/server_setup.log"
BACKUP_ROOT="$TMP/backups"; ACME_ROOT="$TMP/acme"; SSL_DEPLOY_DIR="$TMP/ssl"
SYSCTL_FILE="$TMP/sysctl.conf"; LIMITS_FILE="$TMP/limits.conf"; MARIADB_TUNED_FILE="$TMP/60-tuned.cnf"
FAIL2BAN_JAIL_FILE="$TMP/jail.conf"; FAIL2BAN_WEB_JAIL_FILE="$TMP/jail-web.conf"; CRON_FILE="$TMP/cron"
FAIL2BAN_FILTER_DIR="$TMP/f2b-filters"
CERTBOT_DEPLOY_HOOK="$TMP/hook.sh"; LOGROTATE_SITES_FILE="$TMP/lr-sites"; LOGROTATE_SELF_FILE="$TMP/lr-self"
INSTALL_DIR="$TMP/install"; BIN_LINK="$TMP/lompstack"; BIN_SHORT="$TMP/lomp"; LOCK_FILE="$TMP/lock"
OPT_YES=1 OPT_DRY_RUN=0 OPT_QUIET=1 OPT_VERBOSE=0 OPT_NO_COLOR=1 OPT_JSON=0 OPT_NON_INTERACTIVE=1
SCRIPT_PATH="$ROOT/setup.sh"; SCRIPT_DIR="$ROOT"
export TMPDIR="$TMP"
for m in common system ols php db ssl domain cloudflare backup monitor install; do
  # shellcheck source=/dev/null
  source "$ROOT/lib/$m.sh"
done
trap cleanup EXIT
mkdir -p "$STATE_DIR" "$LSWS_HOME/conf/vhosts" "$SITES_ROOT"; : >"$LOG_FILE"
chown() { return 0; }   # no lsadm/site users on the test machine

# Some filesystems (MSYS/NTFS under Git Bash) ignore chmod, so permission assertions
# only run where they are meaningful. On Linux and in CI they always run.
CAN_CHMOD=0
: >"$TMP/.permprobe"; chmod 0600 "$TMP/.permprobe" 2>/dev/null || true
[[ "$(stat -c %a "$TMP/.permprobe" 2>/dev/null || true)" == "600" ]] && CAN_CHMOD=1
rm -f "$TMP/.permprobe"
# MSYS under Git Bash copies instead of linking, so symlink assertions only run elsewhere
CAN_SYMLINK=0
: >"$TMP/.symtarget"
ln -sfn "$TMP/.symtarget" "$TMP/.symprobe" 2>/dev/null && [[ -L "$TMP/.symprobe" ]] && CAN_SYMLINK=1
rm -f "$TMP/.symprobe" "$TMP/.symtarget"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*" >&2; }
assert_eq()    { if [[ "$2" == "$3" ]]; then ok; else fail "$1: expected [$2] got [$3]"; fi; }
assert_true()  { local n="$1"; shift; if "$@"; then ok; else fail "$n"; fi; }
assert_false() { local n="$1"; shift; if "$@"; then fail "$n (expected failure)"; else ok; fi; }
assert_has()   { if [[ "$3" == *"$2"* ]]; then ok; else fail "$1: missing [$2]"; fi; }
assert_lacks() { if [[ "$3" != *"$2"* ]]; then ok; else fail "$1: unexpected [$2]"; fi; }
section() { printf '%s\n' "-- $*"; }
# Run a function the way the installer does (errexit armed) and report its exit status.
# A plain "if func; then" would disable errexit and hide exactly the bugs we look for.
run_isolated() { local rc=0; ( set -Eeuo pipefail; shopt -s lastpipe; "$@" ) >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

# =============================================================================
section "domain helpers"
assert_true  "valid example.com"       lib_domain_valid example.com
assert_true  "valid sub.example.co.uk" lib_domain_valid sub.example.co.uk
assert_true  "valid uppercase"         lib_domain_valid EXAMPLE.COM
assert_false "invalid leading dash"    lib_domain_valid -bad.com
assert_false "invalid no dot"          lib_domain_valid localhost
assert_false "invalid double dot"      lib_domain_valid a..b.com
assert_false "invalid underscore"      lib_domain_valid exa_mple.com
assert_eq "ident example.com" "example_com" "$(lib_domain_ident example.com)"
assert_eq "ident digits first" "s_123_com" "$(lib_domain_ident 123.com)"
assert_eq "ident dashes" "my_site_co_uk" "$(lib_domain_ident my-site.co.uk)"
assert_eq "ident length" 28 "$(lib_domain_ident averyveryveryverylongdomainname.example.com | wc -c | tr -d ' ')"
assert_eq "size 64M" 64 "$(lib_size_to_mb 64M)"
assert_eq "size 1G" 1024 "$(lib_size_to_mb 1G)"
assert_eq "size empty" 0 "$(lib_size_to_mb "")"
assert_true "version ge" lib_version_ge 10.11.2 10.6
assert_false "version lt" lib_version_ge 10.6.12 10.11
assert_eq "human mb" "2.0 GB" "$(lib_human_mb 2048)"
assert_eq "password length" 32 "$(lib_random_password | wc -c | tr -d ' ')"
is_alnum20() { [[ "$1" =~ ^[A-Za-z0-9]{20}$ ]]; }
assert_true "password alnum" is_alnum20 "$(lib_random_password 20)"

# =============================================================================
section "secret masking"
m() { printf '%s' "$1" | lib_mask_secrets; }
assert_eq "mask password=" "password=********" "$(m 'password=abc123')"
assert_eq "mask PASSWORD: quoted" "PASSWORD: '********'" "$(m "PASSWORD: 'abc123'")"
assert_eq "mask identified by" "IDENTIFIED BY '********'" "$(m "IDENTIFIED BY 'S3cr3t!'")"
assert_eq "mask bearer" "Authorization: Bearer ********" "$(m 'Authorization: Bearer abcDEF.123-x')"
assert_eq "mask cf token" "dns_cloudflare_api_token = ********" "$(m 'dns_cloudflare_api_token = q1w2e3r4')"
assert_eq "mask pass:" "-pass pass:********" "$(m '-pass pass:hunter2')"
assert_eq "mask telegram url" "https://api.telegram.org/bot********/sendMessage" "$(m 'https://api.telegram.org/bot123:ABC/sendMessage')"
assert_eq "no false positive" "wrote /etc/ssh/sshd_config.d/99-server-setup.conf" "$(m 'wrote /etc/ssh/sshd_config.d/99-server-setup.conf')"
assert_eq "no mask PasswordAuthentication" "PasswordAuthentication no" "$(m 'PasswordAuthentication no')"

# =============================================================================
section "OpenLiteSpeed config editing (awk)"
cat >"$LSWS_CONF" <<'EOF'
#
# PLAIN TEXT CONFIGURATION FILE
#
serverName
user                             nobody
group                            nogroup
showVersionNumber                0
adminEmails                      root@localhost

tuning{
    maxConnections               10000
    maxSSLConnections            10000
    keepAliveTimeout             5
    quicEnable                   1
}

accessControl{
	allow                                   ALL
	deny
}

extProcessor lsphp{
    type                            lsapi
    address                         uds://tmp/lshttpd/lsphp.sock
    env                             PHP_LSAPI_CHILDREN=10
    path                            fcgi-bin/lsphp
}

scriptHandler{
    add lsapi:lsphp  php
}

virtualHost Example{
    vhRoot                   Example/
    configFile               conf/vhosts/Example/vhconf.conf
    setUIDMode               0
}

listener Default{
    address                  *:8088
    secure                   0
    map                      Example *
}

module cache {
    ls_enabled          1
    enableCache         0
}
EOF
lib_ols_tx_begin
assert_eq "top get showVersionNumber" "0" "$(lib_ols_tx_top_get showVersionNumber)"
assert_eq "top get user" "nobody" "$(lib_ols_tx_top_get user)"
assert_eq "top get missing" "" "$(lib_ols_tx_top_get httpdWorkers)"
lib_ols_tx_top_set httpdWorkers 2
assert_eq "top set new key" "2" "$(lib_ols_tx_top_get httpdWorkers)"
assert_true "new key placed before first block" bash -c "awk '/^httpdWorkers/{k=NR} /^tuning/{t=NR} END{exit !(k && t && k<t)}' '$OLS_TX_FILE'"
lib_ols_tx_top_set showVersionNumber 0
assert_eq "top set existing (idempotent)" "1" "$(grep -c '^showVersionNumber' "$OLS_TX_FILE")"
lib_ols_tx_top_set adminEmails "admin@example.com"
assert_eq "top set existing value" "admin@example.com" "$(lib_ols_tx_top_get adminEmails)"
assert_eq "block get tuning key" "10000" "$(lib_ols_tx_block_get tuning "" maxConnections)"
lib_ols_tx_block_set tuning "" maxConnections 5000
assert_eq "block set tuning key" "5000" "$(lib_ols_tx_block_get tuning "" maxConnections)"
lib_ols_tx_block_set tuning "" totalInMemCacheSize 64M
assert_eq "block set new tuning key" "64M" "$(lib_ols_tx_block_get tuning "" totalInMemCacheSize)"
assert_eq "tuning still one block" "1" "$(grep -c '^tuning' "$OLS_TX_FILE")"
assert_true  "block exists case-insensitive" lib_ols_tx_block_exists virtualhost Example
assert_true  "block exists extprocessor" lib_ols_tx_block_exists extprocessor lsphp
assert_false "block not exists" lib_ols_tx_block_exists virtualhost Nope
assert_eq "extprocessor path get" "fcgi-bin/lsphp" "$(lib_ols_tx_block_get extprocessor lsphp path)"
lib_ols_tx_block_set extprocessor lsphp path /usr/local/lsws/lsphp83/bin/lsphp
assert_eq "extprocessor path set" "/usr/local/lsws/lsphp83/bin/lsphp" "$(lib_ols_tx_block_get extprocessor lsphp path)"
assert_eq "listener Default address" "*:8088" "$(lib_ols_tx_block_get listener Default address)"
lib_ols_tx_block_remove virtualhost Example
assert_false "block removed" lib_ols_tx_block_exists virtualhost Example
assert_true  "other blocks intact after remove" lib_ols_tx_block_exists listener Default
lib_ols_tx_block_remove listener Default
assert_false "listener removed" lib_ols_tx_block_exists listener Default
assert_true "braces balanced after edits" _ols_braces_balanced "$OLS_TX_FILE"

SYS_IPV6=0
_ols_tx_listeners_ensure
assert_true "listener HTTP created" lib_ols_tx_block_exists listener HTTP
assert_true "listener HTTPS created" lib_ols_tx_block_exists listener HTTPS
assert_eq "HTTP address" "*:80" "$(lib_ols_tx_block_get listener HTTP address)"
assert_eq "HTTPS sslProtocol" "24" "$(lib_ols_tx_block_get listener HTTPS sslProtocol)"
assert_eq "HTTPS default map" "*" "$(lib_ols_tx_map_get HTTPS _default)"
_ols_tx_listeners_ensure
assert_eq "listeners ensure idempotent" "1" "$(grep -c '^listener HTTPS' "$OLS_TX_FILE")"
assert_eq "map lines not duplicated" "1" "$(awk '/^listener HTTPS/,/^}/' "$OLS_TX_FILE" | grep -c 'map ')"
lib_ols_tx_map_set HTTP example.com "example.com, www.example.com"
assert_eq "map set" "example.com, www.example.com" "$(lib_ols_tx_map_get HTTP example.com)"
lib_ols_tx_map_set HTTP example.com "example.com"
assert_eq "map replace" "example.com" "$(lib_ols_tx_map_get HTTP example.com)"
assert_eq "map count" "2" "$(awk '/^listener HTTP \{/,/^}/' "$OLS_TX_FILE" | grep -c 'map ')"
lib_ols_tx_map_del HTTP example.com
assert_eq "map del" "" "$(lib_ols_tx_map_get HTTP example.com)"
assert_eq "default map kept" "*" "$(lib_ols_tx_map_get HTTP _default)"
lib_ols_render_extprocessor 8.3 12 | lib_ols_tx_block_put extprocessor lsphp83
assert_eq "extprocessor put" "12" "$(lib_ols_tx_block_get extprocessor lsphp83 maxConns)"
lib_ols_render_extprocessor 8.3 6 | lib_ols_tx_block_put extprocessor lsphp83
assert_eq "extprocessor replace" "6" "$(lib_ols_tx_block_get extprocessor lsphp83 maxConns)"
assert_eq "extprocessor single" "1" "$(grep -c '^extprocessor lsphp83' "$OLS_TX_FILE")"
assert_eq "block names" "$(printf 'lsphp\nlsphp83')" "$(_ols_block_names "$OLS_TX_FILE" extprocessor)"
assert_true "braces balanced after listeners" _ols_braces_balanced "$OLS_TX_FILE"
lib_ols_tx_commit
assert_eq "commit changed" "1" "$OLS_CONF_CHANGED"
assert_true "committed file balanced" _ols_braces_balanced "$LSWS_CONF"
lib_ols_tx_begin; lib_ols_tx_commit
assert_eq "commit idempotent" "0" "$OLS_CONF_CHANGED"
assert_eq "conf vhosts after edits" "" "$(lib_ols_conf_vhosts)"

# heredoc awareness
cat >"$TMP/vh.conf" <<'EOF'
docRoot                   $VH_ROOT/public_html/
rewrite  {
  enable                  1
  rules                   <<<END_rules
RewriteCond %{HTTPS} !on
RewriteRule ^(.*)$ https://%{HTTP_HOST}$1 [R=301,L]
# a stray { brace } inside the heredoc must be ignored
  END_rules
}
context / {
  location                $VH_ROOT/public_html/
  allowBrowse             1
}
EOF
assert_true "heredoc braces balanced" _ols_braces_balanced "$TMP/vh.conf"
assert_eq "span skips heredoc" "2 9" "$(_ols_span "$TMP/vh.conf" rewrite "")"
assert_eq "context key after heredoc" "1" "$(_ols_block_key "$TMP/vh.conf" context / allowBrowse get)"
printf 'a {\n  b {\n}\n' >"$TMP/bad.conf"
assert_false "unbalanced detected" _ols_braces_balanced "$TMP/bad.conf"

# =============================================================================
section "profile calculation"
SYS_ANALYZED=1; SYS_RAM_MB=4096; SYS_RAM_AVAIL_MB=3000; SYS_CPU_CORES=2; SYS_DISK_TYPE=ssd; SYS_SWAP_MB=0
lib_system_profile
assert_eq "db buffer pct 4G" 40 "$CALC_DB_BUFFER_PCT"
assert_eq "db buffer mb" 1632 "$CALC_DB_BUFFER_MB"
assert_eq "db log mb" 408 "$CALC_DB_LOG_MB"
assert_eq "db max conn" 256 "$CALC_DB_MAX_CONN"
assert_eq "db io cap ssd" 1000 "$CALC_DB_IO_CAP"
assert_eq "redis mb" 327 "$CALC_REDIS_MB"
assert_eq "php memory" 256 "$CALC_PHP_MEMORY_MB"
assert_eq "opcache" 192 "$CALC_OPCACHE_MB"
assert_eq "ols workers" 2 "$CALC_OLS_WORKERS"
assert_eq "ols max conn" 5000 "$CALC_OLS_MAX_CONN"
assert_eq "no swap needed at 4G" 0 "$CALC_SWAP_MB"
assert_true "php children sane" bash -c "(( $CALC_PHP_CHILDREN_SITE >= 2 && $CALC_PHP_CHILDREN_SITE <= 8 && $CALC_PHP_CHILDREN_TOTAL >= $CALC_PHP_CHILDREN_SITE ))"
SYS_RAM_MB=1024; SYS_DISK_TYPE=nvme; lib_system_profile
assert_eq "db buffer pct 1G" 25 "$CALC_DB_BUFFER_PCT"
assert_eq "swap 1G" 2048 "$CALC_SWAP_MB"
assert_eq "io cap nvme" 2000 "$CALC_DB_IO_CAP"
assert_eq "redis min 64" 64 "$CALC_REDIS_MB"
SYS_RAM_MB=512; lib_system_profile; assert_eq "swap 512M" 1024 "$CALC_SWAP_MB"
DB_BUFFER_PERCENT=60; SYS_RAM_MB=8192; lib_system_profile
assert_eq "db pct override" 60 "$CALC_DB_BUFFER_PCT"; assert_eq "db mb override" 4912 "$CALC_DB_BUFFER_MB"
DB_BUFFER_PERCENT=""; SYS_RAM_MB=4096; SYS_DISK_TYPE=ssd; lib_system_profile
out="$(lib_db_render_tuning)"
assert_has "tuning buffer pool" "innodb_buffer_pool_size         = 1632M" "$out"
assert_has "tuning max conn" "max_connections                 = 256" "$out"
assert_has "tuning bind" "bind-address                    = 127.0.0.1" "$out"
out="$(lib_php_render_ini)"
assert_has "php ini memory" "memory_limit = 256M" "$out"
assert_has "php ini opcache" "opcache.memory_consumption = 192" "$out"
assert_has "php ini tz" "date.timezone = Europe/Istanbul" "$out"
out="$(lib_redis_render_conf secretpass 0)"
assert_has "redis pass" "requirepass secretpass" "$out"
assert_has "redis maxmemory" "maxmemory 327mb" "$out"
assert_has "redis no persistence" 'save ""' "$out"
out="$(lib_redis_render_conf secretpass 1)"
assert_has "redis persistence" "appendonly yes" "$out"
out="$(lib_system_render_sysctl)"; assert_has "sysctl header" "Managed by lompstack" "$out"
out="$(lib_system_render_limits)"; assert_has "limits nofile" "nofile  1048576" "$out"

# =============================================================================
section "vhost templates"
lib_domain_state_reset
D_DOMAIN="example.com"; D_IDENT="example_com"; D_USER="example_com"; D_GROUP="example_com"; D_HOME="$SITES_ROOT/example.com"
D_MODE="php"; D_PHP="8.3"; D_PHP_CHILDREN=4; D_MEMORY="256M"; D_UPLOAD="64M"; D_WWW=1; D_SSL=1; D_HSTS_PRELOAD=0; D_EMAIL="a@example.com"
out="$(lib_ols_render_vhconf)"; printf '%s\n' "$out" >"$TMP/php.vhconf"
assert_true "php vhconf balanced" _ols_braces_balanced "$TMP/php.vhconf"
assert_has "php extprocessor" "extprocessor example_com {" "$out"
assert_has "php extUser" "extUser                 example_com" "$out"
assert_has "php post size" "post_max_size 72M" "$out"
assert_has "php sessions path" "session.save_path $SITES_ROOT/example.com/private/sessions" "$out"
assert_has "www alias" "vhAliases                 www.example.com" "$out"
assert_has "www redirect" 'RewriteCond %{HTTP_HOST} ^www\.example\.com$ [NC]' "$out"
assert_has "https redirect" 'RewriteRule ^(.*)$ https://%{HTTP_HOST}$1 [R=301,L]' "$out"
assert_has "hsts" "Strict-Transport-Security: max-age=31536000; includeSubDomains" "$out"
assert_lacks "no preload" "preload" "$out"
assert_has "vhssl" "vhssl  {" "$out"
assert_has "vhssl key" "keyFile                 $SSL_DEPLOY_DIR/example.com/privkey.pem" "$out"
assert_has "dotfile block" 'RewriteRule ^/?\.(?!well-known/) - [F,L]' "$out"
assert_has "acme context" "context /.well-known/acme-challenge/ {" "$out"
assert_eq "rewrite heredoc terminated" "1" "$(grep -c '^  END_rules$' "$TMP/php.vhconf")"
assert_eq "extraHeaders heredoc terminated" "1" "$(grep -c '^  END_extraHeaders$' "$TMP/php.vhconf")"
D_SSL=0; D_WWW=0; D_MODE="static"
out="$(lib_ols_render_vhconf)"; printf '%s\n' "$out" >"$TMP/static.vhconf"
assert_true "static vhconf balanced" _ols_braces_balanced "$TMP/static.vhconf"
assert_lacks "static no scripthandler" "scripthandler" "$out"
assert_lacks "static no vhssl" "vhssl" "$out"
assert_lacks "static no https redirect" "https://%{HTTP_HOST}" "$out"
D_MODE="proxy"; D_PROXY="127.0.0.1:3000"; D_WS_PATH="/socket.io"
out="$(lib_ols_render_vhconf)"; printf '%s\n' "$out" >"$TMP/proxy.vhconf"
assert_true "proxy vhconf balanced" _ols_braces_balanced "$TMP/proxy.vhconf"
assert_has "proxy extprocessor" "extprocessor example_com_proxy {" "$out"
assert_has "proxy context" "handler                 example_com_proxy" "$out"
assert_has "proxy static ctx" "context /static/ {" "$out"
assert_has "websocket" "websocket /socket.io {" "$out"
D_MODE="wordpress"; D_PHP="8.3"
out="$(lib_ols_render_vhconf)"; printf '%s\n' "$out" >"$TMP/wp.vhconf"
assert_true "wp vhconf balanced" _ols_braces_balanced "$TMP/wp.vhconf"
assert_has "wp cache module" "module cache {" "$out"
assert_has "wp htaccess" "autoLoadHtaccess        1" "$out"
lib_ols_render_default_vhconf >"$TMP/default.vhconf"
assert_true "default vhconf balanced" _ols_braces_balanced "$TMP/default.vhconf"
lib_ols_render_vhost_block example.com 1 >"$TMP/vhblock.conf"
assert_true "vhost block balanced" _ols_braces_balanced "$TMP/vhblock.conf"
assert_has "vhost block root" "vhRoot                  $SITES_ROOT/example.com/" "$(cat "$TMP/vhblock.conf")"
lib_ssl_hook_render >"$TMP/hook.sh"
assert_true "deploy hook parses" bash -n "$TMP/hook.sh"

# =============================================================================
section "state / manifest / cron / files"
lib_state_init
assert_true "manifest valid" lib_json_valid "$STATE_DIR/manifest.json"
lib_manifest_set '.params.timezone' 'Europe/Istanbul'
assert_eq "manifest get" "Europe/Istanbul" "$(lib_manifest_get '.params.timezone')"
lib_manifest_set_json '.cloudflare.enabled' true
assert_eq "manifest json bool" "true" "$(lib_manifest_get '.cloudflare.enabled')"
assert_true "cf enabled helper" lib_cf_enabled
lib_domain_state_reset
D_DOMAIN="example.com"; D_IDENT="example_com"; D_USER="example_com"; D_GROUP="example_com"; D_HOME="$SITES_ROOT/example.com"
D_MODE="php"; D_PHP="8.3"; D_PHP_CHILDREN=4; D_MEMORY="256M"; D_UPLOAD="64M"; D_WWW=1; D_SSL_WANTED=1; D_STATUS="active"; D_CREATED="2025-01-01T00:00:00Z"
lib_domain_state_save
assert_true "domain registered" lib_domain_registered example.com
lib_json_set "$(lib_domain_json example.com)" '.db = {name:"example_com", user:"example_com"}'
lib_domain_state_reset
assert_true "state load" lib_domain_state_load example.com
assert_eq "state php" "8.3" "$D_PHP"; assert_eq "state www" "1" "$D_WWW"; assert_eq "state ssl" "0" "$D_SSL"
assert_eq "state db merged" "example_com" "$D_DB_NAME"; assert_eq "state memory" "256M" "$D_MEMORY"
D_SSL=1; lib_domain_state_save; lib_domain_state_load example.com
assert_eq "state ssl saved" "1" "$D_SSL"; assert_eq "state db kept after save" "example_com" "$D_DB_NAME"
assert_eq "domains list" "example.com" "$(lib_domains_list)"
lib_cron_set healthcheck "15 6 * * * root $BIN_LINK healthcheck"
assert_true "cron has" lib_cron_has healthcheck
assert_has "cron shell header" "SHELL=/bin/bash" "$(cat "$CRON_FILE")"
lib_cron_set healthcheck "30 6 * * * root $BIN_LINK healthcheck"
assert_eq "cron replaced" "1" "$(grep -c 'server-setup:healthcheck' "$CRON_FILE")"
assert_has "cron new schedule" "30 6 * * *" "$(cat "$CRON_FILE")"
lib_cron_set "wpcron:example.com" "*/5 * * * * example_com true"
lib_cron_remove healthcheck
assert_false "cron removed" lib_cron_has healthcheck
assert_true "cron other kept" lib_cron_has "wpcron:example.com"
lib_backup_schedule "daily 03:00"
assert_has "schedule daily" "0 3 * * * root $BIN_LINK backup --all" "$(cat "$CRON_FILE")"
lib_backup_schedule "weekly sun 04:30"
assert_has "schedule weekly" "30 4 * * 0 root" "$(cat "$CRON_FILE")"
lib_backup_schedule "hourly"; assert_has "schedule hourly" "7 * * * * root" "$(cat "$CRON_FILE")"
lib_backup_schedule "15 2 * * *"; assert_has "schedule raw" "15 2 * * * root" "$(cat "$CRON_FILE")"
assert_false "schedule invalid" bash -c "$(declare -f lib_backup_schedule lib_die lib_log_write lib_mask_secrets lib_rollback_run lib_log_line_no lib_cron_set lib_manifest_set lib_ok); lib_backup_schedule bogus 2>/dev/null"
printf 'hello\n' | lib_write_file "$TMP/wf.txt"
assert_eq "write new" 1 "$LIB_FILE_CHANGED"; assert_eq "write content" "hello" "$(cat "$TMP/wf.txt")"
printf 'hello\n' | lib_write_file "$TMP/wf.txt"
assert_eq "write unchanged" 0 "$LIB_FILE_CHANGED"
printf 'world\n' | lib_write_file "$TMP/wf.txt"
assert_eq "write changed" 1 "$LIB_FILE_CHANGED"; assert_eq "write content 2" "world" "$(cat "$TMP/wf.txt")"
assert_true "backup archived" bash -c "ls '$STATE_DIR'/archive/configs/*wf.txt* >/dev/null 2>&1"
OPT_DRY_RUN=1; printf 'dry\n' | lib_write_file "$TMP/wf.txt"; OPT_DRY_RUN=0
assert_eq "dry-run flagged" 1 "$LIB_FILE_CHANGED"; assert_eq "dry-run untouched" "world" "$(cat "$TMP/wf.txt")"
printf 'a = 1\n;b = 2\n' >"$TMP/kv.ini"
lib_set_kv "$TMP/kv.ini" a 5; lib_set_kv "$TMP/kv.ini" b 7; lib_set_kv "$TMP/kv.ini" c 9
assert_eq "set_kv result" "$(printf 'a = 5\nb = 7\nc = 9')" "$(cat "$TMP/kv.ini")"
lib_append_line_once "$TMP/kv.ini" "include x"; lib_append_line_once "$TMP/kv.ini" "include x"
assert_eq "append once" 1 "$(grep -c '^include x$' "$TMP/kv.ini")"
_ini_set "$TMP/nd.conf" web "bind to" "127.0.0.1"; _ini_set "$TMP/nd.conf" web "bind to" "*"; _ini_set "$TMP/nd.conf" web "allow connections from" "localhost"
assert_eq "ini set" "$(printf '[web]\n    bind to = *\n    allow connections from = localhost')" "$(cat "$TMP/nd.conf")"
lib_domain_logrotate_regen
assert_has "logrotate site path" "$SITES_ROOT/example.com/logs/*.log" "$(cat "$LOGROTATE_SITES_FILE")"
assert_has "logrotate copytruncate" "copytruncate" "$(cat "$LOGROTATE_SITES_FILE")"
mkdir -p "$TMP/f2b"; mv_filter_dir="$TMP/f2b"
lib_domain_fail2ban_filters_write 2>/dev/null || true

# =============================================================================
section "cloudflare access control"
printf '# cf\n173.245.48.0/20\n103.21.244.0/22\n2400:cb00::/32\n' >"$CF_IPS_FILE"
lib_ols_tx_begin; lib_cf_tx_apply 1
assert_eq "cf useIpInProxyHeader" "2" "$(lib_ols_tx_top_get useIpInProxyHeader)"
assert_eq "cf allow list" "ALL, 173.245.48.0/20T, 103.21.244.0/22T, 2400:cb00::/32T" "$(lib_ols_tx_block_get accessControl "" allow)"
lib_cf_tx_apply 0
assert_eq "cf disabled header" "0" "$(lib_ols_tx_top_get useIpInProxyHeader)"
assert_eq "cf disabled allow" "ALL" "$(lib_ols_tx_block_get accessControl "" allow)"
lib_ols_tx_abort
if command -v python3 >/dev/null 2>&1; then
  assert_true  "ip in cf range" lib_ip_in_cidr_list 173.245.50.1 "$CF_IPS_FILE"
  assert_false "ip not in cf range" lib_ip_in_cidr_list 8.8.8.8 "$CF_IPS_FILE"
  assert_true  "ipv6 in cf range" lib_ip_in_cidr_list 2400:cb00::1 "$CF_IPS_FILE"
fi

# =============================================================================
section "add argument parsing"
lib_domain_parse_add_args Example.COM --www --php 8.3 --memory 512M --upload 128M --email a@b.c
assert_eq "parse domain lower" "example.com" "$D_DOMAIN"; assert_eq "parse www" 1 "$D_WWW"; assert_eq "parse memory" "512M" "$D_MEMORY"
assert_eq "parse ident" "example_com" "$D_IDENT"; assert_eq "parse home" "$SITES_ROOT/example.com" "$D_HOME"
lib_domain_parse_add_args app.example.com --proxy 127.0.0.1:3000 --ws-path /ws --no-ssl
assert_eq "parse proxy mode" "proxy" "$D_MODE"; assert_eq "parse proxy target" "127.0.0.1:3000" "$D_PROXY"; assert_eq "parse no-ssl" 0 "$D_SSL_WANTED"; assert_eq "parse proxy php cleared" "" "$D_PHP"
lib_domain_parse_add_args blog.example.com --wordpress --wp-locale tr_TR
assert_eq "parse wp mode" "wordpress" "$D_MODE"; assert_eq "parse wp db" 1 "$DOM_OPT_WITH_DB"; assert_eq "parse wp locale" "tr_TR" "$DOM_OPT_WP_LOCALE"
PARSE_FNS="$(declare -f lib_domain_parse_add_args lib_domain_state_reset lib_domain_valid lib_domain_add_usage lib_die lib_log_write lib_mask_secrets lib_rollback_run lib_log_line_no lib_php_valid_version lib_domain_ident lib_domain_home lib_iso_now)"
assert_false "parse bad memory" bash -c "${PARSE_FNS}; DEFAULT_EMAIL=; PHP_VERSION=8.3; SITES_ROOT=/home; STATE_DIR=/tmp; lib_domain_parse_add_args x.com --memory 256 2>/dev/null"
assert_false "parse www domain" bash -c "${PARSE_FNS}; DEFAULT_EMAIL=; PHP_VERSION=8.3; SITES_ROOT=/home; STATE_DIR=/tmp; lib_domain_parse_add_args www.x.com 2>/dev/null"
assert_true  "parse ok in subshell" bash -c "${PARSE_FNS}; DEFAULT_EMAIL=; PHP_VERSION=8.3; SITES_ROOT=/home; STATE_DIR=/tmp; lib_domain_parse_add_args ok.example.com --static 2>/dev/null"

# =============================================================================
section "WebAdmin access modes"
mkdir -p "$LSWS_HOME/admin/conf"
cat >"$LSWS_ADMIN_CONF" <<'EOF'
enableCoreDump      1
sessionTimeout      3600

accessControl {
  allow             ALL
}

listener adminListener {
  address           *:7080
  secure            0
}
EOF
SYS_IPV6=0
ADMIN_ACCESS="tunnel"; assert_eq "tunnel binds localhost" "127.0.0.1" "$(lib_ols_admin_address)"
ADMIN_ACCESS="ip";     assert_eq "ip mode binds all (v4)" "*" "$(lib_ols_admin_address)"
ADMIN_ACCESS="open";   assert_eq "open mode binds all" "*" "$(lib_ols_admin_address)"
SYS_IPV6=1; assert_eq "dual stack binds [ANY]" "[ANY]" "$(lib_ols_admin_address)"
SYS_IPV6=0; ADMIN_ACCESS="tunnel"
assert_eq "current bind read" "*:7080" "$(lib_ols_admin_current_bind)"
assert_false "not tunnel-only yet" lib_ols_admin_tunnel_only
lib_ols_admin_bind 127.0.0.1
assert_eq "bind rewritten" "127.0.0.1:7574" "$(lib_ols_admin_current_bind)"
assert_true  "tunnel-only detected" lib_ols_admin_tunnel_only
assert_eq "admin URL uses localhost" "http://127.0.0.1:7574" "$(lib_ols_admin_url)"
lib_ols_admin_bind 127.0.0.1
assert_eq "rebinding is idempotent" 0 "$LIB_FILE_CHANGED"
lib_ols_admin_bind '*'
assert_eq "bind back to all" "*:7574" "$(lib_ols_admin_current_bind)"
assert_false "no longer tunnel-only" lib_ols_admin_tunnel_only
assert_eq "admin conf still balanced" 1 "$( _ols_braces_balanced "$LSWS_ADMIN_CONF" && echo 1 || echo 0)"
assert_eq "secure flag untouched" "0" "$(_ols_block_key "$LSWS_ADMIN_CONF" listener adminListener secure get)"

SYS_SSH_PORTS="22"; SYS_PUBLIC_IPV4="198.51.100.7"; SUDO_USER="deploy"
assert_eq "tunnel command (default port)" "ssh -N -L 7574:127.0.0.1:7574 deploy@198.51.100.7" "$(lib_ols_admin_tunnel_cmd)"
SYS_SSH_PORTS="2222 22"
assert_eq "tunnel command (custom port)" "ssh -N -L 7574:127.0.0.1:7574 -p 2222 deploy@198.51.100.7" "$(lib_ols_admin_tunnel_cmd)"
unset SUDO_USER

SSH_CONNECTION="203.0.113.9 51234 10.0.0.5 22"
assert_eq "admin client ip from SSH" "203.0.113.9" "$(lib_admin_client_ip)"
SSH_CONNECTION="2001:db8::1 51234 2001:db8::2 22"
assert_eq "admin client ipv6 from SSH" "2001:db8::1" "$(lib_admin_client_ip)"
unset SSH_CONNECTION
# sudo clears the environment, so the fallbacks decide; each part is tested on its own
# because the ancestry walk depends on the machine the suite runs on.
assert_eq "who: remote IPv4"  "203.0.113.77" "$(lib_admin_ip_from_who <<<'root     pts/0        2026-09-14 17:30 (203.0.113.77)')"
assert_eq "who: remote IPv6"  "2001:db8::1"  "$(lib_admin_ip_from_who <<<'ubuntu   pts/1        2026-09-14 17:30 (2001:db8::1)')"
assert_eq "who: local console" ""            "$(lib_admin_ip_from_who <<<'root     tty1         2026-09-14 17:30')"
assert_eq "who: X display"     ":0"          "$(lib_admin_ip_from_who <<<'root     pts/0        2026-09-14 17:30 (:0)')"
assert_eq "who: no output"     ""            "$(lib_admin_ip_from_who </dev/null)"
assert_true  "valid IPv4 accepted" lib_admin_ip_valid 203.0.113.77
assert_true  "valid IPv6 accepted" lib_admin_ip_valid 2001:db8::1
assert_false "X display rejected"  lib_admin_ip_valid ':0'
assert_false "hostname rejected"   lib_admin_ip_valid 'client.example.com'
assert_false "empty rejected"      lib_admin_ip_valid ''
assert_eq "ancestry walk exits cleanly" 0 "$(run_isolated lib_admin_ip_from_ancestors)"

# ufw rule parsing must never touch a port it was not asked about
ufw() {
  [[ "$*" == "status numbered" ]] || return 0
  cat <<'EOF'
Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 80/tcp                     ALLOW IN    Anywhere
[ 3] 7080/tcp                   ALLOW IN    203.0.113.5
[ 4] 443/tcp                    ALLOW IN    Anywhere
[10] 7080/tcp (v6)              ALLOW IN    Anywhere (v6)
EOF
}
assert_eq "admin port rules, highest first" "$(printf '10\n3')" "$(lib_ufw_port_rule_numbers 7080)"
assert_eq "ssh port rule found" "1" "$(lib_ufw_port_rule_numbers 22)"
assert_eq "unused port has no rules" "" "$(lib_ufw_port_rule_numbers 9999)"
assert_lacks "port 80 never matched for 7080" "2" "$(lib_ufw_port_rule_numbers 7080)"
unset -f ufw

# =============================================================================
section "config test (structural)"
lib_ols_tx_begin; lib_ols_tx_vhost_add example.com 1 1; lib_ols_tx_commit
assert_eq "vhost map http" "example.com, www.example.com" "$(lib_ols_conf_map_get HTTP example.com)"
assert_false "config test fails on missing vhconf" lib_ols_config_test
assert_has "config test message" "configFile" "$OLS_TEST_OUTPUT"
mkdir -p "$LSWS_VHOSTS_DIR/example.com"; cp "$TMP/php.vhconf" "$LSWS_VHOSTS_DIR/example.com/vhconf.conf"
assert_true "config test passes" lib_ols_config_test
lib_ols_tx_begin; lib_ols_tx_vhost_remove example.com; lib_ols_tx_commit
assert_false "vhost removed from conf" lib_ols_conf_block_exists virtualhost example.com
assert_eq "maps removed" "" "$(lib_ols_conf_map_get HTTPS example.com)"

# =============================================================================
section "php.ini discovery (regression: SIGPIPE from a large phpinfo)"
mkdir -p "$TMP/fakephp/bin"
cat >"$TMP/fakephp/bin/php" <<'FAKEPHP'
#!/usr/bin/env bash
# stand-in for the LSPHP CLI; --ini is short, -i is deliberately huge
case "${1:-}" in
  --ini)
    [[ "${FAKE_NO_INI_FLAG:-0}" == "1" ]] && exit 0
    printf 'Configuration File (php.ini) Path: /fake/etc\n'
    printf 'Loaded Configuration File:         %s\n' "${FAKE_INI:-/fake/etc/php.ini}"
    printf 'Scan for additional .ini files in: %s\n' "${FAKE_SCAN:-/fake/etc/conf.d}"
    printf 'Additional .ini files parsed:      (none)\n'
    ;;
  -i)
    printf 'Loaded Configuration File => %s\n' "${FAKE_INI:-/fake/etc/php.ini}"
    printf 'Scan this dir for additional .ini files => %s\n' "${FAKE_SCAN:-/fake/etc/conf.d}"
    i=0
    while (( i < 20000 )); do
      printf 'filler %s ..........................................................\n' "$i" || exit 255
      i=$(( i + 1 ))
    done
    ;;
esac
FAKEPHP
chmod +x "$TMP/fakephp/bin/php"
lib_php_cli() { printf '%s/bin/php' "$TMP/fakephp"; }
assert_eq "ini discovery exits 0 (--ini path)" 0 "$(run_isolated lib_php_ini_paths 8.3)"
lib_php_ini_paths 8.3
assert_eq "php.ini parsed from --ini" "/fake/etc/php.ini" "$PHP_INI_FILE"
assert_eq "scan dir parsed from --ini" "/fake/etc/conf.d" "$PHP_INI_SCAN_DIR"
export FAKE_NO_INI_FLAG=1
assert_eq "ini discovery exits 0 (huge -i fallback)" 0 "$(run_isolated lib_php_ini_paths 8.3)"
lib_php_ini_paths 8.3
assert_eq "php.ini parsed from -i" "/fake/etc/php.ini" "$PHP_INI_FILE"
assert_eq "scan dir parsed from -i" "/fake/etc/conf.d" "$PHP_INI_SCAN_DIR"
unset FAKE_NO_INI_FLAG
export FAKE_SCAN="(none)"
lib_php_ini_paths 8.3
assert_eq "(none) scan dir becomes empty" "" "$PHP_INI_SCAN_DIR"
unset FAKE_SCAN
lib_php_cli() { printf '%s/bin/php' "$TMP/does-not-exist"; }
assert_eq "missing CLI exits 0" 0 "$(run_isolated lib_php_ini_paths 8.3)"
# shellcheck source=/dev/null
source "$ROOT/lib/php.sh"

# =============================================================================
section "renderers must exit 0 (pipefail safety)"
# Every renderer is used as "renderer | lib_write_file". If a renderer's last statement is a
# conditional that turns out false, the renderer exits 1 and pipefail aborts the installer.
# These run with errexit explicitly re-armed, which is how the installer executes them.
for fn in lib_system_render_sysctl lib_system_render_limits lib_db_render_tuning \
          lib_php_render_ini lib_ols_render_default_vhconf lib_ols_render_default_vhost_block \
          lib_ssl_hook_render lib_ols_admin_address; do
  assert_eq "${fn} exits 0" 0 "$(run_isolated "$fn")"
done
assert_eq "lib_ols_render_extprocessor exits 0" 0 "$(run_isolated lib_ols_render_extprocessor 8.3 4)"
assert_eq "lib_ols_render_vhost_block exits 0" 0 "$(run_isolated lib_ols_render_vhost_block example.com 1)"
assert_eq "lib_redis_render_conf (cache) exits 0" 0 "$(run_isolated lib_redis_render_conf pw 0)"
assert_eq "lib_redis_render_conf (persist) exits 0" 0 "$(run_isolated lib_redis_render_conf pw 1)"
assert_eq "lib_ols_render_vhssl exits 0" 0 "$(run_isolated lib_ols_render_vhssl /k.pem /c.pem 1)"

# the site renderer has the most branches: cover every mode with and without TLS
for _mode in php static proxy wordpress; do
  for _ssl in 0 1; do
    lib_domain_state_reset
    D_DOMAIN="example.com"; D_IDENT="example_com"; D_USER="example_com"; D_GROUP="example_com"
    D_HOME="$SITES_ROOT/example.com"; D_MODE="$_mode"; D_SSL="$_ssl"
    [[ "$_mode" == "proxy" ]] && D_PROXY="127.0.0.1:3000"
    [[ "$_mode" == "php" || "$_mode" == "wordpress" ]] && { D_PHP="8.3"; D_MEMORY="256M"; D_UPLOAD="64M"; D_PHP_CHILDREN=4; }
    assert_eq "vhconf ${_mode} ssl=${_ssl} exits 0" 0 "$(run_isolated lib_ols_render_vhconf)"
    # and with every optional switch on at once
    D_WWW=1; D_WWW_PRIMARY=1; D_HSTS_PRELOAD=1; D_EMAIL="a@b.c"; D_WS_PATH="/ws"
    assert_eq "vhconf ${_mode} ssl=${_ssl} (all options) exits 0" 0 "$(run_isolated lib_ols_render_vhconf)"
  done
done
lib_domain_state_reset

# =============================================================================
section "every configured path is created (regression: path is not accessible)"
# OpenLiteSpeed refuses the whole configuration when a context points at a directory that
# does not exist. This walks the rendered configuration, resolves the OLS variables and
# asserts the installer really creates every path it references.
ACME_ROOT="$TMP/acme"; OLS_CACHE_DIR="$TMP/cachedata"; OLS_DEFAULT_ROOT="$TMP/lsws/_default"
config_paths() { awk '$1=="location" || $1=="docRoot" || $1=="storagePath" {print $2}'; }

lib_ols_acme_root_ensure
lib_mkdir "${OLS_DEFAULT_ROOT}/html" 0755
missing=""
while read -r p; do
  [[ -n "$p" ]] || continue
  p="${p//'$VH_ROOT'/$OLS_DEFAULT_ROOT}"
  [[ -e "$p" ]] || missing+="${p} "
done < <(lib_ols_render_default_vhconf | config_paths)
assert_eq "catch-all vhost: every path exists" "" "$missing"

for _mode in php static proxy wordpress; do
  lib_domain_state_reset
  D_DOMAIN="paths-${_mode}.example.com"; D_IDENT="paths_${_mode}"
  D_USER="paths_user"; D_GROUP="paths_user"   # chown is stubbed out in this suite
  D_HOME="$SITES_ROOT/${D_DOMAIN}"; D_MODE="$_mode"
  [[ "$_mode" == "proxy" ]] && D_PROXY="127.0.0.1:3000"
  [[ "$_mode" == "php" || "$_mode" == "wordpress" ]] && { D_PHP="8.3"; D_MEMORY="256M"; D_UPLOAD="64M"; D_PHP_CHILDREN=4; }
  lib_domain_dirs_create >/dev/null 2>&1
  missing=""
  while read -r p; do
    [[ -n "$p" ]] || continue
    p="${p//'$VH_ROOT'/$D_HOME}"
    p="${p//'$VH_NAME'/$D_DOMAIN}"
    [[ -e "$p" ]] || missing+="${p} "
  done < <(lib_ols_render_vhconf | config_paths)
  assert_eq "${_mode} site: every path exists" "" "$missing"
done
assert_true "proxy static dir created" test -d "${SITES_ROOT}/paths-proxy.example.com/public_html/static"
assert_true "proxy app dir created" test -d "${SITES_ROOT}/paths-proxy.example.com/app"
assert_true "wordpress cache dir created" test -d "${OLS_CACHE_DIR}/paths-wordpress.example.com"
assert_true "acme webroot created" test -d "${ACME_ROOT}/.well-known/acme-challenge"
lib_domain_state_reset

# =============================================================================
section "HTTP status helper (regression: 000000)"
# curl prints 000 itself on a connection failure and then exits non-zero, so appending a
# fallback produced "000000"; callers compared that against "000" and saw a healthy server.
curl() {
  case "${FAKE_CURL:-ok}" in
    ok)   printf '200' ;;
    fail) printf '000'; return 7 ;;
    empty) return 7 ;;
  esac
}
FAKE_CURL=ok;    assert_eq "successful request" "200" "$(lib_http_code http://127.0.0.1/)"
FAKE_CURL=fail;  assert_eq "connection refused is exactly 000" "000" "$(lib_http_code http://127.0.0.1/)"
FAKE_CURL=empty; assert_eq "no output at all is 000" "000" "$(lib_http_code http://127.0.0.1/)"
FAKE_CURL=fail;  assert_true "failure is detected as 000" bash -c "[[ '$(lib_http_code http://127.0.0.1/)' == '000' ]]"
unset -f curl; unset FAKE_CURL

# =============================================================================
section "self-installation (regression: the command runs the installed copy)"
# "lompstack" runs the copy under INSTALL_DIR, not the checkout, so a git pull alone does
# not change what runs. lib_install_self refreshes it, and must never replace a working
# installation with a checkout that does not parse.
SRC_GOOD="$TMP/src-good"
mkdir -p "$SRC_GOOD/lib"
printf '#!/usr/bin/env bash\necho marker-v1\n' >"$SRC_GOOD/setup.sh"
printf '# lib a\n' >"$SRC_GOOD/lib/a.sh"
printf '# lib b\n' >"$SRC_GOOD/lib/b.sh"
assert_eq "install_self exits 0" 0 "$(run_isolated lib_install_self "$SRC_GOOD")"
assert_true "setup.sh copied" test -f "${INSTALL_DIR}/setup.sh"
if (( CAN_SYMLINK )); then
  assert_true "long command linked" test -L "$BIN_LINK"
  assert_true "short alias linked" test -L "$BIN_SHORT"
  assert_eq "both names point at the same script" "$(readlink -f "$BIN_LINK")" "$(readlink -f "$BIN_SHORT")"
  # an unrelated program owning the short name must not be replaced
  rm -f "$BIN_SHORT"; printf '#!/bin/sh\necho other\n' >"$BIN_SHORT"
  lib_install_self "$SRC_GOOD" >/dev/null 2>&1
  assert_false "a real file at the short name is left alone" test -L "$BIN_SHORT"
  assert_has "the foreign program survived" "echo other" "$(cat "$BIN_SHORT")"
  rm -f "$BIN_SHORT"
fi
assert_true "lib copied" test -f "${INSTALL_DIR}/lib/a.sh"
assert_has "copied content is the source" "marker-v1" "$(cat "${INSTALL_DIR}/setup.sh")"
# compared by suffix: MSYS rewrites absolute paths when handing them to jq
assert_has "source dir recorded for self-update" "src-good" "$(lib_manifest_get '.install.source_dir')"

# a file removed from the checkout must disappear from the installation
rm -f "$SRC_GOOD/lib/b.sh"
printf '#!/usr/bin/env bash\necho marker-v2\n' >"$SRC_GOOD/setup.sh"
lib_install_self "$SRC_GOOD" >/dev/null 2>&1
assert_has "second copy updated" "marker-v2" "$(cat "${INSTALL_DIR}/setup.sh")"
assert_false "deleted module is gone from the installation" test -f "${INSTALL_DIR}/lib/b.sh"
assert_false "no staging leftovers" test -e "${INSTALL_DIR}/lib.new"
assert_false "no rollback leftovers" test -e "${INSTALL_DIR}/lib.old"

SRC_BAD="$TMP/src-bad"
mkdir -p "$SRC_BAD/lib"
printf '#!/usr/bin/env bash\necho ok\n' >"$SRC_BAD/setup.sh"
printf 'if then fi\n' >"$SRC_BAD/lib/broken.sh"
assert_eq "a checkout that does not parse is refused" 1 "$(run_isolated lib_install_self "$SRC_BAD")"
assert_has "the good installation survived" "marker-v2" "$(cat "${INSTALL_DIR}/setup.sh")"
assert_false "the broken module was not installed" test -f "${INSTALL_DIR}/lib/broken.sh"

# =============================================================================
section "shell pitfalls (static)"
# Under set -u a "local x" that is only assigned on some branches aborts the script when it
# is read on another branch. This bit lib_db_install ("dump: unbound variable") on a real
# server, so every scalar local must be initialised at declaration.
bare_locals="$(for f in "$ROOT/setup.sh" "$ROOT"/lib/*.sh; do
  awk -v F="$f" '
    BEGIN { q = sprintf("%c", 39) }                     # a literal single quote
    /^[[:space:]]*local[[:space:]]+-/ { next }          # typed declarations are left alone
    /^[[:space:]]*local[[:space:]]/ {
      line=$0
      sub(/^[[:space:]]*local[[:space:]]+/, "", line)
      gsub(/"[^"]*"/, "", line)                         # values may contain spaces
      gsub(q "[^" q "]*" q, "", line)
      gsub(/\$\(\([^)]*\)\)/, "", line)                 # arithmetic values, e.g. $(( A - B ))
      gsub(/\$\([^)]*\)/, "", line)                     # command substitution
      gsub(/\$\{[^}]*\}/, "", line)
      sub(/;.*$/, "", line)                             # another command on the same line
      n=split(line, tok, /[[:space:]]+/)
      for (i=1; i<=n; i++) if (tok[i] ~ /^[A-Za-z_][A-Za-z0-9_]*$/) printf "%s:%d: %s\n", F, NR, tok[i]
    }
  ' "$f"
done)"
assert_eq "every scalar local is initialised" "" "$bare_locals"
# A group that ends in "[[ ... ]] && cmd" exits 1 when the test is false. Feeding such a
# group into a pipeline makes pipefail kill the whole script. This regression guard exists
# because exactly that bug reached a real server in lib_domain_fail2ban_regen.
pitfalls="$(for f in "$ROOT/setup.sh" "$ROOT"/lib/*.sh; do
  awk -v F="$f" '
    /^[[:space:]]*\}[[:space:]]*\|/ {
      if (prev ~ /(^|[^|&])&&[^&]/ || prev ~ /^[[:space:]]*(\[\[|\(\()/) printf "%s:%d: %s\n", F, prevnr, prev
    }
    !/^[[:space:]]*(#|$)/ { prev=$0; prevnr=NR }
  ' "$f"
done)"
assert_eq "no piped group ends in a conditional" "" "$pitfalls"

# =============================================================================
section "fail2ban jail regeneration (regression: empty Cloudflare action)"
mkdir -p "$FAIL2BAN_FILTER_DIR"
mv "$STATE_DIR/domains" "$STATE_DIR/domains.bak" 2>/dev/null || true
mkdir -p "$STATE_DIR/domains"
CF_F2B_ACTION="$TMP/cf-action.conf"; CF_INI="$TMP/cloudflare-absent.ini"
lib_pkg_installed() { [[ "$1" == "fail2ban" ]]; }
lib_service_active() { return 1; }
# run with errexit explicitly re-armed: this is what the installer does, and what broke
rc=0; ( set -Eeuo pipefail; shopt -s lastpipe; lib_domain_fail2ban_regen ) >/dev/null 2>&1 || rc=$?
assert_eq "regen succeeds with no sites and no Cloudflare token" 0 "$rc"
assert_true "web jail file written" test -s "$FAIL2BAN_WEB_JAIL_FILE"
out="$(cat "$FAIL2BAN_WEB_JAIL_FILE")"
assert_has "wp-login jail present" "[server-setup-wp-login]" "$out"
assert_has "probe jail present" "[server-setup-web-probe]" "$out"
assert_has "jails disabled while there are no sites" "enabled = false" "$out"
assert_lacks "no cloudflare action without a token" "server-setup-cloudflare" "$out"
assert_true "wp-login filter written" test -s "${FAIL2BAN_FILTER_DIR}/server-setup-wp-login.conf"
assert_true "probe filter written" test -s "${FAIL2BAN_FILTER_DIR}/server-setup-web-probe.conf"
if (( CAN_CHMOD )); then assert_eq "jail file is 0600" "600" "$(stat -c %a "$FAIL2BAN_WEB_JAIL_FILE")"; fi
rc=0; ( set -Eeuo pipefail; shopt -s lastpipe; lib_domain_fail2ban_regen ) >/dev/null 2>&1 || rc=$?
assert_eq "second regen is also clean" 0 "$rc"
rm -rf "$STATE_DIR/domains"
mv "$STATE_DIR/domains.bak" "$STATE_DIR/domains" 2>/dev/null || mkdir -p "$STATE_DIR/domains"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then exit 1; fi
exit 0
