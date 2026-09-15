#!/usr/bin/env bash
# =============================================================================
#  setup.sh - Production VPS provisioning & site management
#
#  lomp = the LOMP stack, named the way LAMP and LEMP are:
#           L  Linux         Ubuntu 22.04 / 24.04
#           O  OpenLiteSpeed the web server (official LiteSpeed repository)
#           M  MariaDB       the database
#           P  PHP           as LSPHP, OpenLiteSpeed's LSAPI build
#
#  Stack : the four above, plus Redis, Let's Encrypt, Fail2ban, UFW,
#          Cloudflare real-IP, backups and monitoring
#  Layout: setup.sh (entry point) + lib/*.sh (modules, functions prefixed lib_)
#
#  Usage : sudo ./setup.sh help
# =============================================================================
set -Eeuo pipefail
shopt -s lastpipe        # "render | lib_write_file" must run the writer in this shell (LIB_FILE_CHANGED)
umask 022
export LC_ALL=C.UTF-8 LANG=C.UTF-8

readonly SCRIPT_VERSION="1.0.0"

# =============================================================================
#  USER CONFIGURATION - adjust to taste (command-line flags override these)
# =============================================================================
TIMEZONE="Europe/Istanbul"
ADMIN_PORT="7080"            # OpenLiteSpeed WebAdmin port (change it with --admin-port)
PHP_VERSION="8.3"            # default LSPHP version (e.g. 8.2, 8.3, 8.4)
ADMIN_ACCESS="tunnel"        # how the WebAdmin panel is reachable:
                             #   tunnel = closed to the internet, use an SSH tunnel (safest,
                             #            works with a dynamic IP) -> setup.sh panel
                             #   ip     = only from ADMIN_ALLOWED_IP (needs a static address)
                             #   open   = reachable from anywhere (not recommended)
ADMIN_ALLOWED_IP=""          # only used when ADMIN_ACCESS=ip: your IP/CIDR, not the server's
DEFAULT_EMAIL=""             # Let's Encrypt / notifications default address
SSH_PORT=""                  # only set to CHANGE the SSH port (empty = keep)
DB_BUFFER_PERCENT=""         # innodb_buffer_pool_size as % of RAM (empty = auto)
REDIS_MAX_PERCENT=""         # redis maxmemory as % of RAM (empty = auto)
BACKUP_KEEP="7"              # number of local backups to keep per domain
BACKUP_SCHEDULE=""           # e.g. "daily 03:00" (empty = no scheduled backups)
FAIL2BAN_IGNORE_IP=""        # extra IPs/CIDRs fail2ban must never ban
# =============================================================================
#  END OF USER CONFIGURATION
# =============================================================================

# ---- Target versions (informational, shown by --version) --------------------
readonly TARGET_OLS_VERSION="latest stable from the LiteSpeed official repository (1.9.x at the time of writing)"
readonly TARGET_MARIADB_JAMMY="10.6 (Ubuntu 22.04 package)"
readonly TARGET_MARIADB_NOBLE="10.11 (Ubuntu 24.04 package)"

# ---- Fixed paths (see spec section 22) --------------------------------------
readonly STATE_DIR="/root/.server-setup"
readonly SITES_ROOT="/home"
readonly LSWS_HOME="/usr/local/lsws"
readonly LOG_FILE="/var/log/server_setup.log"
readonly BACKUP_ROOT="/var/backups/server-setup"
readonly ACME_ROOT="/var/www/acme"
readonly SSL_DEPLOY_DIR="/etc/server-setup/ssl"
readonly SYSCTL_FILE="/etc/sysctl.d/99-production-server.conf"
readonly LIMITS_FILE="/etc/security/limits.d/99-production-server.conf"
readonly MARIADB_TUNED_FILE="/etc/mysql/mariadb.conf.d/60-production-tuned.cnf"
readonly FAIL2BAN_JAIL_FILE="/etc/fail2ban/jail.d/server-setup.conf"
readonly FAIL2BAN_WEB_JAIL_FILE="/etc/fail2ban/jail.d/server-setup-web.conf"
readonly FAIL2BAN_FILTER_DIR="/etc/fail2ban/filter.d"
readonly CRON_FILE="/etc/cron.d/server-setup"
readonly CERTBOT_DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/99-server-setup-ols.sh"
readonly LOGROTATE_SITES_FILE="/etc/logrotate.d/ols-sites"
readonly LOGROTATE_SELF_FILE="/etc/logrotate.d/server-setup"
readonly INSTALL_DIR="/usr/local/lib/lompstack"
readonly BIN_LINK="/usr/local/sbin/lompstack"
readonly BIN_SHORT="/usr/local/sbin/lomp"      # short alias; cron and hooks use BIN_LINK
readonly LOCK_FILE="/run/lock/server-setup.lock"

# ---- Global runtime flags ----------------------------------------------------
OPT_YES=0
OPT_DRY_RUN=0
OPT_QUIET=0
OPT_VERBOSE=0
OPT_NO_COLOR=0
OPT_JSON=0
OPT_NON_INTERACTIVE=0

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
readonly SCRIPT_PATH SCRIPT_DIR

# ---- Load modules ------------------------------------------------------------
_ss_load_module() {
  local file="${SCRIPT_DIR}/lib/$1.sh"
  if [[ ! -r "$file" ]]; then
    printf 'ERROR: module %s is missing. Expected layout: setup.sh + lib/*.sh\n' "$file" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$file"
}
for _m in common system ols php db ssl domain proxy app cloudflare backup monitor install menu; do
  _ss_load_module "$_m"
done
unset _m


lib_version() {
  cat <<EOF
setup.sh ${SCRIPT_VERSION}
  Target OpenLiteSpeed : ${TARGET_OLS_VERSION}
  Target PHP           : LSPHP ${PHP_VERSION} (LiteSpeed repository)
  Target MariaDB       : ${TARGET_MARIADB_JAMMY} / ${TARGET_MARIADB_NOBLE}
  Supported OS         : Ubuntu 22.04 (jammy), Ubuntu 24.04 (noble)
EOF
}

# =============================================================================
#  Argument pre-processing: extract global flags, keep the rest
# =============================================================================
declare -a ARGS=()
_ss_parse_globals() {
  local a=""
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --yes|-y)            OPT_YES=1 ;;
      --dry-run)           OPT_DRY_RUN=1 ;;
      --quiet|-q)          OPT_QUIET=1 ;;
      --verbose|-v)        OPT_VERBOSE=1 ;;
      --no-color|--no-colour) OPT_NO_COLOR=1 ;;
      --json)              OPT_JSON=1; OPT_QUIET=1 ;;
      --non-interactive)   OPT_NON_INTERACTIVE=1 ;;
      --version|-V)        lib_version; exit 0 ;;
      --help|-h)           lib_usage; exit 0 ;;
      *)                   ARGS+=("$a") ;;
    esac
  done
}
_ss_parse_globals "$@"

# =============================================================================
#  Dispatcher
# =============================================================================
main() {
  local cmd="${ARGS[0]:-}"
  # a bare "lomp" on a terminal opens the menu; piped or non-interactive it prints help,
  # so scripts and cron keep getting predictable output
  if [[ -z "$cmd" ]]; then
    if [[ -t 0 && -t 1 ]] && (( ! OPT_NON_INTERACTIVE )); then cmd="menu"; else cmd="help"; fi
  fi
  local -a rest=()
  if ((${#ARGS[@]} > 1)); then rest=("${ARGS[@]:1}"); fi

  # Shorthand: "setup.sh domain.com" == "setup.sh add domain.com"
  if [[ "$cmd" != -* && "$cmd" == *.* ]] && lib_domain_valid "$cmd"; then
    rest=("$cmd" "${rest[@]}")
    cmd="add"
  fi

  case "$cmd" in
    help|-h|--help) lib_usage; return 0 ;;
    version)        lib_version; return 0 ;;
  esac

  lib_common_init_colors
  lib_require_root
  lib_check_os
  lib_log_file_init
  lib_tmp_root_init      # must run here, not inside $(lib_mktemp): that is a subshell
  # every command except "install" works from the settings chosen at install time;
  # "install" merges its own flags with the manifest in lib_install_parse_args
  if [[ "$cmd" != "install" ]]; then lib_params_load; fi

  # read-only commands (and "notify --send", used by hooks/PAM) do not take the lock
  case "$cmd" in
    list|status|doctor|credentials|logs|menu) ;;
    panel) if [[ "${rest[0]:-open}" != "status" ]]; then lib_lock; fi ;;
    notify) [[ " ${rest[*]:-} " == *" --send "* ]] || lib_lock ;;
    proxy)  if [[ "${rest[0]:-list}" != "list" && "${rest[0]:-list}" != "help" ]]; then lib_lock; fi ;;
    # "app deploy" can build for minutes: it takes the site's own lock (lib/app.sh) instead
    app)    case "${rest[0]:-list}" in list|status|logs|deploy|help|-h|--help) ;; *) lib_lock ;; esac ;;
    *) lib_lock ;;
  esac

  lib_log_write INFO "=== setup.sh ${SCRIPT_VERSION} command='${cmd}' args='${rest[*]:-}' dry-run=${OPT_DRY_RUN} ==="

  # commands that report problems through their exit status use "|| exit" so the
  # ERR trap (meant for unexpected failures) stays quiet
  case "$cmd" in
    install)        lib_install_main "${rest[@]}" ;;
    add)            lib_domain_add_main "${rest[@]}" ;;
    db)             lib_db_main "${rest[@]}" ;;
    proxy)          lib_proxy_main "${rest[@]}" ;;
    app)            lib_app_main "${rest[@]}" ;;
    remove|delete)  lib_domain_remove_main "${rest[@]}" ;;
    list)           lib_domain_list_main "${rest[@]}" ;;
    status)         lib_status_main "${rest[@]}" ;;
    doctor)         lib_doctor_main "${rest[@]}" || exit 1 ;;
    credentials)    lib_domain_credentials_main "${rest[@]}" ;;
    optimize)       lib_optimize_main "${rest[@]}" ;;
    backup)         lib_backup_main "${rest[@]}" ;;
    restore)        lib_restore_main "${rest[@]}" ;;
    renew-ssl)      lib_ssl_renew_main "${rest[@]}" ;;
    update)         lib_update_main "${rest[@]}" ;;
    update-cf-ips)  lib_cf_update_main "${rest[@]}" || exit 1 ;;
    notify)         lib_notify_main "${rest[@]}" ;;
    panel)          lib_panel_main "${rest[@]}" ;;
    menu)           lib_menu_main "${rest[@]}" ;;
    self-update)    lib_selfupdate_main "${rest[@]}" ;;
    logs)           lib_domain_logs_main "${rest[@]}" ;;
    healthcheck)    lib_healthcheck_main "${rest[@]}" ;;   # internal (cron)
    *)
      lib_error "Unknown command: ${cmd}"
      printf '\n'
      lib_usage
      exit 2
      ;;
  esac
  return 0
}

main
exit 0
