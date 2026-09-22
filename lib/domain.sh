#!/usr/bin/env bash
# lib/domain.sh - sites: add / remove / list / logs / credentials, per-site state,
#                 users & directories, WordPress, logrotate + fail2ban regeneration.

# ---- per-site state (loaded from domain.json or set by "add") ---------------
# D_PATH_PROXIES: one "path target" line per path proxy (.proxies[], written by lib/proxy.sh)
D_PATH_PROXIES=""
D_DOMAIN="" D_IDENT="" D_USER="" D_GROUP="" D_HOME="" D_MODE="php" D_PHP="" D_PHP_CHILDREN=""
D_MEMORY="" D_UPLOAD="" D_PROXY="" D_STATIC_PATHS="/static/,/assets/,/uploads/" D_WS_PATH=""
D_WWW=0 D_WWW_PRIMARY=0 D_SSL=0 D_SSL_WANTED=1 D_SSL_WILDCARD=0 D_HSTS_PRELOAD=0 D_CLOUDFLARE=0
D_EMAIL="" D_CREATED="" D_STATUS="" D_DB_NAME="" D_DB_USER="" D_WP=0 D_BACKUP_LAST="" D_STAGING=0
# ---- add-only options ---------------------------------------------------------
# Every new site gets a database and its own MariaDB user by default; --no-db opts out.
DOM_OPT_WP_TITLE="" DOM_OPT_WP_ADMIN="admin" DOM_OPT_WP_EMAIL="" DOM_OPT_WP_LOCALE="en_US" DOM_OPT_WITH_DB=1
DOMAIN_CREATED_HOME=0
DOMAIN_CREATED_USER=0

WPCLI_PHAR="${INSTALL_DIR}/wp-cli.phar"
WPCLI_BIN="/usr/local/bin/wp"

# =============================================================================
#  State
# =============================================================================
lib_domain_state_reset() {
  D_PATH_PROXIES=""
  D_DOMAIN="" D_IDENT="" D_USER="" D_GROUP="" D_HOME="" D_MODE="php" D_PHP="" D_PHP_CHILDREN=""
  D_MEMORY="" D_UPLOAD="" D_PROXY="" D_STATIC_PATHS="/static/,/assets/,/uploads/" D_WS_PATH=""
  D_WWW=0 D_WWW_PRIMARY=0 D_SSL=0 D_SSL_WANTED=1 D_SSL_WILDCARD=0 D_HSTS_PRELOAD=0 D_CLOUDFLARE=0
  D_EMAIL="" D_CREATED="" D_STATUS="" D_DB_NAME="" D_DB_USER="" D_WP=0 D_BACKUP_LAST="" D_STAGING=0
}

_d_bool() { [[ "$1" == "true" ]] && printf '1' || printf '0'; }
_d_json_bool() { (( ${1:-0} )) && printf 'true' || printf 'false'; }

# lib_domain_state_load domain  (returns 1 when not registered)
lib_domain_state_load() {
  local domain="$1" f=""
  f="$(lib_domain_json "$domain")"
  lib_domain_state_reset
  [[ -s "$f" ]] || return 1
  D_DOMAIN="$(lib_json_get "$f" '.domain')"
  D_IDENT="$(lib_json_get "$f" '.ident')"
  D_USER="$(lib_json_get "$f" '.user')"
  D_GROUP="$(lib_json_get "$f" '.group')"
  D_HOME="$(lib_json_get "$f" '.home')"
  D_MODE="$(lib_json_get "$f" '.mode')"
  D_PHP="$(lib_json_get "$f" '.php.version')"
  D_PHP_CHILDREN="$(lib_json_get "$f" '.php.children')"
  D_MEMORY="$(lib_json_get "$f" '.php.memory_limit')"
  D_UPLOAD="$(lib_json_get "$f" '.php.upload_max')"
  D_PROXY="$(lib_json_get "$f" '.proxy.target')"
  D_STATIC_PATHS="$(lib_json_get "$f" '.proxy.static_paths')"
  D_WS_PATH="$(lib_json_get "$f" '.proxy.websocket_path')"
  D_PATH_PROXIES="$(jq -r '(.proxies // [])[] | "\(.path) \(.target)"' "$f" 2>/dev/null || true)"
  D_WWW="$(_d_bool "$(lib_json_get "$f" '.www')")"
  D_WWW_PRIMARY="$(_d_bool "$(lib_json_get "$f" '.www_primary')")"
  D_SSL="$(_d_bool "$(lib_json_get "$f" '.ssl.enabled')")"
  D_SSL_WANTED="$(_d_bool "$(lib_json_get "$f" '.ssl.wanted')")"
  D_SSL_WILDCARD="$(_d_bool "$(lib_json_get "$f" '.ssl.wildcard')")"
  D_HSTS_PRELOAD="$(_d_bool "$(lib_json_get "$f" '.ssl.hsts_preload')")"
  D_CLOUDFLARE="$(_d_bool "$(lib_json_get "$f" '.cloudflare')")"
  D_EMAIL="$(lib_json_get "$f" '.email')"
  D_CREATED="$(lib_json_get "$f" '.created_at')"
  D_STATUS="$(lib_json_get "$f" '.status')"
  D_DB_NAME="$(lib_json_get "$f" '.db.name')"
  D_DB_USER="$(lib_json_get "$f" '.db.user')"
  D_WP="$(_d_bool "$(lib_json_get "$f" '.wordpress')")"
  D_BACKUP_LAST="$(lib_json_get "$f" '.backup.last')"
  [[ -z "$D_MODE" ]] && D_MODE="php"
  [[ -z "$D_HOME" ]] && D_HOME="$(lib_domain_home "$domain")"
  # "none" is how "--static-paths ''" survives a round trip. An empty string here cannot be
  # told apart from "key absent", so the default came back on every reload and re-added
  # three contexts pointing at directories that add time never created - after which
  # openlitespeed -t rejected the vhost and renew-ssl failed for that site forever.
  if [[ "$D_STATIC_PATHS" == "none" ]]; then D_STATIC_PATHS=""
  elif [[ -z "$D_STATIC_PATHS" ]]; then D_STATIC_PATHS="/static/,/assets/,/uploads/"; fi
  return 0
}

lib_domain_state_json() {
  jq -n \
    --arg domain "$D_DOMAIN" --arg ident "$D_IDENT" --arg user "$D_USER" --arg group "$D_GROUP" --arg home "$D_HOME" \
    --arg mode "$D_MODE" --arg php "$D_PHP" --arg children "$D_PHP_CHILDREN" --arg mem "$D_MEMORY" --arg up "$D_UPLOAD" \
    --arg proxy "$D_PROXY" --arg spaths "${D_STATIC_PATHS:-none}" --arg ws "$D_WS_PATH" \
    --argjson www "$(_d_json_bool "$D_WWW")" --argjson wwwp "$(_d_json_bool "$D_WWW_PRIMARY")" \
    --argjson ssl "$(_d_json_bool "$D_SSL")" --argjson sslw "$(_d_json_bool "$D_SSL_WANTED")" \
    --argjson wild "$(_d_json_bool "$D_SSL_WILDCARD")" --argjson hsts "$(_d_json_bool "$D_HSTS_PRELOAD")" \
    --argjson cf "$(_d_json_bool "$D_CLOUDFLARE")" --arg email "$D_EMAIL" --arg created "$D_CREATED" \
    --arg status "$D_STATUS" --arg dbn "$D_DB_NAME" --arg dbu "$D_DB_USER" --argjson wp "$(_d_json_bool "$D_WP")" \
    --arg blast "$D_BACKUP_LAST" --arg ts "$(lib_iso_now)" --arg ver "$SCRIPT_VERSION" \
    '{domain:$domain, ident:$ident, user:$user, group:$group, home:$home, mode:$mode,
      php:{version:$php, children:$children, memory_limit:$mem, upload_max:$up},
      proxy:{target:$proxy, static_paths:$spaths, websocket_path:$ws},
      www:$www, www_primary:$wwwp,
      ssl:{enabled:$ssl, wanted:$sslw, wildcard:$wild, hsts_preload:$hsts},
      cloudflare:$cf, email:$email, created_at:$created, status:$status,
      db:(if $dbn == "" then null else {name:$dbn, user:$dbu} end),
      wordpress:$wp, backup:{last:$blast}, updated_at:$ts, script_version:$ver}
     | del(.. | nulls)'
}

lib_domain_state_save() {
  local dir="" f="" tmp=""
  dir="$(lib_domain_state_dir "$D_DOMAIN")"; f="${dir}/domain.json"
  if (( OPT_DRY_RUN )); then lib_debug "dry-run: state for ${D_DOMAIN} not written"; return 0; fi
  mkdir -p "$dir" && chmod 0700 "$dir"
  tmp="$(lib_mktemp)"
  # keep fields written by other modules (db.*, ssl.expires, backup.last ...)
  if [[ -s "$f" ]]; then
    lib_domain_state_json >"${tmp}.new"
    jq -s '.[0] * .[1]' "$f" "${tmp}.new" >"$tmp"
    rm -f "${tmp}.new"
  else
    lib_domain_state_json >"$tmp"
  fi
  chmod 0600 "$tmp" && mv -f "$tmp" "$f"
}

# Keep a copy of domain.json and put it back if the run dies before lib_rollback_clear, so a
# command that records a change and then cannot apply it does not leave the state ahead of
# the configuration. Starts a fresh rollback stack.
lib_domain_state_guard() {   # domain
  local f="" bak=""
  (( OPT_DRY_RUN )) && return 0
  f="$(lib_domain_json "$1")"
  bak="$(lib_mktemp)"
  cp -f "$f" "$bak"
  lib_rollback_clear
  lib_rollback_push "cp -f '${bak}' '${f}'"
}

# =============================================================================
#  add
# =============================================================================
lib_domain_add_usage() {
  cat <<'EOF'
Usage: setup.sh add <domain> [options]
  --email a@b.c        Contact e-mail (Let's Encrypt, vhost adminEmails)
  --no-ssl             Do not request a certificate (add later with renew-ssl)
  --www                Serve www.<domain> too; redirects www -> apex
  --www-primary        With --www: redirect apex -> www instead
  --php 8.3            PHP version for this site (installed on demand)
  --php-children N     LSAPI workers for this site (default from profile)
  --memory 256M        PHP memory_limit           --upload 64M  upload_max_filesize
  --proxy 127.0.0.1:3000   Reverse proxy to an app you run yourself (Node/Python/...)
  --node               Node.js site: PM2 runs the app as the site's user (see: setup.sh app help)
  --port N             With --node: the app's port (default: the first free one from 3000)
  --start "npm start"  With --node: start command, run without a shell  (or --script dist/main.js)
  --git URL            With --node: deploy from this repository right away (--branch B)
  --static-paths "/static/,/assets/"   Paths served by OLS in proxy mode
  --ws-path PATH       No longer needed: WebSocket upgrades are proxied on every path
  --static             Static site only (no PHP)
  --wordpress          Install WordPress (creates the database automatically)
  --no-db              Do not create a database (one is created by default)
  --with-db            Create a database - this is the default, kept for older scripts
  --cloudflare         Enable Cloudflare real-IP mode (global)
  --wildcard           Also request *.<domain> (DNS-01, needs --cf-api-token)
  --staging            Use the Let's Encrypt staging CA
  --hsts-preload       Add "preload" to the HSTS header (irreversible!)
  --wp-title "Site"  --wp-admin admin  --wp-email a@b.c  --wp-locale en_US
EOF
}

lib_domain_parse_add_args() {
  local a="" static_set=0
  lib_domain_state_reset
  APP_OPT_NODE=0 APP_OPT_PORT="" APP_OPT_START="" APP_OPT_SCRIPT="" APP_OPT_GIT="" APP_OPT_BRANCH=""
  D_DOMAIN="${1,,}"; shift
  D_EMAIL="$DEFAULT_EMAIL"
  D_PHP="$PHP_VERSION"
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --email)        D_EMAIL="${1:-}"; shift ;;
      --no-ssl)       D_SSL_WANTED=0 ;;
      --www)          D_WWW=1 ;;
      --www-primary)  D_WWW=1; D_WWW_PRIMARY=1 ;;
      --php)          D_PHP="${1:-}"; shift ;;
      --php-children) D_PHP_CHILDREN="${1:-}"; shift ;;
      --memory)       D_MEMORY="${1:-}"; shift ;;
      --upload)       D_UPLOAD="${1:-}"; shift ;;
      --proxy)        D_MODE="proxy"; D_PROXY="${1:-}"; shift ;;
      --node)         D_MODE="proxy"; APP_OPT_NODE=1 ;;
      --port)         APP_OPT_PORT="${1:-}"; shift ;;
      --start)        APP_OPT_START="${1:-}"; shift ;;
      --script)       APP_OPT_SCRIPT="${1:-}"; shift ;;
      --git)          APP_OPT_GIT="${1:-}"; shift ;;
      --branch)       APP_OPT_BRANCH="${1:-}"; shift ;;
      --static-paths) D_STATIC_PATHS="${1:-}"; static_set=1; shift ;;
      --ws-path)      D_WS_PATH="${1:-}"; shift ;;
      --static)       D_MODE="static" ;;
      --wordpress)    D_MODE="wordpress"; DOM_OPT_WITH_DB=1 ;;
      --with-db)      DOM_OPT_WITH_DB=1 ;;
      --no-db)        DOM_OPT_WITH_DB=0 ;;
      --cloudflare)   D_CLOUDFLARE=1 ;;
      --wildcard)     D_SSL_WILDCARD=1 ;;
      --staging)      D_STAGING=1 ;;
      --hsts-preload) D_HSTS_PRELOAD=1 ;;
      --wp-title)     DOM_OPT_WP_TITLE="${1:-}"; shift ;;
      --wp-admin)     DOM_OPT_WP_ADMIN="${1:-}"; shift ;;
      --wp-email)     DOM_OPT_WP_EMAIL="${1:-}"; shift ;;
      --wp-locale)    DOM_OPT_WP_LOCALE="${1:-}"; shift ;;
      -h|--help)      lib_domain_add_usage; exit 0 ;;
      *)              lib_domain_add_usage >&2; lib_die "Unknown option for add: ${a}" "" "see the usage above" ;;
    esac
  done
  lib_domain_valid "$D_DOMAIN" || lib_die "Invalid domain name '${D_DOMAIN}'" "not a valid FQDN (use the bare domain, without http:// or paths)" "setup.sh add example.com"
  [[ "$D_DOMAIN" == www.* ]] && lib_die "Use the apex domain and --www instead of www.${D_DOMAIN#www.}" "" "setup.sh add ${D_DOMAIN#www.} --www"
  if (( APP_OPT_NODE )); then
    [[ -z "$D_PROXY" ]] || lib_die "--node and --proxy cannot be combined" "a Node.js site proxies to its own application" "drop --proxy; choose the port with --port"
    [[ -z "$APP_OPT_START" || -z "$APP_OPT_SCRIPT" ]] || lib_die "--start and --script cannot be combined" "" "use one of them"
    [[ -z "$APP_OPT_START" ]] || lib_app_start_valid "$APP_OPT_START" || lib_die "Invalid --start '${APP_OPT_START}'" \
      "the command runs without a shell: words only, no quotes, pipes or &&" "put it into a package.json script and use --start \"npm run <name>\""
    [[ -z "$APP_OPT_SCRIPT" ]] || lib_app_script_valid "$APP_OPT_SCRIPT" || lib_die "Invalid --script '${APP_OPT_SCRIPT}'" "a file inside the app directory, such as dist/main.js" "--script dist/main.js"
    [[ -z "$APP_OPT_PORT" || "$APP_OPT_PORT" =~ ^[0-9]{4,5}$ ]] || lib_die "Invalid --port '${APP_OPT_PORT}'" "a number between 1024 and 65535" "--port 3000"
    [[ -z "$APP_OPT_GIT" ]] || lib_app_git_url_valid "$APP_OPT_GIT" || lib_die "Refused repository URL" \
      "use https://host/owner/repo.git or git@host:owner/repo.git, without a user, password or token inside" \
      "for a private repository add the site first, then: setup.sh app deploy-key ${D_DOMAIN}"
    [[ -z "$APP_OPT_BRANCH" ]] || lib_app_git_branch_valid "$APP_OPT_BRANCH" || lib_die "Invalid --branch '${APP_OPT_BRANCH}'" "" "--branch main"
    [[ -z "$APP_OPT_BRANCH" || -n "$APP_OPT_GIT" ]] || lib_die "--branch needs --git" "" "setup.sh add ${D_DOMAIN} --node --git <url> --branch ${APP_OPT_BRANCH}"
    # a Node.js application serves its own assets: paths served from disk would shadow them
    if (( ! static_set )); then D_STATIC_PATHS=""; fi
  elif [[ -n "${APP_OPT_PORT}${APP_OPT_START}${APP_OPT_SCRIPT}${APP_OPT_GIT}${APP_OPT_BRANCH}" ]]; then
    lib_die "--port, --start, --script, --git and --branch belong to --node" "" "setup.sh add ${D_DOMAIN} --node --port 3000"
  fi
  if [[ "$D_MODE" == "proxy" ]]; then
    if (( ! APP_OPT_NODE )); then
      [[ "$D_PROXY" =~ ^[A-Za-z0-9.-]+:[0-9]{2,5}$ ]] || lib_die "Invalid --proxy target '${D_PROXY}'" "expected host:port" "--proxy 127.0.0.1:3000"
    fi
    if [[ -n "$D_WS_PATH" ]]; then lib_note "--ws-path is no longer needed: a proxy site passes WebSocket upgrades on every path"; fi
  fi
  if [[ "$D_MODE" == "php" || "$D_MODE" == "wordpress" ]]; then
    lib_php_valid_version "$D_PHP" || lib_die "Invalid PHP version '${D_PHP}'" "expected e.g. 8.3" "--php 8.3"
    [[ -z "$D_PHP_CHILDREN" || "$D_PHP_CHILDREN" =~ ^[0-9]{1,2}$ ]] || lib_die "Invalid --php-children '${D_PHP_CHILDREN}'" "1..64 expected" "--php-children 6"
    [[ -z "$D_MEMORY" || "$D_MEMORY" =~ ^[0-9]+[MG]$ ]] || lib_die "Invalid --memory '${D_MEMORY}'" "use e.g. 256M or 1G" "--memory 256M"
    [[ -z "$D_UPLOAD" || "$D_UPLOAD" =~ ^[0-9]+[MG]$ ]] || lib_die "Invalid --upload '${D_UPLOAD}'" "use e.g. 64M" "--upload 64M"
  else
    D_PHP=""; D_PHP_CHILDREN=""; D_MEMORY=""; D_UPLOAD=""
  fi
  (( D_SSL_WILDCARD )) && (( ! D_SSL_WANTED )) && lib_die "--wildcard and --no-ssl cannot be combined" "" "drop one of them"
  D_IDENT="$(lib_domain_ident "$D_DOMAIN")"
  D_HOME="$(lib_domain_home "$D_DOMAIN")"
  D_USER="$D_IDENT"; D_GROUP="$D_IDENT"
  D_STATUS="installing"
  D_CREATED="$(lib_iso_now)"
  return 0
}

lib_domain_add_main() {
  [[ -n "${1:-}" ]] || { lib_domain_add_usage; lib_die "Domain missing" "" "setup.sh add example.com"; }
  [[ "$1" == "-h" || "$1" == "--help" ]] && { lib_domain_add_usage; return 0; }
  lib_require_tools
  lib_require_installed
  lib_domain_parse_add_args "$@"
  local domain="$D_DOMAIN" total=6 http_expect="200|301|302" rc="" why=""
  lib_domain_registered "$domain" && lib_die "Site ${domain} already exists" "registered in $(lib_domain_state_dir "$domain")" "use 'setup.sh remove ${domain}' first, or 'renew-ssl' / 'db' to change it"
  lib_ols_is_installed || lib_die "OpenLiteSpeed is not installed" "run install first" "sudo ./setup.sh install"
  (( D_SSL_WANTED )) && total=$((total + 1))
  (( DOM_OPT_WITH_DB )) && total=$((total + 1))
  [[ "$D_MODE" == "wordpress" ]] && total=$((total + 1))
  (( APP_OPT_NODE )) && total=$((total + 1))
  lib_steps_begin "$total"
  lib_rollback_clear
  lib_system_profile
  [[ -z "$D_MEMORY" && -n "$D_PHP" ]] && D_MEMORY="${CALC_PHP_MEMORY_MB}M"
  [[ -z "$D_UPLOAD" && -n "$D_PHP" ]] && D_UPLOAD="${CALC_PHP_UPLOAD_MB}M"
  [[ -z "$D_PHP_CHILDREN" && -n "$D_PHP" ]] && D_PHP_CHILDREN="$CALC_PHP_CHILDREN_SITE"

  # ---- 1 preflight ---------------------------------------------------------
  lib_step "Preflight checks for ${domain} (mode: ${D_MODE})"
  if [[ -n "$D_PHP" ]]; then lib_php_ensure_version "$D_PHP"; fi
  if (( D_CLOUDFLARE )) && [[ "$(lib_manifest_get '.cloudflare.enabled')" != "true" ]]; then lib_cf_enable; fi
  [[ "$(lib_manifest_get '.cloudflare.enabled')" == "true" ]] && D_CLOUDFLARE=1
  if [[ "$D_MODE" == "wordpress" ]] && ! lib_db_installed; then lib_die "WordPress needs MariaDB" "MariaDB is not installed" "run: setup.sh install"; fi
  if (( APP_OPT_NODE )); then
    # before anything is created, so a missing runtime or a taken port stops the run here
    lib_app_node_ensure
    if [[ -z "$APP_OPT_PORT" ]]; then
      APP_OPT_PORT="$(lib_app_port_pick)" || lib_die "No free port between ${APP_PORT_MIN} and ${APP_PORT_MAX}" "" "choose one with --port"
    fi
    why="$(lib_app_port_conflict "$APP_OPT_PORT" || true)"
    [[ -z "$why" ]] || lib_die "Port ${APP_OPT_PORT} cannot be used for ${domain}" "$why" "choose another one with --port, or leave --port out to get a free one"
    APP_OPT_PORT="$((10#$APP_OPT_PORT))"
    D_PROXY="127.0.0.1:${APP_OPT_PORT}"
    lib_ok "Node.js $(node -v 2>/dev/null || printf '(not installed yet)') with PM2; the application will listen on ${D_PROXY}"
  fi
  (( OPT_DRY_RUN )) || lib_rollback_push "rm -rf '$(lib_domain_state_dir "$domain")'"
  lib_domain_state_save
  lib_ok "Preflight OK (user ${D_USER}, home ${D_HOME})"

  # ---- 2 user + directories ------------------------------------------------
  lib_step "System user and directory layout"
  lib_domain_user_ensure
  lib_domain_dirs_create
  lib_ok "Directories ready: ${D_HOME}/{public_html,logs,private,backups}"

  # ---- 3 vhost -------------------------------------------------------------
  lib_step "OpenLiteSpeed virtual host"
  (( OPT_DRY_RUN )) || lib_rollback_push "lib_ols_vhost_purge '${domain}' 0"
  lib_domain_apply_config "add vhost ${domain}"

  # ---- 4 smoke test --------------------------------------------------------
  lib_step "Smoke test (HTTP)"
  http_expect="$(lib_domain_expected_codes)"
  lib_ols_smoke_test "$domain" "$http_expect" || lib_die "Smoke test failed for ${domain}" "${OLS_TEST_OUTPUT}" "check ${LSWS_HOME}/logs/error.log and ${D_HOME}/logs/error.log"
  if [[ "$D_MODE" == "php" || "$D_MODE" == "wordpress" ]]; then
    lib_domain_php_probe || lib_die "PHP is not executing for ${domain}" "${OLS_TEST_OUTPUT}" "check ${D_HOME}/logs/error.log and the LSAPI processor (${D_IDENT})"
  fi
  lib_ok "Site answers on http://${domain}/"
  if [[ "$D_MODE" == "proxy" ]]; then
    lib_note "Until your application listens on ${D_PROXY}, the site answers 502/503. That is expected."
  fi

  # ---- 5 SSL ---------------------------------------------------------------
  if (( D_SSL_WANTED )); then
    lib_step "SSL certificate (Let's Encrypt)"
    lib_domain_add_ssl
  fi

  # ---- 6 database ----------------------------------------------------------
  if (( DOM_OPT_WITH_DB )); then
    lib_step "MariaDB database"
    lib_db_create_for_domain "$domain"
    lib_domain_state_load "$domain" >/dev/null 2>&1 || true
  fi

  # ---- 7 WordPress ---------------------------------------------------------
  if [[ "$D_MODE" == "wordpress" ]]; then
    lib_step "WordPress installation"
    lib_domain_wp_install
    # WordPress wrote its .htaccess (permalinks, LiteSpeed Cache) after OpenLiteSpeed loaded the
    # configuration, and OpenLiteSpeed reads it only while loading: without this, every
    # permalink answers 404 until the next restart
    lib_ols_htaccess_reload "WordPress wrote ${D_HOME}/public_html/.htaccess" \
      || lib_warn "OpenLiteSpeed did not reload; permalinks work after: systemctl restart ${OLS_SERVICE}"
  fi

  # ---- 8 housekeeping ------------------------------------------------------
  lib_step "Log rotation, fail2ban and scheduled tasks"
  D_STATUS="active"
  lib_domain_state_save
  lib_domain_logrotate_regen
  lib_domain_fail2ban_regen
  if [[ "$D_MODE" == "php" || "$D_MODE" == "wordpress" ]]; then lib_ols_htaccess_watch_ensure; fi
  lib_ok "Housekeeping done"

  # From here on nothing undoes the site: the vhost, certificate and database are in place,
  # and creating them again on a retry would only burn Let's Encrypt rate limits.
  lib_rollback_clear

  # ---- 9 Node.js application -------------------------------------------------
  if (( APP_OPT_NODE )); then
    lib_step "Node.js application (PM2)"
    lib_app_provision_new
  fi

  # ---- 10 summary ----------------------------------------------------------
  lib_step "Done"
  lib_manifest_set '.updated_at' "$(lib_iso_now)"
  lib_domain_summary
}

# SSL inside "add": failures are reported, the site stays (renew-ssl later).
lib_domain_add_ssl() {
  local rc=0 method="auto"
  lib_ssl_dns_check "$D_DOMAIN" "$D_WWW" || rc=$?
  if (( rc == 1 )); then
    lib_error "DNS for ${D_DOMAIN} does not point to this server: ${SSL_LAST_ERROR}"
    lib_warn "Certificate skipped. Point the A/AAAA records to ${SYS_PUBLIC_IPV4:-<server IP>} and run: setup.sh renew-ssl ${D_DOMAIN}"
    return 0
  elif (( rc == 2 )); then
    lib_warn "${D_DOMAIN} is proxied by Cloudflare (orange cloud)."
    if lib_ssl_cf_token_available; then
      lib_info "Using DNS-01 validation with the stored Cloudflare API token"; method="dns"
    else
      lib_warn "HTTP-01 through the Cloudflare proxy may fail; DNS-01 is recommended (setup.sh install --cf-api-token <token>). Trying HTTP-01 anyway..."
    fi
  fi
  if (( D_SSL_WILDCARD )) && ! lib_ssl_cf_token_available; then
    lib_error "--wildcard needs DNS-01 with a Cloudflare API token (${CF_INI} missing); certificate skipped"
    return 0
  fi
  if lib_ssl_obtain "$D_DOMAIN" "$D_WWW" "$D_SSL_WILDCARD" "$D_STAGING" 0 "$D_EMAIL" "$method"; then
    (( OPT_DRY_RUN )) && return 0
    (( OPT_DRY_RUN )) || lib_rollback_push "lib_ssl_delete '${D_DOMAIN}'"
    D_SSL=1
    lib_domain_state_save
    lib_domain_apply_config "enable SSL for ${D_DOMAIN}"
    if lib_ols_smoke_test "$D_DOMAIN" "$(lib_domain_expected_codes)" https; then lib_ok "HTTPS active: https://${D_DOMAIN}/"
    else lib_warn "HTTPS smoke test failed (${OLS_TEST_OUTPUT}); check ${D_HOME}/logs/error.log"; fi
  else
    lib_error "Certificate could not be obtained: ${SSL_LAST_ERROR}"
    lib_warn "The site stays on HTTP. Fix the problem and run: setup.sh renew-ssl ${D_DOMAIN}"
  fi
  return 0
}

# =============================================================================
#  Users, directories, config application, probes
# =============================================================================
lib_domain_user_ensure() {
  local existing_home=""
  if getent group "$D_GROUP" >/dev/null 2>&1; then :; else
    if (( OPT_DRY_RUN )); then lib_info "[dry-run] would create group ${D_GROUP}"; else lib_run groupadd "$D_GROUP" || lib_die "groupadd ${D_GROUP} failed" "" "check /etc/group"; fi
  fi
  if id -u "$D_USER" >/dev/null 2>&1; then
    existing_home="$(getent passwd "$D_USER" | cut -d: -f6)"
    if [[ "$existing_home" != "$D_HOME" ]]; then
      lib_die "System user ${D_USER} already exists with home ${existing_home}" "name collision with an unrelated account" "remove/rename that account or choose another domain"
    fi
    lib_ok "System user ${D_USER} exists"
  else
    if (( OPT_DRY_RUN )); then lib_info "[dry-run] would create user ${D_USER} (home ${D_HOME}, nologin)"
    else
      lib_run useradd -M -d "$D_HOME" -s /usr/sbin/nologin -g "$D_GROUP" -c "site ${D_DOMAIN}" "$D_USER" || lib_die "useradd ${D_USER} failed" "" "check /etc/passwd"
      DOMAIN_CREATED_USER=1
      lib_rollback_push "userdel '${D_USER}' >/dev/null 2>&1; groupdel '${D_GROUP}' >/dev/null 2>&1"
    fi
  fi
  return 0
}

lib_domain_dirs_create() {
  local ols_user=""; ols_user="$(lib_ols_user)"
  if [[ ! -d "$D_HOME" ]]; then
    DOMAIN_CREATED_HOME=1
    (( OPT_DRY_RUN )) || lib_rollback_push "rm -rf '${D_HOME}'"
  fi
  lib_mkdir "$D_HOME" 0711 "${D_USER}:${D_GROUP}"
  lib_mkdir "${D_HOME}/public_html" 0755 "${D_USER}:${D_GROUP}"
  lib_mkdir "${D_HOME}/private" 0700 "${D_USER}:${D_GROUP}"
  lib_mkdir "${D_HOME}/private/sessions" 0700 "${D_USER}:${D_GROUP}"
  lib_mkdir "${D_HOME}/private/tmp" 0700 "${D_USER}:${D_GROUP}"
  lib_mkdir "${D_HOME}/backups" 0700 "${D_USER}:${D_GROUP}"
  lib_mkdir "${D_HOME}/logs" 0750 "root:${D_GROUP}"
  if [[ "$D_MODE" == "proxy" ]]; then
    lib_mkdir "${D_HOME}/app" 0750 "${D_USER}:${D_GROUP}"
    # every static context in the vhost points at one of these; OpenLiteSpeed rejects the
    # whole configuration with "path is not accessible" if the directory is missing
    local p=""
    for p in ${D_STATIC_PATHS//,/ }; do
      [[ "$p" == /*/ ]] || continue
      lib_mkdir "${D_HOME}/public_html${p}" 0755 "${D_USER}:${D_GROUP}"
    done
  fi
  if [[ "$D_MODE" == "wordpress" ]]; then
    lib_mkdir "${OLS_CACHE_DIR}/${D_DOMAIN}" 0750 "${ols_user}:$(lib_ols_group)"
  fi
  lib_ols_acme_root_ensure
  # OLS worker (nobody) must be able to traverse into public_html
  (( OPT_DRY_RUN )) || setfacl -m "u:${ols_user}:x" "$D_HOME" 2>/dev/null || true
  if [[ ! -e "${D_HOME}/public_html/index.html" && ! -e "${D_HOME}/public_html/index.php" ]] && [[ "$D_MODE" != "proxy" ]]; then
    if (( ! OPT_DRY_RUN )); then
      cat >"${D_HOME}/public_html/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${D_DOMAIN}</title>
<style>body{font-family:system-ui,sans-serif;margin:10% auto;max-width:40em;color:#333}</style></head>
<body><h1>${D_DOMAIN}</h1><p>This site was provisioned by server-setup and is waiting for content.</p>
<p>Upload files to <code>${D_HOME}/public_html/</code>.</p></body></html>
EOF
      chown "${D_USER}:${D_GROUP}" "${D_HOME}/public_html/index.html"
    fi
  fi
  return 0
}

# HTTP status codes that mean "this vhost is working", for the site currently in D_*.
# Kept in one place so the add, SSL and renew paths cannot drift apart.
#   proxy sites: the application is usually deployed after the site is created, so a
#                502/503/504 from an absent backend still proves the vhost is right
#   lenient    : also accept 403, which an existing site with an empty docroot returns
lib_domain_expected_codes() {   # [lenient]
  local codes="200|301|302"
  if (( D_WWW && D_WWW_PRIMARY )); then codes="301|302"; fi
  if [[ "$D_MODE" == "proxy" ]]; then codes="${codes}|502|503|504"; fi
  if [[ "${1:-}" == "lenient" ]]; then codes="${codes}|403"; fi
  printf '%s' "$codes"
}

# Render vhconf + register vhost/maps in httpd_config, test and reload (one change set).
lib_domain_apply_config() {   # [description]
  local desc="${1:-vhost ${D_DOMAIN}}" script=1
  [[ "$D_MODE" == "php" || "$D_MODE" == "wordpress" ]] || script=0
  # Every other lib_ols_tx_begin call site checks this. Without it, "renew-ssl" and
  # "restore" on a host that has lost httpd_config.conf start a transaction from an empty
  # file and COMMIT a stub config to the canonical path - which the gate then passes,
  # because openlitespeed -t is skipped when the binary is missing too.
  lib_ols_is_installed || lib_die "OpenLiteSpeed is not installed on this server" \
    "${LSWS_CONF} is missing, so there is no configuration to add ${D_DOMAIN} to" \
    "run 'lompstack install' first, then retry"
  lib_system_profile
  lib_ols_change_begin
  lib_ols_vhconf_write "$D_DOMAIN"
  lib_ols_tx_begin
  lib_ols_tx_vhost_add "$D_DOMAIN" "$D_WWW" "$script"
  lib_ols_tx_commit
  lib_ols_change_commit "$desc"
}

# Drop a tiny PHP probe into the docroot, fetch it, remove it.
lib_domain_php_probe() {
  (( OPT_DRY_RUN )) && return 0
  local name="" f="" body="" i=""
  name="ss-probe-$(lib_random_hex 6).php"
  f="${D_HOME}/public_html/${name}"
  printf '<?php echo "server-setup-php-ok:" . PHP_VERSION;\n' >"$f"
  chown "${D_USER}:${D_GROUP}" "$f"
  for (( i = 0; i < 5; i++ )); do
    body="$(curl -s --max-time 15 -H "Host: ${D_DOMAIN}" "http://127.0.0.1/${name}" 2>/dev/null || true)"
    [[ "$body" == server-setup-php-ok:* ]] && break
    sleep 2
  done
  rm -f "$f"
  if [[ "$body" == server-setup-php-ok:* ]]; then lib_debug "PHP probe OK (${body#*:})"; return 0; fi
  OLS_TEST_OUTPUT="PHP probe returned: ${body:0:120}"
  return 1
}

# =============================================================================
#  logrotate / fail2ban regeneration (state -> config)
# =============================================================================
lib_domain_logrotate_regen() {
  local d="" line="" u="" g="" h="" paths=() apps=()
  while read -r d; do [[ -n "$d" ]] && paths+=("$(lib_domain_home "$d")/logs/*.log"); done < <(lib_domains_list)
  # Node.js sites: PM2 writes into the site user's own ~/.pm2, so logrotate works there as that
  # user (as root it would follow whatever links the user put in place of the logs)
  while read -r d; do
    [[ -n "$d" ]] || continue
    line="$(jq -r 'select(has("app")) | "\(.user) \(.group) \(.home)"' "$(lib_domain_json "$d")" 2>/dev/null || true)"
    if [[ -n "$line" ]]; then apps+=("$line"); fi
  done < <(lib_domains_list)
  {
    printf '# Managed by lompstack - site logs (OpenLiteSpeed rolling is disabled for sites; logrotate owns rotation)\n'
    if ((${#paths[@]} > 0)); then
      printf '%s\n' "${paths[@]}"
      cat <<'EOF'
{
  daily
  missingok
  rotate 14
  compress
  delaycompress
  notifempty
  copytruncate
  dateext
  su root root
}
EOF
    fi
    for line in "${apps[@]}"; do
      read -r u g h <<<"$line"
      printf '\n%s/.pm2/logs/*.log %s/.pm2/pm2.log\n' "$h" "$h"
      printf '{\n  daily\n  missingok\n  rotate 14\n  compress\n  delaycompress\n  notifempty\n  copytruncate\n  dateext\n  su %s %s\n}\n' "$u" "$g"
    done
  } | lib_write_file "$LOGROTATE_SITES_FILE" 0644 root:root
  return 0
}

lib_domain_fail2ban_filters_write() {
  lib_mkdir "$FAIL2BAN_FILTER_DIR" 0755 root:root
  cat <<'EOF' | lib_write_file "${FAIL2BAN_FILTER_DIR}/server-setup-wp-login.conf" 0644 root:root
# Managed by lompstack - WordPress login / xmlrpc brute force (OpenLiteSpeed combined access log)
[Definition]
failregex = ^<HOST> \S+ \S+ \[[^\]]+\] "POST /+(?:wp-login\.php|xmlrpc\.php)[^"]*" (?:200|403)
ignoreregex =
EOF
  cat <<'EOF' | lib_write_file "${FAIL2BAN_FILTER_DIR}/server-setup-web-probe.conf" 0644 root:root
# Managed by lompstack - vulnerability scanners probing well-known paths
[Definition]
failregex = ^<HOST> \S+ \S+ \[[^\]]+\] "(?:GET|POST|HEAD) /+(?:\.env|\.git|\.aws|\.ssh|wp-config\.php|phpmyadmin|pma|adminer|cgi-bin|vendor/phpunit|wp-content/plugins/[^/]+/[^"]*\.php)[^"]*" (?:403|404)
ignoreregex =
EOF
  return 0
}

lib_domain_fail2ban_regen() {
  local d="" logs=() enabled=true
  lib_pkg_installed fail2ban || return 0
  while read -r d; do [[ -n "$d" ]] && logs+=("$(lib_domain_home "$d")/logs/access.log"); done < <(lib_domains_list)
  ((${#logs[@]} == 0)) && { enabled=false; logs=("/dev/null"); }
  lib_domain_fail2ban_filters_write
  # rewrites the action and its 0600 header file; both are idempotent, and this is where a
  # server that stored its token before the header file existed picks it up
  if [[ -n "$(lib_cf_token)" ]]; then lib_cf_fail2ban_action_write; fi
  local cf_action=""; cf_action="$(lib_cf_fail2ban_action_lines)"
  # NOTE: every branch below must end on a successful command. A trailing
  # "[[ ... ]] && printf ..." makes the whole group exit 1 when the test is false,
  # and pipefail then propagates that to the pipeline. Use "if" blocks here.
  {
    printf '# Managed by lompstack - web jails (regenerated on add/remove)\n\n'
    printf '[server-setup-wp-login]\nenabled = %s\nfilter = server-setup-wp-login\nbackend = auto\nport = http,https\nmaxretry = 10\nfindtime = 10m\nbantime = 1h\nlogpath = %s\n' "$enabled" "$(lib_join $'\n          ' "${logs[@]}")"
    if [[ -n "$cf_action" ]]; then printf '%s\n' "$cf_action"; fi
    printf '\n[server-setup-web-probe]\nenabled = %s\nfilter = server-setup-web-probe\nbackend = auto\nport = http,https\nmaxretry = 5\nfindtime = 10m\nbantime = 6h\nlogpath = %s\n' "$enabled" "$(lib_join $'\n          ' "${logs[@]}")"
    if [[ -n "$cf_action" ]]; then printf '%s\n' "$cf_action"; fi
  } | lib_write_file "$FAIL2BAN_WEB_JAIL_FILE" 0600 root:root
  if (( LIB_FILE_CHANGED )) && (( ! OPT_DRY_RUN )) && lib_service_active fail2ban; then
    lib_run fail2ban-client reload || lib_warn "fail2ban reload failed (see log)"
  fi
  return 0
}

# =============================================================================
#  WordPress
# =============================================================================
lib_domain_wpcli_ensure() {
  local tmp="" sha=""
  if [[ -x "$WPCLI_PHAR" && -x "$WPCLI_BIN" ]]; then return 0; fi
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would install wp-cli into ${WPCLI_PHAR}"; return 0; fi
  lib_info "Installing wp-cli..."
  mkdir -p "$INSTALL_DIR"
  tmp="$(lib_mktemp -d)"
  curl -fsSL --retry 3 --max-time 120 -o "${tmp}/wp-cli.phar" "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar" \
    && curl -fsSL --retry 3 --max-time 60 -o "${tmp}/wp-cli.phar.sha512" "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar.sha512" \
    || lib_die "wp-cli download failed" "network problem" "retry later"
  sha="$(awk '{print $1}' "${tmp}/wp-cli.phar.sha512")"
  [[ "$(sha512sum "${tmp}/wp-cli.phar" | awk '{print $1}')" == "$sha" ]] || lib_die "wp-cli checksum mismatch" "corrupted download" "retry later"
  install -m 0755 "${tmp}/wp-cli.phar" "$WPCLI_PHAR"
  cat >"$WPCLI_BIN" <<EOF
#!/usr/bin/env bash
# Managed by lompstack - wp-cli launcher (set WP_CLI_PHP to pick a PHP CLI)
exec "\${WP_CLI_PHP:-$(lib_php_cli "$(lib_php_default_version)")}" "${WPCLI_PHAR}" "\$@"
EOF
  chmod 0755 "$WPCLI_BIN"
  lib_ok "wp-cli installed"
}

_wp() {   # run wp-cli as the site user
  runuser -u "$D_USER" -- env HOME="$D_HOME" WP_CLI_PHP="$(lib_php_cli "$D_PHP")" WP_CLI_CACHE_DIR="${D_HOME}/private/.wp-cli/cache" \
    WP_CLI_CONFIG_PATH="${D_HOME}/private/.wp-cli/config.yml" "$WPCLI_BIN" --path="${D_HOME}/public_html" "$@"
}

lib_domain_wp_install() {
  local docroot="${D_HOME}/public_html" url="" scheme="http" host="$D_DOMAIN" title="" admin="" email="" pass="" info=""
  info="$(lib_domain_state_dir "$D_DOMAIN")/wp.info"
  lib_domain_wpcli_ensure
  lib_db_info_load "$D_DOMAIN" || lib_die "WordPress needs a database" "db.info missing" "run: setup.sh db ${D_DOMAIN}"
  (( D_SSL )) && scheme="https"
  (( D_WWW && D_WWW_PRIMARY )) && host="www.${D_DOMAIN}"
  url="${scheme}://${host}"
  title="${DOM_OPT_WP_TITLE:-$D_DOMAIN}"
  admin="${DOM_OPT_WP_ADMIN:-admin}"
  email="${DOM_OPT_WP_EMAIL:-${D_EMAIL:-admin@${D_DOMAIN}}}"
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would download and install WordPress (${DOM_OPT_WP_LOCALE}) at ${url}"; return 0; fi
  # From the command line WordPress cannot tell that LiteSpeed takes rewrite rules, so
  # "wp rewrite --hard" wrote none into .htaccess and every permalink answered 404. wp-cli is
  # told in its own configuration, kept out of the document root; written by the site user.
  runuser -u "$D_USER" -- sh -c 'umask 077 && mkdir -p "$1" && printf "apache_modules:\n  - mod_rewrite\n" >"$1/config.yml"' _ "${D_HOME}/private/.wp-cli" \
    || lib_warn "could not write ${D_HOME}/private/.wp-cli/config.yml; save Settings > Permalinks once in WordPress"
  if [[ -f "${docroot}/wp-config.php" ]]; then
    lib_warn "WordPress already present in ${docroot}; skipping download/install"
  else
    rm -f "${docroot}/index.html"
    lib_run _wp core download --locale="$DOM_OPT_WP_LOCALE" --force || lib_die "WordPress download failed" "network / wp-cli error" "see the log"
    lib_run_secret "wp config create (db ${DBI_NAME})" _wp config create --dbname="$DBI_NAME" --dbuser="$DBI_USER" --dbpass="$DBI_PASS" \
      --dbhost=localhost --dbcharset=utf8mb4 --skip-check \
      --extra-php <<<"define('DISABLE_WP_CRON', true);
define('FS_METHOD', 'direct');" || lib_die "wp config create failed" "database credentials or wp-cli error" "see the log"
    pass="$(lib_random_password 20)"
    lib_run_secret "wp core install (${url})" _wp core install --url="$url" --title="$title" --admin_user="$admin" --admin_password="$pass" \
      --admin_email="$email" --skip-email || lib_die "WordPress installation failed" "wp core install error" "see the log; database reachable?"
    lib_run _wp rewrite structure '/%postname%/' --hard || lib_warn "could not set permalink structure"
    if ! runuser -u "$D_USER" -- timeout 5 grep -qs '^# BEGIN WordPress' "${docroot}/.htaccess"; then
      lib_warn "WordPress wrote no rewrite rules into ${docroot}/.htaccess; permalinks answer 404 until Settings > Permalinks is saved once"
    fi
    lib_run _wp plugin install litespeed-cache --activate || lib_warn "LiteSpeed Cache plugin could not be installed (no network?)"
    lib_run _wp option update timezone_string "$TIMEZONE" || true
    {
      printf '# WordPress admin for %s - created %s\n' "$D_DOMAIN" "$(lib_iso_now)"
      printf 'WP_URL=%s\nWP_ADMIN_USER=%s\nWP_ADMIN_PASS=%s\nWP_ADMIN_EMAIL=%s\nWP_LOCALE=%s\nWP_PATH=%s\n' "$url" "$admin" "$pass" "$email" "$DOM_OPT_WP_LOCALE" "$docroot"
    } >"$info"
    chmod 0600 "$info"
    lib_ok "WordPress installed at ${url} (admin credentials in ${info})"
  fi
  chown -R "${D_USER}:${D_GROUP}" "$docroot"
  find "$docroot" -type d -exec chmod 0755 {} + 2>/dev/null || true
  find "$docroot" -type f -exec chmod 0644 {} + 2>/dev/null || true
  [[ -f "${docroot}/wp-config.php" ]] && chmod 0640 "${docroot}/wp-config.php"
  lib_mkdir "${OLS_CACHE_DIR}/${D_DOMAIN}" 0750 "$(lib_ols_user):$(lib_ols_group)"
  lib_cron_set "wpcron:${D_DOMAIN}" "*/5 * * * * ${D_USER} cd ${docroot} && WP_CLI_PHP=$(lib_php_cli "$D_PHP") ${WPCLI_BIN} --path=${docroot} cron event run --due-now --quiet >/dev/null 2>&1"
  D_WP=1
  lib_domain_state_save
}

# =============================================================================
#  summary / credentials / list / logs
# =============================================================================
lib_domain_summary() {
  local sslline="" hint=""
  sslline="$(lib_ssl_status_line "$D_DOMAIN")"
  # NOT 'sslline="...$( (( x )) && printf ... )"'. A command substitution whose last command
  # is a conditional that turns out false exits 1; a plain assignment adopts that status, and
  # errexit then kills the run. This fired on a real "add" AFTER the site had been created
  # and every step had reported OK - the only casualty was the summary nobody got to read.
  if (( ! D_SSL )); then
    if (( D_SSL_WANTED )); then hint=" (run: setup.sh renew-ssl ${D_DOMAIN})"; fi
    sslline="not active${hint}"
  fi
  printf '\n%s%sSite %s is ready%s\n' "$C_BLD" "$C_GRN" "$D_DOMAIN" "$C_RST"
  lib_print_kv "URL"         "$( (( D_SSL )) && printf 'https' || printf 'http')://${D_DOMAIN}/$( (( D_WWW )) && printf '  (+ www)')"
  lib_print_kv "Mode"        "${D_MODE}${D_PROXY:+ -> $D_PROXY}"
  if lib_app_state_load "$D_DOMAIN"; then
    lib_print_kv "Application" "${D_HOME}/app, run by PM2 ($(lib_app_unit_name "$D_IDENT")): ${APP_RESULT:-prepared}"
    if [[ "$APP_RESULT" != "running" ]]; then
      lib_print_kv "Next"      "put the code into ${D_HOME}/app (chown -R ${D_USER}:${D_GROUP}), then: setup.sh app deploy ${D_DOMAIN}"
    fi
  fi
  lib_print_kv "Document root" "${D_HOME}/public_html"
  lib_print_kv "System user" "${D_USER} (upload with: chown -R ${D_USER}:${D_GROUP})"
  [[ -n "$D_PHP" ]] && lib_print_kv "PHP" "${D_PHP} (memory ${D_MEMORY}, upload ${D_UPLOAD}, workers ${D_PHP_CHILDREN})"
  lib_print_kv "Logs"        "${D_HOME}/logs/access.log, error.log  (setup.sh logs ${D_DOMAIN})"
  lib_print_kv "SSL"         "$sslline"
  # The password is shown here deliberately: this is the moment the operator is looking, and
  # it saves a second command. lib_print_kv writes to stdout only, so nothing here is logged.
  if lib_db_info_load "$D_DOMAIN"; then
    lib_print_kv "Database"    "$DBI_NAME"
    lib_print_kv "DB user"     "$DBI_USER"
    lib_print_kv "DB password" "$DBI_PASS"
    lib_print_kv "DB host"     "localhost (socket ${DB_SOCKET})"
  elif [[ -n "$D_DB_NAME" ]]; then
    lib_print_kv "Database"    "${D_DB_NAME} (setup.sh credentials ${D_DOMAIN})"
  fi
  (( D_WP )) && lib_print_kv "WordPress" "admin credentials: setup.sh credentials ${D_DOMAIN}"
  printf '\n'
}

lib_domain_credentials_main() {
  local target="${1:-}" d=""
  [[ -n "$target" ]] || lib_die "Usage: setup.sh credentials <domain>|--all" "" "setup.sh credentials example.com"
  lib_require_tools
  if [[ "$target" == "--all" ]]; then
    lib_domain_credentials_server
    while read -r d; do [[ -n "$d" ]] && lib_domain_credentials_show "$d"; done < <(lib_domains_list)
    return 0
  fi
  target="${target,,}"
  lib_domain_registered "$target" || lib_die "Site ${target} is not registered" "" "setup.sh list"
  lib_domain_credentials_show "$target"
}

lib_domain_credentials_server() {
  local info="${STATE_DIR}/openlitespeed-admin.info"
  printf '\n%sOpenLiteSpeed WebAdmin%s\n' "$C_BLD" "$C_RST"
  if [[ -s "$info" ]]; then
    lib_system_analyze --no-net
    lib_print_kv "URL"      "$(lib_ols_admin_url)"
    lib_print_kv "User"     "$(awk -F= '$1=="USER"{print $2}' "$info")"
    lib_print_kv "Password" "$(awk -F= '$1=="PASSWORD"{sub(/^[^=]*=/,""); print}' "$info")"
  else
    lib_note "not configured"
  fi
  lib_redis_show
}

lib_domain_credentials_show() {
  local domain="$1" info="" pp="" pt=""
  lib_domain_state_load "$domain" || return 0
  printf '\n%s== %s ==%s\n' "$C_BLD" "$domain" "$C_RST"
  lib_print_kv "Mode / status" "${D_MODE} / ${D_STATUS}"
  lib_print_kv "Home"          "${D_HOME}  (public_html, private, logs, backups)"
  lib_print_kv "System user"   "${D_USER}:${D_GROUP}"
  [[ -n "$D_PHP" ]] && lib_print_kv "PHP" "${D_PHP} (memory ${D_MEMORY}, upload ${D_UPLOAD}, workers ${D_PHP_CHILDREN})"
  [[ -n "$D_PROXY" ]] && lib_print_kv "Proxy target" "$D_PROXY"
  if lib_app_state_load "$domain"; then
    lib_print_kv "Application" "${D_HOME}/app on 127.0.0.1:${APP_PORT}, $(lib_app_unit_name "$D_IDENT"), wanted state: $( (( APP_ENABLED )) && printf 'running' || printf 'stopped') (setup.sh app status ${domain})"
  fi
  while read -r pp pt; do
    if [[ -n "$pp" ]]; then lib_print_kv "Path proxy" "${pp} -> ${pt}"; fi
  done <<<"$D_PATH_PROXIES"
  lib_print_kv "SSL"           "$( (( D_SSL )) && lib_ssl_status_line "$domain" || printf 'not active')"
  lib_db_show "$domain"
  info="$(lib_domain_state_dir "$domain")/wp.info"
  if [[ -s "$info" ]]; then
    printf '%sWordPress%s\n' "$C_BLD" "$C_RST"
    lib_print_kv "URL"      "$(awk -F= '$1=="WP_URL"{print $2}' "$info")/wp-admin/"
    lib_print_kv "Admin"    "$(awk -F= '$1=="WP_ADMIN_USER"{print $2}' "$info")"
    lib_print_kv "Password" "$(awk -F= '$1=="WP_ADMIN_PASS"{sub(/^[^=]*=/,""); print}' "$info")"
    printf '\n'
  fi
  if [[ -n "$(lib_redis_password)" ]]; then lib_print_kv "Redis" "127.0.0.1:6379 (password: setup.sh credentials --all)"; fi
}

lib_domain_list_main() {
  local d="" rows=() json=0 mode="" php="" ssl="" last="" status=""
  [[ "${1:-}" == "--json" ]] && json=1
  (( OPT_JSON )) && json=1
  lib_require_tools
  if (( json )); then
    local files=()
    while read -r d; do [[ -n "$d" ]] && files+=("$(lib_domain_json "$d")"); done < <(lib_domains_list)
    if ((${#files[@]} == 0)); then printf '[]\n'; else jq -s '.' "${files[@]}"; fi
    return 0
  fi
  printf '%s%-28s %-10s %-5s %-24s %-22s %-10s%s\n' "$C_BLD" "DOMAIN" "MODE" "PHP" "SSL" "LAST BACKUP" "STATUS" "$C_RST"
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_domain_state_load "$d" || continue
    ssl="$( (( D_SSL )) && lib_ssl_status_line "$d" || printf -- '-')"
    last="${D_BACKUP_LAST:--}"
    status="$D_STATUS"
    [[ -d "$D_HOME/public_html" ]] || status="${status} (missing dir!)"
    printf '%-28s %-10s %-5s %-24s %-22s %-10s\n' "$d" "$D_MODE" "${D_PHP:--}" "${ssl:0:24}" "${last:0:22}" "$status"
    rows+=("$d")
  done < <(lib_domains_list)
  ((${#rows[@]} == 0)) && printf '(no sites yet - add one with: setup.sh add example.com)\n'
  printf '\n%s%d site(s); files under %s/<domain>/public_html%s\n' "$C_DIM" "${#rows[@]}" "$SITES_ROOT" "$C_RST"
}

lib_domain_logs_main() {
  local domain="${1:-}" which="both" lines=50 a="" files=()
  [[ -n "$domain" ]] || lib_die "Usage: setup.sh logs <domain> [--access|--error] [-n LINES]" "" "setup.sh logs example.com"
  shift
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --access) which="access" ;;
      --error)  which="error" ;;
      -n)       lines="${1:-50}"; shift ;;
      *)        lib_die "Unknown option for logs: ${a}" "" "logs <domain> [--access|--error] [-n LINES]" ;;
    esac
  done
  domain="${domain,,}"
  lib_domain_registered "$domain" || lib_die "Site ${domain} is not registered" "" "setup.sh list"
  local dir=""; dir="$(lib_domain_home "$domain")/logs"
  [[ "$which" != "error" ]]  && files+=("${dir}/access.log")
  [[ "$which" != "access" ]] && files+=("${dir}/error.log")
  for a in "${files[@]}"; do [[ -f "$a" ]] || touch "$a" 2>/dev/null || true; done
  printf '%sFollowing %s (Ctrl-C to stop)%s\n' "$C_DIM" "${files[*]}" "$C_RST"
  # not "exec": that replaced this process and skipped the EXIT trap, which left the per-run
  # temporary directory behind every time a log was followed
  tail -n "$lines" -F "${files[@]}" || true
}

# =============================================================================
#  remove
# =============================================================================
lib_domain_remove_main() {
  local domain="${1:-}" keep_db=0 keep_files=0 keep_ssl=0 a=""
  [[ -n "$domain" ]] || lib_die "Usage: setup.sh remove <domain> [--keep-db] [--keep-files] [--keep-ssl]" "" "setup.sh remove example.com"
  shift
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --keep-db)    keep_db=1 ;;
      --keep-files) keep_files=1 ;;
      --keep-ssl)   keep_ssl=1 ;;
      *)            lib_die "Unknown option for remove: ${a}" "" "remove <domain> [--keep-db] [--keep-files] [--keep-ssl]" ;;
    esac
  done
  domain="${domain,,}"
  lib_require_tools
  lib_domain_registered "$domain" || lib_die "Site ${domain} is not registered" "" "setup.sh list"
  lib_domain_state_load "$domain"
  printf '\n%sThis will remove %s%s\n' "$C_BLD" "$domain" "$C_RST"
  lib_note "vhost + listener maps (archived), $( (( keep_files )) && printf 'files KEPT' || printf "files ${D_HOME} DELETED"), $( (( keep_db )) && printf 'database KEPT' || printf 'database DROPPED'), $( (( keep_ssl )) && printf 'certificate KEPT' || printf 'certificate deleted')"
  lib_note "a safety backup (files + database) is written to ${BACKUP_ROOT}/${domain}/ first"
  if lib_app_state_load "$domain"; then
    local other=""
    other="$(_app_port_claimed_by "$APP_PORT" "$domain" || true)"
    if [[ -n "$other" ]]; then lib_warn "${other} also sends requests to 127.0.0.1:${APP_PORT}; they fail once this application is gone"; fi
    lib_note "its Node.js application and $(lib_app_unit_name "$D_IDENT") are stopped and removed"
    _app_site_lock "$domain"   # not while a deploy of it is still running
  fi
  lib_confirm "Continue?" n || lib_die "Removal cancelled" "" "re-run with --yes to skip the question"
  lib_steps_begin 8
  lib_rollback_clear

  lib_step "Scheduled tasks"
  lib_cron_remove "wpcron:${domain}"
  lib_cron_remove_prefix "job:${domain}:"
  lib_ok "cron entries cleaned"

  lib_step "OpenLiteSpeed configuration"
  lib_ols_vhost_purge "$domain" 1
  lib_ok "vhost removed and archived under ${STATE_DIR}/archive/vhosts/"

  # before the backup, and long before the files: nothing may keep running out of the home
  lib_step "Node.js application"
  lib_app_teardown

  lib_step "Safety backup"
  if [[ -d "$D_HOME" ]]; then
    if lib_backup_domain "$domain" --tag pre-remove --keep 0; then lib_ok "safety backup written"; else lib_warn "safety backup FAILED (continuing because you confirmed the removal)"; fi
  else
    lib_info "home directory missing; nothing to back up"
  fi

  lib_step "Database"
  if (( keep_db )); then lib_info "database kept (--keep-db)"; else lib_db_drop_for_domain "$domain"; fi

  lib_step "Certificate"
  if (( keep_ssl )); then lib_info "certificate kept (--keep-ssl)"; else lib_ssl_delete "$domain"; lib_ok "certificate removed"; fi

  lib_step "Files and system user"
  if (( keep_files )); then
    lib_info "files and user kept (--keep-files)"
  else
    lib_rm "$D_HOME"
    lib_rm "${OLS_CACHE_DIR}/${domain}"
    if (( ! OPT_DRY_RUN )) && id -u "$D_USER" >/dev/null 2>&1; then
      pkill -u "$D_USER" >/dev/null 2>&1 || true
      lib_run userdel "$D_USER" || lib_warn "userdel ${D_USER} failed"
      getent group "$D_GROUP" >/dev/null 2>&1 && { lib_run groupdel "$D_GROUP" || true; }
    fi
    lib_ok "files and user removed"
  fi

  lib_step "State and housekeeping"
  if (( ! OPT_DRY_RUN )); then
    mkdir -p "${STATE_DIR}/archive/domains" && chmod 0700 "${STATE_DIR}/archive/domains"
    mv "$(lib_domain_state_dir "$domain")" "${STATE_DIR}/archive/domains/${domain}.$(lib_ts)" 2>/dev/null || rm -rf "$(lib_domain_state_dir "$domain")"
  fi
  lib_domain_logrotate_regen
  lib_domain_fail2ban_regen
  lib_manifest_set '.updated_at' "$(lib_iso_now)"
  printf '\n%s%sRemoved %s%s  (state archived in %s/archive/domains/, backup in %s/%s/)\n\n' "$C_BLD" "$C_GRN" "$domain" "$C_RST" "$STATE_DIR" "$BACKUP_ROOT" "$domain"
}
