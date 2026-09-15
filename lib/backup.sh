#!/usr/bin/env bash
# lib/backup.sh - per-site backups (files + DB + vhost + state), retention,
#                 encryption, rsync/rclone remotes, scheduling and restore.

BACKUP_REMOTE_CONF="${STATE_DIR}/backup-remote.conf"
BACKUP_KEY_FILE="${STATE_DIR}/backup.key"
BK_LAST_FILE=""
BK_ERROR=""

# =============================================================================
#  helpers
# =============================================================================
lib_backup_key_ensure() {
  [[ -s "$BACKUP_KEY_FILE" ]] && return 0
  (( OPT_DRY_RUN )) && { lib_info "[dry-run] would generate ${BACKUP_KEY_FILE}"; return 0; }
  mkdir -p "$STATE_DIR" && chmod 0700 "$STATE_DIR"
  lib_random_password 48 >"$BACKUP_KEY_FILE"
  chmod 0600 "$BACKUP_KEY_FILE"
  lib_warn "A new backup encryption key was generated: ${BACKUP_KEY_FILE}"
  lib_warn "COPY THIS KEY OFF THE SERVER NOW. Encrypted backups cannot be restored without it and it is NOT included in any backup."
}

lib_backup_remote_load() {   # -> BKR_TYPE BKR_TARGET ; returns 1 when not configured
  BKR_TYPE=""; BKR_TARGET=""
  [[ -s "$BACKUP_REMOTE_CONF" ]] || return 1
  BKR_TYPE="$(awk -F= '$1=="TYPE"{print $2; exit}' "$BACKUP_REMOTE_CONF")"
  BKR_TARGET="$(awk -F= '$1=="TARGET"{sub(/^[^=]*=/,""); print; exit}' "$BACKUP_REMOTE_CONF")"
  [[ -n "$BKR_TYPE" && -n "$BKR_TARGET" ]]
}

lib_backup_remote_send() {   # file [file...]
  lib_backup_remote_load || { BK_ERROR="remote backup not configured (backup --configure-remote)"; return 1; }
  (( OPT_DRY_RUN )) && { lib_info "[dry-run] would upload $* via ${BKR_TYPE} to ${BKR_TARGET}"; return 0; }
  case "$BKR_TYPE" in
    rsync)
      lib_run rsync -az --partial -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new" "$@" "${BKR_TARGET%/}/" || { BK_ERROR="rsync upload failed"; return 1; } ;;
    rclone)
      local f=""
      for f in "$@"; do lib_run rclone copy --no-traverse "$f" "$BKR_TARGET" || { BK_ERROR="rclone upload failed"; return 1; }; done ;;
    *) BK_ERROR="unknown remote type ${BKR_TYPE}"; return 1 ;;
  esac
  lib_ok "Uploaded to ${BKR_TYPE}:${BKR_TARGET}"
}

lib_backup_configure_remote() {   # [--type rsync|rclone --target X]
  local type="" target="" a=""
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --type)   type="${1:-}"; shift ;;
      --target) target="${1:-}"; shift ;;
      *) lib_die "Unknown option: ${a}" "" "backup --configure-remote [--type rsync|rclone --target <dest>]" ;;
    esac
  done
  if [[ -z "$type" ]]; then lib_prompt type "Remote type (rsync = SSH host, rclone = S3/B2/...)" "rsync"; fi
  [[ "$type" == "rsync" || "$type" == "rclone" ]] || lib_die "Invalid remote type '${type}'" "" "--type rsync | --type rclone"
  if [[ -z "$target" ]]; then
    if [[ "$type" == "rsync" ]]; then lib_prompt target "rsync target (user@host:/path/to/backups)" ""
    else lib_prompt target "rclone target (remote:bucket/path)" ""; fi
  fi
  [[ -n "$target" ]] || lib_die "Remote target missing" "" "provide --target"
  if [[ "$type" == "rclone" ]]; then
    lib_apt_install rclone || lib_die "rclone installation failed" "" "apt-get install rclone"
    local remote="${target%%:*}"
    if (( ! OPT_DRY_RUN )) && ! rclone listremotes 2>/dev/null | grep -qx "${remote}:"; then
      lib_warn "rclone remote '${remote}' is not configured yet."
      if lib_is_interactive; then rclone config; else lib_die "rclone remote '${remote}' missing" "run 'rclone config' first" "rclone config"; fi
    fi
    [[ -f /root/.config/rclone/rclone.conf ]] && chmod 0600 /root/.config/rclone/rclone.conf
    (( OPT_DRY_RUN )) || lib_run rclone lsd "$target" || lib_run rclone mkdir "$target" || lib_die "Cannot access ${target}" "rclone error" "check credentials with: rclone lsd ${target}"
  else
    lib_apt_install rsync
    (( OPT_DRY_RUN )) || lib_run rsync --dry-run -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new" /etc/hostname "${target%/}/" \
      || lib_die "Cannot reach ${target} over SSH" "key-based SSH login required (BatchMode)" "install your public key on the remote host and retry"
  fi
  printf '# Managed by lompstack - remote backup destination\nTYPE=%s\nTARGET=%s\n' "$type" "$target" | lib_write_file "$BACKUP_REMOTE_CONF" 0600 root:root
  lib_manifest_set_json '.backup.remote' true
  lib_manifest_set '.backup.remote_type' "$type"
  lib_ok "Remote backup destination saved: ${type} ${target}"
}

# Keep the newest N untagged archives of a domain.
lib_backup_prune() {   # domain keep
  local domain="$1" keep="$2" dir="${BACKUP_ROOT}/${1}" f=""
  (( keep > 0 )) || return 0
  [[ -d "$dir" ]] || return 0
  find "$dir" -maxdepth 1 -type f -regextype posix-extended -regex ".*/${domain//./\\.}-[0-9]{8}-[0-9]{6}\.tar\.gz(\.enc)?" -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | awk -v k="$keep" 'NR>k{print $2}' | while read -r f; do
      [[ -n "$f" ]] || continue
      if (( OPT_DRY_RUN )); then lib_info "[dry-run] would prune ${f}"; else rm -f "$f" "${f}.sha256"; lib_log_write INFO "pruned ${f}"; fi
    done || true
  return 0
}

lib_backup_verify() {   # archive -> 0 ok  (checks sha256 sidecar + tar listing when not encrypted)
  local f="$1"
  if [[ -s "${f}.sha256" ]]; then
    ( cd "$(dirname "$f")" && sha256sum -c --quiet "$(basename "$f").sha256" >/dev/null 2>&1 ) || { BK_ERROR="sha256 mismatch for ${f}"; return 1; }
  fi
  if [[ "$f" != *.enc ]]; then tar -tzf "$f" >/dev/null 2>&1 || { BK_ERROR="archive is not a valid tar.gz: ${f}"; return 1; }; fi
  return 0
}

# =============================================================================
#  backup one domain  (never dies: returns 1 and sets BK_ERROR)
# =============================================================================
lib_backup_domain() {   # domain [--keep N] [--encrypt] [--remote] [--tag T]
  local domain="$1"; shift
  local keep="$BACKUP_KEEP" encrypt=0 remote=0 tag="" a="" work="" name="" ts="" dest="" final="" dbfile="" parts=() vh=""
  BK_ERROR=""; BK_LAST_FILE=""
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --keep)    keep="${1:-7}"; shift ;;
      --encrypt) encrypt=1 ;;
      --remote)  remote=1 ;;
      --tag)     tag="${1:-}"; shift ;;
      *) BK_ERROR="unknown backup option ${a}"; return 1 ;;
    esac
  done
  [[ "$keep" =~ ^[0-9]+$ ]] || { BK_ERROR="--keep must be a number"; return 1; }
  lib_domain_state_load "$domain" || { BK_ERROR="site ${domain} is not registered"; return 1; }
  ts="$(lib_ts)"
  name="${domain}-${tag:+${tag}-}${ts}"
  dest="${BACKUP_ROOT}/${domain}"
  if (( OPT_DRY_RUN )); then
    lib_info "[dry-run] would create ${dest}/${name}.tar.gz$( (( encrypt )) && printf '.enc') (files: public_html, private$( [[ -d "${D_HOME}/app" ]] && printf ', app without node_modules'); db: ${D_DB_NAME:-none}; vhost; state)$( (( remote )) && printf ' and upload it')"
    return 0
  fi
  (( encrypt )) && lib_backup_key_ensure
  mkdir -p "$BACKUP_ROOT" "$dest" "${BACKUP_ROOT}/.work" && chmod 0700 "$BACKUP_ROOT" "$dest" "${BACKUP_ROOT}/.work"
  work="$(mktemp -d "${BACKUP_ROOT}/.work/${domain}.XXXXXX")" || { BK_ERROR="cannot create work dir"; return 1; }
  lib_info "Backing up ${domain} -> ${dest}/${name}.tar.gz"

  # ---- files ---------------------------------------------------------------
  local -a dirs=()
  [[ -d "${D_HOME}/public_html" ]] && dirs+=(public_html)
  [[ -d "${D_HOME}/private" ]] && dirs+=(private)
  # a Node.js application's code; its dependencies are reinstalled when it is restored
  [[ -d "${D_HOME}/app" ]] && dirs+=(app)
  # the site's deploy key, so a restored site can pull its private repository again
  [[ -d "${D_HOME}/.ssh" ]] && dirs+=(.ssh)
  if ((${#dirs[@]} > 0)); then
    if ! tar -C "$D_HOME" --exclude='private/sessions' --exclude='private/tmp' --exclude='private/.wp-cli' \
          --exclude='public_html/wp-content/cache' --exclude='app/node_modules' --exclude='app/*/node_modules' \
          --warning=no-file-changed -czf "${work}/files.tar.gz" "${dirs[@]}" 2>>"$LOG_FILE"; then
      if [[ ! -s "${work}/files.tar.gz" ]]; then BK_ERROR="file archive failed"; rm -rf "$work"; lib_backup_failed "$domain"; return 1; fi
    fi
    parts+=("files.tar.gz")
  fi
  # ---- database -----------------------------------------------------------
  if lib_db_info_load "$domain"; then
    dbfile="${work}/db-${DBI_NAME}.sql.gz"
    if ! lib_db_dump_domain "$domain" "$dbfile"; then BK_ERROR="database dump failed (${DBI_NAME})"; rm -rf "$work"; lib_backup_failed "$domain"; return 1; fi
    parts+=("$(basename "$dbfile")")
  fi
  # ---- vhost + state -------------------------------------------------------
  mkdir -p "${work}/conf" "${work}/state"
  vh="${LSWS_VHOSTS_DIR}/${domain}/vhconf.conf"
  [[ -f "$vh" ]] && cp "$vh" "${work}/conf/vhconf.conf" && parts+=("conf/vhconf.conf")
  for a in domain.json db.info wp.info ssl.info app-env.json; do
    [[ -f "$(lib_domain_state_dir "$domain")/${a}" ]] && cp "$(lib_domain_state_dir "$domain")/${a}" "${work}/state/${a}" && parts+=("state/${a}")
  done
  # ---- manifest + checksums ------------------------------------------------
  ( cd "$work" && sha256sum "${parts[@]}" >SHA256SUMS ) || { BK_ERROR="checksum generation failed"; rm -rf "$work"; lib_backup_failed "$domain"; return 1; }
  jq -n --arg d "$domain" --arg ts "$(lib_iso_now)" --arg tag "$tag" --arg host "$(hostname -f 2>/dev/null || hostname)" \
        --arg ver "$SCRIPT_VERSION" --arg db "${DBI_NAME:-}" --arg mode "$D_MODE" --arg php "$D_PHP" --arg home "$D_HOME" \
        --argjson parts "$(printf '%s\n' "${parts[@]}" | jq -R . | jq -s .)" \
        '{format:1, domain:$d, created_at:$ts, tag:$tag, host:$host, script_version:$ver, mode:$mode, php:$php, home:$home,
          database:(if $db=="" then null else $db end), parts:$parts}' >"${work}/manifest.json"
  # ---- final archive -------------------------------------------------------
  final="${dest}/${name}.tar.gz"
  if ! tar -C "$work" -czf "$final" . 2>>"$LOG_FILE"; then BK_ERROR="final archive failed"; rm -rf "$work" "$final"; lib_backup_failed "$domain"; return 1; fi
  rm -rf "$work"
  chmod 0600 "$final"
  if (( encrypt )); then
    if ! openssl enc -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 -salt -in "$final" -out "${final}.enc" -pass "file:${BACKUP_KEY_FILE}" 2>>"$LOG_FILE"; then
      BK_ERROR="encryption failed"; rm -f "$final" "${final}.enc"; lib_backup_failed "$domain"; return 1
    fi
    rm -f "$final"; final="${final}.enc"; chmod 0600 "$final"
  fi
  ( cd "$dest" && sha256sum "$(basename "$final")" >"$(basename "$final").sha256" ) || true
  BK_LAST_FILE="$final"
  lib_json_set "$(lib_domain_json "$domain")" '.backup.last = $ts | .backup.last_file = $f' --arg ts "$(lib_iso_now)" --arg f "$final"
  lib_log_write INFO "backup created: ${final} ($(du -h "$final" | cut -f1))"
  lib_ok "Backup created: ${final} ($(du -h "$final" | cut -f1))$( (( encrypt )) && printf ' [encrypted]')"
  lib_backup_prune "$domain" "$keep"
  if (( remote )); then
    lib_backup_remote_send "$final" "${final}.sha256" || { lib_backup_failed "$domain"; return 1; }
  fi
  return 0
}

lib_backup_failed() {
  lib_error "Backup of ${1} failed: ${BK_ERROR}"
  lib_notify_send "Backup FAILED for ${1} on $(hostname)" "Reason: ${BK_ERROR}. See ${LOG_FILE}." || true
}

# =============================================================================
#  backup command
# =============================================================================
lib_backup_main() {
  local domain="" all=0 remote=0 encrypt=0 keep="$BACKUP_KEEP" tag="" a=""
  local -a passthru=()
  [[ "${1:-}" == "--configure-remote" ]] && { shift; lib_require_tools; lib_backup_configure_remote "$@"; return 0; }
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --all)     all=1 ;;
      --remote)  remote=1; passthru+=(--remote) ;;
      --encrypt) encrypt=1; passthru+=(--encrypt) ;;
      --keep)    keep="${1:-7}"; passthru+=(--keep "$keep"); shift ;;
      --tag)     tag="${1:-}"; passthru+=(--tag "$tag"); shift ;;
      -*)        lib_die "Unknown option for backup: ${a}" "" "backup <domain>|--all [--remote] [--encrypt] [--keep N] [--tag T]" ;;
      *)         domain="${a,,}" ;;
    esac
  done
  lib_require_tools
  lib_require_installed
  (( remote )) && ! lib_backup_remote_load && lib_die "Remote backup is not configured" "" "setup.sh backup --configure-remote"
  if (( all )); then
    local d="" failed=() n=0
    while read -r d; do
      [[ -n "$d" ]] || continue
      n=$((n + 1))
      if ! SERVER_SETUP_LOCKED=1 "$SCRIPT_PATH" backup "$d" --yes "${passthru[@]}" $( (( OPT_QUIET )) && printf -- '--quiet') $( (( OPT_DRY_RUN )) && printf -- '--dry-run'); then
        failed+=("$d")
      fi
    done < <(lib_domains_list)
    lib_manifest_set '.backup.last_run' "$(lib_iso_now)"
    (( n == 0 )) && { lib_info "No sites to back up"; return 0; }
    if ((${#failed[@]} > 0)); then
      lib_die "Backup failed for: ${failed[*]}" "see the errors above" "fix and re-run 'setup.sh backup --all'"
    fi
    lib_ok "All ${n} site(s) backed up"
    return 0
  fi
  [[ -n "$domain" ]] || lib_die "Usage: setup.sh backup <domain>|--all [options]" "" "setup.sh backup example.com"
  lib_domain_registered "$domain" || lib_die "Site ${domain} is not registered" "" "setup.sh list"
  lib_backup_domain "$domain" "${passthru[@]}" || lib_die "Backup failed for ${domain}" "$BK_ERROR" "check disk space, MariaDB and the log"
}

# =============================================================================
#  schedule
# =============================================================================
# lib_backup_schedule "daily 03:00" | "hourly" | "weekly sun 04:00" | "<5-field cron>"  [extra flags]
lib_backup_schedule() {
  local spec="$1" flags="${2:-}" cron="" hh="" mm="" dow=""
  case "$spec" in
    daily\ [0-9]*:[0-9]*)
      hh="${spec#daily }"; mm="${hh#*:}"; hh="${hh%%:*}"
      cron="${mm#0} ${hh#0} * * *"; cron="${cron/# /0 }" ;;
    hourly) cron="7 * * * *" ;;
    weekly\ *)
      dow="$(awk '{print tolower($2)}' <<<"$spec")"; hh="$(awk '{print $3}' <<<"$spec")"; mm="${hh#*:}"; hh="${hh%%:*}"
      case "$dow" in sun) dow=0 ;; mon) dow=1 ;; tue) dow=2 ;; wed) dow=3 ;; thu) dow=4 ;; fri) dow=5 ;; sat) dow=6 ;; *) dow=0 ;; esac
      cron="${mm#0} ${hh#0} * * ${dow}"; cron="${cron/# /0 }" ;;
    *)
      if [[ "$spec" =~ ^[0-9*/,-]+([[:space:]]+[0-9*/,a-zA-Z-]+){4}$ ]]; then cron="$spec"; fi ;;
  esac
  [[ -n "$cron" ]] || lib_die "Invalid backup schedule '${spec}'" "expected e.g. \"daily 03:00\", \"hourly\", \"weekly sun 04:00\" or a cron expression" "--backup-schedule \"daily 03:00\""
  lib_cron_set backup "${cron} root ${BIN_LINK} backup --all --yes --quiet ${flags}"
  lib_manifest_set '.backup.schedule' "$spec"
  lib_manifest_set '.backup.schedule_flags' "$flags"
  lib_ok "Scheduled backups: ${spec} (${cron}) -> ${BACKUP_ROOT}${flags:+ [$flags]}"
}

# =============================================================================
#  restore
# =============================================================================
lib_restore_main() {
  local domain="${1:-}" file="" no_db=0 no_files=0 a="" work="" archive="" plain="" adomain=""
  [[ -n "$domain" ]] || lib_die "Usage: setup.sh restore <domain> --file <archive> [--no-db] [--no-files]" "" "setup.sh restore example.com --file /var/backups/server-setup/example.com/example.com-20250101-030000.tar.gz"
  shift
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --file)     file="${1:-}"; shift ;;
      --no-db)    no_db=1 ;;
      --no-files) no_files=1 ;;
      *) lib_die "Unknown option for restore: ${a}" "" "restore <domain> --file <archive> [--no-db] [--no-files]" ;;
    esac
  done
  domain="${domain,,}"
  lib_require_tools
  lib_require_installed
  [[ -n "$file" && -f "$file" ]] || lib_die "Archive not found: '${file}'" "" "restore <domain> --file /path/to/archive.tar.gz[.enc]"
  lib_backup_verify "$file" || lib_die "Archive verification failed" "$BK_ERROR" "use an intact archive"
  work="$(lib_mktemp -d)"
  archive="$file"
  if [[ "$file" == *.enc ]]; then
    [[ -s "$BACKUP_KEY_FILE" ]] || lib_die "Encrypted archive but ${BACKUP_KEY_FILE} is missing" "" "restore the key file (0600) first"
    plain="${work}/archive.tar.gz"
    openssl enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 -in "$file" -out "$plain" -pass "file:${BACKUP_KEY_FILE}" 2>>"$LOG_FILE" \
      || lib_die "Decryption failed" "wrong key or corrupted archive" "check ${BACKUP_KEY_FILE}"
    archive="$plain"
  fi
  mkdir -p "${work}/x"
  tar -C "${work}/x" -xzf "$archive" || lib_die "Could not extract the archive" "corrupted archive" "verify the file"
  [[ -s "${work}/x/manifest.json" ]] || lib_die "Archive has no manifest.json" "not a server-setup backup" "use an archive created by 'setup.sh backup'"
  ( cd "${work}/x" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1 ) || lib_die "Archive content checksum mismatch" "corrupted archive" "use another backup"
  adomain="$(jq -r '.domain' "${work}/x/manifest.json")"
  if [[ "$adomain" != "$domain" ]]; then
    lib_warn "Archive was created for ${adomain}, restoring into ${domain}"
    lib_confirm "Continue anyway?" n || lib_die "Restore cancelled" "" ""
  fi
  lib_heading "Restore ${domain} from $(basename "$file") (created $(jq -r '.created_at' "${work}/x/manifest.json"))"

  # ---- register the site when it does not exist (disaster recovery) --------
  if ! lib_domain_registered "$domain"; then
    [[ -s "${work}/x/state/domain.json" ]] || lib_die "Site ${domain} is not registered and the archive carries no state" "" "add the site first: setup.sh add ${domain}"
    lib_info "Site ${domain} is not registered; recreating it from the archived state"
    if (( ! OPT_DRY_RUN )); then
      mkdir -p "$(lib_domain_state_dir "$domain")" && chmod 0700 "$(lib_domain_state_dir "$domain")"
      jq --arg d "$domain" '.domain = $d | .ssl.enabled = false | .status = "restoring" | del(.db) | del(.backup)' "${work}/x/state/domain.json" >"$(lib_domain_json "$domain")"
      chmod 0600 "$(lib_domain_json "$domain")"
    fi
    lib_domain_state_load "$domain" || lib_domain_state_load "$adomain" || true
    D_DOMAIN="$domain"; D_HOME="$(lib_domain_home "$domain")"; D_SSL=0; D_STATUS="restoring"
    [[ -n "$D_PHP" ]] && lib_php_ensure_version "$D_PHP"
    lib_domain_user_ensure
    lib_domain_dirs_create
    lib_domain_state_save
    lib_domain_apply_config "restore vhost ${domain}"
  fi
  lib_domain_state_load "$domain"
  # not while a deploy of this application works in the tree the restore writes into
  if lib_app_state_load "$domain"; then _app_site_lock "$domain"; fi

  lib_note "files: $( (( no_files )) && printf 'skipped' || printf "restored into ${D_HOME} (existing files are overwritten)")"
  lib_note "database: $( (( no_db )) && printf 'skipped' || printf 'restored (tables are replaced)')"
  lib_note "a safety backup of the current state is taken first"
  lib_confirm "Proceed with the restore?" n || lib_die "Restore cancelled" "" ""
  lib_rollback_clear

  if (( ! OPT_DRY_RUN )); then
    lib_backup_domain "$domain" --tag pre-restore --keep 0 || lib_warn "safety backup failed: ${BK_ERROR} (continuing)"
  fi

  # ---- files -----------------------------------------------------------------
  if (( ! no_files )) && [[ -s "${work}/x/files.tar.gz" ]]; then
    if (( OPT_DRY_RUN )); then lib_info "[dry-run] would extract files into ${D_HOME}"
    else
      tar -C "$D_HOME" -xzf "${work}/x/files.tar.gz" || lib_die "File restore failed" "tar error" "check disk space"
      chown -R "${D_USER}:${D_GROUP}" "${D_HOME}/public_html" "${D_HOME}/private" 2>/dev/null || true
      if [[ -d "${D_HOME}/app" ]]; then chown -R "${D_USER}:${D_GROUP}" "${D_HOME}/app" 2>/dev/null || true; fi
      if [[ -d "${D_HOME}/.ssh" ]]; then chown -R "${D_USER}:${D_GROUP}" "${D_HOME}/.ssh" 2>/dev/null || true; fi
      lib_ok "Files restored into ${D_HOME}"
    fi
  fi
  # ---- database --------------------------------------------------------------
  local dump=""
  dump="$(find "${work}/x" -maxdepth 1 -name 'db-*.sql.gz' | head -n1 || true)"
  if (( ! no_db )) && [[ -n "$dump" ]]; then
    if ! lib_db_info_load "$domain"; then
      if [[ -s "${work}/x/state/db.info" ]]; then
        lib_info "Recreating the database and user from the archived credentials"
        lib_db_recreate_from_info "$domain" "${work}/x/state/db.info" || lib_die "Could not recreate the database" "SQL error" "see the log"
      else
        lib_warn "Archive contains a dump but no database credentials; creating a new database"
        lib_db_create_for_domain "$domain"
      fi
    fi
    if (( OPT_DRY_RUN )); then lib_info "[dry-run] would import $(basename "$dump") into ${DBI_NAME}"
    else
      lib_db_restore_domain "$domain" "$dump" || lib_die "Database import failed" "SQL error (see log)" "inspect the dump"
      lib_ok "Database ${DBI_NAME} restored"
    fi
  fi
  # ---- wp.info -----------------------------------------------------------------
  if [[ -s "${work}/x/state/wp.info" && ! -s "$(lib_domain_state_dir "$domain")/wp.info" ]] && (( ! OPT_DRY_RUN )); then
    cp "${work}/x/state/wp.info" "$(lib_domain_state_dir "$domain")/wp.info" && chmod 0600 "$(lib_domain_state_dir "$domain")/wp.info"
  fi
  if (( ! OPT_DRY_RUN )); then
    lib_json_set "$(lib_domain_json "$domain")" '.status = "active" | .restored_at = $ts | .restored_from = $f' --arg ts "$(lib_iso_now)" --arg f "$file"
    lib_domain_logrotate_regen
    lib_domain_fail2ban_regen
  fi
  lib_rollback_clear
  # a Node.js site: its dependencies are not in the archive; reinstall them and start it again
  lib_domain_state_load "$domain" >/dev/null 2>&1 || true
  lib_app_restore
  lib_ok "Restore of ${domain} finished"
  (( D_SSL )) || lib_note "SSL is not active for ${domain}; run: setup.sh renew-ssl ${domain}"
}
