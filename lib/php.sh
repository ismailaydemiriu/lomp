#!/usr/bin/env bash
# lib/php.sh - LSPHP installation, required extensions, php.ini tuning, CLI links.

# Every LSPHP version must load these. Most are compiled into lsphpXX itself; the framework basics
# on the second line are checked too, so a build without one is reported by install and update
# instead of breaking an application at runtime.
PHP_REQUIRED_EXTS="curl mbstring mysqli pdo_mysql sqlite3 pdo_sqlite gd imagick xml zip intl bcmath soap opcache redis apcu fileinfo exif"
PHP_REQUIRED_EXTS+=" ctype dom filter iconv openssl pdo phar posix session simplexml sodium tokenizer xmlreader xmlwriter zlib"
PHP_EXTS_ADDED=""   # packages lib_php_ensure_extensions installed during this run
PHP_INI_FILE=""
PHP_INI_SCAN_DIR=""
PHP_INI_CHANGED=0

lib_php_tag()        { printf 'lsphp%s' "${1//./}"; }              # 8.3 -> lsphp83
lib_php_home()       { printf '%s/%s' "$LSWS_HOME" "$(lib_php_tag "$1")"; }
lib_php_bin()        { printf '%s/bin/lsphp' "$(lib_php_home "$1")"; }
lib_php_cli()        { printf '%s/bin/php' "$(lib_php_home "$1")"; }
lib_php_installed()  { [[ -x "$(lib_php_bin "$1")" ]]; }
lib_php_valid_version() { [[ "$1" =~ ^[78]\.[0-9]$ ]]; }

lib_php_installed_versions() {
  local d="" tag="" v=""
  for d in "$LSWS_HOME"/lsphp[0-9][0-9]/bin/lsphp; do
    [[ -x "$d" ]] || continue
    tag="$(basename "$(dirname "$(dirname "$d")")")"
    v="${tag#lsphp}"
    printf '%s.%s\n' "${v:0:1}" "${v:1}"
  done
}

lib_php_full_version() {   # 8.3 -> 8.3.12
  local cli=""; cli="$(lib_php_cli "$1")"
  [[ -x "$cli" ]] && "$cli" -r 'echo PHP_VERSION;' 2>/dev/null || true
}

lib_php_default_version() {
  local v=""; v="$(lib_manifest_get '.components.php.default')"
  printf '%s' "${v:-$PHP_VERSION}"
}

# Base package set for a version (verified against the LiteSpeed repository naming).
_php_packages() {
  local tag="" p="" out=""; tag="$(lib_php_tag "$1")"
  out="$tag"
  for p in common mysql sqlite3 opcache curl imagick intl redis apcu; do out+=" ${tag}-${p}"; done
  printf '%s\n' "$out"
}

# lib_php_install <version>  (idempotent)
lib_php_install() {
  local ver="$1" pkgs=() p="" existing=0 added=""
  lib_php_valid_version "$ver" || lib_die "Invalid PHP version '${ver}'" "expected e.g. 8.2 / 8.3 / 8.4" "use --php 8.3"
  if (( OPT_DRY_RUN )) && ! lib_php_installed "$ver"; then
    lib_info "[dry-run] would install $(_php_packages "$ver"), verify extensions (${PHP_REQUIRED_EXTS}) and write the php.ini drop-in"
    return 0
  fi
  if lib_php_installed "$ver"; then
    existing=1
    lib_ok "LSPHP ${ver} already installed ($(lib_php_full_version "$ver"))"
  else
    lib_apt_update
    for p in $(_php_packages "$ver"); do
      if lib_pkg_available "$p"; then pkgs+=("$p"); else lib_warn "package ${p} not available in the repository (skipped)"; fi
    done
    [[ " ${pkgs[*]} " == *" $(lib_php_tag "$ver") "* ]] || lib_die "LSPHP ${ver} is not available for Ubuntu ${OS_VERSION_ID}" \
      "no $(lib_php_tag "$ver") package in the LiteSpeed repository" "choose another version with --php"
    lib_apt_install "${pkgs[@]}" || lib_die "LSPHP ${ver} installation failed" "apt error" "check the log and re-run"
    (( OPT_DRY_RUN )) || lib_php_installed "$ver" || lib_die "LSPHP ${ver} binary missing after install" "unexpected package layout" "apt-get install --reinstall $(lib_php_tag "$ver")"
    lib_ok "LSPHP ${ver} installed ($(lib_php_full_version "$ver"))"
  fi
  if (( ! OPT_DRY_RUN )) || lib_php_installed "$ver"; then
    added="$PHP_EXTS_ADDED"
    lib_php_ensure_extensions "$ver"
    lib_php_write_ini "$ver"
    # workers that were already running never load an extension installed under them
    if (( existing )) && [[ "$PHP_EXTS_ADDED" != "$added" ]]; then lib_php_restart_workers; fi
  else
    lib_info "[dry-run] would verify extensions and write php.ini overrides for LSPHP ${ver}"
  fi
  lib_php_register "$ver"
}

lib_php_register() {   # record version in manifest
  local ver="$1"
  (( OPT_DRY_RUN )) && return 0
  lib_state_init
  lib_json_set "$STATE_DIR/manifest.json" \
    '.components.php.installed = ((.components.php.installed // []) + [$v] | unique) | .components.php.default = (.components.php.default // $d)' \
    --arg v "$ver" --arg d "$PHP_VERSION"
}

# Verify every required extension is loaded; try lsphpXX-<ext> packages for missing ones.
# What it installs goes into PHP_EXTS_ADDED: running workers only load it after a restart.
lib_php_ensure_extensions() {
  local ver="$1" cli="" mods="" ext="" pkg="" missing=() tag="" tried=" "
  cli="$(lib_php_cli "$ver")"; tag="$(lib_php_tag "$ver")"
  [[ -x "$cli" ]] || return 0
  mods="$("$cli" -m 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  for ext in $PHP_REQUIRED_EXTS; do
    _php_has_ext "$mods" "$ext" && continue
    case "$ext" in
      mysqli|pdo_mysql)   pkg="${tag}-mysql" ;;
      sqlite3|pdo_sqlite) pkg="${tag}-sqlite3" ;;
      *)                  pkg="${tag}-${ext}" ;;
    esac
    if [[ "$tried" != *" ${pkg} "* ]] && lib_pkg_available "$pkg" && ! lib_pkg_installed "$pkg"; then
      tried+="${pkg} "
      if lib_apt_install "$pkg" && (( ! OPT_DRY_RUN )); then PHP_EXTS_ADDED+="${PHP_EXTS_ADDED:+ }${pkg}"; fi
      mods="$("$cli" -m 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    fi
    _php_has_ext "$mods" "$ext" && continue
    # a dry run installs nothing, so what the package would bring cannot show up yet
    (( OPT_DRY_RUN )) && [[ "$tried" == *" ${pkg} "* ]] && continue
    missing+=("$ext")
  done
  if ((${#missing[@]} > 0)); then
    lib_warn "LSPHP ${ver}: extensions still missing: ${missing[*]} (install ${tag}-dev and build via PECL if required)"
  elif [[ "$tried" == " " ]]; then
    lib_ok "LSPHP ${ver}: all required extensions present"
  elif (( OPT_DRY_RUN )); then
    lib_info "[dry-run] LSPHP ${ver}: would install${tried% } for the extensions it lacks"
  else
    lib_ok "LSPHP ${ver}: all required extensions present (installed${tried% })"
  fi
}

_php_has_ext() {   # modules-list ext
  local mods="$1" ext="$2"
  case "$ext" in
    opcache) grep -qx 'zend opcache' <<<"$mods" ;;
    *)       grep -qx "$ext" <<<"$mods" ;;
  esac
}

_php_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

lib_php_ini_paths() {   # sets PHP_INI_FILE / PHP_INI_SCAN_DIR for a version
  local cli="" info=""
  cli="$(lib_php_cli "$1")"
  PHP_INI_FILE=""; PHP_INI_SCAN_DIR=""
  [[ -x "$cli" ]] || return 0
  # The output is captured once and parsed from a variable on purpose. Piping the PHP CLI
  # straight into an awk that exits on the first match closes the pipe while PHP is still
  # writing its (very large) phpinfo, PHP turns that EPIPE into exit status 255, and pipefail
  # propagates it. "--ini" additionally keeps the output to four lines.
  info="$("$cli" --ini 2>/dev/null || true)"
  if [[ "$info" == *"Loaded Configuration File"* ]]; then
    PHP_INI_FILE="$(awk '/^Loaded Configuration File:/{sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' <<<"$info")"
    PHP_INI_SCAN_DIR="$(awk '/^Scan for additional \.ini files in:/{sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' <<<"$info")"
  else
    info="$("$cli" -i 2>/dev/null || true)"
    PHP_INI_FILE="$(awk -F'=> ' '/^Loaded Configuration File/{print $2; exit}' <<<"$info")"
    PHP_INI_SCAN_DIR="$(awk -F'=> ' '/^Scan this dir for additional \.ini files/{print $2; exit}' <<<"$info")"
  fi
  PHP_INI_FILE="$(_php_trim "$PHP_INI_FILE")"
  PHP_INI_SCAN_DIR="$(_php_trim "$PHP_INI_SCAN_DIR")"
  [[ "$PHP_INI_FILE" == "(none)" ]] && PHP_INI_FILE=""
  [[ "$PHP_INI_SCAN_DIR" == "(none)" ]] && PHP_INI_SCAN_DIR=""
  return 0
}

lib_php_render_ini() {
  lib_system_profile
  cat <<EOF
; Managed by lompstack - regenerated by "setup.sh install" and "setup.sh optimize"
; Profile: ${SYS_RAM_MB} MB RAM, ${SYS_CPU_CORES} CPU. Per-site overrides live in the vhost (phpIniOverride).
expose_php = Off
date.timezone = ${TIMEZONE}
memory_limit = ${CALC_PHP_MEMORY_MB}M
upload_max_filesize = ${CALC_PHP_UPLOAD_MB}M
post_max_size = ${CALC_PHP_POST_MB}M
max_execution_time = ${CALC_PHP_MAX_EXEC}
max_input_time = ${CALC_PHP_MAX_EXEC}
max_input_vars = ${CALC_PHP_MAX_INPUT_VARS}
max_file_uploads = 50
display_errors = Off
display_startup_errors = Off
log_errors = On
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
realpath_cache_size = 4096K
realpath_cache_ttl = 600
session.cookie_httponly = 1
session.use_strict_mode = 1
session.gc_maxlifetime = 1440
allow_url_include = Off
cgi.fix_pathinfo = 0
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = ${CALC_OPCACHE_MB}
opcache.interned_strings_buffer = ${CALC_OPCACHE_STRINGS_MB}
opcache.max_accelerated_files = ${CALC_OPCACHE_FILES}
opcache.validate_timestamps = 1
opcache.revalidate_freq = 60
opcache.save_comments = 1
opcache.huge_code_pages = 0
EOF
}

# Write the tuning drop-in (or patch php.ini when no scan dir exists). Sets PHP_INI_CHANGED.
lib_php_write_ini() {
  local ver="$1" target="" line="" key="" value=""
  PHP_INI_CHANGED=0
  lib_php_ini_paths "$ver"
  if [[ -n "$PHP_INI_SCAN_DIR" ]]; then
    target="${PHP_INI_SCAN_DIR%/}/99-server-setup.ini"
    lib_php_render_ini | lib_write_file "$target" 0644 root:root
    PHP_INI_CHANGED="$LIB_FILE_CHANGED"
  elif [[ -n "$PHP_INI_FILE" ]]; then
    target="$PHP_INI_FILE"
    while IFS= read -r line; do
      [[ "$line" =~ ^\; || -z "$line" ]] && continue
      key="${line%% =*}"; value="${line#*= }"
      lib_set_kv "$target" "$key" "$value" "="
      (( LIB_FILE_CHANGED )) && PHP_INI_CHANGED=1
    done < <(lib_php_render_ini)
  else
    lib_warn "LSPHP ${ver}: could not locate php.ini; tuning skipped"
    return 0
  fi
  if (( PHP_INI_CHANGED )); then lib_ok "PHP ${ver} settings written (${target})"; else lib_ok "PHP ${ver} settings already up to date"; fi
}

# Restart detached lsphp workers so php.ini changes take effect.
lib_php_restart_workers() {
  (( OPT_DRY_RUN )) && return 0
  pkill -x lsphp >/dev/null 2>&1 || true
  lib_debug "lsphp workers signalled to restart"
}

# /usr/local/bin/php -> default LSPHP CLI (only when no distro php exists), plus php<ver> links.
lib_php_cli_links() {
  local ver="$1" cli=""
  cli="$(lib_php_cli "$ver")"
  [[ -x "$cli" ]] || return 0
  if (( OPT_DRY_RUN )); then lib_debug "dry-run: would link CLI for PHP ${ver}"; return 0; fi
  ln -sfn "$cli" "/usr/local/bin/php${ver//./}"
  if [[ ! -e /usr/bin/php ]]; then
    if [[ ! -e /usr/local/bin/php || "$(readlink -f /usr/local/bin/php)" == "$LSWS_HOME"/lsphp* ]]; then
      ln -sfn "$cli" /usr/local/bin/php
    fi
  fi
  return 0
}

# Make sure a version exists (installs after confirmation). lib_php_ensure_version 8.2
lib_php_ensure_version() {
  local ver="$1"
  lib_php_valid_version "$ver" || lib_die "Invalid PHP version '${ver}'" "expected e.g. 8.2 / 8.3 / 8.4" "use --php 8.3"
  if lib_php_installed "$ver"; then return 0; fi
  lib_warn "LSPHP ${ver} is not installed on this server."
  if lib_confirm "Install LSPHP ${ver} now?" y; then
    lib_php_install "$ver"
    if lib_ols_is_installed && (( ! OPT_DRY_RUN )); then
      lib_system_profile
      lib_ols_change_begin
      lib_ols_tx_begin
      lib_ols_render_extprocessor "$ver" "$CALC_PHP_CHILDREN_TOTAL" | lib_ols_tx_block_put extprocessor "$(lib_php_tag "$ver")"
      lib_ols_tx_commit
      lib_ols_change_commit "register LSPHP ${ver}"
    fi
  else
    lib_die "LSPHP ${ver} is required but not installed" "installation declined" "re-run with --php <installed version> or accept the installation"
  fi
}

lib_php_summary_line() {   # for status: "8.3 (8.3.12), 8.2 (8.2.24)"
  local v="" out=()
  for v in $(lib_php_installed_versions); do out+=("${v} ($(lib_php_full_version "$v"))"); done
  ((${#out[@]})) && lib_join ', ' "${out[@]}" || printf 'none'
}

# =============================================================================
#  php-cleanup - undo "apt-get install lsphp83*"
# =============================================================================
# The wildcard installs every package of a version: the debug symbols, the module sources,
# -dev and with it a compiler, and with Recommends the distribution's own PHP beside this one.
# apt's history says exactly what such a run added, so that - and nothing else - can go: not
# lomp's own set, not what was on the server before, not what was marked as manually installed
# since.
PHP_APT_HISTORY="/var/log/apt/history.log"   # and its rotated copies
declare -ga PHP_CLEAN_REMOVE=() PHP_CLEAN_EXTS=() PHP_CLEAN_MANUAL=() PHP_CLEAN_HELD=()
PHP_CLEAN_EXTRA=""    # what a purge would take along that the wildcard did not install
PHP_CLEAN_PURGED=0

# Every package a "... install <tag>*" run added, one per line, from apt's history.
_php_wildcard_added() {   # tag
  local f=""
  for f in "$PHP_APT_HISTORY"*; do
    [[ -f "$f" ]] || continue
    zcat -f -- "$f" 2>/dev/null || true
    printf '\n'
  done | awk -v re=" ${1}[^ ]*[*]" '
    BEGIN { RS = "" }
    { hit = 0; inst = ""; n = split($0, l, "\n")
      for (i = 1; i <= n; i++) {
        if (l[i] ~ /^Commandline: / && l[i] ~ re) hit = 1
        if (l[i] ~ /^Install: /) inst = substr(l[i], 10)
      }
      if (hit && inst != "") print inst }' \
    | sed 's/([^)]*)//g' | tr ',' '\n' | sed 's/^ *//; s/[: ].*//; /^$/d' | sort -u
}

# What lomp installs for a version itself (igbinary comes with redis).
_php_keep() {   # version
  printf '%s %s-igbinary' "$(_php_packages "$1")" "$(lib_php_tag "$1")"
}

# What is left of a wildcard install that lomp did not ask for, one per line. Cheap enough for
# doctor: it reads the history and asks dpkg, and simulates nothing.
lib_php_cleanup_candidates() {   # version
  local tag="" keep="" p=""
  tag="$(lib_php_tag "$1")"; keep=" $(_php_keep "$1") "
  for p in $(_php_wildcard_added "$tag"); do
    [[ "$keep" == *" $p "* ]] && continue
    if lib_pkg_installed "$p"; then printf '%s\n' "$p"; fi
  done
  return 0
}

_php_purge_sim() {   # apt-get arguments -> the packages that run would remove
  { LC_ALL=C apt-get -s "$@" 2>/dev/null || true; } | awk '$1 == "Purg" || $1 == "Remv" { sub(/:.*/, "", $2); print $2 }' | sort -u
}

# What a purge of the arguments would take along besides them.
_php_purge_collateral() {
  _php_purge_sim purge "$@" | grep -vxF -f <(printf '%s\n' "$@") || true
}

# Sorts a version's candidates into PHP_CLEAN_REMOVE (with the extension packages among them in
# PHP_CLEAN_EXTS), PHP_CLEAN_MANUAL (marked as manually installed since) and PHP_CLEAN_HELD
# (something that stays needs them). All of them go when purging them takes nothing else along.
# When it would, apt is asked what nothing needs any more, and the rest stays. PHP_CLEAN_EXTRA
# is what even that list would drag along: the caller stops on it.
lib_php_cleanup_plan() {   # version
  local tag="" auto="" gone="" p="" cand=() ext=() sim=()
  tag="$(lib_php_tag "$1")"
  PHP_CLEAN_REMOVE=(); PHP_CLEAN_EXTS=(); PHP_CLEAN_MANUAL=(); PHP_CLEAN_HELD=(); PHP_CLEAN_EXTRA=""
  auto=" $(apt-mark showauto 2>/dev/null | tr '\n' ' ') "
  for p in $(lib_php_cleanup_candidates "$1"); do
    if [[ "$p" == "$tag"-* ]]; then ext+=("$p")
    elif [[ "$auto" != *" $p "* ]]; then PHP_CLEAN_MANUAL+=("$p"); continue
    fi
    cand+=("$p")
  done
  ((${#cand[@]})) || return 0
  if [[ -z "$(_php_purge_collateral "${cand[@]}")" ]]; then
    PHP_CLEAN_REMOVE=("${cand[@]}")
  else
    if ((${#ext[@]})); then sim=(purge --autoremove "${ext[@]}"); else sim=(autoremove --purge); fi
    gone=" $(_php_purge_sim -o APT::AutoRemove::RecommendsImportant=false -o APT::AutoRemove::SuggestsImportant=false "${sim[@]}" | tr '\n' ' ') "
    for p in "${cand[@]}"; do
      if [[ "$gone" == *" $p "* ]]; then PHP_CLEAN_REMOVE+=("$p"); else PHP_CLEAN_HELD+=("$p"); fi
    done
    ((${#PHP_CLEAN_REMOVE[@]})) || return 0
    PHP_CLEAN_EXTRA="$(_php_purge_collateral "${PHP_CLEAN_REMOVE[@]}" | tr '\n' ' ')"
    PHP_CLEAN_EXTRA="${PHP_CLEAN_EXTRA% }"
  fi
  for p in "${PHP_CLEAN_REMOVE[@]}"; do
    if [[ "$p" == "$tag"-* ]]; then PHP_CLEAN_EXTS+=("$p"); fi
  done
  return 0
}

_php_cleanup_one() {   # version -> 1 when it had to stop
  local ver="$1" tag="" out="" size=""
  tag="$(lib_php_tag "$ver")"
  if [[ -z "$(_php_wildcard_added "$tag")" ]]; then
    lib_ok "LSPHP ${ver}: apt's history has no '${tag}*' install, so there is nothing to undo"
    return 0
  fi
  lib_php_cleanup_plan "$ver"
  ((${#PHP_CLEAN_MANUAL[@]} == 0)) || lib_info "Kept, marked as manually installed since: ${PHP_CLEAN_MANUAL[*]}"
  ((${#PHP_CLEAN_HELD[@]} == 0))   || lib_info "Kept, still needed by packages that stay: ${PHP_CLEAN_HELD[*]}"
  if [[ -n "$PHP_CLEAN_EXTRA" ]]; then
    lib_error "LSPHP ${ver}: stopped, nothing was changed. apt would also remove packages that '${tag}*' did not install: ${PHP_CLEAN_EXTRA}"
    return 1
  fi
  if ((${#PHP_CLEAN_REMOVE[@]} == 0)); then
    lib_ok "LSPHP ${ver}: nothing to remove; what '${tag}*' added beyond lomp's own set is gone"
    return 0
  fi
  lib_info "LSPHP ${ver}: '${tag}*' added these ${#PHP_CLEAN_REMOVE[@]} packages beyond what lomp installs:"
  printf '%s ' "${PHP_CLEAN_REMOVE[@]}" | fold -s -w 96 | sed 's/^/        /'; printf '\n'
  size="$( { LC_ALL=C apt-get purge --assume-no "${PHP_CLEAN_REMOVE[@]}" 2>/dev/null || true; } | grep -o '[0-9.,]* [kMG]B disk space will be freed' || true)"
  [[ -z "$size" ]] || lib_info "${size}"
  if ((${#PHP_CLEAN_EXTS[@]})); then
    lib_warn "PHP extensions among them, which every site stops loading: ${PHP_CLEAN_EXTS[*]}"
    lib_note "A site that needs one of them (ionCube, IMAP, LDAP, PostgreSQL ...) breaks without it: answer no then, and purge the others by hand."
  fi
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would purge them"; return 0; fi
  if ! lib_confirm "Purge these ${#PHP_CLEAN_REMOVE[@]} packages?" n; then lib_info "Nothing changed."; return 0; fi
  lib_run env DEBIAN_FRONTEND=noninteractive apt-get purge -y -q "${PHP_CLEAN_REMOVE[@]}" \
    || lib_die "apt-get purge failed" "see the log" "fix apt problems (apt-get -f install) and run it again"
  PHP_CLEAN_PURGED=1
  # an ini left behind for a purged extension would warn on every request
  out="$("$(lib_php_cli "$ver")" -d display_startup_errors=1 -d display_errors=1 -d log_errors=0 -r 'echo "ok";' 2>&1 || true)"
  if [[ "$out" == "ok" ]]; then lib_ok "LSPHP ${ver}: ${#PHP_CLEAN_REMOVE[@]} packages purged, and PHP starts cleanly"
  else lib_warn "LSPHP ${ver} prints at startup: ${out:0:300}"; fi
  lib_php_ensure_extensions "$ver"
  return 0
}

lib_php_cleanup_main() {
  local a="" ver="" v="" rc=0 versions=()
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --php) ver="${1:-}"; shift || true ;;
      -h|--help) printf 'Usage: lomp php-cleanup [--php 8.3]\n'; return 0 ;;
      *) lib_die "Unknown option for php-cleanup: ${a}" "" "php-cleanup [--php 8.3]" ;;
    esac
  done
  lib_require_tools
  lib_require_installed
  if [[ -n "$ver" ]]; then
    lib_php_valid_version "$ver" || lib_die "Invalid PHP version '${ver}'" "expected e.g. 8.2 / 8.3 / 8.4" "use --php 8.3"
    lib_php_installed "$ver" || lib_die "LSPHP ${ver} is not installed" "" "lomp status lists the installed versions"
    versions=("$ver")
  else
    for v in $(lib_php_installed_versions); do versions+=("$v"); done
  fi
  ((${#versions[@]})) || { lib_ok "No LSPHP version is installed"; return 0; }
  PHP_CLEAN_PURGED=0
  for v in "${versions[@]}"; do _php_cleanup_one "$v" || rc=1; done
  if (( PHP_CLEAN_PURGED )); then
    lib_php_restart_workers   # running workers still carry the old set
    lib_run apt-get clean || true
    if lib_have gcc; then lib_note "gcc is still installed: it was there before the wildcard install, or something that stays needs it."; fi
    if [[ -e /usr/bin/php ]]; then lib_note "/usr/bin/php still exists: it was there before the wildcard install, or something that stays needs it."; fi
  fi
  return "$rc"
}
