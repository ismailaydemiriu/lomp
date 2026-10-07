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
# hardening (lib/harden.sh): "blocked", "allowed", or empty for a site nobody decided about yet
D_SEC_EXEC="" D_SEC_UPLOAD=""
# ---- add-only options ---------------------------------------------------------
# Every new site gets a database and its own MariaDB user by default; --no-db opts out.
DOM_OPT_WP_TITLE="" DOM_OPT_WP_ADMIN="admin" DOM_OPT_WP_EMAIL="" DOM_OPT_WP_LOCALE="en_US" DOM_OPT_WITH_DB=1
DOM_OPT_MAIL=0 DOM_OPT_MAILBOX="" DOM_OPT_MAIL_QUOTA=""
DOMAIN_CREATED_HOME=0
DOMAIN_CREATED_USER=0
DOMAIN_LOGS_MOVED=""    # sites whose logs lib_domain_logs_repair moved out of their homes
DOMAIN_F2B_FILTERS_CHANGED=0   # set by lib_domain_fail2ban_filters_write
DOMAIN_ISOLATED=""      # sites whose homes lib_domain_isolation_repair closed to other accounts
SITE_HOME_MODE="0710"   # /home/<domain>: the site's user and group, and nobody else
# the sentence in the page a new site's document root starts with (lib_domain_dirs_create);
# "wordpress" tells that page from somebody's own index.html by it
DOMAIN_PLACEHOLDER_MARK="provisioned by server-setup and is waiting for content"

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
  D_SEC_EXEC="" D_SEC_UPLOAD=""
}

_d_bool() { [[ "$1" == "true" ]] && printf '1' || printf '0'; }
_d_json_bool() { (( ${1:-0} )) && printf 'true' || printf 'false'; }

# lib_domain_state_load domain  (returns 1 when not registered)
lib_domain_state_load() { lib_domain_state_load_file "$(lib_domain_json "$1")" "$1"; }

# The same, out of a named file rather than the site's own. A dry run writes no domain.json,
# so a restore that would recreate a site has to read the copy inside the archive: asking for
# the file it did not write finds nothing, and the reset below has already happened by then.
lib_domain_state_load_file() {   # file domain  (returns 1 when the file is not there)
  local f="$1" domain="${2:-}"
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
  D_SEC_EXEC="$(lib_json_get "$f" '.security.php_exec')"
  D_SEC_UPLOAD="$(lib_json_get "$f" '.security.upload_php')"
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
    --arg sexec "$D_SEC_EXEC" --arg supl "$D_SEC_UPLOAD" \
    '{domain:$domain, ident:$ident, user:$user, group:$group, home:$home, mode:$mode,
      php:{version:$php, children:$children, memory_limit:$mem, upload_max:$up},
      proxy:{target:$proxy, static_paths:$spaths, websocket_path:$ws},
      www:$www, www_primary:$wwwp,
      ssl:{enabled:$ssl, wanted:$sslw, wildcard:$wild, hsts_preload:$hsts},
      cloudflare:$cf, email:$email, created_at:$created, status:$status,
      db:(if $dbn == "" then null else {name:$dbn, user:$dbu} end),
      wordpress:$wp, backup:{last:$blast}, updated_at:$ts, script_version:$ver}
     | if $sexec != "" then .security.php_exec = $sexec else . end
     | if $supl != "" then .security.upload_php = $supl else . end
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
  # a usage text is no single message lib/lang.sh could look up: its Turkish is here
  if [[ "${LIB_LANG:-en}" == "tr" ]]; then
    cat <<'EOF'
Kullanım: setup.sh add <domain> [seçenekler]
  --email a@b.c        İletişim e-postası (Let's Encrypt, vhost adminEmails)
  --no-ssl             Sertifika istenmez (sonradan renew-ssl ile eklenir)
  --www                www.<domain> da sunulur; www -> apex yönlendirilir
  --www-primary        --www ile: bunun yerine apex -> www yönlendirilir
  --php 8.3            Bu sitenin PHP sürümü (gerektiğinde kurulur)
  --php-children N     Bu sitenin LSAPI worker sayısı (varsayılan profilden gelir)
  --memory 256M        PHP memory_limit           --upload 64M  upload_max_filesize
  --proxy 127.0.0.1:3000   Kendi çalıştırdığınız bir uygulamaya ters proxy (Node/Python/...)
  --node               Node.js sitesi: uygulamayı PM2, sitenin kullanıcısı olarak çalıştırır
                       (bkz. setup.sh app help)
  --port N             --node ile: uygulamanın portu (varsayılan: 3000'den itibaren ilk boş)
  --start "npm start"  --node ile: kabuk olmadan çalıştırılan başlatma komutu  (ya da --script dist/main.js)
  --git URL            --node ile: hemen bu depodan dağıtım yapılır (--branch B)
  --static-paths "/static/,/assets/"   Proxy modunda OLS'nin sunduğu yollar
  --ws-path PATH       Artık gerekmez: WebSocket yükseltmeleri her yolda proxy'lenir
  --static             Yalnızca statik site (PHP yok)
  --wordpress          WordPress kurulur (veritabanı kendiliğinden oluşturulur)
  --no-db              Veritabanı oluşturulmaz (varsayılan olarak bir tane oluşturulur)
  --with-db            Veritabanı oluşturulur - varsayılan budur, eski betikler için korunur
  --cloudflare         Cloudflare gerçek IP modu açılır (tüm sunucu için)
  --wildcard           *.<domain> için de sertifika istenir (DNS-01, --cf-api-token gerekir)
  --staging            Let's Encrypt staging CA kullanılır
  --hsts-preload       HSTS başlığına "preload" eklenir (geri alınamaz)
  --wp-title "Site"  --wp-admin admin  --wp-email a@b.c  --wp-locale en_US
EOF
    return 0
  fi
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
  # a new site starts hardened; "lomp harden <domain> --allow-exec" relaxes one that needs it
  D_SEC_EXEC="blocked"; D_SEC_UPLOAD="blocked"
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
      --mail)         DOM_OPT_MAIL=1 ;;
      --mailbox)      DOM_OPT_MAIL=1; DOM_OPT_MAILBOX="${1:-}"; shift ;;
      --mail-quota)   DOM_OPT_MAIL=1; DOM_OPT_MAIL_QUOTA="${1:-}"; shift ;;
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
  # A server installed for mail alone carries OpenLiteSpeed and PHP for the webmail, tuned for
  # that and nothing more. A site here would be one nobody planned for; a domain gets mail.
  if lib_server_mail_only; then
    lib_die "This server is set up for mail only, so ${D_DOMAIN} cannot be added as a site" \
      "it was installed with --mail-only: a domain gets its mail here and its site somewhere else" \
      "lomp mail domain add ${D_DOMAIN} --mailbox info   (to host sites here as well: lomp install --role web)"
  fi
  local domain="$D_DOMAIN" total=6 http_expect="200|301|302" rc="" why=""
  lib_domain_registered "$domain" && lib_die "Site ${domain} already exists" "registered in $(lib_domain_state_dir "$domain")" "use 'setup.sh remove ${domain}' first, or 'renew-ssl' / 'db' to change it"
  # the name is taken: its virtual host and its certificate are the redirect's
  if lib_redirect_exists "$domain"; then
    lib_die "${domain} only redirects to $(lib_json_get "$(lib_redirect_file "$domain")" '.target') on this server" \
      "a site of that name would take the redirect's place" "setup.sh redirect del ${domain}   (then add the site)"
  fi
  lib_ols_is_installed || lib_die "OpenLiteSpeed is not installed" "run install first" "sudo ./setup.sh install"
  (( D_SSL_WANTED )) && total=$((total + 1))
  (( DOM_OPT_WITH_DB )) && total=$((total + 1))
  [[ "$D_MODE" == "wordpress" ]] && total=$((total + 1))
  (( APP_OPT_NODE )) && total=$((total + 1))
  (( DOM_OPT_MAIL )) && total=$((total + 1))
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
  # The name its mail would go by, should it ever get some. Two sites never share an
  # identifier, but a mail domain that was here first may have this one's (lib_mail_ident).
  if lib_mail_installed; then lib_mail_ident_claim "$domain" || lib_warn "${MAIL_LAST_ERROR}"; fi
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
  lib_ols_smoke_test "$domain" "$http_expect" || lib_die "Smoke test failed for ${domain}" "${OLS_TEST_OUTPUT}" "check ${LSWS_HOME}/logs/error.log and $(lib_domain_log_dir "$D_DOMAIN")/error.log"
  if [[ "$D_MODE" == "php" || "$D_MODE" == "wordpress" ]]; then
    lib_domain_php_probe || lib_die "PHP is not executing for ${domain}" "${OLS_TEST_OUTPUT}" "check $(lib_domain_log_dir "$D_DOMAIN")/error.log and the LSAPI processor (${D_IDENT})"
  fi
  lib_ok "Site answers on http://${domain}/"
  if [[ "$D_MODE" == "proxy" ]]; then
    lib_note "Until your application listens on ${D_PROXY}, the site answers 502/503. That is expected."
  fi

  # ---- 5 SSL ---------------------------------------------------------------
  if (( D_SSL_WANTED )); then
    lib_step "SSL certificate (Let's Encrypt)"
    lib_domain_add_ssl
    # A WordPress that is in the document root already - the files were kept by "remove", or
    # put there before the site was added - may call itself http://. Here and not in
    # lib_domain_add_ssl: rename gets its certificate through that too, before the addresses
    # in the database say the new name. In a subshell: nothing in it may end the add.
    if (( D_SSL )); then ( lib_domain_wp_https ) || true; fi
  fi

  # ---- 6 database ----------------------------------------------------------
  if (( DOM_OPT_WITH_DB )); then
    lib_step "MariaDB database"
    lib_db_create_for_domain "$domain"
    # it writes .db straight into domain.json (lib_json_set), so the file is read back to pick
    # up D_DB_NAME/D_DB_USER for the summary. NOT in a dry run: nothing was written, the load
    # fails on the missing file - and lib_domain_state_load resets the state BEFORE it looks at
    # the file, so every D_* this run had built up (domain, mode, home, user) came back empty.
    # The site was then created correctly and the closing summary described a nameless site.
    if (( ! OPT_DRY_RUN )); then lib_domain_state_load "$domain" >/dev/null 2>&1 || true; fi
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

  # ---- 10 mail -------------------------------------------------------------
  # after lib_rollback_clear on purpose: the site is live by now, and mail that will not come
  # up must leave it that way. Whatever goes wrong here is a warning and a command to run.
  if (( DOM_OPT_MAIL )); then
    lib_step "Mail for ${domain}"
    local -a _mail_args=("$domain" --yes)
    # --with-mail is how a mail server gets installed, deliberately and with its own name.
    # "add --mail" on a server that has none must not do it as a side effect of --yes.
    if ! lib_mail_installed; then
      lib_warn "This server does not run mail yet, so ${domain} did not get any"
      lib_note "Install it once, with the name it will send as: lomp install --with-mail --mail-hostname mail.example.com"
      DOM_OPT_MAIL=0
    fi
    [[ -n "$DOM_OPT_MAILBOX" ]] && _mail_args+=(--mailbox "$DOM_OPT_MAILBOX")
    [[ -n "$DOM_OPT_MAIL_QUOTA" ]] && _mail_args+=(--quota "$DOM_OPT_MAIL_QUOTA")
    if (( DOM_OPT_MAIL )) && ! ( set -Eeuo pipefail; lib_mail_enable_main "${_mail_args[@]}" ); then
      lib_warn "The site is up, but its mail is not: run 'lomp mail enable ${domain}' once the cause is fixed"
    fi
  fi

  # ---- 11 summary ----------------------------------------------------------
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
    else lib_warn "HTTPS smoke test failed (${OLS_TEST_OUTPUT}); check $(lib_domain_log_dir "$D_DOMAIN")/error.log"; fi
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
      lib_rollback_push "lib_domain_user_drop '${D_USER}' '${D_GROUP}'"
    fi
  fi
  return 0
}

# Take back the account lib_domain_user_ensure made, when "add" fails. What still runs as the
# user is stopped first, as "remove" does: userdel refuses a user something runs as, and the
# account left behind stands in the way of the next "add" of that name. userdel takes the
# user's own group along where the system is set up that way (USERGROUPS_ENAB), so a group
# that is gone already is no failure.
lib_domain_user_drop() {   # user group
  local u="$1" g="$2"
  if id -u "$u" >/dev/null 2>&1; then
    _domain_rename_quiet_user "$u" || true
    userdel "$u" || return 1
  fi
  if getent group "$g" >/dev/null 2>&1; then groupdel "$g" || return 1; fi
  return 0
}

# Is the account a site is about to be given somebody else's? It exists, and its home is not
# the one this site will have: another site whose name comes out as the same identifier
# (a-b.example and a.b.example), or an account that has nothing to do with lomp. It is what
# lib_domain_user_ensure dies on, asked on its own by a caller that has to know before it
# writes anything.
lib_domain_user_taken() {   # the site in D_USER / D_HOME
  id -u "${D_USER:-}" >/dev/null 2>&1 || return 1
  [[ "$(getent passwd "$D_USER" | cut -d: -f6)" != "$D_HOME" ]]
}

# The same about a record that exists: is the account it names another site's? Not if the
# account lives where a site of this name lives. Otherwise yes - unless the record itself
# gives that home and no other site on record has the user, which is a site whose home was
# simply put somewhere else. The last test is what catches a record copied out of the archive
# of the very site whose account it is: it says the same user and the same home as that
# site's own record does.
lib_domain_account_foreign() {   # domain  (its D_* are loaded)
  local h="" x=""
  id -u "${D_USER:-}" >/dev/null 2>&1 || return 1
  h="$(getent passwd "$D_USER" | cut -d: -f6)"
  [[ "$h" != "$(lib_domain_home "$1")" ]] || return 1
  [[ "$h" == "$D_HOME" ]] || return 0
  while read -r x; do
    [[ -n "$x" && "$x" != "$1" ]] || continue
    if [[ "$(lib_json_get "$(lib_domain_json "$x")" '.user')" == "$D_USER" ]]; then return 0; fi
  done < <(lib_domains_list)
  return 1
}

# Run a command as the site user, from "/". Writes and mode changes inside a site's home belong
# here rather than in root: every name below /home/<domain> is under that user's control, and
# root following one of its links turns "chmod a WordPress file" into "chmod /etc/shadow". As
# the user, a planted link reaches nothing the user could not already touch. ("/" because
# runuser keeps root's working directory, and find run by a user who cannot read it does nothing.)
lib_domain_as_user() {
  runuser -u "$D_USER" -- env -C / "$@"
}

lib_domain_dirs_create() {
  local ols_user=""; ols_user="$(lib_ols_user)"
  local new_home=0
  if [[ ! -d "$D_HOME" ]]; then
    DOMAIN_CREATED_HOME=1; new_home=1
    (( OPT_DRY_RUN )) || lib_rollback_push "rm -rf '${D_HOME}'"
  fi
  # closed to every other account: the other sites' users are "others" here, and a home they
  # could pass through let one site's PHP read every world-readable file of the next - its
  # database password included. OpenLiteSpeed's user gets in by the ACL below.
  lib_mkdir "$D_HOME" "$SITE_HOME_MODE" "${D_USER}:${D_GROUP}"
  lib_mkdir "${D_HOME}/public_html" 0755 "${D_USER}:${D_GROUP}"
  lib_mkdir "${D_HOME}/private" 0700 "${D_USER}:${D_GROUP}"
  lib_mkdir "${D_HOME}/private/sessions" 0700 "${D_USER}:${D_GROUP}"
  lib_mkdir "${D_HOME}/private/tmp" 0700 "${D_USER}:${D_GROUP}"
  lib_mkdir "${D_HOME}/backups" 0700 "${D_USER}:${D_GROUP}"
  # the logs live outside the home, and logs/ there leads to them; the site is not served yet,
  # so an older release's logs/ left in a kept home can be emptied right away. A failed run
  # takes the log directory back only with a home it made: in a kept home it may hold that
  # history, and nothing else has a copy of it any more.
  if (( new_home && ! OPT_DRY_RUN )) && [[ ! -e "$(lib_domain_log_dir "$D_DOMAIN")" ]]; then
    lib_rollback_push "rm -rf '$(lib_domain_log_dir "$D_DOMAIN")'"
  fi
  lib_domain_logs_dir_ensure
  lib_domain_logs_move_old
  lib_domain_logs_link
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
  # OLS worker (nobody) must be able to traverse into public_html. Fine as root: the home sits
  # directly in root's SITES_ROOT, so no part of this path is the site user's to re-point.
  (( OPT_DRY_RUN )) || setfacl -m "u:${ols_user}:x" "$D_HOME" 2>/dev/null || true
  if [[ ! -e "${D_HOME}/public_html/index.html" && ! -e "${D_HOME}/public_html/index.php" ]] && [[ "$D_MODE" != "proxy" ]]; then
    if (( ! OPT_DRY_RUN )); then
      # Written by the site user. Root's "cat >" and chown followed an index.html link the user
      # left in its own docroot - to /etc/ld.so.preload, say - and handed that file over.
      lib_domain_as_user tee "${D_HOME}/public_html/index.html" >/dev/null <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${D_DOMAIN}</title>
<style>body{font-family:system-ui,sans-serif;margin:10% auto;max-width:40em;color:#333}</style></head>
<body><h1>${D_DOMAIN}</h1><p>This site was ${DOMAIN_PLACEHOLDER_MARK}.</p>
<p>Upload files to <code>${D_HOME}/public_html/</code>.</p></body></html>
EOF
    fi
  fi
  return 0
}

# May accounts other than the site's own pass into this home? (true for a home that is missing
# or not a directory of its own: there is nothing to say about it here)
lib_domain_home_closed() {   # home
  local mode=""
  [[ -d "$1" && ! -L "$1" ]] || return 0
  mode="$(stat -c %a "$1" 2>/dev/null)" || return 0
  [[ "${mode: -1}" == "0" ]]
}

# "update" closes the homes an older release made 0711, the way lib_domain_dirs_create makes
# them now. Only the home's own mode changes - nothing below it, and no owner - and the ACL
# that lets OpenLiteSpeed's user through is set again, since without it a closed home serves
# nothing. As root on a name in SITES_ROOT, which is root's: not a path the site user can
# re-point. DOMAIN_ISOLATED names the sites whose homes were open.
lib_domain_isolation_repair() {
  local d="" ols_user="" closed=()
  DOMAIN_ISOLATED=""
  ols_user="$(lib_ols_user)"
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_domain_state_load "$d" || continue
    lib_domain_home_closed "$D_HOME" && continue
    closed+=("$d")
    (( OPT_DRY_RUN )) && continue
    # the ACL first: between the two the home is as open as it was, never shut to the server
    setfacl -m "u:${ols_user}:x" "$D_HOME" 2>/dev/null \
      || { lib_warn "setfacl could not let OpenLiteSpeed into ${D_HOME}; the home was left open to other accounts"; unset 'closed[-1]'; continue; }
    chmod "$SITE_HOME_MODE" "$D_HOME" \
      || { lib_warn "could not close ${D_HOME} to other accounts"; unset 'closed[-1]'; }
  done < <(lib_domains_list)
  DOMAIN_ISOLATED="${closed[*]-}"
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
  # the ports a site may reach on this machine follow its proxy targets
  lib_sitefw_regen
  # and the names that only redirect to this one follow its address (https or not, www or not)
  lib_redirect_sync_target "$D_DOMAIN"
}

# The name the site itself answers under. With --www-primary the bare name answers every
# request with a redirect to www.<domain>, whatever the path.
lib_domain_primary_host() {
  if (( D_WWW && D_WWW_PRIMARY )); then printf 'www.%s' "$D_DOMAIN"; else printf '%s' "$D_DOMAIN"; fi
}

# Drop a tiny PHP probe into the docroot, fetch it, remove it. Asked for under the name that
# serves pages: from the redirecting one comes OpenLiteSpeed's 301 page, not what PHP printed.
lib_domain_php_probe() {
  (( OPT_DRY_RUN )) && return 0
  local name="" f="" body="" i="" host=""
  host="$(lib_domain_primary_host)"
  name="ss-probe-$(lib_random_hex 6).php"
  f="${D_HOME}/public_html/${name}"
  # as the site user: root's chown of a file in the user's docroot follows a link swapped in for it
  printf '<?php echo "server-setup-php-ok:" . PHP_VERSION;\n' | lib_domain_as_user tee "$f" >/dev/null
  for (( i = 0; i < 5; i++ )); do
    body="$(curl -s --max-time 15 -H "Host: ${host}" "http://127.0.0.1/${name}" 2>/dev/null || true)"
    [[ "$body" == server-setup-php-ok:* ]] && break
    sleep 2
  done
  lib_domain_as_user rm -f -- "$f"
  if [[ "$body" == server-setup-php-ok:* ]]; then lib_debug "PHP probe OK (${body#*:})"; return 0; fi
  OLS_TEST_OUTPUT="PHP probe returned: ${body:0:120}"
  return 1
}

# =============================================================================
#  Site logs
# =============================================================================
# OpenLiteSpeed's main process opens a virtual host's logs as root - it creates them, and hands
# them to its server user, whose workers write them. So no directory on the way to them may be
# one the site user controls, and /home/<domain> is the site user's: a logs/ kept there could be
# renamed and replaced by a link, and root would then create and hand over files wherever that
# pointed. The logs live in SITES_LOG_ROOT/<domain>, which only root may change, with the same
# rights logs/ had: the site's group reads them, nobody may enter to write them.
# /home/<domain>/logs is a link there, for people to read them by. Nothing run as root goes
# through it - OpenLiteSpeed, logrotate, fail2ban and "lomp logs" use the directory itself - so
# the site user replacing it changes nothing but where its own shortcut leads.
# lib_ols_vhconf_write calls this too: whatever renders a vhost has its log directory in place.
lib_domain_logs_dir_ensure() {
  local dir=""; dir="$(lib_domain_log_dir "$D_DOMAIN")"
  lib_mkdir "$SITES_LOG_ROOT" 0711 root:root
  lib_mkdir "$dir" 0750 "root:${D_GROUP}"
  lib_ols_logdir_grant "$dir" \
    || lib_warn "setfacl could not let OpenLiteSpeed into ${dir}; the site's logs will stay empty"
}

# Does OpenLiteSpeed still write this site's logs into its home? A vhost an older release
# rendered does, until update moves them.
lib_domain_logs_in_home() {   # domain
  grep -qF '$VH_ROOT/logs/' "${LSWS_VHOSTS_DIR}/${1}/vhconf.conf" 2>/dev/null
}

# Where OpenLiteSpeed writes a site's logs right now, for what reads them: logrotate, fail2ban,
# "lomp logs". Between a self-update and the update that moves them that is still logs/ in the
# home of a site an older release set up; leaving it out would stop rotating those logs and
# drop the site from the fail2ban jails until then.
lib_domain_log_dir_in_use() {   # domain
  if lib_domain_logs_in_home "$1"; then printf '%s/logs' "$(lib_domain_home "$1")"
  else lib_domain_log_dir "$1"; fi
}

# /home/<domain>/logs -> the log directory. With -T, ln never takes the name for a directory to
# put the link into, and replacing a link it neither follows it nor anything else, so what root
# makes here is a link in the home and nothing else. A directory or a file there is left alone:
# an older release's logs/ is emptied and removed by lib_domain_logs_move_old first, and
# anything else there is the site user's own.
lib_domain_logs_link() {
  local link="${D_HOME}/logs" dir=""
  dir="$(lib_domain_log_dir "$D_DOMAIN")"
  if [[ -L "$link" && "$(readlink -- "$link")" == "$dir" ]]; then return 0; fi
  # a dry run moved nothing out of an older release's logs/, which a real run would have
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would link ${link} to ${dir}"; return 0; fi
  if [[ -e "$link" && ! -L "$link" ]]; then
    lib_warn "${link} is not a link to ${dir}, where the logs of ${D_DOMAIN} are; it was left as it is"
    return 0
  fi
  ln -sfnT -- "$dir" "$link" || lib_warn "could not link ${link} to ${dir}, where the logs of ${D_DOMAIN} are"
}

# An older release kept the logs in /home/<domain>/logs itself, a directory of root's. Once
# OpenLiteSpeed no longer writes there - add and restore run this for a site that is not served
# yet, update after the reload that moved every site's logs - what it holds goes to the log
# directory, and the empty directory goes. The site user can rename that directory or put
# something else in its place, so _domain_logs_move_old enters it once and checks it from the
# inside before it reads a name there; what is not root's directory is left alone.
lib_domain_logs_move_old() {
  local old="${D_HOME}/logs" dir="" why="" rc=0
  dir="$(lib_domain_log_dir "$D_DOMAIN")"
  [[ -d "$old" && ! -L "$old" ]] || return 0
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would move the logs in ${old} to ${dir}"; return 0; fi
  why="$(_domain_logs_move_old "$D_HOME" "$dir" "$D_GROUP" 2>&1)" || rc=$?
  if (( rc == 3 )); then
    lib_warn "${old} is not the log directory an older release made (${why}); it was left as it is"
  elif (( rc != 0 )); then
    lib_warn "the logs in ${old} could not all be moved to ${dir}${why:+ (${why})}; the rest stays there"
  elif rmdir -- "$old" 2>/dev/null; then
    lib_log_write INFO "moved the logs of ${D_DOMAIN} from ${old} to ${dir}"
  else
    lib_warn "${old} could not be removed after its logs were moved to ${dir}"
  fi
  return 0
}

# Run in a subshell: it changes directory. Enters <home>/logs the way _lib_mkdir_walk enters a
# component - not through a link, confirmed with the kernel's getcwd - and wants it root's and
# closed to everybody else's writes, so that nobody but root can have put a name in it. Every
# file is written to a temporary name in the log directory first and only renamed into place
# once complete, without replacing anything, and removed here after that: a copy cut short -
# the disk full, the log directory on another filesystem - never takes a real name. Rotated
# copies keep their names. The two live logs, which nothing writes any more, go at the end of
# the newest rotated copy (as a gzip member of their own when that one is compressed): the lines
# stay in order, and logrotate keeps them as long as that copy. With no copy at all they become
# one, dated yesterday - a name logrotate, which dates its copies with the day it runs, never
# makes. Empty ones are dropped. Exit 3 = not that directory.
_domain_logs_move_old() (   # home dir group
  LIB_ERR_HANDLING=1   # an unexpected failure exits quietly; the caller reports it
  local home="$1" dir="$2" group="$3" here="" f="" c="" day="" best=0 newest="" mode="" tmp="" left=0
  shopt -s nullglob dotglob
  cd -P -- "$home" || exit 1
  here="$(env pwd -P)" || exit 1
  if [[ -L logs ]]; then printf 'a symbolic link'; exit 3; fi
  cd -P -- logs || exit 1
  [[ "$(env pwd -P)" == "${here%/}/logs" ]] || { printf 'it moved while it was entered'; exit 3; }
  [[ "$(stat -c %u .)" == 0 ]] || { printf 'it does not belong to root'; exit 3; }
  mode="$(stat -c %a .)"
  (( (8#$mode & 8#022) == 0 )) || { printf 'others may write to it (mode %s)' "$mode"; exit 3; }
  for f in *; do
    [[ "$f" == access.log || "$f" == error.log ]] && continue
    tmp="${dir}/.${f}.lomp-tmp"
    if [[ -f "$f" && ! -L "$f" ]] && cp -p -- "$f" "$tmp" && mv -n -- "$tmp" "${dir}/${f}" && [[ ! -e "$tmp" ]]; then
      rm -f -- "$f"; continue
    fi
    rm -f -- "$tmp"; left=1
  done
  for f in access.log error.log; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    if [[ ! -s "$f" ]]; then rm -f -- "$f"; continue; fi
    newest=""; best=0; tmp="${dir}/.${f}.lomp-tmp"
    for c in "${dir}/${f}"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9] "${dir}/${f}"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].gz; do
      [[ -f "$c" && ! -L "$c" ]] || continue
      day="${c##*/"${f}"-}"; day="${day%.gz}"
      if (( 10#$day > best )); then best=$(( 10#$day )); newest="$c"; fi
    done
    if [[ "$newest" == *.gz ]]; then
      { cat -- "$newest" && gzip -c -- "$f"; } >"$tmp" && chmod --reference="$newest" -- "$tmp" \
        && chown --reference="$newest" -- "$tmp" && mv -f -- "$tmp" "$newest" && rm -f -- "$f" && continue
    elif [[ -n "$newest" ]]; then
      { cat -- "$newest" && cat -- "$f"; } >"$tmp" && chmod --reference="$newest" -- "$tmp" \
        && chown --reference="$newest" -- "$tmp" && mv -f -- "$tmp" "$newest" && rm -f -- "$f" && continue
    else
      c="${dir}/${f}-$(date -d '-1 day' +%Y%m%d).gz"
      gzip -c -- "$f" >"$tmp" && chmod 0640 -- "$tmp" && chown "root:${group}" -- "$tmp" \
        && mv -n -- "$tmp" "$c" && [[ ! -e "$tmp" ]] && rm -f -- "$f" && continue
    fi
    rm -f -- "$tmp"; left=1
  done
  (( ! left )) || { printf 'a name that is already in %s, something other than a file, or a copy that failed' "$dir"; exit 1; }
  exit 0
)

# "update" gives every site what a new one gets from lib_domain_dirs_create and the vhost
# template: its logs in SITES_LOG_ROOT, with a link in the home, and a vhost rendered again -
# which writes them there, and puts the error log at NOTICE. The vhosts go first, in one change
# set: one configuration test, one graceful reload, the snapshot back if either fails. What
# reads the logs - logrotate, the fail2ban filters and jails - follows them right away, and only
# then is anything taken out of the old place. The webmail's log directory is put right too.
# DOMAIN_LOGS_MOVED names the sites whose logs were still written in their homes.
lib_domain_logs_repair() {
  local d="" moved=()
  DOMAIN_LOGS_MOVED=""
  lib_ols_is_installed || return 0
  [[ -n "$(lib_domains_list)" ]] || return 0
  lib_system_profile
  lib_ols_change_begin
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_domain_state_load "$d" || continue
    if lib_domain_logs_in_home "$d"; then moved+=("$d"); fi
    lib_ols_vhconf_write "$d"   # which makes the log directory as well
    # a log directory made again, or one somebody emptied: OpenLiteSpeed writes it once reloaded
    if (( ! OPT_DRY_RUN )) && [[ ! -e "$(lib_domain_log_dir "$d")/access.log" ]]; then OLS_PENDING_RELOAD=1; fi
  done < <(lib_domains_list)
  # a dry run has nothing to test or reload when no vhost would change
  if (( OLS_PENDING_RELOAD || ! OPT_DRY_RUN )); then lib_ols_change_commit "site logs"; fi
  lib_domain_logrotate_regen
  # an older release's fail2ban filters matched none of the access log's lines
  lib_domain_fail2ban_regen
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_domain_state_load "$d" || continue
    lib_domain_logs_move_old
    lib_domain_logs_link
  done < <(lib_domains_list)
  if lib_webmail_installed; then lib_webmail_dirs_ensure; fi
  DOMAIN_LOGS_MOVED="${moved[*]-}"
  return 0
}

# =============================================================================
#  logrotate / fail2ban regeneration (state -> config)
# =============================================================================

lib_domain_logrotate_regen() {
  local d="" line="" u="" g="" h="" paths=() apps=()
  while read -r d; do [[ -n "$d" ]] && paths+=("$(lib_domain_log_dir_in_use "$d")/*.log"); done < <(lib_domains_list)
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

# fail2ban cuts the date out of a line before it applies a failregex, so of
# "[28/Sep/2026:19:56:50 +0300]" a filter sees "[]". Both filters used to want a character
# between those brackets and matched no line at all: nobody was ever banned. "*" takes the
# empty pair. DOMAIN_F2B_FILTERS_CHANGED says whether either file was rewritten.
lib_domain_fail2ban_filters_write() {
  local changed=0
  lib_mkdir "$FAIL2BAN_FILTER_DIR" 0755 root:root
  cat <<'EOF' | lib_write_file "${FAIL2BAN_FILTER_DIR}/server-setup-wp-login.conf" 0644 root:root
# Managed by lompstack - WordPress login / xmlrpc brute force (OpenLiteSpeed combined access log)
[Definition]
failregex = ^<HOST> \S+ \S+ \[[^\]]*\] "POST /+(?:wp-login\.php|xmlrpc\.php)[^"]*" (?:200|403)
ignoreregex =
EOF
  changed=$(( changed + LIB_FILE_CHANGED ))
  cat <<'EOF' | lib_write_file "${FAIL2BAN_FILTER_DIR}/server-setup-web-probe.conf" 0644 root:root
# Managed by lompstack - vulnerability scanners probing well-known paths
[Definition]
failregex = ^<HOST> \S+ \S+ \[[^\]]*\] "(?:GET|POST|HEAD) /+(?:\.env|\.git|\.aws|\.ssh|wp-config\.php|phpmyadmin|pma|adminer|cgi-bin|vendor/phpunit|wp-content/plugins/[^/]+/[^"]*\.php)[^"]*" (?:403|404)
ignoreregex =
EOF
  changed=$(( changed + LIB_FILE_CHANGED ))
  DOMAIN_F2B_FILTERS_CHANGED=$(( changed > 0 ))
  return 0
}

lib_domain_fail2ban_regen() {
  local d="" f="" logs=() enabled=true
  lib_pkg_installed fail2ban || return 0
  # The access logs OpenLiteSpeed writes (lib_domain_log_dir_in_use), and only those that are
  # there: fail2ban will not load a jail none of whose files it finds, and a jail it cannot load
  # takes the whole reload down, sshd's jail with it. OpenLiteSpeed makes a site's access.log
  # when it loads the vhost, so every caller that just added or moved a site finds it.
  while read -r d; do
    [[ -n "$d" ]] || continue
    f="$(lib_domain_log_dir_in_use "$d")/access.log"
    if [[ -e "$f" ]]; then logs+=("$f"); fi
  done < <(lib_domains_list)
  ((${#logs[@]} == 0)) && { enabled=false; logs=("/dev/null"); }
  lib_domain_fail2ban_filters_write
  local filters_changed="$DOMAIN_F2B_FILTERS_CHANGED"
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
  # fail2ban reads a changed filter again only on a reload, as it does a changed jail
  if (( LIB_FILE_CHANGED || filters_changed )) && (( ! OPT_DRY_RUN )) && lib_service_active fail2ban; then
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
  local docroot="${D_HOME}/public_html" url="" scheme="http" host="" title="" admin="" email="" pass="" info=""
  info="$(lib_domain_state_dir "$D_DOMAIN")/wp.info"
  lib_domain_wpcli_ensure
  lib_db_info_load "$D_DOMAIN" || lib_die "WordPress needs a database" "db.info missing" "run: setup.sh db ${D_DOMAIN}"
  (( D_SSL )) && scheme="https"
  host="$(lib_domain_primary_host)"
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
    lib_domain_as_user rm -f -- "${docroot}/index.html"
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
  # Handing the files to the site user needs root, and chown -R is safe for it: it changes a link
  # itself and never descends through one. (A hard link to a root file would still be changed,
  # which the kernel's fs.protected_hardlinks=1 - Ubuntu's default - stops the user creating.)
  # The modes are another matter: find hands chmod path names, and the user can re-point a
  # directory in them between the listing and the chmod. The user owns every file by now, so
  # that part runs as the user.
  chown -R "${D_USER}:${D_GROUP}" "$docroot"
  lib_domain_as_user find "$docroot" -type d -exec chmod 0755 {} + 2>/dev/null || true
  lib_domain_as_user find "$docroot" -type f -exec chmod 0644 {} + 2>/dev/null || true
  [[ -f "${docroot}/wp-config.php" ]] && lib_domain_as_user chmod 0640 "${docroot}/wp-config.php"
  lib_mkdir "${OLS_CACHE_DIR}/${D_DOMAIN}" 0750 "$(lib_ols_user):$(lib_ols_group)"
  lib_domain_wpcron_set
  D_WP=1
  lib_domain_state_save
}

# The WordPress of the site in D_*, once the site has a certificate: "home" and "siteurl" from
# http:// to https://. A WordPress installed before its certificate (add --no-ssl, or DNS that
# did not point here yet) kept http:// as its address. Its pages were right over HTTPS, but
# wp-cli, WP-Cron, the mails WordPress sends and its REST index went on saying http://, and so
# did "credentials".
#
# Only a value that is the plain http:// address of this site is changed - its name, or www.
# before it where the site has www - and only its scheme. An address somebody set (another
# host, a port, a directory) is named and left alone. What the posts link to is not rewritten:
# the old links arrive through the redirect, and WordPress (5.7 and later) hands out its own
# http:// address in content as https:// once "home" has changed this way. How many there are
# is said, with the command. Never fatal: the certificate is there whatever happens here.
lib_domain_wp_https() {   # [keep-cache: the caller empties the page cache itself]
  local docroot="${D_HOME}/public_html" info="" k="" v="" cmp="" new="" now="" h="" n="" own=0 changed=0
  local -a hosts=("$D_DOMAIN")
  (( D_SSL )) || return 0
  (( OPT_DRY_RUN )) && return 0
  if (( D_WWW )); then hosts+=("www.${D_DOMAIN}"); fi
  # lomp's own record of the address, which "credentials" prints: right over HTTPS whatever
  # WordPress turns out to say
  info="$(lib_domain_state_dir "$D_DOMAIN")/wp.info"
  if [[ -s "$info" ]]; then
    for h in "${hosts[@]}"; do
      grep -qx "WP_URL=http://${h//./\\.}" "$info" || continue
      if sed -i "s#^WP_URL=http://${h//./\\.}\$#WP_URL=https://${h}#" "$info"; then
        lib_info "WordPress: the admin address lomp keeps is now https://${h}/wp-admin/"
      fi
    done
  fi
  lib_domain_as_user test -f "${docroot}/wp-config.php" 2>/dev/null || return 0
  if ! ( lib_domain_wpcli_ensure ) >/dev/null 2>&1 || [[ ! -x "$WPCLI_BIN" ]]; then
    lib_warn "wp-cli could not be installed, so WordPress was not asked whether its address still says http://"
    lib_note "The certificate is in place. To have it looked at again: setup.sh renew-ssl ${D_DOMAIN}"
    return 0
  fi
  for k in home siteurl; do
    if ! v="$(_wp option get "$k" --skip-plugins --skip-themes 2>>"$LOG_FILE")"; then
      lib_warn "WordPress could not be asked for its address (wp-cli failed, see ${LOG_FILE}): it may still say http://"
      lib_note "The certificate is in place. To have it looked at again: setup.sh renew-ssl ${D_DOMAIN}"
      return 0
    fi
    v="${v##*$'\n'}"; cmp="${v,,}"; cmp="${cmp%/}"
    [[ "$cmp" == http://* ]] || continue
    own=0
    for h in "${hosts[@]}"; do
      if [[ "$cmp" == "http://${h}" ]]; then own=1; fi
    done
    if (( ! own )); then
      lib_info "WordPress: its ${k} is ${v}, which is not the plain address of this site; left as it is"
      continue
    fi
    new="https://${v:7}"
    if ! lib_run _wp option update "$k" "$new" --skip-plugins --skip-themes; then
      lib_warn "WordPress: its ${k} could not be set to ${new} (see ${LOG_FILE})"
      lib_note "By hand: runuser -u ${D_USER} -- wp --path=${docroot} option update ${k} '${new}'"
      continue
    fi
    # asked again: an address that is set outside the database is not reached by writing into it
    now="$(_wp option get "$k" --skip-plugins --skip-themes 2>>"$LOG_FILE")" || now=""
    now="${now##*$'\n'}"
    if [[ "$now" == "$new" ]]; then
      lib_ok "WordPress: its ${k} is now ${new} (was ${v})"
      changed=1
    else
      lib_warn "WordPress still gives ${v} as its ${k}, although its database now says ${new}"
      lib_note "The address is then set outside the database: look for WP_HOME and WP_SITEURL in ${docroot}/wp-config.php"
    fi
  done
  (( changed )) || return 0
  lib_run _wp cache flush --skip-plugins --skip-themes || true
  # a page kept from before - the REST index is one - still says http://
  if [[ "${1:-}" != "keep-cache" ]]; then _domain_rename_cache_clear; fi
  for h in "${hosts[@]}"; do
    n="$(_wp search-replace "http://${h}" "https://${h}" --all-tables-with-prefix --skip-columns=guid --dry-run --format=count --skip-plugins --skip-themes 2>>"$LOG_FILE")" || continue
    n="${n##*$'\n'}"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) || continue
    lib_info "WordPress: ${n} place(s) in its database still say http://${h}. They work - WordPress and the redirect turn them into https:// - and were left as they are"
    lib_note "To rewrite them for good: runuser -u ${D_USER} -- wp --path=${docroot} search-replace 'http://${h}' 'https://${h}' --all-tables-with-prefix --skip-columns=guid"
  done
  return 0
}

# WordPress's scheduled events, run every five minutes as the site in D_*. The line names the
# site's user and its document root, so "rename" writes it again.
lib_domain_wpcron_set() {
  local docroot="${D_HOME}/public_html"
  lib_cron_set "wpcron:${D_DOMAIN}" "*/5 * * * * ${D_USER} cd ${docroot} && WP_CLI_PHP=$(lib_php_cli "$D_PHP") ${WPCLI_BIN} --path=${docroot} cron event run --due-now --quiet >/dev/null 2>&1"
}

# =============================================================================
#  wordpress: the files only, into a site that is already there
# =============================================================================
# "add --wordpress" installs WordPress whole - database, admin account, cache plugin. This puts
# the release wordpress.org publishes into the document root of a site that exists and stops
# there: whoever opens the site next finishes the installation in the browser. Root downloads
# the archive and checks it. Unpacking and copying run as the site's user, so every file is
# that user's from the start - PHP runs as it, and WordPress has to write its wp-config.php
# and update itself - and nothing root does follows a name inside the site.
WP_ARCHIVE_URL="https://wordpress.org/latest.zip"

# The installer ends by making the wp-config.php it wrote 0666, whatever the umask - in a site
# this command put the files into, and just the same in one somebody uploaded and installed in
# the browser. The check cron runs every minute (lib_ols_htaccess_check_main) therefore looks
# at the wp-config.php in the document root of every PHP and WordPress site and closes one
# that carries more than 0640, the mode "add --wordpress" gives it: as the site's user, whose
# file it has to be - closed as root's it would be a file PHP could no longer read. One root
# uploaded has become the site's a moment earlier in the same pass (lib_domain_fix_owner_auto),
# unless that is switched off. A file closed further (0600) is left as it is, and so is a
# link. A site costs a pass one stat; the state is read only for a file that has to change.
lib_domain_wp_config_close() {
  local j="" d="" home="" f="" st="" mode="" owner="" ids=""
  (( OPT_DRY_RUN )) && return 0
  for j in "$STATE_DIR"/domains/*/domain.json; do
    [[ -s "$j" ]] || continue
    d="${j%/domain.json}"; d="${d##*/}"
    home="$(lib_domain_home "$d")"; f="${home}/public_html/wp-config.php"
    [[ -f "$f" && ! -L "$f" ]] || continue
    st="$(stat -c '%a %u' "$f" 2>/dev/null || true)"
    mode="${st%% *}"; owner="${st##* }"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || continue
    (( (8#$mode & ~8#640) != 0 )) || continue
    lib_domain_state_load "$d" || continue
    [[ "$D_MODE" == "php" || "$D_MODE" == "wordpress" ]] || continue
    # the site's own account, as fix-owner wants it, and the file that account's
    ids="$(_domain_fix_owner_ids "$home")" || continue
    [[ "$owner" == "${ids%% *}" ]] || continue
    # a failure is not reported: this runs again in a minute, and would say so every time
    if lib_domain_as_user chmod 0640 "$f" 2>/dev/null; then
      lib_ok "wp-config.php of ${d} closed to 0640 (it was ${mode})"
    fi
  done
  return 0
}

lib_domain_wordpress_usage() {
  # a usage text is no single message lib/lang.sh could look up: its Turkish is here
  if [[ "${LIB_LANG:-en}" == "tr" ]]; then
    cat <<'EOF'
Kullanım: setup.sh wordpress <domain>
  En güncel WordPress'in dosyalarını (https://wordpress.org/latest.zip), var olan bir PHP
  sitesinin belge köküne, sitenin kendi kullanıcısı olarak doğrudan yerleştirir: dizinler 0755,
  dosyalar 0644. Kurulumun kendisi - dil, veritabanı girişi, yönetici hesabı - tarayıcıda
  tamamlanır; sitenin veritabanı giriş bilgileri sonunda yazdırılır.
  İçinde zaten bir şey bulunan belge kökü için önce sorulur (--yes bunu yanıtlar):
  WordPress'in dosyaları aynı adlı dosyaların yerine geçer, gerisi kalır. root'un oraya
  yüklediği dosyalar, fix-owner'ın yaptığı gibi, önce sitenin kullanıcısına devredilir.
  wp-config.php dosyası olan bir siteye dokunulmaz. Seçenek olarak --dry-run verilirse hiçbir
  şey indirilmez ya da yazılmaz.
  WordPress'in kurulum aracı wp-config.php dosyasını 0666 bırakır; bir dakika içinde 0640 olur.
EOF
    return 0
  fi
  cat <<'EOF'
Usage: setup.sh wordpress <domain>
  Put the files of the latest WordPress (https://wordpress.org/latest.zip) straight into the
  document root of a PHP site that exists, as the site's own user: directories 0755, files
  0644. The installation itself - language, database login, admin account - is finished in
  the browser, and the site's database login is printed at the end.
  A document root that already holds something is asked about first (--yes answers it):
  WordPress's files replace the ones with the same name, the rest stays. What root uploaded
  there is handed to the site's user first, as fix-owner does. A site that has a
  wp-config.php is left alone. With --dry-run nothing is downloaded or written.
  WordPress's installer leaves its wp-config.php 0666; within a minute it is 0640.
EOF
}

# Is index.html the page a new site starts with?
_domain_wp_placeholder() {   # docroot
  [[ -f "${1}/index.html" && ! -L "${1}/index.html" ]] && grep -qsF -- "$DOMAIN_PLACEHOLDER_MARK" "${1}/index.html"
}

# How many names the document root holds, that page left out.
_domain_wp_docroot_count() {   # docroot
  local n=0
  n="$( { find -P "$1" -mindepth 1 -maxdepth 1 -printf . 2>/dev/null || true; } | wc -c)"
  n=$(( n ))
  if (( n > 0 )) && _domain_wp_placeholder "$1"; then n=$(( n - 1 )); fi
  printf '%d' "$n"
}

# How many in the document root, itself included, belong to someone else.
_domain_wp_foreign_count() {   # docroot uid gid
  local n=0
  n="$( { find -P "$1" -xdev \( ! -uid "$2" -o ! -gid "$3" \) -printf . 2>/dev/null || true; } | wc -c)"
  printf '%d' "$(( n ))"
}

lib_domain_wordpress_main() {
  local a="" domain="" docroot="" ids="" uid="" gid="" n=0 foreign=0 tmp="" zip="" want="" stage="" ver="" scheme="http" host=""
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      -h|--help|help) lib_domain_wordpress_usage; return 0 ;;
      -*) lib_domain_wordpress_usage >&2; lib_die "Unknown option for wordpress: ${a}" "" "see the usage above" ;;
      *)  [[ -z "$domain" ]] || lib_die "wordpress takes one site at a time" "" "setup.sh wordpress ${domain}"
          domain="${a,,}" ;;
    esac
  done
  if [[ -z "$domain" ]]; then
    lib_domain_wordpress_usage >&2
    lib_die "Domain missing" "" "setup.sh wordpress example.com"
  fi
  lib_require_tools
  lib_rollback_clear
  lib_domain_valid "$domain" || lib_die "Invalid domain name '${domain}'" "" "setup.sh list"
  lib_domain_registered "$domain" \
    || lib_die "Site ${domain} is not registered" "WordPress goes into a site that exists" "setup.sh add ${domain}, then run this again"
  lib_domain_state_load "$domain"
  docroot="${D_HOME}/public_html"
  [[ "$D_MODE" == "php" || "$D_MODE" == "wordpress" ]] \
    || lib_die "${domain} cannot run WordPress" "it is a ${D_MODE} site: no PHP runs there" "choose a PHP site, or add one: setup.sh add <domain>"
  [[ -d "$docroot" && ! -L "$docroot" ]] \
    || lib_die "${docroot} is not a directory" "the document root of ${domain} is missing, or a link" "setup.sh doctor"
  if [[ -e "${docroot}/wp-config.php" || -L "${docroot}/wp-config.php" ]]; then
    lib_die "WordPress is already installed in ${docroot}" "wp-config.php is there, so the installation screen would not come up" \
      "nothing was changed; WordPress updates itself from its own dashboard"
  fi
  if ! ids="$(_domain_fix_owner_ids "$D_HOME")"; then lib_die "WordPress was not put into ${docroot}" "$ids" "setup.sh doctor"; fi
  read -r uid gid <<<"$ids"

  n="$(_domain_wp_docroot_count "$docroot")"
  foreign="$(_domain_wp_foreign_count "$docroot" "$uid" "$gid")"
  if (( n > 0 )); then
    lib_warn "${docroot} already holds $(_domain_n_entries "$n"): WordPress's files replace the ones that have the same name, the rest stays"
  fi
  if (( foreign > 0 )); then
    lib_warn "${docroot} is not all ${D_USER}'s (uploaded as root?): 'fix-owner ${domain}' runs first"
  fi
  if (( OPT_DRY_RUN )); then
    lib_info "[dry-run] would download ${WP_ARCHIVE_URL} and unpack it into ${docroot} as ${D_USER}"
    return 0
  fi
  if (( n > 0 || foreign > 0 )); then
    lib_confirm "Put WordPress into ${docroot}?" n \
      || lib_die "WordPress was not put into ${docroot}" "not confirmed" "answer y, or add --yes"
  fi
  # a directory root uploaded is one the site's user cannot unpack into, and a file root
  # uploaded one WordPress could never update
  if (( foreign > 0 )); then
    lib_domain_fix_owner_guard
    lib_domain_fix_owner "$domain" \
      || lib_die "WordPress was not put into ${docroot}" "the files of ${domain} could not all be handed to ${D_USER} (see above)" "clear that up, then run this again"
  fi
  lib_have unzip || lib_apt_install unzip || lib_die "unzip is not installed" "apt could not install it" "apt-get install unzip"

  tmp="$(lib_mktemp -d)"; zip="${tmp}/wordpress.zip"
  lib_info "Downloading ${WP_ARCHIVE_URL} ..."
  curl -fsSL --retry 3 --max-time 300 -o "$zip" "$WP_ARCHIVE_URL" \
    && curl -fsSL --retry 3 --max-time 60 -o "${zip}.sha1" "${WP_ARCHIVE_URL}.sha1" \
    || lib_die "WordPress download failed" "network problem, or wordpress.org did not answer" "retry later; ${docroot} was not touched"
  read -r want _ <"${zip}.sha1" || true
  [[ "$(sha1sum "$zip" | cut -d' ' -f1)" == "$want" ]] \
    || lib_die "WordPress checksum mismatch" "corrupted download" "retry later; ${docroot} was not touched"

  # A working directory in private/tmp, which is the site user's and in no backup - after
  # taking away what a run that was interrupted left there. Its name goes into a rollback
  # step, so it has to be the one asked for.
  lib_domain_as_user find "${D_HOME}/private/tmp" -mindepth 1 -maxdepth 1 -type d -name '.lomp-wordpress.??????' \
    -exec rm -rf -- {} + 2>/dev/null || true
  stage="$(lib_domain_as_user mktemp -d "${D_HOME}/private/tmp/.lomp-wordpress.XXXXXX" 2>/dev/null || true)"
  [[ "$stage" == "${D_HOME}/private/tmp/.lomp-wordpress."?????? ]] \
    || lib_die "Could not make a working directory in ${D_HOME}/private/tmp" "it is missing, or ${D_USER} cannot write there" "setup.sh fix-owner ${domain}; ${docroot} was not touched"
  lib_rollback_push "runuser -u '${D_USER}' -- env -C / rm -rf -- '${stage}'"

  lib_info "Unpacking it into ${docroot} as ${D_USER} ..."
  lib_domain_as_user tee "${stage}/wordpress.zip" <"$zip" >/dev/null \
    && lib_run lib_domain_as_user unzip -q -o "${stage}/wordpress.zip" -d "$stage" \
    && lib_domain_as_user test -f "${stage}/wordpress/wp-includes/version.php" \
    || lib_die "The WordPress archive could not be unpacked" "the disk is full, or it is not the archive wordpress.org publishes" "see the log; ${docroot} was not touched"
  ver="$(lib_domain_as_user awk -F\' '/^\$wp_version[[:space:]]*=/ { print $2; exit }' "${stage}/wordpress/wp-includes/version.php" 2>/dev/null || true)"
  [[ "$ver" =~ ^[0-9][0-9A-Za-z.+-]*$ ]] || ver=""
  # whatever modes the archive carries: directories 0755, files 0644
  lib_domain_as_user find "${stage}/wordpress" -type d -exec chmod 0755 {} + \
    && lib_domain_as_user find "${stage}/wordpress" -type f -exec chmod 0644 {} + \
    || lib_die "The modes of the WordPress files could not be set" "" "see the log; ${docroot} was not touched"
  if _domain_wp_placeholder "$docroot"; then lib_domain_as_user rm -f -- "${docroot}/index.html" || true; fi
  lib_run lib_domain_as_user cp -a --remove-destination -- "${stage}/wordpress/." "${docroot}/" \
    || lib_die "WordPress could not be copied into ${docroot}" "the disk is full, or something there cannot be replaced by ${D_USER}" \
         "see the log; what was copied stays, and running this again once the cause is gone completes it"
  lib_domain_as_user rm -rf -- "$stage" || lib_warn "could not remove ${stage}"
  lib_rollback_clear
  lib_log_write INFO "WordPress ${ver:-of an unknown version} put into ${docroot} as ${D_USER}"
  # the check that will close the wp-config.php the installer is going to write (see above)
  lib_ols_htaccess_watch_ensure

  if (( D_SSL )); then scheme="https"; fi
  host="$(lib_domain_primary_host)"
  printf '\n%s%sWordPress%s is in place and waits for its installation%s\n' "$C_BLD" "$C_GRN" "${ver:+ ${ver}}" "$C_RST"
  lib_print_kv "Open in a browser" "${scheme}://${host}/  (language, database login, admin account)"
  lib_print_kv "Files"             "${docroot}, owned by ${D_USER}:${D_GROUP} (directories 0755, files 0644)"
  # shown for the same reason the summary of "add" shows it: the installer asks for it next
  if lib_db_info_load "$domain"; then
    lib_print_kv "Database name"     "$DBI_NAME"
    lib_print_kv "Database user"     "$DBI_USER"
    lib_print_kv "Database password" "$DBI_PASS"
    lib_print_kv "Database host"     "localhost"
  else
    lib_print_kv "Database"          "none yet; this makes one and prints its login: setup.sh db ${domain}"
  fi
  lib_print_kv "wp-config.php"     "goes to 0640 by itself within a minute of the installation (WordPress writes it 0666)"
  printf '\n'
}

# =============================================================================
#  summary / credentials / list / logs
# =============================================================================
lib_domain_summary() {
  local sslline=""
  sslline="$(lib_ssl_status_line "$D_DOMAIN")"
  # NOT 'sslline="...$( (( x )) && printf ... )"'. A command substitution whose last command
  # is a conditional that turns out false exits 1; a plain assignment adopts that status, and
  # errexit then kills the run. This fired on a real "add" AFTER the site had been created
  # and every step had reported OK - the only casualty was the summary nobody got to read.
  if (( ! D_SSL )); then
    if (( D_SSL_WANTED )); then sslline="not active (run: setup.sh renew-ssl ${D_DOMAIN})"
    else sslline="not requested (once DNS points here: setup.sh renew-ssl ${D_DOMAIN})"; fi
  fi
  lib_tr "Site ${D_DOMAIN} is ready"
  printf '\n%s%s%s%s\n' "$C_BLD" "$C_GRN" "$LIB_TR" "$C_RST"
  lib_print_kv "URL"         "$( (( D_SSL )) && printf 'https' || printf 'http')://${D_DOMAIN}/$( (( D_WWW )) && printf '  (+ www)')"
  lib_print_kv "Mode"        "${D_MODE}${D_PROXY:+ -> $D_PROXY}"
  if lib_app_state_load "$D_DOMAIN"; then
    lib_print_kv "Application" "${D_HOME}/app, run by PM2 ($(lib_app_unit_name "$D_IDENT")): ${APP_RESULT:-prepared}"
    if [[ "$APP_RESULT" != "running" ]]; then
      lib_print_kv "Next"      "put the code into ${D_HOME}/app (copied as root? setup.sh fix-owner ${D_DOMAIN}), then: setup.sh app deploy ${D_DOMAIN}"
    fi
  fi
  lib_print_kv "Document root" "${D_HOME}/public_html"
  lib_print_kv "System user" "${D_USER} (uploaded as root? setup.sh fix-owner ${D_DOMAIN})"
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
    # ...and the domains that have their mail here and no site
    if lib_mail_installed; then
      while read -r d; do
        [[ -n "$d" ]] || continue
        lib_domain_registered "$d" && continue
        lib_domain_credentials_mail_domain "$d"
      done < <(lib_mail_standalone_domains)
    fi
    return 0
  fi
  target="${target,,}"
  lib_domain_arg_ok "$target" || lib_die "Invalid domain name '${target}'" "" "setup.sh list"
  if ! lib_domain_registered "$target" && lib_mail_installed && lib_mail_domain_standalone "$target"; then
    lib_domain_credentials_mail_domain "$target"
    return 0
  fi
  lib_domain_registered "$target" || lib_die "Site ${target} is not registered" "" "setup.sh list"
  lib_domain_credentials_show "$target"
}

# A mail domain that is no site: there is nothing to show but its mail.
lib_domain_credentials_mail_domain() {   # domain
  local domain="$1"
  printf '\n%s== %s ==%s\n' "$C_BLD" "$domain" "$C_RST"
  lib_print_kv "Kind" "mail domain (its mail is here; no site on this server)"
  if lib_mail_domain_enabled "$domain"; then
    lib_domain_credentials_mail "$domain"
  else
    lib_print_kv "Mail" "switched off (setup.sh mail enable ${domain})"
    printf '\n'
  fi
  return 0
}

# What somebody needs to set up a mail client, and nothing they should not have: a mailbox
# password is not stored anywhere on this server, only its hash. A domain whose addresses are
# delivered into another domain's mailbox has no login of its own, and says where they go.
lib_domain_credentials_mail() {   # domain
  local domain="$1" mhost="" box="" alias="" targets="" all=""
  lib_mail_installed || return 0
  lib_mail_domain_enabled "$domain" || return 0
  mhost="mail.${domain}"
  [[ -s "${SSL_DEPLOY_DIR}/$(lib_mail_cert_name "$domain")/fullchain.pem" ]] || mhost="$(lib_mail_host)"
  all="$(lib_mail_catchall "$domain")"
  printf '%sMail%s\n' "$C_BLD" "$C_RST"
  lib_print_kv "IMAP"     "${mhost}:993, SSL/TLS"
  lib_print_kv "SMTP"     "${mhost}:465 (SSL/TLS) or :587 (STARTTLS)"
  box="$(lib_mail_boxes "$domain" | sed -n 1p)"
  if [[ -z "$box" && -n "$(lib_mail_aliases "$domain")${all}" ]]; then
    lib_print_kv "User name" "none of its own: the mailbox its addresses are delivered into signs in, with that mailbox's address"
  else
    lib_print_kv "User name" "the full address, e.g. ${box:-info@${domain} (no mailbox yet: setup.sh mail box add info@${domain})}"
    lib_print_kv "Password" "set when the mailbox was made; change it with: setup.sh mail box passwd <address>"
  fi
  while read -r box; do [[ -n "$box" ]] && lib_print_kv "Mailbox" "${box} ($(lib_mail_box_quota "$box"))"; done < <(lib_mail_boxes "$domain")
  # postmaster, abuse and dmarc are on every domain and go where its first address goes
  while IFS=$'\t' read -r alias targets; do
    [[ -n "$alias" ]] || continue
    case "${alias%%@*}" in postmaster|abuse|dmarc) continue ;; esac
    lib_print_kv "Alias" "${alias} -> ${targets//,/, }"
  done < <(lib_mail_aliases "$domain")
  if [[ -n "$all" ]]; then lib_print_kv "Every other address" "-> ${all//,/, }"; fi
  if [[ "$(lib_json_get "$(lib_mail_json "$domain")" '.mail.webmail')" == "true" ]]; then
    lib_print_kv "Webmail" "https://$(lib_webmail_host "$domain")  (the same address and password)"
  fi
  lib_print_kv "DNS"      "setup.sh mail dns ${domain} --check"
  printf '\n'
  return 0
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
  lib_domain_credentials_mail "$domain"
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
  lib_tprintf '%s%-28s %-10s %-5s %-24s %-22s %-10s%s\n' "$C_BLD" "DOMAIN" "MODE" "PHP" "SSL" "LAST BACKUP" "STATUS" "$C_RST"
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_domain_state_load "$d" || continue
    ssl="$( (( D_SSL )) && lib_ssl_status_line "$d" || printf -- '-')"
    last="${D_BACKUP_LAST:--}"
    status="$D_STATUS"
    [[ -d "$D_HOME/public_html" ]] || status="${status} (missing dir!)"
    lib_tprintf '%-28s %-10s %-5s %-24s %-22s %-10s\n' "$d" "$D_MODE" "${D_PHP:--}" "${ssl:0:24}" "${last:0:22}" "$status"
    rows+=("$d")
  done < <(lib_domains_list)
  if ((${#rows[@]} == 0)); then lib_tr "(no sites yet - add one with: setup.sh add example.com)"; printf '%s\n' "$LIB_TR"; fi
  # names that are no site and only send their visitors on to one
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_redirect_load "$d" || continue
    ssl="$(lib_ssl_deployed "$d" && lib_ssl_status_line "$d" || printf -- '-')"
    printf '%-28s %-10s %-5s %-24s %-22s %s\n' "$d" "redirect" "-" "${ssl:0:24}" "-" "-> ${R_TARGET}"
  done < <(lib_redirects_list)
  lib_tr "${#rows[@]} site(s); files under ${SITES_ROOT}/<domain>/public_html"
  printf '\n%s%s%s\n' "$C_DIM" "$LIB_TR" "$C_RST"
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
  lib_domain_arg_ok "$domain" || lib_die "Invalid domain name '${domain}'" "" "setup.sh list"
  lib_domain_registered "$domain" || lib_die "Site ${domain} is not registered" "" "setup.sh list"
  # the directory OpenLiteSpeed writes, not the link in the home: that one is the site user's
  local dir=""; dir="$(lib_domain_log_dir_in_use "$domain")"
  [[ "$which" != "error" ]]  && files+=("${dir}/access.log")
  [[ "$which" != "access" ]] && files+=("${dir}/error.log")
  # A missing log is not created here: made by root, it is a file OpenLiteSpeed's workers
  # cannot write. OpenLiteSpeed puts it back itself, and tail -F waits for it.
  printf '%sFollowing %s (Ctrl-C to stop)%s\n' "$C_DIM" "${files[*]}" "$C_RST"
  # not "exec": that replaced this process and skipped the EXIT trap, which left the per-run
  # temporary directory behind every time a log was followed
  tail -n "$lines" -F "${files[@]}" || true
}

# =============================================================================
#  fix-owner: files uploaded as root go back to the site's user
# =============================================================================
# Files uploaded as root - WinSCP or scp logged in as root, an archive root unpacked - stay
# root's, and PHP runs as the site's own user: WordPress cannot update itself or store an
# upload until they are handed over. Doing that means root working in a tree the site user
# controls, so every step below is written against that user.
DOM_FIX_OWNER_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
DOM_HARDLINKS_SYSCTL="/proc/sys/fs/protected_hardlinks"
DOM_MOUNTINFO="/proc/self/mountinfo"

lib_domain_fix_owner_usage() {
  # a usage text is no single message lib/lang.sh could look up: its Turkish is here
  if [[ "${LIB_LANG:-en}" == "tr" ]]; then
    cat <<'EOF'
Kullanım: setup.sh fix-owner <domain>... | --all
          setup.sh fix-owner --auto on|off
  root olarak yüklemeden sonra (WinSCP, scp, root'un açtığı bir arşiv) bir sitenin dosyalarını
  kendi kullanıcısına ve grubuna geri verir. Yalnızca başkasına ait olanlar değişir; logs/
  root'ta kalır, dosya izinleri de olduğu gibi kalır. Seçenek olarak --dry-run verilirse yalnızca sayar.
  Aynısı her sitede, yüklemeden sonraki bir dakika içinde kendiliğinden olur: bu komut, bir
  dakika beklemeden hemen yapmak ve bir sitenin dosyalarının neden devredilmediğini görmek
  içindir. Bunu --auto off durdurur; root'un bir sitede bilerek kendi dosyalarını tuttuğu
  sunucu içindir (devredilince sitenin PHP'si bu dosyaları değiştirebilir); yeniden başlatmak
  için --auto on kullanın.
EOF
    return 0
  fi
  cat <<'EOF'
Usage: setup.sh fix-owner <domain>... | --all
       setup.sh fix-owner --auto on|off
  Hand a site's files back to its own user and group after uploading as root (WinSCP, scp,
  an archive unpacked by root). Only what belongs to someone else changes; logs/ stays
  root's and the file modes stay as they are. With --dry-run it only counts.
  The same happens by itself, in every site, within a minute of an upload: the command is
  for now rather than in a minute, and for seeing why a site's files were not handed over.
  --auto off stops that, on a server where root keeps files of its own in a site on purpose
  (handed over, they are files the site's PHP may change); --auto on starts it again.
EOF
}

# A hard link is how a chown run by root could reach past a site: it changes the file, and the
# file may have another name anywhere on the disk. With fs.protected_hardlinks=1 - Ubuntu's
# default, and in lomp's sysctl file - a user can link only a file it owns or may read and
# write, so a site user cannot plant /etc/shadow in its site for this command to hand over.
lib_domain_hardlinks_protected() {
  local v=""
  v="$(cat "$DOM_HARDLINKS_SYSCTL" 2>/dev/null || true)"
  [[ "$v" == "1" ]]
}

# A name out of a site's tree, fit for a terminal: its owner chose it, control characters too.
_domain_printable() { local s="$1"; printf '%s' "${s//[[:cntrl:]]/?}"; }

_domain_n_entries() {   # count
  if (( $1 == 1 )); then printf '1 file or directory'; else printf '%d files and directories' "$1"; fi
}

# The numbers the files go to, once the account proves to be this site's: it exists, it is not
# root, and its home is the site's - the pairing useradd made when the site was added
# (lib_domain_user_ensure). Prints "uid gid", or why not.
_domain_fix_owner_ids() {   # home
  local pw="" uid="" gid="" dir=""
  pw="$(getent passwd "$D_USER" 2>/dev/null || true)"
  [[ -n "$pw" ]] || { printf 'its user %s does not exist' "$D_USER"; return 1; }
  IFS=: read -r _ _ uid _ _ dir _ <<<"$pw"
  gid="$(getent group "$D_GROUP" 2>/dev/null | cut -d: -f3 || true)"
  [[ -n "$gid" ]] || { printf 'its group %s does not exist' "$D_GROUP"; return 1; }
  [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ && "$uid" != 0 && "$gid" != 0 ]] \
    || { printf '%s:%s is not a site account (uid %s, gid %s)' "$D_USER" "$D_GROUP" "$uid" "$gid"; return 1; }
  [[ "$dir" == "$1" ]] || { printf 'the home of %s is %s, not %s' "$D_USER" "$dir" "$1"; return 1; }
  printf '%s %s' "$uid" "$gid"
}

# Mount points below the home. chown cannot tell a directory from the top of a mounted
# filesystem, and one bind-mounted into a site - shared with other sites, say - would become
# that site's user's. (Field 5 of mountinfo; without the file there is nothing to report.)
_domain_mounts_below() {   # dir
  awk -v p="$1/" 'index($5, p) == 1 { print $5 }' "$DOM_MOUNTINFO" 2>/dev/null || true
}

# What this command never hands over: a device node gives its owner the disk or the memory
# behind it, and a file with a second name may have that name outside the site - pnpm or bun
# installing from root's store, cp -al, rsync --link-dest. A file whose every name is in this
# home is another matter, and an everyday one: npm's esbuild (every Vite project has it) gives
# its binary a second name inside node_modules. So the names a file has in the home are
# counted against its link count, and it is handed over when none is missing. A name in logs/
# is not counted: something moved there before the run could be moved back under a name the
# run is about to change. Sets DOM_FO_HAZARDS (paths) and DOM_FO_SHARED ("inode:links" of the
# files that may go).
DOM_FO_HAZARDS=() DOM_FO_SHARED=()
_domain_fix_owner_survey() {   # home uid gid
  local rec="" y="" i="" n="" p="" k=0
  local -a paths=() inos=()
  local -A seen=() links=()
  DOM_FO_HAZARDS=(); DOM_FO_SHARED=()
  while IFS= read -r -d '' rec; do
    y="${rec%% *}"; rec="${rec#* }"; i="${rec%% *}"; rec="${rec#* }"; n="${rec%% *}"; p="${rec#* }"
    paths+=("$p"); inos+=("$i")
    if [[ "$y" == [bc] || "$p" == "$1/logs" || "$p" == "$1/logs/"* ]]; then
      links[$i]="x"
    elif [[ "${links[$i]:-$n}" == "$n" ]]; then
      links[$i]="$n"; seen[$i]=$(( ${seen[$i]:-0} + 1 ))
    else
      links[$i]="x"   # its link count changed during the walk
    fi
  done < <(find -P "$1" -xdev \( ! -uid "$2" -o ! -gid "$3" \) \
    \( -type b -o -type c -o \( ! -type d -links +1 \) \) -printf '%y %i %n %p\0' 2>/dev/null || true)
  for ((k = 0; k < ${#paths[@]}; k++)); do
    i="${inos[k]}"
    [[ "${links[$i]}" == "${seen[$i]:-0}" ]] || DOM_FO_HAZARDS+=("${paths[k]}")
  done
  for i in "${!seen[@]}"; do
    [[ "${links[$i]}" != "${seen[$i]}" ]] || DOM_FO_SHARED+=("${i}:${links[$i]}")
  done
}

# How many in the home belong to someone else: the home itself included, logs/ left out.
_domain_fix_owner_count() {   # home uid gid
  local n=""
  n="$( { find -P "$1" -xdev \( -path "$1/logs" -prune \) -o \( ! -uid "$2" -o ! -gid "$3" \) -printf . 2>/dev/null || true; } | wc -c)"
  printf '%d' "$(( n ))"
}

# The change. -execdir runs chown from the directory find holds open, on names relative to
# it, so a directory swapped for a link while the run is under way takes chown nowhere new;
# chown -h changes a link itself, never what it names; -xdev keeps to the home's filesystem.
# Devices stay out here too, and so does a file with a second name unless the look before
# found all its names in the home: it is taken by its inode number, and only while it has as
# many names as it had then, in case one was moved into place after that look. (A thousand of
# those to a walk: a command line has an end.) find refuses -execdir under a PATH with a
# relative entry, so it gets a fixed one rather than whatever the operator's is.
_domain_fix_owner_apply() {   # home uid gid [inode:links]...
  local home="$1" uid="$2" gid="$3" k=0 rc=0
  local -a pick=(-type d -o -links 1)
  shift 3
  while :; do
    for ((k = 0; k < 1000 && $# > 0; k++)); do
      pick+=(-o \( -inum "${1%%:*}" -links "${1##*:}" \)); shift
    done
    PATH="$DOM_FIX_OWNER_PATH" find -P "$home" -xdev \( -path "$home/logs" -prune \) -o \
      \( ! -uid "$uid" -o ! -gid "$gid" \) ! -type b ! -type c \( "${pick[@]}" \) \
      -execdir chown -h -- "${D_USER}:${D_GROUP}" {} + || rc=1
    (($# > 0)) || break
    pick=(-false)
  done
  return "$rc"
}

# One site: its home and everything below it but logs/, which leads to - or, on a server an
# older release set up, still is - the log directory root has to keep. Only what belongs to
# someone else changes: a chown re-dates a file (ctime), and the .htaccess check reloads
# OpenLiteSpeed for a .htaccess that looks changed. A site that fails a check is left exactly
# as it is. Returns 1 when not all of it could be handed over.
lib_domain_fix_owner() {   # domain
  local domain="$1" home="" ids="" uid="" gid="" mounts="" n=0 left=0 f=""
  local -a hazards=() shared=()
  home="$(lib_domain_home "$domain")"
  lib_domain_state_load "$domain" || { lib_error "${domain} is not registered"; return 1; }
  if [[ -L "$home" || ! -d "$home" ]]; then
    lib_error "${domain}: ${home} is not a directory; nothing changed"
    return 1
  fi
  if ! ids="$(_domain_fix_owner_ids "$home")"; then
    lib_error "${domain}: ${ids}; nothing changed"
    return 1
  fi
  read -r uid gid <<<"$ids"
  mounts="$(_domain_mounts_below "$home")"
  if [[ -n "$mounts" ]]; then
    lib_error "${domain}: a filesystem is mounted inside the home, at $(_domain_printable "${mounts%%$'\n'*}"); nothing changed"
    return 1
  fi
  _domain_fix_owner_survey "$home" "$uid" "$gid"
  hazards=("${DOM_FO_HAZARDS[@]}"); shared=("${DOM_FO_SHARED[@]}")
  if ((${#hazards[@]} > 0)); then
    lib_error "${domain}: nothing changed - this command never hands over a device node or a file that has another name outside the site, and the site has ${#hazards[@]} of them:"
    for f in "${hazards[@]:0:5}"; do lib_note "$(_domain_printable "$f")"; done
    if ((${#hazards[@]} > 5)); then lib_note "... and $(( ${#hazards[@]} - 5 )) more"; fi
    lib_note "look at them with ls -li, take away what is not this site's, then run it again"
    return 1
  fi
  n="$(_domain_fix_owner_count "$home" "$uid" "$gid")"
  if (( n == 0 )); then
    lib_ok "${domain}: everything already belongs to ${D_USER}"
    return 0
  fi
  if (( OPT_DRY_RUN )); then
    lib_info "[dry-run] ${domain}: would hand $(_domain_n_entries "$n") to ${D_USER}:${D_GROUP}"
    return 0
  fi
  lib_log_write CMD "fix-owner ${domain}: chown -h ${D_USER}:${D_GROUP} what belongs to someone else in ${home} (${n})"
  # what find and chown complain about goes to the log, without the control characters a name
  # the site user chose could bring along
  { _domain_fix_owner_apply "$home" "$uid" "$gid" "${shared[@]}" 2>&1 >/dev/null || true; } \
    | tr -d '\000-\011\013-\037\177' | lib_mask_secrets >>"$LOG_FILE" 2>/dev/null || true
  left="$(_domain_fix_owner_count "$home" "$uid" "$gid")"
  if (( left > 0 )); then
    lib_warn "${domain}: not all of it changed hands (${left} of ${n} left) - an upload still under way, or a file made immutable (lsattr); run it again once the upload is done"
    return 1
  fi
  lib_ok "${domain}: $(_domain_n_entries "$n") handed to ${D_USER}:${D_GROUP}"
}

# What has to hold before lib_domain_fix_owner runs at all, for whoever calls it.
lib_domain_fix_owner_guard() {
  lib_domain_hardlinks_protected && return 0
  if (( OPT_DRY_RUN )); then
    lib_warn "fs.protected_hardlinks is off; a real run refuses to start until it is on (sysctl -w fs.protected_hardlinks=1)"
    return 0
  fi
  lib_die "fs.protected_hardlinks is off" \
    "without it a site user can hard-link a file it does not own - /etc/shadow, say - into its site, and this command would hand that file over" \
    "sysctl -w fs.protected_hardlinks=1 (Ubuntu's default; setup.sh optimize writes it for good), then run it again"
}

# ---- the same, by itself -----------------------------------------------------------------
# Whoever uploads as root does so again and again, and a site whose files are root's is one
# WordPress cannot update or store an upload in. So the check cron runs every minute
# (lib_ols_htaccess_check_main) hands over what is not a site's own as well, in every site:
# one walk of a home finds out whether there is anything (it stops at the first, and after 30
# seconds), and only then do the checks and the chown of fix-owner run - the same ones, in the
# same order, with what they find kept in two variables instead of printed.
# "fix-owner --auto off" stops it, for a server where root keeps files of its own in a site on
# purpose: handed over, such a file is one the site's PHP may change.
# What cannot be handed over is said once, not every minute: the reason is kept in the site's
# state directory, where doctor reads it, and goes when the site has nothing left that is
# somebody else's.
DOM_AUTO_N=0 DOM_AUTO_WHY=""

lib_domain_fix_owner_auto_enabled() { [[ "$(lib_manifest_get '.fix_owner_auto')" != "off" ]]; }
_domain_fix_owner_stamp() { printf '%s/fix-owner.auto' "$(lib_domain_state_dir "$1")"; }

# 0 = DOM_AUTO_N entries changed hands (0 when there was nothing); 1 = none could, and
# DOM_AUTO_WHY says why. An upload still under way leaves some for the next pass: that is
# progress, not a failure.
_domain_fix_owner_quiet() {   # domain  (its D_* are loaded)
  local home="" ids="" uid="" gid="" mounts="" n=0 left=0
  local -a hazards=() shared=()
  DOM_AUTO_N=0; DOM_AUTO_WHY=""
  home="$(lib_domain_home "$1")"
  if ! ids="$(_domain_fix_owner_ids "$home")"; then DOM_AUTO_WHY="$ids"; return 1; fi
  read -r uid gid <<<"$ids"
  mounts="$(_domain_mounts_below "$home")"
  if [[ -n "$mounts" ]]; then DOM_AUTO_WHY="a filesystem is mounted inside the home"; return 1; fi
  _domain_fix_owner_survey "$home" "$uid" "$gid"
  hazards=("${DOM_FO_HAZARDS[@]}"); shared=("${DOM_FO_SHARED[@]}")
  if ((${#hazards[@]} > 0)); then
    DOM_AUTO_WHY="a device node or a file that has another name outside the site is never handed over, and the site has ${#hazards[@]} of them"
    return 1
  fi
  n="$(_domain_fix_owner_count "$home" "$uid" "$gid")"
  (( n > 0 )) || return 0
  _domain_fix_owner_apply "$home" "$uid" "$gid" "${shared[@]}" >/dev/null 2>&1 || true
  left="$(_domain_fix_owner_count "$home" "$uid" "$gid")"
  if (( left >= n )); then
    DOM_AUTO_WHY="$(_domain_n_entries "$left") did not change hands (made immutable? lsattr)"
    return 1
  fi
  DOM_AUTO_N=$(( n - left ))
  return 0
}

lib_domain_fix_owner_auto() {
  local j="" d="" home="" ug="" ids="" first="" stamp=""
  (( OPT_DRY_RUN )) && return 0
  lib_domain_fix_owner_auto_enabled || return 0
  lib_domain_hardlinks_protected || return 0
  for j in "$STATE_DIR"/domains/*/domain.json; do
    [[ -s "$j" ]] || continue
    d="${j%/domain.json}"; d="${d##*/}"
    home="$(lib_domain_home "$d")"
    [[ -d "$home" && ! -L "$home" ]] || continue
    # the account from one jq call, not the thirty of a whole state load: this is every minute
    ug="$(jq -r '"\(.user // "") \(.group // "")"' "$j" 2>/dev/null || true)"
    [[ "$ug" == ?*" "?* ]] || continue
    ids="$(D_USER="${ug%% *}"; D_GROUP="${ug##* }"; _domain_fix_owner_ids "$home")" || continue
    first="$(timeout 30 find -P "$home" -xdev \( -path "${home}/logs" -prune \) -o \
      \( ! -uid "${ids%% *}" -o ! -gid "${ids##* }" \) -print -quit 2>/dev/null || true)"
    stamp="$(_domain_fix_owner_stamp "$d")"
    if [[ -z "$first" ]]; then
      if [[ -e "$stamp" ]]; then rm -f -- "$stamp"; fi
      continue
    fi
    lib_domain_state_load "$d" || continue
    if _domain_fix_owner_quiet "$d"; then
      if [[ -e "$stamp" ]]; then rm -f -- "$stamp"; fi
      if (( DOM_AUTO_N > 0 )); then
        lib_ok "${d}: $(_domain_n_entries "$DOM_AUTO_N") handed to ${D_USER}:${D_GROUP} (somebody else's until now: uploaded as root?)"
      fi
    elif [[ "$(cat "$stamp" 2>/dev/null || true)" != "$DOM_AUTO_WHY" ]]; then
      printf '%s\n' "$DOM_AUTO_WHY" >"$stamp"
      lib_warn "${d}: what is not ${D_USER}'s in ${home} is not handed over by itself: ${DOM_AUTO_WHY} (setup.sh fix-owner ${d} shows it)"
    fi
  done
  return 0
}

lib_domain_fix_owner_main() {
  local a="" all=0 d="" failed=0 auto=""
  local -a domains=()
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --all)     all=1 ;;
      --auto)    auto="${1:-}"; shift || true
                 [[ "$auto" == "on" || "$auto" == "off" ]] || lib_die "--auto takes on or off" "" "setup.sh fix-owner --auto off" ;;
      -h|--help) lib_domain_fix_owner_usage; return 0 ;;
      -*)        lib_domain_fix_owner_usage >&2; lib_die "Unknown option for fix-owner: ${a}" "" "see the usage above" ;;
      *)         domains+=("${a,,}") ;;
    esac
  done
  if [[ -n "$auto" ]]; then
    if (( all )) || ((${#domains[@]} > 0)); then lib_die "--auto switches it for every site" "" "setup.sh fix-owner --auto ${auto}"; fi
    lib_require_tools
    lib_require_installed
    if (( OPT_DRY_RUN )); then lib_info "[dry-run] would switch the automatic hand-over ${auto}"; return 0; fi
    lib_manifest_set '.fix_owner_auto' "$auto"
    if [[ "$auto" == "on" ]]; then
      lib_ols_htaccess_watch_ensure
      lib_ok "What is not a site's own in its home is handed to its user by itself, within a minute"
    else
      lib_ok "Files change hands only when fix-owner is run (a wp-config.php root uploaded is then not closed by itself either)"
    fi
    return 0
  fi
  if (( all )) && ((${#domains[@]} > 0)); then lib_die "--all and a domain cannot be combined" "" "setup.sh fix-owner --all"; fi
  if (( ! all )) && ((${#domains[@]} == 0)); then
    lib_domain_fix_owner_usage >&2
    lib_die "Domain missing" "" "setup.sh fix-owner example.com   (every site: setup.sh fix-owner --all)"
  fi
  lib_require_tools
  for d in "${domains[@]}"; do
    lib_domain_valid "$d" || lib_die "Invalid domain name '${d}'" "" "setup.sh list"
    lib_domain_registered "$d" || lib_die "Site ${d} is not registered" "" "setup.sh list"
  done
  lib_domain_fix_owner_guard
  if (( all )); then
    mapfile -t domains < <(lib_domains_list)
    if ((${#domains[@]} == 0)); then lib_info "No sites have been added yet."; return 0; fi
  fi
  for d in "${domains[@]}"; do
    lib_domain_fix_owner "$d" || failed=$((failed + 1))
  done
  if (( failed > 0 )); then
    lib_warn "${failed} of ${#domains[@]} site(s) could not be handed over completely; see above"
    return 1
  fi
  return 0
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
  # Said for what it is. "example.com/" - what the shell's completion makes of a site typed in
  # /home - is no domain name, and "Site example.com/ is not registered" reads as if the site
  # itself had gone missing.
  lib_domain_arg_ok "$domain" || lib_die "Invalid domain name '${domain}'" "" "setup.sh list"
  lib_domain_registered "$domain" || lib_die "Site ${domain} is not registered" "" "setup.sh list"
  lib_domain_state_load "$domain"
  # A record whose Linux user is another site's. A restore that was refused because the site's
  # user was taken used to leave its record behind, and nothing else: no home, no virtual
  # host, no user. Every step below goes by the record's user and identifier - and those are
  # the OTHER site's: its account, its PHP, its Node.js application - and, where the record
  # was copied from that site's own archive, its home. Of such a record the record is all
  # there is, so the record is all that goes.
  if lib_domain_account_foreign "$domain"; then
    lib_warn "${domain} is on record as running as ${D_USER}, and that account's home is $(getent passwd "$D_USER" | cut -d: -f6): another site's"
    lib_note "nothing but the record exists of ${domain} - a restore that was refused left it - so the record is put away and nothing else is touched"
    lib_confirm "Put the record of ${domain} away?" n || lib_die "Removal cancelled" "" "re-run with --yes to skip the question"
    if (( OPT_DRY_RUN )); then lib_info "[dry-run] would put the record of ${domain} away"; return 0; fi
    mkdir -p "${STATE_DIR}/archive/domains" && chmod 0700 "${STATE_DIR}/archive/domains"
    mv "$(lib_domain_state_dir "$domain")" "${STATE_DIR}/archive/domains/${domain}.$(lib_ts)" 2>/dev/null || rm -rf "$(lib_domain_state_dir "$domain")"
    # the lists that are written from the sites on record
    lib_domain_logrotate_regen
    lib_domain_fail2ban_regen
    lib_sitefw_regen
    lib_manifest_set '.updated_at' "$(lib_iso_now)"
    lib_ok "The record of ${domain} is put away (${STATE_DIR}/archive/domains/); ${D_USER} and the site it belongs to are as they were"
    return 0
  fi
  lib_tr "This will remove ${domain}"
  printf '\n%s%s%s\n' "$C_BLD" "$LIB_TR" "$C_RST"
  lib_note "vhost + listener maps (archived), $( (( keep_files )) && printf 'files KEPT' || printf "files ${D_HOME} and logs $(lib_domain_log_dir "$domain") DELETED"), $( (( keep_db )) && printf 'database KEPT' || printf 'database DROPPED'), $( (( keep_ssl )) && printf 'certificate KEPT' || printf 'certificate deleted')"
  lib_note "a safety backup (files + database) is written to ${BACKUP_ROOT}/${domain}/ first"
  if lib_mail_installed && lib_mail_domain_standalone "$domain"; then
    lib_note "the mail of ${domain} is a mail domain of its own here and stays as it is (setup.sh mail domain del ${domain})"
  elif lib_mail_installed && lib_mail_domain_has_traces "$domain"; then
    lib_warn "Every mailbox of ${domain} and all of its mail is deleted too, and the safety backup does NOT include it"
    lib_note "to keep the mail, turn it off instead and leave the site: setup.sh mail disable ${domain}"
  fi
  if lib_app_state_load "$domain"; then
    local other=""
    other="$(_app_port_claimed_by "$APP_PORT" "$domain" || true)"
    if [[ -n "$other" ]]; then lib_warn "${other} also sends requests to 127.0.0.1:${APP_PORT}; they fail once this application is gone"; fi
    lib_note "its Node.js application and $(lib_app_unit_name "$D_IDENT") are stopped and removed"
    _app_site_lock "$domain"   # not while a deploy of it is still running
  fi
  lib_confirm "Continue?" n || lib_die "Removal cancelled" "" "re-run with --yes to skip the question"
  lib_steps_begin 9
  lib_rollback_clear

  lib_step "Scheduled tasks"
  lib_cron_remove "wpcron:${domain}"
  lib_cron_remove_prefix "job:${domain}:"
  lib_cron_remove_prefix "imported:${domain}:"
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

  # after the backup, so what is deleted here was saved a moment ago
  lib_step "Mail"
  # traces, not the flag: a domain whose mail was turned off still has its mailbox lines, and
  # a mailbox line is a login that works from anywhere until it is taken away
  if lib_mail_installed && lib_mail_domain_standalone "$domain"; then
    # added with "mail domain add", before or beside the site: that mail was never the site's,
    # and it is not what "remove this site" was asked to delete
    lib_info "the mail of ${domain} does not belong to the site and was left alone"
  elif lib_mail_installed && lib_mail_domain_has_traces "$domain"; then
    lib_mail_domain_purge "$domain"
    if (( ! OPT_DRY_RUN )); then
      lib_json_set "$(lib_domain_json "$domain")" '.mail.enabled = false' 2>/dev/null || true
    fi
    lib_mail_tables_apply || lib_warn "the mail tables could not be rebuilt: ${MAIL_LAST_ERROR}"
    lib_ok "mailboxes, mail, DKIM key and certificate removed"
    lib_note "At your DNS provider, the records for ${domain} can go too (MX, mail.${domain}, SPF, DKIM, _dmarc)"
  else
    lib_info "this site had no mail"
  fi

  lib_step "Database"
  if (( keep_db )); then lib_info "database kept (--keep-db)"; else lib_db_drop_for_domain "$domain"; fi

  lib_step "Certificate"
  if (( keep_ssl )); then lib_info "certificate kept (--keep-ssl)"; else lib_ssl_delete "$domain"; lib_ok "certificate removed"; fi

  lib_step "Files and system user"
  if (( keep_files )); then
    lib_info "files, logs and user kept (--keep-files)"
  else
    lib_rm "$D_HOME" "$(lib_domain_log_dir "$domain")" "$(lib_harden_php_ini_dir "$domain")"
    lib_rm "${OLS_CACHE_DIR}/${domain}"
    if (( ! OPT_DRY_RUN )) && id -u "$D_USER" >/dev/null 2>&1; then
      # until they are gone: userdel refuses a user something still runs as, and the account
      # left behind then stands in the way of a new site of that name
      _domain_rename_quiet_user "$D_USER" || true
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
  lib_sitefw_regen
  lib_manifest_set '.updated_at' "$(lib_iso_now)"
  lib_tr "Removed ${domain}"
  printf '\n%s%s%s%s  ' "$C_BLD" "$C_GRN" "$LIB_TR" "$C_RST"
  lib_tr "(state archived in ${STATE_DIR}/archive/domains/, backup in ${BACKUP_ROOT}/${domain}/)"
  printf '%s\n\n' "$LIB_TR"
  while read -r a; do
    [[ -n "$a" ]] && lib_warn "${a} still redirects to ${domain}, which is no longer here: setup.sh redirect del ${a}"
  done < <(lib_redirects_to "$domain")
  return 0
}
