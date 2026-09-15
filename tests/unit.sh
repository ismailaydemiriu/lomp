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
for m in common system ols php db ssl domain proxy app cloudflare backup monitor install menu; do
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
# Every secret this tool accepts on the command line is SPACE separated, and setup.sh logs
# the whole argument vector. A key=value-only masker let live tokens into the log.
assert_eq "mask --cf-api-token"   "args='--cf-api-token ********'"   "$(m "args='--cf-api-token Xv8sQ2pLm9TzR4kWn1bYc7dEf0g'")"
assert_eq "mask --smtp-pass"      "--smtp-pass ********"             "$(m '--smtp-pass hunter2secret')"
assert_eq "mask --telegram-token" "--telegram-token ********"        "$(m '--telegram-token 123456:ABCdefGhi')"
assert_eq "mask --api-key"        "--api-key ********"               "$(m '--api-key abcd1234efgh')"
assert_eq "mask redis requirepass line" "requirepass ********"       "$(m 'requirepass S3cr3tRedisPass')"
assert_eq "mask msmtp password line"    "password ********"          "$(m 'password S3cr3tSmtpPass')"
assert_eq "mask json token"       '"token":"********"'               "$(m '"token":"abcd1234efgh"')"
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
assert_has "token passed to the action" 'cftoken="Xv8sQ2pLm9TzR4kWn1bYc7dEf0g"' "$out"
assert_has "account passed to the action" 'cfaccount="acc0123456789"' "$out"
# the action block belongs to the jail above it; one stray newline moves it into the next
assert_eq "action stays inside the wp-login jail" "logpath action action_cf [server-setup-web-probe]" \
  "$(awk '/^logpath/{print "logpath"} /^action = /{print "action"} /server-setup-cloudflare/{print "action_cf"} /^\[server-setup-web-probe\]/{print; exit}' <<<"$out" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "second regen with sites is also clean" 0 "$(run_isolated lib_domain_fail2ban_regen)"
if (( CAN_CHMOD )); then assert_eq "jail holding a token is 0600" "600" "$(stat -c %a "$FAIL2BAN_WEB_JAIL_FILE")"; fi
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
section "no command replaces itself and skips the EXIT cleanup"
assert_eq "no 'exec tail' in the libraries" "" "$(grep -nE '^[[:space:]]*exec tail' "$ROOT"/lib/*.sh || true)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then exit 1; fi
exit 0
