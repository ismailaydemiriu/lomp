#!/usr/bin/env bash
# lib/app.sh - Node.js applications run by PM2: one PM2 daemon per site, started by systemd
#              as that site's own user, never as root.
#
#   state  domain.json .app{port, start, script, memory, enabled}; environment values live in
#          the root-only app-env.json next to it, never in domain.json ("list --json" prints it)
#   files  /etc/systemd/system/pm2-<ident>.service   root, rendered by lompstack
#          /home/<domain>/.pm2/lomp.ecosystem.json    0600, written AS the site user
#          /home/<domain>/.pm2/lomp.env               0600, the same values for builds
#          /home/<domain>/.pm2/logs/web-{out,error}.log
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
# "add --node" options, kept apart from D_*, which the add flow reloads from domain.json
APP_OPT_NODE=0 APP_OPT_PORT="" APP_OPT_START="" APP_OPT_SCRIPT=""
# outcome of lib_app_apply (running | waiting | stopped | failed) and a sentence for humans
APP_RESULT="" APP_RESULT_MSG="" APP_BUILD_ERROR="" APP_FILE_CHANGED=0

lib_app_usage() {
  cat <<'EOF'
Usage: setup.sh app list [--json]
       setup.sh app status <domain>
       setup.sh app start | stop | restart <domain>
       setup.sh app logs <domain> [--out|--error] [-n LINES]
       setup.sh app deploy <domain>     install dependencies, build, restart
       setup.sh app set <domain> [--port N] [--start "npm start" | --script dist/main.js] [--memory 512M|none]
       setup.sh app env <domain> list [--show] | set NAME | unset NAME... | import-db
  Create a Node.js site with: setup.sh add app.example.com --node [--port N] [--start CMD]
  The application must listen on the port in $PORT. "env set" reads the value from standard
  input or asks for it, so it never shows up in the process list, shell history or log.
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
    set)            lib_app_set "$@" ;;
    env)            lib_app_env "$@" ;;
    help|-h|--help) lib_app_usage ;;
    *) lib_app_usage >&2; lib_die "Unknown app action '${action}'" "" "setup.sh app list | status | start | stop | restart | logs | deploy | set | env" ;;
  esac
}

# =============================================================================
#  Acting as the site user
# =============================================================================
_app_as() {   # dir cmd...   (the site in D_*)
  local dir="$1"; shift
  runuser -u "$D_USER" -- env -i -C "$dir" HOME="$D_HOME" PM2_HOME="${D_HOME}/.pm2" \
    PATH="$APP_PATH_ENV" LANG="C.UTF-8" "$@"
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
  _app_as "$D_HOME" sh -c 'umask 077 && mkdir -p .pm2/logs'
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
  f="$(lib_domain_json "$1")"
  [[ -s "$f" ]] || return 1
  [[ "$(jq -r 'has("app")' "$f" 2>/dev/null || true)" == "true" ]] || return 1
  APP_PRESENT=1
  APP_PORT="$(lib_json_get "$f" '.app.port')"
  APP_START="$(lib_json_get "$f" '.app.start')"
  APP_SCRIPT="$(lib_json_get "$f" '.app.script')"
  APP_MEMORY="$(lib_json_get "$f" '.app.memory')"
  if [[ "$(lib_json_get_raw "$f" '.app.enabled')" == "true" ]]; then APP_ENABLED=1; fi
  return 0
}

lib_app_state_write() {   # domain   (from APP_PORT APP_START APP_SCRIPT APP_MEMORY APP_ENABLED)
  lib_json_set "$(lib_domain_json "$1")" \
    '.app = ((.app // {}) + {manager: "pm2", port: ($port | tonumber), start: $start, script: $script, memory: $mem, enabled: ($en == "1")})' \
    --arg port "$APP_PORT" --arg start "$APP_START" --arg script "$APP_SCRIPT" --arg mem "$APP_MEMORY" --arg en "$APP_ENABLED"
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

# =============================================================================
#  Ports
# =============================================================================
# The site that already claims this loopback port (app port, proxy target or path proxy).
_app_port_claimed_by() {   # port [own domain] -> domain, or status 1
  local port="$1" own="${2:-}" d=""
  while read -r d; do
    [[ -n "$d" && "$d" != "$own" ]] || continue
    if jq -e --arg p "$port" '([(.app.port // empty | tostring)] + ([(.proxy.target // empty), ((.proxies // [])[].target)] | map(select(test("^(127\\.0\\.0\\.1|localhost):")) | sub("^[^:]*:"; "")))) | index($p) != null' "$(lib_domain_json "$d")" >/dev/null 2>&1; then
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
    jq -r '(.app.port // empty | tostring), ([(.proxy.target // empty), ((.proxies // [])[].target)] | map(select(test("^(127\\.0\\.0\\.1|localhost):")) | sub("^[^:]*:"; "")) | .[])' "$(lib_domain_json "$d")" 2>/dev/null || true
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

# filter_env: the application gets exactly this environment and nothing inherited from
# whoever ran pm2. exec_mode fork without "instances" (instances silently means cluster mode).
# The variables reach jq through its environment, not its argument list.
lib_app_render_ecosystem() {   # command JSON, environment JSON
  LOMP_APP_ECO_ENV="${2:-}" jq -n --argjson cmd "$1" \
    --arg home "$D_HOME" --arg port "$APP_PORT" --arg mem "$APP_MEMORY" --arg enabled "$APP_ENABLED" --arg path "$APP_PATH_ENV" \
    '(($ENV.LOMP_APP_ECO_ENV // "") | if . == "" then {} else fromjson end) as $env
     | {apps: (if $enabled != "1" then [] else [
        {name: "web", cwd: ($home + "/app"), script: $cmd.script, args: $cmd.args,
         exec_mode: "fork", filter_env: true, vizion: false, autorestart: true, merge_logs: true, time: true,
         out_file: ($home + "/.pm2/logs/web-out.log"), error_file: ($home + "/.pm2/logs/web-error.log"),
         env: ($env + {NODE_ENV: ($env.NODE_ENV // "production"), PORT: $port, HOME: $home, PATH: $path, LANG: "C.UTF-8"})}
        + (if $mem == "" then {} else {max_memory_restart: $mem} end)
      ] end)}'
}

lib_app_render_envfile() {   # environment JSON -> sourceable lines
  printf '# Managed by lompstack - change it with: setup.sh app env <domain> set NAME\n'
  jq -r 'to_entries[] | "export \(.key)=\(.value | tostring | @sh)"' <<<"$1"
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

# "status cpu memory_bytes started_ms restarts" of a process. PM2 can print a version warning
# before the JSON, so only the last line of "jlist" is read.
_app_process_info() {   # name
  local out=""
  out="$(_app_pm2 jlist 2>/dev/null | tail -n 1 || true)"
  [[ -n "$out" ]] || return 0
  jq -r --arg n "$1" '.[]? | select(.name == $n) | [.pm2_env.status, (.monit.cpu // 0), (.monit.memory // 0), (.pm2_env.pm_uptime // 0), (.pm2_env.restart_time // 0)] | map(tostring) | join(" ")' <<<"$out" 2>/dev/null || true
}

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

# Bring the site's PM2 in line with its state: ecosystem and env file (as the site user), the
# systemd unit, then the process. An application problem, including a home the site user has
# made unwritable, is reported in APP_RESULT and never fails the command: "add" must not undo
# a site because its application does not start.
lib_app_apply() {   # [restart]
  local restart="${1:-}" unit="" ufile="" pm2="" cmd="" env="" eco="" eco_changed=0 unit_changed=0 info=""
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
  cmd="$(lib_app_command_json)"
  env="$(lib_app_env_json "$D_DOMAIN")"
  if ! lib_app_render_ecosystem "$cmd" "$env" | _app_write_as_user "$eco"; then
    APP_RESULT="failed"; APP_RESULT_MSG="could not write ${eco} as ${D_USER}"; return 0
  fi
  eco_changed="$APP_FILE_CHANGED"
  if ! lib_app_render_envfile "$env" | _app_write_as_user "${D_HOME}/.pm2/lomp.env"; then
    APP_RESULT="failed"; APP_RESULT_MSG="could not write ${D_HOME}/.pm2/lomp.env as ${D_USER}"; return 0
  fi
  lib_app_render_unit "$pm2" | lib_write_file "$ufile" 0644 root:root
  if (( LIB_FILE_CHANGED )); then unit_changed=1; lib_systemctl daemon-reload; fi

  if (( ! APP_ENABLED )); then
    _app_stop_service "$unit"
    APP_RESULT="stopped"; APP_RESULT_MSG="stopped; start it with: setup.sh app start ${D_DOMAIN}"
    return 0
  fi
  if ! lib_app_runnable; then
    _app_stop_service "$unit"
    APP_RESULT="waiting"
    APP_RESULT_MSG="waiting for code: ${APP_RESULT_MSG}. Put the application into ${D_HOME}/app (owned by ${D_USER}), then run: setup.sh app deploy ${D_DOMAIN}"
    return 0
  fi
  if (( OPT_DRY_RUN )); then APP_RESULT="running"; APP_RESULT_MSG="[dry-run] would enable and start ${unit}"; return 0; fi

  lib_systemctl enable "$unit" >/dev/null 2>&1 || true
  if ! lib_service_active "$unit"; then
    if ! lib_systemctl start "$unit"; then APP_RESULT="failed"; APP_RESULT_MSG="${unit} did not start (journalctl -u ${unit})"; return 0; fi
  elif (( unit_changed )); then
    if ! lib_systemctl restart "$unit"; then APP_RESULT="failed"; APP_RESULT_MSG="${unit} did not restart (journalctl -u ${unit})"; return 0; fi
  elif (( eco_changed )) || [[ "$restart" == "restart" ]]; then
    # delete + start, not reload: a reload keeps the old script, cwd and removed variables
    _app_pm2 delete web >/dev/null 2>&1 || true
    if ! lib_run _app_pm2 start "$eco" --only web; then APP_RESULT="failed"; APP_RESULT_MSG="pm2 could not start the application (setup.sh app logs ${D_DOMAIN})"; return 0; fi
  fi
  if lib_app_wait_port "$APP_PORT" 30; then
    APP_RESULT="running"; APP_RESULT_MSG="running on 127.0.0.1:${APP_PORT}"
  else
    info="$(_app_process_info web)"
    APP_RESULT="failed"
    APP_RESULT_MSG="nothing listens on 127.0.0.1:${APP_PORT} after 30 s (PM2 status: ${info%% *}); the application must listen on process.env.PORT - see: setup.sh app logs ${D_DOMAIN}"
  fi
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

# Install the dependencies and build, as the site user, with the application's environment
# loaded from its env file, so no value ever appears on a command line.
lib_app_build() {   # -> status; APP_BUILD_ERROR says why
  local dir="${D_HOME}/app" files="" install="" run="npm run" script="" rc=0
  APP_BUILD_ERROR=""
  # which of these exist, asked as the site user
  files=" $(_app_as "$D_HOME" sh -c 'cd app 2>/dev/null || exit 0
    for f in package.json pnpm-lock.yaml yarn.lock package-lock.json npm-shrinkwrap.json; do
      if [ -f "$f" ] && [ ! -L "$f" ]; then printf "%s " "$f"; fi
    done' 2>/dev/null || true) "
  if [[ "$files" != *" package.json "* ]]; then APP_BUILD_ERROR="there is no package.json in ${dir}"; return 1; fi
  if [[ "$files" == *" pnpm-lock.yaml "* ]]; then install="corepack pnpm install --frozen-lockfile"; run="corepack pnpm run"
  elif [[ "$files" == *" yarn.lock "* ]]; then install="corepack yarn install"; run="corepack yarn run"
  elif [[ "$files" == *" package-lock.json "* || "$files" == *" npm-shrinkwrap.json "* ]]; then install="npm ci --include=dev"
  else install="npm install --include=dev"; fi
  if [[ "$install" == corepack* ]] && ! lib_have corepack; then
    APP_BUILD_ERROR="the project uses ${install#corepack }, which needs corepack (npm install -g corepack)"
    return 1
  fi
  script="$install"
  if [[ -n "$(_app_package_script build)" ]]; then script+=" && ${run} build"; fi
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would run as ${D_USER} in ${dir}: ${script}"; return 0; fi
  lib_info "As ${D_USER} in ${dir}: ${script}"
  _app_as "$dir" bash -c 'set -a; if [ -f "$HOME/.pm2/lomp.env" ]; then . "$HOME/.pm2/lomp.env"; fi; set +a
export NODE_ENV="${NODE_ENV:-production}"
'"$script" || rc=$?
  if (( rc != 0 )); then APP_BUILD_ERROR="'${script}' failed with status ${rc}"; return 1; fi
  return 0
}

# =============================================================================
#  Lifecycle hooks used by add / remove / restore
# =============================================================================
lib_app_provision_new() {   # the site in D_*, the options in APP_OPT_*
  _app_site_lock "$D_DOMAIN"   # a deploy of the same site takes no global lock
  APP_PORT="$APP_OPT_PORT"; APP_SCRIPT="$APP_OPT_SCRIPT"; APP_START="$APP_OPT_START"; APP_MEMORY=""; APP_ENABLED=1
  if [[ -z "$APP_START" && -z "$APP_SCRIPT" ]]; then APP_START="npm start"; fi
  lib_app_state_write "$D_DOMAIN"
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
  local by=""
  lib_app_state_load "$D_DOMAIN" || return 0
  lib_app_node_ensure
  by="$(_app_port_claimed_by "$APP_PORT" "$D_DOMAIN" || true)"
  if [[ -n "$by" ]]; then
    APP_ENABLED=0; lib_app_state_write "$D_DOMAIN"
    lib_warn "Port ${APP_PORT} is already used by ${by}; the application of ${D_DOMAIN} stays stopped (setup.sh app set ${D_DOMAIN} --port <free port>)"
  fi
  if lib_app_env_json "$D_DOMAIN" | jq -e '.DB_HOST == "127.0.0.1"' >/dev/null 2>&1; then
    lib_db_tcp_account_ensure "$D_DOMAIN" || lib_warn "could not restore the TCP login of the database user (setup.sh app env ${D_DOMAIN} import-db)"
  fi
  if (( APP_ENABLED )) && _app_user_file app/package.json; then
    lib_app_build || lib_warn "dependencies of ${D_DOMAIN} could not be installed: ${APP_BUILD_ERROR}"
  fi
  lib_app_apply
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
  local json=0 a="" d="" unit="" state="" info="" st="" cpu="" mem="" up="" rs="" n=0 rows="[]"
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
    st="" cpu="" mem="" up="" rs=""
    if lib_service_active "$unit"; then
      info="$(_app_process_info web)"
      read -r st cpu mem up rs <<<"$info"
      state="${st:-not in PM2}"
    elif (( ! APP_ENABLED )); then state="stopped"
    elif ! lib_app_runnable; then state="waiting for code"
    else state="service down"; fi
    if (( json )); then
      rows="$(jq -cn --argjson a "$rows" --arg d "$d" --arg port "$APP_PORT" --arg state "$state" --arg en "$APP_ENABLED" \
        --arg cpu "${cpu:-0}" --arg mem "${mem:-0}" --arg up "${up:-0}" --arg rs "${rs:-0}" \
        '$a + [{domain: $d, port: ($port | tonumber), status: $state, enabled: ($en == "1"), cpu: ($cpu | tonumber),
                memory_bytes: ($mem | tonumber), started_ms: ($up | tonumber), restarts: ($rs | tonumber)}]')"
    else
      printf '%-28s %-6s %-18s %4s%% %9s %8s %8s\n' "$d" "$APP_PORT" "$state" "${cpu:-0}" "$(( ${mem:-0} / 1048576 )) MB" "$(_app_age_ms "${up:-0}")" "${rs:-0}"
    fi
  done < <(lib_domains_list)
  if (( json )); then printf '%s\n' "$rows"; return 0; fi
  if (( n == 0 )); then printf '(no Node.js applications - create one with: setup.sh add app.example.com --node)\n'; fi
  return 0
}

lib_app_status() {   # domain
  local unit="" info="" st="" cpu="" mem="" up="" rs="" start="" wanted="stopped" boot=""
  _app_load_site "${1:-}"
  unit="$(lib_app_unit_name "$D_IDENT")"
  start="$APP_START"
  if [[ -n "$APP_SCRIPT" ]]; then start="node ${APP_SCRIPT}"; fi
  if (( APP_ENABLED )); then wanted="running"; fi
  if lib_service_enabled "$unit"; then boot=", starts at boot"; fi
  printf '\n%s== %s ==%s\n' "$C_BLD" "$D_DOMAIN" "$C_RST"
  lib_print_kv "Application"  "${D_HOME}/app"
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
  printf '\n'
}

lib_app_start() {   # domain
  _app_load_site "${1:-}"
  _app_site_lock "$D_DOMAIN"
  APP_ENABLED=1; lib_app_state_write "$D_DOMAIN"
  lib_app_apply
  _app_report
}

lib_app_stop() {   # domain
  _app_load_site "${1:-}"
  _app_site_lock "$D_DOMAIN"
  APP_ENABLED=0; lib_app_state_write "$D_DOMAIN"
  lib_app_apply
  _app_report
}

lib_app_restart() {   # domain
  _app_load_site "${1:-}"
  _app_site_lock "$D_DOMAIN"
  (( APP_ENABLED )) || lib_die "The application of ${D_DOMAIN} is stopped" "" "setup.sh app start ${D_DOMAIN}"
  lib_app_apply restart
  _app_report
}

# Runs without the global lock (setup.sh) because a build can take minutes. The only
# domain.json write here is enabling a stopped app, which a concurrent backup could in theory
# overwrite with its own update; the next start or deploy writes it again.
lib_app_deploy() {   # domain
  _app_load_site "${1:-}"
  _app_site_lock "$D_DOMAIN"
  lib_app_build || lib_die "Deploy of ${D_DOMAIN} failed" "$APP_BUILD_ERROR" "fix the build, then run: setup.sh app deploy ${D_DOMAIN}"
  if (( ! APP_ENABLED )); then APP_ENABLED=1; lib_app_state_write "$D_DOMAIN"; fi
  lib_app_apply restart
  _app_report
}

lib_app_logs() {   # domain [--out|--error] [-n LINES]
  local domain="${1:-}" which="both" lines=50 a="" shown=""
  local -a files=()
  if (($# > 0)); then shift; fi
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --out)   which="out" ;;
      --error) which="error" ;;
      -n)      lines="${1:-50}"; shift ;;
      *) lib_die "Unknown option for app logs: ${a}" "" "setup.sh app logs <domain> [--out|--error] [-n LINES]" ;;
    esac
  done
  [[ "$lines" =~ ^[0-9]+$ ]] || lib_die "Invalid -n '${lines}'" "" "-n 100"
  _app_load_site "$domain"
  if [[ "$which" != "error" ]]; then files+=(".pm2/logs/web-out.log"); fi
  if [[ "$which" != "out" ]]; then files+=(".pm2/logs/web-error.log"); fi
  shown="${files[*]/#/${D_HOME}/}"
  printf '%sFollowing %s (Ctrl-C to stop)%s\n' "$C_DIM" "$shown" "$C_RST"
  # read as the site user: a log replaced by a link cannot show root's files to anyone
  _app_as "$D_HOME" tail -n "$lines" -F "${files[@]}" || true
}

lib_app_set() {   # domain [--port N] [--start CMD | --script FILE] [--memory 512M|none]
  local domain="${1:-}" a="" port="" start="" script="" mem="" why="" port_changed=0
  if (($# > 0)); then shift; fi
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --port)   port="${1:-}"; shift ;;
      --start)  start="${1:-}"; shift ;;
      --script) script="${1:-}"; shift ;;
      --memory) mem="${1:-}"; shift ;;
      *) lib_die "Unknown option for app set: ${a}" "" "setup.sh app set <domain> [--port N] [--start CMD | --script FILE] [--memory 512M|none]" ;;
    esac
  done
  [[ -n "${port}${start}${script}${mem}" ]] || lib_die "Nothing to change" "" "setup.sh app set ${domain:-<domain>} --port 3001"
  [[ -z "$start" || -z "$script" ]] || lib_die "--start and --script cannot be combined" "" "use one of them"
  [[ -z "$start" ]] || lib_app_start_valid "$start" || lib_die "Invalid --start '${start}'" \
    "the command runs without a shell: words only, no quotes, pipes or &&" "put it into a package.json script and use --start \"npm run <name>\""
  [[ -z "$script" ]] || lib_app_script_valid "$script" || lib_die "Invalid --script '${script}'" "a file inside the app directory, such as dist/main.js" "--script dist/main.js"
  [[ -z "$mem" || "$mem" == "none" || "$mem" =~ ^[0-9]+[MG]$ ]] || lib_die "Invalid --memory '${mem}'" "use e.g. 512M, 1G or none" "--memory 512M"
  _app_load_site "$domain" optional
  if (( ! APP_PRESENT )); then
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
  lib_rollback_clear
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
  # the running application only sees the change after a fresh start (a removed variable
  # survives a reload in PM2)
  if (( APP_ENABLED )); then lib_app_apply restart; _app_report; fi
  return 0
}
