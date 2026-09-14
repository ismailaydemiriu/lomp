#!/usr/bin/env bash
# lib/ols.sh - OpenLiteSpeed: repository, installation, safe config editing
#              (transactions + snapshots + config test + graceful reload),
#              server tuning, listeners, default vhost, WebAdmin, templates.

LSWS_CONF="${LSWS_HOME}/conf/httpd_config.conf"
LSWS_VHOSTS_DIR="${LSWS_HOME}/conf/vhosts"
LSWS_ADMIN_CONF="${LSWS_HOME}/admin/conf/admin_config.conf"
LSWS_BIN="${LSWS_HOME}/bin/openlitespeed"
OLS_SERVICE="lsws"
OLS_DEFAULT_VHOST="_default"
OLS_DEFAULT_ROOT="${LSWS_HOME}/_default"
OLS_LISTENER_HTTP="HTTP"
OLS_LISTENER_HTTPS="HTTPS"
OLS_CACHE_DIR="${LSWS_HOME}/cachedata"
OLS_CIPHERS="ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305"
OLS_APT_LIST="/etc/apt/sources.list.d/litespeed.list"
OLS_LEGACY_APT_LIST="/etc/apt/sources.list.d/lst_debian_repo.list"

OLS_TX_FILE=""          # working copy of httpd_config.conf during a transaction
OLS_SNAPSHOT=""         # conf/ snapshot taken by lib_ols_change_begin
OLS_PENDING_RELOAD=0    # set when something changed and OLS must be reloaded
OLS_CONF_CHANGED=0
OLS_TEST_OUTPUT=""

# =============================================================================
#  Repository & installation
# =============================================================================
lib_ols_repo_setup() {
  if [[ -f "$OLS_LEGACY_APT_LIST" ]]; then
    lib_ok "LiteSpeed repository already configured (${OLS_LEGACY_APT_LIST})"
    return 0
  fi
  lib_apt_key_install "https://rpms.litespeedtech.com/debian/lst_debian_repo.gpg" /etc/apt/keyrings/litespeed-debian.gpg
  lib_apt_key_install "https://rpms.litespeedtech.com/debian/lst_repo.gpg" /etc/apt/keyrings/litespeed.gpg
  printf 'deb [signed-by=/etc/apt/keyrings/litespeed-debian.gpg,/etc/apt/keyrings/litespeed.gpg] https://rpms.litespeedtech.com/debian/ %s main\n' "$OS_CODENAME" \
    | lib_write_file "$OLS_APT_LIST" 0644 root:root
  if (( LIB_FILE_CHANGED )); then LIB_APT_UPDATED=0; lib_ok "LiteSpeed repository added (${OLS_APT_LIST})"
  else lib_ok "LiteSpeed repository already configured"; fi
}

lib_ols_is_installed() { [[ -x "$LSWS_BIN" && -f "$LSWS_CONF" ]]; }

lib_ols_version() {
  [[ -x "$LSWS_BIN" ]] || { printf ''; return 0; }
  "$LSWS_BIN" -v 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -n1 || true
}

lib_ols_user()  { local u; u="$(lib_ols_conf_top_get user)";  printf '%s' "${u:-nobody}"; }
lib_ols_group() { local g; g="$(lib_ols_conf_top_get group)"; printf '%s' "${g:-nogroup}"; }

lib_ols_install() {
  if lib_ols_is_installed; then
    lib_ok "OpenLiteSpeed already installed (version $(lib_ols_version))"
  else
    lib_apt_install openlitespeed || lib_die "OpenLiteSpeed installation failed" "apt could not install 'openlitespeed'" "check the LiteSpeed repository entry and network"
    (( OPT_DRY_RUN )) || lib_ols_is_installed || lib_die "OpenLiteSpeed binary missing after installation" "package did not deliver ${LSWS_BIN}" "apt-get install --reinstall openlitespeed"
    lib_ok "OpenLiteSpeed installed (version $(lib_ols_version || true)${OPT_DRY_RUN:+ }$( (( OPT_DRY_RUN )) && printf 'dry-run'))"
  fi
  lib_systemctl enable "$OLS_SERVICE" >/dev/null 2>&1 || true
  lib_mkdir "$LSWS_VHOSTS_DIR" 0750 lsadm:lsadm
  lib_mkdir "$OLS_CACHE_DIR" 0750 "$(lib_ols_user):$(lib_ols_group)"
  # owned by the server user: a root-owned docRoot makes OpenLiteSpeed log a uid/gid warning
  lib_mkdir "${OLS_DEFAULT_ROOT}/html" 0755 "$(lib_ols_user):$(lib_ols_group)"
  lib_ols_acme_root_ensure
  return 0
}

# The shared ACME webroot is referenced by every generated vhost, including the catch-all,
# so it has to exist before any configuration test runs - not only when certbot is set up.
lib_ols_acme_root_ensure() {
  lib_mkdir "${ACME_ROOT}/.well-known/acme-challenge" 0755 root:root
}

# =============================================================================
#  Low-level config parsing (awk, heredoc aware, case-insensitive block types)
# =============================================================================
# print "start end" of the first top-level block:  _ols_span file type [name]
_ols_span() {
  local file="$1" type="${2,,}" name="${3:-}"
  [[ -f "$file" ]] || return 0
  awk -v t="$type" -v n="$name" '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
    BEGIN{ depth=0; here=""; inblk=0; start=0 }
    {
      l=$0
      if (here != "") { if (trim(l)==here) here=""; next }
      if (match(l, /<<<[A-Za-z0-9_]+[[:space:]]*$/)) { here=trim(substr(l,RSTART+3)) }
      if (l ~ /\{[[:space:]]*$/) {
        if (depth==0 && !inblk) {
          h=l; sub(/\{[[:space:]]*$/,"",h); h=trim(h)
          np=split(h, parts, /[[:space:]]+/)
          bt=tolower(parts[1]); bn=(np>=2)?parts[2]:""
          if (bt==t && ((n=="" && bn=="") || (n!="" && bn==n))) { inblk=1; start=NR }
        }
        depth++
        next
      }
      if (l ~ /^[[:space:]]*\}[[:space:]]*$/) {
        depth--
        if (inblk && depth==0) { print start, NR; exit }
      }
    }' "$file"
}

# key inside a block (depth 1):  _ols_block_key file type name key get|set|del [value]
_ols_block_key() {
  local file="$1" type="${2,,}" name="$3" key="$4" op="$5" value="${6:-}"
  awk -v t="$type" -v n="$name" -v k="$key" -v op="$op" -v v="$value" '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
    function fmt(key,val){ return sprintf("  %-24s%s", key, val) }
    BEGIN{ depth=0; here=""; inblk=0; done=0; lk=tolower(k); bdepth=0 }
    {
      l=$0
      if (here != "") { if (op!="get") print l; if (trim(l)==here) here=""; next }
      ishere=0
      if (match(l, /<<<[A-Za-z0-9_]+[[:space:]]*$/)) { here=trim(substr(l,RSTART+3)); ishere=1 }
      if (l ~ /\{[[:space:]]*$/) {
        if (depth==0 && !inblk) {
          h=l; sub(/\{[[:space:]]*$/,"",h); h=trim(h)
          np=split(h, parts, /[[:space:]]+/)
          bt=tolower(parts[1]); bn=(np>=2)?parts[2]:""
          if (bt==t && ((n=="" && bn=="") || (n!="" && bn==n))) { inblk=1; bdepth=depth }
        }
        depth++
        if (op!="get") print l
        next
      }
      if (l ~ /^[[:space:]]*\}[[:space:]]*$/) {
        depth--
        if (inblk && depth==bdepth) {
          if (op=="set" && !done) { print fmt(k, v); done=1 }
          inblk=0
        }
        if (op!="get") print l
        next
      }
      if (inblk && depth==bdepth+1 && !ishere) {
        tl=trim(l); split(tl, w, /[[:space:]]+/)
        if (tolower(w[1])==lk) {
          if (op=="get") { val=tl; sub(/^[^[:space:]]+[[:space:]]*/,"",val); print val; exit }
          if (op=="set") { if (!done) { print fmt(k, v); done=1 }; next }
          if (op=="del") { next }
        }
      }
      if (op!="get") print l
    }' "$file"
}

# listener map lines:  _ols_map file listener vhost get|set|del [domains]
_ols_map() {
  local file="$1" listener="$2" vhost="$3" op="$4" domains="${5:-}"
  awk -v n="$listener" -v vh="$vhost" -v op="$op" -v d="$domains" '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
    function fmt(val){ return sprintf("  %-24s%s", "map", val) }
    BEGIN{ depth=0; here=""; inblk=0; done=0; bdepth=0 }
    {
      l=$0
      if (here != "") { if (op!="get") print l; if (trim(l)==here) here=""; next }
      if (match(l, /<<<[A-Za-z0-9_]+[[:space:]]*$/)) { here=trim(substr(l,RSTART+3)) }
      if (l ~ /\{[[:space:]]*$/) {
        if (depth==0 && !inblk) {
          h=l; sub(/\{[[:space:]]*$/,"",h); h=trim(h)
          np=split(h, parts, /[[:space:]]+/)
          if (tolower(parts[1])=="listener" && np>=2 && parts[2]==n) { inblk=1; bdepth=depth }
        }
        depth++
        if (op!="get") print l
        next
      }
      if (l ~ /^[[:space:]]*\}[[:space:]]*$/) {
        depth--
        if (inblk && depth==bdepth) {
          if (op=="set" && !done) { print fmt(vh " " d); done=1 }
          inblk=0
        }
        if (op!="get") print l
        next
      }
      if (inblk && depth==bdepth+1) {
        tl=trim(l); split(tl, w, /[[:space:]]+/)
        if (tolower(w[1])=="map" && w[2]==vh) {
          if (op=="get") { val=tl; sub(/^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]*/,"",val); print val; exit }
          if (op=="set") { if (!done) { print fmt(vh " " d); done=1 }; next }
          if (op=="del") { next }
        }
      }
      if (op!="get") print l
    }' "$file"
}

# top-level (depth 0) key:  _ols_top_key file key get|set|del [value]
_ols_top_key() {
  local file="$1" key="$2" op="$3" value="${4:-}"
  awk -v k="$key" -v op="$op" -v v="$value" '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
    function fmt(key,val){ return sprintf("%-26s%s", key, val) }
    BEGIN{ depth=0; here=""; done=0; lk=tolower(k); n=0; firstblk=0 }
    {
      l=$0; n++; lines[n]=l; keep[n]=1
      if (here != "") { if (trim(l)==here) here=""; next }
      if (match(l, /<<<[A-Za-z0-9_]+[[:space:]]*$/)) { here=trim(substr(l,RSTART+3)); next }
      if (l ~ /\{[[:space:]]*$/) { if (depth==0 && !firstblk) firstblk=n; depth++; next }
      if (l ~ /^[[:space:]]*\}[[:space:]]*$/) { depth--; next }
      if (depth==0) {
        tl=trim(l); split(tl, w, /[[:space:]]+/)
        if (tolower(w[1])==lk) {
          if (op=="get") { val=tl; sub(/^[^[:space:]]+[[:space:]]*/,"",val); print val; exit }
          if (op=="set") { if (!done) { lines[n]=fmt(k, v); done=1 } else keep[n]=0 }
          if (op=="del") { keep[n]=0 }
        }
      }
    }
    END{
      if (op=="get") exit
      for (i=1;i<=n;i++) {
        if (op=="set" && !done && firstblk>0 && i==firstblk) { print fmt(k, v); print ""; done=1 }
        if (keep[i]) print lines[i]
      }
      if (op=="set" && !done) print fmt(k, v)
    }' "$file"
}

# names of all top-level blocks of a type:  _ols_block_names file type
_ols_block_names() {
  local file="$1" type="${2,,}"
  [[ -f "$file" ]] || return 0
  awk -v t="$type" '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
    BEGIN{ depth=0; here="" }
    {
      l=$0
      if (here != "") { if (trim(l)==here) here=""; next }
      if (match(l, /<<<[A-Za-z0-9_]+[[:space:]]*$/)) { here=trim(substr(l,RSTART+3)) }
      if (l ~ /\{[[:space:]]*$/) {
        if (depth==0) {
          h=l; sub(/\{[[:space:]]*$/,"",h); h=trim(h)
          np=split(h, parts, /[[:space:]]+/)
          if (tolower(parts[1])==t && np>=2) print parts[2]
        }
        depth++; next
      }
      if (l ~ /^[[:space:]]*\}[[:space:]]*$/) depth--
    }' "$file"
}

# brace balance check (heredoc aware): returns 0 when balanced
_ols_braces_balanced() {
  awk '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
    BEGIN{ depth=0; here=""; bad=0 }
    {
      l=$0
      if (here != "") { if (trim(l)==here) here=""; next }
      if (match(l, /<<<[A-Za-z0-9_]+[[:space:]]*$/)) { here=trim(substr(l,RSTART+3)); next }
      if (l ~ /\{[[:space:]]*$/) depth++
      else if (l ~ /^[[:space:]]*\}[[:space:]]*$/) { depth--; if (depth<0) bad=1 }
    }
    END{ exit (bad || depth!=0) ? 1 : 0 }' "$1"
}

# remove a block (and collapse blank lines)
_ols_block_remove_stream() {   # file type name -> stdout
  local file="$1" type="$2" name="$3" span="" s="" e=""
  span="$(_ols_span "$file" "$type" "$name")"
  if [[ -z "$span" ]]; then cat "$file"; return 0; fi
  s="${span%% *}"; e="${span##* }"
  awk -v s="$s" -v e="$e" 'NR<s || NR>e' "$file" | cat -s
}

# replace a block with the content of $4 (a file) or append it
_ols_block_put_stream() {      # file type name contentfile -> stdout
  local file="$1" type="$2" name="$3" content="$4" span="" s="" e=""
  span="$(_ols_span "$file" "$type" "$name")"
  if [[ -z "$span" ]]; then
    cat "$file"
    [[ -s "$file" ]] && printf '\n'
    cat "$content"
    return 0
  fi
  s="${span%% *}"; e="${span##* }"
  awk -v s="$s" -v e="$e" -v cf="$content" '
    NR==s { while ((getline line < cf) > 0) print line; close(cf); next }
    NR>s && NR<=e { next }
    { print }' "$file"
}

# =============================================================================
#  Transaction API on httpd_config.conf
# =============================================================================
lib_ols_tx_begin() {
  OLS_TX_FILE="$(lib_mktemp)"
  if [[ -f "$LSWS_CONF" ]]; then cp "$LSWS_CONF" "$OLS_TX_FILE"; else : >"$OLS_TX_FILE"; fi
}
_ols_tx_apply() {   # stdin -> tx file
  local tmp=""; tmp="$(mktemp "${TMPDIR:-/tmp}/server-setup.XXXXXX")"
  cat >"$tmp" && mv -f "$tmp" "$OLS_TX_FILE"
}
lib_ols_tx_top_set()      { _ols_top_key "$OLS_TX_FILE" "$1" set "$2" | _ols_tx_apply; }
lib_ols_tx_top_get()      { _ols_top_key "$OLS_TX_FILE" "$1" get; }
lib_ols_tx_top_del()      { _ols_top_key "$OLS_TX_FILE" "$1" del | _ols_tx_apply; }
lib_ols_tx_block_set()    { _ols_block_key "$OLS_TX_FILE" "$1" "$2" "$3" set "$4" | _ols_tx_apply; }   # type name key value
lib_ols_tx_block_get()    { _ols_block_key "$OLS_TX_FILE" "$1" "$2" "$3" get; }
lib_ols_tx_block_del()    { _ols_block_key "$OLS_TX_FILE" "$1" "$2" "$3" del | _ols_tx_apply; }
lib_ols_tx_block_exists() { [[ -n "$(_ols_span "$OLS_TX_FILE" "$1" "${2:-}")" ]]; }
lib_ols_tx_block_remove() { _ols_block_remove_stream "$OLS_TX_FILE" "$1" "${2:-}" | _ols_tx_apply; }
lib_ols_tx_block_put() {    # type name  (block content on stdin)
  local c=""; c="$(lib_mktemp)"; cat >"$c"
  _ols_block_put_stream "$OLS_TX_FILE" "$1" "$2" "$c" | _ols_tx_apply
  rm -f "$c"
}
lib_ols_tx_map_set()      { _ols_map "$OLS_TX_FILE" "$1" "$2" set "$3" | _ols_tx_apply; }   # listener vhost domains
lib_ols_tx_map_get()      { _ols_map "$OLS_TX_FILE" "$1" "$2" get; }
lib_ols_tx_map_del()      { _ols_map "$OLS_TX_FILE" "$1" "$2" del | _ols_tx_apply; }
lib_ols_tx_diff()         { [[ -f "$LSWS_CONF" ]] && diff -u "$LSWS_CONF" "$OLS_TX_FILE" || true; }

lib_ols_tx_commit() {
  OLS_CONF_CHANGED=0
  lib_write_file "$LSWS_CONF" 0640 lsadm:lsadm <"$OLS_TX_FILE"
  OLS_CONF_CHANGED="$LIB_FILE_CHANGED"
  rm -f "$OLS_TX_FILE"; OLS_TX_FILE=""
  (( OLS_CONF_CHANGED )) && OLS_PENDING_RELOAD=1
  return 0
}
lib_ols_tx_abort() { [[ -n "$OLS_TX_FILE" ]] && rm -f "$OLS_TX_FILE"; OLS_TX_FILE=""; return 0; }

# read-only helpers on the live configuration
lib_ols_conf_top_get()      { [[ -f "$LSWS_CONF" ]] && _ols_top_key "$LSWS_CONF" "$1" get || true; }
lib_ols_conf_block_exists() { [[ -n "$(_ols_span "$LSWS_CONF" "$1" "${2:-}")" ]]; }
lib_ols_conf_block_get()    { [[ -f "$LSWS_CONF" ]] && _ols_block_key "$LSWS_CONF" "$1" "$2" "$3" get || true; }
lib_ols_conf_map_get()      { [[ -f "$LSWS_CONF" ]] && _ols_map "$LSWS_CONF" "$1" "$2" get || true; }
lib_ols_conf_vhosts()       { _ols_block_names "$LSWS_CONF" virtualhost; }

# =============================================================================
#  Snapshots, config test, reload
# =============================================================================
lib_ols_snapshot_take() {
  local dest="" ts=""
  ts="$(lib_ts)"
  dest="${STATE_DIR}/archive/ols-conf-${ts}.tar.gz"
  mkdir -p "${STATE_DIR}/archive" && chmod 0700 "${STATE_DIR}/archive"
  if ! tar -czf "$dest" -C "$LSWS_HOME" conf 2>/dev/null; then
    lib_warn "could not snapshot ${LSWS_HOME}/conf"
    printf ''
    return 0
  fi
  # keep the last 10 snapshots
  find "${STATE_DIR}/archive" -maxdepth 1 -name 'ols-conf-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | awk 'NR>10{print $2}' | xargs -r rm -f || true
  printf '%s' "$dest"
}

lib_ols_snapshot_restore() {
  local snap="$1" tmp=""
  if [[ -z "$snap" || ! -f "$snap" ]]; then lib_warn "no OpenLiteSpeed snapshot available to restore"; return 1; fi
  tmp="$(lib_mktemp -d)"
  if ! tar -xzf "$snap" -C "$tmp"; then lib_warn "snapshot ${snap} is unreadable"; return 1; fi
  rm -rf "${LSWS_HOME}/conf.failed"
  if ! mv "${LSWS_HOME}/conf" "${LSWS_HOME}/conf.failed"; then return 1; fi
  if ! mv "${tmp}/conf" "${LSWS_HOME}/conf"; then
    mv "${LSWS_HOME}/conf.failed" "${LSWS_HOME}/conf" || true
    return 1
  fi
  rm -rf "${LSWS_HOME}/conf.failed"
  lib_warn "OpenLiteSpeed configuration restored from ${snap}"
  lib_log_write ROLLBACK "OLS conf restored from ${snap}"
  return 0
}

# Structural checks + "openlitespeed -t". Output/diagnostics in OLS_TEST_OUTPUT.
lib_ols_config_test() {
  local f="" rc=0 out="" name="" cfg=""
  OLS_TEST_OUTPUT=""
  [[ -f "$LSWS_CONF" ]] || { OLS_TEST_OUTPUT="missing ${LSWS_CONF}"; return 1; }
  for f in "$LSWS_CONF" "$LSWS_VHOSTS_DIR"/*/vhconf.conf; do
    [[ -f "$f" ]] || continue
    if ! _ols_braces_balanced "$f"; then OLS_TEST_OUTPUT="unbalanced braces in ${f}"; lib_log_write ERROR "$OLS_TEST_OUTPUT"; return 1; fi
  done
  while read -r name; do
    [[ -n "$name" ]] || continue
    cfg="$(_ols_block_key "$LSWS_CONF" virtualhost "$name" configFile get)"
    [[ "$cfg" == /* ]] || cfg="${LSWS_HOME}/${cfg}"
    if [[ -n "$cfg" && ! -f "$cfg" ]]; then OLS_TEST_OUTPUT="virtualhost ${name}: configFile ${cfg} does not exist"; lib_log_write ERROR "$OLS_TEST_OUTPUT"; return 1; fi
  done < <(lib_ols_conf_vhosts)
  if [[ -x "$LSWS_BIN" ]]; then
    out="$(timeout 90 "$LSWS_BIN" -t 2>&1)" || rc=$?
    OLS_TEST_OUTPUT="$out"
    [[ -n "$out" ]] && { printf '%s\n' "$out" | lib_mask_secrets >>"$LOG_FILE" 2>/dev/null || true; }
    if (( rc != 0 )) || grep -q '\[ERROR\]' <<<"$out"; then
      lib_log_write ERROR "openlitespeed -t failed (rc=${rc})"
      return 1
    fi
  fi
  return 0
}

lib_ols_running() { lib_service_active "$OLS_SERVICE"; }

# "systemctl reload lsws" runs ExecReload, which is "lswsctrl restart": a graceful restart
# that replaces the main process. systemd goes on tracking the old PID, sees it exit and
# marks the unit inactive while OpenLiteSpeed keeps serving. The unit then supervises
# nothing, "systemctl status" lies, and a later stop leaves orphans. A restart keeps
# systemd's view of the service correct, and its ExecStop already drains connections.
lib_ols_reload() {
  if lib_ols_running; then lib_systemctl restart "$OLS_SERVICE"; else lib_systemctl start "$OLS_SERVICE"; fi
}

lib_ols_restart() { lib_systemctl restart "$OLS_SERVICE"; }

# The server answers but systemd does not own it any more (see above, or somebody ran
# lswsctrl by hand). Put the two back in sync.
lib_ols_service_desynced() {
  lib_ols_is_installed || return 1
  lib_service_active "$OLS_SERVICE" && return 1
  lib_port_listening 80
}

lib_ols_service_repair() {
  (( OPT_DRY_RUN )) && return 0
  lib_ols_service_desynced || return 0
  lib_warn "OpenLiteSpeed is serving but systemd has lost track of the unit; re-attaching it"
  if [[ -x "${LSWS_HOME}/bin/lswsctrl" ]]; then lib_run "${LSWS_HOME}/bin/lswsctrl" stop || true; fi
  lib_systemctl stop "$OLS_SERVICE" || true
  sleep 1
  lib_systemctl start "$OLS_SERVICE" || true
  if lib_ols_wait_ready 40 && lib_service_active "$OLS_SERVICE"; then
    lib_ok "OpenLiteSpeed is back under systemd control"
  else
    lib_warn "OpenLiteSpeed did not re-attach cleanly; check: systemctl status lsws"
  fi
  return 0
}

# Wait until the service is active, is listening on port 80 and answers an HTTP request.
lib_ols_wait_ready() {
  local timeout="${1:-30}" i="" code=""
  (( OPT_DRY_RUN )) && return 0
  for (( i = 0; i < timeout; i++ )); do
    if lib_ols_running && lib_port_listening 80; then
      code="$(lib_http_code "http://127.0.0.1/" -H "Host: server-setup-probe.invalid")"
      [[ "$code" != "000" ]] && return 0
    fi
    sleep 1
  done
  lib_log_write ERROR "OpenLiteSpeed not ready after ${timeout}s (running=$(lib_ols_running && echo yes || echo no), port 80=$(lib_port_listening 80 && echo listening || echo closed), probe=${code:-none})"
  return 1
}

# lib_ols_smoke_test <host> <expected-code-regex> [https]  -> 0 on match
lib_ols_smoke_test() {
  local host="$1" expect="$2" scheme="${3:-http}" code="" i=""
  (( OPT_DRY_RUN )) && return 0
  for (( i = 0; i < 6; i++ )); do
    if [[ "$scheme" == "https" ]]; then
      code="$(lib_http_code "https://${host}/" -k --resolve "${host}:443:127.0.0.1")"
    else
      code="$(lib_http_code "http://127.0.0.1/" -H "Host: ${host}")"
    fi
    if [[ "$code" =~ ^(${expect})$ ]]; then lib_debug "smoke test ${scheme}://${host}/ -> ${code}"; return 0; fi
    sleep 2
  done
  lib_log_write ERROR "smoke test ${scheme}://${host}/ returned ${code:-?} (expected ${expect})"
  OLS_TEST_OUTPUT="HTTP ${code:-?} for ${scheme}://${host}/ (expected ${expect})"
  return 1
}

# Begin/commit a change set: snapshot -> (edits) -> test -> graceful reload -> verify,
# with automatic restore of the snapshot when anything fails.
lib_ols_change_begin() {
  OLS_PENDING_RELOAD=0
  OLS_SNAPSHOT=""
  (( OPT_DRY_RUN )) && return 0
  lib_ols_is_installed || return 0
  OLS_SNAPSHOT="$(lib_ols_snapshot_take)"
}

lib_ols_change_commit() {   # [description]
  local desc="${1:-OpenLiteSpeed configuration}"
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would test the configuration and gracefully reload OpenLiteSpeed (${desc})"; return 0; fi
  if (( ! OLS_PENDING_RELOAD )); then lib_debug "no OpenLiteSpeed changes to apply (${desc})"; OLS_SNAPSHOT=""; return 0; fi
  lib_info "Testing OpenLiteSpeed configuration..."
  if ! lib_ols_config_test; then
    lib_error "Configuration test failed: ${OLS_TEST_OUTPUT}"
    lib_ols_snapshot_restore "$OLS_SNAPSHOT" || true
    lib_die "OpenLiteSpeed configuration test failed (${desc})" \
      "the generated configuration was rejected by openlitespeed -t; previous configuration restored" \
      "inspect ${LOG_FILE} and ${LSWS_HOME}/logs/error.log, then re-run"
  fi
  if ! lib_ols_reload || ! lib_ols_wait_ready 40; then
    lib_error "OpenLiteSpeed did not come back after the reload"
    lib_ols_snapshot_restore "$OLS_SNAPSHOT" || true
    lib_ols_reload || true
    lib_ols_wait_ready 40 || lib_ols_restart || true
    lib_die "OpenLiteSpeed failed to reload (${desc})" \
      "service did not become healthy with the new configuration; previous configuration restored" \
      "systemctl status lsws; tail -n 50 ${LSWS_HOME}/logs/error.log"
  fi
  OLS_PENDING_RELOAD=0
  OLS_SNAPSHOT=""
  lib_ok "OpenLiteSpeed reloaded (${desc})"
}

lib_ols_change_abort() {
  lib_ols_tx_abort
  if [[ -n "$OLS_SNAPSHOT" && -f "$OLS_SNAPSHOT" ]]; then lib_ols_snapshot_restore "$OLS_SNAPSHOT" || true; fi
  OLS_SNAPSHOT=""; OLS_PENDING_RELOAD=0
  return 0
}

# =============================================================================
#  Templates
# =============================================================================
lib_ols_listener_address() { if (( SYS_IPV6 )); then printf '[ANY]'; else printf '*'; fi; }

lib_ols_render_extprocessor() {   # version children
  local ver="$1" children="$2" tag="lsphp${1//./}"
  cat <<EOF
extprocessor ${tag} {
  type                    lsapi
  address                 uds://tmp/lshttpd/${tag}.sock
  maxConns                ${children}
  env                     PHP_LSAPI_CHILDREN=${children}
  env                     LSAPI_AVOID_FORK=200M
  initTimeout             60
  retryTimeout            0
  persistConn             1
  pcKeepAliveTimeout      1
  respBuffer              0
  autoStart               1
  path                    ${LSWS_HOME}/lsphp${ver//./}/bin/lsphp
  backlog                 100
  instances               1
  priority                0
  memSoftLimit            2047M
  memHardLimit            2047M
  procSoftLimit           1400
  procHardLimit           1500
}
EOF
}

lib_ols_render_vhost_block() {   # domain enableScript
  local domain="$1" script="${2:-1}"
  cat <<EOF
virtualhost ${domain} {
  vhRoot                  $(lib_domain_home "$domain")/
  configFile              conf/vhosts/${domain}/vhconf.conf
  allowSymbolLink         1
  enableScript            ${script}
  restrained              1
  setUIDMode              2
}
EOF
}

lib_ols_render_default_vhost_block() {
  cat <<EOF
virtualhost ${OLS_DEFAULT_VHOST} {
  vhRoot                  ${OLS_DEFAULT_ROOT}/
  configFile              conf/vhosts/${OLS_DEFAULT_VHOST}/vhconf.conf
  allowSymbolLink         0
  enableScript            0
  restrained              1
  setUIDMode              0
}
EOF
}

lib_ols_render_default_vhconf() {
  cat <<EOF
# Managed by lompstack - catch-all vhost: unknown Host/SNI -> 403
docRoot                   \$VH_ROOT/html/
enableGzip                1

errorlog \$SERVER_ROOT/logs/_default.error.log {
  useServer               0
  logLevel                WARN
  rollingSize             10M
}

accesslog  {
  useServer               1
}

index  {
  useServer               0
  indexFiles              index.html
  autoIndex               0
}

context /.well-known/acme-challenge/ {
  location                ${ACME_ROOT}/.well-known/acme-challenge/
  allowBrowse             1
  addDefaultCharset       off
}

rewrite  {
  enable                  1
  autoLoadHtaccess        0
  logLevel                0
  rules                   <<<END_rules
RewriteCond %{REQUEST_URI} !^/\\.well-known/acme-challenge/
RewriteRule .* - [F,L]
  END_rules
}
EOF
}

lib_ols_render_vhssl() {   # keyfile certfile [stapling]
  local key="$1" cert="$2" stapling="${3:-1}"
  cat <<EOF
vhssl  {
  keyFile                 ${key}
  certFile                ${cert}
  certChain               1
  sslProtocol             24
  ciphers                 ${OLS_CIPHERS}
  enableECDHE             1
  renegProtection         1
  sslSessionCache         1
  sslSessionTickets       1
  enableSpdy              15
  enableQuic              1
  enableStapling          ${stapling}
  ocspRespMaxAge          86400
}
EOF
}

# Site vhconf.conf rendered from the D_* state variables (see lib/domain.sh).
lib_ols_render_vhconf() {
  local scheme="http" post_mb="" upload_mb="" php_bin="" children="" rules="" hsts="" esc=""
  (( D_SSL )) && scheme="https"
  esc="${D_DOMAIN//./\\.}"
  upload_mb="$(lib_size_to_mb "$D_UPLOAD")"
  post_mb=$(( upload_mb + 8 ))
  children="${D_PHP_CHILDREN:-$CALC_PHP_CHILDREN_SITE}"
  php_bin="${LSWS_HOME}/lsphp${D_PHP//./}/bin/lsphp"

  cat <<EOF
# Managed by lompstack for ${D_DOMAIN} - regenerated on every change; do not edit by hand.
docRoot                   \$VH_ROOT/public_html/
vhDomain                  ${D_DOMAIN}
EOF
  (( D_WWW )) && printf 'vhAliases                 www.%s\n' "$D_DOMAIN"
  [[ -n "$D_EMAIL" ]] && printf 'adminEmails               %s\n' "$D_EMAIL"
  cat <<EOF
enableGzip                1
enableIpGeo               0

errorlog \$VH_ROOT/logs/error.log {
  useServer               0
  logLevel                WARN
  rollingSize             0
}

accesslog \$VH_ROOT/logs/access.log {
  useServer               0
  logReferer              1
  logUserAgent            1
  rollingSize             0
  keepDays                0
  compressArchive         0
}

index  {
  useServer               0
  indexFiles              index.php, index.html, index.htm
  autoIndex               0
}
EOF

  # ---- PHP handler --------------------------------------------------------
  if [[ "$D_MODE" == "php" || "$D_MODE" == "wordpress" ]]; then
    cat <<EOF

scripthandler  {
  add                     lsapi:${D_IDENT} php
}

extprocessor ${D_IDENT} {
  type                    lsapi
  address                 UDS://tmp/lshttpd/${D_IDENT}.sock
  maxConns                ${children}
  env                     PHP_LSAPI_CHILDREN=${children}
  env                     LSAPI_AVOID_FORK=200M
  env                     PHP_LSAPI_MAX_REQUESTS=1000
  initTimeout             60
  retryTimeout            0
  persistConn             1
  pcKeepAliveTimeout      1
  respBuffer              0
  autoStart               1
  path                    ${php_bin}
  extUser                 ${D_USER}
  extGroup                ${D_GROUP}
  memSoftLimit            2047M
  memHardLimit            2047M
  procSoftLimit           400
  procHardLimit           500
}

phpIniOverride  {
  php_admin_value memory_limit ${D_MEMORY}
  php_admin_value upload_max_filesize ${D_UPLOAD}
  php_admin_value post_max_size ${post_mb}M
  php_admin_value session.save_path ${D_HOME}/private/sessions
  php_admin_value upload_tmp_dir ${D_HOME}/private/tmp
  php_admin_value sys_temp_dir ${D_HOME}/private/tmp
}
EOF
  fi

  # ---- reverse proxy ------------------------------------------------------
  if [[ "$D_MODE" == "proxy" ]]; then
    cat <<EOF

extprocessor ${D_IDENT}_proxy {
  type                    proxy
  address                 ${D_PROXY}
  maxConns                200
  pcKeepAliveTimeout      60
  initTimeout             60
  retryTimeout            0
  respBuffer              0
}
EOF
  fi

  # ---- rewrite rules ------------------------------------------------------
  rules+=$'# server-setup: never expose dotfiles (except ACME), VCS, env and dump files\n'
  rules+=$'RewriteRule ^/?\\.(?!well-known/) - [F,L]\n'
  rules+=$'RewriteRule (?i)\\.(sql|bak|env|log|swp|orig|old|inc|sh)$ - [F,L]\n'
  rules+=$'RewriteRule ^/?(wp-config\\.php|composer\\.(json|lock)|package(-lock)?\\.json|yarn\\.lock)$ - [F,L]\n'
  if (( D_WWW )); then
    if (( D_WWW_PRIMARY )); then
      rules+="RewriteCond %{HTTP_HOST} ^${esc}\$ [NC]"$'\n'
      rules+="RewriteRule ^(.*)\$ ${scheme}://www.${D_DOMAIN}\$1 [R=301,L]"$'\n'
    else
      rules+="RewriteCond %{HTTP_HOST} ^www\\.${esc}\$ [NC]"$'\n'
      rules+="RewriteRule ^(.*)\$ ${scheme}://${D_DOMAIN}\$1 [R=301,L]"$'\n'
    fi
  fi
  if (( D_SSL )); then
    rules+=$'RewriteCond %{HTTPS} !on\n'
    rules+=$'RewriteCond %{HTTP:X-Forwarded-Proto} !https\n'
    rules+=$'RewriteCond %{REQUEST_URI} !^/\\.well-known/acme-challenge/\n'
    rules+=$'RewriteRule ^(.*)$ https://%{HTTP_HOST}$1 [R=301,L]\n'
  fi
  local autoload=0
  [[ "$D_MODE" == "php" || "$D_MODE" == "wordpress" ]] && autoload=1
  cat <<EOF

rewrite  {
  enable                  1
  autoLoadHtaccess        ${autoload}
  logLevel                0
  rules                   <<<END_rules
${rules}  END_rules
}
EOF

  # ---- contexts -----------------------------------------------------------
  if (( D_SSL )); then
    hsts="Strict-Transport-Security: max-age=31536000; includeSubDomains"
    (( D_HSTS_PRELOAD )) && hsts+="; preload"
  fi
  cat <<EOF

context /.well-known/acme-challenge/ {
  location                ${ACME_ROOT}/.well-known/acme-challenge/
  allowBrowse             1
  addDefaultCharset       off
}
EOF
  if [[ "$D_MODE" == "proxy" ]]; then
    local p=""
    for p in ${D_STATIC_PATHS//,/ }; do
      [[ "$p" == /*/ ]] || continue
      cat <<EOF

context ${p} {
  location                \$VH_ROOT/public_html${p}
  allowBrowse             1
  addDefaultCharset       off
}
EOF
    done
    cat <<EOF

context / {
  type                    proxy
  handler                 ${D_IDENT}_proxy
  addDefaultCharset       off
  extraHeaders            <<<END_extraHeaders
X-Content-Type-Options: nosniff
Referrer-Policy: strict-origin-when-cross-origin
${hsts:+${hsts}
}  END_extraHeaders
}
EOF
    if [[ -n "${D_WS_PATH:-}" ]]; then
      cat <<EOF

websocket ${D_WS_PATH} {
  address                 ${D_PROXY}
}
EOF
    fi
  else
    cat <<EOF

context / {
  location                \$VH_ROOT/public_html/
  allowBrowse             1
  addDefaultCharset       off
  extraHeaders            <<<END_extraHeaders
X-Content-Type-Options: nosniff
Referrer-Policy: strict-origin-when-cross-origin
${hsts:+${hsts}
}  END_extraHeaders

  rewrite  {
    enable                1
    inherit               1
  }
}
EOF
  fi

  # ---- LiteSpeed cache for WordPress ------------------------------------------
  if [[ "$D_MODE" == "wordpress" ]]; then
    cat <<EOF

module cache {
  storagePath             ${OLS_CACHE_DIR}/\$VH_NAME
}
EOF
  fi

  # ---- SSL ----------------------------------------------------------------
  if (( D_SSL )); then
    printf '\n'
    lib_ols_render_vhssl "${SSL_DEPLOY_DIR}/${D_DOMAIN}/privkey.pem" "${SSL_DEPLOY_DIR}/${D_DOMAIN}/fullchain.pem" 1
  fi
}

# "64M" / "1G" / "512" -> MB
lib_size_to_mb() {
  local v="${1^^}"
  case "$v" in
    *G) printf '%d' $(( ${v%G} * 1024 )) ;;
    *M) printf '%d' "${v%M}" ;;
    *K) printf '%d' $(( ${v%K} / 1024 )) ;;
    *)  printf '%d' "${v:-0}" ;;
  esac
}

# =============================================================================
#  Server-level configuration (idempotent)
# =============================================================================
lib_ols_default_cert_ensure() {
  local dir="${SSL_DEPLOY_DIR}/${OLS_DEFAULT_VHOST}"
  if [[ -s "${dir}/privkey.pem" && -s "${dir}/fullchain.pem" ]]; then lib_debug "default certificate present"; return 0; fi
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would generate a self-signed default certificate in ${dir}"; return 0; fi
  lib_mkdir "$SSL_DEPLOY_DIR" 0700 root:root
  lib_mkdir "$dir" 0700 root:root
  lib_run openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
    -subj "/CN=default.invalid/O=server-setup" -keyout "${dir}/privkey.pem" -out "${dir}/fullchain.pem" \
    || lib_die "Could not create the default self-signed certificate" "openssl failed" "check openssl installation"
  chmod 0600 "${dir}/privkey.pem" "${dir}/fullchain.pem"
  lib_ok "Default self-signed certificate created (used for unknown SNI)"
}

# Ensure the two listeners exist with the right settings (maps are preserved).
_ols_tx_listeners_ensure() {
  local addr=""; addr="$(lib_ols_listener_address)"
  local keydir="${SSL_DEPLOY_DIR}/${OLS_DEFAULT_VHOST}"
  if ! lib_ols_tx_block_exists listener "$OLS_LISTENER_HTTP"; then
    lib_ols_tx_block_put listener "$OLS_LISTENER_HTTP" <<EOF
listener ${OLS_LISTENER_HTTP} {
  address                 ${addr}:80
  secure                  0
  map                     ${OLS_DEFAULT_VHOST} *
}
EOF
  fi
  lib_ols_tx_block_set listener "$OLS_LISTENER_HTTP" address "${addr}:80"
  lib_ols_tx_block_set listener "$OLS_LISTENER_HTTP" secure 0
  lib_ols_tx_map_set "$OLS_LISTENER_HTTP" "$OLS_DEFAULT_VHOST" "*"

  if ! lib_ols_tx_block_exists listener "$OLS_LISTENER_HTTPS"; then
    lib_ols_tx_block_put listener "$OLS_LISTENER_HTTPS" <<EOF
listener ${OLS_LISTENER_HTTPS} {
  address                 ${addr}:443
  secure                  1
  map                     ${OLS_DEFAULT_VHOST} *
}
EOF
  fi
  lib_ols_tx_block_set listener "$OLS_LISTENER_HTTPS" address "${addr}:443"
  lib_ols_tx_block_set listener "$OLS_LISTENER_HTTPS" secure 1
  lib_ols_tx_block_set listener "$OLS_LISTENER_HTTPS" keyFile "${keydir}/privkey.pem"
  lib_ols_tx_block_set listener "$OLS_LISTENER_HTTPS" certFile "${keydir}/fullchain.pem"
  lib_ols_tx_block_set listener "$OLS_LISTENER_HTTPS" certChain 1
  lib_ols_tx_block_set listener "$OLS_LISTENER_HTTPS" sslProtocol 24
  lib_ols_tx_block_set listener "$OLS_LISTENER_HTTPS" ciphers "$OLS_CIPHERS"
  lib_ols_tx_block_set listener "$OLS_LISTENER_HTTPS" enableECDHE 1
  lib_ols_tx_block_set listener "$OLS_LISTENER_HTTPS" renegProtection 1
  lib_ols_tx_block_set listener "$OLS_LISTENER_HTTPS" sslSessionCache 1
  lib_ols_tx_block_set listener "$OLS_LISTENER_HTTPS" sslSessionTickets 1
  lib_ols_tx_block_set listener "$OLS_LISTENER_HTTPS" enableSpdy 15
  lib_ols_tx_block_set listener "$OLS_LISTENER_HTTPS" enableQuic 1
  lib_ols_tx_block_set listener "$OLS_LISTENER_HTTPS" enableStapling 0
  lib_ols_tx_map_set "$OLS_LISTENER_HTTPS" "$OLS_DEFAULT_VHOST" "*"
}

# Re-assert listener maps for every registered domain (state -> config).
_ols_tx_domain_maps_ensure() {
  local d="" www=""
  while read -r d; do
    [[ -n "$d" ]] || continue
    www="$(lib_json_get "$(lib_domain_json "$d")" '.www')"
    if [[ "$www" == "true" ]]; then
      lib_ols_tx_map_set "$OLS_LISTENER_HTTP"  "$d" "${d}, www.${d}"
      lib_ols_tx_map_set "$OLS_LISTENER_HTTPS" "$d" "${d}, www.${d}"
    else
      lib_ols_tx_map_set "$OLS_LISTENER_HTTP"  "$d" "$d"
      lib_ols_tx_map_set "$OLS_LISTENER_HTTPS" "$d" "$d"
    fi
  done < <(lib_domains_list)
}

# Apply tuning + structure to the transaction (used by install and optimize).
lib_ols_tx_apply_server_settings() {
  local ver="" php_bin=""
  lib_ols_tx_top_set showVersionNumber 0
  lib_ols_tx_top_set adminEmails "${DEFAULT_EMAIL:-root@localhost}"
  lib_ols_tx_top_set httpdWorkers "$CALC_OLS_WORKERS"
  lib_ols_tx_top_set autoFix503 1
  lib_ols_tx_top_set gracefulRestartTimeout 300
  lib_ols_tx_top_set indexFiles "index.html, index.php"
  [[ -n "$(lib_ols_tx_top_get useIpInProxyHeader)" ]] || lib_ols_tx_top_set useIpInProxyHeader 0

  if ! lib_ols_tx_block_exists tuning ""; then lib_ols_tx_block_put tuning "" <<<$'tuning  {\n}'; fi
  lib_ols_tx_block_set tuning "" maxConnections "$CALC_OLS_MAX_CONN"
  lib_ols_tx_block_set tuning "" maxSSLConnections "$CALC_OLS_MAX_CONN"
  lib_ols_tx_block_set tuning "" connTimeout 300
  lib_ols_tx_block_set tuning "" maxKeepAliveReq 10000
  lib_ols_tx_block_set tuning "" smartKeepAlive 0
  lib_ols_tx_block_set tuning "" keepAliveTimeout 5
  lib_ols_tx_block_set tuning "" totalInMemCacheSize "${CALC_OLS_INMEM_MB}M"
  lib_ols_tx_block_set tuning "" totalMMapCacheSize "${CALC_OLS_MMAP_MB}M"
  lib_ols_tx_block_set tuning "" maxCachedFileSize 4096
  lib_ols_tx_block_set tuning "" useSendfile 1
  lib_ols_tx_block_set tuning "" maxReqBodySize 2047M
  lib_ols_tx_block_set tuning "" enableGzipCompress 1
  lib_ols_tx_block_set tuning "" enableDynGzipCompress 1
  lib_ols_tx_block_set tuning "" gzipCompressLevel 6
  lib_ols_tx_block_set tuning "" gzipAutoUpdateStatic 1
  lib_ols_tx_block_set tuning "" gzipMaxFileSize 10M
  lib_ols_tx_block_set tuning "" gzipMinFileSize 300
  lib_ols_tx_block_set tuning "" quicEnable 1
  lib_ols_tx_block_set tuning "" quicShmDir /dev/shm

  if ! lib_ols_tx_block_exists accessControl ""; then
    lib_ols_tx_block_put accessControl "" <<<$'accessControl  {\n  allow                   ALL\n}'
  fi
  if ! lib_ols_tx_block_exists perClientConnLimit ""; then
    lib_ols_tx_block_put perClientConnLimit "" <<EOF
perClientConnLimit  {
  staticReqPerSec         0
  dynReqPerSec            0
  outBandwidth            0
  inBandwidth             0
  softLimit               10000
  hardLimit               10000
  gracePeriod             15
  banPeriod               300
}
EOF
  fi

  # stock example vhost / listener (port 8088) are removed
  if lib_ols_tx_block_exists listener Default; then
    if [[ "$(lib_ols_tx_block_get listener Default address)" == *:8088 ]]; then lib_ols_tx_block_remove listener Default; fi
  fi
  lib_ols_tx_block_exists virtualhost Example && lib_ols_tx_block_remove virtualhost Example

  # catch-all vhost + listeners
  lib_ols_render_default_vhost_block | lib_ols_tx_block_put virtualhost "$OLS_DEFAULT_VHOST"
  _ols_tx_listeners_ensure
  _ols_tx_domain_maps_ensure

  # one server-level LSAPI processor per installed PHP version
  for ver in $(lib_php_installed_versions); do
    lib_ols_render_extprocessor "$ver" "$CALC_PHP_CHILDREN_TOTAL" | lib_ols_tx_block_put extprocessor "lsphp${ver//./}"
  done
  php_bin="${LSWS_HOME}/lsphp${PHP_VERSION//./}/bin/lsphp"
  if lib_ols_tx_block_exists extprocessor lsphp && [[ -x "$php_bin" ]]; then
    lib_ols_tx_block_set extprocessor lsphp path "$php_bin"
    lib_ols_tx_block_set extprocessor lsphp env "PHP_LSAPI_CHILDREN=${CALC_PHP_CHILDREN_TOTAL}"
  fi
  if ! lib_ols_tx_block_exists scripthandler ""; then
    lib_ols_tx_block_put scripthandler "" <<<$'scripthandler  {\n  add                     lsapi:lsphp php\n}'
  fi
  return 0
}

# Full server configuration: files + transaction + test + reload.
lib_ols_configure_server() {
  lib_system_profile
  if (( OPT_DRY_RUN )) && ! lib_ols_is_installed; then
    lib_info "[dry-run] OpenLiteSpeed is not installed yet; server configuration would be generated after installation"
    return 0
  fi
  lib_ols_service_repair
  lib_ols_acme_root_ensure
  lib_ols_default_cert_ensure
  # e.g. the WebAdmin port was just changed by lib_ols_admin_setup
  local pending="$OLS_PENDING_RELOAD"
  lib_ols_change_begin
  (( pending )) && OLS_PENDING_RELOAD=1
  lib_mkdir "${LSWS_VHOSTS_DIR}/${OLS_DEFAULT_VHOST}" 0750 lsadm:lsadm
  lib_ols_render_default_vhconf | lib_write_file "${LSWS_VHOSTS_DIR}/${OLS_DEFAULT_VHOST}/vhconf.conf" 0640 lsadm:lsadm
  (( LIB_FILE_CHANGED )) && OLS_PENDING_RELOAD=1
  lib_ols_tx_begin
  lib_ols_tx_apply_server_settings
  if [[ "$(lib_manifest_get '.cloudflare.enabled')" == "true" ]]; then lib_cf_tx_apply 1; fi
  lib_ols_tx_commit
  if (( OLS_PENDING_RELOAD )); then
    lib_ols_change_commit "server configuration"
  else
    lib_ok "OpenLiteSpeed server configuration already up to date"
  fi
  if (( ! OPT_DRY_RUN )); then
    lib_ols_running || { lib_ols_restart; lib_ols_wait_ready 40 || lib_die "OpenLiteSpeed is not running" "service failed to start" "journalctl -u lsws"; }
    lib_ols_smoke_test "server-setup-probe.invalid" "403" || lib_warn "catch-all vhost did not answer 403 (${OLS_TEST_OUTPUT})"
  fi
}

# Address the WebAdmin listener should bind to, derived from ADMIN_ACCESS.
lib_ols_admin_address() {
  case "${ADMIN_ACCESS:-tunnel}" in
    tunnel) printf '127.0.0.1' ;;
    *)      lib_ols_listener_address ;;
  esac
}

lib_ols_admin_current_bind() {
  [[ -f "$LSWS_ADMIN_CONF" ]] || { printf ''; return 0; }
  _ols_block_key "$LSWS_ADMIN_CONF" listener adminListener address get 2>/dev/null || true
}

lib_ols_admin_tunnel_only() { [[ "$(lib_ols_admin_current_bind)" == 127.0.0.1:* ]]; }

# Bind the WebAdmin listener to an address ("127.0.0.1", "*" or "[ANY]").
lib_ols_admin_bind() {
  local addr="$1" tmp=""
  [[ -f "$LSWS_ADMIN_CONF" ]] || return 0
  tmp="$(lib_mktemp)"
  sed -E "s|^([[:space:]]*address[[:space:]]+)[^[:space:]]*:[0-9]+[[:space:]]*$|\1${addr}:${ADMIN_PORT}|" "$LSWS_ADMIN_CONF" >"$tmp"
  lib_write_file "$LSWS_ADMIN_CONF" 0640 lsadm:lsadm <"$tmp"
  rm -f "$tmp"
  (( LIB_FILE_CHANGED )) && OLS_PENDING_RELOAD=1
  return 0
}

# WebAdmin: random password (once) and listener binding.
lib_ols_admin_setup() {
  local info="${STATE_DIR}/openlitespeed-admin.info" pass="" hash="" addr=""
  if [[ -s "$info" ]]; then
    lib_ok "WebAdmin credentials already stored (${info})"
  elif (( OPT_DRY_RUN )); then
    lib_info "[dry-run] would generate the WebAdmin password and store it in ${info}"
  else
    pass="$(lib_random_password 24)"
    hash="$("${LSWS_HOME}/admin/fcgi-bin/admin_php" -q "${LSWS_HOME}/admin/misc/htpasswd.php" "$pass" 2>/dev/null)" \
      || lib_die "Could not hash the WebAdmin password" "admin_php/htpasswd.php failed" "check the OpenLiteSpeed installation"
    [[ -n "$hash" ]] || lib_die "Empty WebAdmin password hash" "htpasswd.php produced no output" "check the OpenLiteSpeed installation"
    printf 'admin:%s\n' "$hash" >"${LSWS_HOME}/admin/conf/htpasswd"
    chown lsadm:lsadm "${LSWS_HOME}/admin/conf/htpasswd" && chmod 0600 "${LSWS_HOME}/admin/conf/htpasswd"
    mkdir -p "$STATE_DIR" && chmod 0700 "$STATE_DIR"
    printf '# OpenLiteSpeed WebAdmin credentials - generated %s\nUSER=admin\nPASSWORD=%s\n' "$(lib_iso_now)" "$pass" >"$info"
    chmod 0600 "$info"
    lib_ok "WebAdmin password generated and stored in ${info}"
  fi
  if [[ -f "$LSWS_ADMIN_CONF" ]]; then
    addr="$(lib_ols_admin_address)"
    lib_ols_admin_bind "$addr"
    if (( LIB_FILE_CHANGED )); then
      case "${ADMIN_ACCESS:-tunnel}" in
        tunnel) lib_ok "WebAdmin bound to 127.0.0.1:${ADMIN_PORT} (reachable through an SSH tunnel only)" ;;
        *)      lib_ok "WebAdmin listener set to ${addr}:${ADMIN_PORT}" ;;
      esac
    fi
  fi
  return 0
}

lib_ols_admin_url() {
  local secure="" host=""
  secure="$(_ols_block_key "$LSWS_ADMIN_CONF" listener adminListener secure get 2>/dev/null || true)"
  if lib_ols_admin_tunnel_only; then host="127.0.0.1"; else host="${SYS_PUBLIC_IPV4:-$(lib_primary_ipv4)}"; fi
  if [[ "$secure" == "0" ]]; then printf 'http://%s:%s' "$host" "$ADMIN_PORT"; else printf 'https://%s:%s' "$host" "$ADMIN_PORT"; fi
}

# Ready-to-paste tunnel command for the administrator's workstation.
lib_ols_admin_tunnel_cmd() {
  local port="" user="" ip=""
  port="$(printf '%s' "${SYS_SSH_PORTS:-22}" | awk '{print $1}')"
  user="${SUDO_USER:-root}"
  ip="${SYS_PUBLIC_IPV4:-$(lib_primary_ipv4)}"
  printf 'ssh -N -L %s:127.0.0.1:%s%s %s@%s' "$ADMIN_PORT" "$ADMIN_PORT" \
    "$( [[ "$port" != "22" ]] && printf ' -p %s' "$port")" "$user" "${ip:-<server-ip>}"
}

# =============================================================================
#  Domain-level helpers used by lib/domain.sh (inside a change set)
# =============================================================================
lib_ols_vhconf_write() {   # domain  (uses D_* state)
  local dir="${LSWS_VHOSTS_DIR}/${1}"
  lib_mkdir "$dir" 0750 lsadm:lsadm
  lib_ols_render_vhconf | lib_write_file "${dir}/vhconf.conf" 0640 lsadm:lsadm
  (( LIB_FILE_CHANGED )) && OLS_PENDING_RELOAD=1
  return 0
}

lib_ols_tx_vhost_add() {   # domain www(0/1) enableScript(0/1)
  local domain="$1" www="$2" script="$3"
  local maps="$domain"
  (( www )) && maps="${domain}, www.${domain}"
  lib_ols_render_vhost_block "$domain" "$script" | lib_ols_tx_block_put virtualhost "$domain"
  lib_ols_tx_map_set "$OLS_LISTENER_HTTP"  "$domain" "$maps"
  lib_ols_tx_map_set "$OLS_LISTENER_HTTPS" "$domain" "$maps"
}

lib_ols_tx_vhost_remove() {   # domain
  local domain="$1"
  lib_ols_tx_map_del "$OLS_LISTENER_HTTP"  "$domain"
  lib_ols_tx_map_del "$OLS_LISTENER_HTTPS" "$domain"
  lib_ols_tx_block_exists virtualhost "$domain" && lib_ols_tx_block_remove virtualhost "$domain"
  return 0
}

# Remove vhost from config + archive its vhconf. Used by remove and by add-rollback.
lib_ols_vhost_purge() {   # domain [archive=1]
  local domain="$1" archive="${2:-1}" dir="${LSWS_VHOSTS_DIR}/${1}"
  lib_ols_is_installed || return 0
  lib_ols_change_begin
  lib_ols_tx_begin
  lib_ols_tx_vhost_remove "$domain"
  lib_ols_tx_commit
  if [[ -d "$dir" ]]; then
    if (( archive )) && (( ! OPT_DRY_RUN )); then
      mkdir -p "${STATE_DIR}/archive/vhosts" && chmod 0700 "${STATE_DIR}/archive/vhosts"
      cp -a "$dir" "${STATE_DIR}/archive/vhosts/${domain}.$(lib_ts)" 2>/dev/null || true
    fi
    lib_rm "$dir"
    OLS_PENDING_RELOAD=1
  fi
  lib_ols_change_commit "remove vhost ${domain}"
}
