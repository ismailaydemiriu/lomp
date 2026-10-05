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
      --with-mail [--mail-hostname mail.example.com]
                                Mail server (Postfix, Dovecot, Rspamd) for the sites of
                                this server; needs its own name, an A record and a PTR
      --mail-only [--mail-hostname mail.example.com]
                                A server for mail alone: the same mail server, and the web
                                stack only because the webmail needs one. Domains get mail
                                ("mail domain add"), not sites. --role web undoes it
      --cloudflare              Trust Cloudflare proxies (real client IP)
      --cf-api-token TOKEN      Store Cloudflare API token (DNS-01 / fail2ban); "-" reads it
                                from stdin so it stays out of the process list
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
      --mail [--mailbox info] [--mail-quota 2G]
                                Give the site its own mail while creating it
      --wp-title "Title" --wp-admin admin --wp-email a@b.c --wp-locale en_US
      --node [--port N] [--start "npm start" | --script dist/main.js] [--git URL [--branch B]]
                                Node.js site: PM2 runs the app as the site's user and
                                OpenLiteSpeed proxies to it (a free port from 3000 up);
                                with --git the application is deployed right away
                                Every site gets its own database and MariaDB user
                                unless --no-db is given.
  wordpress <domain>            Put the files of the latest WordPress (wordpress.org/latest.zip)
                                into the public_html of a PHP site that exists, as the site's
                                own user; the installation is finished in the browser, and
                                the wp-config.php it writes is closed to 0640 within a minute
                                ("add --wordpress" installs it whole instead)
  db <domain>                   Create (or show) the MariaDB database for a site
  db list                       Every site's database, user and size (no passwords)
  db passwd <domain>            A new random password for the site's database user
  proxy list [<domain>]         Path proxies of every site and whether their app answers
  proxy add <domain> <path> <host:port>
                                Publish an app under a path of an existing site, in any
                                mode: proxy add example.com /api/ 127.0.0.1:3001
  proxy remove <domain> <path>  Stop proxying that path
  app list                      Node.js applications: status, CPU, memory, restarts (--json)
  app status <domain>
  app start|stop|restart <domain> [--process NAME]
  app logs <domain> [--process NAME] [--out|--error] [-n LINES]
  app worker <domain> list | remove NAME | run NAME
  app worker <domain> add NAME --start CMD [--cwd DIR] [--port N] [--memory 256M]
  app worker <domain> add NAME --cron "*/5 * * * *" --start CMD [--timeout 1h]
                                Workers (queue consumers, bots) run next to the app under
                                its PM2; with --cron, cron starts a job, one run at a time
  app deploy <domain> [--git URL [--branch B]]
                                Pull from git (the first time: clone), install dependencies
                                when they changed, build with a memory limit, restart
  app deploy-key <domain>       Create or print the site's read-only key for a private repo
  app set <domain> [--port N] [--start CMD | --script FILE] [--memory 512M|none] [--no-git]
  app env <domain> list [--show] | set NAME | unset NAME... | import-db
                                Values come from stdin or a hidden prompt, never from
                                the command line; import-db adds DB_* and DATABASE_URL
  mail domain add <domain> [--mailbox info] [--quota 2G]
                                Mail for a domain that is no site of this server (its web
                                site is elsewhere, or it has none): no Linux user, no vhost
  mail domain add <domain> --to <you@example.com> [--address info,sales] [--catch-all]
                                The same without a mailbox of its own: its addresses are
                                delivered into a mailbox that exists - one inbox for several
                                domains - and that mailbox may send as them
  mail domain list              Every domain with mail: site or mail only, mailboxes, aliases
  mail domain del <domain> [--dns-cleanup] [--no-backup]
                                Remove a mail domain and all of its mail, after a last backup
  mail enable <domain> [--mailbox info] [--quota 2G]
                                Give a site its own mail: DKIM key, certificate for
                                mail.<domain>, and the DNS records to add
                                (--to, --address and --catch-all work here as well)
  mail disable <domain> [--delete-data]
  mail box add|passwd|quota|list|del|kick <user@domain>
                                Passwords come from stdin or a hidden prompt, never from
                                the command line; "kick" ends the open sessions of a mailbox
  mail alias add|del|list <alias@domain> [target,...]
                                An address that goes somewhere else; a mailbox here that it
                                goes to may also send as it. "@<domain>" as the alias is a
                                catch-all: every address of the domain with no line of its own
  mail dns <domain> [--check] [--json]   What to put in DNS, and whether it is there
  mail dns <domain> --apply [--replace-mx]
                                Write those records into Cloudflare with the stored token.
                                A foreign MX or a second SPF record is reported, never
                                overwritten; only records lompstack wrote are ever removed
  mail status|test|queue        The mail stack: what runs, reverse DNS, outgoing port 25
  mail cert [domain]            Ask again for a certificate that did not come
  mail regenerate               Rewrite every mail configuration file and restart the stack
  mail webmail on|off <domain>  A webmail at webmail.<domain>. Every domain that has one
                                shares a single Roundcube and a single PHP process, so the
                                twentieth costs a vhost and nothing else
  webmail status                What runs, and for which domains (people change their own
                                password in it, under Settings)
  webmail update [version]      Take a newer Roundcube (it also happens by itself, daily)
  webmail forget <user@domain>|@<domain>|--gone
                                Remove what the webmail still keeps for a mailbox that is gone
                                (address book, identities, settings). Deleting a mailbox does
                                this by itself; the command is for one that went before lomp
                                did, or while the database was down. --gone is every such
                                address at once: it lists them (doctor names the first few)
                                and asks before it removes them
  webmail uninstall | purge     Remove it; "purge" drops its database too
  mail dkim status <domain>     Which key this domain signs with
  mail dkim rotate <domain> [--abort]
                                Make a second key and publish its record; signing moves to it
                                by itself once DNS carries it, and the old key is kept a week
                                so that mail already sent still verifies
  mail backup <domain> [--keep N]     The mail on its own: mailboxes, aliases, the DKIM key
  mail restore <domain> [--file A]    and the mail itself, back into the same mailboxes
                                with the same passwords and the same key. A mailbox that is
                                not empty is asked about first: the copy replaces what is
                                there. Add --yes to answer it in a script
  mail relay set --host H [--port 587] --user U [--spf-include NAME] [--tls LEVEL] | relay off
                                Send outgoing mail through another server where port 25
                                is blocked; the password is read from stdin
  remove <domain> [opts]        Remove a site  (--keep-db --keep-files --keep-ssl; alias: delete)
  list                          Table of sites (--json)
  status                        Services, versions, resources, sites (--json)
  doctor                        Deep health check (--json, --quiet)
  credentials <domain>|--all    Show stored credentials (never logged)
  fix-owner <domain>|--all      Hand a site's files back to its own user after uploading as
                                root (WinSCP, scp). Only what is someone else's changes;
                                logs/ and the file modes stay as they are. It happens by itself
                                within a minute of an upload; the command is for right now
  fix-owner --auto on|off       Stop that (root keeps files of its own in a site), or start it
  optimize                      Re-measure the system and re-tune (shows a diff)
  harden <domain>|--all         Limit what a PHP shell in a site can do: no process execution
                                from PHP, open_basedir, no scripts in upload directories, and
                                only DNS, web, MariaDB, Redis and its own application reachable
                                on this machine (--allow-exec, --allow-upload-php per site;
                                "harden status"; --firewall on|off)
  scan <domain>|--all [--wide]  Look through a site's PHP files for what web shells are made of
                                (eval of decoded or request data, commands made of the request,
                                packed code) and list the files to open. Changes nothing;
                                --wide also lists every use of eval, base64_decode and exec
  php-cleanup [--php 8.3]       Undo an "apt-get install lsphp83*": purge what it added beyond
                                lomp's own PHP packages (compiler, debug symbols, sources,
                                the distribution's PHP). Shows the list and asks first
  backup <domain>|--all [opts]  --remote --encrypt --keep N --no-mail --dry-run
                                A domain with mail gets a second archive beside the site's,
                                with a retention of its own: mail is measured in gigabytes
         --configure-remote     Configure rsync/rclone destination
         --schedule "daily 03:00" [--encrypt] [--remote] [--keep N] [--no-mail]
                                Back up every site automatically ("weekly sun 04:00", "hourly"
                                or a cron expression work too); --schedule off stops it
  restore <domain> --file <archive>   [--no-db] [--no-files] [--no-mail] [--mail-file F]
                                The mail comes from the newest mail archive next to it, with
                                the same mailbox passwords and the same DKIM key
  renew-ssl [domain] [opts]     --force --all --staging --wildcard
  ssl [status]                  Every certificate, sites and mail: whether there is one, how
                                long it has, and whether it renews by itself (what runs
                                certbot, the deploy hook, each renewal file). Changes nothing;
                                it also says when Cloudflare can go to Full (strict)
  ssl test                      Rehearse every renewal (certbot renew --dry-run)
  ssl fix                       Put automatic renewal back: the timer or cron entry, the hook
  update                        Safe package update + ordered service restarts; also applies
                                what a newer lompstack changes (scheduled tasks, site homes, logs)
  self-update [--from DIR]      Pull the latest lompstack and refresh the installed
                                copy, which then applies what it changes on the server.
                                No package is touched (update does that).
  update-cf-ips                 Refresh Cloudflare IP ranges
  firewall [status]             Whether the web ports answer everyone or Cloudflare only
  firewall --web-cloudflare-only   Close 80/443 to everything but Cloudflare's ranges, so
                                nobody can walk around the edge by using the server's address.
                                Needs a Cloudflare token: certificates then come over DNS-01
  firewall --web-open           Open them again
  htaccess-check                Reload OpenLiteSpeed when a site's .htaccess has changed
                                (cron runs it every minute; OpenLiteSpeed reads it only on load),
                                hand what root uploaded into a site to the site's user, and
                                close to 0640 a wp-config.php WordPress left more open
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

# The registered sites a menu entry offers, one per line: all of them, with "apps" those that
# run a Node.js application, with "php" those PHP runs in.
_menu_domains() {   # [apps|php]
  local d="" only="${1:-}"
  while read -r d; do
    [[ -n "$d" ]] || continue
    if [[ "$only" == "apps" ]] && ! lib_app_state_load "$d"; then continue; fi
    if [[ "$only" == "php" ]]; then
      case "$(lib_json_get "$(lib_domain_json "$d")" '.mode')" in php|wordpress|"") ;; *) continue ;; esac
    fi
    printf '%s\n' "$d"
  done < <(lib_domains_list)
  return 0
}

# Ask for a domain, offering those by number. Prints the choice.
_menu_pick_domain() {   # [apps|php]
  local -a doms=()
  local d="" i=1 choice="" only="${1:-}"
  mapfile -t doms < <(_menu_domains "$only")
  if ((${#doms[@]} == 0)); then
    if [[ "$only" == "apps" ]]; then printf '%sNo Node.js applications yet: add a site and choose "Node.js app".%s\n' "$C_YEL" "$C_RST" >&2
    elif [[ "$only" == "php" ]]; then printf '%sNo PHP sites yet: add a site and choose "PHP site".%s\n' "$C_YEL" "$C_RST" >&2
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
    _menu_item 4 "Install a mail-only server (mail and webmail for your domains, no web sites)"
    _menu_item 0 "Exit"
    printf '\n%sChoice: %s' "$C_BLD" "$C_RST"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_ask email "E-mail for Let's Encrypt and alerts" "$DEFAULT_EMAIL"
         if [[ -n "$email" ]]; then _menu_run install --email "$email"; else _menu_run install; fi ;;
      2) _menu_run install --dry-run ;;
      3) lib_usage | ${PAGER:-less} 2>/dev/null || lib_usage; _menu_pause ;;
      4) _menu_install_mail_only ;;
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
  # a server installed for mail alone has no site to list: its menu is the mail menu
  if lib_server_mail_only; then _menu_mail top; return 0; fi

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
    _menu_item 20 "Mail: domains, mailboxes, DNS"
    _menu_item 21 "Fix file ownership (after uploading as root)"
    _menu_item 23 "Harden sites against PHP shells"
    _menu_item 24 "Scan sites for PHP shells (eval, base64, exec)"
    _menu_item 25 "Download WordPress into a site (you finish the setup in the browser)"
    _menu_group "SERVER"
    _menu_item  8 "Status"
    _menu_item  9 "Health check"
    _menu_item 10 "Open WebAdmin panel"
    _menu_item 11 "Certificates (which exist, automatic renewal, a site's first one)"
    _menu_item 12 "Back up sites (now, or automatically)"
    _menu_item 13 "Restore a site"
    _menu_group "MAINTENANCE"
    _menu_item 14 "Update packages"
    _menu_item 15 "Update lompstack"
    _menu_item 16 "Re-tune to hardware"
    _menu_item 17 "Notifications"
    _menu_item 18 "Optional components (Node.js, Python, Netdata, Mail)"
    _menu_item 22 "Remove extra PHP packages (after apt install lsphp83*)"
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
      20) _menu_mail ;;
      21) _menu_fix_owner ;;
      23) _menu_harden ;;
      24) _menu_scan ;;
      25) _menu_wordpress ;;
      8) _menu_run status ;;
      9) _menu_run doctor ;;
      10) _menu_run panel ;;
      11) _menu_certificates ;;
      12) _menu_backup ;;
      13) _menu_restore ;;
      14) _menu_run update ;;
      15) _menu_run self-update ;;
      16) _menu_run optimize ;;
      22) _menu_run php-cleanup ;;
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

  # "n" by default: a site usually goes in before its DNS moves here. The certificate comes
  # later, from "Certificates" in this menu.
  _menu_ask ssl "Request a Let's Encrypt certificate now? DNS must already point here (y/n)" "n"
  [[ "${ssl,,}" == y* ]] || args+=(--no-ssl)

  _menu_ask email "Contact e-mail" "info@${domain,,}"
  [[ -n "$email" ]] && args+=(--email "$email")

  # only where this server actually runs mail; otherwise the question is an offer it cannot keep
  if lib_mail_installed; then
    local mail="" mailbox=""
    _menu_ask mail "Give this site its own mail (mailboxes at @${domain})? (y/n)" "n"
    if [[ "${mail,,}" == y* ]]; then
      _menu_ask mailbox "First mailbox name (before the @)" "info"
      args+=(--mail)
      [[ -n "$mailbox" ]] && args+=(--mailbox "$mailbox")
    fi
  fi

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
    _menu_item 3 "Give a site's database a new random password"
    _menu_item 0 "Back"
    printf '\n%sChoice: %s' "$C_BLD" "$C_RST"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run db list ;;
      2) domain="$(_menu_pick_domain)" && _menu_run db "$domain" || _menu_pause ;;
      3) domain="$(_menu_pick_domain)" && _menu_run db passwd "$domain" || _menu_pause ;;
      0|q|Q|"") return 0 ;;
      *) printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

# A site added without a certificate is not asking for one, so "renew-ssl --all" passes it
# over. Item 2 is how such a site gets its first certificate once its DNS points here.
_menu_certificates() {
  local choice="" domain=""
  while true; do
    printf '\n %sCERTIFICATES%s   renewal is automatic; item 1 shows whether it is working\n' "$C_BLD" "$C_RST"
    _menu_rule
    _menu_item 1 "Check: which certificates exist, days left, is renewal automatic"
    _menu_item 2 "Get a certificate for a site (its DNS must point here)"
    _menu_item 3 "Renew every certificate now"
    _menu_item 4 "Rehearse the automatic renewal (replaces nothing)"
    _menu_item 5 "Switch automatic renewal back on (timer or cron, deploy hook)"
    _menu_item 0 "Back"
    printf '\n%sChoice: %s' "$C_BLD" "$C_RST"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run ssl status ;;
      2) domain="$(_menu_pick_domain)" && _menu_run renew-ssl "$domain" || _menu_pause ;;
      3) _menu_run renew-ssl --all ;;
      4) _menu_run ssl test ;;
      5) _menu_run ssl fix ;;
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
    _menu_item 14 "Workers and scheduled jobs (queues, bots, cron)"
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
      14) domain="$(_menu_pick_domain apps)" && _menu_workers "$domain" || _menu_pause ;;
      0|q|Q|"") return 0 ;;
      *) printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

# A worker of the site, by number: jobs only with "job", long-running ones with "process".
_menu_pick_worker() {   # domain [process|job]
  local -a names=()
  local n="" i=1 choice=""
  while IFS= read -r n; do
    if [[ -n "$n" ]]; then names+=("$n"); fi
  done < <(jq -r --arg k "${2:-}" '.[] | select($k == "" or (($k == "job") == ((.cron // "") != ""))) | .name' <<<"$(lib_app_workers_json "$1")" || true)
  if ((${#names[@]} == 0)); then printf '%sThere is nothing to choose from here yet.%s\n' "$C_YEL" "$C_RST" >&2; return 1; fi
  printf '\n%sWhich one?%s\n' "$C_BLD" "$C_RST" >&2
  for n in "${names[@]}"; do printf '  %2d) %s\n' "$i" "$n" >&2; i=$((i + 1)); done
  printf '   0) cancel\n%sNumber: %s' "$C_BLD" "$C_RST" >&2
  read -r choice </dev/tty || return 1
  [[ "$choice" =~ ^[0-9]+$ ]] || return 1
  (( choice >= 1 && choice <= ${#names[@]} )) || return 1
  printf '%s' "${names[$((choice - 1))]}"
}

_menu_workers() {   # domain
  local domain="$1" choice="" name="" start="" cron="" port="" cwd=""
  local -a args=()
  while true; do
    printf '\n %sWORKERS AND JOBS OF %s%s   run as the site user, next to the application\n' "$C_BLD" "$domain" "$C_RST"
    _menu_rule
    _menu_item 1 "List"
    _menu_item 2 "Add a background worker (queue consumer, bot)"
    _menu_item 3 "Add a scheduled job (cron)"
    _menu_item 4 "Run a scheduled job now"
    _menu_item 5 "Follow the logs of one"
    _menu_item 6 "Restart a worker"
    _menu_item 7 "Stop one"
    _menu_item 8 "Start one"
    _menu_item 9 "Remove one"
    _menu_item 0 "Back"
    printf '\n%sChoice: %s' "$C_BLD" "$C_RST"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run app worker "$domain" list ;;
      2) _menu_ask name "Name (a-z, 0-9 and -)"
         _menu_ask start "Command, run without a shell (e.g. node worker.js)"
         _menu_ask cwd "Directory, inside the site's home" "app"
         _menu_ask port "Port, only if it listens on one"
         if [[ -n "$name" && -n "$start" ]]; then
           args=(app worker "$domain" add "$name" --start "$start" --cwd "${cwd:-app}")
           if [[ -n "$port" ]]; then args+=(--port "$port"); fi
           _menu_run "${args[@]}"
         else _menu_pause; fi ;;
      3) _menu_ask name "Name (a-z, 0-9 and -)"
         _menu_ask cron "Schedule: minute hour day month weekday" "*/5 * * * *"
         _menu_ask start "Command, run without a shell (e.g. npm run cleanup)"
         _menu_ask cwd "Directory, inside the site's home" "app"
         if [[ -n "$name" && -n "$start" && -n "$cron" ]]; then
           _menu_run app worker "$domain" add "$name" --cron "$cron" --start "$start" --cwd "${cwd:-app}"
         else _menu_pause; fi ;;
      4) name="$(_menu_pick_worker "$domain" job)" && _menu_run app worker "$domain" run "$name" || _menu_pause ;;
      5) name="$(_menu_pick_worker "$domain")" && _menu_run app logs "$domain" --process "$name" || _menu_pause ;;
      6) name="$(_menu_pick_worker "$domain" process)" && _menu_run app restart "$domain" --process "$name" || _menu_pause ;;
      7) name="$(_menu_pick_worker "$domain")" && _menu_run app stop "$domain" --process "$name" || _menu_pause ;;
      8) name="$(_menu_pick_worker "$domain")" && _menu_run app start "$domain" --process "$name" || _menu_pause ;;
      9) name="$(_menu_pick_worker "$domain")" && _menu_run app worker "$domain" remove "$name" || _menu_pause ;;
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

# Files uploaded as root (WinSCP, scp) stay root's, and PHP, which runs as the site's own
# user, cannot change them. This hands them over, every site at once unless one is picked.
_menu_fix_owner() {
  local what="" domain="" auto="on"
  lib_domain_fix_owner_auto_enabled || auto="off"
  printf '\n  %s\n' "Files uploaded as root go to their site's own user; what already is the site's stays as it is."
  if [[ "$auto" == "on" ]]; then printf '  %s\n' "It happens by itself within a minute of an upload; this does it right now."; fi
  printf '  1) Every site\n  2) One site\n'
  if [[ "$auto" == "on" ]]; then printf '  3) Stop doing it automatically (root keeps files of its own in a site)\n'
  else printf '  3) Do it automatically again, within a minute of an upload (now: off)\n'; fi
  _menu_ask what "Choice" "1"
  if [[ "$what" == "3" ]]; then
    if [[ "$auto" == "on" ]]; then _menu_run fix-owner --auto off; else _menu_run fix-owner --auto on; fi
  elif [[ "$what" == "2" ]]; then
    domain="$(_menu_pick_domain)" || { _menu_pause; return 0; }
    _menu_run fix-owner "$domain"
  else
    _menu_run fix-owner --all
  fi
}

# Every site at once, or one - and for one, whether it keeps process execution.
_menu_harden() {
  local what="" domain="" keep=""
  printf '\n  %s\n  %s\n' "PHP in a site can then start no process, read only its own files and run no script in an upload directory;" "its user reaches only DNS, the web server, MariaDB and Redis on this machine."
  printf '  1) Every site\n  2) One site\n  3) Show what is set\n'
  _menu_ask what "Choice" "1"
  case "$what" in
    3) _menu_run harden status ;;
    2) domain="$(_menu_pick_domain)" || { _menu_pause; return 0; }
       _menu_ask keep "Does this site need exec/proc_open (y/N)" "n"
       if [[ "${keep,,}" == y* ]]; then _menu_run harden "$domain" --allow-exec; else _menu_run harden "$domain"; fi ;;
    *) _menu_run harden --all ;;
  esac
}

# Every site at once, or one - and whether to list every use of the functions shells are made
# of, which on a WordPress site is a long list of honest plugins.
_menu_scan() {
  local what="" domain="" wide=""
  local -a args=()
  printf '\n  %s\n' "Reads the PHP files for what web shells are made of and lists the files to open. It changes nothing."
  printf '  1) Every site\n  2) One site\n'
  _menu_ask what "Choice" "1"
  if [[ "$what" == "2" ]]; then
    domain="$(_menu_pick_domain)" || { _menu_pause; return 0; }
    args=("$domain")
  else
    args=(--all)
  fi
  _menu_ask wide "Also list every use of eval, base64_decode and exec? Plugins use them too (y/N)" "n"
  if [[ "${wide,,}" == y* ]]; then args+=(--wide); fi
  _menu_run scan "${args[@]}"
}

# WordPress's files into a site that is already there; "Add a site" with kind 2 installs it
# whole instead. The command asks before it puts them next to something.
_menu_wordpress() {
  local domain=""
  printf '\n  %s\n  %s\n' "The latest WordPress (wordpress.org/latest.zip) goes straight into the site's public_html, as the" \
    "site's own user. You finish the installation in the browser; the database login is printed for it."
  domain="$(_menu_pick_domain php)" || { _menu_pause; return 0; }
  _menu_run wordpress "$domain"
}

# The domains a mail menu entry offers, one per line: those whose mail is on, or with "all"
# every domain that has mail here at all - one whose mail was turned off included.
_menu_mail_domains() {   # [all]
  local d=""
  if [[ "${1:-}" != "all" ]]; then lib_mail_domains; return 0; fi
  while read -r d; do
    [[ -n "$d" ]] || continue
    if _mail_domain_listed "$d"; then printf '%s\n' "$d"; fi
  done < <(lib_mail_domains_known)
  return 0
}

# Ask for one of them, offered by number. Prints the choice.
_menu_pick_mail_domain() {   # [all]
  local -a doms=()
  local d="" i=1 choice=""
  mapfile -t doms < <(_menu_mail_domains "${1:-}")
  if ((${#doms[@]} == 0)); then
    printf '%sNo domain has mail yet: "Add a domain" gives one its mail.%s\n' "$C_YEL" "$C_RST" >&2
    return 1
  fi
  printf '\n%sWhich domain?%s\n' "$C_BLD" "$C_RST" >&2
  for d in "${doms[@]}"; do printf '  %2d) %s\n' "$i" "$d" >&2; i=$((i + 1)); done
  printf '   0) cancel\n' >&2
  printf '%sNumber: %s' "$C_BLD" "$C_RST" >&2
  read -r choice </dev/tty || return 1
  [[ "$choice" =~ ^[0-9]+$ ]] || return 1
  (( choice >= 1 && choice <= ${#doms[@]} )) || return 1
  printf '%s' "${doms[$((choice - 1))]}"
}

# Mail for a domain. A site of this server gets its mail switched on; any other domain is
# added for its mail alone. Either way the mail goes into a mailbox of the domain's own, or
# into one that exists already - which is how one inbox comes to hold several domains.
_menu_mail_add_domain() {
  local domain="" how="" box="" quota="" to="" addrs="" first=""
  local -a args=()
  _menu_ask domain "Domain (without www, e.g. example.com)"
  [[ -n "$domain" ]] || return 0
  domain="${domain,,}"
  if ! lib_domain_valid "$domain"; then
    printf '%s"%s" is not a valid domain name.%s\n' "$C_YEL" "$domain" "$C_RST"
    _menu_pause; return 0
  fi
  if lib_domain_registered "$domain" && ! lib_mail_domain_standalone "$domain"; then
    args=(mail enable "$domain")
  else
    args=(mail domain add "$domain")
    if ! lib_server_mail_only; then
      printf '\n  %s is not a site of this server: it is added for its mail alone (no site, no Linux user).\n' "$domain"
    fi
  fi
  first="$(lib_mail_boxes | head -n 1 || true)"
  printf '\n%sWhere does the mail of %s go?%s\n' "$C_BLD" "$domain" "$C_RST"
  printf '  1) Into a mailbox of its own (info@%s, with a password of its own)\n' "$domain"
  printf '  2) Into a mailbox that exists already - one inbox for several domains\n'
  _menu_ask how "Choice" "1"
  if [[ "$how" == "2" ]]; then
    if [[ -z "$first" ]]; then
      printf '%sThere is no mailbox on this server yet: the first domain needs one of its own.%s\n' "$C_YEL" "$C_RST"
      _menu_pause; return 0
    fi
    _menu_ask to "Deliver into which mailbox" "$first"
    [[ -n "$to" ]] || return 0
    _menu_ask addrs "Which addresses of ${domain}? Names with commas (info,sales), or * for every address" "info"
    args+=(--to "$to")
    if [[ "$addrs" == "*" ]]; then args+=(--catch-all)
    elif [[ -n "$addrs" ]]; then args+=(--address "$addrs"); fi
  else
    _menu_ask box 'Mailbox name (before the @), or a dash for none' "info"
    _menu_ask quota "Mailbox size" "2G"
    if [[ -n "$box" && "$box" != "-" ]]; then args+=(--mailbox "$box" --quota "$quota"); fi
  fi
  _menu_run "${args[@]}"
}

_menu_mail_webmail() {
  local what="" domain=""
  printf '\n  1) What runs, and for which domains\n  2) Switch it on for a domain (it answers at webmail.<domain>)\n  3) Switch it off for a domain\n'
  _menu_ask what "Choice" "1"
  if [[ "$what" == "2" ]]; then
    domain="$(_menu_pick_mail_domain)" || { _menu_pause; return 0; }
    _menu_run mail webmail on "$domain"
  elif [[ "$what" == "3" ]]; then
    domain="$(_menu_pick_mail_domain)" || { _menu_pause; return 0; }
    _menu_run mail webmail off "$domain"
  else
    _menu_run webmail status
  fi
}

# Turning mail off keeps every message and can be undone. Removing is for a mail domain only -
# a site's mail goes with the site - and takes a last backup before it deletes anything.
_menu_mail_off() {
  local domain="" what=""
  domain="$(_menu_pick_mail_domain all)" || { _menu_pause; return 0; }
  if ! lib_mail_domain_standalone "$domain"; then _menu_run mail disable "$domain"; return 0; fi
  printf '\n  1) Turn its mail off: no delivery and no login, every message stays, and it can be turned on again\n'
  printf '  2) Remove the domain with all of its mail (a last backup is taken first)\n'
  _menu_ask what "Choice" "1"
  if [[ "$what" == "2" ]]; then _menu_run mail domain del "$domain"
  else _menu_run mail disable "$domain"; fi
}

# Header of the mail menu when it is the server's own menu.
_menu_mail_header() {
  local n=0 d="" svc="" label=""
  while read -r d; do [[ -n "$d" ]] && n=$((n + 1)); done < <(lib_mail_domains)
  printf '\n %s%slompstack%s  %s  mail server, sends as %s  %s domain(s)\n ' "$C_BLD" "$C_CYN" "$C_RST" \
    "$(hostname -s 2>/dev/null || hostname)" "$(lib_mail_host)" "$n"
  for svc in postfix:smtp dovecot:imap rspamd:filter lsws:webmail mariadb:db fail2ban:f2b; do
    label="${svc#*:}"; svc="${svc%%:*}"
    if lib_service_active "$svc"; then printf ' %s%s:up%s' "$C_GRN" "$label" "$C_RST"
    else printf ' %s%s:DOWN%s' "$C_RED" "$label" "$C_RST"; fi
  done
  printf '\n'
  _menu_rule
}

# "top": this is the menu of a mail-only server, not a submenu of the sites' one.
_menu_mail() {   # [top]
  local top="${1:-}" choice="" domain="" box="" quota="" alias="" target=""
  while true; do
    if ! lib_mail_installed; then
      printf '\n  The mail server is not installed yet. Optional components (18) installs it.\n'
      _menu_pause
      return 0
    fi
    if [[ -n "$top" ]]; then _menu_mail_header
    else
      printf '\n %sMAIL%s   (this server sends as %s)\n' "$C_BLD" "$C_RST" "$(lib_mail_host)"
      _menu_rule
    fi
    _menu_item  1 "Domains that have mail here"
    _menu_item  2 "Add a domain (a mailbox of its own, or into one that exists)"
    _menu_item  3 "Mailboxes: who has one, its size, how full it is"
    _menu_item  4 "Add a mailbox"
    _menu_item  5 "Change a mailbox password"
    _menu_item  6 "Aliases: an address that is delivered into another mailbox"
    _menu_item  7 "What to put in DNS (and whether it is there)"
    _menu_item  8 "Can this server send? (reverse DNS, port 25)"
    _menu_item  9 "Webmail (on or off for a domain, or what runs)"
    _menu_item 10 "Turn mail off for a domain, or remove a mail domain"
    if [[ -n "$top" ]]; then
      _menu_item 11 "Server: status, health check, backups, updates"
      _menu_item  0 "Exit"
    else
      _menu_item  0 "Back"
    fi
    printf '\n%sChoice: %s' "$C_BLD" "$C_RST"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run mail domain list ;;
      2) _menu_mail_add_domain ;;
      3) _menu_run mail box list ;;
      4) domain="$(_menu_pick_mail_domain)" || { _menu_pause; continue; }
         _menu_ask box "Mailbox name (before the @)" "info"
         _menu_ask quota "Mailbox size" "2G"
         [[ -n "$box" ]] && _menu_run mail box add "${box}@${domain}" --quota "$quota" ;;
      5) _menu_ask box "Which address?"
         [[ -n "$box" ]] && _menu_run mail box passwd "$box" ;;
      6) _menu_ask alias "Alias address, or @domain for every address of a domain (empty to only list them)"
         if [[ -z "$alias" ]]; then _menu_run mail alias list
         else
           _menu_ask target "Where should it go? (an address, or several with commas)"
           [[ -n "$target" ]] && _menu_run mail alias add "$alias" "$target"
         fi ;;
      7) domain="$(_menu_pick_mail_domain)" || { _menu_pause; continue; }
         _menu_run mail dns "$domain" --check ;;
      8) _menu_run mail test ;;
      9) _menu_mail_webmail ;;
      10) _menu_mail_off ;;
      11) if [[ -n "$top" ]]; then _menu_mail_server
          else printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST"; fi ;;
      0|q|Q|"") [[ -n "$top" ]] && printf '\n'; return 0 ;;
      *) printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

# What a mail-only server needs besides its mail: the same commands the sites' menu offers,
# without the ones that are about sites.
_menu_mail_server() {
  local choice=""
  while true; do
    printf '\n %sSERVER%s\n' "$C_BLD" "$C_RST"
    _menu_rule
    _menu_item  1 "Status"
    _menu_item  2 "Health check"
    _menu_item  3 "Back up the mail (now, or automatically)"
    _menu_item  4 "Restore a domain's mail from a backup"
    _menu_item  5 "Update packages"
    _menu_item  6 "Update lompstack"
    _menu_item  7 "Re-tune to hardware"
    _menu_item  8 "Notifications"
    _menu_item  9 "Open WebAdmin panel"
    _menu_item 10 "Command reference"
    _menu_item 11 "Certificates: which exist, is renewal automatic"
    _menu_item  0 "Back"
    printf '\n%sChoice: %s' "$C_BLD" "$C_RST"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run status ;;
      2) _menu_run doctor ;;
      3) _menu_mail_backup ;;
      4) _menu_mail_restore ;;
      5) _menu_run update ;;
      6) _menu_run self-update ;;
      7) _menu_run optimize ;;
      8) _menu_run notify --show ;;
      9) _menu_run panel ;;
      10) lib_usage | ${PAGER:-less} 2>/dev/null || lib_usage; _menu_pause ;;
      11) _menu_run ssl status ;;
      0|q|Q|"") return 0 ;;
      *) printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

# A mail domain's backup is its mail: mailboxes with their password hashes, aliases, the DKIM
# key and every message, in one archive under BACKUP_ROOT/<domain>/.
_menu_mail_backup() {
  local what="" enc="" sched="" domain=""
  local -a args=()
  sched="$(lib_manifest_get '.backup.schedule' 2>/dev/null || true)"
  printf '\n  1) Every domain, now\n  2) One domain, now\n  3) Automatic backups (now: %s)\n' "${sched:-off}"
  _menu_ask what "Choice" "1"
  if [[ "$what" == "3" ]]; then _menu_backup_schedule; return 0; fi
  if [[ "$what" == "2" ]]; then
    domain="$(_menu_pick_mail_domain all)" || { _menu_pause; return 0; }
    args=("$domain")
  else
    args=(--all)
  fi
  _menu_ask enc "Encrypt the archive? (y/n)" "n"
  [[ "${enc,,}" == y* ]] && args+=(--encrypt)
  _menu_run backup "${args[@]}"
}

# The domain is typed, not picked: on a new server - the case a restore exists for - it is not
# a domain of this server yet, and the restore is what makes it one.
_menu_mail_restore() {
  local domain="" file=""
  _menu_ask domain "Domain whose mail to restore"
  [[ -n "$domain" ]] || return 0
  domain="${domain,,}"
  if ! lib_domain_valid "$domain"; then
    printf '%s"%s" is not a valid domain name.%s\n' "$C_YEL" "$domain" "$C_RST"
    _menu_pause; return 0
  fi
  printf '\n%sMail archives of %s:%s\n' "$C_BLD" "$domain" "$C_RST"
  if ! find "${BACKUP_ROOT}/${domain}" -maxdepth 1 -name "${domain}-mail-*.tar.gz*" ! -name '*.sha256' -printf '  %p\n' 2>/dev/null | sort | tail -20 | grep .; then
    printf '  (none found under %s - copy the archive there, or give its path below)\n' "${BACKUP_ROOT}/${domain}"
  fi
  _menu_ask file "Full path of the archive (empty: the newest one above)"
  if [[ -n "$file" ]]; then _menu_run mail restore "$domain" --file "$file"
  else _menu_run mail restore "$domain"; fi
}

# A mail-only server from the menu: the two things it cannot be installed without are asked
# for here, everything else has a default.
_menu_install_mail_only() {
  local email="" mh=""
  local -a args=(install --mail-only)
  printf '\n  A server for mail alone: Postfix, Dovecot, Rspamd and a webmail. Your domains get their\n'
  printf '  mail here; their web sites stay where they are. It needs a name of its own, like\n'
  printf '  mail.example.com, with an A record pointing here and a PTR record your provider sets.\n\n'
  _menu_ask mh "Name this server sends mail as" "$(hostname -f 2>/dev/null || true)"
  [[ -n "$mh" ]] || return 0
  _menu_ask email "E-mail for Let's Encrypt and alerts" "$DEFAULT_EMAIL"
  args+=(--mail-hostname "$mh")
  [[ -n "$email" ]] && args+=(--email "$email")
  _menu_run "${args[@]}"
}

# Optional components are never installed unless asked for, on the command line with
# --with-node / --with-python / --with-netdata / --with-mail, or from here.
_menu_runtimes() {
  local choice="" ver="" node_v="" py_v="" nd="" mail_v="" mail_host=""
  while true; do
    node_v="$(lib_manifest_get '.components.node')"
    py_v="$(lib_manifest_get '.components.python')"
    nd="$(lib_manifest_get '.components.netdata')"
    mail_v="$(lib_manifest_get '.components.mail.postfix')"
    mail_host="$(lib_mail_host)"
    printf '\n %sOPTIONAL COMPONENTS%s   (nothing here is installed by default)\n' "$C_BLD" "$C_RST"
    _menu_rule
    printf '  %s1%s) Node.js + PM2        %s\n' "$C_CYN" "$C_RST" \
      "$( [[ -n "$node_v" ]] && printf '%sinstalled %s%s' "$C_GRN" "$node_v" "$C_RST" || printf '%snot installed%s' "$C_DIM" "$C_RST")"
    printf '  %s2%s) Python venv + pip    %s\n' "$C_CYN" "$C_RST" \
      "$( [[ -n "$py_v" ]] && printf '%sinstalled %s%s' "$C_GRN" "$py_v" "$C_RST" || printf '%snot installed%s' "$C_DIM" "$C_RST")"
    printf '  %s3%s) Netdata monitoring   %s\n' "$C_CYN" "$C_RST" \
      "$( [[ "$nd" == "true" ]] && printf '%sinstalled%s' "$C_GRN" "$C_RST" || printf '%snot installed%s' "$C_DIM" "$C_RST")"
    printf '  %s4%s) Mail server          %s\n' "$C_CYN" "$C_RST" \
      "$( [[ -n "$mail_v" ]] && printf '%sinstalled, sends as %s%s' "$C_GRN" "$mail_host" "$C_RST" || printf '%snot installed%s' "$C_DIM" "$C_RST")"
    printf '  %s0%s) Back\n' "$C_CYN" "$C_RST"
    printf '\n%sChoice: %s' "$C_BLD" "$C_RST"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_ask ver "Node.js major version" "$(lib_install_node_major_resolve)"
         _menu_run install --with-node --node "$ver" --skip-upgrade ;;
      2) _menu_run install --with-python --skip-upgrade ;;
      3) _menu_run install --with-netdata --skip-upgrade ;;
      4) if [[ -n "$mail_v" ]]; then
           _menu_run mail status
         else
           local mh=""
           printf '\n  The mail server needs a name of its own (mail.example.com), an A record\n'
           printf '  pointing here, and a PTR record your provider sets to the same name.\n'
           _menu_ask mh "Name this server sends mail as" "$(hostname -f 2>/dev/null || true)"
           [[ -n "$mh" ]] && _menu_run install --with-mail --mail-hostname "$mh" --skip-upgrade
         fi ;;
      0|q|Q|"") return 0 ;;
      *) printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

# Automatic backups: every site, each night or week, by cron. One archive per site holds its
# files, its database, its vhost and its state.
_menu_backup_schedule() {
  local how="" at="" day="" keep="" enc="" rem="" spec="" keep_def="$BACKUP_KEEP"
  local -a args=()
  printf '\n  Every site gets an archive of its own under %s/<domain>/:\n' "$BACKUP_ROOT"
  printf '  files, database, vhost and state. Older archives are removed as new ones arrive.\n'
  printf '\n  1) Every day\n  2) Once a week\n  3) Every hour\n  4) Turn automatic backups off\n  0) Back\n'
  _menu_ask how "Choice" "1"
  case "$how" in
    1) _menu_ask at "At what time (HH:MM, the server's clock)" "03:00"; spec="daily ${at}" ;;
    2) _menu_ask day "On which day (mon tue wed thu fri sat sun)" "sun"
       _menu_ask at "At what time (HH:MM, the server's clock)" "03:00"
       day="${day,,}"; spec="weekly ${day} ${at}" ;;
    3) spec="hourly"; keep_def="24" ;;
    4) _menu_run backup --schedule off; return 0 ;;
    *) return 0 ;;
  esac
  if [[ "$how" != "3" ]] && ! [[ "$at" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    printf '%s"%s" is not a time like 03:00.%s\n' "$C_YEL" "$at" "$C_RST"; _menu_pause; return 0
  fi
  if [[ "$how" == "2" ]] && ! [[ "$day" =~ ^(mon|tue|wed|thu|fri|sat|sun)$ ]]; then
    printf '%s"%s" is not one of mon tue wed thu fri sat sun.%s\n' "$C_YEL" "$day" "$C_RST"; _menu_pause; return 0
  fi
  _menu_ask keep "Archives to keep per site" "$keep_def"
  if ! [[ "$keep" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s"%s" is not a number of archives.%s\n' "$C_YEL" "$keep" "$C_RST"; _menu_pause; return 0
  fi
  args=(--schedule "$spec" --keep "$keep")
  _menu_ask enc "Encrypt the archives? (y/n)" "n"
  [[ "${enc,,}" == y* ]] && args+=(--encrypt)
  if lib_backup_remote_load; then
    _menu_ask rem "Also upload each one to ${BKR_TYPE} ${BKR_TARGET}? (y/n)" "y"
    [[ "${rem,,}" == y* ]] && args+=(--remote)
  else
    printf '%s  They stay on this server only: "%s backup --configure-remote" adds a second place.%s\n' "$C_DIM" "$MENU_CMD" "$C_RST"
  fi
  _menu_run backup "${args[@]}"
}

_menu_backup() {
  local what="" enc="" sched=""
  local -a args=()
  sched="$(lib_manifest_get '.backup.schedule' 2>/dev/null || true)"
  printf '\n  1) Every site, now\n  2) One site, now\n  3) Automatic backups (now: %s)\n' "${sched:-off}"
  _menu_ask what "Choice" "1"
  if [[ "$what" == "3" ]]; then _menu_backup_schedule; return 0; fi
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
