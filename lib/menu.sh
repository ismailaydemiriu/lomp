#!/usr/bin/env bash
# lib/menu.sh - user interface: the command reference and the interactive menu shown
#               when the command is run with no arguments on a terminal. The menu is a
#               launcher: every entry runs the ordinary command as a child process, so
#               each action takes the lock, starts from clean state and cannot take the
#               menu down when it fails.

lib_usage() {
  cat <<'USAGE_EOF'
lomp - LOMP stack: Linux + OpenLiteSpeed + MariaDB + PHP (LSPHP), with Redis and TLS.
       Production VPS provisioning and site management for Ubuntu 22.04 / 24.04.

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
      --with-node [--node 24]   Node.js (NodeSource) + PM2; an installed major is kept
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
      --proxy 127.0.0.1:3000  --static  --wordpress  --cloudflare  --no-db
      --wildcard  --staging  --hsts-preload
      --wp-title "Title" --wp-admin admin --wp-email a@b.c --wp-locale en_US
      --node [--port N] [--start "npm start" | --script dist/main.js] [--git URL [--branch B]]
                                Node.js site: PM2 runs the app as the site's user and
                                OpenLiteSpeed proxies to it (a free port from 3000 up);
                                with --git the application is deployed right away
                                Every site gets its own database and MariaDB user
                                unless --no-db is given.
  db <domain>                   Create (or show) the MariaDB database for a site
  db list                       Every site's database, user and size (no passwords)
  proxy list [<domain>]         Path proxies of every site and whether their app answers
  proxy add <domain> <path> <host:port>
                                Publish an app under a path of an existing site, in any
                                mode: proxy add example.com /api/ 127.0.0.1:3001
  proxy remove <domain> <path>  Stop proxying that path
  app list                      Node.js applications: status, CPU, memory, restarts (--json)
  app status|start|stop|restart <domain>
  app logs <domain> [--out|--error] [-n LINES]
  app deploy <domain> [--git URL [--branch B]]
                                Pull from git (the first time: clone), install dependencies
                                when they changed, build with a memory limit, restart
  app deploy-key <domain>       Create or print the site's read-only key for a private repo
  app set <domain> [--port N] [--start CMD | --script FILE] [--memory 512M|none] [--no-git]
  app env <domain> list [--show] | set NAME | unset NAME... | import-db
                                Values come from stdin or a hidden prompt, never from
                                the command line; import-db adds DB_* and DATABASE_URL
  remove <domain> [opts]        Remove a site  (--keep-db --keep-files --keep-ssl; alias: delete)
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
  # Ctrl-C belongs to the child (stopping a followed log, say). The terminal sends it to the
  # menu as well, which used to end the whole menu. ':' rather than '' so the child, which
  # does not inherit a handler, still gets the default action and stops.
  trap ':' INT
  "$SCRIPT_PATH" "$@" </dev/tty || rc=$?
  trap - INT
  if (( rc == 130 )); then printf '\n%sStopped.%s\n' "$C_DIM" "$C_RST"
  elif (( rc != 0 )); then printf '\n%sThat command exited with status %s.%s\n' "$C_YEL" "$rc" "$C_RST"; fi
  _menu_pause
}

# Ask for a domain, offering the registered ones by number. Prints the choice.
# "apps" offers only the sites that run a Node.js application.
_menu_pick_domain() {   # [apps]
  local -a doms=()
  local d="" i=1 choice="" only="${1:-}"
  while read -r d; do
    [[ -n "$d" ]] || continue
    if [[ "$only" == "apps" ]] && ! lib_app_state_load "$d"; then continue; fi
    doms+=("$d")
  done < <(lib_domains_list)
  if ((${#doms[@]} == 0)); then
    if [[ "$only" == "apps" ]]; then printf '%sNo Node.js applications yet: add a site and choose "Node.js app".%s\n' "$C_YEL" "$C_RST" >&2
    else printf '%sNo sites have been added yet.%s\n' "$C_YEL" "$C_RST" >&2; fi
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
    _menu_item  5 "Databases"
    _menu_item  6 "Node.js apps (PM2) and path proxies"
    _menu_item  7 "Remove a site"
    _menu_group "SERVER"
    _menu_item  8 "Status"
    _menu_item  9 "Health check"
    _menu_item 10 "Open WebAdmin panel"
    _menu_item 11 "Renew certificates"
    _menu_item 12 "Back up sites"
    _menu_item 13 "Restore a site"
    _menu_group "MAINTENANCE"
    _menu_item 14 "Update packages"
    _menu_item 15 "Update lompstack"
    _menu_item 16 "Re-tune to hardware"
    _menu_item 17 "Notifications"
    _menu_item 18 "Optional components (Node.js, Python, Netdata)"
    _menu_item 19 "Command reference"
    _menu_item  0 "Exit"
    printf '\n%sChoice: %s' "$C_BLD" "$C_RST"
    read -r choice </dev/tty || return 0

    case "$choice" in
      1) _menu_run list ;;
      2) _menu_add_site ;;
      3) domain="$(_menu_pick_domain)" && _menu_run credentials "$domain" || _menu_pause ;;
      4) domain="$(_menu_pick_domain)" && _menu_run logs "$domain" || _menu_pause ;;
      5) _menu_databases ;;
      6) _menu_apps ;;
      7) _menu_remove_site ;;
      8) _menu_run status ;;
      9) _menu_run doctor ;;
      10) _menu_run panel ;;
      11) _menu_run renew-ssl --all ;;
      12) _menu_backup ;;
      13) _menu_restore ;;
      14) _menu_run update ;;
      15) _menu_run self-update ;;
      16) _menu_run optimize ;;
      17) _menu_run notify --show ;;
      18) _menu_runtimes ;;
      19) lib_usage | ${PAGER:-less} 2>/dev/null || lib_usage; _menu_pause ;;
      0|q|Q|"") printf '\n'; return 0 ;;
      *) printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

_menu_add_site() {
  local domain="" kind="" email="" www="" ssl="" proxy="" port="" start=""
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
  printf '  3) Static files only\n  4) Node.js app, run by PM2\n'
  printf '  5) Reverse proxy to an app you run yourself (host:port)\n'
  _menu_ask kind "Choice" "1"
  case "$kind" in
    2) args+=(--wordpress) ;;
    3) args+=(--static) ;;
    4) _menu_ask port "Port the app listens on (it gets it as PORT)" "$(lib_app_port_pick 2>/dev/null || true)"
       _menu_ask start "Start command (runs without a shell)" "npm start"
       args+=(--node)
       if [[ -n "$port" ]]; then args+=(--port "$port"); fi
       if [[ -n "$start" && "$start" != "npm start" ]]; then args+=(--start "$start"); fi ;;
    5) _menu_ask proxy "Application address" "127.0.0.1:3000"; args+=(--proxy "$proxy") ;;
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

# Like _menu_run, but the child's standard input is the given value instead of the terminal.
# Used for secrets: the value is piped in and never appears on a command line.
_menu_run_input() {   # value args...
  local value="$1" rc=0
  shift
  printf '\n%s%s$ %s %s%s\n\n' "$C_BLD" "$C_CYN" "$MENU_CMD" "$*" "$C_RST"
  trap ':' INT
  printf '%s' "$value" | "$SCRIPT_PATH" "$@" || rc=$?
  trap - INT
  if (( rc != 0 )); then printf '\n%sThat command exited with status %s.%s\n' "$C_YEL" "$rc" "$C_RST"; fi
  _menu_pause
}

_menu_databases() {
  local choice="" domain=""
  while true; do
    printf '\n %sDATABASES%s\n' "$C_BLD" "$C_RST"
    _menu_rule
    _menu_item 1 "List databases (sizes, no passwords)"
    _menu_item 2 "Create or show the database of a site"
    _menu_item 0 "Back"
    printf '\n%sChoice: %s' "$C_BLD" "$C_RST"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run db list ;;
      2) domain="$(_menu_pick_domain)" && _menu_run db "$domain" || _menu_pause ;;
      0|q|Q|"") return 0 ;;
      *) printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

_menu_apps() {
  local choice="" domain=""
  while true; do
    printf '\n %sNODE.JS APPS (PM2)%s   every site runs its own PM2 as its own user\n' "$C_BLD" "$C_RST"
    _menu_rule
    _menu_item  1 "List applications"
    _menu_item  2 "Add a site (choose \"Node.js app\")"
    _menu_item  3 "Deploy: install dependencies, build, restart"
    _menu_item  4 "Start"
    _menu_item  5 "Stop"
    _menu_item  6 "Restart"
    _menu_item  7 "Follow the logs"
    _menu_item  8 "Status of one application"
    _menu_item  9 "Environment variables"
    _menu_item 10 "Port, start command, memory limit"
    _menu_item 11 "Path proxies (example.com/api -> an app)"
    _menu_item 12 "Deploy from a Git repository (URL, branch)"
    _menu_item 13 "Deploy key for a private repository"
    _menu_item  0 "Back"
    printf '\n%sChoice: %s' "$C_BLD" "$C_RST"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run app list ;;
      2) _menu_add_site ;;
      3) domain="$(_menu_pick_domain apps)" && _menu_run app deploy "$domain" || _menu_pause ;;
      4) domain="$(_menu_pick_domain apps)" && _menu_run app start "$domain" || _menu_pause ;;
      5) domain="$(_menu_pick_domain apps)" && _menu_run app stop "$domain" || _menu_pause ;;
      6) domain="$(_menu_pick_domain apps)" && _menu_run app restart "$domain" || _menu_pause ;;
      7) domain="$(_menu_pick_domain apps)" && _menu_run app logs "$domain" || _menu_pause ;;
      8) domain="$(_menu_pick_domain apps)" && _menu_run app status "$domain" || _menu_pause ;;
      9) domain="$(_menu_pick_domain apps)" && _menu_app_env "$domain" || _menu_pause ;;
      10) domain="$(_menu_pick_domain apps)" && _menu_app_set "$domain" || _menu_pause ;;
      11) _menu_proxies ;;
      12) domain="$(_menu_pick_domain apps)" && _menu_app_git "$domain" || _menu_pause ;;
      13) domain="$(_menu_pick_domain apps)" && _menu_run app deploy-key "$domain" || _menu_pause ;;
      0|q|Q|"") return 0 ;;
      *) printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

_menu_app_git() {   # domain
  local domain="$1" url="" branch=""
  lib_app_state_load "$domain" || return 0
  printf '\n%sA private repository needs the deploy key first (item 13).%s\n' "$C_DIM" "$C_RST"
  _menu_ask url "Repository URL (https://host/owner/repo.git or git@host:owner/repo.git)" "$APP_GIT_URL"
  if [[ -z "$url" ]]; then _menu_pause; return 0; fi
  _menu_ask branch "Branch (empty: the repository's default)" "$APP_GIT_BRANCH"
  if [[ -n "$branch" ]]; then _menu_run app deploy "$domain" --git "$url" --branch "$branch"
  else _menu_run app deploy "$domain" --git "$url"; fi
}

_menu_app_env() {   # domain
  local domain="$1" choice="" name="" value=""
  while true; do
    printf '\n %sENVIRONMENT OF %s%s   stored root-only, never logged\n' "$C_BLD" "$domain" "$C_RST"
    _menu_rule
    _menu_item 1 "List the names"
    _menu_item 2 "Set a variable (the value is typed hidden)"
    _menu_item 3 "Remove a variable"
    _menu_item 4 "Add this site's database login (DB_*, DATABASE_URL)"
    _menu_item 0 "Back"
    printf '\n%sChoice: %s' "$C_BLD" "$C_RST"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run app env "$domain" list ;;
      2) _menu_ask name "Name (A-Z, 0-9 and _)"
         if [[ -n "$name" ]]; then
           printf '%sValue (hidden): %s' "$C_BLD" "$C_RST"
           IFS= read -r -s value </dev/tty || value=""
           printf '\n'
           _menu_run_input "$value" app env "$domain" set "$name"
           value=""
         fi ;;
      3) _menu_ask name "Name to remove"
         if [[ -n "$name" ]]; then _menu_run app env "$domain" unset "$name"; fi ;;
      4) _menu_run app env "$domain" import-db ;;
      0|q|Q|"") return 0 ;;
      *) printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

_menu_app_set() {   # domain
  local domain="$1" port="" start="" mem="" current=""
  local -a args=()
  lib_app_state_load "$domain" || return 0
  current="${APP_SCRIPT:-$APP_START}"
  printf '\n%sPress Enter to keep a value.%s\n' "$C_DIM" "$C_RST"
  _menu_ask port "Port" "$APP_PORT"
  _menu_ask start "Start command, or a file such as dist/main.js" "$current"
  _menu_ask mem "Memory limit (e.g. 512M, or none)" "${APP_MEMORY:-none}"
  if [[ -n "$port" && "$port" != "$APP_PORT" ]]; then args+=(--port "$port"); fi
  if [[ -n "$start" && "$start" != "$current" ]]; then
    if [[ "$start" =~ ^[^[:space:]]+\.(c|m)?js$ ]]; then args+=(--script "$start"); else args+=(--start "$start"); fi
  fi
  if [[ -n "$mem" && "$mem" != "${APP_MEMORY:-none}" ]]; then args+=(--memory "$mem"); fi
  if ((${#args[@]} == 0)); then printf '%sNothing changed.%s\n' "$C_DIM" "$C_RST"; _menu_pause; return 0; fi
  _menu_run app set "$domain" "${args[@]}"
}

_menu_proxies() {
  local choice="" domain="" path="" target=""
  while true; do
    printf '\n %sPATH PROXIES%s   example.com/api/... -> an application, the rest of the site stays\n' "$C_BLD" "$C_RST"
    _menu_rule
    _menu_item 1 "List path proxies"
    _menu_item 2 "Add a path proxy"
    _menu_item 3 "Remove a path proxy"
    _menu_item 0 "Back"
    printf '\n%sChoice: %s' "$C_BLD" "$C_RST"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run proxy list ;;
      2) if domain="$(_menu_pick_domain)"; then
           _menu_ask path "Path" "/api/"
           _menu_ask target "Application address" "127.0.0.1:$(lib_app_port_pick 2>/dev/null || printf '3001')"
           _menu_run proxy add "$domain" "$path" "$target"
         else _menu_pause; fi ;;
      3) if domain="$(_menu_pick_domain)"; then
           _menu_ask path "Path to remove (e.g. /api/)"
           if [[ -n "$path" ]]; then _menu_run proxy remove "$domain" "$path"; else _menu_pause; fi
         else _menu_pause; fi ;;
      0|q|Q|"") return 0 ;;
      *) printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
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

# Optional runtimes are never installed unless asked for, on the command line with
# --with-node / --with-python / --with-netdata, or from here.
_menu_runtimes() {
  local choice="" ver="" node_v="" py_v="" nd=""
  while true; do
    node_v="$(lib_manifest_get '.components.node')"
    py_v="$(lib_manifest_get '.components.python')"
    nd="$(lib_manifest_get '.components.netdata')"
    printf '\n %sOPTIONAL COMPONENTS%s   (nothing here is installed by default)\n' "$C_BLD" "$C_RST"
    _menu_rule
    printf '  %s1%s) Node.js + PM2        %s\n' "$C_CYN" "$C_RST" \
      "$( [[ -n "$node_v" ]] && printf '%sinstalled %s%s' "$C_GRN" "$node_v" "$C_RST" || printf '%snot installed%s' "$C_DIM" "$C_RST")"
    printf '  %s2%s) Python venv + pip    %s\n' "$C_CYN" "$C_RST" \
      "$( [[ -n "$py_v" ]] && printf '%sinstalled %s%s' "$C_GRN" "$py_v" "$C_RST" || printf '%snot installed%s' "$C_DIM" "$C_RST")"
    printf '  %s3%s) Netdata monitoring   %s\n' "$C_CYN" "$C_RST" \
      "$( [[ "$nd" == "true" ]] && printf '%sinstalled%s' "$C_GRN" "$C_RST" || printf '%snot installed%s' "$C_DIM" "$C_RST")"
    printf '  %s0%s) Back\n' "$C_CYN" "$C_RST"
    printf '\n%sChoice: %s' "$C_BLD" "$C_RST"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_ask ver "Node.js major version" "$(lib_install_node_major_resolve)"
         _menu_run install --with-node --node "$ver" --skip-upgrade ;;
      2) _menu_run install --with-python --skip-upgrade ;;
      3) _menu_run install --with-netdata --skip-upgrade ;;
      0|q|Q|"") return 0 ;;
      *) printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
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
