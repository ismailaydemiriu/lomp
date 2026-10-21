#!/usr/bin/env bash
# lib/nginx.sh - an image server: nginx alone, serving images (and other static files) for any
#                number of domains. "install --images" sets one up, without OpenLiteSpeed, PHP,
#                MariaDB or Redis; on such a server add, remove, list, logs, renew-ssl,
#                optimize, update, status and doctor work on nginx instead.

# Not readonly like the paths in setup.sh: tests/unit.sh points them into its own directory.
NGX_ETC="${NGX_ETC:-/etc/nginx}"
NGX_CONF="${NGX_CONF:-${NGX_ETC}/nginx.conf}"
NGX_LOMP_DIR="${NGX_LOMP_DIR:-${NGX_ETC}/lomp}"
NGX_SITES_DIR="${NGX_SITES_DIR:-${NGX_LOMP_DIR}/sites}"
NGX_LOGROTATE_FILE="${NGX_LOGROTATE_FILE:-/etc/logrotate.d/lomp-nginx-sites}"
NGX_DEPLOY_HOOK="${NGX_DEPLOY_HOOK:-/etc/letsencrypt/renewal-hooks/deploy/99-lomp-nginx.sh}"
NGX_IPV6_PROC="${NGX_IPV6_PROC:-/proc/net/if_inet6}"
NGX_CACHE_DAYS_DEFAULT=30
# what the minute check makes readable, and how often (lib_nginx_perms_main)
NGX_PERMS_CRON="*/10 * * * *"

# the image types served with a long cache lifetime; svg is apart, it can carry script
NGX_IMAGE_EXT='jpe?g|jfif|pjpeg|pjp|png|apng|gif|webp|avif|jxl|heic|heif|bmp|ico|cur|tiff?'

lib_server_images() { [[ "$(lib_server_role)" == "images" ]]; }
lib_nginx_installed() { lib_have nginx || [[ -x /usr/sbin/nginx ]]; }

lib_nginx_version() {   # -> 1.24.0, or nothing
  local v=""
  v="$( { nginx -v 2>&1 || true; } | sed -n 's#^nginx version: nginx/\([0-9.]*\).*#\1#p')"
  printf '%s' "$v"
}

# 0 when version $1 is at least $2 (dotted numbers)
lib_nginx_version_ge() {   # have want
  [[ -n "$1" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | sed -n 1p)" == "$2" ]]
}

_ngx_ipv6() { [[ -s "$NGX_IPV6_PROC" ]]; }

# =============================================================================
#  Tuning: what nginx.conf is sized to, from the CPU and memory of this machine
# =============================================================================
# Every worker serves every site; one per core is what nginx itself recommends for static files.
# Memory decides how many connections each worker may hold and how many open files are kept
# in the cache, so a 1 GB VPS and a 32 GB one both get a configuration that fits them.
lib_nginx_tune() {
  local cores="${SYS_CPU_CORES:-1}" ram="${SYS_RAM_MB:-1024}"
  [[ "$cores" =~ ^[0-9]+$ ]] && (( cores > 0 )) || cores=1
  [[ "$ram" =~ ^[0-9]+$ ]] && (( ram > 0 )) || ram=1024
  NGX_T_WORKERS="$(_sys_clamp "$cores" 1 64)"
  # ~2 connections per MB: 1 GB -> 2048, 4 GB -> 8192, 8 GB and more -> 16384
  NGX_T_CONNS="$(_sys_clamp $(( ram * 2 )) 1024 16384)"
  # a connection holds a socket and, while sending, a file: twice as many descriptors
  NGX_T_NOFILE="$(_sys_clamp $(( NGX_T_CONNS * 2 )) 4096 65536)"
  # open_file_cache entries are a few hundred bytes each: 10 per MB costs well under 1%
  NGX_T_FILE_CACHE="$(_sys_clamp $(( ram * 10 )) 1000 100000)"
  # 1 MB of TLS session cache holds about 4000 sessions
  NGX_T_SSL_CACHE_MB="$(_sys_clamp $(( ram / 128 )) 2 64)"
  # images are compressed already: gzip only reaches svg, icons and text. One core spends
  # less on it.
  if (( cores == 1 )); then NGX_T_GZIP_LEVEL=2; else NGX_T_GZIP_LEVEL=5; fi
  if (( ram < 1024 )); then NGX_T_LOG_BUFFER="32k"; else NGX_T_LOG_BUFFER="128k"; fi
  # a spinning disk blocks a worker on every read that misses the page cache; threads keep the
  # worker serving the other connections meanwhile
  if [[ "${SYS_DISK_TYPE:-}" == "hdd" ]]; then NGX_T_AIO=1; else NGX_T_AIO=0; fi
  return 0
}

lib_nginx_tune_report() {
  lib_nginx_tune
  lib_print_kv "nginx workers" "${NGX_T_WORKERS} (one per CPU core)"
  lib_print_kv "Connections" "${NGX_T_CONNS} per worker, ${NGX_T_NOFILE} open files"
  lib_print_kv "File cache" "${NGX_T_FILE_CACHE} entries, TLS session cache ${NGX_T_SSL_CACHE_MB} MB"
  lib_print_kv "Disk reads" "$( (( NGX_T_AIO )) && printf 'threads (spinning disk)' || printf 'sendfile')"
  return 0
}

# =============================================================================
#  Rendering
# =============================================================================
# mime.types of nginx 1.18 knows no avif, and none knows jxl or heic: added where it lacks them.
# Naming one it has already makes "nginx -t" warn about a duplicate extension.
_ngx_types_extra() {
  local mime="${NGX_ETC}/mime.types" pair="" t="" e="" out=""
  for pair in image/avif:avif image/jxl:jxl image/heic:heic image/heif:heif image/apng:apng; do
    t="${pair%%:*}"; e="${pair#*:}"
    if [[ -r "$mime" ]] && grep -Eq "[[:space:]]${e}([[:space:]]|;)" "$mime"; then continue; fi
    out+="    ${t} ${e};"$'\n'
  done
  if [[ -n "$out" ]]; then printf '  types {\n%s  }\n' "$out"; fi
  return 0
}

lib_nginx_render_conf() {
  local ver="" v6=0
  lib_nginx_tune
  ver="$(lib_nginx_version)"
  _ngx_ipv6 && v6=1
  cat <<EOF
# Managed by lompstack - image server. Sized for ${SYS_CPU_CORES:-1} CPU core(s) and ${SYS_RAM_MB:-?} MB of memory;
# "lomp optimize" sizes it again after the machine changed. Sites are in ${NGX_SITES_DIR}.
user www-data;
worker_processes ${NGX_T_WORKERS};
worker_rlimit_nofile ${NGX_T_NOFILE};
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;
include ${NGX_ETC}/modules-enabled/*.conf;

events {
  worker_connections ${NGX_T_CONNS};
  multi_accept on;
  use epoll;
}

http {
  include ${NGX_ETC}/mime.types;
$(_ngx_types_extra)
  default_type application/octet-stream;
  server_tokens off;

  sendfile on;
  sendfile_max_chunk 1m;
  tcp_nopush on;
  tcp_nodelay on;
EOF
  if (( NGX_T_AIO )); then printf '  aio threads;\n'; fi
  cat <<EOF

  keepalive_timeout 30s;
  keepalive_requests 1000;
  reset_timedout_connection on;
  client_header_timeout 10s;
  client_body_timeout 10s;
  send_timeout 30s;
  # nothing is uploaded over HTTP here: files come in over SFTP
  client_max_body_size 1m;
  client_body_buffer_size 16k;
  large_client_header_buffers 4 8k;

  # what was found is kept; what was not is looked for again on the next request, so a file
  # uploaded a moment ago (or just made readable) is served at once
  open_file_cache max=${NGX_T_FILE_CACHE} inactive=60s;
  open_file_cache_valid 60s;
  open_file_cache_min_uses 2;
  open_file_cache_errors off;

  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers off;
  ssl_session_cache shared:lompSSL:${NGX_T_SSL_CACHE_MB}m;
  ssl_session_timeout 1d;
  ssl_session_tickets off;

  gzip on;
  gzip_comp_level ${NGX_T_GZIP_LEVEL};
  gzip_min_length 1024;
  gzip_vary on;
  gzip_proxied any;
  gzip_types image/svg+xml image/x-icon image/vnd.microsoft.icon image/bmp text/plain text/css application/javascript application/json application/xml;

  access_log /var/log/nginx/access.log combined buffer=${NGX_T_LOG_BUFFER} flush=1m;
  # the visitor's own address behind Cloudflare (empty when Cloudflare mode is off)
  include ${NGX_LOMP_DIR}/cloudflare.conf;

  # a name no site was added for, or a bare IP address: the connection is closed unanswered
  server {
    listen 80 default_server;
EOF
  if (( v6 )); then printf '    listen [::]:80 default_server;\n'; fi
  printf '    server_name _;\n    access_log off;\n    return 444;\n  }\n'
  # nginx 1.19.4 and later can refuse the TLS handshake itself, without any certificate
  if lib_nginx_version_ge "$ver" 1.19.4; then
    printf '  server {\n    listen 443 ssl default_server;\n'
    if (( v6 )); then printf '    listen [::]:443 ssl default_server;\n'; fi
    printf '    server_name _;\n    access_log off;\n    ssl_reject_handshake on;\n  }\n'
  fi
  cat <<EOF

  include ${NGX_SITES_DIR}/*.conf;
}
EOF
}

# What every image site serves and how. Included inside each site's server block.
lib_nginx_render_common() {
  local days="${1:-$NGX_CACHE_DAYS_DEFAULT}" secs=0
  secs=$(( days * 86400 ))
  cat <<EOF
# Managed by lompstack - what an image site serves (included by every file in sites/)
index index.html;
autoindex off;

# nothing here takes a form or an upload
if (\$request_method !~ ^(GET|HEAD)\$) { return 405; }

location ^~ /.well-known/acme-challenge/ {
  root ${ACME_ROOT};
  default_type text/plain;
  try_files \$uri =404;
}
# .git, .env, .htaccess and every other dotted name: not served
location ~ /\\. { access_log off; log_not_found off; return 404; }
# a script is never run here, and its source is nobody's business either
location ~* \\.(?:php[0-9]?|phtml|phar|pl|py|cgi|sh|asp|aspx|jsp|sql|bak|log|ini|conf)\$ { return 404; }

location = /favicon.ico { access_log off; log_not_found off; add_header Cache-Control "public, max-age=${secs}" always; }
location = /robots.txt  { access_log off; log_not_found off; }

location ~* \\.(?:${NGX_IMAGE_EXT})\$ {
  add_header Cache-Control "public, max-age=${secs}" always;
  add_header Access-Control-Allow-Origin "*" always;
  add_header Timing-Allow-Origin "*" always;
  add_header X-Content-Type-Options "nosniff" always;
  try_files \$uri =404;
}
# an svg is a document that can run script: shown as an image it never does, opened on its own
# this keeps it from doing so on this domain
location ~* \\.svgz?\$ {
  add_header Cache-Control "public, max-age=${secs}" always;
  add_header Access-Control-Allow-Origin "*" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header Content-Security-Policy "default-src 'none'; img-src data:; style-src 'unsafe-inline'; sandbox" always;
  try_files \$uri =404;
}
location / {
  add_header X-Content-Type-Options "nosniff" always;
  try_files \$uri \$uri/ =404;
}
EOF
}

# The common part is one file per cache lifetime, so sites with different lifetimes can live
# side by side: common-30d.conf, common-365d.conf ...
_ngx_common_file() { printf '%s/common-%sd.conf' "$NGX_LOMP_DIR" "$1"; }

lib_nginx_render_cloudflare() {
  printf '# Managed by lompstack - Cloudflare ranges whose CF-Connecting-IP is believed\n'
  if lib_cf_enabled && [[ -s "$CF_IPS_FILE" ]]; then
    local cidr=""
    while read -r cidr; do
      [[ -z "$cidr" || "$cidr" == \#* ]] && continue
      printf 'set_real_ip_from %s;\n' "$cidr"
    done <"$CF_IPS_FILE"
    printf 'real_ip_header CF-Connecting-IP;\n'
  fi
  return 0
}

# Where a name that was renamed sends its visitors: https://<new> once the new name has its
# certificate, http://<new> until then. Nothing for a site that is no such record.
_ngx_redirect_target() {   # domain
  local f="" to=""
  f="$(lib_domain_json "$1")"
  [[ -s "$f" ]] || return 0
  to="$(lib_json_get "$f" '.redirect_to')"
  [[ -n "$to" ]] || return 0
  if [[ "$(lib_json_get "$(lib_domain_json "$to")" '.ssl.enabled')" == "true" ]]; then printf 'https://%s' "$to"
  else printf 'http://%s' "$to"; fi
}

_ngx_listen_443() {   # version v6(0/1)
  if lib_nginx_version_ge "$1" 1.25.1; then
    printf '  listen 443 ssl;\n'; (( $2 )) && printf '  listen [::]:443 ssl;\n'
    printf '  http2 on;\n'
  else
    printf '  listen 443 ssl http2;\n'; (( $2 )) && printf '  listen [::]:443 ssl http2;\n'
  fi
  return 0
}

# A name that was renamed: every path answers 301 to the same path under the new name. Its
# certificate stays and renews, so https:// links to it keep working too.
_ngx_render_redirect() {   # domain names ssl(0/1) target version v6(0/1)
  local d="$1" names="$2" ssl="$3" to="$4" ver="$5" v6="$6"
  printf '# Managed by lompstack - %s was renamed and redirects to %s ("lomp remove %s" ends that)\n' "$d" "$to" "$d"
  printf 'server {\n  listen 80;\n'
  (( v6 )) && printf '  listen [::]:80;\n'
  printf '  server_name %s;\n  access_log off;\n' "$names"
  printf '  location ^~ /.well-known/acme-challenge/ {\n    root %s;\n    default_type text/plain;\n    try_files $uri =404;\n  }\n' "$ACME_ROOT"
  printf '  location / { return 301 %s$request_uri; }\n}\n' "$to"
  if (( ssl )); then
    printf 'server {\n'
    _ngx_listen_443 "$ver" "$v6"
    printf '  server_name %s;\n' "$names"
    printf '  ssl_certificate %s/%s/fullchain.pem;\n  ssl_certificate_key %s/%s/privkey.pem;\n' "$SSL_DEPLOY_DIR" "$d" "$SSL_DEPLOY_DIR" "$d"
    printf '  access_log off;\n  location / { return 301 %s$request_uri; }\n}\n' "$to"
  fi
  return 0
}

# One site: http only, or http that sends on to https and the https server itself - or, for a
# name that was renamed, the redirect to the new one.
lib_nginx_render_site() {   # domain www(0/1) ssl(0/1) cache_days
  local d="$1" www="${2:-0}" ssl="${3:-0}" days="${4:-$NGX_CACHE_DAYS_DEFAULT}" names="" ver="" v6=0 logdir="" to=""
  names="$d"; (( www )) && names+=" www.${d}"
  ver="$(lib_nginx_version)"
  _ngx_ipv6 && v6=1
  logdir="$(lib_domain_log_dir "$d")"
  to="$(_ngx_redirect_target "$d")"
  if [[ -n "$to" ]]; then _ngx_render_redirect "$d" "$names" "$ssl" "$to" "$ver" "$v6"; return 0; fi
  printf '# Managed by lompstack - image site %s ("lomp remove %s" takes it away)\n' "$d" "$d"
  if (( ssl )); then
    printf 'server {\n  listen 80;\n'
    (( v6 )) && printf '  listen [::]:80;\n'
    printf '  server_name %s;\n' "$names"
    printf '  access_log %s/access.log combined buffer=%s flush=1m;\n' "$logdir" "${NGX_T_LOG_BUFFER:-32k}"
    printf '  location ^~ /.well-known/acme-challenge/ {\n    root %s;\n    default_type text/plain;\n    try_files $uri =404;\n  }\n' "$ACME_ROOT"
    printf '  location / { return 301 https://$host$request_uri; }\n}\n'
    printf 'server {\n'
    _ngx_listen_443 "$ver" "$v6"
    printf '  server_name %s;\n' "$names"
    printf '  ssl_certificate %s/%s/fullchain.pem;\n  ssl_certificate_key %s/%s/privkey.pem;\n' "$SSL_DEPLOY_DIR" "$d" "$SSL_DEPLOY_DIR" "$d"
  else
    printf 'server {\n  listen 80;\n'
    (( v6 )) && printf '  listen [::]:80;\n'
    printf '  server_name %s;\n' "$names"
  fi
  printf '  root %s/public_html;\n' "$(lib_domain_home "$d")"
  printf '  access_log %s/access.log combined buffer=%s flush=1m;\n' "$logdir" "${NGX_T_LOG_BUFFER:-32k}"
  printf '  error_log %s/error.log warn;\n' "$logdir"
  printf '  include %s;\n}\n' "$(_ngx_common_file "$days")"
}

# =============================================================================
#  Applying: write, test, and put back what was there when nginx refuses it
# =============================================================================
NGX_TEST_OUTPUT=""
lib_nginx_test() {
  (( OPT_DRY_RUN )) && return 0
  NGX_TEST_OUTPUT="$(nginx -t 2>&1)" && return 0
  lib_log_write ERROR "nginx -t: ${NGX_TEST_OUTPUT}"
  return 1
}

_ngx_workers() {   # -> the pids of nginx's workers on one line, or nothing
  local m=""
  m="$(cat /run/nginx.pid 2>/dev/null || true)"
  [[ "$m" =~ ^[0-9]+$ ]] || return 0
  { pgrep -P "$m" 2>/dev/null || true; } | sort -n | tr '\n' ' '
}

lib_nginx_reload() {
  local before="" now="" p="" i=0 left=0
  (( OPT_DRY_RUN )) && { lib_info "[dry-run] would reload nginx"; return 0; }
  if lib_service_active nginx; then
    before="$(_ngx_workers)"
    lib_systemctl reload nginx || lib_die "nginx could not be reloaded" "journalctl -u nginx" "sudo nginx -t"
    # "reload" only signals the master and returns. The old workers go on taking connections
    # until they have heard from it - after the new ones started - so a request a moment later
    # could still meet the old configuration: "add" said a site was served while it was not
    # yet. Waited for here until the old workers are gone, at most 5 seconds (one still
    # sending a large file to somebody is left to finish).
    if [[ -n "$before" ]]; then
      for (( i = 0; i < 50; i++ )); do
        now=" $(_ngx_workers) "; left=0
        for p in $before; do if [[ "$now" == *" ${p} "* ]]; then left=1; break; fi; done
        (( left )) || break
        sleep 0.1
      done
    fi
  else
    lib_systemctl enable nginx >/dev/null 2>&1 || true
    lib_systemctl restart nginx || lib_die "nginx did not start" "journalctl -u nginx" "sudo nginx -t"
  fi
  return 0
}

# file mode  (content on stdin). The file is written; when "nginx -t" then refuses the whole,
# the previous content is put back (or the new file removed) and the status is 1.
NGX_CHANGED=0
lib_nginx_write() {   # path mode
  local path="$1" mode="${2:-0644}" prev=""
  if [[ -f "$path" ]] && (( ! OPT_DRY_RUN )); then prev="$(lib_mktemp)"; cp -p -- "$path" "$prev"; fi
  lib_write_file "$path" "$mode" root:root
  if (( ! LIB_FILE_CHANGED )); then [[ -z "$prev" ]] || rm -f -- "$prev"; return 0; fi
  NGX_CHANGED=1
  if ! lib_nginx_test; then
    if [[ -n "$prev" ]]; then mv -f -- "$prev" "$path"; else rm -f -- "$path"; fi
    lib_error "nginx refused ${path}; the previous version was put back"
    return 1
  fi
  [[ -z "$prev" ]] || rm -f -- "$prev"
  return 0
}

# Every file nginx reads from lompstack, as this release writes them, for the hardware it runs
# on now. Used by install, optimize, update and migrate.
lib_nginx_configure() {
  local d="" days="" seen=" "
  NGX_CHANGED=0
  # here and not only inside the renderers: those run on the left of a pipe, in a subshell
  lib_nginx_tune
  lib_mkdir "$NGX_LOMP_DIR" 0755 root:root
  lib_mkdir "$NGX_SITES_DIR" 0755 root:root
  lib_mkdir "$ACME_ROOT/.well-known/acme-challenge" 0755 root:root
  # the files the other files name come first, so each test sees a whole configuration
  lib_nginx_render_cloudflare | lib_write_file "${NGX_LOMP_DIR}/cloudflare.conf" 0644 root:root
  (( LIB_FILE_CHANGED )) && NGX_CHANGED=1
  for days in "$NGX_CACHE_DAYS_DEFAULT" $(_ngx_sites_cache_days); do
    [[ "$seen" == *" ${days} "* ]] && continue
    seen+="${days} "
    lib_nginx_render_common "$days" | lib_write_file "$(_ngx_common_file "$days")" 0644 root:root
    (( LIB_FILE_CHANGED )) && NGX_CHANGED=1
  done
  # Ubuntu's package enables a "Welcome to nginx" site on port 80, which would answer every
  # name nobody added. The package's own nginx.conf is kept once, beside ours.
  if [[ -f "$NGX_CONF" && ! -f "${NGX_CONF}.lomp-orig" ]] && ! grep -q 'Managed by lompstack' "$NGX_CONF" && (( ! OPT_DRY_RUN )); then
    cp -p -- "$NGX_CONF" "${NGX_CONF}.lomp-orig"
  fi
  lib_rm "${NGX_ETC}/sites-enabled/default"
  lib_nginx_render_conf | lib_nginx_write "$NGX_CONF" 0644 || _ngx_refused "$NGX_CONF"
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_nginx_site_load "$d" || continue
    lib_nginx_render_site "$d" "$NGX_S_WWW" "$NGX_S_SSL" "$NGX_S_DAYS" | lib_nginx_write "$(_ngx_site_file "$d")" 0644 || _ngx_refused "$(_ngx_site_file "$d")"
  done < <(lib_domains_list)
  if ! lib_nginx_test; then
    lib_die "nginx refuses its configuration" "${NGX_TEST_OUTPUT##*$'\n'}" "sudo nginx -t"
  fi
  return 0
}

_ngx_refused() {   # path
  lib_die "nginx refused ${1}; the previous version was put back" "${NGX_TEST_OUTPUT##*$'\n'}" "sudo nginx -t   (the whole output is in ${LOG_FILE})"
}

lib_nginx_cf_apply() {
  lib_server_images || return 0
  lib_nginx_render_cloudflare | lib_nginx_write "${NGX_LOMP_DIR}/cloudflare.conf" 0644 || _ngx_refused "${NGX_LOMP_DIR}/cloudflare.conf"
  if (( LIB_FILE_CHANGED )); then lib_nginx_reload; lib_ok "nginx believes CF-Connecting-IP from Cloudflare's ranges only"; fi
  return 0
}

# =============================================================================
#  Sites
# =============================================================================
_ngx_site_file() { printf '%s/%s.conf' "$NGX_SITES_DIR" "$1"; }

NGX_S_WWW=0 NGX_S_SSL=0 NGX_S_DAYS="$NGX_CACHE_DAYS_DEFAULT" NGX_S_REDIRECT=""
lib_nginx_site_load() {   # domain -> NGX_S_*; 1 when it is no image site
  local f="" v=""
  f="$(lib_domain_json "$1")"
  [[ -s "$f" ]] || return 1
  [[ "$(lib_json_get "$f" '.mode')" == "images" ]] || return 1
  NGX_S_WWW=0; NGX_S_SSL=0
  NGX_S_REDIRECT="$(lib_json_get "$f" '.redirect_to')"
  [[ "$(lib_json_get "$f" '.www')" == "true" ]] && NGX_S_WWW=1
  [[ "$(lib_json_get "$f" '.ssl.enabled')" == "true" ]] && NGX_S_SSL=1
  v="$(lib_json_get "$f" '.cache_days')"
  if [[ "$v" =~ ^[0-9]+$ ]]; then NGX_S_DAYS="$v"; else NGX_S_DAYS="$NGX_CACHE_DAYS_DEFAULT"; fi
  return 0
}

_ngx_sites_cache_days() {
  local d=""
  while read -r d; do
    [[ -n "$d" ]] || continue
    if lib_nginx_site_load "$d"; then printf '%s\n' "$NGX_S_DAYS"; fi
  done < <(lib_domains_list)
  return 0
}

# The site's state file: made on the first call, and later calls change these fields only, so
# what lib_ssl_deploy keeps under .ssl (cert_name, expires) stays.
_ngx_site_json_write() {   # domain www ssl days status
  local f="" old="{}"
  f="$(lib_domain_json "$1")"
  (( OPT_DRY_RUN )) && return 0
  lib_mkdir "$(lib_domain_state_dir "$1")" 0700 root:root
  if [[ -s "$f" ]]; then old="$(cat -- "$f")"; fi
  jq --arg d "$1" --argjson www "$( (( $2 )) && printf true || printf false)" \
     --argjson ssl "$( (( $3 )) && printf true || printf false)" --argjson days "$4" --arg st "$5" \
     --arg home "$(lib_domain_home "$1")" --arg ts "$(lib_iso_now)" \
     '.domain = $d | .mode = "images" | .www = $www | .home = $home | .cache_days = $days | .status = $st
      | .created_at = (.created_at // $ts) | .ssl = ((.ssl // {}) | .enabled = $ssl)' <<<"$old" \
     | lib_write_file "$f" 0600 root:root
}

lib_nginx_add_usage() {
  cat <<'EOF'
Usage: lomp add <domain> [--www] [--no-ssl] [--email a@b.c] [--cache-days N] [--staging]
  An image site: files go into /home/<domain>/public_html (upload them over SFTP, as root is
  fine) and nginx serves them. Images get "Cache-Control: public, max-age" of N days
  (default 30) and may be shown on any other site.
  --www          also answer www.<domain>
  --no-ssl       no Let's Encrypt certificate now (later: lomp renew-ssl <domain>)
  --cache-days N how long browsers and Cloudflare may keep an image (1..3650)
EOF
}

lib_nginx_add_main() {
  local domain="" www=0 ssl=1 email="${DEFAULT_EMAIL:-}" days="$NGX_CACHE_DAYS_DEFAULT" staging=0 a="" home="" logdir="" rc=0
  [[ -n "${1:-}" ]] || { lib_nginx_add_usage; lib_die "Domain missing" "" "lomp add example.com"; }
  [[ "$1" == "-h" || "$1" == "--help" ]] && { lib_nginx_add_usage; return 0; }
  domain="${1,,}"; shift
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --www)        www=1 ;;
      --no-ssl)     ssl=0 ;;
      --email)      email="${1:-}"; shift ;;
      --cache-days) days="${1:-}"; shift ;;
      --staging)    staging=1 ;;
      -h|--help)    lib_nginx_add_usage; return 0 ;;
      *) lib_die "Unknown option for add on an image server: ${a}" \
           "this server serves files with nginx: there is no PHP, WordPress, database or proxy here" \
           "lomp add ${domain} [--www] [--no-ssl] [--email a@b.c] [--cache-days N]" ;;
    esac
  done
  lib_require_tools
  lib_require_installed
  lib_domain_valid "$domain" || lib_die "Invalid domain '${domain}'" "not a valid FQDN (use the bare domain, without http:// or paths)" "lomp add example.com"
  [[ "$domain" != www.* ]] || lib_die "Add ${domain#www.} with --www instead of ${domain}" "the www name is the second name of a site" "lomp add ${domain#www.} --www"
  [[ "$days" =~ ^[0-9]+$ ]] && (( days >= 1 && days <= 3650 )) || lib_die "Invalid --cache-days '${days}'" "a number of days between 1 and 3650" "--cache-days 30"
  days=$(( 10#$days ))
  if [[ -n "$email" ]]; then lib_email_valid "$email" || lib_die "Invalid --email '${email}'" "" "--email you@example.com"; fi
  lib_domain_registered "$domain" && lib_die "Site ${domain} already exists" "registered in $(lib_domain_state_dir "$domain")" "lomp remove ${domain} first, or lomp renew-ssl ${domain}"
  lib_nginx_installed || lib_die "nginx is not installed" "this image server was not set up to the end" "sudo lomp install --images"
  home="$(lib_domain_home "$domain")"; logdir="$(lib_domain_log_dir "$domain")"
  # the certificate's DNS check needs the public address, which only the full analysis finds
  if (( ssl )); then lib_system_analyze; else lib_system_analyze --no-net; fi
  lib_nginx_tune
  lib_steps_begin 4

  lib_step "Directories"
  # root's, and readable by everyone: nginx (www-data) only reads, and whoever uploads does
  # so as root. Nothing below is anybody else's to swap for a link.
  lib_mkdir "$home" 0755 root:root
  lib_mkdir "${home}/public_html" 0755 root:root
  lib_mkdir "$SITES_LOG_ROOT" 0711 root:root
  lib_mkdir "$logdir" 0750 root:adm
  if (( ! OPT_DRY_RUN )); then
    if [[ -e "${home}/logs" && ! -L "${home}/logs" ]]; then lib_warn "${home}/logs is not a link to ${logdir}; it was left as it is"
    else ln -sfnT -- "$logdir" "${home}/logs"; fi
  fi
  lib_ok "Files go into ${home}/public_html"

  lib_step "nginx site"
  _ngx_site_json_write "$domain" "$www" 0 "$days" "installing"
  if [[ ! -f "$(_ngx_common_file "$days")" ]]; then
    lib_nginx_render_common "$days" | lib_write_file "$(_ngx_common_file "$days")" 0644 root:root
  fi
  # nginx refusing the new file leaves nothing behind: the state file goes too, so a second
  # "add" starts clean
  if ! lib_nginx_render_site "$domain" "$www" 0 "$days" | lib_nginx_write "$(_ngx_site_file "$domain")" 0644; then
    lib_rm "$(lib_domain_state_dir "$domain")"
    lib_die "nginx refused the site ${domain}" "${NGX_TEST_OUTPUT##*$'\n'}" "sudo nginx -t"
  fi
  lib_nginx_perms_fix "$domain"
  lib_nginx_reload
  lib_ok "nginx serves http://${domain}/$( (( www )) && printf ' and http://www.%s/' "$domain")"

  lib_step "SSL certificate"
  local got=0
  if (( ! ssl )); then
    lib_info "No certificate requested (--no-ssl). Later: lomp renew-ssl ${domain}"
  else
    rc=0; lib_ssl_dns_check "$domain" "$www" || rc=$?
    if (( rc == 1 )); then
      lib_warn "DNS of ${domain} does not point here yet: ${SSL_LAST_ERROR}"
      lib_note "the site works over http meanwhile; once DNS is right: lomp renew-ssl ${domain}"
    elif lib_ssl_obtain "$domain" "$www" 0 "$staging" 0 "$email" webroot; then
      got=1
    else
      lib_warn "No certificate for ${domain}: ${SSL_LAST_ERROR}"
      lib_note "the site works over http meanwhile; try again with: lomp renew-ssl ${domain}"
    fi
  fi
  if (( got )); then
    _ngx_site_json_write "$domain" "$www" 1 "$days" "installing"
    lib_nginx_render_site "$domain" "$www" 1 "$days" | lib_nginx_write "$(_ngx_site_file "$domain")" 0644 || _ngx_refused "$(_ngx_site_file "$domain")"
    lib_nginx_reload
    lib_ok "https://${domain}/ is served with a Let's Encrypt certificate"
  fi

  lib_step "Finishing"
  _ngx_site_json_write "$domain" "$www" "$got" "$days" "active"
  lib_domain_fail2ban_regen
  printf '\n'
  lib_print_kv "Site" "$( (( got )) && printf 'https' || printf 'http')://${domain}/"
  lib_print_kv "Upload to" "${home}/public_html   (SFTP, e.g. WinSCP)"
  lib_print_kv "Example" "$( (( got )) && printf 'https' || printf 'http')://${domain}/photos/a.jpg = ${home}/public_html/photos/a.jpg"
  lib_print_kv "Browser cache" "${days} days (Cache-Control: public, max-age=$(( days * 86400 )))"
  lib_print_kv "Logs" "lomp logs ${domain}"
  return 0
}

lib_nginx_remove_main() {
  local domain="${1:-}" keep_files=0 keep_ssl=0 a="" home=""
  [[ -n "$domain" ]] || lib_die "Usage: lomp remove <domain> [--keep-files] [--keep-ssl]" "" "lomp remove example.com"
  domain="${domain,,}"; shift
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --keep-files) keep_files=1 ;;
      --keep-ssl)   keep_ssl=1 ;;
      # the sites' command takes these; here they ask for what is there anyway
      --keep-db)    ;;
      *) lib_die "Unknown option for remove: ${a}" "" "remove <domain> [--keep-files] [--keep-ssl]" ;;
    esac
  done
  lib_require_tools
  lib_require_installed
  lib_domain_registered "$domain" || lib_die "Site ${domain} is not registered" "" "lomp list"
  lib_nginx_site_load "$domain" || lib_die "${domain} is no image site" "" "lomp list"
  home="$(lib_domain_home "$domain")"
  local what="its nginx site"
  (( keep_ssl )) || what+=", its certificate"
  if [[ -n "$NGX_S_REDIRECT" ]]; then what="its redirect to ${NGX_S_REDIRECT}"; (( keep_ssl )) || what+=" and its certificate"
  elif (( ! keep_files )); then what+=" and every file under ${home}"; fi
  lib_confirm "Remove ${domain}: ${what}?" n || lib_die "Removal cancelled" "" "lomp remove ${domain} --yes"
  lib_rm "$(_ngx_site_file "$domain")"
  if (( ! OPT_DRY_RUN )); then lib_nginx_test || lib_die "nginx refuses its configuration without ${domain}" "${NGX_TEST_OUTPUT##*$'\n'}" "sudo nginx -t"; fi
  lib_nginx_reload
  lib_ok "nginx no longer serves ${domain}"
  if (( ! keep_ssl )); then lib_ssl_delete "$domain"; fi
  if (( keep_files )); then lib_info "Files kept in ${home}"
  else lib_rm "$home"; lib_ok "Removed ${home}"; fi
  lib_rm "$(lib_domain_log_dir "$domain")"
  lib_rm "$(lib_domain_state_dir "$domain")"
  lib_domain_fail2ban_regen
  lib_ok "Site ${domain} removed"
}

lib_nginx_list_main() {
  local d="" n=0 ssl="" json=0
  [[ "${1:-}" == "--json" ]] && json=1
  (( OPT_JSON )) && json=1
  lib_require_tools
  if (( json )); then
    local files=()
    while read -r d; do [[ -n "$d" ]] && files+=("$(lib_domain_json "$d")"); done < <(lib_domains_list)
    if ((${#files[@]} == 0)); then printf '[]\n'; else jq -s '.' "${files[@]}"; fi
    return 0
  fi
  lib_tprintf '%s%-32s %-5s %-26s %-6s %-10s%s\n' "$C_BLD" "DOMAIN" "WWW" "SSL" "CACHE" "STATUS" "$C_RST"
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_nginx_site_load "$d" || continue
    ssl="$( (( NGX_S_SSL )) && lib_ssl_status_line "$d" || printf -- '-')"
    if [[ -n "$NGX_S_REDIRECT" ]]; then
      lib_tprintf '%-32s %-5s %-26s %-6s %s\n' "$d" "$( (( NGX_S_WWW )) && printf yes || printf no)" "${ssl:0:26}" "-" "-> ${NGX_S_REDIRECT}"
      continue
    fi
    lib_tprintf '%-32s %-5s %-26s %-6s %-10s\n' "$d" "$( (( NGX_S_WWW )) && printf yes || printf no)" "${ssl:0:26}" "${NGX_S_DAYS}d" \
      "$(lib_json_get "$(lib_domain_json "$d")" '.status')$( [[ -d "$(lib_domain_home "$d")/public_html" ]] || printf ' (missing dir!)')"
    n=$((n + 1))
  done < <(lib_domains_list)
  if (( n == 0 )); then lib_tr "(no sites yet - add one with: lomp add example.com)"; printf '%s\n' "$LIB_TR"; fi
  lib_tr "${n} site(s); files under ${SITES_ROOT}/<domain>/public_html"; printf '%s\n' "$LIB_TR"
}

# renew-ssl <domain> [--force] [--staging] [--email a@b.c]   - a first certificate or a new one
# renew-ssl                                                  - certbot renew for every site
lib_nginx_renew_ssl_main() {
  local domain="" force=0 staging=0 email="${DEFAULT_EMAIL:-}" a=""
  lib_require_tools
  lib_require_installed
  if [[ -z "${1:-}" || "${1:-}" == "--all" ]]; then
    lib_info "Renewing every certificate that is due (certbot renew)"
    lib_run certbot renew --non-interactive || lib_die "certbot renew failed" "see /var/log/letsencrypt/letsencrypt.log" "lomp doctor"
    lib_ok "Certificates checked; renewed ones were put into effect by ${NGX_DEPLOY_HOOK}"
    return 0
  fi
  domain="${1,,}"; shift
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --force)   force=1 ;;
      --staging) staging=1 ;;
      --email)   email="${1:-}"; shift ;;
      *) lib_die "Unknown option for renew-ssl: ${a}" "" "renew-ssl <domain> [--force] [--staging] [--email a@b.c]" ;;
    esac
  done
  lib_domain_registered "$domain" || lib_die "Site ${domain} is not registered" "" "lomp list"
  lib_nginx_site_load "$domain" || lib_die "${domain} is no image site" "" "lomp list"
  local www="$NGX_S_WWW" days="$NGX_S_DAYS" rc=0
  lib_system_analyze
  lib_nginx_tune
  lib_ssl_dns_check "$domain" "$www" || rc=$?
  if (( rc == 1 )); then
    lib_die "DNS of ${domain} does not point here" "$SSL_LAST_ERROR" "fix the A/AAAA records (or proxy them through Cloudflare) and run this again"
  fi
  lib_ssl_obtain "$domain" "$www" 0 "$staging" "$force" "$email" webroot || lib_die "No certificate for ${domain}" "$SSL_LAST_ERROR" "lomp renew-ssl ${domain} --staging   (to test without the rate limit)"
  (( OPT_DRY_RUN )) && return 0
  _ngx_site_json_write "$domain" "$www" 1 "$days" "$( [[ -n "$NGX_S_REDIRECT" ]] && printf redirect || printf active)"
  lib_nginx_render_site "$domain" "$www" 1 "$days" | lib_nginx_write "$(_ngx_site_file "$domain")" 0644 || _ngx_refused "$(_ngx_site_file "$domain")"
  # a name that redirects here sends visitors to https:// from now on
  _ngx_redirects_render_to "$domain"
  lib_nginx_reload
  lib_ok "https://${domain}/ is served with the new certificate"
}

# =============================================================================
#  rename: a site under another name; the old one answers 301 to it
# =============================================================================
# Every record that redirects to <domain> is written again: its target's scheme follows the
# certificate of <domain>.
_ngx_redirects_render_to() {   # domain
  local d=""
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_nginx_site_load "$d" || continue
    [[ "$NGX_S_REDIRECT" == "$1" ]] || continue
    lib_nginx_render_site "$d" "$NGX_S_WWW" "$NGX_S_SSL" "$NGX_S_DAYS" | lib_nginx_write "$(_ngx_site_file "$d")" 0644 || _ngx_refused "$(_ngx_site_file "$d")"
  done < <(lib_domains_list)
  return 0
}

lib_nginx_rename_usage() {
  cat <<'EOF'
Usage: lomp rename <old> <new> [--www|--no-www] [--no-ssl] [--no-redirect] [--email a@b.c] [--yes]
  The image site <old> moves to <new>: its files (/home/<old> becomes /home/<new>), its logs
  and its cache lifetime. <new> gets its own Let's Encrypt certificate. <old> then answers
  every path with "301 Moved Permanently" to the same path under <new>, over http and - with
  the certificate it had, which keeps renewing - over https. "lomp remove <old>" ends that.
  --www / --no-www  whether <new> also answers www.<new> (default: as <old> did)
  --no-ssl          no certificate for <new> now (later: lomp renew-ssl <new>)
  --no-redirect     <old> is removed instead, with its certificate
  Point the DNS of <new> to this server first.
EOF
}

lib_nginx_rename_main() {
  local old="" new="" www="" ssl=1 redirect=1 email="${DEFAULT_EMAIL:-}" a="" rc=0 got=0 d=""
  if [[ -z "${1:-}" || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    lib_nginx_rename_usage
    [[ -n "${1:-}" ]] && return 0
    lib_die "Old and new domain missing" "" "lomp rename old.example.com new.example.com"
  fi
  old="${1,,}"; new="${2:-}"; new="${new,,}"; shift; (($# > 0)) && shift
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --www)         www=1 ;;
      --no-www)      www=0 ;;
      --no-ssl)      ssl=0 ;;
      --no-redirect) redirect=0 ;;
      --email)       email="${1:-}"; shift ;;
      *) lib_die "Unknown option for rename: ${a}" "" "lomp rename <old> <new> [--www|--no-www] [--no-ssl] [--no-redirect] [--email a@b.c]" ;;
    esac
  done
  lib_require_tools
  lib_require_installed
  [[ -n "$new" ]] || lib_die "New domain missing" "" "lomp rename ${old} new.example.com"
  lib_domain_registered "$old" || lib_die "Site ${old} is not registered" "" "lomp list"
  lib_nginx_site_load "$old" || lib_die "${old} is no image site" "" "lomp list"
  [[ -z "$NGX_S_REDIRECT" ]] || lib_die "${old} only redirects to ${NGX_S_REDIRECT}" "there are no files under that name to move" "lomp rename ${NGX_S_REDIRECT} ${new}"
  lib_domain_valid "$new" || lib_die "Invalid domain '${new}'" "not a valid FQDN (use the bare domain, without http:// or paths)" "lomp rename ${old} new.example.com"
  [[ "$new" != www.* ]] || lib_die "Rename to ${new#www.} with --www instead of ${new}" "the www name is the second name of a site" "lomp rename ${old} ${new#www.} --www"
  [[ "$new" != "$old" ]] || lib_die "${old} already has that name" "" "lomp rename ${old} another.example.com"
  if lib_domain_registered "$new"; then
    lib_die "Site ${new} already exists" "registered in $(lib_domain_state_dir "$new")" "lomp remove ${new} first, then rename again"
  fi
  if [[ -n "$email" ]]; then lib_email_valid "$email" || lib_die "Invalid --email '${email}'" "" "--email you@example.com"; fi
  local days="$NGX_S_DAYS" old_www="$NGX_S_WWW" old_ssl="$NGX_S_SSL"
  [[ -n "$www" ]] || www="$old_www"
  local home_old="" home_new="" log_old="" log_new=""
  home_old="$(lib_domain_home "$old")"; home_new="$(lib_domain_home "$new")"
  log_old="$(lib_domain_log_dir "$old")"; log_new="$(lib_domain_log_dir "$new")"
  [[ ! -e "$home_new" && ! -L "$home_new" ]] || lib_die "${home_new} is already there" "the files of ${old} would be moved into it" "move it away (or remove it) and rename again"
  [[ -d "$home_old" && ! -L "$home_old" ]] || lib_die "${home_old} is missing" "there are no files to move" "lomp remove ${old}, then lomp add ${new}"

  local what="its files move to ${home_new}"
  if (( redirect )); then what+=", and ${old} answers 301 to ${new}"; else what+=", and ${old} is removed with its certificate"; fi
  lib_confirm "Rename ${old} to ${new}: ${what}?" n || lib_die "Rename cancelled" "" "lomp rename ${old} ${new} --yes"

  if (( ssl )); then lib_system_analyze; else lib_system_analyze --no-net; fi
  lib_nginx_tune
  lib_steps_begin 4

  # first what nginx can refuse, while nothing has moved yet
  lib_step "nginx site for ${new}"
  # "nginx -t" opens the log files a site names, and refuses one in a directory that is not there
  local log_new_made=0
  [[ -d "$log_new" ]] || log_new_made=1
  lib_mkdir "$SITES_LOG_ROOT" 0711 root:root
  lib_mkdir "$log_new" 0750 root:adm
  _ngx_site_json_write "$new" "$www" 0 "$days" "installing"
  if ! lib_nginx_render_site "$new" "$www" 0 "$days" | lib_nginx_write "$(_ngx_site_file "$new")" 0644; then
    lib_rm "$(lib_domain_state_dir "$new")"
    (( log_new_made )) && lib_rm "$log_new"
    lib_die "nginx refused the site ${new}" "${NGX_TEST_OUTPUT##*$'\n'}" "sudo nginx -t"
  fi
  lib_ok "nginx site for ${new} written"

  lib_step "Files and logs"
  if (( OPT_DRY_RUN )); then
    lib_info "[dry-run] would move ${home_old} to ${home_new} and ${log_old} to ${log_new}"
  else
    mv -T -- "$home_old" "$home_new" || lib_die "Could not move ${home_old} to ${home_new}" "see the log" "nothing else was changed; lomp remove ${new} undoes the new site"
    # the logs go along; "nginx -t" above made empty files of the same names, which give way
    local f="" t=""
    if [[ -d "$log_old" && ! -L "$log_old" ]]; then
      for f in "$log_old"/*; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        t="${log_new}/${f##*/}"
        if [[ ! -s "$t" ]]; then mv -f -- "$f" "$t" || true; fi
      done
      rmdir -- "$log_old" 2>/dev/null || lib_warn "some logs of ${old} stayed in ${log_old}"
    fi
    if [[ -L "${home_new}/logs" || ! -e "${home_new}/logs" ]]; then ln -sfnT -- "$log_new" "${home_new}/logs"; fi
  fi
  lib_json_set "$(lib_domain_json "$new")" '.renamed_from = $o' --arg o "$old"
  if (( redirect )); then
    lib_json_set "$(lib_domain_json "$old")" '.redirect_to = $n | .status = "redirect" | del(.home)' --arg n "$new"
    lib_nginx_render_site "$old" "$old_www" "$old_ssl" "$days" | lib_nginx_write "$(_ngx_site_file "$old")" 0644 || _ngx_refused "$(_ngx_site_file "$old")"
  else
    lib_rm "$(_ngx_site_file "$old")"
  fi
  # a name that redirected to the old one goes straight to the new one now
  while read -r d; do
    [[ -n "$d" && "$d" != "$old" ]] || continue
    lib_nginx_site_load "$d" || continue
    [[ "$NGX_S_REDIRECT" == "$old" ]] || continue
    lib_json_set "$(lib_domain_json "$d")" '.redirect_to = $n' --arg n "$new"
    lib_nginx_render_site "$d" "$NGX_S_WWW" "$NGX_S_SSL" "$NGX_S_DAYS" | lib_nginx_write "$(_ngx_site_file "$d")" 0644 || _ngx_refused "$(_ngx_site_file "$d")"
  done < <(lib_domains_list)
  lib_nginx_reload
  lib_ok "http://${new}/ serves the files of ${old}"

  lib_step "SSL certificate"
  if (( ! ssl )); then
    lib_info "No certificate requested (--no-ssl). Later: lomp renew-ssl ${new}"
  else
    rc=0; lib_ssl_dns_check "$new" "$www" || rc=$?
    if (( rc == 1 )); then
      lib_warn "DNS of ${new} does not point here yet: ${SSL_LAST_ERROR}"
      lib_note "the site works over http meanwhile; once DNS is right: lomp renew-ssl ${new}"
    elif lib_ssl_obtain "$new" "$www" 0 0 0 "$email" webroot; then
      got=1
    else
      lib_warn "No certificate for ${new}: ${SSL_LAST_ERROR}"
      lib_note "the site works over http meanwhile; try again with: lomp renew-ssl ${new}"
    fi
  fi
  if (( got )); then
    _ngx_site_json_write "$new" "$www" 1 "$days" "installing"
    lib_nginx_render_site "$new" "$www" 1 "$days" | lib_nginx_write "$(_ngx_site_file "$new")" 0644 || _ngx_refused "$(_ngx_site_file "$new")"
    _ngx_redirects_render_to "$new"
    lib_nginx_reload
    lib_ok "https://${new}/ is served with a Let's Encrypt certificate"
  fi

  lib_step "Finishing"
  _ngx_site_json_write "$new" "$www" "$got" "$days" "active"
  if (( ! redirect )); then
    if (( old_ssl )); then lib_ssl_delete "$old"; fi
    lib_rm "$log_old" "$(lib_domain_state_dir "$old")"
    lib_ok "${old} removed"
  fi
  lib_domain_fail2ban_regen
  printf '\n'
  lib_print_kv "Site" "$( (( got )) && printf 'https' || printf 'http')://${new}/"
  lib_print_kv "Files" "${home_new}/public_html"
  if (( redirect )); then lib_print_kv "Old name" "${old} -> 301 to ${new}   (lomp remove ${old} ends it)"; fi
  return 0
}

# =============================================================================
#  Permissions: what root uploads becomes readable to nginx
# =============================================================================
# WinSCP and scp keep the mode a file had on the uploader's machine, and an archive unpacked
# as root may hold 0600 files: nginx, which reads as www-data, answers 403 for those. Every
# site tree is root's alone, so making it readable to all is safe - nothing here is secret,
# it is all served. Run on add, and every 10 minutes from cron.
lib_nginx_perms_fix() {   # domain
  local pub="" n=0
  pub="$(lib_domain_home "$1")/public_html"
  [[ -d "$pub" && ! -L "$pub" ]] || return 0
  n="$(find -P "$pub" -xdev \( -type d ! -perm -0005 -o -type f ! -perm -0004 \) -print 2>/dev/null | wc -l | tr -d ' ')"
  (( n > 0 )) || return 0
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would make ${n} entries under ${pub} readable to nginx"; return 0; fi
  find -P "$pub" -xdev -type d ! -perm -0005 -exec chmod o+rx {} + 2>/dev/null || true
  find -P "$pub" -xdev -type f ! -perm -0004 -exec chmod o+r {} + 2>/dev/null || true
  lib_log_write INFO "nginx-perms: ${1}: ${n} entries made readable to nginx"
  return 0
}

lib_nginx_perms_main() {
  local d=""
  lib_server_images || return 0
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_nginx_site_load "$d" || continue
    lib_nginx_perms_fix "$d"
  done < <(lib_domains_list)
  return 0
}

# =============================================================================
#  Certificates: what the renewal does on this server
# =============================================================================
lib_nginx_hook_render() {
  cat <<EOF
#!/usr/bin/env bash
# Managed by lompstack - certbot deploy hook of an image server: copy a renewed certificate
# into the deploy directory nginx reads, then reload nginx.
set -u
STATE_DIR="${STATE_DIR}"
DEPLOY_DIR="${SSL_DEPLOY_DIR}"
LOG="${LOG_FILE}"
BIN="${BIN_LINK}"
log()  { printf '%s [HOOK] %s\\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$*" >>"\$LOG" 2>/dev/null; }
fail() {
  log "ERROR: \$*"
  if [[ -x "\$BIN" ]]; then "\$BIN" notify --send "SSL deploy failed on \$(hostname)" "\$* Check \$LOG." --quiet >/dev/null 2>&1; fi
  exit 1
}
[[ -n "\${RENEWED_LINEAGE:-}" ]] || exit 0
name="\$(basename "\$RENEWED_LINEAGE")"
if [[ ! -d "\$STATE_DIR/domains/\$name" ]]; then log "renewed lineage \$name is not managed by lompstack; nothing deployed"; exit 0; fi
mkdir -p "\$DEPLOY_DIR/\$name" && chmod 0700 "\$DEPLOY_DIR" "\$DEPLOY_DIR/\$name" || fail "cannot make \$DEPLOY_DIR/\$name"
cp -L "\$RENEWED_LINEAGE/fullchain.pem" "\$DEPLOY_DIR/\$name/fullchain.pem.new" \\
  && cp -L "\$RENEWED_LINEAGE/privkey.pem" "\$DEPLOY_DIR/\$name/privkey.pem.new" || fail "Could not copy the renewed certificate for \$name."
chmod 0600 "\$DEPLOY_DIR/\$name/"*.new
mv -f "\$DEPLOY_DIR/\$name/fullchain.pem.new" "\$DEPLOY_DIR/\$name/fullchain.pem"
mv -f "\$DEPLOY_DIR/\$name/privkey.pem.new" "\$DEPLOY_DIR/\$name/privkey.pem"
log "deployed renewed certificate for \$name (\${RENEWED_DOMAINS:-})"
if nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1; then
  log "nginx reloaded after renewal of \$name"
else
  fail "Certificate \$name renewed but nginx could not be reloaded."
fi
exit 0
EOF
}

lib_nginx_ssl_setup() {
  lib_apt_install certbot || lib_die "certbot installation failed" "apt error" "check the log"
  lib_mkdir "${ACME_ROOT}/.well-known/acme-challenge" 0755 root:root
  lib_mkdir "$(dirname "$NGX_DEPLOY_HOOK")" 0755 root:root
  lib_nginx_hook_render | lib_write_file "$NGX_DEPLOY_HOOK" 0755 root:root
  # the sites' hook would restart an OpenLiteSpeed that is not here
  lib_rm "$CERTBOT_DEPLOY_HOOK"
  lib_ssl_renewal_ensure
  lib_manifest_set '.components.certbot' "$(lib_pkg_version certbot)"
  lib_ok "certbot ready (webroot ${ACME_ROOT}, renewals reload nginx)"
}

# =============================================================================
#  install --images
# =============================================================================
lib_nginx_ufw() {
  local p=""
  lib_apt_install ufw
  lib_ufw_rule default deny incoming
  lib_ufw_rule default allow outgoing
  for p in $SYS_SSH_PORTS $SSH_PORT; do lib_ufw_rule allow "${p}/tcp"; done
  if lib_cf_origin_locked; then
    lib_info "The origin is locked to Cloudflare; the rules for 80 and 443 are left as they are"
  else
    lib_ufw_rule allow 80/tcp
    lib_ufw_rule allow 443/tcp
  fi
  if (( ! OPT_DRY_RUN )); then
    if ! ufw status 2>/dev/null | sed -n 1p | lib_grepq 'Status: active'; then
      ufw show added 2>/dev/null | lib_grepq -E "allow ${SYS_SSH_PORTS%% *}/tcp" || lib_die "Refusing to enable UFW without an SSH allow rule" "SSH port ${SYS_SSH_PORTS} rule missing" "add it manually: ufw allow ${SYS_SSH_PORTS%% *}/tcp"
      lib_run ufw --force enable || lib_die "ufw enable failed" "" "check 'ufw status' and the log"
    fi
    lib_systemctl enable ufw >/dev/null 2>&1 || true
  fi
  lib_manifest_set_json '.components.ufw' true
  lib_ok "UFW active: SSH ${SYS_SSH_PORTS}${SSH_PORT:+ + $SSH_PORT}, 80/tcp, 443/tcp"
}

lib_nginx_install_pkg() {
  if (( OPT_DRY_RUN )) && ! lib_nginx_installed; then
    lib_info "[dry-run] would install nginx (Ubuntu package) and write ${NGX_CONF}"
    return 0
  fi
  lib_apt_install nginx || lib_die "nginx installation failed" "apt error" "check network / apt sources and re-run"
  lib_nginx_configure
  lib_nginx_reload
  lib_manifest_set '.components.nginx' "$(lib_nginx_version)"
  lib_ok "nginx $(lib_nginx_version): ${NGX_T_WORKERS} worker(s) x ${NGX_T_CONNS} connections"
}

lib_nginx_logrotate() {
  cat <<EOF | lib_write_file "$LOGROTATE_SELF_FILE" 0644 root:root
# Managed by lompstack
${LOG_FILE} {
  weekly
  rotate 12
  compress
  delaycompress
  missingok
  notifempty
  dateext
  create 0600 root root
}
EOF
  cat <<EOF | lib_write_file "$NGX_LOGROTATE_FILE" 0644 root:root
# Managed by lompstack - the image sites' nginx logs
${SITES_LOG_ROOT}/*/*.log {
  daily
  rotate 14
  compress
  delaycompress
  missingok
  notifempty
  dateext
  sharedscripts
  postrotate
    [ -s /run/nginx.pid ] && kill -USR1 "\$(cat /run/nginx.pid)" 2>/dev/null || true
  endscript
}
EOF
  lib_ok "logrotate configured (${LOGROTATE_SELF_FILE}, ${NGX_LOGROTATE_FILE})"
}

lib_nginx_cron_base() {
  local id="" added=()
  for id in healthcheck nginx-perms; do lib_cron_has "$id" || added+=("$id"); done
  lib_cron_set healthcheck "15 6 * * * root ${BIN_LINK} healthcheck"
  lib_cron_set nginx-perms "${NGX_PERMS_CRON} root ${BIN_LINK} nginx-perms"
  # the sites' checks look for OpenLiteSpeed, which an image server has not
  lib_cron_remove htaccess
  lib_cron_remove ols-logs
  INS_CRON_ADDED="${added[*]-}"
  return 0
}

lib_nginx_manifest() {
  local rerun="$1"
  (( OPT_DRY_RUN )) && return 0
  lib_manifest_set '.version' "$SCRIPT_VERSION"
  (( rerun )) || lib_manifest_set '.installed_at' "$(lib_iso_now)"
  [[ -n "$(lib_manifest_get '.installed_at')" ]] || lib_manifest_set '.installed_at' "$(lib_iso_now)"
  lib_manifest_set '.last_install_run' "$(lib_iso_now)"
  lib_manifest_set_json '.os' "$(jq -n --arg id "$OS_ID" --arg v "$OS_VERSION_ID" --arg c "$OS_CODENAME" --arg a "$SYS_ARCH" '{id:$id, version:$v, codename:$c, arch:$a}')"
  lib_manifest_set '.components.nginx' "$(lib_nginx_version)"
  lib_manifest_merge_json '.params' "$(jq -n --arg tz "$TIMEZONE" --arg em "$DEFAULT_EMAIL" \
      --arg ssh "${SYS_SSH_PORTS}${SSH_PORT:+ $SSH_PORT}" --arg f2b "$FAIL2BAN_IGNORE_IP" \
      --argjson ar "$( (( INS_AUTO_REBOOT )) && printf 'true' || printf 'false')" \
      '{role:"images", timezone:$tz, email:$em, ssh_ports:$ssh, auto_reboot:$ar, fail2ban_ignore_ip:$f2b}')"
  lib_manifest_set_json '.profile' "$(lib_system_profile_json)"
  lib_ok "Manifest updated (${STATE_DIR}/manifest.json)"
}

# What may not become an image server: one that already serves sites with OpenLiteSpeed. Its
# sites would stop answering the moment nginx took port 80.
lib_nginx_install_guard() {
  local d=""
  while read -r d; do
    [[ -n "$d" ]] || continue
    if [[ "$(lib_json_get "$(lib_domain_json "$d")" '.mode')" != "images" ]]; then
      lib_die "This server hosts OpenLiteSpeed sites, so it cannot become an image server" \
        "nginx would take ports 80 and 443 from them" "use a server of its own for the images: lomp install --images there"
    fi
  done < <(lib_domains_list)
  if [[ -x "${LSWS_HOME}/bin/openlitespeed" ]] || lib_service_active lsws; then
    lib_die "OpenLiteSpeed is installed here, so this cannot become an image server" \
      "nginx and OpenLiteSpeed would both want ports 80 and 443" "start from a fresh Ubuntu 22.04 / 24.04 server"
  fi
  if (( INS_WITH_MAIL || INS_WITH_NODE || INS_WITH_PYTHON || INS_WITH_NETDATA )); then
    lib_die "An image server takes no optional components" "--with-mail, --with-node, --with-python and --with-netdata belong to the sites' server" \
      "lomp install --images [--email you@example.com] [--cloudflare]"
  fi
  return 0
}

lib_nginx_install_main() {   # rerun(0/1)
  local rerun="$1"
  lib_nginx_install_guard
  if (( ! OPT_DRY_RUN )); then lib_manifest_set '.params.role' "images"; fi
  lib_info "Image server: nginx serves the files of every domain added here; no OpenLiteSpeed, PHP, MariaDB or Redis"
  lib_steps_begin 15

  lib_step "Command installation (lomp)"
  lib_install_self

  lib_step "System analysis"
  lib_system_analyze
  lib_system_report
  lib_system_profile
  lib_nginx_tune_report
  (( OPT_DRY_RUN )) && lib_warn "DRY RUN: nothing will be changed; the plan below shows what a real run would do"

  lib_step "Base packages and system upgrade"
  lib_install_base_packages

  lib_step "Timezone and NTP"
  lib_system_timezone_apply
  lib_system_ntp_apply

  lib_step "Kernel parameters, limits and swap"
  lib_system_sysctl_apply
  lib_system_limits_apply
  lib_system_swap_ensure

  lib_step "Unattended security updates"
  lib_install_unattended

  lib_step "Firewall (UFW)"
  lib_nginx_ufw

  lib_step "SSH hardening"
  lib_install_ssh_harden

  lib_step "Fail2ban"
  lib_install_fail2ban

  lib_step "nginx"
  lib_nginx_install_pkg

  lib_step "SSL infrastructure (certbot)"
  [[ -n "$INS_CF_TOKEN" ]] && lib_cf_store_token "$INS_CF_TOKEN"
  lib_nginx_ssl_setup

  lib_step "Cloudflare real-IP mode"
  if (( INS_CLOUDFLARE )) || lib_cf_enabled; then
    lib_cf_enable
    lib_nginx_installed && lib_nginx_cf_apply
  else
    lib_info "Cloudflare mode disabled (enable with --cloudflare)"
  fi

  lib_step "Log rotation and scheduled tasks"
  lib_nginx_logrotate
  lib_nginx_cron_base
  lib_cf_enabled && lib_cf_schedule
  lib_ok "Scheduled tasks in ${CRON_FILE} (healthcheck daily 06:15, uploads made readable every 10 minutes)"

  lib_step "Manifest"
  lib_nginx_manifest "$rerun"

  lib_step "Summary"
  printf '\n%s%s=== Image server %s ===%s\n' "$C_BLD" "$C_GRN" "$( (( rerun )) && printf 'verified' || printf 'ready')" "$C_RST"
  lib_print_kv "Web server" "nginx $(lib_nginx_version) (${NGX_CONF})"
  lib_print_kv "Add a domain" "lomp add images.example.com [--www] [--no-ssl] [--cache-days 30]"
  lib_print_kv "Files" "${SITES_ROOT}/<domain>/public_html   (upload over SFTP)"
  lib_print_kv "Health" "lomp status | lomp doctor"
  lib_print_kv "Re-tune" "lomp optimize   (after the VPS got more CPU or memory)"
  lib_print_kv "Log" "$LOG_FILE"
  lib_system_reboot_required && lib_warn "A reboot is required to finish kernel/package updates (reboot at your convenience)."
  (( OPT_DRY_RUN )) && lib_warn "DRY RUN finished - no changes were made."
  printf '\n'
  (( OPT_DRY_RUN )) || lib_notify_send "Image server $( (( rerun )) && printf 'verified' || printf 'installed')" \
    "setup.sh ${SCRIPT_VERSION} finished on $(hostname). nginx $(lib_nginx_version)." || true
  return 0
}

# =============================================================================
#  optimize / update / migrate on an image server
# =============================================================================
lib_nginx_optimize_main() {
  local changes=() c=""
  lib_require_tools
  lib_require_installed
  lib_system_analyze
  lib_system_report
  lib_system_profile
  lib_nginx_tune_report
  lib_heading "Proposed changes"
  lib_system_render_sysctl | _opt_diff "Kernel parameters" "$SYSCTL_FILE" && changes+=(sysctl)
  lib_system_render_limits | _opt_diff "Limits" "$LIMITS_FILE" && changes+=(limits)
  lib_nginx_render_conf | _opt_diff "nginx" "$NGX_CONF" && changes+=(nginx)
  if ((${#changes[@]} == 0)); then lib_ok "Everything is already tuned for this hardware; nothing to do."; return 0; fi
  printf '\n'
  lib_confirm "Apply these changes (${changes[*]})?" y || { lib_info "No changes applied."; return 0; }
  for c in "${changes[@]}"; do
    case "$c" in
      sysctl) lib_system_sysctl_apply ;;
      limits) lib_system_limits_apply ;;
      nginx)  lib_nginx_configure; lib_nginx_reload ;;
    esac
  done
  (( OPT_DRY_RUN )) || lib_manifest_set_json '.profile' "$(lib_system_profile_json)"
  lib_ok "Optimisation applied"
}

lib_nginx_migrate() {
  lib_nginx_cron_base
  if [[ -z "$INS_CRON_ADDED" ]]; then lib_ok "Scheduled tasks in ${CRON_FILE} are all in place"
  elif (( OPT_DRY_RUN )); then lib_info "[dry-run] would add to ${CRON_FILE}, which this server is missing: ${INS_CRON_ADDED}"
  else lib_ok "Added to ${CRON_FILE}, which this server was missing: ${INS_CRON_ADDED}"; fi
  lib_nginx_hook_render | lib_write_file "$NGX_DEPLOY_HOOK" 0755 root:root
  lib_system_analyze --no-net
  lib_nginx_configure
  if (( NGX_CHANGED )); then lib_nginx_reload; lib_ok "nginx configuration rewritten the way this release writes it"
  else lib_ok "nginx configuration is up to date"; fi
  lib_domain_fail2ban_regen
  return 0
}

lib_nginx_update_main() {
  local before="" after=""
  lib_require_tools
  lib_require_installed
  lib_system_analyze --no-net
  lib_steps_begin 3
  lib_step "Package update"
  before="$(lib_nginx_version)"
  LIB_APT_UPDATED=0
  lib_apt_update
  if (( OPT_DRY_RUN )); then
    lib_info "[dry-run] upgradable packages:"; apt list --upgradable 2>/dev/null | sed 's/^/        /' | sed -n '1,40p' || true
  else
    lib_run apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade || lib_die "apt-get upgrade failed" "see the log" "fix apt problems (apt-get -f install) and re-run"
    lib_run apt-get -y -q autoremove || true
  fi
  after="$(lib_nginx_version)"
  _ver_report_line "nginx" "$before" "$after"
  lib_step "nginx"
  if (( ! OPT_DRY_RUN )); then
    lib_nginx_test || lib_die "nginx config test failed after the update" "${NGX_TEST_OUTPUT##*$'\n'}" "sudo nginx -t"
    if [[ "$before" != "$after" ]]; then lib_systemctl restart nginx || lib_die "nginx did not start after the update" "journalctl -u nginx" ""
      lib_ok "nginx restarted"
    else lib_ok "nginx unchanged (no restart)"; fi
    lib_manifest_set '.components.nginx' "$after"
    lib_manifest_set '.last_update' "$(lib_iso_now)"
  fi
  lib_step "Housekeeping"
  lib_cf_enabled && { lib_cf_update_ips || true; }
  lib_install_self
  lib_nginx_migrate
  lib_system_reboot_required && lib_warn "Reboot required to activate the new kernel/libraries."
  lib_ok "Update finished"
}

# =============================================================================
#  status / doctor
# =============================================================================
lib_nginx_status_main() {
  local json=0 svc="" d="" n=0
  [[ "${1:-}" == "--json" ]] && json=1
  (( OPT_JSON )) && json=1
  lib_require_tools
  lib_system_analyze --no-net
  lib_nginx_tune
  local -A st=()
  for svc in nginx fail2ban ufw certbot.timer; do st["$svc"]="$(_svc_state "$svc")"; done
  while read -r d; do [[ -n "$d" ]] && n=$((n + 1)); done < <(lib_domains_list)
  if (( json )); then
    jq -n --arg host "$(hostname)" --arg ver "$SCRIPT_VERSION" --arg ngx "$(lib_nginx_version)" \
      --arg n "${st[nginx]}" --arg f "${st[fail2ban]}" --arg u "${st[ufw]}" --arg c "${st[certbot.timer]}" \
      --argjson sites "$n" --argjson cores "${SYS_CPU_CORES:-1}" --argjson ram "${SYS_RAM_MB:-0}" \
      --argjson w "$NGX_T_WORKERS" --argjson conns "$NGX_T_CONNS" --argjson disk "${SYS_DISK_USED_PCT:-0}" \
      '{host:$host, role:"images", lompstack:$ver, nginx:{version:$ngx, workers:$w, connections:$conns},
        services:{nginx:$n, fail2ban:$f, ufw:$u, "certbot.timer":$c}, sites:$sites,
        hardware:{cpu_cores:$cores, ram_mb:$ram, disk_used_pct:$disk}}'
    return 0
  fi
  lib_heading "Image server $(hostname)"
  lib_print_kv "lompstack" "$SCRIPT_VERSION"
  lib_print_kv "nginx" "$(lib_nginx_version) - ${NGX_T_WORKERS} worker(s) x ${NGX_T_CONNS} connections"
  lib_print_kv "Hardware" "${SYS_CPU_CORES} core(s), ${SYS_RAM_MB} MB RAM ($(( SYS_RAM_MB - SYS_RAM_AVAIL_MB )) MB used), disk ${SYS_DISK_USED_PCT}% used"
  for svc in nginx fail2ban ufw certbot.timer; do lib_print_kv "$svc" "${st[$svc]}"; done
  lib_print_kv "Sites" "${n} (lomp list)"
  lib_system_reboot_required && lib_warn "A reboot is required"
  return 0
}

lib_nginx_doctor_checks() {
  local svc="" d="" days="" home=""
  for svc in nginx fail2ban; do
    if lib_service_active "$svc"; then _doc_add OK "${svc} service" "running"; else _doc_add FAIL "${svc} service" "not running (systemctl status ${svc})"; fi
  done
  if ufw status 2>/dev/null | sed -n 1p | lib_grepq 'Status: active'; then _doc_add OK "firewall" "UFW active"; else _doc_add FAIL "firewall" "UFW inactive"; fi
  if lib_nginx_test; then _doc_add OK "nginx configuration" "nginx -t passes"; else _doc_add FAIL "nginx configuration" "${NGX_TEST_OUTPUT##*$'\n'}"; fi
  lib_nginx_tune
  if [[ -f "$NGX_CONF" ]] && cmp -s "$NGX_CONF" <(lib_nginx_render_conf); then _doc_add OK "nginx tuning" "sized for ${SYS_CPU_CORES} core(s), ${SYS_RAM_MB} MB"
  else _doc_add WARN "nginx tuning" "not sized for this machine any more (lomp optimize)"; fi
  if [[ -n "$(lib_ssl_renewal_how)" ]]; then _doc_add OK "certificate renewal" "certbot renew runs ($(lib_ssl_renewal_how))"
  else _doc_add FAIL "certificate renewal" "nothing runs certbot renew (lomp install --images repairs it)"; fi
  if [[ -x "$NGX_DEPLOY_HOOK" ]]; then _doc_add OK "renewal hook" "renewed certificates reload nginx"
  else _doc_add WARN "renewal hook" "${NGX_DEPLOY_HOOK} missing (lomp update)"; fi
  if (( ${SYS_DISK_USED_PCT:-0} >= 90 )); then _doc_add FAIL "disk space" "${SYS_DISK_USED_PCT}% used"
  elif (( ${SYS_DISK_USED_PCT:-0} >= 80 )); then _doc_add WARN "disk space" "${SYS_DISK_USED_PCT}% used"
  else _doc_add OK "disk space" "${SYS_DISK_USED_PCT:-0}% used"; fi
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_nginx_site_load "$d" || continue
    home="$(lib_domain_home "$d")"
    if [[ ! -f "$(_ngx_site_file "$d")" ]]; then _doc_add FAIL "site ${d}" "no nginx site file (lomp update writes it again)"; continue; fi
    if [[ -n "$NGX_S_REDIRECT" ]]; then
      if ! lib_domain_registered "$NGX_S_REDIRECT"; then _doc_add WARN "site ${d}" "redirects to ${NGX_S_REDIRECT}, which is no site here any more (lomp remove ${d})"
      elif (( NGX_S_SSL )) && [[ -z "$(lib_ssl_days_left "$d")" ]]; then _doc_add FAIL "site ${d}" "redirects to ${NGX_S_REDIRECT}, but its certificate is missing (lomp renew-ssl ${d})"
      else _doc_add OK "site ${d}" "redirects to ${NGX_S_REDIRECT}"; fi
      continue
    fi
    if [[ ! -d "${home}/public_html" ]]; then _doc_add FAIL "site ${d}" "${home}/public_html is missing"; continue; fi
    if (( NGX_S_SSL )); then
      days="$(lib_ssl_days_left "$d")"
      if [[ -z "$days" ]]; then _doc_add FAIL "site ${d}" "certificate missing (lomp renew-ssl ${d})"
      elif (( days < 7 )); then _doc_add FAIL "site ${d}" "certificate expires in ${days} days (lomp renew-ssl ${d})"
      elif (( days < 20 )); then _doc_add WARN "site ${d}" "certificate expires in ${days} days"
      else _doc_add OK "site ${d}" "https, certificate ${days} days"; fi
    else
      _doc_add OK "site ${d}" "http only (lomp renew-ssl ${d} for https)"
    fi
  done < <(lib_domains_list)
  return 0
}

# =============================================================================
#  Commands on an image server
# =============================================================================
# setup.sh asks this before its own dispatch: 0 when the command is lib_nginx_dispatch's (it
# runs it or refuses it), 1 when it is the one every server runs (install, self-update,
# notify ...) or one that looks at the server's role itself (status, doctor, optimize, update).
# A predicate of its own, so the command never runs as the condition of an "if", where errexit
# is off for everything it calls.
lib_nginx_owns() {   # command
  case "$1" in
    install|self-update|migrate|update|optimize|status|doctor|healthcheck|logs|notify|menu|update-cf-ips|help|version) return 1 ;;
  esac
  return 0
}

lib_nginx_dispatch() {   # command args...
  local cmd="$1"; shift
  case "$cmd" in
    add)            lib_nginx_add_main "$@" ;;
    remove|delete)  lib_nginx_remove_main "$@" ;;
    list)           lib_nginx_list_main "$@" ;;
    renew-ssl)      lib_nginx_renew_ssl_main "$@" ;;
    rename)         lib_nginx_rename_main "$@" ;;
    nginx-perms)    lib_nginx_perms_main ;;
    htaccess-check) ;;   # an older cron line: nothing of OpenLiteSpeed to watch here
    *)
      lib_die "'${cmd}' is not part of an image server" \
        "this server was installed with --images: nginx serves files; there is no PHP, database, mail or OpenLiteSpeed here" \
        "lomp help   (an image server: add, remove, rename, list, logs, renew-ssl, status, doctor, optimize, update, self-update)" ;;
  esac
  return 0
}

# =============================================================================
#  The messages above in Turkish (lib/lang.sh explains the table)
# =============================================================================
LIB_TR_PAIRS+=(
  'Image server: nginx serves the files of every domain added here; no OpenLiteSpeed, PHP, MariaDB or Redis' 'Resim sunucusu: buraya eklenen her alan adının dosyalarını nginx sunar; OpenLiteSpeed, PHP, MariaDB ya da Redis yok'
  'Directories' 'Dizinler'
  'nginx site' 'nginx sitesi'
  'Finishing' 'Bitiriliyor'
  'Log rotation and scheduled tasks' 'Günlük döndürme ve zamanlanmış görevler'
  'Files go into {1}' 'Dosyalar {1} içine konur'
  'nginx serves {1}' 'nginx {1} adresini sunuyor'
  'No certificate requested (--no-ssl). Later: lomp renew-ssl {1}' 'Sertifika istenmedi (--no-ssl). Sonra: lomp renew-ssl {1}'
  'DNS of {1} does not point here yet: {2}' '{1} alan adının DNS kaydı henüz buraya göstermiyor: {2}'
  'the site works over http meanwhile; once DNS is right: lomp renew-ssl {1}' 'site bu arada http üzerinden çalışır; DNS düzelince: lomp renew-ssl {1}'
  'the site works over http meanwhile; try again with: lomp renew-ssl {1}' 'site bu arada http üzerinden çalışır; yeniden denemek için: lomp renew-ssl {1}'
  'https://{1}/ is served with a Let'\''s Encrypt certificate' 'https://{1}/ bir Let'\''s Encrypt sertifikasıyla sunuluyor'
  'https://{1}/ is served with the new certificate' 'https://{1}/ yeni sertifikayla sunuluyor'
  'nginx no longer serves {1}' 'nginx artık {1} alan adını sunmuyor'
  'Remove {1}: {2}?' '{1} kaldırılsın mı: {2}?'
  'Site {1} removed' '{1} sitesi kaldırıldı'
  'Files kept in {1}' 'Dosyalar {1} içinde bırakıldı'
  '{1} is no image site' '{1} bir resim sitesi değil'
  'Unknown option for add on an image server: {1}' 'Resim sunucusunda add için bilinmeyen seçenek: {1}'
  'this server serves files with nginx: there is no PHP, WordPress, database or proxy here' 'bu sunucu dosyaları nginx ile sunar: burada PHP, WordPress, veritabanı ya da proxy yok'
  'Invalid --cache-days '\''{1}'\''' 'Geçersiz --cache-days '\''{1}'\'''
  'a number of days between 1 and 3650' '1 ile 3650 arasında bir gün sayısı'
  'Add {1} with --www instead of {2}' '{2} yerine {1} alan adını --www ile ekleyin'
  'the www name is the second name of a site' 'www adı bir sitenin ikinci adıdır'
  'nginx is not installed' 'nginx kurulu değil'
  'nginx refused the site {1}' 'nginx {1} sitesini kabul etmedi'
  'nginx refused {1}; the previous version was put back' 'nginx {1} dosyasını kabul etmedi; önceki hâli geri kondu'
  'nginx refuses its configuration' 'nginx yapılandırmasını kabul etmiyor'
  'nginx could not be reloaded' 'nginx yeniden yüklenemedi'
  'nginx did not start' 'nginx başlamadı'
  'DNS of {1} does not point here' '{1} alan adının DNS kaydı buraya göstermiyor'
  '{1} is not part of an image server' '{1} bir resim sunucusunun parçası değil'
  'this server was installed with --images: nginx serves files; there is no PHP, database, mail or OpenLiteSpeed here' 'bu sunucu --images ile kuruldu: dosyaları nginx sunar; burada PHP, veritabanı, posta ya da OpenLiteSpeed yok'
  'This server hosts OpenLiteSpeed sites, so it cannot become an image server' 'Bu sunucu OpenLiteSpeed siteleri barındırıyor, bu yüzden resim sunucusu olamaz'
  'OpenLiteSpeed is installed here, so this cannot become an image server' 'Burada OpenLiteSpeed kurulu, bu yüzden bu sunucu resim sunucusu olamaz'
  'An image server takes no optional components' 'Resim sunucusuna isteğe bağlı bileşen kurulmaz'
  'nginx workers' 'nginx işçileri'
  'Connections' 'Bağlantılar'
  'File cache' 'Dosya önbelleği'
  'Disk reads' 'Disk okumaları'
  'Upload to' 'Yükleme yeri'
  'Example' 'Örnek'
  'Browser cache' 'Tarayıcı önbelleği'
  'Re-tune' 'Yeniden ayarla'
  'Web server' 'Web sunucusu'
  '(no sites yet - add one with: lomp add example.com)' '(henüz site yok - eklemek için: lomp add example.com)'
  'certbot ready (webroot {1}, renewals reload nginx)' 'certbot hazır (webroot {1}, yenilemeler nginx'\''i yeniden yükler)'
  'nginx configuration rewritten the way this release writes it' 'nginx yapılandırması bu sürümün yazdığı biçimde yeniden yazıldı'
  'nginx configuration is up to date' 'nginx yapılandırması güncel'
  'nginx restarted' 'nginx yeniden başlatıldı'
  'nginx unchanged (no restart)' 'nginx değişmedi (yeniden başlatılmadı)'
  'Image server {1}' 'Resim sunucusu {1}'
  'Renewing every certificate that is due (certbot renew)' 'Süresi gelen her sertifika yenileniyor (certbot renew)'
  '@doctor nginx configuration' 'nginx yapılandırması'
  '@doctor nginx tuning' 'nginx ayarı'
  '@doctor nginx -t passes' 'nginx -t geçiyor'
  '@doctor not sized for this machine any more (lomp optimize)' 'artık bu makineye göre boyutlu değil (lomp optimize)'
  '@doctor renewal hook' 'yenileme kancası'
  '@doctor renewed certificates reload nginx' 'yenilenen sertifikalar nginx'\''i yeniden yükler'
  '@doctor http only (lomp renew-ssl {1} for https)' 'yalnızca http (https için lomp renew-ssl {1})'
  '@doctor https, certificate {1} days' 'https, sertifika {1} gün'
  '@doctor redirects to {1}' '{1} adresine yönlendiriyor'
  '@doctor redirects to {1}, which is no site here any more (lomp remove {2})' '{1} adresine yönlendiriyor, ama o artık burada bir site değil (lomp remove {2})'
  '@doctor redirects to {1}, but its certificate is missing (lomp renew-ssl {2})' '{1} adresine yönlendiriyor, ama sertifikası yok (lomp renew-ssl {2})'
  'Rename {1} to {2}: {3}?' '{1} adı {2} olarak değiştirilsin mi: {3}?'
  'its files move to {1}, and {2} answers 301 to {3}' 'dosyaları {1} konumuna taşınır ve {2} adresi {3} adresine 301 ile yönlenir'
  'its files move to {1}, and {2} is removed with its certificate' 'dosyaları {1} konumuna taşınır ve {2} sertifikasıyla birlikte kaldırılır'
  'nginx site for {1}' '{1} için nginx sitesi'
  'nginx site for {1} written' '{1} için nginx sitesi yazıldı'
  'Files and logs' 'Dosyalar ve günlükler'
  'http://{1}/ serves the files of {2}' 'http://{1}/ artık {2} dosyalarını sunuyor'
  '{1} only redirects to {2}' '{1} yalnızca {2} adresine yönlendiriyor'
  'there are no files under that name to move' 'o adın altında taşınacak dosya yok'
  '{1} already has that name' '{1} zaten bu adı taşıyor'
  '{1} is already there' '{1} zaten var'
  'the files of {1} would be moved into it' '{1} dosyaları onun içine taşınırdı'
  'there are no files to move' 'taşınacak dosya yok'
  'Rename to {1} with --www instead of {2}' '{2} yerine {1} adını --www ile kullanın'
  'Old and new domain missing' 'Eski ve yeni alan adı eksik'
  'New domain missing' 'Yeni alan adı eksik'
)
