#!/usr/bin/env bash
# lib/rename.sh - a site under another name ("rename"), and a name that does nothing but send
#                 its visitors on to another one ("redirect").

# ---- the redirect lib_redirect_load read --------------------------------------
R_DOMAIN="" R_TARGET="" R_WWW=0

# =============================================================================
#  Redirects
# =============================================================================
# A redirect is not a site: no Linux user, no home, no files, no database. Its record is a
# redirect.json in the state directory of its name, and never a domain.json beside it, so
# nothing that walks the sites (lib_domains_list) meets it. The directory is the one a site of
# that name would have, on purpose: the certbot deploy hook copies a renewed certificate for
# every lineage that has one, and the name's own certificate is what the redirect answers
# HTTPS with. Its virtual host carries the name itself, the way a site's does.
lib_redirect_file()   { printf '%s/redirect.json' "$(lib_domain_state_dir "$1")"; }
lib_redirect_exists() { lib_domain_valid "$1" && [[ -s "$(lib_redirect_file "$1")" ]]; }

lib_redirects_list() {   # one per line
  local f=""
  [[ -d "$STATE_DIR/domains" ]] || return 0
  for f in "$STATE_DIR"/domains/*/redirect.json; do
    [[ -s "$f" ]] || continue
    basename "$(dirname "$f")"
  done
  return 0
}

lib_redirect_load() {   # domain -> R_* ; status 1 when there is no such redirect
  local f=""
  R_DOMAIN="" R_TARGET="" R_WWW=0
  lib_domain_valid "$1" || return 1
  f="$(lib_redirect_file "$1")"
  [[ -s "$f" ]] || return 1
  R_DOMAIN="$1"
  R_TARGET="$(lib_json_get "$f" '.target')"
  R_WWW="$(_d_bool "$(lib_json_get "$f" '.www')")"
  [[ -n "$R_TARGET" ]]
}

lib_redirect_save() {   # domain target www(0/1)
  local f="" dir="" created=""
  f="$(lib_redirect_file "$1")"; dir="$(dirname "$f")"
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would record that ${1} redirects to ${2}"; return 0; fi
  created="$(lib_json_get "$f" '.created_at')"
  mkdir -p "$dir" && chmod 0700 "$dir"
  jq -n --arg d "$1" --arg t "$2" --argjson www "$(_d_json_bool "$3")" --arg c "${created:-$(lib_iso_now)}" --arg ts "$(lib_iso_now)" \
    '{domain:$d, kind:"redirect", target:$t, www:$www, created_at:$c, updated_at:$ts}' >"${f}.new"
  chmod 0600 "${f}.new" && mv -f "${f}.new" "$f"
}

# The redirects that lead to a name, one per line.
lib_redirects_to() {   # target
  local d=""
  while read -r d; do
    [[ -n "$d" ]] || continue
    [[ "$(lib_json_get "$(lib_redirect_file "$d")" '.target')" == "$1" ]] && printf '%s\n' "$d"
  done < <(lib_redirects_list)
  return 0
}

# Where a redirect sends its visitors: the address the target answers under itself, so that
# nobody is sent on twice. A site of this server is asked - HTTPS only once it has a
# certificate, www in front when that is its main name; any other name gets https://.
lib_redirect_target_url() {   # target
  local t="$1" f="" scheme="https" host="$1"
  f="$(lib_domain_json "$t")"
  if [[ -s "$f" ]]; then
    [[ "$(lib_json_get "$f" '.ssl.enabled')" == "true" ]] || scheme="http"
    if [[ "$(lib_json_get "$f" '.www')" == "true" && "$(lib_json_get "$f" '.www_primary')" == "true" ]]; then host="www.${t}"; fi
  fi
  printf '%s://%s' "$scheme" "$host"
}

lib_redirect_render_vhost_block() {   # domain
  cat <<EOF
virtualhost ${1} {
  vhRoot                  ${OLS_DEFAULT_ROOT}/
  configFile              conf/vhosts/${1}/vhconf.conf
  allowSymbolLink         0
  enableScript            0
  restrained              1
  setUIDMode              0
}
EOF
}

# The redirect in R_*. Everything but the ACME challenge goes on to the target, path and query
# string kept; the challenge stays, because the name's own certificate is renewed through it.
lib_redirect_render_vhconf() {
  local url=""; url="$(lib_redirect_target_url "$R_TARGET")"
  cat <<EOF
# Managed by lompstack - ${R_DOMAIN} only sends its visitors on to ${R_TARGET}; regenerated on every change.
docRoot                   \$VH_ROOT/html/
vhDomain                  ${R_DOMAIN}
EOF
  (( R_WWW )) && printf 'vhAliases                 www.%s\n' "$R_DOMAIN"
  cat <<EOF
enableGzip                0

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
RewriteRule ^(.*)\$ ${url}\$1 [R=301,L]
  END_rules
}
EOF
  if lib_ssl_deployed "$R_DOMAIN"; then
    printf '\n'
    lib_ols_render_vhssl "${SSL_DEPLOY_DIR}/${R_DOMAIN}/privkey.pem" "${SSL_DEPLOY_DIR}/${R_DOMAIN}/fullchain.pem" 1
  fi
  return 0
}

# Virtual host and listener maps of one redirect, tested and reloaded as one change set.
# "reload" asks for the reload even when no file changed: a certificate replaced under the
# same path is one OpenLiteSpeed only reads when it starts.
lib_redirect_apply() {   # domain [reload]
  local d="$1" reload="${2:-}" dir="${LSWS_VHOSTS_DIR}/${1}" maps="$1"
  lib_redirect_load "$d" || return 1
  lib_ols_is_installed || lib_die "OpenLiteSpeed is not installed on this server" \
    "${LSWS_CONF} is missing, so there is no configuration to add ${d} to" "run 'lomp install' first, then retry"
  (( R_WWW )) && maps="${d}, www.${d}"
  lib_ols_change_begin
  lib_mkdir "$dir" 0750 lsadm:lsadm
  lib_redirect_render_vhconf | lib_write_file "${dir}/vhconf.conf" 0640 lsadm:lsadm
  if (( LIB_FILE_CHANGED )) || [[ -n "$reload" ]]; then OLS_PENDING_RELOAD=1; fi
  lib_ols_tx_begin
  lib_redirect_render_vhost_block "$d" | lib_ols_tx_block_put virtualhost "$d"
  lib_ols_tx_map_set "$OLS_LISTENER_HTTP"  "$d" "$maps"
  lib_ols_tx_map_set "$OLS_LISTENER_HTTPS" "$d" "$maps"
  lib_ols_tx_commit
  lib_ols_change_commit "redirect ${d} -> ${R_TARGET}"
  return 0
}

# A site got its certificate, lost it, or changed which of its names is the main one: the
# redirects that lead to it follow. Called by lib_domain_apply_config; does not touch D_*.
lib_redirect_sync_target() {   # site
  local d="" f=""
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_redirect_load "$d" || continue
    f="${LSWS_VHOSTS_DIR}/${d}/vhconf.conf"
    if [[ -f "$f" ]] && lib_redirect_render_vhconf | cmp -s - "$f"; then continue; fi
    lib_redirect_apply "$d"
  done < <(lib_redirects_to "$1")
  return 0
}

# A certificate that covers every name of the redirect in R_*, deployed. 0 = it is there.
# SSL_OBTAINED says whether this call is what put it there.
lib_redirect_ssl_ensure() {
  local rc=0
  local -a names=("$R_DOMAIN")
  SSL_OBTAINED=0
  (( R_WWW )) && names+=("www.${R_DOMAIN}")
  if lib_ssl_deployed "$R_DOMAIN" && lib_ssl_cert_covers "$R_DOMAIN" "${names[@]}"; then return 0; fi
  lib_ssl_dns_check "$R_DOMAIN" "$R_WWW" || rc=$?
  if (( rc == 1 )); then SSL_LAST_ERROR="its DNS does not point to this server (${SSL_LAST_ERROR})"; return 1; fi
  lib_ssl_obtain_names "$R_DOMAIN" "${names[@]}" || return 1
  SSL_OBTAINED=1
  return 0
}

lib_redirect_usage() {
  if [[ "${LIB_LANG:-en}" == "tr" ]]; then
    cat <<'EOF'
Kullanım: setup.sh redirect <komut>
  add <kimden> <nereye> [--www] [--no-ssl]   <kimden> için gelen her isteği 301 ile <nereye>
                                       adresine gönderir; yol ve sorgu korunur. <kimden> bir
                                       site değildir: kullanıcısı ve dosyası olmaz, yalnızca
                                       kendi sertifikası olur. --www, www.<kimden> adını da
                                       alır. <kimden> alan adının DNS kaydı buraya yönlendikten
                                       sonra yeniden çalıştırılırsa sertifikayı alır
  list                                 Yönlendirmeler ve nereye gittikleri
  del <kimden> [--keep-ssl]            <kimden> için yanıt vermeyi bırakır
Bir siteyi başka bir ada taşıyıp geride yönlendirme bırakmak için: setup.sh rename <eski> <yeni>
EOF
    return 0
  fi
  cat <<'EOF'
Usage: setup.sh redirect <command>
  add <from> <to> [--www] [--no-ssl]   Send every request for <from> on to <to> with a 301,
                                       path and query string kept. <from> is no site: it gets
                                       no user and no files, only a certificate of its own.
                                       --www takes www.<from> along. Run it again after the
                                       DNS of <from> moved here, and it fetches the certificate
  list                                 The redirects and where they lead
  del <from> [--keep-ssl]              Stop answering for <from>
To move a site to another name and leave a redirect behind: setup.sh rename <old> <new>
EOF
}

lib_redirect_add() {
  local from="${1:-}" to="${2:-}" www=0 ssl=1 a="" isnew=1 f=""
  if [[ -z "$from" || -z "$to" || "$from" == -* || "$to" == -* ]]; then
    lib_redirect_usage >&2; lib_die "Two names are needed: the one that redirects and where to" "" "setup.sh redirect add old-name.com example.com"
  fi
  shift 2
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --www)    www=1 ;;
      --no-ssl) ssl=0 ;;
      *)        lib_redirect_usage >&2; lib_die "Unknown option for redirect add: ${a}" "" "see the usage above" ;;
    esac
  done
  from="${from,,}"; to="${to,,}"
  lib_require_tools
  lib_require_installed
  lib_domain_valid "$from" || lib_die "Invalid domain name '${from}'" "not a valid FQDN (use the bare domain, without http:// or paths)" "setup.sh redirect add old-name.com example.com"
  lib_domain_valid "$to"   || lib_die "Invalid domain name '${to}'" "the target is a domain name, without http:// or paths" "setup.sh redirect add ${from} example.com"
  [[ "$from" != www.* ]] || lib_die "Use the bare name and --www instead of ${from}" "" "setup.sh redirect add ${from#www.} ${to} --www"
  [[ "$from" != "$to" && "www.${from}" != "$to" ]] || lib_die "${from} cannot redirect to itself" "" "setup.sh redirect add ${from} another-name.com"
  if lib_domain_registered "$from"; then
    lib_die "${from} is a site of this server" "a redirect answers for the whole name, and the site does that now" \
      "to move the site to ${to} and leave a redirect behind: setup.sh rename ${from} ${to}"
  fi
  if lib_redirect_exists "$to"; then
    lib_die "${to} is itself only a redirect" "it sends its visitors on to $(lib_json_get "$(lib_redirect_file "$to")" '.target')" "redirect ${from} to that name instead"
  fi
  f="$(lib_redirect_file "$from")"
  [[ -s "$f" ]] && isnew=0
  lib_rollback_clear
  if (( isnew && ! OPT_DRY_RUN )); then lib_rollback_push "rm -f '${f}'; rmdir '$(dirname "$f")' 2>/dev/null"; fi
  lib_redirect_save "$from" "$to" "$www"
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would add the virtual host that sends ${from} on to $(lib_redirect_target_url "$to")"; return 0; fi
  lib_redirect_apply "$from"
  lib_rollback_clear
  if (( ssl )); then
    if lib_redirect_ssl_ensure; then
      # with "reload" only when the files changed under a path the virtual host already named
      if (( SSL_OBTAINED )); then lib_redirect_apply "$from" reload; else lib_redirect_apply "$from"; fi
    else
      lib_warn "No certificate for ${from}: ${SSL_LAST_ERROR}"
      lib_note "It redirects over HTTP only until then. Once its DNS points here: setup.sh redirect add ${from} ${to}$( (( www )) && printf ' --www')"
    fi
  fi
  lib_redirect_load "$from"
  lib_ols_smoke_test "$from" "301" || lib_warn "${from} does not answer with a redirect yet (${OLS_TEST_OUTPUT})"
  lib_manifest_set '.updated_at' "$(lib_iso_now)"
  lib_ok "${from}$( (( www )) && printf ' and www.%s' "$from") now go to $(lib_redirect_target_url "$to")$( lib_ssl_deployed "$from" && printf ' (HTTPS too)' || printf ' (HTTP only)')"
  return 0
}

lib_redirect_list() {
  local d="" n=0 ssl=""
  lib_require_tools
  lib_tprintf '%s%-30s %-34s %-24s%s\n' "$C_BLD" "FROM" "TO" "SSL" "$C_RST"
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_redirect_load "$d" || continue
    ssl="$(lib_ssl_deployed "$d" && lib_ssl_status_line "$d" || printf -- '-')"
    printf '%-30s %-34s %-24s\n' "${d}$( (( R_WWW )) && printf ' (+www)')" "$(lib_redirect_target_url "$R_TARGET")" "${ssl:0:24}"
    n=$((n + 1))
  done < <(lib_redirects_list)
  if (( n == 0 )); then
    lib_tr "(no redirects - add one with: setup.sh redirect add old-name.com example.com)"
    printf '%s\n' "$LIB_TR"
  fi
  return 0
}

lib_redirect_del() {
  local from="${1:-}" keep_ssl=0 a="" dir=""
  [[ -n "$from" && "$from" != -* ]] || { lib_redirect_usage >&2; lib_die "Which redirect?" "" "setup.sh redirect list"; }
  shift
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --keep-ssl) keep_ssl=1 ;;
      *)          lib_die "Unknown option for redirect del: ${a}" "" "redirect del <from> [--keep-ssl]" ;;
    esac
  done
  from="${from,,}"
  lib_require_tools
  # before anything is built from the name: what goes at the end is a directory named after it
  lib_domain_valid "$from" || lib_die "Invalid domain name '${from}'" "" "setup.sh redirect list"
  lib_redirect_load "$from" || lib_die "No redirect called ${from}" "" "setup.sh redirect list"
  lib_confirm "Stop sending ${from} on to ${R_TARGET}?" n || lib_die "Nothing was changed" "" "re-run with --yes to skip the question"
  lib_rollback_clear
  lib_ols_vhost_purge "$from" 1
  if (( keep_ssl )); then lib_info "certificate kept (--keep-ssl)"; else lib_ssl_delete "$from"; fi
  dir="$(lib_domain_state_dir "$from")"
  lib_rm "$(lib_redirect_file "$from")" "${dir}/ssl.info"
  if (( ! OPT_DRY_RUN )); then rmdir "$dir" 2>/dev/null || true; fi
  lib_manifest_set '.updated_at' "$(lib_iso_now)"
  lib_ok "${from} no longer redirects; this server answers it like any name it does not know"
  return 0
}

lib_redirect_main() {
  local sub="${1:-list}"
  shift || true
  case "$sub" in
    add)                lib_redirect_add "$@" ;;
    list|--list)        lib_redirect_list ;;
    del|delete|remove)  lib_redirect_del "$@" ;;
    help|-h|--help)     lib_redirect_usage ;;
    *)                  lib_redirect_usage >&2; lib_die "Unknown redirect command: ${sub}" "" "setup.sh redirect help" ;;
  esac
}

# =============================================================================
#  rename
# =============================================================================
lib_domain_rename_usage() {
  # a usage text is no single message lib/lang.sh could look up: it has its Turkish here
  if [[ "${LIB_LANG:-en}" == "tr" ]]; then
    cat <<'EOF'
Kullanım: setup.sh rename <eski-alan-adı> <yeni-alan-adı> [seçenekler]
  Site olduğu gibi yeni ada taşınır: dosyaları (/home/<eski>, /home/<yeni> olur; hiçbir şey
  kopyalanmaz), logları, Linux kullanıcısı, ayarları. Veritabanı adını ve şifresini korur.
  Yeni ad kendi sertifikasını alır; WordPress ise veritabanındaki adresler yeniden yazılır.
  Eski ad sertifikasını korur ve her isteği 301 ile yeni ada gönderir. Önce bir güvenlik
  yedeği alınır; site yaklaşık bir dakika kapalı kalır.
  Node.js uygulaması yeni kullanıcıyla yeniden kurulur (bağımlılıklar, derleme, PM2).
  Posta kutuları postaları ve şifreleriyle yeni alan adına taşınır; her eski adres yenisinin
  takma adı olur: ona gelen posta yine ulaşır, giriş ise artık yeni adresle yapılır.
  Alan adı olmayan bir adla kayıtlı site de ("shop_old": eski bir geri yükleme böyle kayıtlar
  bırakırdı) alan adını bu yolla alır. O adla kimse gelemeyeceği için geride yönlendirme
  bırakılmaz; WordPress ise veritabanının verdiği ad yeniden yazılır.
  --no-redirect        Eski adı yönlendirme olarak bırakma (sertifikası da silinir)
  --no-ssl             Yeni ad için şimdi sertifika isteme (sonra: renew-ssl)
  --no-search-replace  WordPress veritabanındaki adresleri olduğu gibi bırak
  --keep-mail          Posta kutularını taşımak yerine eski alan adında bırak
EOF
    return 0
  fi
  cat <<'EOF'
Usage: setup.sh rename <old-domain> <new-domain> [options]
  The site moves to the new name as it is: its files (/home/<old> becomes /home/<new>, nothing
  is copied), its logs, its Linux user, its settings. The database keeps its name and its
  password. The new name gets a certificate of its own, and a WordPress has the addresses in
  its database rewritten. The old name keeps its certificate and sends every request on to
  the new one with a 301. A safety backup is taken first; the site is away for about a minute.
  A Node.js application is set up again under the new user (dependencies, build, PM2).
  Mailboxes move to the new domain with their mail and their passwords, and every old address
  becomes an alias of its new one: mail to it still arrives, and people sign in with the new
  address from then on.
  A site that is registered under a name which is no domain name ("shop_old": an old restore
  made such) gets its domain name this way too. Nothing could ever ask for such a name, so no
  redirect is left under it, and a WordPress has the name its database gives rewritten.
  --no-redirect        Do not keep the old name as a redirect (its certificate goes too)
  --no-ssl             Do not request a certificate for the new name now (renew-ssl later)
  --no-search-replace  Leave the addresses inside a WordPress database as they are
  --keep-mail          Leave the mailboxes at the old domain instead of moving them
EOF
}

# Why this site cannot move to that name, as one line; nothing when it can. The site is in D_*.
_domain_rename_blocker() {   # old new
  local old="$1" new="$2" ni="" p=""
  ni="$(lib_domain_ident "$new")"
  if lib_domain_registered "$new"; then printf '%s is a site of this server already' "$new"; return 0; fi
  if lib_redirect_exists "$new"; then
    printf '%s only redirects to %s here (setup.sh redirect del %s)' "$new" "$(lib_json_get "$(lib_redirect_file "$new")" '.target')" "$new"; return 0
  fi
  for p in "$(lib_domain_state_dir "$new")" "$(lib_domain_home "$new")" "$(lib_domain_log_dir "$new")" "${LSWS_VHOSTS_DIR}/${new}"; do
    if [[ -e "$p" || -L "$p" ]]; then printf '%s is in the way: something of that name was here before' "$p"; return 0; fi
  done
  if [[ "$D_HOME" != "$(lib_domain_home "$old")" || ! -d "$D_HOME" || -L "$D_HOME" ]]; then
    printf 'the home of %s is not the directory %s' "$old" "$(lib_domain_home "$old")"; return 0
  fi
  if [[ "$D_USER" != "$D_IDENT" || "$D_GROUP" != "$D_IDENT" ]]; then
    printf 'the site runs as %s:%s, not as the user lomp named after it (%s)' "$D_USER" "$D_GROUP" "$D_IDENT"; return 0
  fi
  # And that user has to be this site's own. A record that names another site's account - a
  # restore that was refused used to leave one behind - passes every test above as soon as a
  # directory of its name exists, and renaming "its" user would take the account, and whatever
  # runs as it, away from the site it belongs to.
  if lib_domain_account_foreign "$old"; then
    printf "it is on record as running as %s, and that account's home is %s: another site's (setup.sh remove %s puts such a record away)" \
      "$D_USER" "$(getent passwd "$D_USER" | cut -d: -f6)" "$old"; return 0
  fi
  if [[ "$ni" != "$D_IDENT" ]]; then
    if id -u "$ni" >/dev/null 2>&1; then printf 'a Linux user called %s exists already' "$ni"; return 0; fi
    if getent group "$ni" >/dev/null 2>&1; then printf 'a Linux group called %s exists already' "$ni"; return 0; fi
  fi
  return 0
}

# Nothing of that user may still run when its name changes: usermod refuses otherwise.
_domain_rename_quiet_user() {   # user
  local u="$1" i=0
  id -u "$u" >/dev/null 2>&1 || return 0
  pkill -u "$u" >/dev/null 2>&1 || true
  for (( i = 0; i < 20; i++ )); do
    pgrep -u "$u" >/dev/null 2>&1 || return 0
    if (( i == 10 )); then pkill -KILL -u "$u" >/dev/null 2>&1 || true; fi
    sleep 0.5
  done
  ! pgrep -u "$u" >/dev/null 2>&1
}

# The state file of the site under its new name: who it is and where it lives. The certificate
# was the old name's, and so were the backups its record points at.
_domain_rename_state() {   # file new ident home old
  local tmp=""
  tmp="$(lib_mktemp)"
  jq --arg d "$2" --arg i "$3" --arg h "$4" --arg old "$5" --arg ts "$(lib_iso_now)" \
    '.domain = $d | .ident = $i | .user = $i | .group = $i | .home = $h
     | .ssl.enabled = false | del(.ssl.expires) | del(.ssl.cert_name) | del(.ssl.updated_at)
     | del(.backup) | .renamed_from = $old | .renamed_at = $ts' "$1" >"$tmp" || return 1
  chmod 0600 "$tmp" && mv -f "$tmp" "$1"
}

# User, home, logs and state from the old name to the new one. The site is in D_* (old name)
# and is not served: its virtual host is gone and nothing runs as its user. Every step is a
# rename in place - the uid does not change, so no file changes its owner.
_domain_rename_move() {   # old new
  local old="$1" new="$2" oi="$D_IDENT" ni="" oh="$D_HOME" nh="" cron="/var/spool/cron/crontabs"
  ni="$(lib_domain_ident "$new")"; nh="$(lib_domain_home "$new")"
  if [[ "$ni" != "$oi" ]]; then
    lib_run groupmod -n "$ni" "$oi" || lib_die "Could not rename the group ${oi} to ${ni}" "" "see the log"
    lib_run usermod -l "$ni" "$oi" || lib_die "Could not rename the user ${oi} to ${ni}" "something still runs as ${oi}" "see the log"
    if [[ -f "${cron}/${oi}" && ! -e "${cron}/${ni}" ]]; then mv -- "${cron}/${oi}" "${cron}/${ni}" || true; fi
  fi
  lib_run usermod -d "$nh" -c "site ${new}" "$ni" || lib_die "Could not point the user ${ni} at ${nh}" "" "see the log"
  mv -T -- "$oh" "$nh" || lib_die "Could not move ${oh} to ${nh}" "" "see the log"
  if [[ -d "$(lib_domain_log_dir "$old")" && ! -L "$(lib_domain_log_dir "$old")" ]]; then
    mv -T -- "$(lib_domain_log_dir "$old")" "$(lib_domain_log_dir "$new")" || lib_die "Could not move the logs of ${old}" "" "see the log"
  fi
  mv -T -- "$(lib_domain_state_dir "$old")" "$(lib_domain_state_dir "$new")" || lib_die "Could not move the state of ${old}" "" "see the log"
  _domain_rename_state "$(lib_domain_json "$new")" "$new" "$ni" "$nh" "$old" || lib_die "Could not rewrite the state of ${new}" "" "inspect $(lib_domain_json "$new")"
  # written again for the new name by whatever renders its virtual host
  lib_rm "$(lib_harden_php_ini_dir "$old")" "${OLS_CACHE_DIR}/${old}"
  return 0
}

# Rollback: the site back under its old name, from wherever the run stopped. Each part looks
# at what is there before it acts, so it undoes half a move as well as a whole one.
_domain_rename_undo() {   # old new saved-domain.json had-wpcron(0/1)
  local old="$1" new="$2" saved="$3" wpcron="${4:-0}" oi="" ni="" oh="" nh=""
  oi="$(lib_json_get "$saved" '.user')"; ni="$(lib_domain_ident "$new")"
  oh="$(lib_domain_home "$old")"; nh="$(lib_domain_home "$new")"
  [[ -n "$oi" ]] || return 1
  # in a subshell: a lib_die in there must not end the rest of this
  if lib_ols_conf_block_exists virtualhost "$new"; then ( lib_ols_vhost_purge "$new" 0 ) || true; fi
  rm -rf -- "${LSWS_VHOSTS_DIR:?}/${new}"
  _domain_rename_quiet_user "$ni" || true
  if [[ -d "$(lib_domain_state_dir "$new")" && ! -e "$(lib_domain_state_dir "$old")" ]]; then
    mv -T -- "$(lib_domain_state_dir "$new")" "$(lib_domain_state_dir "$old")"
  fi
  cp -f "$saved" "$(lib_domain_json "$old")" && chmod 0600 "$(lib_domain_json "$old")"
  if [[ -d "$nh" && ! -e "$oh" ]]; then mv -T -- "$nh" "$oh"; fi
  if [[ -d "$(lib_domain_log_dir "$new")" && ! -e "$(lib_domain_log_dir "$old")" ]]; then
    mv -T -- "$(lib_domain_log_dir "$new")" "$(lib_domain_log_dir "$old")"
  fi
  if [[ "$ni" != "$oi" ]]; then
    if id -u "$ni" >/dev/null 2>&1 && ! id -u "$oi" >/dev/null 2>&1; then usermod -l "$oi" "$ni"; fi
    if getent group "$ni" >/dev/null 2>&1 && ! getent group "$oi" >/dev/null 2>&1; then groupmod -n "$oi" "$ni"; fi
  fi
  usermod -d "$oh" -c "site ${old}" "$oi"
  rm -rf -- "$(lib_harden_php_ini_dir "$new")" "${OLS_CACHE_DIR:?}/${new}"
  lib_domain_state_load "$old" || return 1
  lib_domain_logs_link
  if [[ "$D_MODE" == "wordpress" ]]; then lib_mkdir "${OLS_CACHE_DIR}/${old}" 0750 "$(lib_ols_user):$(lib_ols_group)"; fi
  lib_domain_apply_config "put ${old} back"
  if (( wpcron )); then lib_domain_wpcron_set; fi
  # its PM2 service was taken down under the old name, and nothing was built under the new one
  if lib_app_state_load "$old"; then lib_app_apply; _app_jobs_sync; fi
  lib_domain_logrotate_regen
  lib_domain_fail2ban_regen
  return 0
}

# The mail of a renamed site stays where it is. A mailbox is an address at the old domain: a
# new domain cannot take it over without every correspondent being told. So the old name
# becomes a mail domain of its own - the record "mail domain add" would have made, carrying
# the site's .mail block as it is (selectors, webmail, its mail identifier) - and the site
# under its new name starts without mail - until _domain_rename_mail_move, unless --keep-mail,
# brings the mailboxes over. Sets RENAME_MAIL_KEPT when there was mail to keep, and
# RENAME_MAIL_DETACHED when this run is what made the record.
_domain_rename_mail_detach() {   # old new
  local old="$1" sf="" mf=""
  sf="$(lib_domain_json "$2")"
  RENAME_MAIL_KEPT=0; RENAME_MAIL_DETACHED=0
  [[ "$(jq -r 'has("mail")' "$sf" 2>/dev/null || true)" == "true" ]] || return 0
  if lib_mail_domain_standalone "$old"; then
    RENAME_MAIL_KEPT=1   # it had a record of its own all along, and that one counts
  elif lib_mail_domain_has_traces "$old"; then
    mf="$(lib_mail_domain_file "$old")"
    mkdir -p "$(dirname "$mf")" && chmod 0700 "$(dirname "$mf")" || return 1
    jq --arg d "$old" --arg ts "$(lib_iso_now)" '{domain: $d, kind: "mail", created_at: $ts, mail: (.mail // {})}' "$sf" >"${mf}.new" || return 1
    chmod 0600 "${mf}.new" && mv -f "${mf}.new" "$mf" || return 1
    RENAME_MAIL_KEPT=1; RENAME_MAIL_DETACHED=1
    lib_log_write INFO "the mail of ${old} is a mail domain of its own now (the site was renamed to ${2})"
  fi
  lib_json_set "$sf" 'del(.mail)'
}

# ---- the mailboxes follow the site ------------------------------------------------------
# The targets of an alias, with every address of the old domain that has moved - a mailbox, or
# an alias that is copied - named at the new one. "moved" is those addresses, one per line.
_domain_rename_mail_targets() {   # targets old new moved
  local t="" out=""
  local -a list=()
  IFS=',' read -r -a list <<<"${1// /}"
  for t in ${list[@]+"${list[@]}"}; do
    [[ -n "$t" ]] || continue
    if [[ "${t#*@}" == "$2" ]] && grep -qxF -- "$t" <<<"$4"; then t="${t%%@*}@${3}"; fi
    out+="${out:+,}${t}"
  done
  printf '%s' "$out"
}

# One mailbox to the new domain: its mail, and a line for the new address with the password
# hash and the quota it had. The line of the old address stays for now - see below.
_domain_rename_box_move() {   # user@old new-domain
  local a="$1" nd="$2" loc="${1%%@*}" od="${1#*@}" na="" hash="" quota="" src="" dst=""
  na="${loc}@${nd}"
  src="${MAIL_VMAIL_HOME}/${od}/${loc}"; dst="${MAIL_VMAIL_HOME}/${nd}/${loc}"
  if lib_mail_box_exists "$na"; then MAIL_LAST_ERROR="${na} exists already"; return 1; fi
  if [[ -e "$dst" || -L "$dst" ]]; then MAIL_LAST_ERROR="${dst} is in the way"; return 1; fi
  hash="$(awk -F: -v u="$a" '$1 == u { print $2; exit }' "$MAIL_PASSWD_FILE")"
  [[ -n "$hash" ]] || { MAIL_LAST_ERROR="no password line for ${a}"; return 1; }
  quota="$(lib_mail_box_quota "$a")"
  if lib_have doveadm; then doveadm kick "$a" >/dev/null 2>&1 || true; fi
  if [[ -d "$src" && ! -L "$src" ]]; then
    if [[ ! -d "${MAIL_VMAIL_HOME}/${nd}" ]]; then
      mkdir -- "${MAIL_VMAIL_HOME}/${nd}" \
        && chown --reference="${MAIL_VMAIL_HOME}/${od}" "${MAIL_VMAIL_HOME}/${nd}" \
        && chmod --reference="${MAIL_VMAIL_HOME}/${od}" "${MAIL_VMAIL_HOME}/${nd}" \
        || { MAIL_LAST_ERROR="could not make ${MAIL_VMAIL_HOME}/${nd}"; return 1; }
    fi
    mv -T -- "$src" "$dst" || { MAIL_LAST_ERROR="could not move ${src}"; return 1; }
  fi
  lib_mail_passwd_set "$na" "$hash" "$quota"
  lib_mail_alias_set "$od" "$a" "$na"
}

# A message that reached the old address in the moment between the move of its mail and the
# alias taking effect was put into a mailbox made afresh under the old name. It goes on to
# the new one, and the leftover directory goes.
_domain_rename_box_sweep() {   # user@old new-domain
  local loc="${1%%@*}" od="${1#*@}" src="" dst="" f="" n=0
  src="${MAIL_VMAIL_HOME}/${od}/${loc}"; dst="${MAIL_VMAIL_HOME}/${2}/${loc}/Maildir/new"
  [[ -d "$src" && ! -L "$src" ]] || return 0
  if [[ -d "$dst" ]]; then
    while IFS= read -r -d '' f; do
      mv -n -- "$f" "${dst}/" && n=$((n + 1))
    done < <(find "${src}/Maildir/new" "${src}/Maildir/cur" -maxdepth 1 -type f -print0 2>/dev/null)
  fi
  if (( n > 0 )); then lib_log_write INFO "${n} message(s) that arrived for ${1} during the move went on to ${loc}@${2}"; fi
  if [[ -z "$(find "$src" -type f -path '*/Maildir/*' \( -path '*/new/*' -o -path '*/cur/*' \) -print -quit 2>/dev/null)" ]]; then rm -rf -- "$src"; fi
  return 0
}

# What the webmail keeps for a mailbox - address book, settings, identities - is kept under
# the name it signs in with. That name changes, so the row is renamed rather than left behind
# for whoever is given the old address one day.
_domain_rename_webmail_user() {   # user@old user@new
  local o="${1,,}" n="${2,,}"
  lib_mail_address_valid "$o" && lib_mail_address_valid "$n" || return 0
  _wm_info_load || return 0
  [[ -z "$(_wm_users "$n" || true)" ]] || return 0   # somebody signed in under the new name already
  [[ -n "$(_wm_users "$o" || true)" ]] || return 0
  lib_db_sql "UPDATE \`${WM_DB_NAME}\`.users SET username = '${n}' WHERE LOWER(username) = '${o}';
UPDATE \`${WM_DB_NAME}\`.identities i JOIN \`${WM_DB_NAME}\`.users u ON u.user_id = i.user_id SET i.email = '${n}' WHERE u.username = '${n}' AND LOWER(i.email) = '${o}';" >/dev/null 2>&1
}

# The mail of the old domain moves to the new one: every mailbox with its mail, its password
# and its quota, every alias with its targets. What is left at the old domain is one alias per
# address, pointing at the same address of the new domain - so mail to an old address still
# arrives, and the mailbox it arrives in may still send as it. The old domain stays a mail
# domain (it has to, to take that mail) with the DKIM key its earlier mail was signed with.
# Nothing is ever without a home on the way: the new address exists before the old one stops
# being a mailbox, and the old one is an alias by the time it stops. RENAME_MAIL_MOVED lists
# the new addresses. Status 1 with MAIL_LAST_ERROR when the new domain could not get mail at
# all: then nothing has moved.
_domain_rename_mail_move() {   # old new
  local old="$1" new="$2" boxes="" aliases="" catchall="" moved="" a="" t="" webmail=""
  RENAME_MAIL_MOVED=""
  lib_mail_domain_enabled "$old" || { MAIL_LAST_ERROR="the mail of ${old} is switched off"; return 1; }
  boxes="$(lib_mail_boxes "$old")"; aliases="$(lib_mail_aliases "$old")"; catchall="$(lib_mail_catchall "$old")"
  webmail="$(lib_json_get "$(lib_mail_json "$old")" '.mail.webmail')"
  # a subshell: it ends with lib_die when it cannot finish, and that must not end the rename
  ( lib_mail_enable_main "$new" --yes ) || true
  lib_mail_domain_enabled "$new" || { MAIL_LAST_ERROR="mail could not be switched on for ${new}"; return 1; }
  # what moves, so that a target at the old domain is named at the new one
  moved="$boxes"$'\n'"$(awk -F'\t' '{ print $1 }' <<<"$aliases")"
  while read -r a; do
    [[ -n "$a" ]] || continue
    if _domain_rename_box_move "$a" "$new"; then RENAME_MAIL_MOVED+="${RENAME_MAIL_MOVED:+ }${a%%@*}@${new}"
    else lib_warn "${a} stays a mailbox at ${old}: ${MAIL_LAST_ERROR}"; moved="$(grep -vxF -- "$a" <<<"$moved" || true)"; fi
  done <<<"$boxes"
  while IFS=$'\t' read -r a t; do
    [[ -n "$a" && -n "$t" ]] || continue
    lib_mail_alias_set "$new" "${a%%@*}@${new}" "$(_domain_rename_mail_targets "$t" "$old" "$new" "$moved")"
    lib_mail_alias_set "$old" "$a" "${a%%@*}@${new}"
  done <<<"$aliases"
  if [[ -n "$catchall" ]]; then
    t="$(_domain_rename_mail_targets "$catchall" "$old" "$new" "$moved")"
    lib_mail_alias_set "$new" "@${new}" "$t"
    lib_mail_alias_set "$old" "@${old}" "$t"
  fi
  lib_mail_tables_apply || lib_warn "The mail tables could not be rebuilt (${MAIL_LAST_ERROR}): setup.sh mail status"
  # the old addresses are aliases now, for Postfix too: their mailbox lines go, and whatever
  # arrived for them in between goes on
  for a in $RENAME_MAIL_MOVED; do
    a="${a%%@*}@${old}"
    awk -F: -v u="$a" '$1 != u' "$MAIL_PASSWD_FILE" | lib_write_file "$MAIL_PASSWD_FILE" 0640 root:dovecot secret
    _domain_rename_box_sweep "$a" "$new"
    ( _domain_rename_webmail_user "$a" "${a%%@*}@${new}" ) || true
  done
  lib_mail_tables_apply || lib_warn "The mail tables could not be rebuilt (${MAIL_LAST_ERROR}): setup.sh mail status"
  if [[ "$webmail" == "true" ]]; then
    ( lib_webmail_domain_enable "$new" ) >/dev/null 2>&1 \
      || lib_warn "The webmail of ${new} could not be set up; later: setup.sh mail webmail on ${new}"
  fi
  lib_log_write INFO "the mail of ${old} moved to ${new}: ${RENAME_MAIL_MOVED:-no mailbox}"
  return 0
}

# Does the site in D_* have mail that is the site's own - not a mail domain's?
_domain_rename_has_mail() {   # old
  ! lib_mail_domain_standalone "$1" && lib_mail_domain_has_traces "$1"
}

# Is there a WordPress in the site in D_*? Asked as the site user: the document root is its.
_domain_rename_has_wp() { lib_domain_as_user test -f "${D_HOME}/public_html/wp-config.php" 2>/dev/null; }

# The address pairs a WordPress database is rewritten with, "from<TAB>to" per line. Addresses
# only - "//name" - so that a mail address at the old domain stays what it is. The www form
# first; each also in the form JSON stores it in. Then the home directory, which plugins
# write into their options as an absolute path.
#
# The addresses are those of the name the database says, and that is the old name - unless the
# old name is no domain name. Such a name was never an address, and as a pattern it is worse
# than none: "//staging" is also how "//staging.example.com" begins. What the database of such
# a site says is the name WordPress gives as its own (_domain_rename_wp_said, handed in as the
# fourth argument): the addresses of that name are rewritten, and the home a site of that name
# has. None are where WordPress gave no name, or gives the new one already.
_domain_rename_wp_pairs() {   # old new www(0/1) [the name the database says, where the old one is none]
  local old="$1" new="$2" wnew="$2" said="$1"
  (( ${3:-0} )) && wnew="www.${2}"
  if ! lib_domain_valid "$old"; then
    said=""
    if lib_domain_valid "${4:-}"; then said="$4"; fi
  fi
  if [[ -n "$said" && "$said" != "$new" ]]; then
    printf '//www.%s\t//%s\n' "$said" "$wnew"
    printf '//%s\t//%s\n' "$said" "$new"
    printf '\\/\\/www.%s\t\\/\\/%s\n' "$said" "$wnew"
    printf '\\/\\/%s\t\\/\\/%s\n' "$said" "$new"
    if [[ "$said" != "$old" ]]; then printf '%s/\t%s/\n' "$(lib_domain_home "$said")" "$(lib_domain_home "$new")"; fi
  fi
  printf '%s/\t%s/\n' "$(lib_domain_home "$old")" "$(lib_domain_home "$new")"
}

# The domain name the WordPress in D_* gives as its own address, without a leading www.
# Nothing when it cannot be asked, when its "siteurl" and its "home" name two hosts, or when
# what they name is no domain name: a database is rewritten by this name, and a guess is none.
_domain_rename_wp_said() {
  local k="" v="" said=""
  for k in siteurl home; do
    v="$(_wp option get "$k" --skip-plugins --skip-themes 2>/dev/null | tail -n 1)" || return 0
    v="${v#*://}"; v="${v%%[/:?#]*}"; v="${v,,}"; v="${v#www.}"
    [[ -n "$v" && ( -z "$said" || "$v" == "$said" ) ]] || return 0
    said="$v"
  done
  lib_domain_valid "$said" || return 0
  printf '%s' "$said"
}

# The addresses inside the database of the WordPress in D_* (new name). Never fatal: the site
# has moved by now, and what is left over is said so that it can be done by hand.
_domain_rename_wp() {   # old new
  local old="$1" new="$2" a="" b="" failed=0 info="" nodom=0 said="$1" h="" from="//${1}" to="//${2}"
  local -a names=("$1")
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would rewrite ${old} to ${new} in the WordPress database"; return 0; fi
  lib_domain_valid "$old" || nodom=1
  if ! ( lib_domain_wpcli_ensure ) >/dev/null 2>&1 || [[ ! -x "$WPCLI_BIN" ]]; then
    if (( nodom )); then
      lib_warn "wp-cli could not be installed, so the WordPress database was not looked at: it may give another name than ${new} as its address"
      lib_note "Later: wp option get home - and if that is another name: wp search-replace '//that-name' '//${new}' --all-tables-with-prefix --skip-columns=guid   (as ${D_USER}, in ${D_HOME}/public_html)"
    else
      lib_warn "wp-cli could not be installed, so the WordPress database still says ${old}"
      lib_note "Later: wp search-replace '//${old}' '//${new}' --all-tables-with-prefix --skip-columns=guid   (as ${D_USER}, in ${D_HOME}/public_html)"
    fi
    return 0
  fi
  # A name that is no domain name was never an address. What the database of such a site says
  # is the name WordPress gives as its own - the one the site had where its archive was made.
  if (( nodom )); then
    said="$(_domain_rename_wp_said)"
    if [[ -n "$said" ]]; then names+=("$said"); fi
    if [[ -n "$said" && "$said" != "$new" ]]; then from="//${said}"; else from="$(lib_domain_home "$old")/"; to="$(lib_domain_home "$new")/"; fi
  fi
  while IFS=$'\t' read -r a b; do
    [[ -n "$a" ]] || continue
    lib_run _wp search-replace "$a" "$b" --all-tables-with-prefix --skip-columns=guid --skip-plugins --skip-themes --report-changed-only || failed=1
  done < <(_domain_rename_wp_pairs "$old" "$new" "$D_WWW" "$said")
  lib_run _wp cache flush --skip-plugins --skip-themes || true
  info="$(lib_domain_state_dir "$new")/wp.info"
  if [[ -s "$info" ]]; then
    for a in "${names[@]}"; do
      [[ "$a" != "$new" ]] || continue
      h="$(lib_domain_home "$a")"
      sed -i -e "s#//${a//./\\.}\$#//${new}#" -e "s#//www\\.${a//./\\.}\$#//www.${new}#" -e "s#=${h//./\\.}/#=$(lib_domain_home "$new")/#" "$info" || true
    done
  fi
  if (( failed )); then
    lib_warn "Not every address in the WordPress database could be rewritten (see ${LOG_FILE})"
    lib_note "Again: wp search-replace '${from}' '${to}' --all-tables-with-prefix --skip-columns=guid   (as ${D_USER}, in ${D_HOME}/public_html)"
  elif (( ! nodom )); then
    lib_ok "WordPress: the addresses in its database now say ${new}"
  elif [[ -z "$said" ]]; then
    lib_warn "WordPress did not say which address it has, so no address in its database was rewritten: ${old} itself never was one"
    lib_note "If it answers under another name than ${new}: wp search-replace '//that-name' '//${new}' --all-tables-with-prefix --skip-columns=guid   (as ${D_USER}, in ${D_HOME}/public_html)"
  elif [[ "$said" == "$new" ]]; then
    lib_ok "WordPress: its database gives ${new} as its address already"
  elif [[ "$(_domain_rename_wp_said)" == "$new" ]]; then
    lib_ok "WordPress: its database said ${said}; the addresses in it now say ${new}"
  else
    # asked again, because a name that is set outside the database is not reached by rewriting it
    lib_warn "WordPress does not give ${new} as its address, although its database was rewritten from ${said}"
    lib_note "The name is then set outside the database: look for WP_HOME and WP_SITEURL in ${D_HOME}/public_html/wp-config.php"
  fi
  return 0
}

# The pages OpenLiteSpeed's cache keeps for the site in D_* (new name). The first of them was
# asked for by this command itself, when it looked whether the site answers - before a single
# address in the database was rewritten - and LiteSpeed Cache keeps a page for days. Without
# this the renamed site went on handing out its front page as it was, every link and every
# stylesheet on it at the old address. The files go and the directory stays: OpenLiteSpeed is
# writing into it, and a page it stores from now on is made from the new addresses.
_domain_rename_cache_clear() {
  local dir="${OLS_CACHE_DIR:?}/${D_DOMAIN:?}"
  [[ -d "$dir" && ! -L "$dir" ]] || return 0
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would empty the page cache ${dir}"; return 0; fi
  if find "$dir" -mindepth 1 ! -type d -delete 2>>"$LOG_FILE"; then
    find "$dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    lib_ok "page cache emptied: no page from before the addresses changed is served any more"
  else
    lib_warn "The page cache ${dir} could not be emptied: pages cached before the addresses changed may still be served"
    lib_note "Purge it from WordPress (LiteSpeed Cache > Purge All), or empty that directory"
  fi
  return 0
}

# Configuration files of the site in D_* that still carry the old name - as an address or as
# the old home directory. Read as the site user, and only the files such a name is kept in.
_domain_rename_leftovers() {   # what to look for: the old name, or the forms its home is written in
  local -a dirs=("${D_HOME}/public_html") seek=()
  local p=""
  for p in "$@"; do seek+=(-e "$p"); done
  if [[ -d "${D_HOME}/app" ]]; then dirs+=("${D_HOME}/app"); fi
  lib_domain_as_user timeout 30 find "${dirs[@]}" -maxdepth 3 -name node_modules -prune -o -type f -size -1024k \
    \( -name .htaccess -o -name .user.ini -o -name wp-config.php -o -name .env -o -name 'config*.php' -o -name 'settings*.php' \) \
    -exec grep -lF "${seek[@]}" {} + 2>/dev/null | head -n 20 || true
}

lib_domain_rename_main() {
  local old="${1:-}" new="${2:-}" redirect=1 ssl=1 replace=1 a="" why="" rc=0 saved="" wpcron=0 oldssl=0 f="" total=7 left="" oi="" app=0 mail=0 nodom=0 oh="" what="" mailmove=1
  local -a seek=() greps=()
  if [[ "$old" == "-h" || "$old" == "--help" || "$old" == "help" ]]; then lib_domain_rename_usage; return 0; fi
  if [[ -z "$old" || -z "$new" || "$old" == -* || "$new" == -* ]]; then
    lib_domain_rename_usage >&2; lib_die "Two names are needed: the site and its new name" "" "setup.sh rename old-name.com new-name.com"
  fi
  shift 2
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --no-redirect)       redirect=0 ;;
      --no-ssl)            ssl=0 ;;
      --no-search-replace) replace=0 ;;
      --keep-mail)         mailmove=0 ;;
      *)                   lib_domain_rename_usage >&2; lib_die "Unknown option for rename: ${a}" "" "see the usage above" ;;
    esac
  done
  old="${old,,}"; new="${new,,}"
  lib_require_tools
  lib_require_installed
  # The site is taken by the name it is registered under, and "restore" registered sites under
  # whatever it was given until 1.0.87: "shop_old", "staging". This is how such a site gets
  # its domain name. What it becomes is a domain name, as for every other site.
  lib_domain_arg_ok "$old" || lib_die "Invalid domain name '${old}'" "" "setup.sh list"
  lib_domain_valid "$new" || lib_die "Invalid domain name '${new}'" "not a valid FQDN (use the bare domain, without http:// or paths)" "setup.sh rename ${old} new-name.com"
  [[ "$new" != www.* ]] || lib_die "Use the bare name instead of ${new}" "whether www.<name> is served is a setting the site keeps" "setup.sh rename ${old} ${new#www.}"
  [[ "$old" != "$new" ]] || lib_die "${old} is called that already" "" "setup.sh rename ${old} new-name.com"
  lib_domain_registered "$old" || lib_die "Site ${old} is not registered" "" "setup.sh list"
  # Nothing ever asked this server for a name that is no domain name, so there is nothing to
  # send on from it - and a redirect.json under it would be a record that "redirect list"
  # leaves out and "redirect del" refuses.
  if ! lib_domain_valid "$old"; then nodom=1; redirect=0; fi
  lib_ols_is_installed || lib_die "OpenLiteSpeed is not installed" "run install first" "sudo ./setup.sh install"
  lib_domain_state_load "$old"
  why="$(_domain_rename_blocker "$old" "$new")"
  [[ -z "$why" ]] || lib_die "${old} cannot be renamed to ${new}" "$why" "setup.sh list"
  oi="$D_IDENT"; oldssl="$D_SSL"
  if lib_app_state_load "$old"; then app=1; total=8; fi
  if _domain_rename_has_mail "$old"; then
    mail=1
    if (( mailmove )) && lib_mail_domain_enabled "$old"; then total=$((total + 1)); else mailmove=0; fi
  else
    mailmove=0
  fi
  (( D_SSL_WANTED )) || ssl=0

  lib_tr "This will rename the site ${old} to ${new}"
  printf '\n%s%s%s\n' "$C_BLD" "$LIB_TR" "$C_RST"
  lib_note "files    ${D_HOME} becomes $(lib_domain_home "$new") (moved, not copied); the Linux user ${D_USER} $( [[ "$(lib_domain_ident "$new")" == "$D_USER" ]] && printf 'keeps its name' || printf 'becomes %s' "$(lib_domain_ident "$new")")"
  lib_note "database ${D_DB_NAME:-none}$( [[ -n "$D_DB_NAME" ]] && printf ' keeps its name, its user and its password')"
  lib_note "HTTPS    $( (( ssl )) && printf 'a new certificate for %s' "$new" || printf 'no certificate is requested for %s now' "$new")"
  if (( nodom )); then lib_note "${old}  is no domain name, so nothing ever asked this server for it: nothing stays behind under it"
  elif (( redirect )); then lib_note "${old}  stays as a redirect: every request goes on to ${new} with a 301$( (( oldssl )) && printf ', under the certificate it has')"
  else lib_note "${old}  is no longer answered here, and its certificate is deleted (--no-redirect)"; fi
  if _domain_rename_has_wp; then
    lib_note "WordPress $( (( replace )) && printf 'the addresses in its database are rewritten to %s' "$new" || printf 'its database is left as it is (--no-search-replace)')"
  fi
  if (( app )); then
    lib_note "Node.js  its PM2 service is set up again under the new user: dependencies are installed again, the application is built and started"
  fi
  if (( mail )); then
    if (( mailmove )); then
      lib_note "mail     every mailbox moves to @${new} with its mail and its password; each address at @${old} becomes an alias of it"
      lib_note "         (people sign in with their new address from then on; --keep-mail leaves the mail where it is)"
    else
      lib_note "mail     stays at @${old}: every mailbox, alias and key as it is, ${old} becoming a mail domain of its own"
      lib_note "         (${new} starts without mail: setup.sh mail enable ${new})"
    fi
  fi
  lib_note "a safety backup is written to ${BACKUP_ROOT}/${old}/ first; the site is away for about a minute$( (( app )) && printf ', its application until it is built')"
  if (( ssl )); then
    lib_ssl_dns_check "$new" "$D_WWW" || rc=$?
    if (( rc == 1 )); then
      lib_warn "The DNS of ${new} does not point to this server yet: ${SSL_LAST_ERROR}"
      lib_note "It gets no certificate until it does, so it answers over HTTP only$( (( oldssl )) && printf ' - and a site that expects HTTPS (WordPress does) will not work properly until then')."
      lib_note "Better: point ${new}$( (( D_WWW )) && printf ' and www.%s' "$new") here first, then rename. Afterwards it would be: setup.sh renew-ssl ${new}"
    fi
  fi
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] nothing was changed"; return 0; fi
  lib_confirm "Continue?" n || lib_die "Rename cancelled" "" "re-run with --yes to skip the question"
  if (( app )); then _app_site_lock "$old"; fi   # not while a deploy of it is still running
  lib_steps_begin "$total"
  lib_rollback_clear
  lib_system_profile

  # ---- 1 safety backup -------------------------------------------------------
  lib_step "Safety backup of ${old}"
  lib_backup_domain "$old" --tag pre-rename --keep 0 --no-mail \
    || lib_die "The safety backup failed, so nothing was changed" "$BK_ERROR" "free some space under ${BACKUP_ROOT}, or see the log"
  lib_ok "safety backup written: ${BK_LAST_FILE}"
  lib_domain_state_load "$old"

  # ---- 2 off the air ---------------------------------------------------------
  lib_step "Taking ${old} off the air"
  saved="$(lib_mktemp)"
  cp -f "$(lib_domain_json "$old")" "$saved"
  if lib_cron_has "wpcron:${old}"; then wpcron=1; fi
  lib_rollback_push "_domain_rename_undo '${old}' '${new}' '${saved}' '${wpcron}'"
  lib_cron_remove "wpcron:${old}"
  lib_ols_vhost_purge "$old" 1
  # the PM2 service is named after the user and runs out of the home: both are about to change
  if (( app )); then lib_cron_remove_prefix "job:${old}:"; lib_app_teardown; fi
  _domain_rename_quiet_user "$D_USER" || lib_die "Processes of ${D_USER} are still running" "they did not stop when asked" "pgrep -u ${D_USER} -a"
  lib_ok "virtual host removed, nothing runs as ${D_USER}"

  # ---- 3 the move --------------------------------------------------------------
  lib_step "Moving the site to ${new}"
  _domain_rename_move "$old" "$new"
  lib_domain_state_load "$new"
  lib_domain_logs_link
  if [[ "$D_MODE" == "wordpress" ]]; then lib_mkdir "${OLS_CACHE_DIR}/${new}" 0750 "$(lib_ols_user):$(lib_ols_group)"; fi
  lib_ok "home ${D_HOME}, user ${D_USER}"

  # ---- 4 on the air again ------------------------------------------------------
  lib_step "OpenLiteSpeed virtual host for ${new}"
  lib_domain_apply_config "rename ${old} to ${new}"
  lib_ols_smoke_test "$new" "$(lib_domain_expected_codes lenient)" \
    || lib_die "${new} does not answer" "${OLS_TEST_OUTPUT}" "check ${LSWS_HOME}/logs/error.log; the site is put back under ${old}"
  if [[ "$D_MODE" == "php" || "$D_MODE" == "wordpress" ]]; then
    lib_domain_php_probe || lib_die "PHP is not executing for ${new}" "${OLS_TEST_OUTPUT}" "check $(lib_domain_log_dir "$new")/error.log; the site is put back under ${old}"
  fi
  lib_ok "the site answers on http://${new}/"
  # From here on nothing puts the old name back: the site is served under the new one, and
  # what follows - certificate, database addresses, redirect - can each be done again.
  lib_rollback_clear
  rm -f -- "$(lib_domain_state_dir "$new")/ssl.info"   # the note about the old name's certificate
  D_STATUS="active"
  lib_domain_state_save
  _domain_rename_mail_detach "$old" "$new"     || lib_warn "The mail of ${old} could not be given a record of its own; its mailboxes still work: setup.sh mail domain add ${old}"

  # ---- 5 the old name ----------------------------------------------------------
  # before the certificate, which can take a minute: until this is in place the old name gets
  # the answer of a name this server does not know. The redirect says http:// for now and
  # follows by itself once the new name has its certificate (lib_redirect_sync_target).
  lib_step "The old name ${old}"
  if (( redirect )); then
    lib_redirect_save "$old" "$new" "$D_WWW"
    if ( lib_redirect_apply "$old" ); then
      lib_ok "${old} now sends every request on to ${new}$( lib_ssl_deployed "$old" && printf ', over HTTPS too')"
    else
      lib_warn "The redirect from ${old} could not be set up; later: setup.sh redirect add ${old} ${new}$( (( D_WWW )) && printf ' --www')"
    fi
    lib_rollback_clear
  elif (( nodom )); then
    # no certificate to delete either: lomp never asked for one under a name that is none, so
    # a lineage called that is somebody else's
    lib_ok "nothing is left under ${old}: it was no name anything could ask for"
  else
    lib_ssl_delete "$old"
    lib_ok "${old} is no longer answered here"
  fi
  # a name that was sent on to the old one would now be sent on twice
  while read -r a; do
    [[ -n "$a" && "$a" != "$new" ]] || continue
    lib_redirect_save "$a" "$new" "$(_d_bool "$(lib_json_get "$(lib_redirect_file "$a")" '.www')")"
    ( lib_redirect_apply "$a" ) || lib_warn "The redirect from ${a} still leads to ${old}; later: setup.sh redirect add ${a} ${new}"
    lib_rollback_clear
  done < <(lib_redirects_to "$old")

  # ---- the application ----------------------------------------------------------
  # after the redirect, before the certificate: the site answers 502 until this is done. As
  # after a restore: the dependencies again, a build, then PM2 under the unit of the new user.
  if (( app )); then
    lib_step "Node.js application"
    # PM2's own saved list and pid file name the old paths; lomp starts it from its ecosystem file
    lib_domain_as_user rm -f -- "${D_HOME}/.pm2/dump.pm2" "${D_HOME}/.pm2/dump.pm2.bak" "${D_HOME}/.pm2/pm2.pid" 2>/dev/null || true
    ( lib_app_restore ) || lib_warn "The application of ${new} did not come up; later: setup.sh app deploy ${new}"
    lib_rollback_clear
  fi

  # ---- 6 certificate -----------------------------------------------------------
  lib_step "Certificate for ${new}"
  if (( ssl )); then
    ( lib_domain_add_ssl ) || lib_warn "The certificate step ended early; later: setup.sh renew-ssl ${new}"
    lib_rollback_clear
    lib_domain_state_load "$new"
  else
    lib_info "no certificate requested (setup.sh renew-ssl ${new})"
  fi

  # ---- the mailboxes ------------------------------------------------------------
  # last of what takes time: switching mail on for the new name asks for a certificate too
  if (( mailmove && RENAME_MAIL_DETACHED )) && lib_mail_domain_enabled "$old"; then
    lib_step "Mailboxes to @${new}"
    # in a subshell for the same reason as the certificate above: nothing in it may end the rename
    RENAME_MAIL_MOVED="$( ( _domain_rename_mail_move "$old" "$new" >&2 && printf '%s' "$RENAME_MAIL_MOVED" ) || printf 'FAILED' )"
    lib_rollback_clear
  fi

  # ---- 7 what still says the old name ------------------------------------------
  lib_step "WordPress addresses, scheduled tasks and logs"
  if _domain_rename_has_wp; then
    if (( replace )); then
      _domain_rename_wp "$old" "$new"
      # after the rewrite: what is in the page cache by now was made from the addresses before it
      _domain_rename_cache_clear
    else
      lib_info "WordPress database left as it is (--no-search-replace)"
    fi
  fi
  if (( wpcron )); then lib_domain_wpcron_set; fi
  lib_domain_logrotate_regen
  lib_domain_fail2ban_regen
  if [[ "$D_MODE" == "php" || "$D_MODE" == "wordpress" ]]; then lib_ols_htaccess_watch_ensure; fi
  # the archives follow the site, unless the old name has mail of its own archived beside them
  f="${BACKUP_ROOT}/${old}"
  if [[ -d "$f" && ! -e "${BACKUP_ROOT}/${new}" ]] && ! { lib_mail_installed && lib_mail_domain_has_traces "$old"; }; then
    mv -T -- "$f" "${BACKUP_ROOT}/${new}" && f="${BACKUP_ROOT}/${new}"
  fi
  lib_manifest_set '.updated_at' "$(lib_iso_now)"
  lib_log_write INFO "site ${old} renamed to ${new} (user ${oi} -> ${D_USER})"

  lib_tr "Renamed ${old} to ${new}"
  printf '\n%s%s%s%s\n' "$C_BLD" "$C_GRN" "$LIB_TR" "$C_RST"
  lib_print_kv "Address"  "$(lib_redirect_target_url "$new")/"
  lib_print_kv "Files"    "${D_HOME}/public_html (user ${D_USER})"
  [[ -z "$D_DB_NAME" ]] || lib_print_kv "Database" "${D_DB_NAME} (unchanged; setup.sh credentials ${new})"
  lib_print_kv "Old name" "$( if (( redirect )); then printf '%s -> 301 -> %s' "$old" "$new"; elif (( nodom )); then printf '%s (no domain name: nothing is left under it)' "$old"; else printf 'no longer answered'; fi )"
  lib_print_kv "Backups"  "${f}/ (the one from before the rename: $(basename "${BK_LAST_FILE:-none}"))"
  if (( ! D_SSL && D_SSL_WANTED )); then lib_note "No certificate yet: point the DNS of ${new} here, then run: setup.sh renew-ssl ${new}"; fi
  if (( redirect )); then lib_note "Keep the DNS of ${old} pointing here for as long as the redirect should work."; fi
  if [[ -n "${RENAME_MAIL_MOVED:-}" && "$RENAME_MAIL_MOVED" != FAILED ]]; then
    lib_note "Mail: now at @${new} - ${RENAME_MAIL_MOVED// /, }. Same passwords; the user name to sign in with is the new address."
    lib_note "Mail to the old addresses at @${old} still arrives, as aliases, and may still be sent from. Keep the MX of ${old} pointing here."
    lib_note "For mail from outside to reach @${new} directly, its DNS needs the records: setup.sh mail dns ${new}"
  elif (( RENAME_MAIL_KEPT )); then
    if [[ "${RENAME_MAIL_MOVED:-}" == FAILED ]]; then lib_warn "The mailboxes could not be moved to @${new}; they are at @${old} and work as before"; fi
    lib_note "Mail: the mailboxes at @${old} work as before; ${old} is a mail domain of its own now (setup.sh mail domain list)."
    lib_note "Mail for ${new}, if it should have any: setup.sh mail enable ${new} --mailbox info"
  fi
  # What still carries the old name is looked for by that name. A name that is no domain name
  # is often a word that says nothing by itself - "staging", "test" - and was never an address:
  # of such a name only the home directory it gave the site is looked for, in the forms a
  # path is written in.
  seek=("$old"); what="$old"
  if (( nodom )); then
    oh="$(lib_domain_home "$old")"; seek=("${oh}/" "${oh}'" "${oh}\""); what="the old path ${oh}"
  fi
  for a in "${seek[@]}"; do greps+=(-e "$a"); done
  if (( app )) && lib_app_env_json "$new" | grep -qF "${greps[@]}"; then
    lib_warn "A variable of the application still names ${what}: setup.sh app env ${new} list"
  fi
  left="$(_domain_rename_leftovers "${seek[@]}")"
  if [[ -n "$left" ]]; then
    lib_warn "These files still name ${what}$( (( nodom )) || printf ' (an address, or the old path %s/%s)' "$SITES_ROOT" "$old"); have a look at them:"
    while read -r a; do [[ -n "$a" ]] && lib_note "$a"; done <<<"$left"
  fi
  printf '\n'
  return 0
}
