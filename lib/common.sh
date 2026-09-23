#!/usr/bin/env bash
# lib/common.sh - logging, colours, locking, errors, rollback, file/apt/systemd
#                 helpers, state (JSON) helpers, network helpers.
# All functions are prefixed lib_. Requires globals from setup.sh.

# ---- module globals ----------------------------------------------------------
LIB_STEP_CURRENT=0
LIB_STEP_TOTAL=0
LIB_APT_UPDATED=0
LIB_FILE_CHANGED=0
LIB_LOCK_HELD=0
LIB_ERR_HANDLING=0
# -g: modules are sourced from inside a function in setup.sh; plain "declare" would be local there
declare -ga LIB_ROLLBACK_STACK=()
declare -g LIB_TMP_ROOT=""
OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""

C_RED='' C_GRN='' C_YEL='' C_BLU='' C_CYN='' C_MAG='' C_BLD='' C_DIM='' C_RST=''

# =============================================================================
#  Colours & console output
# =============================================================================
lib_common_init_colors() {
  if [[ -t 1 && "${TERM:-dumb}" != "dumb" && $OPT_NO_COLOR -eq 0 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'; C_BLU=$'\033[0;34m'
    C_CYN=$'\033[0;36m'; C_MAG=$'\033[0;35m'; C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
  else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYN=''; C_MAG=''; C_BLD=''; C_DIM=''; C_RST=''
  fi
}

lib_ts()      { date '+%Y%m%d-%H%M%S'; }
lib_iso_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Secrets this tool handles arrive in three shapes, and all three must be masked:
#   key=value / key:value / "key":"value"   config files, JSON, env
#   --some-token VALUE                      every secret flag is SPACE separated
#   requirepass VALUE                       space separated config syntax (redis, msmtp)
# The flag rule matches any long option whose name contains pass/token/secret/key, so a
# new secret flag is covered without touching this function. What follows the keyword may
# not contain a hyphen, so "--key-type ecdsa" stays readable while "--cf-api-token X" and
# "--api-key X" are still masked. lib_secret_leak_pattern below is the read-side mirror of
# the same three shapes - keep them in step.
lib_mask_secrets() {
  sed -E \
    -e 's/((password|passwd|passwort|pass|pwd|secret|token|api[_-]?key|requirepass|auth_pass|smtp_pass|cftoken|des_key|dns_cloudflare_api_token|MYSQL_PWD|REDISCLI_AUTH)["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"']?)[^[:space:]"'"'"',}]+/\1********/Ig' \
    -e 's/(--[a-z0-9-]*(password|passwd|pass|secret|token|api[_-]?key|key)[a-z0-9]*[=[:space:]]["'"'"']?)[^[:space:]"'"'"',}]+/\1********/Ig' \
    -e 's/^([[:space:]]*(requirepass|password|auth_pass|smtp_pass|cftoken)[[:space:]]+["'"'"']?)[^[:space:]"'"'"',}]+/\1********/Ig' \
    -e 's/(IDENTIFIED[[:space:]]+BY[[:space:]]+["'"'"'])[^"'"'"']*/\1********/Ig' \
    -e 's/(pass:)[^[:space:]]+/\1********/g' \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._~+\/=-]+/\1********/g' \
    -e 's#(https://api\.telegram\.org/bot)[^/[:space:]]+#\1********#g' \
    -e 's#([a-z][a-z0-9+.-]*://[^/@[:space:]:]*:)[^/@[:space:]]+@#\1********@#Ig' \
    -e 's#(https?://)[A-Za-z0-9_-]{20,}@#\1********@#Ig' \
    -e 's/(\{(BLF-CRYPT|SHA512-CRYPT|SHA256-CRYPT|CRYPT|PLAIN)\})[^[:space:]:]+/\1********/Ig' \
    -e 's/\$(2[aby]|5|6)\$[^[:space:]"'"'"',}]+/$\1$********/g' \
    -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/s/.*/********/'
}
# The last two rules cover credentials inside a URL: "scheme://user:secret@host" (git remotes,
# DATABASE_URL-style connection strings) and a token used as the user name of an https remote
# ("https://ghp_...@github.com"). Plain user names ("ssh://git@", "https://bob@bitbucket.org")
# are left alone: they are not secrets, and a token is at least 20 characters long.

# The pattern "doctor" greps the log with. It must cover exactly the shapes
# lib_mask_secrets masks, or the check reports a clean log while a token sits in it.
lib_secret_leak_pattern() {
  printf '%s' '(password|passwd|pass|pwd|secret|token|api[_-]?key|requirepass|auth_pass|des_key)["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"']?[A-Za-z0-9+/=._~-]{8,}|--[a-z0-9-]*(password|pass|secret|token|api[_-]?key|key)[a-z0-9]*[=[:space:]]+[A-Za-z0-9+/=._~:-]{8,}|^[[:space:]]*(requirepass|password|auth_pass)[[:space:]]+[A-Za-z0-9+/=._~-]{8,}|[a-z][a-z0-9+.-]*://[^/@[:space:]:]*:[^*/@[:space:]][^/@[:space:]]{3,}@|https?://[A-Za-z0-9_-]{20,}@|\{(BLF-CRYPT|SHA512-CRYPT|SHA256-CRYPT|CRYPT)\}[^[:space:]*:]{4,}|\$(2[aby]|5|6)\$[^[:space:]"'"'"',}*]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
}

# Append a line to the log file (masked). Never fails.
lib_log_write() {
  local level="$1"; shift
  local msg="$*"
  if (( OPT_DRY_RUN )); then return 0; fi
  [[ -n "${LOG_FILE:-}" && -w "$LOG_FILE" ]] || return 0
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" | lib_mask_secrets >> "$LOG_FILE" 2>/dev/null || true
}

lib_log_file_init() {
  if (( OPT_DRY_RUN )); then return 0; fi
  if [[ ! -f "$LOG_FILE" ]]; then
    touch "$LOG_FILE" 2>/dev/null || return 0
  fi
  chmod 0600 "$LOG_FILE" 2>/dev/null || true
}

lib_info()  { (( OPT_QUIET )) || printf '%s[info]%s  %s\n' "$C_BLU" "$C_RST" "$*"; lib_log_write INFO "$*"; }
lib_ok()    { (( OPT_QUIET )) || printf '%s[ ok ]%s  %s\n' "$C_GRN" "$C_RST" "$*"; lib_log_write OK "$*"; }
lib_warn()  { printf '%s[warn]%s  %s\n' "$C_YEL" "$C_RST" "$*" >&2; lib_log_write WARN "$*"; }
lib_error() { printf '%s[fail]%s  %s\n' "$C_RED" "$C_RST" "$*" >&2; lib_log_write ERROR "$*"; }
lib_debug() { (( OPT_VERBOSE )) && printf '%s[dbg ]  %s%s\n' "$C_DIM" "$*" "$C_RST"; lib_log_write DEBUG "$*"; return 0; }
lib_note()  { (( OPT_QUIET )) || printf '        %s\n' "$*"; }
lib_heading() { (( OPT_QUIET )) || printf '\n%s%s== %s ==%s\n' "$C_BLD" "$C_CYN" "$*" "$C_RST"; lib_log_write INFO "== $* =="; }

# Step counter: lib_steps_begin 14; lib_step "Installing X"  ->  [3/14] Installing X
lib_steps_begin() { LIB_STEP_TOTAL="$1"; LIB_STEP_CURRENT=0; }
lib_step() {
  LIB_STEP_CURRENT=$((LIB_STEP_CURRENT + 1))
  (( OPT_QUIET )) || printf '\n%s%s[%d/%d]%s %s%s%s\n' "$C_BLD" "$C_CYN" "$LIB_STEP_CURRENT" "$LIB_STEP_TOTAL" "$C_RST" "$C_BLD" "$*" "$C_RST"
  lib_log_write STEP "[${LIB_STEP_CURRENT}/${LIB_STEP_TOTAL}] $*"
}

lib_print_kv() { printf '  %s%-26s%s %s\n' "$C_DIM" "$1" "$C_RST" "$2"; }

lib_log_line_no() {
  if [[ -f "${LOG_FILE:-}" ]]; then wc -l < "$LOG_FILE" | tr -d ' '; else printf '0'; fi
}

# =============================================================================
#  Errors, traps, rollback
# =============================================================================
lib_rollback_clear() { LIB_ROLLBACK_STACK=(); }
lib_rollback_push()  { LIB_ROLLBACK_STACK+=("$*"); lib_debug "rollback step registered: $*"; }
# Remove a step by its exact text, for when it has been handled or no longer applies.
# By value rather than by position: other steps may have been pushed in between.
lib_rollback_drop() {
  local want="$*" s=""
  local -a keep=()
  for s in ${LIB_ROLLBACK_STACK[@]+"${LIB_ROLLBACK_STACK[@]}"}; do
    if [[ "$s" != "$want" ]]; then keep+=("$s"); fi
  done
  LIB_ROLLBACK_STACK=(${keep[@]+"${keep[@]}"})
  return 0
}
lib_rollback_run() {
  local n=${#LIB_ROLLBACK_STACK[@]} i="" cmd=""
  (( n > 0 )) || return 0
  local -a steps=("${LIB_ROLLBACK_STACK[@]}")
  LIB_ROLLBACK_STACK=()            # cleared first: a failing step must not re-enter this loop
  lib_warn "Rolling back ${n} step(s)..."
  for (( i = n - 1; i >= 0; i-- )); do
    cmd="${steps[$i]}"
    lib_log_write ROLLBACK "$cmd"
    (( OPT_VERBOSE )) && lib_note "rollback: $cmd"
    # each step runs in a subshell so that a lib_die inside it cannot abort the remaining steps
    if ! ( LIB_ERR_HANDLING=1; eval "$cmd" ) >>"${LOG_FILE:-/dev/null}" 2>&1; then
      lib_warn "rollback step failed: $cmd"
    fi
  done
  lib_warn "Rollback finished."
}

# lib_die "what failed" ["probable cause"] ["suggested fix"]
# How to invoke this tool in a message: the short alias once it is linked, otherwise the
# checkout being run. "install" links it in its very first step so this is almost always
# the short name, even when the run dies early.
lib_self_cmd() {
  if   [[ -n "${BIN_SHORT:-}" && -x "$BIN_SHORT" ]]; then basename "$BIN_SHORT"
  elif [[ -n "${BIN_LINK:-}"  && -x "$BIN_LINK"  ]]; then basename "$BIN_LINK"
  else printf '%s' "${SCRIPT_PATH:-./setup.sh}"; fi
}

# Point at "doctor" after a failure - but only once a numbered step has begun. A rejected
# command-line flag is not something doctor can diagnose, and suggesting it there is noise.
lib_suggest_doctor() {
  (( ${LIB_STEP_CURRENT:-0} > 0 )) || return 0
  printf '  %sHealth check  :%s sudo %s doctor\n' "$C_YEL" "$C_RST" "$(lib_self_cmd)"
}

lib_die() {
  local what="$1" cause="${2:-}" fix="${3:-}"
  local lineno=""
  lineno="$(lib_log_line_no)"
  lib_log_write ERROR "$what${cause:+ | cause: $cause}${fix:+ | fix: $fix}"
  {
    printf '\n%s%s✖ FAILED:%s %s\n' "$C_BLD" "$C_RED" "$C_RST" "$what"
    [[ -n "$cause" ]] && printf '  %sProbable cause:%s %s\n' "$C_YEL" "$C_RST" "$cause"
    [[ -n "$fix" ]]   && printf '  %sSuggested fix :%s %s\n' "$C_YEL" "$C_RST" "$fix"
    printf '  %sLog           :%s %s (around line %s)\n' "$C_YEL" "$C_RST" "$LOG_FILE" "$lineno"
    lib_suggest_doctor
  } >&2
  LIB_ERR_HANDLING=1
  lib_rollback_run
  exit 1
}

# ERR trap handler: file/line/command + rollback
lib_on_error() {
  local code="$1" line="$2" src="$3" cmd="$4"
  (( LIB_ERR_HANDLING )) && exit "$code"
  LIB_ERR_HANDLING=1
  local lineno=""
  lineno="$(lib_log_line_no)"
  lib_log_write ERROR "unexpected failure (exit ${code}) at ${src}:${line}: ${cmd}"
  {
    printf '\n%s%s✖ FAILED:%s command exited with status %s\n' "$C_BLD" "$C_RED" "$C_RST" "$code"
    printf '  %sWhere         :%s %s:%s\n' "$C_YEL" "$C_RST" "${src##*/}" "$line"
    printf '  %sCommand       :%s %s\n' "$C_YEL" "$C_RST" "$cmd"
    printf '  %sProbable cause:%s see the command output captured in the log\n' "$C_YEL" "$C_RST"
    printf '  %sSuggested fix :%s fix the reported problem and re-run the same command (all operations are idempotent)\n' "$C_YEL" "$C_RST"
    printf '  %sLog           :%s %s (around line %s)\n' "$C_YEL" "$C_RST" "$LOG_FILE" "$lineno"
    if [[ -f "$LOG_FILE" ]]; then
      printf '  %sLast log lines:%s\n' "$C_YEL" "$C_RST"
      tail -n 6 "$LOG_FILE" 2>/dev/null | sed 's/^/    | /'
    fi
    lib_suggest_doctor
  } >&2
  lib_rollback_run
  exit "$code"
}
trap 'lib_on_error "$?" "$LINENO" "${BASH_SOURCE[0]}" "$BASH_COMMAND"' ERR

# Everything temporary lives inside one per-run directory, which the EXIT trap removes.
# Registering each file individually cannot work: lib_mktemp is always called as
# "$(lib_mktemp)", and a command substitution runs in a subshell, so any array the
# function appended to is discarded the moment it returns.
lib_tmp_root_init() {
  [[ -n "${LIB_TMP_ROOT:-}" && -d "${LIB_TMP_ROOT:-}" ]] && return 0
  LIB_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lompstack.XXXXXX")"
  return 0
}

lib_cleanup_on_exit() {
  # the name guard makes an unset or inherited LIB_TMP_ROOT harmless
  if [[ -n "${LIB_TMP_ROOT:-}" && -d "${LIB_TMP_ROOT:-}" && "${LIB_TMP_ROOT}" == */lompstack.?????? ]]; then
    rm -rf -- "$LIB_TMP_ROOT"
  fi
  return 0
}
trap lib_cleanup_on_exit EXIT

# mktemp wrapper. Everything it creates is removed on exit. Usage: f=$(lib_mktemp [-d])
lib_mktemp() {
  local t="" dir="${LIB_TMP_ROOT:-}"
  [[ -n "$dir" && -d "$dir" ]] || dir="${TMPDIR:-/tmp}"
  if [[ "${1:-}" == "-d" ]]; then t="$(mktemp -d "${dir}/ss.XXXXXX")"
  else t="$(mktemp "${dir}/ss.XXXXXX")"; fi
  printf '%s' "$t"
}

# =============================================================================
#  Preconditions
# =============================================================================
lib_require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    lib_common_init_colors
    printf '%sThis script must run as root (use sudo).%s\n' "$C_RED" "$C_RST" >&2
    exit 1
  fi
}

lib_check_os() {
  if [[ ! -r /etc/os-release ]]; then
    lib_die "Cannot detect operating system" "/etc/os-release missing" "Run on Ubuntu 22.04 or 24.04"
  fi
  # shellcheck disable=SC1091
  OS_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
  # shellcheck disable=SC1091
  OS_VERSION_ID="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
  # shellcheck disable=SC1091
  OS_CODENAME="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
  if [[ "$OS_ID" != "ubuntu" ]] || [[ "$OS_VERSION_ID" != "22.04" && "$OS_VERSION_ID" != "24.04" ]]; then
    lib_die "Unsupported operating system: ${OS_ID:-?} ${OS_VERSION_ID:-?}" \
      "Only Ubuntu 22.04 (jammy) and 24.04 (noble) are supported" \
      "Use a supported Ubuntu LTS release"
  fi
  if [[ -z "$OS_CODENAME" ]]; then
    case "$OS_VERSION_ID" in 22.04) OS_CODENAME=jammy ;; 24.04) OS_CODENAME=noble ;; esac
  fi
}

lib_lock() {
  (( OPT_DRY_RUN )) && return 0
  if [[ "${SERVER_SETUP_LOCKED:-0}" == "1" ]]; then return 0; fi   # re-entrant child
  mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    # most often the minute-by-minute .htaccess check reloading OpenLiteSpeed, which takes
    # seconds: wait for it instead of failing at once
    (( OPT_QUIET )) || printf '%sAnother lompstack command is running; waiting for it (up to %s s)...%s\n' \
      "$C_DIM" "${LIB_LOCK_WAIT:-90}" "$C_RST" >&2
    if ! flock -w "${LIB_LOCK_WAIT:-90}" 200; then
      lib_die "Another setup.sh instance is already running" \
        "lock ${LOCK_FILE} is held by another process" \
        "Wait for it to finish (ps aux | grep setup.sh)"
    fi
  fi
  LIB_LOCK_HELD=1
  export SERVER_SETUP_LOCKED=1
}

lib_have() { command -v "$1" >/dev/null 2>&1; }

# Make sure the small set of tools every command needs is present.
lib_require_tools() {
  local missing=() t=""
  for t in jq curl flock; do lib_have "$t" || missing+=("$t"); done
  ((${#missing[@]} == 0)) && return 0
  if (( OPT_DRY_RUN )); then
    lib_warn "Required tools missing: ${missing[*]} (a real run installs them; some dry-run details may be skipped)"
    return 0
  fi
  lib_info "Installing required tools: ${missing[*]}"
  lib_apt_install "${missing[@]}" || lib_die "Could not install ${missing[*]}" "apt failure" "check network / apt sources"
}

lib_is_interactive() {
  (( OPT_NON_INTERACTIVE )) && return 1
  [[ -t 0 && -t 1 ]]
}

# lib_confirm "Question?" [y|n]  -> 0 = yes, 1 = no
lib_confirm() {
  local q="$1" def="${2:-n}" ans=""
  (( OPT_YES )) && { lib_log_write INFO "auto-confirmed: $q"; return 0; }
  if ! lib_is_interactive; then
    lib_log_write INFO "non-interactive default '${def}' for: $q"
    [[ "$def" == "y" ]]
    return
  fi
  local hint="[y/N]"; [[ "$def" == "y" ]] && hint="[Y/n]"
  printf '%s%s%s %s ' "$C_BLD" "$q" "$C_RST" "$hint"
  read -r ans || ans=""
  ans="${ans:-$def}"
  [[ "${ans,,}" == y* ]]
}

# lib_prompt VAR "Question" "default" [secret]
lib_prompt() {
  local -n _out="$1"
  local q="$2" def="${3:-}" secret="${4:-}" ans=""
  if ! lib_is_interactive; then _out="$def"; return 0; fi
  if [[ -n "$secret" ]]; then
    printf '%s%s%s: ' "$C_BLD" "$q" "$C_RST"; read -r -s ans || ans=""; printf '\n'
  else
    printf '%s%s%s [%s]: ' "$C_BLD" "$q" "$C_RST" "$def"; read -r ans || ans=""
  fi
  _out="${ans:-$def}"
}

# =============================================================================
#  Command execution
# =============================================================================
# lib_run cmd args...  : logs the command, captures output into the log, returns rc.
lib_run() {
  if (( OPT_DRY_RUN )); then
    (( OPT_QUIET )) || printf '%s[dry ]%s  would run: %s\n' "$C_MAG" "$C_RST" "$(printf '%s ' "$@" | lib_mask_secrets)"
    return 0
  fi
  lib_log_write CMD "$*"
  local out="" rc=0
  out="$(lib_mktemp)"
  if (( OPT_VERBOSE )); then
    "$@" > >(tee -a "$out") 2>&1 || rc=$?
    wait
  else
    "$@" >"$out" 2>&1 || rc=$?
  fi
  if [[ -s "$out" ]]; then lib_mask_secrets <"$out" >>"$LOG_FILE" 2>/dev/null || true; fi
  if (( rc != 0 )); then
    lib_log_write ERROR "command failed (rc=${rc}): $*"
    if (( ! OPT_VERBOSE )) && [[ -s "$out" ]]; then
      printf '%s        command output (last lines):%s\n' "$C_DIM" "$C_RST" >&2
      tail -n 12 "$out" | lib_mask_secrets | sed 's/^/        | /' >&2
    fi
  fi
  rm -f "$out"
  return "$rc"
}

# Same as lib_run but the log only shows a description (for commands carrying secrets).
lib_run_secret() {
  local desc="$1"; shift
  if (( OPT_DRY_RUN )); then
    (( OPT_QUIET )) || printf '%s[dry ]%s  would run: %s\n' "$C_MAG" "$C_RST" "$desc"
    return 0
  fi
  lib_log_write CMD "$desc"
  local out="" rc=0
  out="$(lib_mktemp)"
  "$@" >"$out" 2>&1 || rc=$?
  if [[ -s "$out" ]]; then lib_mask_secrets <"$out" >>"$LOG_FILE" 2>/dev/null || true; fi
  if (( rc != 0 )); then
    lib_log_write ERROR "command failed (rc=${rc}): $desc"
    if [[ -s "$out" ]]; then tail -n 8 "$out" | lib_mask_secrets | sed 's/^/        | /' >&2; fi
  fi
  rm -f "$out"
  return "$rc"
}

# =============================================================================
#  File helpers
# =============================================================================
# Copy a config file into the archive before modifying it. Prints the backup path.
lib_backup_config() {
  local path="$1" dest="" name=""
  [[ -f "$path" ]] || return 0
  (( OPT_DRY_RUN )) && return 0
  name="$(printf '%s' "$path" | sed 's#^/##; s#/#_#g')"
  dest="${STATE_DIR}/archive/configs/${name}.$(lib_ts)"
  mkdir -p "${STATE_DIR}/archive/configs" && chmod 0700 "${STATE_DIR}" "${STATE_DIR}/archive" 2>/dev/null || true
  cp -p "$path" "$dest" 2>/dev/null || true
  lib_log_write INFO "backup of ${path} -> ${dest}"
  printf '%s' "$dest"
}

# lib_write_file <path> [mode] [owner:group] [secret]   (content on stdin)
# Atomic, idempotent (no-op when identical), backs up the previous version,
# dry-run shows a diff. Sets LIB_FILE_CHANGED=1 when the file was (or would be) modified.
# A fourth argument marks the content as secret: the dry run then prints no contents and no
# diff, and the archived copy of the previous version is closed to everyone but root.
lib_write_file() {
  local path="$1" mode="${2:-}" owner="${3:-}" secret="${4:-}"
  local content="" tmp="" bak=""
  LIB_FILE_CHANGED=0
  content="$(lib_mktemp)"
  cat >"$content"
  if [[ -f "$path" ]] && cmp -s "$content" "$path"; then
    rm -f "$content"
    lib_debug "unchanged: $path"
    if (( ! OPT_DRY_RUN )); then
      [[ -n "$mode" ]]  && chmod "$mode" "$path" 2>/dev/null || true
      [[ -n "$owner" ]] && chown "$owner" "$path" 2>/dev/null || true
    fi
    return 0
  fi
  LIB_FILE_CHANGED=1
  if (( OPT_DRY_RUN )); then
    if [[ -n "$secret" ]]; then
      (( OPT_QUIET )) || printf '%s[dry ]%s  would write %s (%s bytes, contents not shown)\n' "$C_MAG" "$C_RST" "$path" "$(wc -c <"$content" | tr -d ' ')"
    elif [[ -f "$path" ]]; then
      (( OPT_QUIET )) || printf '%s[dry ]%s  would modify %s\n' "$C_MAG" "$C_RST" "$path"
      (( OPT_QUIET )) || diff -u "$path" "$content" 2>/dev/null | head -n 60 | sed 's/^/        /' || true
    else
      (( OPT_QUIET )) || printf '%s[dry ]%s  would create %s (%s lines)\n' "$C_MAG" "$C_RST" "$path" "$(wc -l <"$content" | tr -d ' ')"
    fi
    rm -f "$content"
    return 0
  fi
  if [[ -f "$path" ]]; then
    bak="$(lib_backup_config "$path")"
    if [[ -n "$secret" && -n "$bak" ]]; then chmod 0600 "$bak" 2>/dev/null || true; fi
  fi
  mkdir -p "$(dirname "$path")"
  tmp="${path}.tmp.$$"
  cp "$content" "$tmp"
  rm -f "$content"
  if [[ -n "$mode" ]]; then chmod "$mode" "$tmp"
  elif [[ -f "$path" ]]; then chmod --reference="$path" "$tmp"
  else chmod 0644 "$tmp"; fi
  if [[ -n "$owner" ]]; then chown "$owner" "$tmp"
  elif [[ -f "$path" ]]; then chown --reference="$path" "$tmp"; fi
  mv -f "$tmp" "$path"
  lib_log_write INFO "wrote ${path}"
}

lib_mkdir() {   # lib_mkdir path [mode] [owner:group]
  local path="$1" mode="${2:-}" owner="${3:-}"
  if (( OPT_DRY_RUN )); then
    [[ -d "$path" ]] || { (( OPT_QUIET )) || printf '%s[dry ]%s  would create directory %s\n' "$C_MAG" "$C_RST" "$path"; }
    return 0
  fi
  mkdir -p "$path"
  [[ -n "$mode" ]]  && chmod "$mode" "$path"
  [[ -n "$owner" ]] && chown "$owner" "$path"
  return 0
}

lib_rm() {      # lib_rm path...   (dry-run aware)
  local p=""
  for p in "$@"; do
    [[ -e "$p" || -L "$p" ]] || continue
    if (( OPT_DRY_RUN )); then (( OPT_QUIET )) || printf '%s[dry ]%s  would remove %s\n' "$C_MAG" "$C_RST" "$p"; continue; fi
    rm -rf -- "$p"
    lib_log_write INFO "removed ${p}"
  done
  return 0
}

lib_secure_file() {   # chmod 600 root:root (dry-run aware)
  (( OPT_DRY_RUN )) && return 0
  [[ -e "$1" ]] || return 0
  chown root:root "$1" && chmod 0600 "$1"
  return 0
}

# Append a line if it is not already present (exact match).
lib_append_line_once() {
  local file="$1" line="$2"
  if [[ -f "$file" ]] && grep -qxF -- "$line" "$file"; then return 0; fi
  if (( OPT_DRY_RUN )); then (( OPT_QUIET )) || printf '%s[dry ]%s  would append to %s: %s\n' "$C_MAG" "$C_RST" "$file" "$line"; return 0; fi
  lib_backup_config "$file" >/dev/null
  printf '%s\n' "$line" >>"$file"
  LIB_FILE_CHANGED=1
}

# lib_set_kv file key value [sep]  -> replaces "key sep value" (commented or not) or appends.
lib_set_kv() {
  local file="$1" key="$2" value="$3" sep="${4:-=}"
  local tmp="" ekey=""
  ekey="$(printf '%s' "$key" | sed 's/[][\.*^$/]/\\&/g')"
  tmp="$(lib_mktemp)"
  if [[ -f "$file" ]]; then cp "$file" "$tmp"; else : >"$tmp"; fi
  if grep -qE "^[[:space:]]*[;#]?[[:space:]]*${ekey}[[:space:]]*${sep}" "$tmp"; then
    # replace the first occurrence, drop other (duplicate/commented) occurrences
    awk -v k="$key" -v v="$value" -v s="$sep" -v re="^[[:space:]]*[;#]?[[:space:]]*${ekey}[[:space:]]*${sep}" '
      BEGIN{done=0}
      $0 ~ re { if(!done){ print k " " s " " v; done=1 } ; next }
      { print }' "$tmp" >"${tmp}.2" && mv -f "${tmp}.2" "$tmp"
  else
    printf '%s %s %s\n' "$key" "$sep" "$value" >>"$tmp"
  fi
  lib_write_file "$file" <"$tmp"
  rm -f "$tmp"
}

# =============================================================================
#  apt / systemd / ufw helpers
# =============================================================================
export DEBIAN_FRONTEND=noninteractive

lib_pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
lib_pkg_available() { apt-cache show "$1" >/dev/null 2>&1; }
lib_pkg_version()   { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }

lib_apt_update() {
  (( LIB_APT_UPDATED )) && return 0
  if (( OPT_DRY_RUN )); then LIB_APT_UPDATED=1; lib_debug "dry-run: skipping apt-get update"; return 0; fi
  lib_info "Refreshing package lists..."
  lib_run apt-get update -q || lib_die "apt-get update failed" "network or repository problem" "check /etc/apt/sources.list.d and connectivity"
  LIB_APT_UPDATED=1
}

# Install packages that are not installed yet. Returns 0 when nothing to do.
lib_apt_install() {
  local pkgs=() p=""
  for p in "$@"; do lib_pkg_installed "$p" || pkgs+=("$p"); done
  ((${#pkgs[@]} == 0)) && return 0
  lib_apt_update
  lib_info "Installing packages: ${pkgs[*]}"
  lib_run apt-get install -y -q --no-install-recommends \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "${pkgs[@]}"
}

# Download an apt signing key into /etc/apt/keyrings (binary form). lib_apt_key_install url dest
lib_apt_key_install() {
  local url="$1" dest="$2" tmp=""
  if [[ -s "$dest" ]]; then lib_debug "keyring present: $dest"; return 0; fi
  if (( OPT_DRY_RUN )); then (( OPT_QUIET )) || printf '%s[dry ]%s  would install apt key %s -> %s\n' "$C_MAG" "$C_RST" "$url" "$dest"; return 0; fi
  mkdir -p /etc/apt/keyrings && chmod 0755 /etc/apt/keyrings
  tmp="$(lib_mktemp)"
  curl -fsSL --retry 3 --max-time 60 -o "$tmp" "$url" || lib_die "Could not download signing key ${url}" "network problem" "check connectivity / DNS"
  if head -c 40 "$tmp" | grep -q 'BEGIN PGP PUBLIC KEY'; then
    gpg --dearmor --yes -o "$dest" "$tmp" >/dev/null 2>&1 || lib_die "gpg --dearmor failed for ${url}" "invalid key data" "retry later"
  else
    cp "$tmp" "$dest"
  fi
  chmod 0644 "$dest"
  rm -f "$tmp"
  lib_log_write INFO "installed apt keyring ${dest}"
}

lib_systemctl() {   # lib_systemctl action unit [unit...]
  if (( OPT_DRY_RUN )); then (( OPT_QUIET )) || printf '%s[dry ]%s  would run: systemctl %s\n' "$C_MAG" "$C_RST" "$*"; return 0; fi
  lib_run systemctl "$@"
}
lib_service_active()  { systemctl is-active --quiet "$1" 2>/dev/null; }
lib_service_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }
lib_service_exists()  { systemctl list-unit-files "$1.service" 2>/dev/null | grep -q "^$1.service"; }

lib_ufw_rule() {    # lib_ufw_rule allow 80/tcp comment 'x'   (idempotent by ufw itself)
  if (( OPT_DRY_RUN )); then (( OPT_QUIET )) || printf '%s[dry ]%s  would run: ufw %s\n' "$C_MAG" "$C_RST" "$*"; return 0; fi
  lib_run ufw "$@"
}

# Numbers of every UFW rule whose port column is exactly <port>/tcp (highest first,
# because deleting by number renumbers everything below it).
lib_ufw_port_rule_numbers() {
  local port="$1"
  lib_have ufw || return 0
  # "no matching rule" is a normal result, not an error (pipefail would make grep fail the pipeline)
  ufw status numbered 2>/dev/null \
    | grep -E "^\[[[:space:]]*[0-9]+\][[:space:]]+${port}/tcp" \
    | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/' \
    | sort -rn || true
}

# Remove every UFW rule for a port. Only that port is touched; SSH/80/443 are never matched.
lib_ufw_delete_port_rules() {
  local port="$1" n="" count=0
  lib_have ufw || return 0
  if (( OPT_DRY_RUN )); then
    count="$(lib_ufw_port_rule_numbers "$port" | wc -l | tr -d ' ')"
    (( count > 0 )) && { (( OPT_QUIET )) || printf '%s[dry ]%s  would remove %s UFW rule(s) for port %s\n' "$C_MAG" "$C_RST" "$count" "$port"; }
    return 0
  fi
  while read -r n; do
    [[ -n "$n" ]] || continue
    lib_run ufw --force delete "$n" || lib_warn "could not delete UFW rule ${n}"
    count=$((count + 1))
  done < <(lib_ufw_port_rule_numbers "$port")
  (( count > 0 )) && lib_log_write INFO "removed ${count} UFW rule(s) for port ${port}"
  return 0
}

# systemd drop-in with resource limits. lib_systemd_override unit "LimitNOFILE=65535" ...
lib_systemd_override() {
  local unit="$1"; shift
  local dir="/etc/systemd/system/${unit}.service.d" line=""
  {
    printf '# Managed by lompstack\n[Service]\n'
    for line in "$@"; do printf '%s\n' "$line"; done
  } | lib_write_file "${dir}/99-server-setup.conf" 0644
  if (( LIB_FILE_CHANGED )); then lib_systemctl daemon-reload; fi
}

# =============================================================================
#  Random / misc
# =============================================================================
lib_random_password() {   # alphanumeric, default 32 chars
  local len="${1:-32}" out=""
  while ((${#out} < len)); do
    out+="$(openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c "$len")"
  done
  printf '%s' "${out:0:$len}"
}

lib_random_hex() { openssl rand -hex "${1:-8}"; }

lib_human_mb() {   # MB -> human
  local mb="$1"
  if (( mb >= 1024 )); then awk -v m="$mb" 'BEGIN{printf "%.1f GB", m/1024}'; else printf '%d MB' "$mb"; fi
}

lib_version_ge() { # lib_version_ge 10.11.2 10.6  -> 0 if a >= b
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# lib_join <separator> <item>...
# The separator may be more than one character. The obvious 'local IFS="$1"; printf "%s" "$*"'
# silently uses only IFS's FIRST character, which turned the fail2ban "logpath" continuation
# ($'\n' + 10 spaces) into an unindented line - and an unindented continuation makes fail2ban
# reject the whole jail file, so every host with two or more sites lost its web jails.
lib_join() {
  local sep="$1" out="" first=1 item=""
  shift || return 0
  for item in "$@"; do
    if (( first )); then out="$item"; first=0; else out+="${sep}${item}"; fi
  done
  printf '%s' "$out"
}

lib_days_until() {  # epoch -> whole days from now (may be negative)
  local target="$1" now=""
  now="$(date +%s)"
  printf '%d' $(( (target - now) / 86400 ))
}

lib_file_age_days() {
  local f="$1" m="" now=""
  [[ -e "$f" ]] || { printf '%d' 99999; return 0; }
  m="$(stat -c %Y "$f")"; now="$(date +%s)"
  printf '%d' $(( (now - m) / 86400 ))
}

# =============================================================================
#  JSON / state helpers (jq)
# =============================================================================
lib_json_valid() { [[ -s "$1" ]] && jq -e . "$1" >/dev/null 2>&1; }

lib_json_get() {   # lib_json_get file 'filter' -> raw value ("" if null/missing)
  local file="$1" filter="$2" v=""
  [[ -s "$file" ]] || { printf ''; return 0; }
  v="$(jq -r "$filter // empty" "$file" 2>/dev/null || true)"
  printf '%s' "$v"
}

# Same, but preserving false. jq's "//" treats false like null, so lib_json_get turns a
# literal false into "" - fine for the _d_bool callers, wrong for any "== false" test.
lib_json_get_raw() {
  local file="$1" filter="$2" v=""
  [[ -s "$file" ]] || { printf ''; return 0; }
  v="$(jq -r "$filter" "$file" 2>/dev/null || true)"
  [[ "$v" == "null" ]] && v=""
  printf '%s' "$v"
}

# lib_json_set file 'filter' [--arg k v ...]  (atomic; creates {} when missing)
lib_json_set() {
  local file="$1" filter="$2"; shift 2
  local tmp=""
  if (( OPT_DRY_RUN )); then lib_debug "dry-run: state update skipped (${file}: ${filter})"; return 0; fi
  mkdir -p "$(dirname "$file")"
  local made=0
  if [[ ! -s "$file" ]]; then printf '{}\n' >"$file"; made=1; fi
  tmp="$(lib_mktemp)"
  if ! jq "$@" "$filter" "$file" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    (( made )) && rm -f "$file"      # it was empty a moment ago; an empty object is not state
    lib_die "State update failed for ${file}" "invalid jq filter or corrupted JSON: ${filter}" "inspect ${file}"
  fi
  # A filter written with a comma - '.a = 1, .b = 2' - is a generator: jq prints the object
  # TWICE, once with each change, and the file then holds two documents. Every later read of
  # it returns two answers and the state is quietly broken, so it is refused here.
  if [[ "$(jq -s 'length' "$tmp" 2>/dev/null || printf 0)" != "1" ]]; then
    rm -f "$tmp"
    (( made )) && rm -f "$file"      # it was not there a moment ago; an empty object is not state
    lib_die "State update failed for ${file}" \
      "the filter produced more than one document (a comma where a pipe belongs?): ${filter}" \
      "fix the filter; ${file} is as it was"
  fi
  chmod 0600 "$tmp"
  mv -f "$tmp" "$file"
}

lib_state_init() {
  (( OPT_DRY_RUN )) && return 0
  mkdir -p "$STATE_DIR"/{domains,archive} 2>/dev/null || true
  chmod 0700 "$STATE_DIR" "$STATE_DIR/domains" "$STATE_DIR/archive"
  if [[ ! -s "$STATE_DIR/manifest.json" ]]; then
    jq -n --arg v "$SCRIPT_VERSION" --arg ts "$(lib_iso_now)" \
      '{version:$v, created_at:$ts, components:{}, params:{}, profile:{}, cloudflare:{enabled:false}, backup:{}, notify:{}}' \
      >"$STATE_DIR/manifest.json"
    chmod 0600 "$STATE_DIR/manifest.json"
  fi
}

lib_manifest_get() { lib_json_get "$STATE_DIR/manifest.json" "$1"; }
lib_manifest_set() {          # lib_manifest_set '.path.key' 'string value'
  lib_json_set "$STATE_DIR/manifest.json" "$1 = \$v | .updated_at = \$ts" --arg v "$2" --arg ts "$(lib_iso_now)"
}
lib_manifest_set_json() {     # lib_manifest_set_json '.path.key' '<json literal>'
  lib_json_set "$STATE_DIR/manifest.json" "$1 = \$v | .updated_at = \$ts" --argjson v "$2" --arg ts "$(lib_iso_now)"
}

lib_installed() { [[ -s "$STATE_DIR/manifest.json" ]] && [[ -n "$(lib_manifest_get '.installed_at')" ]]; }

# Restore the settings the operator chose at install time. setup.sh only carries the
# built-in defaults, so without this every later command works from them: "panel open"
# rewrote the WebAdmin listener to the compiled-in 7080 even on a server installed with
# --admin-port, and left a stale UFW rule for the port it abandoned.
# "install" is excluded: it merges flags with the manifest itself.
lib_params_load() {
  local v=""
  { [[ -s "$STATE_DIR/manifest.json" ]] && lib_have jq; } || return 0
  v="$(lib_manifest_get '.params.admin_port')"
  if [[ "$v" =~ ^[0-9]+$ ]]; then ADMIN_PORT="$v"; fi
  v="$(lib_manifest_get '.params.admin_access')"
  if [[ -n "$v" ]]; then ADMIN_ACCESS="$v"; fi
  v="$(lib_manifest_get '.params.admin_ip')"
  if [[ -n "$v" ]]; then ADMIN_ALLOWED_IP="$v"; fi
  v="$(lib_manifest_get '.params.php')"
  if [[ -n "$v" ]]; then PHP_VERSION="$v"; fi
  v="$(lib_manifest_get '.params.email')"
  if [[ -n "$v" && -z "$DEFAULT_EMAIL" ]]; then DEFAULT_EMAIL="$v"; fi
  return 0
}

lib_require_installed() {
  lib_installed || lib_die "Server is not provisioned yet" "manifest missing (${STATE_DIR}/manifest.json)" "Run: sudo ./setup.sh install"
}

# =============================================================================
#  Domain helpers shared by several modules
# =============================================================================
lib_domain_valid() {
  local d="${1,,}"
  [[ ${#d} -le 253 ]] || return 1
  [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

# Sanitised identifier for Linux user / DB names: example.com -> example_com
lib_domain_ident() {
  local d="${1,,}" id=""
  id="$(printf '%s' "$d" | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')"
  [[ "$id" =~ ^[a-z] ]] || id="s_${id}"
  printf '%s' "${id:0:28}"
}

lib_domain_state_dir() { printf '%s/domains/%s' "$STATE_DIR" "$1"; }
lib_domain_json()      { printf '%s/domains/%s/domain.json' "$STATE_DIR" "$1"; }
lib_domain_registered() { [[ -s "$(lib_domain_json "$1")" ]]; }
lib_domain_home()      { printf '%s/%s' "$SITES_ROOT" "$1"; }

lib_domains_list() {   # prints registered domains, one per line
  local d=""
  [[ -d "$STATE_DIR/domains" ]] || return 0
  for d in "$STATE_DIR"/domains/*/domain.json; do
    [[ -s "$d" ]] || continue
    basename "$(dirname "$d")"
  done
}

# =============================================================================
#  Cron (single central file /etc/cron.d/server-setup)
# =============================================================================
# lib_cron_set <id> "<schedule> <user> <command>"   ;  lib_cron_remove <id>
_cron_header_ensure() {   # file
  if ! grep -q '^SHELL=' "$1" 2>/dev/null; then
    {
      printf '# Managed by lompstack - do not edit by hand (entries are regenerated)\n'
      printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\nMAILTO=""\n'
      cat "$1"
    } >"${1}.2" && mv -f "${1}.2" "$1"
  fi
}

lib_cron_set() {
  local id="$1" entry="$2" tmp=""
  tmp="$(lib_mktemp)"
  if [[ -f "$CRON_FILE" ]]; then grep -v -- "# server-setup:${id}\$" "$CRON_FILE" >"$tmp" || true; fi
  _cron_header_ensure "$tmp"
  printf '%s # server-setup:%s\n' "$entry" "$id" >>"$tmp"
  lib_write_file "$CRON_FILE" 0644 root:root <"$tmp"
  rm -f "$tmp"
}

lib_cron_remove() {
  local id="$1" tmp=""
  [[ -f "$CRON_FILE" ]] || return 0
  grep -q -- "# server-setup:${id}\$" "$CRON_FILE" || return 0
  tmp="$(lib_mktemp)"
  grep -v -- "# server-setup:${id}\$" "$CRON_FILE" >"$tmp" || true
  lib_write_file "$CRON_FILE" 0644 root:root <"$tmp"
  rm -f "$tmp"
}

lib_cron_has() { [[ -f "$CRON_FILE" ]] && grep -q -- "# server-setup:${1}\$" "$CRON_FILE"; }

# Replace every entry whose id starts with the prefix (all scheduled jobs of one site, say)
# with the "id<TAB>entry" lines on stdin, in a single write.
lib_cron_replace_prefix() {   # id prefix
  local marker="# server-setup:${1}" tmp="" id="" entry="" n=0
  tmp="$(lib_mktemp)"
  if [[ -f "$CRON_FILE" ]]; then awk -v m="$marker" 'index($0, m) == 0' "$CRON_FILE" >"$tmp"; fi
  while IFS=$'\t' read -r id entry; do
    [[ -n "$id" && -n "$entry" ]] || continue
    # cron ignores a whole file that holds one line it cannot parse - and this file also
    # carries the backups, the certificate renewals and the health check
    if ! [[ "$entry" =~ ^(@[a-z]+|[^[:space:]]+([[:space:]]+[^[:space:]]+){4})[[:space:]]+[a-z_][a-z0-9_-]*[[:space:]]+[^[:space:]] ]]; then
      lib_warn "not writing a cron entry that cron could not parse (${id})"
      continue
    fi
    n=$((n + 1))
    printf '%s # server-setup:%s\n' "$entry" "$id" >>"${tmp}.entries"
  done
  if (( n == 0 )) && [[ ! -f "$CRON_FILE" ]]; then rm -f "$tmp"; return 0; fi
  _cron_header_ensure "$tmp"
  if (( n > 0 )); then cat "${tmp}.entries" >>"$tmp"; fi
  rm -f "${tmp}.entries"
  lib_write_file "$CRON_FILE" 0644 root:root <"$tmp"
  rm -f "$tmp"
}

lib_cron_remove_prefix() { lib_cron_replace_prefix "$1" </dev/null; }   # id prefix

# =============================================================================
#  Network helpers
# =============================================================================
lib_public_ipv4() {
  local ip="" u=""
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip="$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then printf '%s' "$ip"; return 0; fi
  done
  printf ''
}

lib_public_ipv6() {
  local ip="" u=""
  for u in https://api6.ipify.org https://ipv6.icanhazip.com; do
    ip="$(curl -6 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" == *:* ]]; then printf '%s' "$ip"; return 0; fi
  done
  printf ''
}

lib_primary_ipv4() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

lib_resolve() {    # lib_resolve A|AAAA name -> addresses (one per line)
  local type="$1" name="$2"
  if lib_have dig; then
    dig +short +time=3 +tries=2 "$type" "$name" 2>/dev/null | grep -E '^[0-9a-fA-F.:]+$' || true
  else
    if [[ "$type" == "A" ]]; then getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | sort -u || true
    else getent ahostsv6 "$name" 2>/dev/null | awk '{print $1}' | sort -u || true; fi
  fi
}

# lib_ip_in_cidr_list ip file  -> 0 when ip is inside any CIDR listed in file
lib_ip_in_cidr_list() {
  local ip="$1" file="$2"
  [[ -s "$file" ]] || return 1
  python3 - "$ip" "$file" <<'PYEOF'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1].strip())
with open(sys.argv[2]) as fh:
    for line in fh:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        try:
            net = ipaddress.ip_network(line, strict=False)
        except ValueError:
            continue
        if ip.version == net.version and ip in net:
            sys.exit(0)
sys.exit(1)
PYEOF
}

# The address the administrator is connected FROM (not the server's own address).
# Empty when the session is not an SSH session, e.g. a provider web console.
#
# sudo resets the environment by default, so SSH_CONNECTION is gone under "sudo lompstack".
# Three sources are tried in order: our own environment, the environment of an ancestor
# process (the login shell still has it), and finally the utmp entry for our terminal.
# Deliberately not an RFC 5322 parser. Its job is to keep line breaks, quotes, backslashes
# and shell metacharacters out of a value that is written into configuration files and mail
# headers: "--email 'x@y.z\nuser root'" reached httpd_config.conf as two directives.
lib_email_valid() {
  local e="${1:-}"
  [[ -n "$e" ]] || return 1
  [[ "$e" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$ ]]
}

lib_admin_ip_valid() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$1" == *:*:* ]]; }

# Extract the remote address from "who -m" output given on stdin. A local console has no
# address, and an X display shows up as ":0", neither of which is a client address.
lib_admin_ip_from_who() {
  local out=""
  out="$(cat)"
  printf '%s' "$(sed -nE 's/.*\(([^)]+)\)[[:space:]]*$/\1/p' <<<"$out" | sed -n 1p)"
}

# Walk our own process ancestry looking for an inherited SSH_CONNECTION. /proc/PID/environ
# is frozen at exec time, so the login shell and the sudo process both still carry it even
# though sudo stripped it from ours.
lib_admin_ip_from_ancestors() {
  local pid="$$" hops=0 env_data="" ip=""
  while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" ]] && (( hops < 20 )); do
    hops=$(( hops + 1 ))
    if [[ -r "/proc/${pid}/environ" ]]; then
      env_data="$(tr '\0' '\n' <"/proc/${pid}/environ" 2>/dev/null || true)"
      ip="$(awk -F= '$1=="SSH_CONNECTION"{print $2; exit}' <<<"$env_data")"
      ip="${ip%% *}"
      if [[ -n "$ip" ]]; then printf '%s' "$ip"; return 0; fi
    fi
    pid="$(awk '/^PPid:/{print $2; exit}' "/proc/${pid}/status" 2>/dev/null || true)"
  done
  printf ''
}

lib_admin_client_ip() {
  local ip=""
  [[ -n "${SSH_CONNECTION:-}" ]] && ip="${SSH_CONNECTION%% *}"
  [[ -z "$ip" ]] && ip="$(lib_admin_ip_from_ancestors)"
  if [[ -z "$ip" ]] && lib_have who; then ip="$(who -m 2>/dev/null | lib_admin_ip_from_who || true)"; fi
  lib_admin_ip_valid "$ip" || ip=""
  printf '%s' "$ip"
}

# Detect SSH ports: active connection first, then sshd -T, then listening sockets.
lib_ssh_ports() {
  local ports=() p=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    p="$(awk '{print $4}' <<<"$SSH_CONNECTION")"
    [[ "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
  fi
  # "|| true" is load-bearing. A process substitution runs in its own subshell that
  # inherits the ERR trap (set -E), so when a probe here fails the trap prints a full
  # "FAILED: command exited with status 255" report in the middle of a healthy install.
  # And these probes DO fail on healthy hosts: "sshd -T" exits 255 whenever the config has
  # a Match block it cannot evaluate without -C (Ubuntu 24.04 ships one), and "ss" is
  # absent in minimal containers. A failure here only means "this source has no answer".
  if lib_have sshd; then
    while read -r p; do
      if [[ "$p" =~ ^[0-9]+$ ]]; then ports+=("$p"); fi
    done < <(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' || true)
  fi
  while read -r p; do
    if [[ "$p" =~ ^[0-9]+$ ]]; then ports+=("$p"); fi
  done < <(ss -tlnpH 2>/dev/null | awk '/sshd/{split($4,a,":"); print a[length(a)]}' || true)
  ((${#ports[@]} == 0)) && ports+=(22)
  printf '%s\n' "${ports[@]}" | sort -un | tr '\n' ' ' | sed 's/ $//'
}

lib_port_listening() {   # lib_port_listening 443 [tcp|udp]
  local port="$1" proto="${2:-tcp}"
  if [[ "$proto" == "udp" ]]; then ss -ulnH 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${port}\$"
  else ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; fi
}

# Whether a port answers an address the internet can reach. A loopback listener is not one:
# 127.0.0.1 and ::1 can only be reached from this machine, which is the whole point of the
# ports the mail stack and the webmail talk to each other on.
lib_port_listening_public() {   # lib_port_listening_public 10587 [tcp|udp]
  local port="$1" proto="${2:-tcp}" f=""
  if [[ "$proto" == "udp" ]]; then f="$(ss -ulnH 2>/dev/null | awk '{print $5}' || true)"
  else f="$(ss -tlnH 2>/dev/null | awk '{print $4}' || true)"; fi
  grep -E "[:.]${port}\$" <<<"$f" | grep -qvE '^(127\.|\[?::1\]?)' || return 1
  return 0
}

# "name (pid N)" for whoever is listening on a port, or "" when it is free.
# Used to turn "Address already in use" into a message that names the culprit.
lib_port_holder() {   # lib_port_holder 7080 [tcp|udp]
  local port="$1" proto="${2:-tcp}" line="" out=""
  if [[ "$proto" == "udp" ]]; then line="$(ss -ulnpH 2>/dev/null | awk -v p="[:.]${port}$" '$5 ~ p {print; exit}' || true)"
  else line="$(ss -tlnpH 2>/dev/null | awk -v p="[:.]${port}$" '$4 ~ p {print; exit}' || true)"; fi
  [[ -n "$line" ]] || { printf ''; return 0; }
  out="$(sed -nE 's/.*users:\(\("([^"]+)",pid=([0-9]+).*/\1 (pid \2)/p' <<<"$line")"
  printf '%s' "${out:-an unidentified process}"
}

# lib_tcp_open host port: does something accept a TCP connection there within 2 seconds?
# Use it as a condition only ("if lib_tcp_open ..."): its status is the answer.
lib_tcp_open() {   # host port [timeout-seconds]
  timeout "${3:-2}" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" >/dev/null 2>&1
}

# Run curl and print exactly one three-digit HTTP status code ("000" when the request failed).
# curl already prints 000 on a connection failure and then exits non-zero, so a naive
# "|| printf '000'" appends a second one and produces "000000", which every caller then
# compares against "000" and wrongly treats as a success.
lib_http_code() {   # lib_http_code url [extra curl args...]
  local url="$1" code=""; shift
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" "$url" 2>/dev/null || true)"
  [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
  printf '%s' "$code"
}
