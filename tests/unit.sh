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
TIMEZONE="Europe/Istanbul"; ADMIN_PORT="7080"; PHP_VERSION="8.3"; ADMIN_ACCESS="tunnel"; ADMIN_ALLOWED_IP=""; DEFAULT_EMAIL=""; SSH_PORT=""
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
for m in common system ols php db ssl domain proxy app mail webmail cloudflare backup monitor install menu; do
  # shellcheck source=/dev/null
  source "$ROOT/lib/$m.sh"
done
trap cleanup EXIT
mkdir -p "$STATE_DIR" "$LSWS_HOME/conf/vhosts" "$SITES_ROOT"; : >"$LOG_FILE"
chown() { return 0; }   # no lsadm/site users on the test machine
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
assert_has "wp: no PHP runs from the uploads" 'RewriteRule (?i)^/?wp-content/uploads/.*\.(php[0-9]?|phtml|phar)$ - [F,L]' "$out"
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
D_SSL_WANTED=1
assert_eq "summary exits 0 when SSL is wanted but not active" 0 "$(run_isolated lib_domain_summary)"
assert_has "and it tells you how to get one" "renew-ssl" "$(lib_domain_summary 2>&1)"
D_SSL=1
assert_eq "summary exits 0 when SSL is active"                0 "$(run_isolated lib_domain_summary)"
D_WWW=1; D_WP=1; D_DB_NAME="sum_db"
assert_eq "summary exits 0 for a www WordPress site"         0 "$(run_isolated lib_domain_summary)"
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
for d in alpha.example beta.example; do
  mkdir -p "$STATE_DIR/domains/$d" "$SITES_ROOT/$d/logs"
  printf '{"domain":"%s"}\n' "$d" >"$STATE_DIR/domains/$d/domain.json"
done
printf 'dns_cloudflare_api_token = Xv8sQ2pLm9TzR4kWn1bYc7dEf0g\n' >"$CF_INI"
: >"$CF_F2B_ACTION"
lib_manifest_set '.cloudflare.account_id' 'acc0123456789'
assert_eq "regen succeeds with sites and a Cloudflare token" 0 "$(run_isolated lib_domain_fail2ban_regen)"
out="$(cat "$FAIL2BAN_WEB_JAIL_FILE")"
assert_has "jails enabled once a site exists" "enabled = true" "$out"
assert_has "first site logpath" "logpath = ${SITES_ROOT}/alpha.example/logs/access.log" "$out"
# fail2ban only reads the second path as part of logpath while the line stays indented
assert_has "second site is an indented continuation" $'\n          '"${SITES_ROOT}/beta.example/logs/access.log" "$out"
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
rm -rf "$STATE_DIR/domains"
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
_ht_started="@$(( $(date +%s) - 600 ))"
: >"$_ht_wp/.htaccess"; touch -d '-20 minutes' "$_ht_wp/.htaccess"
: >"$_ht_st/.htaccess"
assert_eq "an .htaccess older than the running server is in effect" "" "$(lib_ols_htaccess_pending)"
: >"$_ht_wp/wp-content/uploads/.htaccess"
assert_eq "one written after the server started waits for a reload" "$_ht_wp/wp-content/uploads/.htaccess" "$(lib_ols_htaccess_pending)"
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
_ht_flock_rc=0; touch -d '-20 minutes' "$_ht_wp/wp-content/uploads/.htaccess"
( lib_ols_htaccess_check_main ) >/dev/null 2>&1
assert_eq  "and not at all when nothing changed" "1" "$(_ht_count)"
assert_eq  "the check exits 0 with errexit armed" 0 "$(run_isolated lib_ols_htaccess_check_main)"

assert_has "add --wordpress reloads once WordPress wrote its .htaccess" 'lib_ols_htaccess_reload' "$(declare -f lib_domain_add_main)"
assert_has "install schedules the check" 'lib_ols_htaccess_watch_ensure' "$(declare -f lib_install_cron)"
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
assert_has "and never in the clear" "smtp_tls_security_level = encrypt" "$_pfr"

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
assert_has "deleting a mailbox repairs the aliases that pointed at it" "lib_mail_alias_forget_target" "$_bd"
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
printf 'HOST=smtp.provider.example\nPORT=587\nUSER=u\n' >"$MAIL_RELAY_INFO"
assert_has "the relay is included in SPF" "include:provider.example" "$(_mail_dns_records alpha.example)"
rm -f "$MAIL_RELAY_INFO"

MAIL_PASSWD_FILE="$TMP/passwd"; MAIL_ALIAS_DIR="$TMP/aliases"; MAIL_DKIM_DIR="$TMP/dkim-unused"
rm -rf "$_m_state/alpha.example" "$_m_state/beta.example" "$_m_state/plain.example"

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
assert_has "the open rules go first"            "lib_ufw_delete_port_rules 80" "$_ol"
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
# HTTP/3: OpenLiteSpeed answers QUIC on 443/udp, which the port deleter (TCP by name) misses
assert_has "the lock closes 443/udp as well" "delete allow 443/udp" "$_ol"
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
# the log directory belongs to root: OpenLiteSpeed opens the vhost logs there as root, and a
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
section "no command replaces itself and skips the EXIT cleanup"
assert_eq "no 'exec tail' in the libraries" "" "$(grep -nE '^[[:space:]]*exec tail' "$ROOT"/lib/*.sh || true)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then exit 1; fi
exit 0
