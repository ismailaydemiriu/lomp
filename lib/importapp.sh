#!/usr/bin/env bash
# lib/importapp.sh - import: the names another server passes on to a port instead of serving
#                    them from a directory - a Node.js application, or a proxy to an
#                    application somebody runs. lib/import.sh finds the sites and does the
#                    copying; this module finds those names (a lomp's own record, an
#                    OpenLiteSpeed proxy, nginx's proxy_pass, Apache's ProxyPass), looks at what
#                    listens on the port, and brings a Node.js application the way a restore
#                    puts one back: its code without node_modules, its settings, then PM2.

# one entry per name found, the same index in each
declare -ga IMPA_DOMAIN=() IMPA_TARGET=() IMPA_DIR=() IMPA_CWD=() IMPA_SRC=() IMPA_KB=() IMPA_MEM=()
declare -ga IMPA_STATIC=() IMPA_NODE=() IMPA_CMD=() IMPA_DB=() IMPA_CONF=() IMPA_DOCROOT=()
# what _importapp_command made of a command line: one of the two, or neither ("npm start")
IMPA_START="" IMPA_SCRIPT=""
IMPA_LAST=-1

# =============================================================================
#  what runs on the other server
# =============================================================================
# Printed in front of the listing script (lib_import_remote_scan), which calls app_ols for
# each OpenLiteSpeed virtual host it reads and app_rows at its end.
#   P <domain> <host:port> <application directory|-> <where it runs|-> <lomp|ols|nginx|apache>
#     <kilobytes> <memory limit|-> - <paths served from disk|-> <node version|-> <command line|->
#   Q <domain> <database|-> <the file that names it|->
# A name is passed on by: a lomp's own record of the site, a proxy in an OpenLiteSpeed virtual
# host, proxy_pass in an nginx server block, ProxyPass in an Apache virtual host. What listens
# on the port, when it is on that machine: the process ss names, where it runs (/proc), and
# the nearest directory above that with a package.json - which is what makes it a Node.js
# application this server can run. LOMP_IMPORT_PROC stands for /proc (tests).
lib_importapp_remote_lib() {
  cat <<'IMPORTAPP'
PROC="${LOMP_IMPORT_PROC:-/proc}"
app_of_port() {   # port -> "directory<TAB>where it runs<TAB>command line", or nothing
  command -v ss >/dev/null 2>&1 || return 0
  for apid in $(ss -ltnpH "sport = :$1" 2>/dev/null | tr ',' '\n' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u); do
    acwd="$(readlink "$PROC/$apid/cwd" 2>/dev/null)"
    [ -n "$acwd" ] || continue
    adir="$acwd"; an=0
    while [ ! -f "$adir/package.json" ] && [ -n "$adir" ] && [ "$adir" != / ] && [ "$an" -lt 3 ]; do adir="${adir%/*}"; an=$((an + 1)); done
    [ -f "$adir/package.json" ] || continue
    printf '%s\t%s\t%s\n' "$adir" "$acwd" "$(tr '\000' ' ' <"$PROC/$apid/cmdline" 2>/dev/null | tr '\t' ' ' | sed 's/ *$//')"
    return 0
  done
}
app_emit() {   # domain target source [application directory, command line, memory, paths, database]
  ad="$1"; at="$2"; adir2="${4:--}"; acmd="${5:--}"; acw="$adir2"
  case "$ad" in ''|*[!a-z0-9.-]*) return 0 ;; esac
  case "$at" in localhost:*) at="127.0.0.1:${at#localhost:}" ;; esac
  if [ "$adir2" = - ]; then
    case "$at" in
      127.0.0.1:*|'[::1]':*)
        ai="$(app_of_port "${at##*:}")"
        if [ -n "$ai" ]; then
          adir2="$(printf '%s' "$ai" | cut -f1)"; acw="$(printf '%s' "$ai" | cut -f2)"; acmd="$(printf '%s' "$ai" | cut -f3)"
        fi ;;
    esac
  fi
  akb=0; anode=-
  if [ "$adir2" != - ] && [ -d "$adir2" ]; then
    akb="$(du -sk --exclude=node_modules "$adir2" 2>/dev/null | cut -f1)"
    anode="$(node -v 2>/dev/null | head -n 1)"
  else adir2=-; acw=-; fi
  printf 'P\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\t%s\n' "$ad" "$at" "$adir2" "$acw" "$3" "${akb:-0}" "${6:--}" "${7:--}" "${anode:--}" "${acmd:--}"
  adb="${8:--}"; aconf=-
  if [ "$adb" = - ] && [ "$adir2" != - ]; then
    aconf="$(dbconf_pick "$adir2")"
    if [ -n "$aconf" ]; then adb="$(dbconf_val "$aconf" name)"; fi
    [ -n "$adb" ] && [ -n "$aconf" ] || { adb=-; aconf=-; }
  fi
  printf 'Q\t%s\t%s\t%s\n' "$ad" "$adb" "$aconf"
  ssl_row "$ad"
}
app_names() {   # target source, the names on stdin (blanks between them): one entry a name
  set -f
  aseen=" "
  for an2 in $(tr 'A-Z' 'a-z' | tr -s ' \t\n' ' '); do
    case "$an2" in ''|_|'*'|-|*'*'*|'~'*|*[!a-z0-9.-]*) continue ;; esac
    an2="${an2#www.}"
    case "$an2" in *.*) ;; *) continue ;; esac
    case "$aseen" in *" $an2 "*) continue ;; esac
    aseen="$aseen$an2 "
    app_emit "$an2" "$1" "$2"
  done
  set +f
}
# One OpenLiteSpeed virtual host: a processor of the kind "proxy", or a rewrite that passes on.
app_ols() {   # its configuration file, the names its listeners map to it
  aot="$(awk '
    /^[ \t]*extprocessor[ \t]/ { e = 1; p = 0; a = "" }
    e && $1 == "type" && $2 == "proxy" { p = 1 }
    e && $1 == "address" { a = $2 }
    e && /^[ \t]*\}/ { if (p && a != "") { print a; exit } e = 0 }
  ' "$1" 2>/dev/null)"
  [ -n "$aot" ] || aot="$(sed -n 's/.*[Rr]ewrite[Rr]ule.*\(https\{0,1\}:\/\/[A-Za-z0-9.-]*:[0-9][0-9]*\).*\[[^]]*P[^]]*\].*/\1/p' "$1" 2>/dev/null | head -n 1)"
  aot="${aot#http://}"; aot="${aot#https://}"; aot="${aot%%/*}"
  case "$aot" in *:[0-9]*) ;; *) return 0 ;; esac
  printf '%s\n' "$2" | app_names "$aot" ols
}
app_rows() {
  # a lomp: its own record of every site that is passed on, and of the application behind it
  AS="$R/root/.server-setup/domains"
  if command -v jq >/dev/null 2>&1 && [ -d "$AS" ]; then
    for aj in "$AS"/*/domain.json; do
      [ -r "$aj" ] || continue
      jq -r 'select(.mode == "proxy" and (.domain | type) == "string") | [
          .domain, (.proxy.target // "-"),
          (if .app then ((.home // "") + "/app") else "-" end),
          (if .app then (if (.app.script // "") != "" then "node " + .app.script else (.app.start // "npm start") end) else "-" end),
          ((.app.memory // "") | if . == "" then "-" else . end),
          ((.proxy.static_paths // "") | if . == "" then "-" else . end),
          (.db.name // "-")
        ] | @tsv' "$aj" 2>/dev/null
    done | while IFS="$TAB" read -r ad2 at2 adir3 acmd2 amem asp adb2; do
      case "$at2" in *:[0-9]*) ;; *) continue ;; esac
      app_emit "$ad2" "$at2" lomp "$adir3" "$acmd2" "$amem" "$asp" "$adb2"
    done
  fi
  # nginx: every server block that passes its names on, an upstream by its first server
  afiles="$(ls "$R"/etc/nginx/nginx.conf "$R"/etc/nginx/conf.d/*.conf "$R"/etc/nginx/sites-enabled/* 2>/dev/null)"
  if [ -n "$afiles" ]; then
    # shellcheck disable=SC2086
    cat $afiles 2>/dev/null | awk '
      {
        line = $0; sub(/#.*/, "", line); gsub(/[{};]/, " & ", line)
        n = split(line, w, /[ \t\r]+/)
        for (i = 1; i <= n; i++) {
          t = w[i]; if (t == "") continue
          if (t == "{") {
            depth++
            if (kw == "server" && argc == 0) { ins = depth; names = ""; pass = "" }
            else if (kw == "upstream") { inu = depth; un = arg1 }
            kw = ""; argc = 0; continue
          }
          if (t == "}") {
            if (ins == depth) { blocks[++nb] = names "\t" pass; ins = 0 }
            if (inu == depth) inu = 0
            depth--; kw = ""; argc = 0; continue
          }
          if (t == ";") { kw = ""; argc = 0; continue }
          if (kw == "") { kw = t; argc = 0; continue }
          argc++
          if (argc == 1) arg1 = t
          if (kw == "server_name" && ins) names = names " " t
          else if (kw == "proxy_pass" && ins && pass == "" && argc == 1) pass = t
          else if (kw == "server" && inu && argc == 1 && !(un in up)) up[un] = t
        }
      }
      END {
        for (b = 1; b <= nb; b++) {
          split(blocks[b], f, "\t"); p = f[2]
          if (p == "" || f[1] == "") continue
          sub(/^[a-z]+:\/\//, "", p); sub(/\/.*/, "", p)
          if (p in up) p = up[p]
          if (p ~ /^[A-Za-z0-9.-]+:[0-9]+$/) print p "\t" f[1]
        }
      }' | while IFS="$TAB" read -r at3 anames; do
      printf '%s\n' "$anames" | app_names "$at3" nginx
    done
  fi
  # Apache: a virtual host whose whole address space is passed on
  for af in "$R"/etc/apache2/sites-enabled/*.conf "$R"/etc/httpd/conf.d/*.conf; do
    [ -r "$af" ] || continue
    awk '
      { k = tolower($1) }
      k ~ /^<virtualhost/ { inv = 1; names = ""; pass = ""; next }
      inv && (k == "servername" || k == "serveralias") { for (i = 2; i <= NF; i++) names = names " " $i }
      inv && k == "proxypass" && $2 == "/" && pass == "" { pass = $3 }
      k ~ /^<\/virtualhost/ {
        p = pass; sub(/^[a-z]+:\/\//, "", p); sub(/\/.*/, "", p)
        if (inv && names != "" && p ~ /^[A-Za-z0-9.-]+:[0-9]+$/) print p "\t" names
        inv = 0
      }' "$af" 2>/dev/null
  done | while IFS="$TAB" read -r at4 anames2; do
    printf '%s\n' "$anames2" | app_names "$at4" apache
  done
}
IMPORTAPP
}

# =============================================================================
#  the listing, on this server
# =============================================================================
lib_importapp_reset() {
  IMPA_DOMAIN=() IMPA_TARGET=() IMPA_DIR=() IMPA_CWD=() IMPA_SRC=() IMPA_KB=() IMPA_MEM=()
  IMPA_STATIC=() IMPA_NODE=() IMPA_CMD=() IMPA_DB=() IMPA_CONF=() IMPA_DOCROOT=()
  IMPA_LAST=-1
}

_importapp_of() {   # domain -> its index, or status 1
  local k=0
  for (( k = 0; k < ${#IMPA_DOMAIN[@]}; k++ )); do
    if [[ "${IMPA_DOMAIN[k]}" == "$1" ]]; then printf '%d' "$k"; return 0; fi
  done
  return 1
}

# A "P" line of the listing. It is another machine's output, like every line of it: a field
# counts only when it is what it should be. A lomp's own record of a name counts before what
# was read from a web server's configuration.
lib_importapp_row() {   # domain target directory cwd source kilobytes memory paths node command
  local d="${1,,}" target="$2" dir="$3" cwd="$4" src="$5" kb="$6" mem="$7" sp="$8" node="$9" cmd="${10:-}" k=""
  IMPA_LAST=-1
  lib_domain_valid "$d" || return 0
  [[ "$target" =~ ^[A-Za-z0-9.-]{1,253}:[0-9]{2,5}$ ]] || return 0
  case "$src" in lomp|ols|nginx|apache) ;; *) return 0 ;; esac
  _import_path_ok "$dir" || dir="-"
  if [[ "$dir" == "-" ]] || ! _import_path_ok "$cwd" || [[ "${cwd}/" != "${dir}/"* ]]; then cwd="$dir"; fi
  [[ "$kb" =~ ^[0-9]{1,12}$ ]] || kb=0
  [[ "$mem" =~ ^[0-9]{1,5}[MG]$ ]] || mem="-"
  [[ "$sp" =~ ^/[A-Za-z0-9._/-]*(,/[A-Za-z0-9._/-]*)*$ ]] || sp="-"
  [[ "$node" =~ ^v?[0-9]{1,3}(\.[0-9]{1,4}){0,2}$ ]] || node="-"
  if [[ "$cmd" == *[![:print:]]* ]] || (( ${#cmd} > 300 )); then cmd="-"; fi
  if k="$(_importapp_of "$d")"; then
    [[ "$src" == "lomp" && "${IMPA_SRC[k]}" != "lomp" ]] || return 0
  else
    k=${#IMPA_DOMAIN[@]}
    IMPA_DB[k]="-"; IMPA_CONF[k]="-"; IMPA_DOCROOT[k]="-"
  fi
  IMPA_DOMAIN[k]="$d"; IMPA_TARGET[k]="$target"; IMPA_DIR[k]="$dir"; IMPA_CWD[k]="$cwd"; IMPA_SRC[k]="$src"
  IMPA_KB[k]="$kb"; IMPA_MEM[k]="$mem"; IMPA_STATIC[k]="$sp"; IMPA_NODE[k]="$node"; IMPA_CMD[k]="${cmd:--}"
  IMPA_DB[k]="-"; IMPA_CONF[k]="-"
  IMPA_LAST="$k"
  return 0
}

# A "Q" line: the database of the name whose "P" line came just before it.
lib_importapp_db_row() {   # domain database file
  local k="$IMPA_LAST"
  (( k >= 0 )) && [[ "${IMPA_DOMAIN[k]}" == "${1,,}" ]] || return 0
  if _import_dbname_ok "$2"; then IMPA_DB[k]="$2"; else IMPA_DB[k]="-"; fi
  if _import_path_ok "$3"; then IMPA_CONF[k]="$3"; else IMPA_CONF[k]="-"; fi
  return 0
}

# The names found, into the list of sites: one that was listed as a site - its virtual host has
# a document root too - becomes what it is, a Node.js application or a proxy; one that was not
# is an entry of its own.
lib_importapp_merge() {
  local k=0 i=0 found=0 kind=""
  for (( k = 0; k < ${#IMPA_DOMAIN[@]}; k++ )); do
    kind="proxy"; [[ "${IMPA_DIR[k]}" == "-" ]] || kind="node"
    found=0
    for (( i = 0; i < ${#IMP_DOMAIN[@]}; i++ )); do
      [[ "${IMP_DOMAIN[i]}" == "${IMPA_DOMAIN[k]}" ]] || continue
      found=1
      IMPA_DOCROOT[k]="${IMP_ROOT[i]}"
      IMP_KIND[i]="$kind"; IMP_KB[i]=$(( IMP_KB[i] + IMPA_KB[k] )); IMP_DB[i]="${IMPA_DB[k]}"; IMP_CONF[i]="${IMPA_CONF[k]}"
      if [[ "$kind" == "node" ]]; then IMP_ROOT[i]="${IMPA_DIR[k]}"; fi
      IMP_PHP[i]="-"; IMP_MEM[i]="-"; IMP_UPL[i]="-"
      break
    done
    (( found )) && continue
    IMP_DOMAIN+=("${IMPA_DOMAIN[k]}"); IMP_KIND+=("$kind"); IMP_KB+=("${IMPA_KB[k]}")
    if [[ "$kind" == "node" ]]; then IMP_ROOT+=("${IMPA_DIR[k]}"); else IMP_ROOT+=("-"); fi
    IMP_DB+=("${IMPA_DB[k]}"); IMP_CONF+=("${IMPA_CONF[k]}"); IMP_WWW+=(0)
    IMP_PHP+=("-"); IMP_MEM+=("-"); IMP_UPL+=("-")
  done
  return 0
}

# How the application is started here, from how it runs there: "node <file>" with nothing
# else is a script; node with options or arguments, or npm with its words, is a start command
# when it is made of the words this server's "add" takes; and anything else - a process that
# renamed itself, a file outside the application - is left to "npm start".
# IMPA_START / IMPA_SCRIPT; status 1 when it was left to npm.
_importapp_command() {   # directory, where it runs, command line
  local dir="$1" cwd="$2" cmd="$3" first="" x="" sub="" named=0 n=0
  local -a w=() out=()
  IMPA_START=""; IMPA_SCRIPT=""
  read -r -a w <<<"$cmd"
  ((${#w[@]} > 0)) || return 1
  first="${w[0]##*/}"
  case "$first" in
    node|nodejs)
      ((${#w[@]} >= 2)) || return 1
      # where it runs, seen from the application: the file it names is named from there
      sub=""; if [[ "$cwd" != "$dir" ]]; then sub="${cwd#"${dir}/"}/"; fi
      for x in "${w[@]:1}"; do
        # a path inside the application is named from its top; the first word that is no
        # option is the file
        if [[ "$x" == "${dir}/"* ]]; then x="${x#"${dir}/"}"; named=$(( named + 1 ))
        elif [[ "$x" != -* ]] && (( named == 0 )); then x="${sub}${x}"; named=1; fi
        # nothing above the application, and nothing outside it
        [[ "$x" != /* && "/${x}/" != *"/../"* ]] || return 1
        out+=("$x")
      done
      n=${#out[@]}
      if (( n == 1 && named > 0 )) && lib_app_script_valid "${out[0]}"; then IMPA_SCRIPT="${out[0]}"; return 0; fi
      if (( named > 0 )) && lib_app_start_valid "node ${out[*]}"; then IMPA_START="node ${out[*]}"; return 0; fi
      return 1 ;;
    npm|yarn|pnpm|npx)
      [[ "$cwd" == "$dir" ]] || return 1
      if lib_app_start_valid "${first} ${w[*]:1}" && ((${#w[@]} >= 2)); then IMPA_START="${first} ${w[*]:1}"; return 0; fi
      return 1 ;;
  esac
  return 1
}

# =============================================================================
#  one name
# =============================================================================
# The application's own environment and what else a lomp keeps of it, from the record of the
# site there: the values (never printed, never on a command line), its workers and jobs, its
# memory limit, the repository it is deployed from.
_importapp_lomp_state() {   # domain, work directory
  local domain="$1" work="$2" f="" n=0
  if _import_ssh "cat '/root/.server-setup/domains/${domain}/app-env.json'" </dev/null >"${work}/env.json" 2>>"$LOG_FILE" \
     && jq -e 'type == "object"' "${work}/env.json" >/dev/null 2>&1; then
    f="$(lib_app_env_file "$domain")"
    ( umask 077; jq 'with_entries(select((.key | test("^[A-Z_][A-Z0-9_]*$")) and (.key | test("^(PORT|HOME|PATH|LANG)$|^PM2_") | not)
                                         and (.value | type) == "string"))' "${work}/env.json" >"${f}.new" ) \
      && mv -f "${f}.new" "$f" && chmod 0600 "$f"
    n="$(jq 'length' "$f" 2>/dev/null || printf '0')"
    lib_ok "${n} environment value(s) of the application brought (setup.sh app env ${domain} list)"
  fi
  rm -f -- "${work}/env.json"
  if _import_ssh "cat '/root/.server-setup/domains/${domain}/domain.json'" </dev/null >"${work}/there.json" 2>>"$LOG_FILE" \
     && jq -e 'type == "object"' "${work}/there.json" >/dev/null 2>&1; then
    # workers and jobs: the fields this server knows, of the types it expects
    lib_json_set "$(lib_domain_json "$domain")" '.workers = $w' --argjson w "$(jq -c '[(.workers // [])[]
        | select((.name | type) == "string" and (.start | type) == "string")
        | {name, start, cwd, port, memory, cron, timeout, enabled}
        | with_entries(select(.value != null))]' "${work}/there.json")"
    lib_app_state_load "$domain" || true
    APP_GIT_URL="$(jq -r '.app.git.url // ""' "${work}/there.json")"; APP_GIT_BRANCH="$(jq -r '.app.git.branch // ""' "${work}/there.json")"
    if [[ -n "$APP_GIT_URL" ]] && ! lib_app_git_url_valid "$APP_GIT_URL"; then APP_GIT_URL=""; APP_GIT_BRANCH=""; fi
    if [[ -n "$APP_GIT_BRANCH" ]] && ! lib_app_git_branch_valid "$APP_GIT_BRANCH"; then APP_GIT_BRANCH=""; fi
    # the memory at which PM2 starts it again
    n="$(jq -r '.app.memory // ""' "${work}/there.json")"
    if [[ "$n" =~ ^[0-9]{1,5}[MG]$ ]]; then APP_MEMORY="$n"; fi
    lib_app_state_write "$domain"
  fi
  rm -f -- "${work}/there.json"
  return 0
}

# The application's files into app/ of the site here, by the site's own user: everything the
# first time, what changed there since after that (lib/import.sh keeps the note). node_modules
# stays behind - it is built again here, for this server's Node.js.
_importapp_copy() {   # domain, directory there, 1 when the site was just made
  local domain="$1" dir="$2" created="$3" now="" since="" got="" changed=0 list=""
  now="$(_import_remote_now || true)"
  if (( ! created && ! IMP_OPT_FULL )) && [[ -n "$now" ]]; then since="$(_import_mark_get "$domain" "${now#* }" "$dir" || true)"; fi
  if [[ -n "$since" ]]; then
    got="$(_import_ssh "cd '${dir}' && l=\$(mktemp) && find . -mindepth 1 -name node_modules -prune -o -newerct '@${since}' -print0 >\"\$l\" && printf '%s %s\n' \"\$(tr -cd '\\000' <\"\$l\" | wc -c)\" \"\$l\"" </dev/null 2>>"$LOG_FILE" || true)"
    read -r changed list _ <<<"$got"
    if ! [[ "$changed" =~ ^[0-9]+$ ]] || ! _import_path_ok "$list"; then since=""; list=""; changed=0; fi
  fi
  lib_domain_as_user mkdir -p "${D_HOME}/app" 2>>"$LOG_FILE" || true
  if [[ -n "$since" ]] && (( changed == 0 )); then
    _import_ssh "rm -f '${list}'" </dev/null 2>>"$LOG_FILE" || true
    lib_info "Nothing of the application of ${domain} changed there since the last import: nothing to copy (--full copies everything again)"
  elif [[ -n "$since" ]]; then
    lib_info "Copying the ${changed} file(s) and directories of the application that changed there into ${D_HOME}/app as ${D_USER} ..."
    _import_ssh "tar -C '${dir}' --null --no-recursion -T '${list}' -czf - ; r=\$?; rm -f '${list}'; [ \"\$r\" -le 1 ]" </dev/null 2>>"$LOG_FILE" \
      | _import_unpack "${D_HOME}/app" \
      || lib_die "The application of ${domain} could not all be copied" "the connection dropped, the disk is full, or ${IMP_SSH_TARGET} cannot read everything in ${dir} (see the log)" "what was copied stays; run the import again to complete it"
  else
    lib_info "Copying the application (without node_modules) into ${D_HOME}/app as ${D_USER} ..."
    _import_ssh "tar -C '${dir}' --exclude=node_modules -czf - . ; r=\$?; [ \"\$r\" -le 1 ]" </dev/null 2>>"$LOG_FILE" \
      | _import_unpack "${D_HOME}/app" \
      || lib_die "The application of ${domain} could not all be copied" "the connection dropped, the disk is full, or ${IMP_SSH_TARGET} cannot read everything in ${dir} (see the log)" "what was copied stays; run the import again to complete it"
  fi
  if [[ -n "$now" ]]; then
    printf '%s\t%s\t%s\n' "${now#* }" "$dir" "${now%% *}" >"$(lib_import_mark_file "$domain")" 2>/dev/null && chmod 0600 "$(lib_import_mark_file "$domain")" || true
  fi
  return 0
}

lib_importapp_site() {   # index into the list of sites
  local i="$1" domain="${IMP_DOMAIN[$1]}" kind="${IMP_KIND[$1]}" k="" target="" port="" dir="" why="" created=0 work=""
  local docroot="" src="" db=""
  local -a args=()
  k="$(_importapp_of "$domain")" || lib_die "${domain} could not be imported" "what it is passed on to is not known any more" "run the import again"
  target="${IMPA_TARGET[k]}"; port="${target##*:}"; dir="${IMPA_DIR[k]}"; src="${IMPA_SRC[k]}"; db="${IMPA_DB[k]}"
  lib_heading "${domain}  <-  ${IMP_SSH_TARGET}: $( [[ "$kind" == "node" ]] && printf 'the Node.js application in %s' "$dir" || printf 'passed on to %s' "$target")"
  lib_rollback_clear
  work="$(lib_mktemp -d)"

  # ---- the site ------------------------------------------------------------
  if ! lib_domain_registered "$domain"; then
    args=(--no-ssl)
    if [[ "$kind" == "node" ]]; then
      args+=(--node)
      why="$(lib_app_port_conflict "$port" || true)"
      if [[ -z "$why" ]]; then args+=(--port "$port")
      else lib_warn "${domain} listens on port ${port} there, which cannot be its port here (${why}): it gets a free one, and has to take its port from the PORT variable"; fi
      if _importapp_command "$dir" "${IMPA_CWD[k]}" "${IMPA_CMD[k]}"; then
        if [[ -n "$IMPA_SCRIPT" ]]; then args+=(--script "$IMPA_SCRIPT"); else args+=(--start "$IMPA_START"); fi
      elif [[ "${IMPA_CMD[k]}" != "-" ]]; then
        lib_note "How it is started there (${IMPA_CMD[k]}) is not a command this server takes: it is started with \"npm start\" (setup.sh app set ${domain} --start ...)"
      fi
    else
      args+=(--proxy "$target")
      if [[ "${IMPA_STATIC[k]}" != "-" ]]; then args+=(--static-paths "${IMPA_STATIC[k]}"); fi
    fi
    if (( IMP_WWW[i] )); then args+=(--www); fi
    lib_info "Adding the site ${domain}"
    _import_add "$domain" "${args[@]}" \
      || lib_die "The site ${domain} could not be added" "see what 'add' said above" "clear that up, then run the import again"
    created=1
  fi
  lib_domain_state_load "$domain"
  [[ "$D_MODE" == "proxy" ]] || lib_die "${domain} is a ${D_MODE} site here" "there its address is passed on to an application" "remove it here first, or import that name under another one"

  if [[ "$kind" == "proxy" ]]; then
    lib_warn "${domain} is passed on to ${target} here as it is there. What answers on that port there was not brought: it is no Node.js application this server could see (setup.sh proxy / app help)"
    lib_log_write INFO "imported ${domain} from ${IMP_SSH_TARGET} as a proxy to ${target}"
    lib_ok "${domain} is here, as a proxy to ${target}"
    return 0
  fi

  lib_app_state_load "$domain" \
    || lib_die "${domain} is a proxy here, with no Node.js application of its own" "there it runs one, in ${dir}" "remove it here first: the import adds it with its application"
  if (( ! created )); then
    lib_info "A backup of ${domain} as it is now comes first"
    lib_backup_domain "$domain" --tag pre-import --keep 0 --no-mail \
      || lib_die "${domain} was not imported" "the backup of what is here could not be made: ${BK_ERROR}" "nothing was changed; check the disk space, then run it again"
  fi
  _app_site_lock "$domain"

  # ---- the application's files ------------------------------------------------
  if (( ! IMP_OPT_NO_FILES )); then
    _importapp_copy "$domain" "$dir" "$created"
    # what the web server itself serves beside it (a lomp keeps that in public_html)
    docroot="${IMPA_DOCROOT[k]}"
    if [[ "$src" == "lomp" && "$docroot" != "-" && "$docroot" != "$dir" ]]; then
      if _domain_wp_placeholder "${D_HOME}/public_html"; then lib_domain_as_user rm -f -- "${D_HOME}/public_html/index.html" || true; fi
      _import_ssh "tar -C '${docroot}' -czf - . ; r=\$?; [ \"\$r\" -le 1 ]" </dev/null 2>>"$LOG_FILE" | _import_unpack "${D_HOME}/public_html" \
        || lib_warn "what ${docroot} holds could not all be copied into ${D_HOME}/public_html"
    fi
    lib_ok "Application of ${domain} copied into ${D_HOME}/app"
  fi
  if [[ "$src" == "lomp" ]]; then _importapp_lomp_state "$domain" "$work"; fi

  # ---- its database ----------------------------------------------------------
  if [[ "$db" != "-" ]] && (( ! IMP_OPT_NO_DB )); then
    lib_import_db "$domain" "$db" "${IMPA_CONF[k]}" "$work" "$created"
    if [[ "$src" == "lomp" ]]; then
      # the values a lomp wrote into the environment are this server's now
      if lib_app_env_json "$domain" | jq -e 'has("DB_NAME") or has("DATABASE_URL")' >/dev/null 2>&1; then lib_app_env_import_db; fi
    else
      _import_dbconf_fix "${D_HOME}/app" "$db" "$work"
      if [[ -n "$IMP_FIXED" ]]; then lib_ok "The application's database login is now the one of this server (${DBI_NAME}), in: ${IMP_FIXED}"
      else lib_warn "The application's own settings still name the database of the other server: put in the one of this server (setup.sh app env ${domain} import-db)"; fi
    fi
  fi

  # ---- dependencies, build, PM2: what a restore does -------------------------------
  lib_domain_state_load "$domain"
  if [[ "${IMPA_NODE[k]}" != "-" ]] && lib_have node; then
    if [[ "$(node -v 2>/dev/null | sed 's/^v//; s/\..*//')" != "$(sed 's/^v//; s/\..*//' <<<"${IMPA_NODE[k]}")" ]]; then
      lib_note "${domain} runs on Node.js ${IMPA_NODE[k]} there and on $(node -v 2>/dev/null) here"
    fi
  fi
  if [[ "$src" != "lomp" ]]; then
    lib_note "Values the application was given outside its own files there (a PM2 ecosystem file, a systemd unit) were not brought: setup.sh app env ${domain} set NAME"
  fi
  lib_app_restore
  lib_rollback_clear
  lib_log_write INFO "imported the Node.js application of ${domain} from ${IMP_SSH_TARGET}:${dir}"
  lib_ok "${domain} is here: ${D_HOME}/app (setup.sh app status ${domain})"
}
