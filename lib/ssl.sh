#!/usr/bin/env bash
# lib/ssl.sh - Let's Encrypt via certbot (webroot / DNS-01 Cloudflare), DNS checks,
#              certificate deployment for OpenLiteSpeed, renewal hook, renew-ssl.

CF_INI="${STATE_DIR}/cloudflare.ini"          # certbot dns-cloudflare credentials (0600)
LE_LIVE="/etc/letsencrypt/live"
SSL_LAST_ERROR=""

# =============================================================================
#  Installation
# =============================================================================
lib_ssl_install() {
  lib_apt_install certbot || lib_die "certbot installation failed" "apt error" "check the log"
  if [[ -s "$CF_INI" ]] && ! lib_pkg_installed python3-certbot-dns-cloudflare; then
    lib_apt_install python3-certbot-dns-cloudflare || lib_warn "python3-certbot-dns-cloudflare could not be installed (DNS-01 unavailable)"
  fi
  lib_mkdir "${ACME_ROOT}/.well-known/acme-challenge" 0755 root:root
  lib_ssl_hook_install
  if lib_service_exists certbot; then
    lib_systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    if (( ! OPT_DRY_RUN )) && ! lib_service_active certbot.timer; then
      lib_warn "certbot.timer is not active; adding a cron fallback"
      lib_cron_set certbot-renew "17 3,15 * * * root certbot -q renew"
    else
      lib_cron_remove certbot-renew
    fi
  else
    lib_cron_set certbot-renew "17 3,15 * * * root certbot -q renew"
  fi
  lib_manifest_set '.components.certbot' "$(lib_pkg_version certbot)"
  lib_ok "certbot ready (webroot ${ACME_ROOT}, deploy hook ${CERTBOT_DEPLOY_HOOK})"
}

lib_ssl_hook_render() {
  cat <<EOF
#!/usr/bin/env bash
# Managed by lompstack - certbot deploy hook: copy a renewed certificate into the deploy
# directory and put it into effect. Two independent branches: a site's certificate goes to
# OpenLiteSpeed, the mail lineages (_mailhost, _mail_<site>) go to Postfix and Dovecot.
set -u
STATE_DIR="${STATE_DIR}"
DEPLOY_DIR="${SSL_DEPLOY_DIR}"
LOG="${LOG_FILE}"
LSWS_BIN="${LSWS_HOME}/bin/openlitespeed"
OLS_SERVICE="${OLS_SERVICE}"
MAIL_SNI="${MAIL_POSTFIX_DIR}/sni"
WM_VHOSTS="${LSWS_VHOSTS_DIR}"
BIN="${BIN_LINK}"
log()  { printf '%s [HOOK] %s\\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$*" >>"\$LOG" 2>/dev/null; }
fail() {
  log "ERROR: \$*"
  if [[ -x "\$BIN" ]]; then "\$BIN" notify --send "SSL deploy failed on \$(hostname)" "\$* Check \$LOG." --quiet >/dev/null 2>&1; fi
  return 0
}

[[ -n "\${RENEWED_LINEAGE:-}" ]] || exit 0
name="\$(basename "\$RENEWED_LINEAGE")"
rc=0

deploy() {   # copy the renewed pair into the deploy directory, 0600 root
  mkdir -p "\$DEPLOY_DIR/\$name" && chmod 0700 "\$DEPLOY_DIR/\$name" || return 1
  cp -L "\$RENEWED_LINEAGE/fullchain.pem" "\$DEPLOY_DIR/\$name/fullchain.pem.new" \\
    && cp -L "\$RENEWED_LINEAGE/privkey.pem" "\$DEPLOY_DIR/\$name/privkey.pem.new" || return 1
  chmod 0600 "\$DEPLOY_DIR/\$name/"*.new
  mv -f "\$DEPLOY_DIR/\$name/fullchain.pem.new" "\$DEPLOY_DIR/\$name/fullchain.pem"
  mv -f "\$DEPLOY_DIR/\$name/privkey.pem.new" "\$DEPLOY_DIR/\$name/privkey.pem"
}

case "\$name" in
  _mailhost|_mail_*)
    if deploy; then
      log "deployed renewed mail certificate \$name (\${RENEWED_DOMAINS:-})"
      if command -v postfix >/dev/null 2>&1; then
        if [[ -f "\$MAIL_SNI" ]]; then postmap -F "hash:\$MAIL_SNI" >/dev/null 2>&1 || fail "postmap failed for \$MAIL_SNI"; fi
        if postfix check >/dev/null 2>&1 && postfix reload >/dev/null 2>&1; then
          log "Postfix reloaded after renewal of \$name"
        else
          fail "Postfix could not be reloaded after renewal of \$name."; rc=1
        fi
      fi
      if command -v doveconf >/dev/null 2>&1; then
        if doveconf -n >/dev/null 2>&1 && systemctl reload dovecot >/dev/null 2>&1; then
          log "Dovecot reloaded after renewal of \$name"
        else
          fail "Dovecot could not be reloaded after renewal of \$name."; rc=1
        fi
      fi
      # This lineage also carries webmail.<domain>, and OpenLiteSpeed holds the certificate it
      # started with: without this, the webmail would go on serving the expired one while
      # every mail client had the new one.
      if compgen -G "\$WM_VHOSTS/_wm_*" >/dev/null 2>&1; then
        if "\$LSWS_BIN" -t >/dev/null 2>&1 && systemctl restart "\$OLS_SERVICE" >/dev/null 2>&1; then
          log "OpenLiteSpeed restarted for the webmail after renewal of \$name"
        else
          fail "Certificate \$name renewed but OpenLiteSpeed could not be restarted for the webmail."; rc=1
        fi
      fi
    else
      fail "Could not copy the renewed certificate for \$name."; rc=1
    fi
    ;;
  *)
    if [[ ! -d "\$STATE_DIR/domains/\$name" ]]; then
      log "renewed lineage \$name is not managed by lompstack; nothing deployed"
    elif deploy; then
      exp="\$(openssl x509 -enddate -noout -in "\$DEPLOY_DIR/\$name/fullchain.pem" 2>/dev/null | cut -d= -f2)"
      printf 'CERT_NAME=%s\\nEXPIRES=%s\\nDEPLOYED=%s\\nDOMAINS=%s\\n' "\$name" "\$exp" "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" "\${RENEWED_DOMAINS:-}" >"\$STATE_DIR/domains/\$name/ssl.info"
      chmod 0600 "\$STATE_DIR/domains/\$name/ssl.info"
      log "deployed renewed certificate for \$name (\${RENEWED_DOMAINS:-})"
      # a stop and start, not a reload: lsws' own graceful restart replaces the process behind
      # systemd's back, and systemd then refuses the next restart
      if "\$LSWS_BIN" -t >/dev/null 2>&1 && systemctl restart "\$OLS_SERVICE" >/dev/null 2>&1; then
        log "OpenLiteSpeed restarted after renewal of \$name"
      else
        fail "Certificate \$name renewed but OpenLiteSpeed could not be restarted."; rc=1
      fi
    else
      fail "Could not copy the renewed certificate for \$name."; rc=1
    fi
    ;;
esac
exit \$rc
EOF
}

lib_ssl_hook_install() {
  lib_mkdir "$(dirname "$CERTBOT_DEPLOY_HOOK")" 0755 root:root
  lib_ssl_hook_render | lib_write_file "$CERTBOT_DEPLOY_HOOK" 0755 root:root
  (( LIB_FILE_CHANGED )) && lib_ok "certbot deploy hook installed"
  return 0
}

# =============================================================================
#  Certificate information
# =============================================================================
lib_ssl_cert_exists()  { [[ -s "${LE_LIVE}/${1}/fullchain.pem" ]]; }
lib_ssl_deployed()     { [[ -s "${SSL_DEPLOY_DIR}/${1}/fullchain.pem" && -s "${SSL_DEPLOY_DIR}/${1}/privkey.pem" ]]; }

# The names a lineage actually covers, read from the certificate rather than from certbot's
# renewal file: the file says what was asked for, the certificate says what was issued.
# The deployed copy first, because that is the one the servers actually present - a renewal
# that certbot made but the deploy hook could not copy would otherwise look finished.
lib_ssl_cert_names() {   # cert-name -> one name per line
  local f="${SSL_DEPLOY_DIR}/${1}/fullchain.pem"
  [[ -s "$f" ]] || f="${LE_LIVE}/${1}/cert.pem"
  [[ -s "$f" ]] || return 1
  openssl x509 -noout -ext subjectAltName -in "$f" 2>/dev/null \
    | tr ',' '\n' \
    | sed -n 's/.*DNS:[[:space:]]*\([^[:space:],]\{1,\}\).*/\1/p' \
    | grep . || return 1
}

# Whether it covers every name given. A lineage that is missing one has to be re-issued with
# the whole set: certbot expands a lineage in place when --cert-name names an existing one.
lib_ssl_cert_covers() {   # cert-name name [name...]
  local cert="$1" n="" have=""
  shift
  have="$(lib_ssl_cert_names "$cert")" || return 1
  for n in "$@"; do
    grep -qxiF "$n" <<<"$have" || return 1
  done
  return 0
}

lib_ssl_expiry_epoch() {   # certfile -> epoch (empty when unreadable)
  local end=""
  end="$(openssl x509 -enddate -noout -in "$1" 2>/dev/null | cut -d= -f2)"
  [[ -n "$end" ]] && date -d "$end" +%s 2>/dev/null || printf ''
}

lib_ssl_days_left() {      # domain -> days (empty when no cert)
  local f="${SSL_DEPLOY_DIR}/${1}/fullchain.pem" e=""
  [[ -s "$f" ]] || f="${LE_LIVE}/${1}/fullchain.pem"
  [[ -s "$f" ]] || { printf ''; return 0; }
  e="$(lib_ssl_expiry_epoch "$f")"
  [[ -n "$e" ]] && lib_days_until "$e" || printf ''
}

lib_ssl_issuer() {
  local f="${SSL_DEPLOY_DIR}/${1}/fullchain.pem"
  [[ -s "$f" ]] || { printf ''; return 0; }
  openssl x509 -issuer -noout -in "$f" 2>/dev/null | sed -E 's/^issuer=//; s/.*O *= *([^,]+).*/\1/' || true
}

lib_ssl_cf_token_available() { [[ -s "$CF_INI" ]] && grep -q '^dns_cloudflare_api_token' "$CF_INI"; }

# =============================================================================
#  DNS verification  (0 = points here, 1 = mismatch, 2 = Cloudflare proxied)
# =============================================================================
lib_ssl_dns_check() {   # domain www(0/1)
  local domain="$1" www="${2:-0}" n="" a4="" a6="" ok=1 proxied=0 detail=""
  local -a names=("$domain")
  (( www )) && names+=("www.${domain}")
  lib_system_analyze
  if [[ -z "$SYS_PUBLIC_IPV4" && -z "$SYS_PUBLIC_IPV6" ]]; then
    lib_warn "Public IP unknown; DNS verification skipped"
    return 0
  fi
  for n in "${names[@]}"; do
    a4="$(lib_resolve A "$n" | tr '\n' ' ')"
    a6="$(lib_resolve AAAA "$n" | tr '\n' ' ')"
    if [[ -z "$a4" && -z "$a6" ]]; then ok=0; detail+="${n}: no A/AAAA record; "; continue; fi
    if [[ -n "$SYS_PUBLIC_IPV4" && " $a4 " == *" ${SYS_PUBLIC_IPV4} "* ]]; then continue; fi
    if [[ -n "$SYS_PUBLIC_IPV6" && " $a6 " == *" ${SYS_PUBLIC_IPV6} "* ]]; then continue; fi
    if lib_cf_ips_are_cloudflare "$a4 $a6"; then proxied=1; detail+="${n}: resolves to Cloudflare (${a4}${a6}); "; continue; fi
    ok=0; detail+="${n}: resolves to ${a4}${a6} (server: ${SYS_PUBLIC_IPV4:-?}${SYS_PUBLIC_IPV6:+ / $SYS_PUBLIC_IPV6}); "
  done
  SSL_LAST_ERROR="$detail"
  (( ok )) || return 1
  (( proxied )) && return 2
  return 0
}

# =============================================================================
#  Obtain / deploy / delete
# =============================================================================
# lib_ssl_obtain domain www wildcard staging force email [method]
lib_ssl_obtain() {
  local domain="$1" www="${2:-0}" wildcard="${3:-0}" staging="${4:-0}" force="${5:-0}" email="${6:-}" method="${7:-auto}"
  local -a args=(certonly --non-interactive --agree-tos --keep-until-expiring --cert-name "$domain" --key-type ecdsa -d "$domain")
  (( www )) && args+=(-d "www.${domain}")
  (( wildcard )) && args+=(-d "*.${domain}")
  (( staging )) && args+=(--staging)
  (( force )) && args+=(--force-renewal)
  if [[ -n "$email" ]]; then args+=(--email "$email"); else args+=(--register-unsafely-without-email); fi
  if [[ "$method" == "auto" ]]; then
    # With the origin locked to Cloudflare, port 80 answers only through the edge, so DNS-01
    # is the way a certificate still comes for a name that is not proxied. Only with a token,
    # though: without one there is nothing to switch to, and HTTP-01 through an orange cloud
    # still works - the challenge is fetched by a Cloudflare address, which the lock allows.
    if (( wildcard )) \
       || { lib_cf_origin_locked && lib_ssl_cf_token_available; } \
       || { [[ "${D_CLOUDFLARE:-0}" == "1" ]] && lib_ssl_cf_token_available; }; then method="dns"; else method="webroot"; fi
  fi
  if [[ "$method" == "dns" ]]; then
    lib_ssl_cf_token_available || lib_die "DNS-01 requires a Cloudflare API token" "${CF_INI} is missing" "run: setup.sh install --cf-api-token <token>  (or use --cloudflare without --wildcard)"
    lib_pkg_installed python3-certbot-dns-cloudflare || lib_apt_install python3-certbot-dns-cloudflare || lib_die "python3-certbot-dns-cloudflare missing" "apt error" "apt-get install python3-certbot-dns-cloudflare"
    args+=(--dns-cloudflare --dns-cloudflare-credentials "$CF_INI" --dns-cloudflare-propagation-seconds 30)
  else
    args+=(--webroot -w "$ACME_ROOT")
  fi
  lib_info "Requesting certificate for ${domain}$( (( www )) && printf ' + www')$( (( wildcard )) && printf ' + wildcard') via ${method}$( (( staging )) && printf ' (staging)')"
  if ! lib_run certbot "${args[@]}"; then
    SSL_LAST_ERROR="certbot failed (see ${LOG_FILE} and /var/log/letsencrypt/letsencrypt.log)"
    return 1
  fi
  (( OPT_DRY_RUN )) && return 0
  lib_ssl_deploy "$domain"
}

# A certificate for names that do not belong to a site: the mail host, a domain's mail and
# webmail names. The lineage name is given by the caller and starts with an underscore, which
# lib_domain_valid refuses, so it can never collide with a site's own lineage.
lib_ssl_obtain_names() {   # cert-name name [name...]
  local cert="$1"; shift
  local email="${DEFAULT_EMAIL:-}" method="webroot" n=""
  local -a args=(certonly --non-interactive --agree-tos --keep-until-expiring --cert-name "$cert" --key-type ecdsa)
  (( $# > 0 )) || { SSL_LAST_ERROR="no names given for certificate ${cert}"; return 1; }
  for n in "$@"; do args+=(-d "$n"); done
  if [[ -n "$email" ]]; then args+=(--email "$email"); else args+=(--register-unsafely-without-email); fi
  if lib_ssl_cf_token_available; then
    if lib_pkg_installed python3-certbot-dns-cloudflare || lib_apt_install python3-certbot-dns-cloudflare; then method="dns"; fi
  fi
  if [[ "$method" == "dns" ]]; then
    args+=(--dns-cloudflare --dns-cloudflare-credentials "$CF_INI" --dns-cloudflare-propagation-seconds 30)
  else
    args+=(--webroot -w "$ACME_ROOT")
  fi
  lib_info "Requesting certificate ${cert} for ${*} via ${method}"
  if ! lib_run certbot "${args[@]}"; then
    SSL_LAST_ERROR="certbot failed for ${cert} (see ${LOG_FILE} and /var/log/letsencrypt/letsencrypt.log)"
    return 1
  fi
  (( OPT_DRY_RUN )) && return 0
  lib_ssl_deploy_files "$cert" || return 1
  lib_log_write INFO "certificate ${cert} deployed (${*})"
  lib_ok "Certificate ${cert} deployed (${*})"
}

# Copy a live lineage into the deploy directory (0600 root). No site state is touched, so it
# serves both a site's certificate and the mail lineages.
lib_ssl_deploy_files() {   # cert-name
  local name="$1" src="${LE_LIVE}/${1}" dst="${SSL_DEPLOY_DIR}/${1}"
  (( OPT_DRY_RUN )) && { lib_info "[dry-run] would deploy ${src} -> ${dst}"; return 0; }
  [[ -s "${src}/fullchain.pem" && -s "${src}/privkey.pem" ]] || { SSL_LAST_ERROR="no certificate in ${src}"; return 1; }
  lib_mkdir "$SSL_DEPLOY_DIR" 0700 root:root
  lib_mkdir "$dst" 0700 root:root
  cp -L "${src}/fullchain.pem" "${dst}/fullchain.pem.new" && cp -L "${src}/privkey.pem" "${dst}/privkey.pem.new" || return 1
  chmod 0600 "${dst}"/*.new
  mv -f "${dst}/fullchain.pem.new" "${dst}/fullchain.pem"
  mv -f "${dst}/privkey.pem.new" "${dst}/privkey.pem"
}

# Copy live certificate into the OLS deploy directory + update state.
lib_ssl_deploy() {
  local domain="$1" dst="${SSL_DEPLOY_DIR}/${1}" exp=""
  (( OPT_DRY_RUN )) && { lib_info "[dry-run] would deploy ${LE_LIVE}/${domain} -> ${dst}"; return 0; }
  lib_ssl_deploy_files "$domain" || return 1
  exp="$(openssl x509 -enddate -noout -in "${dst}/fullchain.pem" 2>/dev/null | cut -d= -f2)"
  if [[ -d "$(lib_domain_state_dir "$domain")" ]]; then
    printf 'CERT_NAME=%s\nEXPIRES=%s\nDEPLOYED=%s\nISSUER=%s\n' "$domain" "$exp" "$(lib_iso_now)" "$(lib_ssl_issuer "$domain")" \
      >"$(lib_domain_state_dir "$domain")/ssl.info"
    chmod 0600 "$(lib_domain_state_dir "$domain")/ssl.info"
    lib_json_set "$(lib_domain_json "$domain")" '.ssl.enabled = true | .ssl.cert_name = $n | .ssl.expires = $e | .ssl.updated_at = $ts' \
      --arg n "$domain" --arg e "$exp" --arg ts "$(lib_iso_now)"
  fi
  lib_log_write INFO "certificate deployed for ${domain} (expires ${exp})"
  lib_ok "Certificate deployed for ${domain} (expires ${exp})"
}

lib_ssl_delete() {   # domain
  local domain="$1"
  if lib_ssl_cert_exists "$domain" || [[ -f "/etc/letsencrypt/renewal/${domain}.conf" ]]; then
    lib_run certbot delete --non-interactive --cert-name "$domain" || lib_warn "certbot delete failed for ${domain} (see log)"
  fi
  lib_rm "${SSL_DEPLOY_DIR}/${domain}"
  if [[ -s "$(lib_domain_json "$domain")" ]]; then
    lib_json_set "$(lib_domain_json "$domain")" '.ssl.enabled = false | del(.ssl.expires) | del(.ssl.cert_name)'
    lib_rm "$(lib_domain_state_dir "$domain")/ssl.info"
  fi
  return 0
}

lib_ssl_status_line() {   # domain -> "42 days (Let's Encrypt)" / "none"
  local d=""; d="$(lib_ssl_days_left "$1")"
  if [[ -z "$d" ]]; then printf 'none'; else printf '%s days%s' "$d" "$( [[ -n "$(lib_ssl_issuer "$1")" ]] && printf ' (%s)' "$(lib_ssl_issuer "$1")")"; fi
}

# =============================================================================
#  renew-ssl command
# =============================================================================
lib_ssl_renew_main() {
  local domain="" force=0 all=0 staging=0 wildcard=0 a=""
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --force)    force=1 ;;
      --all)      all=1 ;;
      --staging)  staging=1 ;;
      --wildcard) wildcard=1 ;;
      -*)         lib_die "Unknown option for renew-ssl: ${a}" "" "renew-ssl [domain] [--force] [--all] [--staging] [--wildcard]" ;;
      *)          domain="${a,,}" ;;
    esac
  done
  lib_require_tools
  lib_require_installed
  if (( all )) || [[ -z "$domain" ]]; then
    local d="" failed=() n=0
    while read -r d; do
      [[ -n "$d" ]] || continue
      # lib_json_get would turn a literal false into "" (jq's // treats false like null)
      [[ "$(lib_json_get_raw "$(lib_domain_json "$d")" '.ssl.wanted')" == "false" ]] && continue
      n=$((n + 1))
      lib_heading "renew-ssl ${d}"
      if ! SERVER_SETUP_LOCKED=1 "$SCRIPT_PATH" renew-ssl "$d" --yes $( (( force )) && printf -- '--force') $( (( staging )) && printf -- '--staging') $( (( OPT_QUIET )) && printf -- '--quiet'); then
        failed+=("$d")
      fi
    done < <(lib_domains_list)
    (( n == 0 )) && { lib_info "No sites with SSL enabled"; return 0; }
    if ((${#failed[@]} > 0)); then
      lib_notify_send "SSL renewal failed on $(hostname)" "renew-ssl failed for: ${failed[*]}. See ${LOG_FILE}." || true
      lib_die "SSL renewal failed for: ${failed[*]}" "see the per-domain errors above" "fix DNS / certbot problems and re-run"
    fi
    lib_ok "SSL renewal finished for ${n} site(s)"
    return 0
  fi

  lib_domain_valid "$domain" || lib_die "Invalid domain '${domain}'" "not a valid FQDN" "renew-ssl example.com"
  lib_domain_registered "$domain" || lib_die "Site ${domain} is not registered" "unknown domain" "setup.sh add ${domain}"
  lib_domain_state_load "$domain"
  (( wildcard )) && D_SSL_WILDCARD=1
  local rc=0
  lib_ssl_dns_check "$domain" "$D_WWW" || rc=$?
  if (( rc == 1 )); then
    lib_die "DNS for ${domain} does not point to this server" "${SSL_LAST_ERROR}" "create/update the A (and AAAA) records to ${SYS_PUBLIC_IPV4:-<server IP>} and wait for propagation"
  elif (( rc == 2 )); then
    lib_warn "${domain} is proxied by Cloudflare (orange cloud): ${SSL_LAST_ERROR}"
    if lib_ssl_cf_token_available; then lib_info "Using DNS-01 validation through the stored Cloudflare API token"
    else lib_warn "HTTP-01 through the Cloudflare proxy may fail; DNS-01 is recommended: setup.sh install --cf-api-token <token>"; fi
  fi
  if lib_ssl_cert_exists "$domain" && (( ! force )) && (( ! D_SSL_WILDCARD )); then
    lib_info "Renewing existing certificate for ${domain}"
    if ! lib_run certbot renew --cert-name "$domain" --non-interactive $( (( staging )) && printf -- '--staging'); then
      lib_notify_send "SSL renewal failed for ${domain}" "certbot renew failed on $(hostname). See ${LOG_FILE}." || true
      lib_die "certbot renew failed for ${domain}" "see /var/log/letsencrypt/letsencrypt.log" "fix the reported problem and re-run renew-ssl ${domain}"
    fi
    (( OPT_DRY_RUN )) || lib_ssl_deploy "$domain" || lib_die "Certificate deployment failed" "$SSL_LAST_ERROR" "check ${LE_LIVE}/${domain}"
  else
    lib_ssl_obtain "$domain" "$D_WWW" "$D_SSL_WILDCARD" "$staging" "$force" "${D_EMAIL:-$DEFAULT_EMAIL}" \
      || lib_die "Could not obtain a certificate for ${domain}" "$SSL_LAST_ERROR" "verify DNS, port 80 reachability and /var/log/letsencrypt/letsencrypt.log"
  fi
  (( OPT_DRY_RUN )) && return 0
  D_SSL=1; D_SSL_WANTED=1
  lib_domain_state_save
  lib_domain_apply_config "enable SSL for ${domain}"
  lib_ols_smoke_test "$domain" "$(lib_domain_expected_codes lenient)" https || lib_warn "HTTPS smoke test failed for ${domain} (${OLS_TEST_OUTPUT})"
  lib_ok "SSL active for ${domain}: $(lib_ssl_status_line "$domain")"
}
