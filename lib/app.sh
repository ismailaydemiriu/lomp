#!/usr/bin/env bash
# lib/app.sh - Node.js applications run by PM2: one PM2 daemon per site, started by systemd
#              as that site's own user, never as root.
#
#   state  domain.json .app{port, start, script, memory, enabled, git{url, branch}, deps_hash,
#          last_deploy} and .workers[{name, start, cwd, port, memory, cron, timeout, enabled}];
#          environment values live in the root-only app-env.json next to it, never in
#          domain.json ("list --json" prints it). The last deploy's output, masked, is kept in
#          deploy.log there.
#   files  /etc/systemd/system/pm2-<ident>.service   root, rendered by lompstack
#          /home/<domain>/.pm2/lomp.ecosystem.json    0600, written AS the site user
#          /home/<domain>/.pm2/lomp.env               0600, the same values for builds and jobs
#          /home/<domain>/.pm2/logs/<process>-{out,error}.log, <job>-job.log
#          /home/<domain>/.pm2/jobs/<job>.sh          a scheduled job, started by cron as the user
#          /home/<domain>/.ssh/id_ed25519             deploy key, created on request
#
# A worker is a second long-running process of the application under the same PM2 (a queue
# consumer, a bot). A worker with a schedule is a job: cron starts it, one run at a time. Not
# PM2's cron_restart, which also runs it at every start and kills a run that is still going.
#
# Inside a site's home lompstack acts as the site user (_app_as): root neither writes into nor
# reads from a directory that user controls, and nothing from root's environment reaches the
# application. Secret values never travel on a command line (/proc/<pid>/cmdline is readable
# by every user): they go through standard input or a process's own environment.

APP_UNIT_DIR="${APP_UNIT_DIR:-/etc/systemd/system}"
APP_PORT_MIN=3000
APP_PORT_MAX=3999
APP_PATH_ENV="/usr/local/bin:/usr/bin:/bin"
# the application of the site loaded with lib_app_state_load
APP_PRESENT=0 APP_PORT="" APP_START="" APP_SCRIPT="" APP_MEMORY="" APP_ENABLED=0
APP_GIT_URL="" APP_GIT_BRANCH="" APP_DEPS_HASH=""
# "add --node" options, kept apart from D_*, which the add flow reloads from domain.json
APP_OPT_NODE=0 APP_OPT_PORT="" APP_OPT_START="" APP_OPT_SCRIPT="" APP_OPT_GIT="" APP_OPT_BRANCH=""
# outcome of lib_app_apply (running | waiting | stopped | failed) and a sentence for humans
APP_RESULT="" APP_RESULT_MSG="" APP_BUILD_ERROR="" APP_FILE_CHANGED=0
APP_DEPS_HASH_NEW="" APP_GIT_COMMIT="" APP_GIT_PREV=""
# commands put in front of the switch to the site user (resource limits of a build)
APP_AS_WRAP=()
# how long a process just (re)started gets before its PM2 status is believed
APP_SETTLE_SECONDS=3
APP_JOB_TIMEOUT_DEFAULT="1h"
# the process a command was limited to with --process ("" = the application and its workers)
APP_ONLY=""

lib_app_usage() {
  cat <<'EOF'
Usage: setup.sh app list [--json]
       setup.sh app status <domain>
       setup.sh app start | stop | restart <domain> [--process NAME]
       setup.sh app logs <domain> [--process NAME] [--out|--error] [-n LINES]
       setup.sh app worker <domain> list
       setup.sh app worker <domain> add NAME --start CMD [--cwd DIR] [--port N] [--memory 256M]
       setup.sh app worker <domain> add NAME --cron "*/5 * * * *" --start CMD [--cwd DIR] [--timeout 1h]
       setup.sh app worker <domain> remove NAME | run NAME
       setup.sh app deploy <domain> [--git URL [--branch B]]
                                        pull (git), install dependencies, build, restart
       setup.sh app deploy-key <domain> a key for a private repository (prints the public key)
       setup.sh app set <domain> [--port N] [--start "npm start" | --script dist/main.js] [--memory 512M|none] [--no-git]
       setup.sh app env <domain> list [--show] | set NAME | unset NAME... | import-db
  Create a Node.js site with: setup.sh add app.example.com --node [--port N] [--start CMD] [--git URL]
  The application must listen on the port in $PORT. "env set" reads the value from standard
  input or asks for it, so it never shows up in the process list, shell history or log.
  Repository URLs: https://host/owner/repo.git, git@host:owner/repo.git, ssh://git@host/repo.git;
  never with a password or token inside - use a deploy key instead.
  Workers run next to the application under the same PM2, as the site user and with its
  environment: queue consumers, bots (the process is "web" for the application itself). With
  --cron a worker is a scheduled job started by cron: a run never overlaps the previous one
  and is stopped after --timeout. "worker run" starts a job now. The directory is relative to
  the site's home (default: app). Secrets belong in "app env", not in a start command.
EOF
}

lib_app_main() {
  local action="${1:-list}"
  if (($# > 0)); then shift; fi
  case "$action" in
    list)           lib_app_list "$@" ;;
    status)         lib_app_status "$@" ;;
    start)          lib_app_start "$@" ;;
    stop)           lib_app_stop "$@" ;;
    restart)        lib_app_restart "$@" ;;
    logs)           lib_app_logs "$@" ;;
    deploy)         lib_app_deploy "$@" ;;
    deploy-key)     lib_app_deploy_key "$@" ;;
    set)            lib_app_set "$@" ;;
    env)            lib_app_env "$@" ;;
    worker)         lib_app_worker "$@" ;;
    help|-h|--help) lib_app_usage ;;
    *) lib_app_usage >&2; lib_die "Unknown app action '${action}'" "" "setup.sh app list | status | start | stop | restart | logs | deploy | deploy-key | set | env | worker" ;;
  esac
}

# =============================================================================
#  Acting as the site user
# =============================================================================
# umask 027, and none of lompstack's lock descriptors (200 global, 201 site): a process that a
# build or an install script leaves running must not keep every later command locked out.
_app_as() {   # dir cmd...   (the site in D_*)
  local dir="$1"; shift
  ( umask 027 && exec "${APP_AS_WRAP[@]}" runuser -u "$D_USER" -- env -i -C "$dir" HOME="$D_HOME" PM2_HOME="${D_HOME}/.pm2" \
    PATH="$APP_PATH_ENV" LANG="C.UTF-8" "$@" 200>&- 201>&- )
}

# stdin -> file, written by the site user (0600, temporary name then rename).
# APP_FILE_CHANGED says whether the content differed.
_app_write_as_user() {   # path
  local path="$1" new="" old=""
  new="$(cat; printf x)"; new="${new%x}"
  old="$(_app_as "$D_HOME" cat -- "$path" 2>/dev/null || true; printf x)"; old="${old%x}"
  APP_FILE_CHANGED=0
  if [[ "$new" == "$old" ]]; then return 0; fi
  APP_FILE_CHANGED=1
  if (( OPT_DRY_RUN )); then
    (( OPT_QUIET )) || printf '%s[dry ]%s  would write %s as %s (contents not shown)\n' "$C_MAG" "$C_RST" "$path" "$D_USER"
    return 0
  fi
  printf '%s' "$new" | _app_as "$D_HOME" sh -c 'umask 077 && cat >"$1.lomp-tmp" && mv -f "$1.lomp-tmp" "$1"' _ "$path"
}

# umask rather than "mkdir -m": the directories are private from the moment they exist
_app_prepare_home() {
  (( OPT_DRY_RUN )) && return 0
  _app_as "$D_HOME" sh -c 'umask 077 && mkdir -p .pm2/logs .pm2/jobs'
}

# Is there a regular file at this path inside the home? Asked as the site user, so a link the
# user placed there cannot make root look at anything else.
_app_user_file() {   # path relative to the home
  _app_as "$D_HOME" test -f "$1" 2>/dev/null
}

# A script from the application's package.json, read as the site user, limited in size and
# time (a FIFO named package.json must not hang a root command).
_app_package_script() {   # name -> the script ("" when there is none)
  _app_as "$D_HOME" timeout 5 head -c 1048576 -- app/package.json 2>/dev/null \
    | jq -r --arg n "$1" '.scripts[$n] // empty' 2>/dev/null || true
}

# One change to a site's application at a time. A deploy can take minutes, so this is a
# per-site lock rather than the global one: backups and health checks keep running meanwhile.
_app_site_lock() {   # domain
  local f=""
  (( OPT_DRY_RUN )) && return 0
  f="$(lib_domain_state_dir "$1")/app.lock"
  exec 201>"$f"
  flock -n 201 || lib_die "Another change to the application of ${1} is still running" "${f} is locked" "wait for it to finish, then retry"
}

# =============================================================================
#  State
# =============================================================================
lib_app_unit_name() { printf 'pm2-%s' "$1"; }                            # ident
lib_app_unit_file() { printf '%s/pm2-%s.service' "$APP_UNIT_DIR" "$1"; }  # ident

lib_app_state_load() {   # domain -> APP_* ; status 1 when the site runs no PM2 application
  local f=""
  APP_PRESENT=0 APP_PORT="" APP_START="" APP_SCRIPT="" APP_MEMORY="" APP_ENABLED=0
  APP_GIT_URL="" APP_GIT_BRANCH="" APP_DEPS_HASH=""
  f="$(lib_domain_json "$1")"
  [[ -s "$f" ]] || return 1
  [[ "$(jq -r 'has("app")' "$f" 2>/dev/null || true)" == "true" ]] || return 1
  APP_PRESENT=1
  APP_PORT="$(lib_json_get "$f" '.app.port')"
  APP_START="$(lib_json_get "$f" '.app.start')"
  APP_SCRIPT="$(lib_json_get "$f" '.app.script')"
  APP_MEMORY="$(lib_json_get "$f" '.app.memory')"
  APP_GIT_URL="$(lib_json_get "$f" '.app.git.url')"
  APP_GIT_BRANCH="$(lib_json_get "$f" '.app.git.branch')"
  APP_DEPS_HASH="$(lib_json_get "$f" '.app.deps_hash')"
  if [[ "$(lib_json_get_raw "$f" '.app.enabled')" == "true" ]]; then APP_ENABLED=1; fi
  return 0
}

lib_app_state_write() {   # domain   (from APP_PORT APP_START APP_SCRIPT APP_MEMORY APP_ENABLED APP_GIT_*)
  lib_json_set "$(lib_domain_json "$1")" \
    '.app = ((.app // {}) + {manager: "pm2", port: ($port | tonumber), start: $start, script: $script, memory: $mem, enabled: ($en == "1")}
             + (if $url == "" then {} else {git: {url: $url, branch: $branch}} end))' \
    --arg port "$APP_PORT" --arg start "$APP_START" --arg script "$APP_SCRIPT" --arg mem "$APP_MEMORY" --arg en "$APP_ENABLED" \
    --arg url "$APP_GIT_URL" --arg branch "$APP_GIT_BRANCH"
  APP_PRESENT=1
}

lib_app_env_file() { printf '%s/app-env.json' "$(lib_domain_state_dir "$1")"; }

lib_app_env_json() {   # domain -> JSON object, {} when there is none
  local f="" out=""
  f="$(lib_app_env_file "$1")"
  if [[ -s "$f" ]]; then out="$(jq -c 'if type == "object" then . else {} end' "$f" 2>/dev/null || true)"; fi
  if [[ -z "$out" ]]; then out='{}'; fi
  printf '%s' "$out"
}

lib_app_workers_json() {   # domain -> JSON array, [] when there are none
  local f="" out=""
  f="$(lib_domain_json "$1")"
  if [[ -s "$f" ]]; then out="$(jq -c '.workers // [] | if type == "array" then . else [] end' "$f" 2>/dev/null || true)"; fi
  printf '%s' "${out:-[]}"
}

lib_app_worker_get() {   # domain name -> that worker's JSON, or status 1
  local w=""
  w="$(jq -c --arg n "$2" '.[] | select(.name == $n)' <<<"$(lib_app_workers_json "$1")" 2>/dev/null || true)"
  [[ -n "$w" ]] || return 1
  printf '%s' "$w"
}

# One worker added or replaced by name; the list stays in name order. Start commands are not
# secret (they are on every process list), so the JSON may go through jq's arguments.
lib_app_worker_state_set() {   # domain worker JSON
  lib_json_set "$(lib_domain_json "$1")" '.workers = (((.workers // []) | map(select(.name != $w.name))) + [$w] | sort_by(.name))' --argjson w "$2"
}

lib_app_worker_state_del() {   # domain name
  lib_json_set "$(lib_domain_json "$1")" '.workers = ((.workers // []) | map(select(.name != $n))) | if .workers == [] then del(.workers) else . end' --arg n "$2"
}

# PORT, HOME, PATH and LANG are set by lompstack; PM2_* would steer PM2 itself.
lib_app_env_key_valid() {   # name
  [[ "$1" =~ ^[A-Z_][A-Z0-9_]*$ ]] || return 1
  case "$1" in PORT|HOME|PATH|LANG|PM2_*) return 1 ;; esac
  return 0
}

# A start command runs without a shell, so it is words only. Pipes, quotes and && belong in a
# package.json script ("npm run <name>").
lib_app_start_valid() {   # command
  [[ "$1" =~ ^[A-Za-z0-9._/:=@+-]+([[:space:]]+[A-Za-z0-9._/:=@+-]+)*$ ]]
}

lib_app_script_valid() {   # path inside app/
  [[ "$1" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "/$1/" != *"/../"* && "/$1/" != *"/./"* ]]
}

# Repository URLs: https, ssh, scp-style (user@host:path) and file. Refused: plain http, any
# URL with a user or password in it (it would live in .git/config, backups and the process
# list - a deploy key does the same job), git's command-running transports (ext::, fd::) and
# anything that could be read as an option.
# Users and hosts start with a letter or digit, so no part can pass for an ssh option; "?" and
# "#" are refused because a query string is where tokens hide.
lib_app_git_url_valid() {   # url
  local u="$1"
  [[ -n "$u" && "$u" != -* && "$u" != *[[:space:]]* && "$u" != *[?#]* ]] || return 1
  if [[ "$u" =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/[^[:space:]]+$ ]]; then return 0; fi
  if [[ "$u" =~ ^ssh://([A-Za-z0-9][A-Za-z0-9._-]*@)?[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/[^[:space:]]+$ ]]; then return 0; fi
  if [[ "$u" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9.-]*:[A-Za-z0-9_~][^[:space:]]*$ ]]; then return 0; fi
  if [[ "$u" =~ ^file:///[^[:space:]]+$ ]]; then return 0; fi
  return 1
}

# git's ref-name rules that a branch typed by a person can break
lib_app_git_branch_valid() {   # branch
  local b="$1"
  [[ "$b" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*$ ]] || return 1
  [[ "$b" != *..* && "$b" != *.lock && "$b" != *.lock/* && "$b" != *. && "$b" != HEAD ]]
}

# Worker names are PM2 process names and file names. "web" is the application itself, and
# "all" would turn "pm2 delete <name>" into deleting every process.
lib_app_worker_name_valid() {   # name
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ && "$1" != web && "$1" != all ]]
}

# A directory inside the site's home, relative to it: app, app/worker, private/bot
lib_app_cwd_valid() { lib_app_script_valid "$1"; }

lib_app_timeout_valid() { [[ "$1" =~ ^[1-9][0-9]{0,5}[smhd]?$ ]]; }

# One field of a schedule: *, N, N-M, */S or N-M/S, comma separated, inside the field's range;
# month and day of week also take one name. Cron ignores the WHOLE file when a single line is
# malformed - backups, renewals and health checks included - so nothing it could reject is
# ever written there.
_app_cron_field_valid() {   # field min max [names]
  local f="$1" min="$2" max="$3" names="${4:-}" item="" lo="" hi="" step=""
  local -a items=()
  if [[ -n "$names" && "$f" =~ ^[A-Za-z]{3}$ ]]; then [[ " ${names} " == *" ${f,,} "* ]]; return; fi
  [[ "$f" =~ ^[0-9*/,-]+$ && "$f" != ,* && "$f" != *, && "$f" != *,,* ]] || return 1
  IFS=',' read -r -a items <<<"$f"
  for item in "${items[@]}"; do
    step=""
    if [[ "$item" =~ ^(.+)/([0-9]{1,2})$ ]]; then
      item="${BASH_REMATCH[1]}"; step="${BASH_REMATCH[2]}"
      (( 10#$step >= 1 && 10#$step <= max )) || return 1
    fi
    [[ "$item" != "*" ]] || continue
    if [[ -n "$step" && "$item" != *-* ]]; then return 1; fi   # N/S: write N-M/S
    if [[ "$item" =~ ^([0-9]{1,2})-([0-9]{1,2})$ ]]; then lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
    elif [[ "$item" =~ ^[0-9]{1,2}$ ]]; then lo="$item"; hi="$item"
    else return 1; fi
    (( 10#$lo >= min && 10#$hi <= max && 10#$lo <= 10#$hi )) || return 1
  done
  return 0
}

lib_app_cron_valid() {   # schedule
  local -a fields=()
  case "$1" in @hourly|@daily|@weekly|@monthly|@yearly|@annually|@midnight) return 0 ;; esac
  [[ "$1" != *$'\n'* ]] || return 1
  read -r -a fields <<<"$1"
  ((${#fields[@]} == 5)) || return 1
  _app_cron_field_valid "${fields[0]}" 0 59 \
    && _app_cron_field_valid "${fields[1]}" 0 23 \
    && _app_cron_field_valid "${fields[2]}" 1 31 \
    && _app_cron_field_valid "${fields[3]}" 1 12 "jan feb mar apr may jun jul aug sep oct nov dec" \
    && _app_cron_field_valid "${fields[4]}" 0 7 "sun mon tue wed thu fri sat"
}

# =============================================================================
#  Ports
# =============================================================================
# The site that already claims this loopback port (app port, proxy target or path proxy).
_app_port_claimed_by() {   # port [own domain] -> domain, or status 1
  local port="$1" own="${2:-}" d=""
  while read -r d; do
    [[ -n "$d" && "$d" != "$own" ]] || continue
    if jq -e --arg p "$port" '([(.app.port // empty | tostring)] + [(.workers // [])[] | .port // empty | tostring] + ([(.proxy.target // empty), ((.proxies // [])[].target)] | map(select(test("^(127\\.0\\.0\\.1|localhost):")) | sub("^[^:]*:"; "")))) | index($p) != null' "$(lib_domain_json "$d")" >/dev/null 2>&1; then
      printf '%s' "$d"
      return 0
    fi
  done < <(lib_domains_list)
  return 1
}

_app_ports_taken() {   # every port a new application must not get, one per line
  local d=""
  printf '%s\n' 80 443 3306 6379 19999 "${ADMIN_PORT:-7080}"
  lib_ssh_ports | tr ' ' '\n'
  while read -r d; do
    [[ -n "$d" ]] || continue
    jq -r '(.app.port // empty | tostring), ((.workers // [])[] | .port // empty | tostring), ([(.proxy.target // empty), ((.proxies // [])[].target)] | map(select(test("^(127\\.0\\.0\\.1|localhost):")) | sub("^[^:]*:"; "")) | .[])' "$(lib_domain_json "$d")" 2>/dev/null || true
  done < <(lib_domains_list)
  if lib_have ss; then ss -tlnH 2>/dev/null | awk '{n = split($4, a, ":"); print a[n]}' || true; fi
  return 0
}

lib_app_port_pick() {   # -> first free port from APP_PORT_MIN, or status 1
  local taken="" p=0
  taken=" $(_app_ports_taken | tr '\n' ' ') "
  for (( p = APP_PORT_MIN; p <= APP_PORT_MAX; p++ )); do
    if [[ "$taken" != *" ${p} "* ]]; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

lib_app_port_conflict() {   # port [own domain] -> why it cannot be used, or status 1
  local port="$1" own="${2:-}" by="" holder=""
  if ! [[ "$port" =~ ^[0-9]{4,5}$ ]] || (( 10#$port < 1024 || 10#$port > 65535 )); then
    printf 'use a port between 1024 and 65535'; return 0
  fi
  port=$((10#$port))
  case " 3306 6379 19999 ${ADMIN_PORT:-7080} $(lib_ssh_ports | tr '\n' ' ') " in
    *" ${port} "*) printf 'port %s belongs to a service of this server' "$port"; return 0 ;;
  esac
  by="$(_app_port_claimed_by "$port" "$own" || true)"
  if [[ -n "$by" ]]; then printf 'port %s is already used by %s' "$port" "$by"; return 0; fi
  holder="$(lib_port_holder "$port")"
  if [[ -n "$holder" ]]; then printf 'port %s is in use by %s' "$port" "$holder"; return 0; fi
  return 1
}

# =============================================================================
#  Rendering
# =============================================================================
# JSON array of strings, built from stdin. Never through jq's own argument list: an
# application argument such as "--port=3000" would be read as one of jq's options.
_app_json_words() {   # words...
  if (($# == 0)); then printf '[]'; return 0; fi
  printf '%s\n' "$@" | jq -R . | jq -cs .
}

# When "npm start" is plain "node <file> [args]", PM2 runs node itself: it then watches the
# application's memory instead of npm's, and signals reach the app without npm in between.
_app_npm_start_node() {   # -> {script, args} JSON, or status 1
  local s="" file="" rest=""
  local -a words=()
  s="$(_app_package_script start)"
  [[ "$s" =~ ^node[[:space:]]+([A-Za-z0-9._/-]+)(([[:space:]]+[A-Za-z0-9._/:=@+-]+)*)[[:space:]]*$ ]] || return 1
  file="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
  if [[ "$file" == -* ]] || ! lib_app_script_valid "$file"; then return 1; fi
  read -r -a words <<<"$rest"
  jq -cn --arg s "$file" --argjson a "$(_app_json_words "${words[@]}")" '{script: $s, args: $a}'
}

lib_app_command_json() {   # -> {script, args} for PM2 (the app in APP_*, the site in D_*)
  local resolved=""
  local -a words=()
  if [[ -n "$APP_SCRIPT" ]]; then jq -cn --arg s "$APP_SCRIPT" '{script: $s, args: []}'; return 0; fi
  if [[ "$APP_START" == "npm start" ]]; then
    resolved="$(_app_npm_start_node || true)"
    if [[ -n "$resolved" ]]; then printf '%s' "$resolved"; return 0; fi
  fi
  read -r -a words <<<"$APP_START"
  if ((${#words[@]} == 0)); then words=(npm start); fi
  jq -cn --arg s "${words[0]}" --argjson a "$(_app_json_words "${words[@]:1}")" '{script: $s, args: $a}'
}

# Is there code to run yet? Sets APP_RESULT_MSG when there is not.
lib_app_runnable() {
  if [[ -n "$APP_SCRIPT" ]]; then
    if _app_user_file "app/${APP_SCRIPT}"; then return 0; fi
    APP_RESULT_MSG="${D_HOME}/app/${APP_SCRIPT} does not exist yet"
    return 1
  fi
  case "$APP_START" in
    npm\ *|yarn\ *|pnpm\ *|npx\ *)
      if _app_user_file app/package.json; then return 0; fi
      APP_RESULT_MSG="there is no package.json in ${D_HOME}/app yet"
      return 1 ;;
  esac
  return 0
}

lib_app_render_unit() {   # pm2 binary
  local pm2="$1"
  cat <<EOF
# Managed by lompstack - PM2 for ${D_DOMAIN}; regenerated on every change, do not edit.
[Unit]
Description=PM2 process manager for ${D_DOMAIN} (lompstack)
Documentation=https://pm2.keymetrics.io/docs/usage/startup/
After=network-online.target mariadb.service redis-server.service
Wants=network-online.target

[Service]
Type=forking
User=${D_USER}
Group=${D_GROUP}
WorkingDirectory=${D_HOME}
Environment=HOME=${D_HOME}
Environment=PM2_HOME=${D_HOME}/.pm2
Environment=PATH=${APP_PATH_ENV}
Environment=LANG=C.UTF-8
PIDFile=${D_HOME}/.pm2/pm2.pid
# "ping" starts the daemon and the applications follow, so one process that cannot start
# does not fail the unit and take the healthy ones down with it
ExecStart=${pm2} ping
ExecStartPost=-${pm2} start ${D_HOME}/.pm2/lomp.ecosystem.json
ExecStop=${pm2} kill
Restart=always
RestartSec=5
LimitNOFILE=65535
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
}

# filter_env: a process gets exactly this environment and nothing inherited from whoever ran
# pm2. exec_mode fork without "instances" (instances silently means cluster mode). The
# variables reach jq through its environment, not its argument list. The web process is in
# only when it should run (enabled, with code to run); a worker when it is enabled and has no
# schedule (a scheduled job belongs to cron). A worker gets PORT only when it has a port.
lib_app_render_ecosystem() {   # command JSON, environment JSON [, workers JSON [, web 0|1]]
  LOMP_APP_ECO_ENV="${2:-}" jq -n --argjson cmd "$1" --argjson workers "${3:-[]}" --arg web "${4:-$APP_ENABLED}" \
    --arg home "$D_HOME" --arg port "$APP_PORT" --arg mem "$APP_MEMORY" --arg path "$APP_PATH_ENV" \
    '(($ENV.LOMP_APP_ECO_ENV // "") | if . == "" then {} else fromjson end) as $env
     | def proc($n; $dir; $script; $argv; $p; $m):
         {name: $n, cwd: ($home + "/" + $dir), script: $script, args: $argv,
          exec_mode: "fork", filter_env: true, vizion: false, autorestart: true, merge_logs: true, time: true,
          out_file: ($home + "/.pm2/logs/" + $n + "-out.log"), error_file: ($home + "/.pm2/logs/" + $n + "-error.log"),
          env: ($env + {NODE_ENV: ($env.NODE_ENV // "production"), HOME: $home, PATH: $path, LANG: "C.UTF-8"}
                + (if $p == "" then {} else {PORT: $p} end))}
         + (if $m == "" then {} else {max_memory_restart: $m} end);
     {apps: ((if $web == "1" then [proc("web"; "app"; $cmd.script; $cmd.args; $port; $mem)] else [] end)
       + [$workers[] | select((.cron // "") == "" and .enabled != false)
          | ([.start | splits("\\s+") | select(length > 0)]) as $w
          | proc(.name; (.cwd // "app"); $w[0]; $w[1:]; (.port // "" | tostring); (.memory // ""))])}'
}

lib_app_render_envfile() {   # environment JSON -> sourceable lines
  printf '# Managed by lompstack - change it with: setup.sh app env <domain> set NAME\n'
  jq -r 'to_entries[] | "export \(.key)=\(.value | tostring | @sh)"' <<<"$1"
}

# The script cron starts for a scheduled job, written into the home by the site user. No
# secret in it: the values come from the env file when a run starts. The lock is held by the
# script itself, so a process the job leaves behind cannot block the next runs.
lib_app_render_job() {   # worker JSON
  local name="" start="" cwd="" timeout="" cmd=""
  local -a words=()
  name="$(jq -r '.name' <<<"$1")"; start="$(jq -r '.start' <<<"$1")"
  cwd="$(jq -r '.cwd // "app"' <<<"$1")"; timeout="$(jq -r '.timeout // empty' <<<"$1")"
  timeout="${timeout:-$APP_JOB_TIMEOUT_DEFAULT}"
  read -r -a words <<<"$start"
  cmd="$(printf '%q ' "${words[@]}")"
  cat <<EOF
#!/bin/bash
# Managed by lompstack - scheduled job "${name}" of ${D_DOMAIN}; rewritten on every change.
# cron starts it as ${D_USER}: one run at a time, stopped after ${timeout}, output in the job log.
exec >>"${D_HOME}/.pm2/logs/${name}-job.log" 2>&1
exec 9>"${D_HOME}/.pm2/jobs/${name}.lock"
if ! flock -n 9; then
  printf '== %s ${name} skipped: the previous run is still going\n' "\$(date -Is)"
  exit 0
fi
cd "${D_HOME}/${cwd}" || exit 1
set -a
if [ -f "${D_HOME}/.pm2/lomp.env" ]; then . "${D_HOME}/.pm2/lomp.env"; fi
set +a
export HOME="${D_HOME}" PATH="${APP_PATH_ENV}" LANG=C.UTF-8 NODE_ENV="\${NODE_ENV:-production}"
printf '== %s ${name} started\n' "\$(date -Is)"
rc=0
timeout -k 60 ${timeout} ${cmd% } 9>&- || rc=\$?
printf '== %s ${name} finished with status %s\n' "\$(date -Is)" "\$rc"
exit "\$rc"
EOF
}

# The /etc/cron.d line of a job. cron takes an unescaped % for the end of the command.
lib_app_job_line() {   # worker JSON
  local name="" sched="" cmd=""
  name="$(jq -r '.name' <<<"$1")"; sched="$(jq -r '.cron' <<<"$1")"
  cmd="/bin/bash ${D_HOME}/.pm2/jobs/${name}.sh"
  printf '%s %s %s' "$sched" "$D_USER" "${cmd//%/\\%}"
}

# =============================================================================
#  Running
# =============================================================================
lib_app_node_ensure() {
  if lib_have node && lib_have pm2; then return 0; fi
  INS_NODE_MAJOR="$(lib_install_node_major_resolve "")"
  lib_info "Node.js or PM2 is missing: installing Node.js ${INS_NODE_MAJOR} with PM2 ${PM2_MAJOR}"
  lib_install_node
}

# pm2 as the site user. Callers make sure the unit is active first: any pm2 command starts a
# daemon when none runs, and one started outside systemd would make the unit fail later.
_app_pm2() {
  local pm2=""
  pm2="$(command -v pm2 || printf '/usr/bin/pm2')"
  _app_as "$D_HOME" "$pm2" "$@"
}

# PM2's process list as JSON. PM2 can print a version warning before it, so only the last
# line counts. It carries every process's environment: kept in memory, never logged.
_app_jlist() { _app_pm2 jlist 2>/dev/null | tail -n 1 || true; }

# "status cpu memory_bytes started_ms restarts" of one process in such a list
_app_info_from() {   # jlist name
  [[ -n "$1" ]] || return 0
  jq -r --arg n "$2" '.[]? | select(.name == $n) | [.pm2_env.status, (.monit.cpu // 0), (.monit.memory // 0), (.pm2_env.pm_uptime // 0), (.pm2_env.restart_time // 0)] | map(tostring) | join(" ")' <<<"$1" 2>/dev/null || true
}

_app_process_info() { _app_info_from "$(_app_jlist)" "$1"; }   # name

lib_app_wait_port() {   # port seconds
  local i=0
  for (( i = 0; i < $2; i++ )); do
    if lib_tcp_open 127.0.0.1 "$1"; then return 0; fi
    sleep 1
  done
  return 1
}

_app_stop_service() {   # unit
  if lib_service_active "$1"; then lib_systemctl stop "$1" || true; fi
  if lib_service_enabled "$1"; then lib_systemctl disable "$1" >/dev/null 2>&1 || true; fi
  return 0
}

# The processes to start again and to delete, one "start NAME" or "delete NAME" per line:
# new ones and those whose definition changed, those no longer wanted, and on a restart every
# process (or only the one named). The ecosystems carry the environment, so they reach jq
# through its environment.
_app_process_changes() {   # old ecosystem, new ecosystem, restart ("" | restart), only ("" | name)
  LOMP_APP_ECO_OLD="$1" LOMP_APP_ECO_NEW="$2" jq -rn --arg restart "$3" --arg only "$4" '
    ($ENV.LOMP_APP_ECO_OLD | try fromjson catch {apps: []}) as $o
    | ($ENV.LOMP_APP_ECO_NEW | fromjson) as $n
    | (($o.apps // []) | map({key: .name, value: .}) | from_entries) as $old
    | ($n.apps | map(.name)) as $names
    | ((($o.apps // []) | map(.name) | map(select(. as $x | $names | index($x) | not)) | .[] | "delete " + .),
       ($n.apps[] | select(($restart == "restart" and ($only == "" or $only == .name)) or $old[.name] != .) | "start " + .name))'
}

# Every job's script, written by the site user
_app_jobs_write() {   # workers JSON -> status
  local w="" name=""
  while IFS= read -r w <&3; do
    [[ -n "$w" ]] || continue
    name="$(jq -r '.name' <<<"$w")"
    lib_app_render_job "$w" | _app_write_as_user "${D_HOME}/.pm2/jobs/${name}.sh" || return 1
  done 3< <(jq -c '.[] | select((.cron // "") != "")' <<<"$1" || true)
  return 0
}

# The cron entries of the site's enabled jobs, in a single write of the shared cron file.
# Only for commands that hold the global lock: "app deploy" runs without it and never comes here.
_app_jobs_sync() {   # the site in D_*
  local w="" entries=""
  while IFS= read -r w <&3; do
    [[ -n "$w" ]] || continue
    entries+="$(printf 'job:%s:%s\t%s' "$D_DOMAIN" "$(jq -r '.name' <<<"$w")" "$(lib_app_job_line "$w")")"$'\n'
  done 3< <(jq -c '.[] | select((.cron // "") != "" and .enabled != false)' <<<"$(lib_app_workers_json "$D_DOMAIN")" || true)
  printf '%s' "$entries" | lib_cron_replace_prefix "job:${D_DOMAIN}:"
}

# Bring the site's PM2 in line with its state: ecosystem, env file and job scripts (as the site
# user), the systemd unit, then the processes. An application problem, including a home the
# site user has made unwritable, is reported in APP_RESULT and never fails the command: "add"
# must not undo a site because its application does not start. APP_RESULT describes the web
# process when it should run; otherwise the workers.
lib_app_apply() {   # [restart [process]]
  local restart="${1:-}" only="${2:-}" unit="" ufile="" pm2="" cmd="" env="" workers="" eco="" old="" new=""
  local unit_changed=0 web=0 procs=0 waiting="" action="" name="" failed="" info=""
  unit="$(lib_app_unit_name "$D_IDENT")"; ufile="$(lib_app_unit_file "$D_IDENT")"
  eco="${D_HOME}/.pm2/lomp.ecosystem.json"
  APP_RESULT=""; APP_RESULT_MSG=""
  pm2="$(command -v pm2 || true)"
  if [[ -z "$pm2" ]]; then
    if (( ! OPT_DRY_RUN )); then APP_RESULT="failed"; APP_RESULT_MSG="PM2 is not installed (setup.sh install --with-node)"; return 0; fi
    pm2="/usr/bin/pm2"
  fi
  if ! _app_prepare_home; then
    APP_RESULT="failed"; APP_RESULT_MSG="could not create ${D_HOME}/.pm2 as ${D_USER}"; return 0
  fi
  if (( APP_ENABLED )); then
    if lib_app_runnable; then web=1; else waiting="$APP_RESULT_MSG"; APP_RESULT_MSG=""; fi
  fi
  cmd="$(lib_app_command_json)"
  env="$(lib_app_env_json "$D_DOMAIN")"
  workers="$(lib_app_workers_json "$D_DOMAIN")"
  old="$(_app_as "$D_HOME" cat -- "$eco" 2>/dev/null || true)"
  if ! new="$(lib_app_render_ecosystem "$cmd" "$env" "$workers" "$web")" || ! printf '%s\n' "$new" | _app_write_as_user "$eco"; then
    APP_RESULT="failed"; APP_RESULT_MSG="could not write ${eco} as ${D_USER}"; return 0
  fi
  if ! lib_app_render_envfile "$env" | _app_write_as_user "${D_HOME}/.pm2/lomp.env"; then
    APP_RESULT="failed"; APP_RESULT_MSG="could not write ${D_HOME}/.pm2/lomp.env as ${D_USER}"; return 0
  fi
  if ! _app_jobs_write "$workers"; then
    APP_RESULT="failed"; APP_RESULT_MSG="could not write the job scripts into ${D_HOME}/.pm2/jobs as ${D_USER}"; return 0
  fi
  lib_app_render_unit "$pm2" | lib_write_file "$ufile" 0644 root:root
  if (( LIB_FILE_CHANGED )); then unit_changed=1; lib_systemctl daemon-reload; fi

  procs="$(jq '.apps | length' <<<"$new" 2>/dev/null || printf '0')"
  if (( procs == 0 )); then
    _app_stop_service "$unit"
    if [[ -n "$waiting" ]]; then
      APP_RESULT="waiting"
      APP_RESULT_MSG="waiting for code: ${waiting}. Put the application into ${D_HOME}/app (owned by ${D_USER}) or deploy it from git, then run: setup.sh app deploy ${D_DOMAIN}"
    else
      APP_RESULT="stopped"; APP_RESULT_MSG="stopped; start it with: setup.sh app start ${D_DOMAIN}"
    fi
    return 0
  fi
  if (( OPT_DRY_RUN )); then APP_RESULT="running"; APP_RESULT_MSG="[dry-run] would enable and start ${unit}"; return 0; fi

  lib_systemctl enable "$unit" >/dev/null 2>&1 || true
  if ! lib_service_active "$unit"; then
    if ! lib_systemctl start "$unit"; then APP_RESULT="failed"; APP_RESULT_MSG="${unit} did not start (journalctl -u ${unit})"; return 0; fi
  elif (( unit_changed )); then
    if ! lib_systemctl restart "$unit"; then APP_RESULT="failed"; APP_RESULT_MSG="${unit} did not restart (journalctl -u ${unit})"; return 0; fi
  else
    # delete + start, not reload: a reload keeps the old script, cwd and removed variables
    while read -r action name <&3; do
      [[ -n "$name" ]] || continue
      _app_pm2 delete "$name" >/dev/null 2>&1 || true
      if [[ "$action" == "start" ]] && ! lib_run _app_pm2 start "$eco" --only "$name"; then failed+=" ${name}"; fi
    done 3< <(_app_process_changes "$old" "$new" "$restart" "$only" || true)
  fi
  if (( web )); then
    if [[ " ${failed} " == *" web "* ]]; then
      APP_RESULT="failed"; APP_RESULT_MSG="pm2 could not start the application (setup.sh app logs ${D_DOMAIN})"; return 0
    fi
    if lib_app_wait_port "$APP_PORT" 30; then
      APP_RESULT="running"; APP_RESULT_MSG="running on 127.0.0.1:${APP_PORT}"
    else
      info="$(_app_process_info web)"
      APP_RESULT="failed"
      APP_RESULT_MSG="nothing listens on 127.0.0.1:${APP_PORT} after 30 s (PM2 status: ${info%% *}); the application must listen on process.env.PORT - see: setup.sh app logs ${D_DOMAIN}"
      return 0
    fi
  else
    APP_RESULT="running"
    APP_RESULT_MSG="the web process is $( [[ -n "$waiting" ]] && printf 'waiting for code' || printf 'stopped'), ${procs} worker(s) run under ${unit}"
  fi
  if [[ -n "$failed" ]]; then APP_RESULT_MSG+="; pm2 could not start:${failed} (setup.sh app logs ${D_DOMAIN} --process NAME)"; fi
  return 0
}

_app_report() {   # [soft]
  case "$APP_RESULT" in
    running|stopped) lib_ok "${D_DOMAIN}: ${APP_RESULT_MSG}" ;;
    waiting)         lib_warn "${D_DOMAIN}: ${APP_RESULT_MSG}" ;;
    *)
      if [[ "${1:-}" == "soft" ]]; then lib_warn "${D_DOMAIN}: the application is not running: ${APP_RESULT_MSG}"
      else lib_die "The application of ${D_DOMAIN} is not running" "$APP_RESULT_MSG" "setup.sh app logs ${D_DOMAIN}"; fi ;;
  esac
  return 0
}

# =============================================================================
#  Deploy
# =============================================================================
# git as the site user: its deploy key when it has one, accept-new for a first connection to
# a host, and never an interactive prompt (a missing credential fails instead of hanging).
_app_git() {   # args...
  local ssh="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
  if _app_user_file .ssh/id_ed25519; then ssh+=" -i ${D_HOME}/.ssh/id_ed25519 -o IdentitiesOnly=yes"; fi
  # a stalled https transfer (under 1 KB/s for a minute) fails instead of hanging the deploy
  _app_as "$D_HOME" env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$ssh" GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=60 git "$@"
}

# The branch the remote HEAD points at ("main", usually), asked from the repository itself.
_app_git_default_branch() {
  local b=""
  b="$(_app_git ls-remote --symref -- "$APP_GIT_URL" HEAD 2>/dev/null \
    | awk '$1 == "ref:" && $2 ~ /^refs\/heads\// { sub(/^refs\/heads\//, "", $2); print $2; exit }' || true)"
  if lib_app_git_branch_valid "$b"; then printf '%s' "$b"; fi
}

# Bring app/ to the tip of the repository branch, as the site user: the first time by cloning
# into the empty app directory, later by fetching. The branch is fetched as refs/heads/<branch>
# (a tag with the same name must not win) and checked out by force, so tracked files follow
# it; files git does not track (uploads, a local .env, build output) stay - no "git clean".
# APP_GIT_PREV keeps the commit the tree was on, to roll back to.
lib_app_fetch() {   # -> status; APP_BUILD_ERROR says why
  local branch="$APP_GIT_BRANCH" rc=0 entries=""
  APP_BUILD_ERROR=""; APP_GIT_COMMIT=""; APP_GIT_PREV=""
  if ! lib_have git; then lib_apt_install git || { APP_BUILD_ERROR="git is not installed and could not be installed"; return 1; }; fi
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would fetch ${APP_GIT_URL}${branch:+ (${branch})} into ${D_HOME}/app as ${D_USER}"; return 0; fi
  if _app_user_file app/.git/HEAD; then
    APP_GIT_PREV="$(_app_git -C app rev-parse --verify -q HEAD 2>/dev/null || true)"
    if ! _app_git -C app config remote.origin.url "$APP_GIT_URL"; then
      APP_BUILD_ERROR="could not point ${D_HOME}/app at ${APP_GIT_URL} (git config failed)"; return 1
    fi
  else
    entries="$(_app_as "$D_HOME" sh -c 'ls -A app 2>/dev/null | head -n 1' 2>/dev/null || true)"
    if [[ -n "$entries" ]]; then
      APP_BUILD_ERROR="${D_HOME}/app already holds files but is not a git checkout; move them away before the first deploy from ${APP_GIT_URL}"
      return 1
    fi
    lib_info "Cloning ${APP_GIT_URL}"
    _app_git clone --no-checkout -- "$APP_GIT_URL" app || rc=$?
    if (( rc != 0 )); then
      APP_BUILD_ERROR="git clone of ${APP_GIT_URL} failed (status ${rc}); a private repository needs the site's deploy key: setup.sh app deploy-key ${D_DOMAIN}"
      return 1
    fi
  fi
  if [[ -z "$branch" ]]; then branch="$(_app_git_default_branch)"; fi
  if [[ -z "$branch" ]]; then APP_BUILD_ERROR="could not tell the default branch of ${APP_GIT_URL}; name it with --branch"; return 1; fi
  lib_info "Fetching ${branch} from ${APP_GIT_URL}"
  _app_git -C app fetch --prune origin -- "refs/heads/${branch}" || rc=$?
  if (( rc != 0 )); then APP_BUILD_ERROR="git fetch of branch ${branch} from ${APP_GIT_URL} failed (status ${rc})"; return 1; fi
  _app_git -C app checkout -q -f -B "$branch" FETCH_HEAD || rc=$?
  if (( rc != 0 )); then APP_BUILD_ERROR="git could not check out the fetched ${branch} (status ${rc})"; return 1; fi
  APP_GIT_BRANCH="$branch"
  APP_GIT_COMMIT="$(_app_git -C app rev-parse --short HEAD 2>/dev/null || true)"
  return 0
}

# Dependencies are reinstalled only when package.json or the lockfile changed since the last
# successful deploy, or when there are none installed yet.
_app_install_needed() {   # current hash, recorded hash, installed(0|1)
  [[ "$3" != "1" || -z "$1" || -z "$2" || "$1" != "$2" ]]
}

# A build can take a lot of memory; keep it from pushing MariaDB into the OOM killer, and
# behind the sites in the CPU and disk queues.
_app_build_limits() {
  local mb=0
  APP_AS_WRAP=(nice -n 10)
  if lib_have ionice; then APP_AS_WRAP+=(ionice -c 3); fi
  if lib_have systemd-run && [[ -d /run/systemd/system ]]; then
    if [[ -z "${SYS_RAM_MB:-}" || "${SYS_RAM_MB:-0}" == "0" ]]; then lib_system_analyze --no-net >/dev/null 2>&1 || true; fi
    mb=$(( ${SYS_RAM_MB:-0} * 60 / 100 ))
    if (( mb >= 512 )); then
      APP_AS_WRAP=(systemd-run --scope --quiet --collect -p "MemoryMax=${mb}M" -p CPUWeight=50 -- "${APP_AS_WRAP[@]}")
    fi
  fi
}

# The hash of what node_modules was installed from; cleared ("") while an install is under
# way, so a failed install or build never leaves a hash that no longer matches node_modules.
_app_deps_record() {   # hash
  APP_DEPS_HASH="$1"
  lib_json_set "$(lib_domain_json "$D_DOMAIN")" 'if $h == "" then del(.app.deps_hash) else .app.deps_hash = $h end' --arg h "$1"
}

# Install the dependencies, then build, as the site user with the application's environment
# loaded from its env file (so no value appears on a command line). NODE_ENV is left out of
# the install: under "production" pnpm and yarn skip the devDependencies a build needs. Each
# step is capped at an hour.
lib_app_build() {   # -> status; APP_BUILD_ERROR says why
  local dir="${D_HOME}/app" files="" install="" run="npm run" rc=0 installed=0 hash=""
  local load='set -a; if [ -f "$HOME/.pm2/lomp.env" ]; then . "$HOME/.pm2/lomp.env"; fi; set +a'
  APP_BUILD_ERROR=""; APP_DEPS_HASH_NEW=""
  # which of these exist, asked as the site user
  files=" $(_app_as "$D_HOME" sh -c 'cd app 2>/dev/null || exit 0
    for f in package.json pnpm-lock.yaml yarn.lock package-lock.json npm-shrinkwrap.json; do
      if [ -f "$f" ] && [ ! -L "$f" ]; then printf "%s " "$f"; fi
    done
    if [ -d node_modules ]; then printf "node_modules "; fi' 2>/dev/null || true) "
  if [[ "$files" != *" package.json "* ]]; then
    if (( OPT_DRY_RUN )); then lib_info "[dry-run] would install the dependencies and build once ${dir}/package.json is there"; return 0; fi
    APP_BUILD_ERROR="there is no package.json in ${dir}"; return 1
  fi
  if [[ "$files" == *" node_modules "* ]]; then installed=1; fi
  if [[ "$files" == *" pnpm-lock.yaml "* ]]; then install="corepack pnpm install --frozen-lockfile"; run="corepack pnpm run"
  elif [[ "$files" == *" yarn.lock "* ]]; then install="corepack yarn install"; run="corepack yarn run"
  elif [[ "$files" == *" package-lock.json "* || "$files" == *" npm-shrinkwrap.json "* ]]; then install="npm ci --include=dev"
  # no lockfile of its own, so it gets none: an untracked one would make the next deploy an
  # "npm ci" against a lockfile that no longer matches package.json
  else install="npm install --include=dev --no-package-lock"; fi
  if [[ "$install" == corepack* ]] && ! lib_have corepack; then
    APP_BUILD_ERROR="the project uses ${install#corepack }, which needs corepack (npm install -g corepack)"
    return 1
  fi
  # node's version is part of it: native modules built for another Node.js do not load
  hash="$(_app_as "$D_HOME" sh -c 'cd app && { node -v; cat package.json package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml 2>/dev/null; } | sha256sum' 2>/dev/null | cut -c1-64 || true)"
  APP_DEPS_HASH_NEW="$hash"
  if ! _app_install_needed "$hash" "$APP_DEPS_HASH" "$installed"; then
    lib_info "Dependencies unchanged since the last install; not reinstalling them"
  elif (( OPT_DRY_RUN )); then
    lib_info "[dry-run] would run as ${D_USER} in ${dir}: ${install}"
  else
    lib_info "As ${D_USER} in ${dir}: ${install}"
    _app_deps_record ""
    _app_build_limits
    _app_as "$dir" timeout -k 60 3600 bash -c "${load}; unset NODE_ENV; ${install}" || rc=$?
    APP_AS_WRAP=()
    if (( rc != 0 )); then APP_BUILD_ERROR="'${install}' failed with status ${rc}"; return 1; fi
    _app_deps_record "$hash"
  fi
  if [[ -z "$(_app_package_script build)" ]]; then return 0; fi
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would run as ${D_USER} in ${dir}: ${run} build"; return 0; fi
  lib_info "As ${D_USER} in ${dir}: ${run} build"
  _app_build_limits
  _app_as "$dir" timeout -k 60 3600 bash -c "${load}"'; export NODE_ENV="${NODE_ENV:-production}"; '"${run} build" || rc=$?
  APP_AS_WRAP=()
  if (( rc != 0 )); then APP_BUILD_ERROR="'${run} build' failed with status ${rc}"; return 1; fi
  return 0
}

# Run a step in this shell while its output also goes to a file. The step reads nothing from
# the terminal. tee is waited for by its own pid ($! changes under any later process
# substitution), and only briefly: a process the step left running may still hold the pipe,
# and keep tee alive with it - which is why tee gets no lock descriptor either.
_app_logged() {   # file cmd...
  local file="$1" rc=0 fd="" pid="" i=0
  shift
  exec {fd}> >(exec tee -a "$file" 200>&- 201>&-)
  pid=$!
  "$@" >&"$fd" 2>&1 </dev/null || rc=$?
  exec {fd}>&-
  for (( i = 0; i < 50; i++ )); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  return "$rc"
}

# Keep the output of this deploy (masked) and what came of it.
_app_deploy_record() {   # output file, ok(0|1)
  local log=""
  (( OPT_DRY_RUN )) && return 0
  log="$(lib_domain_state_dir "$D_DOMAIN")/deploy.log"
  (umask 077; lib_mask_secrets <"$1" >"$log") || true
  lib_json_set "$(lib_domain_json "$D_DOMAIN")" '.app.last_deploy = {at: $at, commit: $c, ok: ($ok == "1")}' \
    --arg at "$(lib_iso_now)" --arg c "$APP_GIT_COMMIT" --arg ok "$2"
  return 0
}

# After a build failed on freshly fetched code: the previous commit goes back and is built
# again, so a crash restart or a reboot does not start code that was never built.
_app_rollback() {   # the commit in APP_GIT_PREV
  local short="${APP_GIT_PREV:0:7}"
  lib_warn "The build failed; putting ${short} back and building it again"
  if ! _app_git -C app checkout -q -f -B "$APP_GIT_BRANCH" "$APP_GIT_PREV"; then
    lib_warn "could not check out ${short} again; ${D_HOME}/app stays on the commit that failed"
    return 1
  fi
  if lib_app_build; then lib_ok "Back on ${short}"; return 0; fi
  lib_warn "building ${short} failed as well: ${APP_BUILD_ERROR}"
  return 1
}

# Fetch (when the application comes from git) and build. -> status; APP_BUILD_ERROR says why.
lib_app_deploy_run() {
  local out="" err="" failed="" head=""
  out="$(lib_mktemp)"
  APP_GIT_COMMIT=""; APP_GIT_PREV=""
  if [[ -n "$APP_GIT_URL" ]] && ! _app_logged "$out" lib_app_fetch; then _app_deploy_record "$out" 0; return 1; fi
  if ! _app_logged "$out" lib_app_build; then
    err="$APP_BUILD_ERROR"; failed="$APP_GIT_COMMIT"
    if [[ -n "$APP_GIT_PREV" ]] && (( ! OPT_DRY_RUN )); then
      head="$(_app_git -C app rev-parse --verify -q HEAD 2>/dev/null || true)"
      if [[ "$head" != "$APP_GIT_PREV" ]]; then
        if _app_logged "$out" _app_rollback; then err+="; the application was put back on ${APP_GIT_PREV:0:7}"
        else err+="; putting ${APP_GIT_PREV:0:7} back failed too, see the deploy log"; fi
      fi
    fi
    APP_BUILD_ERROR="$err"; APP_GIT_COMMIT="$failed"
    _app_deploy_record "$out" 0
    return 1
  fi
  _app_deploy_record "$out" 1
  return 0
}

# =============================================================================
#  Lifecycle hooks used by add / remove / restore
# =============================================================================
lib_app_provision_new() {   # the site in D_*, the options in APP_OPT_*
  _app_site_lock "$D_DOMAIN"   # a deploy of the same site takes no global lock
  APP_PORT="$APP_OPT_PORT"; APP_SCRIPT="$APP_OPT_SCRIPT"; APP_START="$APP_OPT_START"; APP_MEMORY=""; APP_ENABLED=1
  APP_GIT_URL="$APP_OPT_GIT"; APP_GIT_BRANCH="$APP_OPT_BRANCH"; APP_DEPS_HASH=""
  if [[ -z "$APP_START" && -z "$APP_SCRIPT" ]]; then APP_START="npm start"; fi
  lib_app_state_write "$D_DOMAIN"
  if [[ -n "$APP_GIT_URL" ]]; then
    if lib_app_deploy_run; then lib_app_state_write "$D_DOMAIN"
    else lib_warn "The first deploy from ${APP_GIT_URL} failed: ${APP_BUILD_ERROR}"; fi
  fi
  lib_app_apply
  case "$APP_RESULT" in
    running) lib_ok "Application running on 127.0.0.1:${APP_PORT} under $(lib_app_unit_name "$D_IDENT")" ;;
    waiting) lib_ok "PM2 service prepared; ${APP_RESULT_MSG}" ;;
    *)       lib_warn "The site is up, its application is not: ${APP_RESULT_MSG}" ;;
  esac
  return 0
}

lib_app_teardown() {   # the site in D_* - before its files and user are removed
  local unit="" ufile=""
  unit="$(lib_app_unit_name "$D_IDENT")"; ufile="$(lib_app_unit_file "$D_IDENT")"
  if [[ ! -e "$ufile" ]] && ! lib_app_state_load "$D_DOMAIN"; then lib_info "no Node.js application"; return 0; fi
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would stop, disable and delete ${unit}"; return 0; fi
  lib_systemctl disable --now "$unit" >/dev/null 2>&1 || true
  lib_rm "$ufile"
  lib_systemctl daemon-reload || true
  systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  lib_ok "${unit} stopped and removed"
}

# After "restore": dependencies are not in the backup, so they are installed and the app is
# built before it starts. Anything that goes wrong leaves the restored site in place.
lib_app_restore() {   # the site in D_*
  local by="" name="" port=""
  lib_app_state_load "$D_DOMAIN" || return 0
  lib_app_node_ensure
  by="$(_app_port_claimed_by "$APP_PORT" "$D_DOMAIN" || true)"
  if [[ -n "$by" ]]; then
    APP_ENABLED=0; lib_app_state_write "$D_DOMAIN"
    lib_warn "Port ${APP_PORT} is already used by ${by}; the application of ${D_DOMAIN} stays stopped (setup.sh app set ${D_DOMAIN} --port <free port>)"
  fi
  while read -r name port; do
    [[ -n "$port" ]] || continue
    by="$(_app_port_claimed_by "$port" "$D_DOMAIN" || true)"
    [[ -n "$by" ]] || continue
    _app_set_enabled 0 "$name"
    lib_warn "Port ${port} is already used by ${by}; worker ${name} of ${D_DOMAIN} stays stopped"
  done < <(jq -r '.[] | select(.port != null and .enabled != false) | "\(.name) \(.port)"' <<<"$(lib_app_workers_json "$D_DOMAIN")" || true)
  if lib_app_env_json "$D_DOMAIN" | jq -e '.DB_HOST == "127.0.0.1"' >/dev/null 2>&1; then
    lib_db_tcp_account_ensure "$D_DOMAIN" || lib_warn "could not restore the TCP login of the database user (setup.sh app env ${D_DOMAIN} import-db)"
  fi
  if (( APP_ENABLED )) && _app_user_file app/package.json; then
    APP_DEPS_HASH=""   # node_modules is not in the archive
    lib_app_build || lib_warn "dependencies of ${D_DOMAIN} could not be installed: ${APP_BUILD_ERROR}"
  fi
  lib_app_apply
  _app_jobs_sync
  _app_report soft
}

# =============================================================================
#  Commands
# =============================================================================
_app_load_site() {   # domain [optional]  (dies unless the site exists and, by default, runs an app)
  local domain="${1:-}"
  if [[ -z "$domain" ]]; then lib_app_usage >&2; lib_die "Domain missing" "" "setup.sh app list"; fi
  domain="${domain,,}"
  lib_require_tools
  lib_domain_registered "$domain" || lib_die "Site ${domain} is not registered" "" "setup.sh list"
  lib_domain_state_load "$domain"
  if lib_app_state_load "$domain"; then return 0; fi
  [[ "${2:-}" == "optional" ]] && return 0
  lib_die "${domain} runs no Node.js application" "" \
    "create one with: setup.sh add app.example.com --node   (a proxy site can take one over: setup.sh app set ${domain} --start \"npm start\")"
}

_app_age_ms() {   # start time in epoch milliseconds -> "3d 4h", "2h 5m", "7m"
  local ms="${1:-0}" s=0
  if ! [[ "$ms" =~ ^[0-9]+$ ]] || (( ms == 0 )); then printf -- '-'; return 0; fi
  s=$(( $(date +%s) - ms / 1000 ))
  if (( s >= 86400 )); then printf '%dd %dh' $(( s / 86400 )) $(( s % 86400 / 3600 ))
  elif (( s >= 3600 )); then printf '%dh %dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
  else printf '%dm' $(( s / 60 )); fi
}

lib_app_list() {   # [--json]
  local json=0 a="" d="" unit="" state="" info="" st="" cpu="" mem="" up="" rs="" n=0 rows="[]" jl="" wstat=""
  local wname="" wport="" wstate="" wcpu="" wmem="" wrs=""
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --json) json=1 ;;
      *) lib_die "Unknown option for app list: ${a}" "" "setup.sh app list [--json]" ;;
    esac
  done
  if (( OPT_JSON )); then json=1; fi
  lib_require_tools
  if (( ! json )); then
    printf '%s%-28s %-6s %-18s %5s %9s %8s %8s%s\n' "$C_BLD" "SITE" "PORT" "STATUS" "CPU" "MEMORY" "UPTIME" "RESTARTS" "$C_RST"
  fi
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_app_state_load "$d" || continue
    lib_domain_state_load "$d" || continue
    n=$((n + 1))
    unit="$(lib_app_unit_name "$D_IDENT")"
    st="" cpu="" mem="" up="" rs="" jl=""
    if lib_service_active "$unit"; then jl="$(_app_jlist)"; fi
    if (( ! APP_ENABLED )); then state="stopped"
    elif [[ -n "$jl" ]]; then
      info="$(_app_info_from "$jl" web)"
      read -r st cpu mem up rs <<<"$info"
      state="${st:-not in PM2}"
    elif ! lib_app_runnable; then state="waiting for code"
    else state="service down"; fi
    wstat="$(_app_workers_status "$(lib_app_workers_json "$d")" "$jl")"
    if (( json )); then
      rows="$(jq -cn --argjson a "$rows" --arg d "$d" --arg port "$APP_PORT" --arg state "$state" --arg en "$APP_ENABLED" \
        --arg cpu "${cpu:-0}" --arg mem "${mem:-0}" --arg up "${up:-0}" --arg rs "${rs:-0}" --arg git "$APP_GIT_URL" --argjson wk "$wstat" \
        '$a + [{domain: $d, port: ($port | tonumber), status: $state, enabled: ($en == "1"), cpu: ($cpu | tonumber),
                memory_bytes: ($mem | tonumber), started_ms: ($up | tonumber), restarts: ($rs | tonumber),
                git: (if $git == "" then null else $git end), workers: $wk}]')"
    else
      printf '%-28s %-6s %-18s %4s%% %9s %8s %8s\n' "$d" "$APP_PORT" "$state" "${cpu:-0}" "$(( ${mem:-0} / 1048576 )) MB" "$(_app_age_ms "${up:-0}")" "${rs:-0}"
      # one line per worker under its site; a job shows its schedule
      jq -r '.[] | [("  - " + .name), (if .kind == "job" then "job" else ((.port // "-") | tostring) end),
                    (if .kind == "job" then .schedule else .status end), (.cpu | tostring),
                    ((.memory_bytes / 1048576 | floor | tostring) + " MB"), (if .kind == "job" then "-" else (.restarts | tostring) end)] | @tsv' <<<"$wstat" \
        | while IFS=$'\t' read -r wname wport wstate wcpu wmem wrs; do
            printf '%-28s %-6s %-18s %4s%% %9s %8s %8s\n' "$wname" "$wport" "$wstate" "$wcpu" "$wmem" "-" "$wrs"
          done || true
    fi
  done < <(lib_domains_list)
  if (( json )); then printf '%s\n' "$rows"; return 0; fi
  if (( n == 0 )); then printf '(no Node.js applications - create one with: setup.sh add app.example.com --node)\n'; fi
  return 0
}

lib_app_status() {   # domain
  local unit="" info="" st="" cpu="" mem="" up="" rs="" start="" wanted="stopped" boot="" last=""
  _app_load_site "${1:-}"
  unit="$(lib_app_unit_name "$D_IDENT")"
  start="$APP_START"
  if [[ -n "$APP_SCRIPT" ]]; then start="node ${APP_SCRIPT}"; fi
  if (( APP_ENABLED )); then wanted="running"; fi
  if lib_service_enabled "$unit"; then boot=", starts at boot"; fi
  last="$(jq -r '.app.last_deploy // empty | "\(.at) \(if .ok then "ok" else "FAILED" end)\(if (.commit // "") != "" then " at " + .commit else "" end)"' "$(lib_domain_json "$D_DOMAIN")" 2>/dev/null || true)"
  printf '\n%s== %s ==%s\n' "$C_BLD" "$D_DOMAIN" "$C_RST"
  lib_print_kv "Application"  "${D_HOME}/app"
  if [[ -n "$APP_GIT_URL" ]]; then lib_print_kv "Repository" "${APP_GIT_URL}${APP_GIT_BRANCH:+ (${APP_GIT_BRANCH})}"; fi
  lib_print_kv "Last deploy"  "${last:-never} (log: $(lib_domain_state_dir "$D_DOMAIN")/deploy.log)"
  lib_print_kv "Start"        "$start"
  lib_print_kv "Port"         "127.0.0.1:${APP_PORT} (given to the app as PORT)"
  lib_print_kv "Memory limit" "${APP_MEMORY:-none}"
  lib_print_kv "Wanted state" "$wanted"
  lib_print_kv "Service"      "${unit}: $(_svc_state "$unit")${boot}"
  if lib_service_active "$unit"; then
    info="$(_app_process_info web)"
    read -r st cpu mem up rs <<<"$info"
    lib_print_kv "Process"    "${st:-not in PM2}, cpu ${cpu:-0}%, memory $(( ${mem:-0} / 1048576 )) MB, up $(_app_age_ms "${up:-0}"), restarts ${rs:-0}"
  fi
  lib_print_kv "Logs"         "${D_HOME}/.pm2/logs/web-out.log, web-error.log (setup.sh app logs ${D_DOMAIN})"
  lib_print_kv "Environment"  "$(jq -r 'keys | length' <<<"$(lib_app_env_json "$D_DOMAIN")") variable(s) (setup.sh app env ${D_DOMAIN} list)"
  if [[ "$(lib_app_workers_json "$D_DOMAIN")" != "[]" ]]; then
    printf '\n%s%-16s %-8s %-14s %-12s %8s  %s%s\n' "$C_BLD" WORKER KIND PORT/SCHEDULE STATUS RESTARTS START "$C_RST"
    info=""; if lib_service_active "$unit"; then info="$(_app_jlist)"; fi
    _app_worker_rows "$(_app_workers_status "$(lib_app_workers_json "$D_DOMAIN")" "$info")"
  fi
  printf '\n'
}

# "<domain> [--process NAME]": loads the site, sets APP_ONLY
_app_parse_process() {   # command domain [--process NAME]
  local cmd="$1" domain="${2:-}" a=""
  APP_ONLY=""
  if (($# >= 2)); then shift 2; else shift; fi
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --process) APP_ONLY="${1:-}"; shift ;;
      *) lib_die "Unknown option for app ${cmd}: ${a}" "" "setup.sh app ${cmd} <domain> [--process NAME]" ;;
    esac
  done
  _app_load_site "$domain"
  if [[ -n "$APP_ONLY" && "$APP_ONLY" != web ]] && ! lib_app_worker_get "$D_DOMAIN" "$APP_ONLY" >/dev/null; then
    lib_die "${D_DOMAIN} has no process named '${APP_ONLY}'" "" "setup.sh app worker ${D_DOMAIN} list"
  fi
  return 0
}

# Want (1) or do not want (0) the process named, or the application with all its workers.
_app_set_enabled() {   # 0|1 [name]
  if [[ -z "${2:-}" || "$2" == web ]]; then APP_ENABLED="$1"; lib_app_state_write "$D_DOMAIN"; fi
  if [[ "${2:-}" != web ]]; then
    lib_json_set "$(lib_domain_json "$D_DOMAIN")" \
      'if has("workers") then .workers |= map(if $n == "" or .name == $n then .enabled = ($en == "1") else . end) else . end' \
      --arg n "${2:-}" --arg en "$1"
  fi
}

# How a worker came out of a change. A process gets a few seconds first: one that crashes at
# once still looks "online" for a moment.
_app_worker_report() {   # name
  local w="" info="" st="" rs="" cron=""
  w="$(lib_app_worker_get "$D_DOMAIN" "$1")" || return 0
  cron="$(jq -r '.cron // empty' <<<"$w")"
  if [[ "$(jq -r '.enabled != false' <<<"$w")" != "true" ]]; then
    lib_ok "$([[ -n "$cron" ]] && printf 'job' || printf 'worker') $1 of ${D_DOMAIN}: stopped"; return 0
  fi
  if [[ -n "$cron" ]]; then lib_ok "job $1 of ${D_DOMAIN}: ${cron} (log: ${D_HOME}/.pm2/logs/$1-job.log)"; return 0; fi
  (( OPT_DRY_RUN )) && return 0
  if [[ "$APP_RESULT" == "failed" ]] || ! lib_service_active "$(lib_app_unit_name "$D_IDENT")"; then
    lib_warn "worker $1 of ${D_DOMAIN} is not running: ${APP_RESULT_MSG}"; return 0
  fi
  sleep "$APP_SETTLE_SECONDS"
  info="$(_app_process_info "$1")"
  read -r st _ _ _ rs <<<"$info"
  if [[ "$st" == online && "${rs:-0}" == 0 ]]; then lib_ok "worker $1 of ${D_DOMAIN}: online"
  else lib_warn "worker $1 of ${D_DOMAIN} does not stay up (PM2 status: ${st:-missing}, ${rs:-0} restart(s)); see: setup.sh app logs ${D_DOMAIN} --process $1"; fi
  return 0
}

_app_report_for() {   # process ("" | web | worker name)
  if [[ -n "$1" && "$1" != web ]]; then _app_worker_report "$1"; else _app_report; fi
}

lib_app_start() {   # domain [--process NAME]
  _app_parse_process start "$@"
  _app_site_lock "$D_DOMAIN"
  _app_set_enabled 1 "$APP_ONLY"
  lib_app_apply
  _app_jobs_sync
  _app_report_for "$APP_ONLY"
}

lib_app_stop() {   # domain [--process NAME]
  _app_parse_process stop "$@"
  _app_site_lock "$D_DOMAIN"
  _app_set_enabled 0 "$APP_ONLY"
  lib_app_apply
  _app_jobs_sync
  _app_report_for "$APP_ONLY"
}

lib_app_restart() {   # domain [--process NAME]
  local w=""
  _app_parse_process restart "$@"
  _app_site_lock "$D_DOMAIN"
  if [[ "$APP_ONLY" == web ]]; then
    (( APP_ENABLED )) || lib_die "The web process of ${D_DOMAIN} is stopped" "" "setup.sh app start ${D_DOMAIN} --process web"
  elif [[ -n "$APP_ONLY" ]]; then
    w="$(lib_app_worker_get "$D_DOMAIN" "$APP_ONLY")"
    [[ -z "$(jq -r '.cron // empty' <<<"$w")" ]] || lib_die "${APP_ONLY} is a scheduled job: it has no process to restart" "" "run it now with: setup.sh app worker ${D_DOMAIN} run ${APP_ONLY}"
    [[ "$(jq -r '.enabled != false' <<<"$w")" == "true" ]] || lib_die "Worker ${APP_ONLY} of ${D_DOMAIN} is stopped" "" "setup.sh app start ${D_DOMAIN} --process ${APP_ONLY}"
  elif (( ! APP_ENABLED )) && ! jq -e 'any(.[]; (.cron // "") == "" and .enabled != false)' <<<"$(lib_app_workers_json "$D_DOMAIN")" >/dev/null; then
    lib_die "Nothing of ${D_DOMAIN} is running" "" "setup.sh app start ${D_DOMAIN}"
  fi
  lib_app_apply restart "$APP_ONLY"
  _app_report_for "$APP_ONLY"
}

# Runs without the global lock (setup.sh) because a build can take minutes. The domain.json
# writes here (repository, last deploy, enabling a stopped app) are small; a backup updating
# the same file at that instant could in theory overwrite one, and the next deploy writes it
# again.
lib_app_deploy() {   # domain [--git URL] [--branch B]
  local domain="${1:-}" a="" url="" branch=""
  if (($# > 0)); then shift; fi
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --git)    url="${1:-}"; shift ;;
      --branch) branch="${1:-}"; shift ;;
      *) lib_die "Unknown option for app deploy: ${a}" "" "setup.sh app deploy <domain> [--git URL [--branch B]]" ;;
    esac
  done
  [[ -z "$url" ]] || lib_app_git_url_valid "$url" || lib_die "Refused repository URL" \
    "use https://host/owner/repo.git, git@host:owner/repo.git or ssh://git@host/owner/repo.git, without a user, password or token inside" \
    "for a private repository: setup.sh app deploy-key ${domain:-<domain>}, then use the SSH URL"
  [[ -z "$branch" ]] || lib_app_git_branch_valid "$branch" || lib_die "Invalid branch '${branch}'" "" "--branch main"
  _app_load_site "$domain"
  _app_site_lock "$D_DOMAIN"
  if [[ -n "$url" && "$url" != "$APP_GIT_URL" ]]; then
    APP_GIT_URL="$url"
    APP_GIT_BRANCH=""   # another repository: its own default branch, unless --branch names one
  fi
  if [[ -n "$branch" ]]; then APP_GIT_BRANCH="$branch"; fi
  if [[ -n "$branch" && -z "$APP_GIT_URL" ]]; then lib_die "--branch needs a repository" "" "setup.sh app deploy ${D_DOMAIN} --git <url> --branch ${branch}"; fi
  # a new repository or branch is recorded only once a deploy from it has worked
  lib_app_deploy_run || lib_die "Deploy of ${D_DOMAIN} failed" "$APP_BUILD_ERROR" \
    "fix it, then run: setup.sh app deploy ${D_DOMAIN}   (output: $(lib_domain_state_dir "$D_DOMAIN")/deploy.log)"
  # what was stopped on purpose stays stopped; what runs starts again on the new code
  lib_app_state_write "$D_DOMAIN"
  lib_app_apply restart
  _app_report
}

lib_app_deploy_key() {   # domain
  local pub=""
  _app_load_site "${1:-}"
  if ! _app_user_file .ssh/id_ed25519; then
    if (( OPT_DRY_RUN )); then lib_info "[dry-run] would create an ed25519 deploy key for ${D_USER} in ${D_HOME}/.ssh"; return 0; fi
    _app_as "$D_HOME" sh -c 'umask 077 && mkdir -p .ssh' || lib_die "Could not create ${D_HOME}/.ssh as ${D_USER}" "" "check the ownership of ${D_HOME}"
    _app_as "$D_HOME" ssh-keygen -q -t ed25519 -N '' -C "lomp-deploy@${D_DOMAIN}" -f .ssh/id_ed25519 \
      || lib_die "ssh-keygen failed for ${D_USER}" "" "apt-get install openssh-client"
    lib_ok "Deploy key created for ${D_DOMAIN}"
  fi
  # the site user controls this file: bounded, and only a public key line is ever printed
  pub="$(_app_as "$D_HOME" timeout 5 head -c 4096 -- .ssh/id_ed25519.pub 2>/dev/null \
    | grep -m 1 -E '^ssh-ed25519 [A-Za-z0-9+/=]+( [A-Za-z0-9@._-]*)?$' || true)"
  [[ -n "$pub" ]] || lib_die "The public deploy key of ${D_DOMAIN} cannot be read" "" "ls -l ${D_HOME}/.ssh"
  printf '\n%sPublic deploy key of %s%s\n\n%s\n\n' "$C_BLD" "$D_DOMAIN" "$C_RST" "$pub"
  lib_note "Add it as a read-only deploy key of the repository (GitHub: Settings > Deploy keys;"
  lib_note "GitLab: Settings > Repository > Deploy keys), then deploy with the SSH URL:"
  lib_note "  setup.sh app deploy ${D_DOMAIN} --git git@github.com:owner/repo.git --branch main"
  return 0
}

lib_app_logs() {   # domain [--process NAME] [--out|--error] [-n LINES]
  local domain="${1:-}" which="both" lines=50 a="" shown="" only="" name="" kind=""
  local -a files=()
  if (($# > 0)); then shift; fi
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --out)     which="out" ;;
      --error)   which="error" ;;
      --process) only="${1:-}"; shift ;;
      -n)        lines="${1:-50}"; shift ;;
      *) lib_die "Unknown option for app logs: ${a}" "" "setup.sh app logs <domain> [--process NAME] [--out|--error] [-n LINES]" ;;
    esac
  done
  [[ "$lines" =~ ^[0-9]+$ ]] || lib_die "Invalid -n '${lines}'" "" "-n 100"
  _app_load_site "$domain"
  if [[ -n "$only" && "$only" != web ]] && ! lib_app_worker_get "$D_DOMAIN" "$only" >/dev/null; then
    lib_die "${D_DOMAIN} has no process named '${only}'" "" "setup.sh app worker ${D_DOMAIN} list"
  fi
  # the process named, or the application and every worker; a job has one log for both streams
  while read -r name kind; do
    [[ -n "$name" ]] || continue
    if [[ "$kind" == job ]]; then
      if [[ "$which" == both ]]; then files+=(".pm2/logs/${name}-job.log"); fi
      continue
    fi
    if [[ "$which" != "error" ]]; then files+=(".pm2/logs/${name}-out.log"); fi
    if [[ "$which" != "out" ]]; then files+=(".pm2/logs/${name}-error.log"); fi
  done < <(jq -r --arg n "$only" '([{name: "web", cron: null}] + .) | .[] | select($n == "" or .name == $n) | "\(.name) \(if (.cron // "") == "" then "process" else "job" end)"' <<<"$(lib_app_workers_json "$D_DOMAIN")" || true)
  ((${#files[@]} > 0)) || lib_die "No log to follow" "" "setup.sh app worker ${D_DOMAIN} list"
  shown="${files[*]/#/${D_HOME}/}"
  printf '%sFollowing %s (Ctrl-C to stop)%s\n' "$C_DIM" "$shown" "$C_RST"
  # read as the site user: a log replaced by a link cannot show root's files to anyone
  _app_as "$D_HOME" tail -n "$lines" -F "${files[@]}" || true
}

lib_app_set() {   # domain [--port N] [--start CMD | --script FILE] [--memory 512M|none] [--no-git]
  local domain="${1:-}" a="" port="" start="" script="" mem="" why="" port_changed=0 nogit=0
  if (($# > 0)); then shift; fi
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --port)   port="${1:-}"; shift ;;
      --start)  start="${1:-}"; shift ;;
      --script) script="${1:-}"; shift ;;
      --memory) mem="${1:-}"; shift ;;
      --no-git) nogit=1 ;;
      *) lib_die "Unknown option for app set: ${a}" "" "setup.sh app set <domain> [--port N] [--start CMD | --script FILE] [--memory 512M|none] [--no-git]" ;;
    esac
  done
  [[ -n "${port}${start}${script}${mem}" ]] || (( nogit )) || lib_die "Nothing to change" "" "setup.sh app set ${domain:-<domain>} --port 3001"
  [[ -z "$start" || -z "$script" ]] || lib_die "--start and --script cannot be combined" "" "use one of them"
  [[ -z "$start" ]] || lib_app_start_valid "$start" || lib_die "Invalid --start '${start}'" \
    "the command runs without a shell: words only, no quotes, pipes or &&" "put it into a package.json script and use --start \"npm run <name>\""
  [[ -z "$script" ]] || lib_app_script_valid "$script" || lib_die "Invalid --script '${script}'" "a file inside the app directory, such as dist/main.js" "--script dist/main.js"
  [[ -z "$mem" || "$mem" == "none" || "$mem" =~ ^[0-9]+[MG]$ ]] || lib_die "Invalid --memory '${mem}'" "use e.g. 512M, 1G or none" "--memory 512M"
  _app_load_site "$domain" optional
  if (( ! APP_PRESENT )); then
    (( ! nogit )) || lib_die "${D_DOMAIN} runs no Node.js application" "" "setup.sh app list"
    [[ "$D_MODE" == "proxy" ]] || lib_die "${D_DOMAIN} is a ${D_MODE} site" "a PM2 application needs a Node.js (proxy) site" \
      "create one with: setup.sh add app.example.com --node, or publish an app under a path: setup.sh proxy add ${D_DOMAIN} /api/ 127.0.0.1:3001"
    if [[ -z "$port" ]]; then
      [[ "$D_PROXY" =~ ^(127\.0\.0\.1|localhost):([0-9]+)$ ]] || lib_die "${D_DOMAIN} proxies to ${D_PROXY}, which is not on this server" "" "choose the port to run the app on: setup.sh app set ${D_DOMAIN} --port 3000"
      port="${BASH_REMATCH[2]}"
      APP_PORT=""
    fi
    APP_START="npm start"; APP_ENABLED=1
    lib_info "${D_DOMAIN} gets a PM2 application on port ${port}"
  fi
  if [[ -n "$port" && "$port" != "$APP_PORT" ]]; then
    why="$(lib_app_port_conflict "$port" "$D_DOMAIN" || true)"
    [[ -z "$why" ]] || lib_die "Port ${port} cannot be used for ${D_DOMAIN}" "$why" "choose another port"
    APP_PORT="$((10#$port))"; port_changed=1
  fi
  if [[ -n "$start" ]]; then APP_START="$start"; APP_SCRIPT=""; fi
  if [[ -n "$script" ]]; then APP_SCRIPT="$script"; APP_START=""; fi
  if [[ "$mem" == "none" ]]; then APP_MEMORY=""; elif [[ -n "$mem" ]]; then APP_MEMORY="$mem"; fi
  _app_site_lock "$D_DOMAIN"
  lib_domain_state_guard "$D_DOMAIN"
  lib_app_state_write "$D_DOMAIN"
  if (( port_changed )) && [[ "$D_PROXY" != "127.0.0.1:${APP_PORT}" ]]; then
    D_PROXY="127.0.0.1:${APP_PORT}"
    lib_domain_state_save
    lib_domain_apply_config "application port ${APP_PORT} for ${D_DOMAIN}"
  fi
  if (( nogit )) && [[ -n "$APP_GIT_URL" ]]; then
    lib_json_set "$(lib_domain_json "$D_DOMAIN")" '.app |= del(.git)'
    lib_ok "${D_DOMAIN} no longer deploys from ${APP_GIT_URL}; the checkout in ${D_HOME}/app stays as it is"
    APP_GIT_URL=""; APP_GIT_BRANCH=""
  fi
  lib_rollback_clear
  if [[ -z "${port}${start}${script}${mem}" ]]; then return 0; fi
  lib_app_apply restart
  _app_report
}

_app_read_secret() {   # prompt -> value on stdout (hidden on a terminal, else all of stdin)
  local v=""
  if [[ -t 0 ]]; then
    printf '%s%s%s: ' "$C_BLD" "$1" "$C_RST" >&2
    IFS= read -r -s v || v=""
    printf '\n' >&2
  else
    IFS= read -r -d '' v || true
    v="${v%$'\n'}"
  fi
  printf '%s' "$v"
}

lib_app_env_print() {   # domain show(0|1)
  local env=""
  env="$(lib_app_env_json "$1")"
  if [[ "$env" == "{}" ]]; then printf '(no variables - add one with: setup.sh app env %s set NAME)\n' "$1"; return 0; fi
  if [[ "$2" == "1" ]]; then
    jq -r 'to_entries[] | "\(.key)=\(.value)"' <<<"$env"
  else
    jq -r 'to_entries[] | "\(.key)  (\(.value | tostring | length) characters)"' <<<"$env"
    lib_note "values are hidden; add --show to print them"
  fi
  return 0
}

lib_app_env_import_db() {   # the site in D_*
  local f=""
  lib_db_info_load "$D_DOMAIN" || lib_die "${D_DOMAIN} has no database" "" "create it first: setup.sh db ${D_DOMAIN}"
  lib_db_tcp_account_ensure "$D_DOMAIN" || lib_die "Could not let ${DBI_USER} log in over TCP" "SQL error (see the log)" "check MariaDB"
  f="$(lib_app_env_file "$D_DOMAIN")"
  if (( ! OPT_DRY_RUN )) && [[ ! -s "$f" ]]; then (umask 077; printf '{}\n' >"$f"); fi
  export LOMP_APP_DB_PASS="$DBI_PASS"
  lib_json_set "$f" '. + {DB_HOST: "127.0.0.1", DB_PORT: "3306", DB_SOCKET: $sock, DB_NAME: $n, DB_USER: $u,
      DB_PASSWORD: env.LOMP_APP_DB_PASS,
      DATABASE_URL: ("mysql://" + ($u | @uri) + ":" + (env.LOMP_APP_DB_PASS | @uri) + "@127.0.0.1:3306/" + ($n | @uri))}' \
    --arg sock "$DB_SOCKET" --arg n "$DBI_NAME" --arg u "$DBI_USER"
  unset LOMP_APP_DB_PASS
  lib_ok "DB_HOST, DB_PORT, DB_SOCKET, DB_NAME, DB_USER, DB_PASSWORD and DATABASE_URL set for ${D_DOMAIN}"
}

lib_app_env() {   # domain list [--show] | set NAME | unset NAME... | import-db
  local domain="${1:-}" action="${2:-list}" f="" k="" v=""
  if (($# >= 2)); then shift 2; elif (($# == 1)); then shift; fi
  _app_load_site "$domain"
  f="$(lib_app_env_file "$D_DOMAIN")"
  case "$action" in
    list)
      if [[ "${1:-}" == "--show" ]]; then lib_app_env_print "$D_DOMAIN" 1; else lib_app_env_print "$D_DOMAIN" 0; fi
      return 0 ;;
    set)
      k="${1:-}"
      if (($# != 1)); then
        lib_die "env set takes one name; the value is read from standard input" "" "printf '%s' 'the value' | setup.sh app env ${D_DOMAIN} set ${k:-NAME}"
      fi
      lib_app_env_key_valid "$k" || lib_die "Invalid variable name '${k}'" \
        "use A-Z, 0-9 and _ (PORT, HOME, PATH, LANG and PM2_* are set by lompstack)" "setup.sh app env ${D_DOMAIN} set API_KEY"
      v="$(_app_read_secret "Value for ${k}")"
      _app_site_lock "$D_DOMAIN"
      if (( ! OPT_DRY_RUN )) && [[ ! -s "$f" ]]; then (umask 077; printf '{}\n' >"$f"); fi
      export LOMP_APP_ENV_VALUE="$v"
      lib_json_set "$f" '.[$k] = env.LOMP_APP_ENV_VALUE' --arg k "$k"
      unset LOMP_APP_ENV_VALUE
      lib_log_write INFO "application variable ${k} set for ${D_DOMAIN} (value not logged)"
      lib_ok "${k} set for ${D_DOMAIN}" ;;
    unset)
      (($# > 0)) || lib_die "Name the variables to remove" "" "setup.sh app env ${D_DOMAIN} unset API_KEY"
      for k in "$@"; do
        lib_app_env_key_valid "$k" || lib_die "Invalid variable name '${k}'" "" "setup.sh app env ${D_DOMAIN} list"
      done
      _app_site_lock "$D_DOMAIN"
      if [[ -s "$f" ]]; then
        for k in "$@"; do lib_json_set "$f" 'del(.[$k])' --arg k "$k"; done
      fi
      lib_ok "removed from ${D_DOMAIN}: $*" ;;
    import-db)
      _app_site_lock "$D_DOMAIN"
      lib_app_env_import_db ;;
    *) lib_die "Unknown env action '${action}'" "" "setup.sh app env <domain> list | set NAME | unset NAME... | import-db" ;;
  esac
  # the running processes only see the change after a fresh start (a removed variable
  # survives a reload in PM2); scheduled jobs read the env file at every run
  lib_app_apply restart
  _app_report
  return 0
}

# =============================================================================
#  Workers and scheduled jobs
# =============================================================================
# The workers with what PM2 says about them - never their environment: the process list,
# which carries it, reaches jq through jq's own environment.
_app_workers_status() {   # workers JSON, PM2 process list ("" when PM2 does not run)
  LOMP_APP_JLIST="${2:-}" jq -c '(($ENV.LOMP_APP_JLIST // "") | try fromjson catch []) as $pl
    | map(. as $w | (if ($pl | type) == "array" then [$pl[] | select(.name == $w.name)][0] else null end) as $p
      | {name, start, cwd: (.cwd // "app"), port, schedule: .cron, timeout, memory, enabled: (.enabled != false),
         kind: (if (.cron // "") == "" then "process" else "job" end),
         status: (if .enabled == false then "stopped" elif (.cron // "") != "" then "scheduled"
                  elif $p == null then "not running" else $p.pm2_env.status end),
         restarts: ($p.pm2_env.restart_time // 0), cpu: ($p.monit.cpu // 0), memory_bytes: ($p.monit.memory // 0)})' <<<"$1"
}

_app_worker_rows() {   # workers status JSON
  local n="" k="" w="" s="" r="" c=""
  jq -r '.[] | [.name, .kind, (if .kind == "job" then .schedule else ((.port // "-") | tostring) end), .status,
                (if .kind == "job" then "-" else (.restarts | tostring) end), .start] | @tsv' <<<"$1" \
    | while IFS=$'\t' read -r n k w s r c; do
        printf '%-16s %-8s %-14s %-12s %8s  %s\n' "$n" "$k" "$w" "$s" "$r" "$c"
      done || true
}

lib_app_worker_list() {   # [--json]   (the site in D_*)
  local workers="" jl=""
  workers="$(lib_app_workers_json "$D_DOMAIN")"
  if lib_service_active "$(lib_app_unit_name "$D_IDENT")"; then jl="$(_app_jlist)"; fi
  if [[ "${1:-}" == "--json" ]] || (( OPT_JSON )); then _app_workers_status "$workers" "$jl"; printf '\n'; return 0; fi
  if [[ "$workers" == "[]" ]]; then
    printf '(no workers - add one with: setup.sh app worker %s add NAME --start CMD [--cron SCHEDULE])\n' "$D_DOMAIN"
    return 0
  fi
  printf '%s%-16s %-8s %-14s %-12s %8s  %s%s\n' "$C_BLD" NAME KIND PORT/SCHEDULE STATUS RESTARTS START "$C_RST"
  _app_worker_rows "$(_app_workers_status "$workers" "$jl")"
  lib_note "logs: setup.sh app logs ${D_DOMAIN} --process NAME (jobs: ${D_HOME}/.pm2/logs/NAME-job.log)"
}

lib_app_worker_add() {   # name options...   (the site in D_*)
  local name="${1:-}" a="" start="" cwd="app" port="" mem="" cron="" timeout="" why="" home="" real="" w=""
  local usage="setup.sh app worker <domain> add NAME --start CMD [--cwd DIR] [--port N] [--memory 256M] | --cron SCHEDULE [--timeout 1h]"
  local -a fields=()
  if (($# > 0)); then shift; fi
  lib_app_worker_name_valid "$name" || lib_die "Invalid worker name '${name}'" \
    "use a-z, 0-9 and -, starting with a letter; web and all are taken" "setup.sh app worker ${D_DOMAIN} add queue --start \"node worker.js\""
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --start)   start="${1:-}"; shift ;;
      --cwd)     cwd="${1:-}"; shift ;;
      --port)    port="${1:-}"; shift ;;
      --memory)  mem="${1:-}"; shift ;;
      --cron)    cron="${1:-}"; shift ;;
      --timeout) timeout="${1:-}"; shift ;;
      *) lib_die "Unknown option for worker add: ${a}" "" "$usage" ;;
    esac
  done
  [[ -n "$start" ]] || lib_die "--start is missing" "the command the worker runs, e.g. \"node worker.js\" or \"npm run queue\"" "$usage"
  lib_app_start_valid "$start" || lib_die "Invalid --start '${start}'" \
    "the command runs without a shell: words only, no quotes, pipes or &&" "put it into a package.json script and use --start \"npm run <name>\""
  lib_app_cwd_valid "$cwd" || lib_die "Invalid --cwd '${cwd}'" "a directory inside ${D_HOME}, written relative to it" "--cwd app/worker"
  [[ -z "$mem" || "$mem" =~ ^[0-9]+[MG]$ ]] || lib_die "Invalid --memory '${mem}'" "use e.g. 256M or 1G" "--memory 256M"
  if [[ -n "$cron" ]]; then
    lib_app_cron_valid "$cron" || lib_die "Invalid --cron '${cron}'" \
      "five fields - minute hour day month weekday - such as \"*/5 * * * *\", or @hourly, @daily, @weekly, @monthly" "--cron \"30 3 * * *\""
    [[ -z "$port" ]] || lib_die "A scheduled job takes no --port" "" "leave out --cron for a long-running worker with a port"
    [[ -z "$mem" ]] || lib_die "A scheduled job takes no --memory" "" "--timeout limits how long a run may take"
    read -r -a fields <<<"$cron"; cron="${fields[*]}"
    timeout="${timeout:-$APP_JOB_TIMEOUT_DEFAULT}"
    lib_app_timeout_valid "$timeout" || lib_die "Invalid --timeout '${timeout}'" "a number followed by s, m, h or d" "--timeout 30m"
  elif [[ -n "$timeout" ]]; then
    lib_die "--timeout belongs to a scheduled job" "" "add --cron \"SCHEDULE\", or leave out --timeout"
  fi
  if lib_app_worker_get "$D_DOMAIN" "$name" >/dev/null; then
    lib_die "${D_DOMAIN} already has a worker named ${name}" "" "remove it first: setup.sh app worker ${D_DOMAIN} remove ${name}"
  fi
  if [[ -n "$port" ]]; then
    why="$(lib_app_port_conflict "$port" "$D_DOMAIN" || true)"
    if [[ -z "$why" && "$((10#$port))" == "$APP_PORT" ]]; then why="it is the port of the ${D_DOMAIN} application itself"; fi
    if [[ -z "$why" ]] && jq -e --argjson p "$((10#$port))" 'any(.[]; .port == $p)' <<<"$(lib_app_workers_json "$D_DOMAIN")" >/dev/null; then
      why="another worker of ${D_DOMAIN} has it"
    fi
    [[ -z "$why" ]] || lib_die "Port ${port} cannot be used for worker ${name}" "$why" "choose another port"
    port="$((10#$port))"
  fi
  # asked as the site user, links included: the directory must not lead out of the home
  if (( ! OPT_DRY_RUN )); then
    home="$(_app_as "$D_HOME" pwd -P 2>/dev/null || true)"
    real="$(_app_as "$D_HOME" realpath -m -- "$cwd" 2>/dev/null || true)"
    [[ -n "$home" && "$real" == "${home}/"* ]] || lib_die "--cwd ${cwd} leads outside ${D_HOME}" "" "use a directory inside the site's home"
    _app_as "$D_HOME" test -d "$cwd" 2>/dev/null || lib_warn "${D_HOME}/${cwd} does not exist yet; the worker cannot start before it does"
  fi
  w="$(jq -cn --arg n "$name" --arg s "$start" --arg c "$cwd" --arg p "$port" --arg m "$mem" --arg cr "$cron" --arg t "$timeout" \
    '{name: $n, start: $s, cwd: $c, port: (if $p == "" then null else ($p | tonumber) end), memory: (if $m == "" then null else $m end),
      cron: (if $cr == "" then null else $cr end), timeout: (if $t == "" then null else $t end), enabled: true}')"
  _app_site_lock "$D_DOMAIN"
  lib_app_worker_state_set "$D_DOMAIN" "$w"
  lib_app_apply
  _app_jobs_sync
  _app_worker_report "$name"
}

lib_app_worker_remove() {   # name   (the site in D_*)
  local name="${1:-}"
  lib_app_worker_get "$D_DOMAIN" "$name" >/dev/null || lib_die "${D_DOMAIN} has no worker named '${name}'" "" "setup.sh app worker ${D_DOMAIN} list"
  _app_site_lock "$D_DOMAIN"
  lib_app_worker_state_del "$D_DOMAIN" "$name"
  lib_app_apply
  _app_jobs_sync
  if (( ! OPT_DRY_RUN )); then _app_as "$D_HOME" rm -f -- ".pm2/jobs/${name}.sh" ".pm2/jobs/${name}.lock" 2>/dev/null || true; fi
  lib_ok "worker ${name} removed from ${D_DOMAIN} (its logs stay in ${D_HOME}/.pm2/logs)"
}

# A scheduled job, now: the same script cron starts, so the same lock, timeout and log.
lib_app_worker_run() {   # name   (the site in D_*)
  local name="${1:-}" w="" rc=0
  w="$(lib_app_worker_get "$D_DOMAIN" "$name")" || lib_die "${D_DOMAIN} has no worker named '${name}'" "" "setup.sh app worker ${D_DOMAIN} list"
  [[ -n "$(jq -r '.cron // empty' <<<"$w")" ]] || lib_die "${name} is a long-running worker, not a scheduled job" "" "setup.sh app restart ${D_DOMAIN} --process ${name}"
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would run job ${name} of ${D_DOMAIN} now, as ${D_USER}"; return 0; fi
  _app_prepare_home || lib_die "Could not prepare ${D_HOME}/.pm2 as ${D_USER}" "" "check the ownership of ${D_HOME}"
  lib_app_render_job "$w" | _app_write_as_user "${D_HOME}/.pm2/jobs/${name}.sh" \
    || lib_die "Could not write the script of job ${name} as ${D_USER}" "" "check the ownership of ${D_HOME}/.pm2"
  lib_info "Running job ${name} of ${D_DOMAIN} as ${D_USER}; its output goes to ${D_HOME}/.pm2/logs/${name}-job.log"
  _app_as "$D_HOME" /bin/bash ".pm2/jobs/${name}.sh" </dev/null || rc=$?
  _app_as "$D_HOME" timeout 5 tail -n 15 -- ".pm2/logs/${name}-job.log" 2>/dev/null || true
  (( rc == 0 )) || lib_die "Job ${name} of ${D_DOMAIN} ended with status ${rc}" "" "see ${D_HOME}/.pm2/logs/${name}-job.log"
  lib_ok "job ${name} of ${D_DOMAIN} done"
}

lib_app_worker() {   # domain list | add NAME ... | remove NAME | run NAME
  local domain="${1:-}" action="${2:-list}"
  case "$domain" in ""|help|-h|--help) lib_app_usage; [[ -n "$domain" ]] || lib_die "Domain missing" "" "setup.sh app worker <domain> list"; return 0 ;; esac
  if (($# >= 2)); then shift 2; else shift; fi
  _app_load_site "$domain"
  case "$action" in
    list)   lib_app_worker_list "$@" ;;
    add)    lib_app_worker_add "$@" ;;
    remove) lib_app_worker_remove "$@" ;;
    run)    lib_app_worker_run "$@" ;;
    help|-h|--help) lib_app_usage ;;
    *) lib_die "Unknown worker action '${action}'" "" "setup.sh app worker <domain> list | add NAME --start CMD ... | remove NAME | run NAME" ;;
  esac
}
