#!/usr/bin/env bash
# lib/menu.sh - user interface: the command reference and the interactive menu shown
#               when the command is run with no arguments on a terminal. The menu is a
#               launcher: every entry runs the ordinary command as a child process, so
#               each action takes the lock, starts from clean state and cannot take the
#               menu down when it fails.

lib_usage() {
  cat <<'USAGE_EOF'
setup.sh - production VPS provisioning for OpenLiteSpeed + LSPHP + MariaDB + Redis

USAGE
  sudo lomp                             # no arguments: interactive menu
  sudo lomp <command>                   # after install: short name, works anywhere
  sudo ./setup.sh <command> [arguments] [global flags]
  sudo ./setup.sh domain.com            # shorthand for: add domain.com

COMMANDS
  install [opts]                Provision the server (idempotent, re-run safe)
      --php 8.3                 Default LSPHP version
      --timezone Europe/Istanbul
      --admin-port 7080         WebAdmin port (OpenLiteSpeed default; any free port works)
      --admin-access MODE       WebAdmin reachability: tunnel (default) | ip | open
      --admin-ip 1.2.3.4        YOUR address (not the server's); implies --admin-access ip
                                Use "auto" to take it from the current SSH session
      --email admin@x.com       Default e-mail (Let's Encrypt / notifications)
      --ssh-port 2222           Change SSH port (UFW is opened first)
      --non-interactive         Never ask questions, use defaults
      --with-node [--node 20]   Node.js LTS (NodeSource) + PM2 + PM2 logrotate
      --with-python             python3-venv + pip (venv-per-app policy)
      --with-netdata            Netdata bound to localhost (+ admin IP)
      --cloudflare              Trust Cloudflare proxies (real client IP)
      --cf-api-token TOKEN      Store Cloudflare API token (DNS-01 / fail2ban)
      --mariadb 11.4            Install MariaDB from the official repository
      --redis-persist           Enable Redis persistence (default: cache only)
      --backup-schedule "daily 03:00"
      --auto-reboot             Allow unattended-upgrades to reboot
      --skip-upgrade            Skip apt upgrade during install
  add <domain> [opts]           Create a site (user, dirs, vhost, SSL)
      --email a@b.c  --no-ssl  --www  --www-primary  --php 8.3
      --memory 256M  --upload 64M  --php-children N
      --proxy 127.0.0.1:3000  --static  --wordpress  --cloudflare
      --wildcard  --staging  --hsts-preload
      --wp-title "Title" --wp-admin admin --wp-email a@b.c --wp-locale en_US
  db <domain>                   Create (or show) the MariaDB database for a site
  remove <domain> [opts]        Remove a site  (--keep-db --keep-files --keep-ssl)
  list                          Table of sites (--json)
  status                        Services, versions, resources, sites (--json)
  doctor                        Deep health check (--json, --quiet)
  credentials <domain>|--all    Show stored credentials (never logged)
  optimize                      Re-measure the system and re-tune (shows a diff)
  backup <domain>|--all [opts]  --remote --encrypt --keep N --dry-run
         --configure-remote     Configure rsync/rclone destination
  restore <domain> --file <archive>   [--no-db] [--no-files]
  renew-ssl [domain] [opts]     --force --all --staging --wildcard
  update                        Safe package update + ordered service restarts
  self-update [--from DIR]      Pull the latest lompstack and refresh the installed
                                copy. Changes nothing on the server itself.
  update-cf-ips                 Refresh Cloudflare IP ranges
  notify [opts]                 --email a@b.c [--smtp-host H --smtp-port P
                                --smtp-user U --smtp-pass P --smtp-from F]
                                --telegram-token T --telegram-chat ID
                                --webhook URL   --ssh-login on|off  --test  --show
  panel [open|status|close]     Open the WebAdmin panel. Bare "panel" opens the port
                                for the address of your current SSH session for 60
                                minutes and prints the URL, user and password; it
                                closes again on its own. Options: --ip auto|IP|any,
                                --minutes N (0 = stay open). "status" shows the
                                current state and the SSH tunnel command, "close"
                                shuts it immediately. Built for dynamic IPs.
  logs <domain> [--access|--error] [-n LINES]
  menu                          Interactive menu (also what a bare "lomp" opens)
  help                          This text

GLOBAL FLAGS
  --yes / -y        Assume yes for confirmations
  --dry-run         Show what would change; touch nothing
  --quiet / -q      Only warnings and errors
  --verbose / -v    Show command output
  --no-color        Disable colours
  --json            Machine-readable output (status, doctor, list)
  --non-interactive Never prompt (defaults are used)
  --version         Show script and target component versions

PATHS
  Sites          /home/<domain>/{public_html,logs,private,backups}
  State          /root/.server-setup/   (0700; credentials live here)
  Log            /var/log/server_setup.log
  Backups        /var/backups/server-setup/
USAGE_EOF
}

MENU_CMD=""   # how the user invoked us, for the prompts we echo back

_menu_cmd_name() { if [[ -x "$BIN_SHORT" ]]; then basename "$BIN_SHORT"; else basename "$BIN_LINK"; fi; }

_menu_rule() { printf '%s%s%s\n' "$C_DIM" "------------------------------------------------------------" "$C_RST"; }

_menu_pause() {
  local _ignored=""
  printf '\n%sPress Enter to go back to the menu...%s' "$C_DIM" "$C_RST"
  read -r _ignored || true
  printf '\n'
}

# Run an ordinary lompstack command as a child. Its failure is reported, not fatal:
# the menu keeps running so the operator can read the error and try something else.
_menu_run() {
  local rc=0
  printf '\n%s%s$ %s %s%s\n\n' "$C_BLD" "$C_CYN" "$MENU_CMD" "$*" "$C_RST"
  "$SCRIPT_PATH" "$@" </dev/tty || rc=$?
  if (( rc != 0 )); then printf '\n%sThat command exited with status %s.%s\n' "$C_YEL" "$rc" "$C_RST"; fi
  _menu_pause
}

# Ask for a domain, offering the registered ones by number. Prints the choice.
_menu_pick_domain() {
  local -a doms=()
  local d="" i=1 choice=""
  while read -r d; do [[ -n "$d" ]] && doms+=("$d"); done < <(lib_domains_list)
  if ((${#doms[@]} == 0)); then
    printf '%sNo sites have been added yet.%s\n' "$C_YEL" "$C_RST" >&2
    return 1
  fi
  printf '\n%sWhich site?%s\n' "$C_BLD" "$C_RST" >&2
  for d in "${doms[@]}"; do printf '  %2d) %s\n' "$i" "$d" >&2; i=$((i + 1)); done
  printf '   0) cancel\n' >&2
  printf '%sNumber: %s' "$C_BLD" "$C_RST" >&2
  read -r choice </dev/tty || return 1
  [[ "$choice" =~ ^[0-9]+$ ]] || return 1
  (( choice >= 1 && choice <= ${#doms[@]} )) || return 1
  printf '%s' "${doms[$((choice - 1))]}"
}

_menu_ask() {   # _menu_ask VAR "prompt" ["default"]
  local -n _out="$1"
  local prompt="$2" def="${3:-}" ans=""
  printf '%s%s%s%s: ' "$C_BLD" "$prompt" "${def:+ [$def]}" "$C_RST"
  read -r ans </dev/tty || ans=""
  _out="${ans:-$def}"
}

# One compact line of context, so the whole menu still fits an 80x24 terminal.
_menu_header() {
  local sites=0 d="" svc="" label=""
  while read -r d; do [[ -n "$d" ]] && sites=$((sites + 1)); done < <(lib_domains_list)
  printf '\n %s%slompstack%s  %s  %s site(s) ' "$C_BLD" "$C_CYN" "$C_RST" "$(hostname -s 2>/dev/null || hostname)" "$sites"
  for svc in lsws:web mariadb:db redis-server:cache fail2ban:f2b; do
    label="${svc#*:}"; svc="${svc%%:*}"
    if lib_service_active "$svc"; then printf ' %s%s:up%s' "$C_GRN" "$label" "$C_RST"
    else printf ' %s%s:DOWN%s' "$C_RED" "$label" "$C_RST"; fi
  done
  printf '\n'
  _menu_rule
}

_menu_group() { printf ' %s%s%s\n' "$C_BLD" "$1" "$C_RST"; }
_menu_item()  { printf '  %s%2s%s) %s\n' "$C_CYN" "$1" "$C_RST" "$2"; }

# =============================================================================
#  Menu shown before the server is provisioned
# =============================================================================
_menu_not_installed() {
  local choice="" email=""
  while true; do
    printf '\n %s%slompstack%s  this server is not provisioned yet\n' "$C_BLD" "$C_CYN" "$C_RST"
    _menu_rule
    _menu_item 1 "Install the server (OpenLiteSpeed, PHP, MariaDB, Redis, firewall)"
    _menu_item 2 "Show what the installation would do, changing nothing (dry run)"
    _menu_item 3 "Command reference"
    _menu_item 0 "Exit"
    printf '\n%sChoice: %s' "$C_BLD" "$C_RST"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_ask email "E-mail for Let's Encrypt and alerts" "$DEFAULT_EMAIL"
         if [[ -n "$email" ]]; then _menu_run install --email "$email"; else _menu_run install; fi ;;
      2) _menu_run install --dry-run ;;
      3) lib_usage | ${PAGER:-less} 2>/dev/null || lib_usage; _menu_pause ;;
      0|q|Q|"") return 0 ;;
      *) printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

# =============================================================================
#  Main menu
# =============================================================================
lib_menu_main() {
  MENU_CMD="$(_menu_cmd_name)"
  if ! [[ -t 0 && -t 1 ]] || (( OPT_NON_INTERACTIVE )); then
    lib_usage
    return 0
  fi
  lib_require_tools
  if ! lib_installed; then _menu_not_installed; return 0; fi

  local choice="" domain="" answer=""
  while true; do
    _menu_header
    _menu_group "SITES"
    _menu_item  1 "List sites"
    _menu_item  2 "Add a site"
    _menu_item  3 "Site credentials"
    _menu_item  4 "Site logs"
    _menu_item  5 "Create database"
    _menu_item  6 "Remove a site"
    _menu_group "SERVER"
    _menu_item  7 "Status"
    _menu_item  8 "Health check"
    _menu_item  9 "Open WebAdmin panel"
    _menu_item 10 "Renew certificates"
    _menu_item 11 "Back up sites"
    _menu_item 12 "Restore a site"
    _menu_group "MAINTENANCE"
    _menu_item 13 "Update packages"
    _menu_item 14 "Update lompstack"
    _menu_item 15 "Re-tune to hardware"
    _menu_item 16 "Notifications"
    _menu_item 17 "Command reference"
    _menu_item  0 "Exit"
    printf '\n%sChoice: %s' "$C_BLD" "$C_RST"
    read -r choice </dev/tty || return 0

    case "$choice" in
      1) _menu_run list ;;
      2) _menu_add_site ;;
      3) domain="$(_menu_pick_domain)" && _menu_run credentials "$domain" || _menu_pause ;;
      4) domain="$(_menu_pick_domain)" && _menu_run logs "$domain" || _menu_pause ;;
      5) domain="$(_menu_pick_domain)" && _menu_run db "$domain" || _menu_pause ;;
      6) _menu_remove_site ;;
      7) _menu_run status ;;
      8) _menu_run doctor ;;
      9) _menu_run panel ;;
      10) _menu_run renew-ssl --all ;;
      11) _menu_backup ;;
      12) _menu_restore ;;
      13) _menu_run update ;;
      14) _menu_run self-update ;;
      15) _menu_run optimize ;;
      16) _menu_run notify --show ;;
      17) lib_usage | ${PAGER:-less} 2>/dev/null || lib_usage; _menu_pause ;;
      0|q|Q|"") printf '\n'; return 0 ;;
      *) printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

_menu_add_site() {
  local domain="" kind="" email="" www="" ssl="" proxy=""
  local -a args=()
  _menu_ask domain "Domain (without www, e.g. example.com)"
  [[ -n "$domain" ]] || return 0
  if ! lib_domain_valid "${domain,,}"; then
    printf '%s"%s" is not a valid domain name.%s\n' "$C_YEL" "$domain" "$C_RST"
    _menu_pause; return 0
  fi
  args=("$domain")

  printf '\n%sWhat kind of site?%s\n' "$C_BLD" "$C_RST"
  printf '  1) PHP site (default)\n  2) WordPress, installed and configured\n'
  printf '  3) Static files only\n  4) Reverse proxy to a local app (Node, Python, ...)\n'
  _menu_ask kind "Choice" "1"
  case "$kind" in
    2) args+=(--wordpress) ;;
    3) args+=(--static) ;;
    4) _menu_ask proxy "Application address" "127.0.0.1:3000"; args+=(--proxy "$proxy") ;;
    *) ;;
  esac

  _menu_ask www "Also serve www.${domain}? (y/n)" "y"
  [[ "${www,,}" == y* ]] && args+=(--www)

  _menu_ask ssl "Request a Let's Encrypt certificate now? DNS must already point here (y/n)" "y"
  [[ "${ssl,,}" == y* ]] || args+=(--no-ssl)

  _menu_ask email "Contact e-mail" "$DEFAULT_EMAIL"
  [[ -n "$email" ]] && args+=(--email "$email")

  _menu_run add "${args[@]}"
}

_menu_remove_site() {
  local domain="" keep=""
  local -a args=()
  domain="$(_menu_pick_domain)" || { _menu_pause; return 0; }
  args=("$domain")
  printf '\n%sRemoving %s deletes its files, database and certificate.%s\n' "$C_YEL" "$domain" "$C_RST"
  printf '%sA safety backup is taken first.%s\n' "$C_DIM" "$C_RST"
  _menu_ask keep "Keep the database? (y/n)" "n"
  [[ "${keep,,}" == y* ]] && args+=(--keep-db)
  _menu_ask keep "Keep the files? (y/n)" "n"
  [[ "${keep,,}" == y* ]] && args+=(--keep-files)
  _menu_run remove "${args[@]}"
}

_menu_backup() {
  local what="" enc=""
  local -a args=()
  printf '\n  1) Every site\n  2) One site\n'
  _menu_ask what "Choice" "1"
  if [[ "$what" == "2" ]]; then
    local domain=""
    domain="$(_menu_pick_domain)" || { _menu_pause; return 0; }
    args=("$domain")
  else
    args=(--all)
  fi
  _menu_ask enc "Encrypt the archive? (y/n)" "n"
  [[ "${enc,,}" == y* ]] && args+=(--encrypt)
  _menu_run backup "${args[@]}"
}

_menu_restore() {
  local domain="" file=""
  domain="$(_menu_pick_domain)" || { _menu_pause; return 0; }
  printf '\n%sAvailable archives for %s:%s\n' "$C_BLD" "$domain" "$C_RST"
  if ! find "${BACKUP_ROOT}/${domain}" -maxdepth 1 -name '*.tar.gz*' -printf '  %p\n' 2>/dev/null | sort | head -20; then
    printf '  (none found under %s)\n' "${BACKUP_ROOT}/${domain}"
  fi
  _menu_ask file "Full path of the archive to restore"
  [[ -n "$file" ]] || return 0
  _menu_run restore "$domain" --file "$file"
}
