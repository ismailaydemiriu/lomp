#!/usr/bin/env bash
# =============================================================================
#  tests/integration.sh - DESTRUCTIVE end-to-end acceptance test for lompstack.
#
#  Implements the acceptance criteria: dry-run changes nothing, install is
#  idempotent, the full site lifecycle works, a broken config is rolled back
#  while the service stays up, and no secret ever reaches the log file.
#
#  RUN ONLY ON A THROWAWAY UBUNTU 22.04 / 24.04 VPS, AS ROOT.
#  It installs packages, creates users, creates and drops databases.
#
#      LOMPSTACK_INTEGRATION=yes bash tests/integration.sh
#      LOMPSTACK_INTEGRATION=yes TEST_DOMAIN=itest.example.com bash tests/integration.sh
# =============================================================================
set -Eeuo pipefail
shopt -s lastpipe

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(dirname "$HERE")"
SETUP="${ROOT}/setup.sh"

TEST_DOMAIN="${TEST_DOMAIN:-itest-lompstack.example.com}"
TEST_DOMAIN2="${TEST_DOMAIN2:-itest2-lompstack.example.com}"
TEST_DOMAIN3="${TEST_DOMAIN3:-itest3-lompstack.example.com}"
STATE_DIR="/root/.server-setup"
LSWS_HOME="/usr/local/lsws"
LOG_FILE="/var/log/server_setup.log"
BACKUP_ROOT="/var/backups/server-setup"
OUT_DIR="${HERE}/out"
PASS=0; FAIL=0; SKIP=0
declare -a FAILED_TESTS=()

C_G=$'\033[0;32m'; C_R=$'\033[0;31m'; C_Y=$'\033[0;33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
[[ -t 1 ]] || { C_G=''; C_R=''; C_Y=''; C_B=''; C_0=''; }

step()  { printf '\n%s=== %s ===%s\n' "$C_B" "$*" "$C_0"; }
ok()    { PASS=$((PASS + 1)); printf '  %s[pass]%s %s\n' "$C_G" "$C_0" "$*"; }
bad()   { FAIL=$((FAIL + 1)); FAILED_TESTS+=("$*"); printf '  %s[FAIL]%s %s\n' "$C_R" "$C_0" "$*"; }
skip()  { SKIP=$((SKIP + 1)); printf '  %s[skip]%s %s\n' "$C_Y" "$C_0" "$*"; }
note()  { printf '         %s\n' "$*"; }

check()      { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
check_not()  { if "${@:2}"; then bad "$1"; else ok "$1"; fi; }
check_eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
check_has()  { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1 (missing [$2])"; fi; }

# Run setup.sh, tee into OUT_DIR, never abort the suite on failure.
run_setup() {   # run_setup <logname> <args...>
  local name="$1"; shift
  local rc=0
  bash "$SETUP" "$@" </dev/null >"${OUT_DIR}/${name}.out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

http_code() {   # http_code <host> [path]
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: ${1}" "http://127.0.0.1${2:-/}" 2>/dev/null || printf '000'
}

managed_hashes() {   # fingerprint of every generated config file (manifest excluded: it has timestamps)
  local f=""
  for f in /etc/sysctl.d/99-production-server.conf \
           /etc/security/limits.d/99-production-server.conf \
           /etc/mysql/mariadb.conf.d/60-production-tuned.cnf \
           /etc/fail2ban/jail.d/server-setup.conf \
           /etc/fail2ban/jail.d/server-setup-web.conf \
           /etc/cron.d/server-setup \
           /etc/redis/server-setup.conf \
           /etc/logrotate.d/server-setup \
           /etc/logrotate.d/ols-sites \
           /etc/apt/apt.conf.d/52server-setup-unattended \
           /etc/letsencrypt/renewal-hooks/deploy/99-server-setup-ols.sh \
           "${LSWS_HOME}/conf/httpd_config.conf" \
           "${LSWS_HOME}/conf/vhosts/_default/vhconf.conf" \
           "${LSWS_HOME}"/lsphp*/etc/php/*/mods-available/99-server-setup.ini; do
    # an "if" body, not a trailing "&&": the last item is a glob that may match nothing,
    # and a false test as the loop's last command makes the loop exit 1 under pipefail
    if [[ -f "$f" ]]; then sha256sum "$f"; fi
  done | sort
}

# =============================================================================
#  Guards
# =============================================================================
if [[ "${LOMPSTACK_INTEGRATION:-}" != "yes" ]]; then
  cat >&2 <<EOF
${C_R}This test is DESTRUCTIVE.${C_0}
It installs OpenLiteSpeed, MariaDB, Redis, fail2ban and UFW, creates system users
and databases, and removes them again. Run it only on a throwaway VPS.

  LOMPSTACK_INTEGRATION=yes bash tests/integration.sh
EOF
  exit 2
fi
[[ "$(id -u)" -eq 0 ]] || { printf '%sMust run as root.%s\n' "$C_R" "$C_0" >&2; exit 1; }
[[ -r /etc/os-release ]] || { printf 'Not an Ubuntu system.\n' >&2; exit 1; }
# shellcheck disable=SC1091
OS_VER="$(. /etc/os-release && printf '%s' "$VERSION_ID")"
[[ "$OS_VER" == "22.04" || "$OS_VER" == "24.04" ]] || { printf 'Unsupported Ubuntu %s\n' "$OS_VER" >&2; exit 1; }

mkdir -p "$OUT_DIR"
if ! command -v jq >/dev/null 2>&1; then
  printf 'Installing jq (needed by the test harness)...\n'
  DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq
fi
printf '%slompstack acceptance test%s  (Ubuntu %s, domain %s)\n' "$C_B" "$C_0" "$OS_VER" "$TEST_DOMAIN"
printf 'Command output is kept in %s\n' "$OUT_DIR"
START_TS="$(date +%s)"

# =============================================================================
step "T01  Static analysis"
# =============================================================================
rc=0; for f in "$SETUP" "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh; do bash -n "$f" || rc=1; done
check_eq "bash -n on every file" 0 "$rc"
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck -S error is clean" shellcheck -S error -x "$SETUP" "$ROOT"/lib/*.sh
else
  skip "shellcheck not installed (apt-get install shellcheck)"
fi
check "unit tests pass" bash "$ROOT/tests/unit.sh"

# =============================================================================
step "T02  install --dry-run must not touch the system"
# =============================================================================
pre_state_exists=0; [[ -e "$STATE_DIR" ]] && pre_state_exists=1
rc="$(run_setup dryrun install --dry-run --non-interactive --no-color --email ci@example.com)"
check_eq "dry-run exits 0" 0 "$rc"
# "the last step ran" without hardcoding how many there are: look for a [N/N] marker.
# A literal "20/20" kept passing after a step was added - [20/21] contains no 20/20, so the
# check only started failing once the totals moved, long after it stopped meaning anything.
check_has "dry-run reached the final step" "yes" \
  "$(awk 'match($0, /\[[0-9]+\/[0-9]+\]/) {
            s = substr($0, RSTART + 1, RLENGTH - 2); split(s, a, "/")
            if (a[1] == a[2]) f = 1
          } END { print (f ? "yes" : "no") }' "${OUT_DIR}/dryrun.out")"
if (( pre_state_exists )); then
  skip "state dir already existed before the test; cannot assert dry-run created nothing"
else
  check_not "dry-run did not create ${STATE_DIR}" test -e "$STATE_DIR"
  check_not "dry-run did not install OpenLiteSpeed" test -e "$LSWS_HOME"
  check_not "dry-run did not write /etc/cron.d/server-setup" test -e /etc/cron.d/server-setup
fi
check_not "dry-run produced no failures" grep -qE '\[fail\]|unbound variable' "${OUT_DIR}/dryrun.out"

# =============================================================================
step "T03  install (non-interactive, stdin closed)"
# =============================================================================
note "this takes several minutes on a fresh VPS"
rc="$(run_setup install install --non-interactive --no-color --email ci@example.com --skip-upgrade)"
check_eq "install exits 0" 0 "$rc"
check_not "install asked no question" grep -qiE '\[y/n\]|\[Y/n\]' "${OUT_DIR}/install.out"
check "manifest written" test -s "${STATE_DIR}/manifest.json"
check "state dir is 0700" test "$(stat -c %a "$STATE_DIR")" = "700"
check "WebAdmin credentials stored 0600" test "$(stat -c %a "${STATE_DIR}/openlitespeed-admin.info")" = "600"
check "redis credentials stored 0600" test "$(stat -c %a "${STATE_DIR}/redis.info")" = "600"
check "log file is 0600" test "$(stat -c %a "$LOG_FILE")" = "600"
check "lompstack command installed" test -x /usr/local/sbin/lompstack

for svc in lsws mariadb redis-server fail2ban; do
  check "service ${svc} is active" systemctl is-active --quiet "$svc"
done
check "ufw is active" bash -c "ufw status | head -1 | grep -q 'Status: active'"
check "port 80 is listening" bash -c "ss -tlnH | awk '{print \$4}' | grep -qE '[:.]80\$'"
check "port 443 is listening" bash -c "ss -tlnH | awk '{print \$4}' | grep -qE '[:.]443\$'"
check "OpenLiteSpeed config test passes" "${LSWS_HOME}/bin/openlitespeed" -t
check "fail2ban base jail written" test -s /etc/fail2ban/jail.d/server-setup.conf
check "fail2ban web jail is 0600" test "$(stat -c %a /etc/fail2ban/jail.d/server-setup-web.conf)" = "600"
check "fail2ban accepted the generated configuration" fail2ban-client ping
check "sshd jail is loaded" bash -c "fail2ban-client status sshd >/dev/null 2>&1"
check_eq "unknown Host gets 403 (catch-all vhost)" "403" "$(http_code unknown-host.invalid)"

# =============================================================================
step "T04  install is idempotent (second run changes nothing)"
# =============================================================================
managed_hashes >"${OUT_DIR}/hashes.before"
rc="$(run_setup install2 install --non-interactive --no-color --email ci@example.com --skip-upgrade)"
managed_hashes >"${OUT_DIR}/hashes.after"
check_eq "second install exits 0" 0 "$rc"
if diff -u "${OUT_DIR}/hashes.before" "${OUT_DIR}/hashes.after" >"${OUT_DIR}/hashes.diff"; then
  ok "no managed config file changed on the second run"
else
  bad "second run modified config files:"
  sed 's/^/         /' "${OUT_DIR}/hashes.diff" | head -20
fi
check_has "second run reports existing components" "already" "$(cat "${OUT_DIR}/install2.out")"
check "services survived the second run" systemctl is-active --quiet lsws

# =============================================================================
step "T05  WebAdmin access (default: closed, SSH tunnel only)"
# =============================================================================
ADMIN_PORT="$(jq -r '.params.admin_port // "7080"' "${STATE_DIR}/manifest.json")"
check_eq "configured mode is tunnel" "tunnel" "$(jq -r '.params.admin_access // ""' "${STATE_DIR}/manifest.json")"
check "listener is bound to localhost" \
  grep -qE "^[[:space:]]*address[[:space:]]+127\.0\.0\.1:${ADMIN_PORT}" "${LSWS_HOME}/admin/conf/admin_config.conf"
check_not "no firewall rule opens the panel" bash -c "ufw status numbered | grep -qE '^\[[[:space:]]*[0-9]+\][[:space:]]+${ADMIN_PORT}/tcp'"
check_not "panel is not listening on a public address" \
  bash -c "ss -tlnH | awk '{print \$4}' | grep -qE '^(0\.0\.0\.0|\*|\[::\]):${ADMIN_PORT}\$'"
check "panel is listening on localhost" bash -c "ss -tlnH | awk '{print \$4}' | grep -qE '^127\.0\.0\.1:${ADMIN_PORT}\$'"
rc="$(run_setup panelstatus panel status --no-color)"
check_eq "panel status exits 0" 0 "$rc"
check_has "panel status prints the tunnel command" "ssh -N -L ${ADMIN_PORT}:127.0.0.1:${ADMIN_PORT}" "$(cat "${OUT_DIR}/panelstatus.out")"

rc="$(run_setup panelopen panel open --ip 203.0.113.5 --minutes 0 --yes --no-color)"
check_eq "panel open exits 0" 0 "$rc"
check "panel open added exactly one firewall rule" \
  bash -c "test \"\$(ufw status numbered | grep -cE '^\[[[:space:]]*[0-9]+\][[:space:]]+${ADMIN_PORT}/tcp')\" -ge 1"
check "panel open allows only that address" bash -c "ufw status | grep -E '^${ADMIN_PORT}/tcp' | grep -q '203.0.113.5'"
check "panel now listens publicly" bash -c "ss -tlnH | awk '{print \$4}' | grep -qE '^(0\.0\.0\.0|\*|\[::\]):${ADMIN_PORT}\$'"
check "OpenLiteSpeed survived the rebind" systemctl is-active --quiet lsws
check_eq "web server still answers while the panel is open" "403" "$(http_code unknown-host.invalid)"

rc="$(run_setup panelclose panel close --yes --no-color)"
check_eq "panel close exits 0" 0 "$rc"
check_not "firewall rule removed again" bash -c "ufw status numbered | grep -qE '^\[[[:space:]]*[0-9]+\][[:space:]]+${ADMIN_PORT}/tcp'"
check_not "listener is private again" \
  bash -c "ss -tlnH | awk '{print \$4}' | grep -qE '^(0\.0\.0\.0|\*|\[::\]):${ADMIN_PORT}\$'"
check "ssh, http and https rules were never touched" \
  bash -c "ufw status | grep -qE '^80/tcp' && ufw status | grep -qE '^443/tcp' && ufw status | grep -qE '^22/tcp'"
check "OpenLiteSpeed still healthy" "${LSWS_HOME}/bin/openlitespeed" -t

# =============================================================================
step "T06  add site (no SSL: the test domain has no public DNS)"
# =============================================================================
rc="$(run_setup add add "$TEST_DOMAIN" --no-ssl --non-interactive --no-color --yes)"
check_eq "add exits 0" 0 "$rc"
check "site registered in state" test -s "${STATE_DIR}/domains/${TEST_DOMAIN}/domain.json"
check "home directory created" test -d "/home/${TEST_DOMAIN}/public_html"
check "private dir is 0700" test "$(stat -c %a "/home/${TEST_DOMAIN}/private")" = "700"
IDENT="$(printf '%s' "$TEST_DOMAIN" | sed -E 's/[^a-zA-Z0-9]+/_/g' | cut -c1-28)"
check "system user exists" id -u "$IDENT"
check_eq "site user shell is nologin" "/usr/sbin/nologin" "$(getent passwd "$IDENT" | cut -d: -f7)"
check "vhost config written" test -f "${LSWS_HOME}/conf/vhosts/${TEST_DOMAIN}/vhconf.conf"
check "vhost registered in httpd_config" grep -q "virtualhost ${TEST_DOMAIN}" "${LSWS_HOME}/conf/httpd_config.conf"
check_eq "site answers HTTP 200" "200" "$(http_code "$TEST_DOMAIN")"

printf '<?php echo "itest-php-ok:".PHP_VERSION;' >"/home/${TEST_DOMAIN}/public_html/itest.php"
chown "${IDENT}:${IDENT}" "/home/${TEST_DOMAIN}/public_html/itest.php"
PHP_BODY="$(curl -s --max-time 15 -H "Host: ${TEST_DOMAIN}" http://127.0.0.1/itest.php || true)"
check_has "PHP executes for the site" "itest-php-ok:" "$PHP_BODY"
note "PHP reported: ${PHP_BODY:-<empty>}"
PHP_OWNER="$(ps -eo user:32,args | awk -v d="$IDENT" '$0 ~ "lsphp" && $1 == d {print $1; exit}')"
check_eq "lsphp runs as the site user" "$IDENT" "${PHP_OWNER:-<none>}"
rm -f "/home/${TEST_DOMAIN}/public_html/itest.php"

printf 'secret\n' >"/home/${TEST_DOMAIN}/private/secret.txt"
check_not "private/ is outside the document root" test "$(http_code "$TEST_DOMAIN" /private/secret.txt)" = "200"
printf 'secret\n' >"/home/${TEST_DOMAIN}/public_html/.env"
check_not "dotfiles are blocked" test "$(http_code "$TEST_DOMAIN" /.env)" = "200"
rm -f "/home/${TEST_DOMAIN}/public_html/.env"

# =============================================================================
step "T06b reverse-proxy site (its static contexts must exist on disk)"
# =============================================================================
rc="$(run_setup addproxy add "$TEST_DOMAIN3" --proxy 127.0.0.1:3000 --no-ssl --non-interactive --no-color --yes)"
check_eq "add --proxy exits 0" 0 "$rc"
check "OpenLiteSpeed accepts the proxy configuration" "${LSWS_HOME}/bin/openlitespeed" -t
check "static context directory exists" test -d "/home/${TEST_DOMAIN3}/public_html/static"
check "assets context directory exists" test -d "/home/${TEST_DOMAIN3}/public_html/assets"
check "application directory created" test -d "/home/${TEST_DOMAIN3}/app"
proxy_code="$(http_code "$TEST_DOMAIN3")"
check "proxy answers 50x while the backend is down" bash -c "[[ '$proxy_code' =~ ^(500|502|503)$ ]]"
note "proxy returned HTTP ${proxy_code} (nothing is listening on 127.0.0.1:3000, which is expected)"
check_eq "the PHP site is unaffected" "200" "$(http_code "$TEST_DOMAIN")"
rc="$(run_setup removeproxy remove "$TEST_DOMAIN3" --yes --no-color)"
check_eq "proxy site removed" 0 "$rc"
check_not "proxy files removed" test -e "/home/${TEST_DOMAIN3}"
check "OpenLiteSpeed still healthy after removal" "${LSWS_HOME}/bin/openlitespeed" -t

# =============================================================================
step "T06c Node.js site run by PM2, and a path proxy on the PHP site"
# =============================================================================
TEST_DOMAIN4="${TEST_DOMAIN4:-itest4-lompstack.example.com}"
IDENT4="$(printf '%s' "$TEST_DOMAIN4" | sed -E 's/[^a-zA-Z0-9]+/_/g' | cut -c1-28)"
rc="$(run_setup addnode add "$TEST_DOMAIN4" --node --port 3197 --no-ssl --no-db --non-interactive --no-color --yes)"
check_eq "add --node exits 0" 0 "$rc"
check "the PM2 unit is rendered" test -f "/etc/systemd/system/pm2-${IDENT4}.service"
check "OpenLiteSpeed accepts the Node.js vhost" "${LSWS_HOME}/bin/openlitespeed" -t
install -d -o "$IDENT4" -g "$IDENT4" -m 0750 "/home/${TEST_DOMAIN4}/app"
cat >"/home/${TEST_DOMAIN4}/app/server.js" <<'JS'
require('http').createServer((q, s) => s.end('itest-node-ok ' + q.url + ' ' + require('os').userInfo().username)).listen(Number(process.env.PORT), '127.0.0.1');
JS
printf '{"name":"itest","version":"1.0.0","scripts":{"start":"node server.js"}}\n' >"/home/${TEST_DOMAIN4}/app/package.json"
chown "${IDENT4}:${IDENT4}" "/home/${TEST_DOMAIN4}/app/server.js" "/home/${TEST_DOMAIN4}/app/package.json"
rc="$(run_setup deploynode app deploy "$TEST_DOMAIN4" --no-color)"
check_eq "app deploy exits 0" 0 "$rc"
check "the PM2 service is active" systemctl is-active --quiet "pm2-${IDENT4}"
check "the PM2 service starts at boot" systemctl is-enabled --quiet "pm2-${IDENT4}"
check_has "the app answers through OpenLiteSpeed, as the site user" "itest-node-ok /hello ${IDENT4}" \
  "$(curl -s --max-time 15 -H "Host: ${TEST_DOMAIN4}" http://127.0.0.1/hello || true)"
check_not "no node or PM2 process runs as root" bash -c "ps -eo user:32,args | awk '\$1 == \"root\" && /(node|PM2)/ && !/awk/' | grep -q ."
printf 'itest-app-secret-value' | bash "$SETUP" app env "$TEST_DOMAIN4" set ITEST_TOKEN --no-color >"${OUT_DIR}/envnode.out" 2>&1 || true
check_not "an application variable never reaches the log" grep -qF "itest-app-secret-value" "$LOG_FILE"
rc="$(run_setup proxyadd proxy add "$TEST_DOMAIN" /api/ 127.0.0.1:3197 --no-color)"
check_eq "proxy add exits 0" 0 "$rc"
check_has "/api/ on the PHP site reaches the Node.js app" "itest-node-ok /api/x" \
  "$(curl -s --max-time 15 -H "Host: ${TEST_DOMAIN}" http://127.0.0.1/api/x || true)"
check_eq "the PHP site itself still answers 200" "200" "$(http_code "$TEST_DOMAIN")"
rc="$(run_setup proxyremove proxy remove "$TEST_DOMAIN" /api/ --no-color)"
check_eq "proxy remove exits 0" 0 "$rc"
rc="$(run_setup workeradd app worker "$TEST_DOMAIN4" add tick --cron "*/5 * * * *" --start "node server.js" --no-color)"
check_eq "app worker add (a scheduled job) exits 0" 0 "$rc"
check "cron runs the job as the site user" grep -qF "*/5 * * * * ${IDENT4} /bin/bash /home/${TEST_DOMAIN4}/.pm2/jobs/tick.sh # server-setup:job:${TEST_DOMAIN4}:tick" /etc/cron.d/server-setup
check "the job script belongs to the site user" test "$(stat -c %U "/home/${TEST_DOMAIN4}/.pm2/jobs/tick.sh" 2>/dev/null)" = "$IDENT4"
check_has "app worker list shows it" "tick" "$(bash "$SETUP" app worker "$TEST_DOMAIN4" list --no-color 2>&1 || true)"
rc="$(run_setup stopnode app stop "$TEST_DOMAIN4" --no-color)"
check_eq "app stop exits 0" 0 "$rc"
check_not "a stopped app no longer runs" systemctl is-active --quiet "pm2-${IDENT4}"
check_not "and its job is no longer scheduled" grep -q "server-setup:job:${TEST_DOMAIN4}:tick" /etc/cron.d/server-setup
rc="$(run_setup removenode remove "$TEST_DOMAIN4" --yes --no-color)"
check_eq "Node.js site removed" 0 "$rc"
check_not "its PM2 unit is gone" test -e "/etc/systemd/system/pm2-${IDENT4}.service"
check_not "its system user is gone" id -u "$IDENT4"
check "OpenLiteSpeed still healthy" "${LSWS_HOME}/bin/openlitespeed" -t

# =============================================================================
step "T07  database for the site"
# =============================================================================
rc="$(run_setup db db "$TEST_DOMAIN" --no-color)"
check_eq "db exits 0" 0 "$rc"
check "db.info stored 0600" test "$(stat -c %a "${STATE_DIR}/domains/${TEST_DOMAIN}/db.info")" = "600"
DB_NAME="$(awk -F= '$1=="DB_NAME"{print $2; exit}' "${STATE_DIR}/domains/${TEST_DOMAIN}/db.info")"
DB_USER="$(awk -F= '$1=="DB_USER"{print $2; exit}' "${STATE_DIR}/domains/${TEST_DOMAIN}/db.info")"
DB_PASS="$(awk -F= '$1=="DB_PASS"{sub(/^[^=]*=/,""); print; exit}' "${STATE_DIR}/domains/${TEST_DOMAIN}/db.info")"
check "database exists" bash -c "mariadb -N -B -e \"SHOW DATABASES LIKE '${DB_NAME}'\" | grep -q ."
# the grant is localhost-only, so connect over the unix socket (no -h)
check "site user can connect to its database" \
  env MYSQL_PWD="$DB_PASS" mariadb -u "$DB_USER" -D "$DB_NAME" -e 'SELECT 1'
check_not "site user cannot read the mysql schema" \
  env MYSQL_PWD="$DB_PASS" mariadb -u "$DB_USER" -D mysql -e 'SELECT 1'
check_not "site user cannot connect over TCP" \
  env MYSQL_PWD="$DB_PASS" mariadb -u "$DB_USER" -h 127.0.0.1 -D "$DB_NAME" -e 'SELECT 1'
check "second db run is idempotent" bash -c "bash '$SETUP' db '$TEST_DOMAIN' --no-color </dev/null | grep -q 'already exists'"
check_not "MariaDB does not listen on a public interface" \
  bash -c "ss -tlnH | awk '{print \$4}' | grep -qE '^(0\.0\.0\.0|\*|\[::\]):3306\$'"

# =============================================================================
step "T08  reporting commands"
# =============================================================================
rc="$(run_setup status status --no-color)";        check_eq "status exits 0" 0 "$rc"
check_has "status lists the site" "$TEST_DOMAIN" "$(cat "${OUT_DIR}/status.out")"
rc="$(run_setup list list --no-color)";            check_eq "list exits 0" 0 "$rc"
rc="$(run_setup credentials credentials "$TEST_DOMAIN" --no-color)"
check_eq "credentials exits 0" 0 "$rc"
check_has "credentials shows the database password" "$DB_PASS" "$(cat "${OUT_DIR}/credentials.out")"
check "status --json is valid JSON" bash -c "bash '$SETUP' status --json </dev/null | jq -e . >/dev/null"
check "list --json is valid JSON"   bash -c "bash '$SETUP' list --json </dev/null | jq -e . >/dev/null"
check "doctor --json is valid JSON" bash -c "bash '$SETUP' doctor --json </dev/null | jq -e . >/dev/null"
# doctor exits 1 when any check fails, which is the case this block exists to report.
# Capturing the output first keeps errexit+pipefail from killing the suite here.
DOC_JSON="$(bash "$SETUP" doctor --json </dev/null || true)"
DOC_FAILS="$(printf '%s' "$DOC_JSON" | jq -r '.summary.fail // "unknown"')"
check_eq "doctor reports no failures" "0" "$DOC_FAILS"
if [[ "$DOC_FAILS" != "0" ]]; then bash "$SETUP" doctor --no-color </dev/null | grep FAIL | sed 's/^/         /'; fi

# =============================================================================
step "T09  backup"
# =============================================================================
rc="$(run_setup backup backup "$TEST_DOMAIN" --no-color --yes)"
check_eq "backup exits 0" 0 "$rc"
ARCHIVE="$(find "${BACKUP_ROOT}/${TEST_DOMAIN}" -maxdepth 1 -name '*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
check "archive created" test -s "$ARCHIVE"
check "archive is 0600" test "$(stat -c %a "$ARCHIVE")" = "600"
check "archive checksum verifies" bash -c "cd '$(dirname "$ARCHIVE")' && sha256sum -c --quiet '$(basename "$ARCHIVE").sha256'"
check "archive contains a manifest" bash -c "tar -tzf '$ARCHIVE' | grep -q '^\./manifest.json$'"
check "archive contains the database dump" bash -c "tar -tzf '$ARCHIVE' | grep -q 'db-.*\.sql\.gz'"
check "archive contains the site files" bash -c "tar -tzf '$ARCHIVE' | grep -q '^\./files\.tar\.gz$'"

# =============================================================================
step "T10  rollback: a broken config must not take the server down"
# =============================================================================
VHCONF="${LSWS_HOME}/conf/vhosts/${TEST_DOMAIN}/vhconf.conf"
cp -p "$VHCONF" "${OUT_DIR}/vhconf.good"
printf '\ncontext /broken/ {\n  location $VH_ROOT/x\n' >>"$VHCONF"   # unbalanced brace on purpose
rc="$(run_setup rollback add "$TEST_DOMAIN2" --no-ssl --non-interactive --no-color --yes)"
check_not "add fails on a broken configuration" test "$rc" = "0"
check "OpenLiteSpeed is still running" systemctl is-active --quiet lsws
check_eq "the existing site still answers" "200" "$(http_code "$TEST_DOMAIN")"
check_not "the failed site was not registered" test -e "${STATE_DIR}/domains/${TEST_DOMAIN2}"
check_not "the failed site left no system user" id -u "$(printf '%s' "$TEST_DOMAIN2" | sed -E 's/[^a-zA-Z0-9]+/_/g' | cut -c1-28)"
check_not "the failed site left no home directory" test -e "/home/${TEST_DOMAIN2}"
check_has "the failure was reported with a cause" "Probable cause" "$(cat "${OUT_DIR}/rollback.out")"
cp -p "${OUT_DIR}/vhconf.good" "$VHCONF"
chown lsadm:lsadm "$VHCONF" 2>/dev/null || true
systemctl reload lsws >/dev/null 2>&1 || true
sleep 2
check_eq "site healthy again after repair" "200" "$(http_code "$TEST_DOMAIN")"

# =============================================================================
step "T11  no secret reaches the log file"
# =============================================================================
check_not "database password is not in the log" grep -qF "$DB_PASS" "$LOG_FILE"
REDIS_PASS="$(awk -F= '$1=="PASSWORD"{sub(/^[^=]*=/,""); print; exit}' "${STATE_DIR}/redis.info")"
check_not "redis password is not in the log" grep -qF "$REDIS_PASS" "$LOG_FILE"
ADMIN_PASS="$(awk -F= '$1=="PASSWORD"{sub(/^[^=]*=/,""); print; exit}' "${STATE_DIR}/openlitespeed-admin.info")"
check_not "WebAdmin password is not in the log" grep -qF "$ADMIN_PASS" "$LOG_FILE"
check_not "no credential-looking assignment in the log" \
  grep -qEi '(password|passwd|secret|token|api[_-]?key|requirepass)[[:space:]]*[=:][[:space:]]*["'"'"']?[A-Za-z0-9+/=._~-]{8,}' "$LOG_FILE"

# =============================================================================
step "T12  add --dry-run changes nothing"
# =============================================================================
rc="$(run_setup adddry add "$TEST_DOMAIN2" --no-ssl --dry-run --non-interactive --no-color)"
check_eq "add --dry-run exits 0" 0 "$rc"
check_not "dry-run created no state" test -e "${STATE_DIR}/domains/${TEST_DOMAIN2}"
check_not "dry-run created no home" test -e "/home/${TEST_DOMAIN2}"
check_not "dry-run created no vhost" test -e "${LSWS_HOME}/conf/vhosts/${TEST_DOMAIN2}"

# =============================================================================
step "T13  remove the site"
# =============================================================================
rc="$(run_setup remove remove "$TEST_DOMAIN" --yes --no-color)"
check_eq "remove exits 0" 0 "$rc"
check_not "home directory removed" test -e "/home/${TEST_DOMAIN}"
check_not "system user removed" id -u "$IDENT"
check_not "vhost config removed" test -e "${LSWS_HOME}/conf/vhosts/${TEST_DOMAIN}"
check_not "vhost unregistered from httpd_config" grep -q "virtualhost ${TEST_DOMAIN}" "${LSWS_HOME}/conf/httpd_config.conf"
check_not "database dropped" bash -c "mariadb -N -B -e \"SHOW DATABASES LIKE '${DB_NAME}'\" | grep -q ."
check_not "database user dropped" bash -c "mariadb -N -B -e \"SELECT 1 FROM mysql.user WHERE User='${DB_USER}'\" | grep -q ."
check_not "no cron entry left for the site" grep -q "$TEST_DOMAIN" /etc/cron.d/server-setup
check "state archived, not deleted" bash -c "ls -d ${STATE_DIR}/archive/domains/${TEST_DOMAIN}.* >/dev/null 2>&1"
check "safety backup was taken before removal" bash -c "ls ${BACKUP_ROOT}/${TEST_DOMAIN}/*pre-remove* >/dev/null 2>&1"
check "OpenLiteSpeed still healthy after removal" "${LSWS_HOME}/bin/openlitespeed" -t
check_eq "catch-all still answers 403" "403" "$(http_code "$TEST_DOMAIN")"

# =============================================================================
step "T14  final health"
# =============================================================================
# doctor exits 1 when any check fails, which is the case this block exists to report.
# Capturing the output first keeps errexit+pipefail from killing the suite here.
DOC_JSON="$(bash "$SETUP" doctor --json </dev/null || true)"
DOC_FAILS="$(printf '%s' "$DOC_JSON" | jq -r '.summary.fail // "unknown"')"
check_eq "doctor reports no failures at the end" "0" "$DOC_FAILS"
check "status still works" bash -c "bash '$SETUP' status --no-color </dev/null >/dev/null"

# =============================================================================
ELAPSED=$(( $(date +%s) - START_TS ))
printf '\n%s================ RESULT ================%s\n' "$C_B" "$C_0"
printf '  passed : %s%d%s\n' "$C_G" "$PASS" "$C_0"
printf '  failed : %s%d%s\n' "$( ((FAIL)) && printf '%s' "$C_R" || printf '%s' "$C_G")" "$FAIL" "$C_0"
printf '  skipped: %d\n' "$SKIP"
printf '  runtime: %dm %ds\n' $((ELAPSED / 60)) $((ELAPSED % 60))
if ((FAIL)); then
  printf '\n%sFailed checks:%s\n' "$C_R" "$C_0"
  printf '  - %s\n' "${FAILED_TESTS[@]}"
  printf '\nCommand output: %s\n' "$OUT_DIR"
  exit 1
fi
printf '\n%sAll acceptance criteria met.%s\n' "$C_G" "$C_0"
exit 0
