#!/usr/bin/env bash
# lib/ssl.sh - Let's Encrypt via certbot (webroot / DNS-01 Cloudflare), DNS checks,
#              certificate deployment for OpenLiteSpeed, renewal hook, renew-ssl.

CF_INI="${STATE_DIR}/cloudflare.ini"          # certbot dns-cloudflare credentials (0600)
LE_LIVE="/etc/letsencrypt/live"
LE_RENEWAL="/etc/letsencrypt/renewal"         # one <lineage>.conf per certificate certbot renews
LE_LOG="/var/log/letsencrypt/letsencrypt.log"
SSL_RENEW_CRON="17 3,15 * * * root certbot -q renew"
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
  lib_ssl_renewal_ensure
  lib_manifest_set '.components.certbot' "$(lib_pkg_version certbot)"
  lib_ok "certbot ready (webroot ${ACME_ROOT}, deploy hook ${CERTBOT_DEPLOY_HOOK})"
}

# What runs "certbot renew" twice a day: the package's systemd timer, and a cron entry of ours
# where there is no timer or it will not start. Never both. install sets it up, and "ssl fix"
# puts it back on a server where it has since been switched off.
lib_ssl_renewal_ensure() {
  if lib_service_exists certbot; then
    lib_systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    if (( ! OPT_DRY_RUN )) && ! lib_service_active certbot.timer; then
      lib_warn "certbot.timer is not active; adding a cron fallback"
      lib_cron_set certbot-renew "$SSL_RENEW_CRON"
    else
      lib_cron_remove certbot-renew
    fi
  else
    lib_cron_set certbot-renew "$SSL_RENEW_CRON"
  fi
}

lib_ssl_renewal_how() {   # -> "timer", "cron", or nothing when no one runs certbot renew
  if lib_service_active certbot.timer; then printf 'timer'
  elif lib_cron_has certbot-renew && { lib_service_active cron || lib_service_active crond; }; then printf 'cron'
  fi
  return 0
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
  local domain="" force=0 all=0 missing=0 staging=0 wildcard=0 a=""
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --force)    force=1 ;;
      --all)      all=1 ;;
      --missing)  missing=1 ;;
      --staging)  staging=1 ;;
      --wildcard) wildcard=1 ;;
      -*)         lib_die "Unknown option for renew-ssl: ${a}" "" "renew-ssl [domain] [--force] [--all] [--missing] [--staging] [--wildcard]" ;;
      *)          domain="${a,,}" ;;
    esac
  done
  lib_require_tools
  lib_require_installed
  if (( missing )) && [[ -n "$domain" ]]; then
    lib_die "--missing takes no domain" "it is every site that has no certificate" "renew-ssl --missing   or   renew-ssl ${domain}"
  fi
  if (( all )) || (( missing )) || [[ -z "$domain" ]]; then
    local d="" failed=() n=0
    while read -r d; do
      [[ -n "$d" ]] || continue
      if (( missing )); then
        # every site that has none, the ones added with --no-ssl included: asking for all of
        # them at once is the operator saying they are wanted now
        [[ "$(lib_json_get_raw "$(lib_domain_json "$d")" '.ssl.enabled')" == "true" ]] && continue
      else
        # lib_json_get would turn a literal false into "" (jq's // treats false like null)
        [[ "$(lib_json_get_raw "$(lib_domain_json "$d")" '.ssl.wanted')" == "false" ]] && continue
      fi
      n=$((n + 1))
      lib_heading "renew-ssl ${d}"
      if ! SERVER_SETUP_LOCKED=1 "$SCRIPT_PATH" renew-ssl "$d" --yes $( (( force )) && printf -- '--force') $( (( staging )) && printf -- '--staging') $( (( OPT_QUIET )) && printf -- '--quiet'); then
        failed+=("$d")
      fi
    done < <(lib_domains_list)
    if (( n == 0 )); then
      if (( missing )); then lib_info "Every site already has a certificate"; else lib_info "No sites with SSL enabled"; fi
      return 0
    fi
    if ((${#failed[@]} > 0)); then
      lib_notify_send "SSL renewal failed on $(hostname)" "renew-ssl failed for: ${failed[*]}. See ${LOG_FILE}." || true
      lib_die "SSL renewal failed for: ${failed[*]}" "see the per-domain errors above" "fix DNS / certbot problems and re-run$( (( missing )) && printf ' (the %s of %s that got one are done; --missing asks only for the rest)' "$(( n - ${#failed[@]} ))" "$n")"
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

# =============================================================================
#  ssl command: which certificates there are, and whether they renew by themselves
# =============================================================================
# One certificate, judged the way a browser - or Cloudflare in Full (strict) - judges it, and
# then the way certbot's next run will. Prints "LEVEL|days|trusted|text": LEVEL is
# OK, WARN, FAIL or NONE (there is none), trusted is 1 when a client accepts it today for
# every name given. The copy in the deploy directory is the one read: the servers present
# that one, whatever certbot holds.
lib_ssl_lineage_check() {   # cert-name [name...]
  local cert="$1"; shift
  local f="${SSL_DEPLOY_DIR}/${cert}/fullchain.pem" live="${LE_LIVE}/${cert}/fullchain.pem"
  local days="" issuer="" n="" missing="" e_live="" e_dep=""
  if [[ ! -s "$f" ]]; then
    if [[ -s "$live" ]]; then printf 'FAIL||0|issued, but never copied to where the servers read it\n'
    else printf 'NONE||0|no certificate\n'; fi
    return 0
  fi
  days="$(lib_ssl_days_left "$cert")"
  if [[ -z "$days" ]]; then printf 'FAIL||0|the certificate file cannot be read\n'; return 0; fi
  if (( days < 0 )); then printf 'FAIL|%s|0|expired %s day(s) ago\n' "$days" "$(( -days ))"; return 0; fi
  if [[ "$(openssl x509 -noout -issuer_hash -in "$f" 2>/dev/null)" == "$(openssl x509 -noout -subject_hash -in "$f" 2>/dev/null)" ]]; then
    printf 'FAIL|%s|0|self-signed: a temporary one, no client trusts it\n' "$days"; return 0
  fi
  issuer="$(lib_ssl_issuer "$cert")"
  if [[ "${issuer^^}" == *STAGING* ]]; then
    printf "FAIL|%s|0|a Let's Encrypt staging (test) certificate, no client trusts it\n" "$days"; return 0
  fi
  for n in "$@"; do lib_ssl_cert_covers "$cert" "$n" || missing+="${missing:+, }${n}"; done
  if [[ -n "$missing" ]]; then printf 'FAIL|%s|0|does not cover %s\n' "$days" "$missing"; return 0; fi
  # trusted today; what follows is about tomorrow
  if [[ ! -s "${LE_RENEWAL}/${cert}.conf" ]]; then
    printf 'FAIL|%s|1|certbot has no renewal file for it: it will not renew by itself\n' "$days"; return 0
  fi
  if (( days < 7 )); then printf 'FAIL|%s|1|renewal is not getting through\n' "$days"; return 0; fi
  if [[ -s "$live" ]]; then
    e_live="$(lib_ssl_expiry_epoch "$live")"; e_dep="$(lib_ssl_expiry_epoch "$f")"
    if [[ -n "$e_live" && -n "$e_dep" ]] && (( e_live > e_dep )); then
      printf 'WARN|%s|1|renewed, but the servers still use the older copy\n' "$days"; return 0
    fi
  fi
  # certbot renews at 30 days left, so a certificate below that has missed at least one run
  if (( days < 30 )); then printf 'WARN|%s|1|renewal is overdue\n' "$days"; return 0; fi
  printf 'OK|%s|1|%s\n' "$days" "${issuer:-unknown issuer}"
}

_ssl_row() {   # label level days text
  local colour="$C_GRN" word="ok" left="-" pad=0 LC_ALL=C.UTF-8
  case "$2" in
    WARN) colour="$C_YEL"; word="warn" ;;
    FAIL) colour="$C_RED"; word="FAIL" ;;
    NONE) colour="$C_DIM"; word="none" ;;
  esac
  if [[ -n "$3" ]]; then lib_tr "days"; left="${3} ${LIB_TR}"; fi
  lib_tr "$4"
  # padded here: printf counts bytes, and "gün" has a letter of two
  pad=$(( 10 - ${#left} )); (( pad > 0 )) || pad=0
  printf '  %-32s %s%-5s%s %s%*s %s\n' "$1" "$colour" "$word" "$C_RST" "$left" "$pad" "" "$LIB_TR"
}

lib_ssl_usage() {
  if [[ "${LIB_LANG:-en}" == "tr" ]]; then
    cat <<'EOF'
ssl [status]   Her sertifika (siteler, yönlendirmeler, posta): var mı, ne kadar süresi kaldı
               ve kendiliğinden yenileniyor mu - certbot'u çalıştıran timer ya da cron satırı,
               deploy kancası, her biri için certbot'un yenileme dosyası. Hiçbir şeyi
               değiştirmez. Düzeltilmesi gereken bir şey varsa çıkış kodu 1 olur.
ssl test       Her sertifikanın yenilenmesini Let's Encrypt'in staging sunucusuna karşı
               dener (certbot renew --dry-run). Hiçbir sertifika değiştirilmez.
ssl fix        Otomatik yenilemeyi geri kurar: deploy kancası ve timer (ya da cron satırı).
EOF
    return 0
  fi
  cat <<'EOF'
ssl [status]   Every certificate (sites, redirects, mail): whether there is one, how long it has,
               and whether it renews by itself - the timer or cron entry that runs certbot,
               the deploy hook, certbot's renewal file for each. Changes nothing.
               Exit status 1 when something needs putting right.
ssl test       Rehearse the renewal of every certificate against Let's Encrypt's staging
               server (certbot renew --dry-run). No certificate is replaced.
ssl fix        Put automatic renewal back: the deploy hook, and the timer (or cron entry).
EOF
}

lib_ssl_main() {
  local sub="${1:-status}"
  (($# > 0)) && shift
  case "$sub" in
    status|--status) lib_ssl_status_main "$@" ;;
    test)            lib_ssl_test_main "$@" ;;
    fix)             lib_ssl_fix_main "$@" ;;
    help|-h|--help)  lib_ssl_usage ;;
    *)               lib_die "Unknown ssl subcommand: ${sub}" "" "ssl status | ssl test | ssl fix" ;;
  esac
}

lib_ssl_status_main() {
  (($# == 0)) || lib_die "Unknown option for ssl status: ${1}" "" "ssl status"
  lib_require_tools
  lib_require_installed
  local d="" cert="" level="" days="" trusted="" text="" how="" me=""
  local -i sites=0 untrusted=0 fails=0 warns=0 auto_ok=1 have=0 without=0
  local -a names=() fixes=()
  me="$(lib_self_cmd)"

  _ssl_count() {   # level fix-hint
    case "$1" in
      FAIL) fails+=1; lib_tr "$2"; fixes+=("$LIB_TR") ;;
      WARN) warns+=1; lib_tr "$2"; fixes+=("$LIB_TR") ;;
    esac
    return 0
  }

  lib_tr "CERTIFICATES"; printf '\n %s%s%s\n' "$C_BLD" "$LIB_TR" "$C_RST"
  if ! lib_server_mail_only; then
    lib_tr "Sites"; printf '  %s%s%s\n' "$C_DIM" "$LIB_TR" "$C_RST"
    while read -r d; do
      [[ -n "$d" ]] || continue
      lib_domain_state_load "$d" || continue
      sites+=1
      if (( ! D_SSL )); then
        untrusted+=1; without+=1
        if (( D_SSL_WANTED )); then
          _ssl_row "$d" FAIL "" "asked for, never issued"
          _ssl_count FAIL "${me} renew-ssl ${d}    # once its DNS points here"
        else
          _ssl_row "$d" NONE "" "not requested: the site answers on HTTP only (${me} renew-ssl ${d})"
        fi
        continue
      fi
      # a wildcard carries www without naming it
      names=("$d"); (( D_WWW && ! D_SSL_WILDCARD )) && names+=("www.${d}")
      IFS='|' read -r level days trusted text < <(lib_ssl_lineage_check "$d" "${names[@]}")
      [[ "$trusted" == "1" ]] || untrusted+=1
      [[ "$level" == "NONE" ]] || have+=1
      _ssl_row "$d" "$level" "$days" "$text"
      # a site whose state says SSL is on has a vhost that points at the file: none is a failure
      [[ "$level" == "NONE" ]] && level="FAIL"
      _ssl_count "$level" "${me} renew-ssl ${d}"
    done < <(lib_domains_list)
    if (( sites == 0 )); then lib_tr "(no sites yet)"; printf '  %s\n' "$LIB_TR"; fi
  fi
  # a name that only redirects answers HTTPS with a certificate of its own, renewed like a site's
  if [[ -n "$(lib_redirects_list)" ]]; then
    lib_tr "Redirects"; printf '  %s%s%s\n' "$C_DIM" "$LIB_TR" "$C_RST"
    while read -r d; do
      [[ -n "$d" ]] || continue
      lib_redirect_load "$d" || continue
      names=("$d"); (( R_WWW )) && names+=("www.${d}")
      IFS='|' read -r level days trusted text < <(lib_ssl_lineage_check "$d" "${names[@]}")
      _ssl_row "$d" "$level" "$days" "$text"
      # without one it still redirects, over HTTP only: worth saying, and nothing is down
      [[ "$level" == "NONE" ]] && level="WARN"
      _ssl_count "$level" "${me} redirect add ${d} ${R_TARGET}$( (( R_WWW )) && printf ' --www')    # once its DNS points here"
    done < <(lib_redirects_list)
  fi
  if lib_mail_installed; then
    lib_tr "Mail"; printf '  %s%s%s\n' "$C_DIM" "$LIB_TR" "$C_RST"
    IFS='|' read -r level days trusted text < <(lib_ssl_lineage_check "$MAIL_CERT_NAME" "$(lib_mail_host)")
    # the mail host starts on a self-signed certificate and asks for the real one every six
    # hours by itself: clients warn meanwhile, which is a warning here as it is in doctor
    [[ "$text" == self-signed* ]] && level="WARN"
    _ssl_row "$(lib_mail_host)" "$level" "$days" "$text"
    [[ "$level" == "NONE" ]] || have+=1
    [[ "$level" == "NONE" ]] && level="WARN"
    _ssl_count "$level" "${me} mail cert"
    while read -r d; do
      [[ -n "$d" ]] || continue
      names=("mail.${d}")
      [[ "$(lib_json_get "$(lib_mail_json "$d")" '.mail.webmail')" == "true" ]] && names+=("$(lib_webmail_host "$d")")
      IFS='|' read -r level days trusted text < <(lib_ssl_lineage_check "$(lib_mail_cert_name "$d")" "${names[@]}")
      _ssl_row "mail.${d}" "$level" "$days" "$text"
      [[ "$level" == "NONE" ]] || have+=1
      [[ "$level" == "NONE" ]] && level="WARN"
      _ssl_count "$level" "${me} mail cert ${d}"
    done < <(lib_mail_domains)
  fi

  lib_tr "AUTOMATIC RENEWAL"; printf '\n %s%s%s\n' "$C_BLD" "$LIB_TR" "$C_RST"
  how="$(lib_ssl_renewal_how)"
  if ! lib_have certbot; then
    auto_ok=0; lib_print_kv "Runs certbot" "${C_RED}certbot is not installed${C_RST}"
  elif [[ "$how" == "timer" ]]; then
    text="$(systemctl show certbot.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)"
    lib_print_kv "Runs certbot" "${C_GRN}certbot.timer${C_RST} (systemd, twice a day)${text:+; next run ${text}}"
  elif [[ "$how" == "cron" ]]; then
    lib_print_kv "Runs certbot" "${C_GRN}cron${C_RST} (${CRON_FILE}: ${SSL_RENEW_CRON%% root *})"
  else
    auto_ok=0; lib_print_kv "Runs certbot" "${C_RED}nothing${C_RST}: no active certbot.timer and no cron entry"
  fi
  if [[ -x "$CERTBOT_DEPLOY_HOOK" ]]; then
    lib_print_kv "Deploy hook" "${C_GRN}installed${C_RST} (hands a renewed certificate to the servers)"
  else
    auto_ok=0; lib_print_kv "Deploy hook" "${C_RED}missing${C_RST}: a renewed certificate would never reach the servers"
  fi
  if [[ -f "$LE_LOG" ]]; then
    lib_print_kv "certbot last ran" "$(date -r "$LE_LOG" '+%Y-%m-%d %H:%M' 2>/dev/null || printf 'unknown')"
  else
    lib_print_kv "certbot last ran" "never (no ${LE_LOG})"
  fi
  if (( ! auto_ok )); then fails+=1; fixes+=("${me} ssl fix"); fi

  printf '\n'
  if (( fails + warns == 0 && have == 0 )); then
    lib_info "There is no certificate on this server yet. Renewal is set up and will look after the ones that come."
  elif (( fails + warns == 0 )); then
    lib_ok "Nothing to put right: every certificate is valid and renews by itself"
  else
    lib_warn "${fails} problem(s), ${warns} warning(s). To put right:"
    printf '%s\n' "${fixes[@]}" | awk '!seen[$0]++ { print "        " $0 }' >&2
  fi
  if (( sites > 0 )); then
    if (( untrusted == 0 && auto_ok )); then
      lib_note "Cloudflare: every site has a certificate it accepts, so SSL/TLS mode Full (strict) is safe."
    elif (( untrusted == 0 )); then
      lib_note "Cloudflare: every site has a certificate it accepts today, but nothing renews them. Put that right before Full (strict)."
    else
      lib_note "Cloudflare: ${untrusted} of ${sites} site(s) would answer 526 under Full (strict). Stay on Full until this list is clean."
    fi
  fi
  if (( without > 0 )); then
    lib_note "A certificate for every site that has none, in one go: ${me} renew-ssl --missing"
  fi
  (( have == 0 )) || lib_note "To rehearse a renewal without replacing anything: ${me} ssl test"
  unset -f _ssl_count
  (( fails == 0 ))
}

lib_ssl_test_main() {
  (($# == 0)) || lib_die "Unknown option for ssl test: ${1}" "" "ssl test"
  lib_require_installed
  lib_have certbot || lib_die "certbot is not installed" "" "$(lib_self_cmd) install"
  if ! compgen -G "${LE_RENEWAL}/*.conf" >/dev/null 2>&1; then
    lib_info "No certificate to renew yet"
    return 0
  fi
  lib_info "Rehearsing the renewal of every certificate (certbot renew --dry-run); nothing is replaced"
  if certbot renew --dry-run --no-random-sleep-on-renew; then
    lib_ok "Every certificate would renew"
  else
    lib_die "At least one certificate would not renew" "see certbot's lines above and ${LE_LOG}" "fix what it names (DNS, port 80, the Cloudflare token), then: $(lib_self_cmd) ssl test"
  fi
}

lib_ssl_fix_main() {
  (($# == 0)) || lib_die "Unknown option for ssl fix: ${1}" "" "ssl fix"
  lib_require_tools
  lib_require_installed
  lib_have certbot || lib_die "certbot is not installed" "" "$(lib_self_cmd) install"
  (( OPT_DRY_RUN )) && lib_info "[dry-run] would write ${CERTBOT_DEPLOY_HOOK} and enable certbot.timer (a cron entry where it will not start)"
  lib_ssl_hook_install
  lib_ssl_renewal_ensure
  (( OPT_DRY_RUN )) && return 0
  case "$(lib_ssl_renewal_how)" in
    timer) lib_ok "Automatic renewal is on: certbot.timer runs certbot twice a day" ;;
    cron)  lib_ok "Automatic renewal is on: cron runs certbot twice a day (${CRON_FILE})" ;;
    *)     lib_die "Automatic renewal could not be switched on" "certbot.timer does not start and cron is not running" "systemctl status certbot.timer cron" ;;
  esac
}
