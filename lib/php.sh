#!/usr/bin/env bash
# lib/php.sh - LSPHP installation, required extensions, php.ini tuning, CLI links.

PHP_REQUIRED_EXTS="curl mbstring mysqli pdo_mysql gd imagick xml zip intl bcmath soap opcache redis fileinfo exif"
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
  local d tag v
  for d in "$LSWS_HOME"/lsphp[0-9][0-9]/bin/lsphp; do
    [[ -x "$d" ]] || continue
    tag="$(basename "$(dirname "$(dirname "$d")")")"
    v="${tag#lsphp}"
    printf '%s.%s\n' "${v:0:1}" "${v:1}"
  done
}

lib_php_full_version() {   # 8.3 -> 8.3.12
  local cli; cli="$(lib_php_cli "$1")"
  [[ -x "$cli" ]] && "$cli" -r 'echo PHP_VERSION;' 2>/dev/null || true
}

lib_php_default_version() {
  local v; v="$(lib_manifest_get '.components.php.default')"
  printf '%s' "${v:-$PHP_VERSION}"
}

# Base package set for a version (verified against the LiteSpeed repository naming).
_php_packages() {
  local tag; tag="$(lib_php_tag "$1")"
  printf '%s %s-common %s-mysql %s-opcache %s-curl %s-imagick %s-intl %s-redis\n' \
    "$tag" "$tag" "$tag" "$tag" "$tag" "$tag" "$tag" "$tag"
}

# lib_php_install <version>  (idempotent)
lib_php_install() {
  local ver="$1" pkgs=() p
  lib_php_valid_version "$ver" || lib_die "Invalid PHP version '${ver}'" "expected e.g. 8.2 / 8.3 / 8.4" "use --php 8.3"
  if (( OPT_DRY_RUN )) && ! lib_php_installed "$ver"; then
    lib_info "[dry-run] would install $(_php_packages "$ver"), verify extensions (${PHP_REQUIRED_EXTS}) and write the php.ini drop-in"
    return 0
  fi
  if lib_php_installed "$ver"; then
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
    lib_php_ensure_extensions "$ver"
    lib_php_write_ini "$ver"
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
lib_php_ensure_extensions() {
  local ver="$1" cli mods ext pkg missing=() tag
  cli="$(lib_php_cli "$ver")"; tag="$(lib_php_tag "$ver")"
  [[ -x "$cli" ]] || return 0
  mods="$("$cli" -m 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  for ext in $PHP_REQUIRED_EXTS; do
    _php_has_ext "$mods" "$ext" && continue
    case "$ext" in
      mysqli|pdo_mysql) pkg="${tag}-mysql" ;;
      *)                pkg="${tag}-${ext}" ;;
    esac
    if lib_pkg_available "$pkg" && ! lib_pkg_installed "$pkg"; then
      lib_apt_install "$pkg" || true
      mods="$("$cli" -m 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    fi
    _php_has_ext "$mods" "$ext" || missing+=("$ext")
  done
  if ((${#missing[@]} > 0)); then
    lib_warn "LSPHP ${ver}: extensions still missing: ${missing[*]} (install ${tag}-dev and build via PECL if required)"
  else
    lib_ok "LSPHP ${ver}: all required extensions present"
  fi
}

_php_has_ext() {   # modules-list ext
  local mods="$1" ext="$2"
  case "$ext" in
    opcache) grep -qx 'zend opcache' <<<"$mods" ;;
    *)       grep -qx "$ext" <<<"$mods" ;;
  esac
}

lib_php_ini_paths() {   # sets PHP_INI_FILE / PHP_INI_SCAN_DIR for a version
  local cli; cli="$(lib_php_cli "$1")"
  PHP_INI_FILE=""; PHP_INI_SCAN_DIR=""
  [[ -x "$cli" ]] || return 0
  PHP_INI_FILE="$("$cli" -i 2>/dev/null | awk -F'=> ' '/^Loaded Configuration File/{print $2; exit}' | tr -d ' ')"
  PHP_INI_SCAN_DIR="$("$cli" -i 2>/dev/null | awk -F'=> ' '/^Scan this dir for additional .ini files/{print $2; exit}' | tr -d ' ')"
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
  local ver="$1" target line key value
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
  local ver="$1" cli
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
  local v out=()
  for v in $(lib_php_installed_versions); do out+=("${v} ($(lib_php_full_version "$v"))"); done
  ((${#out[@]})) && lib_join ', ' "${out[@]}" || printf 'none'
}
