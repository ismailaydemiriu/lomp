#!/usr/bin/env bash
# lib/webmail.sh - Roundcube webmail for the domains that have mail. The code comes from
#                  upstream's own release tarball, verified against a pinned signing key
#                  before anything is unpacked, and lives in a directory per version with
#                  "current" pointing at the one in use: an update that does not answer is
#                  undone by moving one symlink back.
#
# The application is not a site. It runs as its own user (lompwebmail), under a single
# server-level LSPHP process shared by every webmail vhost, and it reaches Dovecot and
# Postfix over the loopback only. A site's PHP can neither read its configuration nor its
# database credentials.

WM_USER="${MAIL_WEBMAIL_USER:-lompwebmail}"
WM_CODE_OWNER="${WM_CODE_OWNER:-www-data}"   # owns the code; nothing on this machine runs as it
WM_ROOT="/var/www/lomp-webmail"
WM_RELEASES="${WM_ROOT}/releases"
WM_CURRENT="${WM_ROOT}/current"
WM_ETC="/etc/lomp-webmail"
WM_CONF="${WM_ETC}/config.inc.php"
WM_KEYRING="${WM_ETC}/roundcube-release.gpg"
WM_VAR="/var/lib/lomp-webmail"
WM_LOG_DIR="/var/log/lomp-webmail"
WM_INFO="${STATE_DIR}/webmail.info"          # database credentials, 0600 root
WM_BRANCH="${WM_BRANCH:-1.7}"                # the branch this release of lomp installs
WM_VERSION="${WM_VERSION:-1.7.4}"            # the version it starts from
WM_DL_BASE="https://github.com/roundcube/roundcubemail/releases/download"
WM_KEY_URL="https://roundcube.net/download/pubkey.asc"
WM_API_RELEASES="https://api.github.com/repos/roundcube/roundcubemail/releases?per_page=30"
# Roundcube signs its releases with this key. Upstream states the identity and the short id
# ("Roundcube Developers <devs@roundcube.net>, alias 41C4F7D5") but publishes no full
# fingerprint on a page, so it is pinned here from the key roundcube.net itself serves. A key
# that does not match is not a key we accept: the download stops rather than trusting it.
WM_KEY_FPR="F3E4C04BB3DB5D4215C45F7F5AB2BAA141C4F7D5"
# 1.7 runs on PHP 8.1 up to but not including 8.6 (composer.json). Outside that range the
# webmail is not installed rather than installed broken.
WM_PHP_MIN="8.1"
WM_PHP_MAX="8.5"
WM_LAST_ERROR=""

lib_webmail_installed() { [[ -L "$WM_CURRENT" && -s "${WM_CURRENT}/public_html/index.php" ]]; }

lib_webmail_version() {
  local p=""
  p="$(readlink -f "$WM_CURRENT" 2>/dev/null || true)"
  [[ -n "$p" ]] || return 1
  printf '%s' "${p##*/}"
}

# The name of a domain's webmail. One host name per domain, so a login is always for the
# domain the operator is looking at.
lib_webmail_host() { printf 'webmail.%s' "$1"; }

# The OpenLiteSpeed names. The leading underscore keeps them out of reach of a site: a domain
# may not start with one, so a site can never be created that collides with a webmail vhost.
lib_webmail_vhost_name() { printf '_wm_%s' "$(lib_domain_ident "$1")"; }

# The PHP this webmail may run on: the server default when it is in range, otherwise the
# newest installed version that is.
lib_webmail_php_version() {
  local v="" best=""
  v="$(lib_php_default_version)"
  if [[ -n "$v" ]] && lib_version_ge "$v" "$WM_PHP_MIN" && lib_version_ge "$WM_PHP_MAX" "$v"; then
    printf '%s' "$v"; return 0
  fi
  while read -r v; do
    [[ -n "$v" ]] || continue
    lib_version_ge "$v" "$WM_PHP_MIN" || continue
    lib_version_ge "$WM_PHP_MAX" "$v" || continue
    best="$v"
  done < <(lib_php_installed_versions | sort -V || true)
  [[ -n "$best" ]] || return 1
  printf '%s' "$best"
}

# =============================================================================
#  Getting the code, and being sure of it
# =============================================================================
# Nothing is unpacked before its signature has been checked against the pinned key. The
# tarball comes from GitHub, the key from roundcube.net: two hosts have to be wrong at the
# same time for a bad release to get in.
_wm_keyring_ensure() {
  local tmp="" fpr=""
  if [[ -s "$WM_KEYRING" ]]; then
    fpr="$(_wm_keyring_fpr)"
    [[ "$fpr" == "$WM_KEY_FPR" ]] && return 0
    lib_warn "the stored Roundcube signing key is not the expected one; fetching it again"
  fi
  lib_have gpg || lib_apt_install gnupg || { WM_LAST_ERROR="gnupg could not be installed"; return 1; }
  tmp="$(lib_mktemp)"
  if ! curl -fsSL --retry 2 --max-time 30 "$WM_KEY_URL" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"; WM_LAST_ERROR="the signing key could not be downloaded from ${WM_KEY_URL}"; return 1
  fi
  lib_mkdir "$WM_ETC" 0755 root:root
  if ! gpg --dearmor <"$tmp" >"${WM_KEYRING}.new" 2>/dev/null; then
    rm -f "$tmp" "${WM_KEYRING}.new"; WM_LAST_ERROR="the downloaded key is not a PGP key"; return 1
  fi
  rm -f "$tmp"
  # exactly one primary key, and it is the pinned one: a second key in the same file would be
  # a second key gpgv accepts signatures from
  fpr="$(WM_KEYRING="${WM_KEYRING}.new" _wm_keyring_fpr)"
  if [[ "$fpr" != "$WM_KEY_FPR" ]]; then
    rm -f "${WM_KEYRING}.new"
    WM_LAST_ERROR="the key at ${WM_KEY_URL} is $(tr '\n' ' ' <<<"${fpr:-none}"), not ${WM_KEY_FPR} alone"
    return 1
  fi
  mv -f "${WM_KEYRING}.new" "$WM_KEYRING"
  chmod 0644 "$WM_KEYRING"
  lib_log_write INFO "Roundcube signing key stored (${WM_KEY_FPR})"
  return 0
}

# The fingerprint of every PRIMARY key in the keyring, one per line. Not the first one: gpgv
# accepts a signature from any key in the file it is given, so a keyring holding the real key
# and one more would pass a check that stopped at the first - which is exactly what somebody
# able to answer for roundcube.net would send.
_wm_keyring_fpr() {
  lib_have gpg || return 1
  gpg --show-keys --with-colons --with-fingerprint "$WM_KEYRING" 2>/dev/null \
    | awk -F: '/^pub:/{p=1; next} /^fpr:/{ if (p) { print $10; p=0 } } /^sub:/{p=0}' || true
}

# Download one release and unpack it into its own directory. Prints the directory.
_wm_fetch_release() {   # version -> path of the unpacked release on stdout
  local ver="$1" tmp="" tgz="" asc="" dest="${WM_RELEASES}/${1}" url=""
  url="${WM_DL_BASE}/${ver}/roundcubemail-${ver}-complete.tar.gz"
  _wm_keyring_ensure || return 1
  lib_have gpgv || lib_apt_install gpgv || { WM_LAST_ERROR="gpgv could not be installed"; return 1; }
  tmp="$(lib_mktemp -d)"
  tgz="${tmp}/roundcube.tar.gz"
  asc="${tgz}.asc"
  if ! curl -fsSL --retry 2 --max-time 180 "$url" -o "$tgz" 2>/dev/null; then
    rm -rf "$tmp"; WM_LAST_ERROR="Roundcube ${ver} could not be downloaded (${url})"; return 1
  fi
  if ! curl -fsSL --retry 2 --max-time 30 "${url}.asc" -o "$asc" 2>/dev/null; then
    rm -rf "$tmp"; WM_LAST_ERROR="the signature of Roundcube ${ver} could not be downloaded"; return 1
  fi
  # Not just "gpgv is happy": gpgv is happy with any key in the keyring, so what it says is
  # read back. VALIDSIG's last field is the fingerprint of the PRIMARY key behind the signing
  # subkey, and it has to be the one pinned here.
  if ! gpgv --status-fd 1 --keyring "$WM_KEYRING" "$asc" "$tgz" 2>/dev/null \
       | awk -v want="$WM_KEY_FPR" '/^\[GNUPG:\] VALIDSIG /{ if ($NF == want) { ok=1 } } END{ exit !ok }'; then
    rm -rf "$tmp"
    WM_LAST_ERROR="the signature of Roundcube ${ver} was not made by ${WM_KEY_FPR}"
    return 1
  fi
  lib_mkdir "$WM_RELEASES" 0755 root:root
  rm -rf "${dest}.part"
  mkdir -p "${dest}.part"
  if ! tar -xzf "$tgz" -C "${dest}.part" --strip-components=1 2>/dev/null; then
    rm -rf "$tmp" "${dest}.part"; WM_LAST_ERROR="the Roundcube ${ver} archive could not be unpacked"; return 1
  fi
  rm -rf "$tmp"
  # the entry point of 1.7 is public_html/; a tarball without it is not what we think it is
  if [[ ! -s "${dest}.part/public_html/index.php" ]]; then
    rm -rf "${dest}.part"; WM_LAST_ERROR="the unpacked Roundcube ${ver} has no public_html/index.php"; return 1
  fi
  # the installer can read the configuration, including the database password. It is taken
  # out here rather than switched off in the configuration: what is not there cannot be
  # served, and upstream's own updater keeps it deleted once it is gone.
  rm -rf "${dest}.part/installer"
  lib_webmail_pw_driver_install "${dest}.part"
  rm -rf "$dest"
  mv "${dest}.part" "$dest"
  # Not root, and not the user that runs it. OpenLiteSpeed refuses a document root whose
  # owner is below its minimum uid - it says so and its own configuration test then fails -
  # so root is out; the webmail user is out because code it owns is code it can rewrite.
  # www-data is the conventional owner of web content here and nothing on this machine runs
  # as it: OpenLiteSpeed runs as nobody, a site as its own user, the webmail as lompwebmail.
  if id -u "$WM_CODE_OWNER" >/dev/null 2>&1; then chown -R "${WM_CODE_OWNER}:${WM_CODE_OWNER}" "$dest"
  else chown -R root:root "$dest"; fi
  chmod -R go-w "$dest"
  # The configuration directory is not for everybody. Nothing lompstack writes into it is a
  # secret - the real file lives outside the release and only a link points at it - but it is
  # where upstream's own updater puts a copy of the live configuration when it migrates a
  # renamed key, and the rest of the tree is deliberately world-readable. The PHP workers run
  # as the webmail user, so that is the group.
  if id -u "$WM_USER" >/dev/null 2>&1; then
    chown "${WM_CODE_OWNER}:${WM_USER}" "${dest}/config" 2>/dev/null || true
    chmod 0750 "${dest}/config" 2>/dev/null || true
  fi
  printf '%s' "$dest"
  return 0
}

# The newest release of the branch this version of lomp knows how to configure. A newer
# branch is not taken by itself: its configuration keys may have been renamed, and an
# unattended update must never end in a webmail that no longer starts.
lib_webmail_latest() {   # -> version on stdout
  local out="" v=""
  out="$(curl -fsSL --retry 2 --max-time 30 -H 'Accept: application/vnd.github+json' "$WM_API_RELEASES" 2>/dev/null || true)"
  [[ -n "$out" ]] || { WM_LAST_ERROR="the release list could not be read"; return 1; }
  v="$(jq -r --arg b "$WM_BRANCH." '[.[] | select(.prerelease == false) | .tag_name
        | select(startswith($b))] | .[0] // empty' <<<"$out" 2>/dev/null || true)"
  [[ -n "$v" ]] || { WM_LAST_ERROR="no ${WM_BRANCH}.x release in the list"; return 1; }
  printf '%s' "$v"
  return 0
}

# =============================================================================
#  State: the database and the key that encrypts a session's IMAP password
# =============================================================================
# Both are made once and never regenerated: a new des_key logs everybody out, and a new
# database loses their address books and settings. They live in one 0600 file, never in
# domain.json and never in the log.
_wm_info_load() {
  WM_DB_NAME=""; WM_DB_USER=""; WM_DB_PASS=""; WM_DES_KEY=""
  [[ -s "$WM_INFO" ]] || return 1
  # shellcheck source=/dev/null
  source "$WM_INFO"
  [[ -n "$WM_DB_NAME" && -n "$WM_DB_USER" && -n "$WM_DB_PASS" && -n "$WM_DES_KEY" ]]
}

_wm_info_ensure() {
  local sql=""
  _wm_info_load && return 0
  lib_db_installed || { WM_LAST_ERROR="MariaDB is not installed"; return 1; }
  if (( OPT_DRY_RUN )); then
    lib_info "[dry-run] would create the webmail database and its user"
    WM_DB_NAME="lomp_webmail"; WM_DB_USER="lomp_webmail"; WM_DB_PASS="dry-run"; WM_DES_KEY="dry-run"
    return 0
  fi
  lib_db_wait_ready 10 || { WM_LAST_ERROR="MariaDB is not answering"; return 1; }
  WM_DB_NAME="lomp_webmail"
  WM_DB_USER="lomp_webmail"
  WM_DB_PASS="$(lib_random_password 32)"
  # AES-256-CBC takes a 32 byte key; the name des_key is upstream's and only historical
  WM_DES_KEY="$(lib_random_password 32)"
  # the account is for 127.0.0.1: Roundcube reaches MariaDB over TCP, and with
  # skip-name-resolve a 'localhost' account matches only connections through the socket
  sql="CREATE DATABASE IF NOT EXISTS \`${WM_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${WM_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${WM_DB_PASS}';
ALTER USER '${WM_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${WM_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${WM_DB_NAME}\`.* TO '${WM_DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;"
  lib_db_sql_secret "create the webmail database ${WM_DB_NAME}" "$sql" \
    || { WM_LAST_ERROR="the webmail database could not be created"; return 1; }
  {
    printf '# Webmail database and session key - created %s. Never leaves this file.\n' "$(lib_iso_now)"
    printf 'WM_DB_NAME=%s\nWM_DB_USER=%s\nWM_DB_PASS=%s\nWM_DES_KEY=%s\n' \
      "$WM_DB_NAME" "$WM_DB_USER" "$WM_DB_PASS" "$WM_DES_KEY"
  } | lib_write_file "$WM_INFO" 0600 root:root secret
  return 0
}

# Every domain whose webmail is on.
lib_webmail_domains() {
  local d=""
  while read -r d; do
    [[ -n "$d" ]] || continue
    [[ "$(lib_json_get "$(lib_domain_json "$d")" '.mail.webmail')" == "true" ]] && printf '%s\n' "$d"
  done < <(lib_mail_domains)
  return 0
}

# =============================================================================
#  The configuration file
# =============================================================================
# Rendered whole from state on every change, like the mail tables: the host names it trusts
# and the proxies it believes follow the domains that exist, and nothing is patched in place.
lib_webmail_render_config() {
  local d="" hosts="" proxies="" r="" esc=""
  _wm_info_load || return 1
  while read -r d; do
    [[ -n "$d" ]] || continue
    # the pattern is a PCRE, so every dot is escaped: an unescaped one would also match
    # "webmailXdeltaYcom", and this list is what keeps a forged Host header out
    esc="$(lib_webmail_host "$d")"
    esc="${esc//./\\.}"
    hosts+="    '^${esc}\$',"$'\n'
  done < <(lib_webmail_domains)
  # Cloudflare's own ranges, so that X-Forwarded-For is believed from the edge and from
  # nowhere else. An empty list means no forwarded header is trusted at all, which is the
  # safe way round: the log then shows the edge address instead of a forged one.
  while read -r r; do
    [[ -n "$r" && "$r" != \#* ]] || continue
    proxies+="    '${r}',"$'\n'
  done < <(grep -v '^#' "${CF_IPS_FILE:-/nonexistent}" 2>/dev/null || true)
  cat <<EOF
<?php
// Managed by lompstack - regenerated on every change; do not edit by hand.
// Anything you add here is lost the next time a domain's mail or webmail changes.

\$config = [];

// Roundcube's own database: users, settings, address books, sessions. Not the mail.
\$config['db_dsnw'] = 'mysql://${WM_DB_USER}:${WM_DB_PASS}@127.0.0.1/${WM_DB_NAME}';

// Dovecot and Postfix on this machine, over the loopback only. Dovecot requires TLS even
// here (ssl = required), so IMAP goes to 993 and speaks TLS; the certificate is this
// server's own and is not checked, because the connection never leaves the machine and the
// name it would be checked against is 127.0.0.1. Submission is the port 10587 that exists
// for the webmail alone - no TLS, but it authenticates like every other submission port.
\$config['imap_host'] = 'ssl://127.0.0.1:993';
\$config['imap_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false, 'allow_self_signed' => true]];
\$config['smtp_host'] = '127.0.0.1:10587';
\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';

// The password of the session is encrypted with this key. Changing it logs everybody out.
\$config['cipher_method'] = 'AES-256-CBC';
\$config['des_key'] = '${WM_DES_KEY}';

\$config['product_name'] = 'Webmail';
\$config['support_url'] = '';
\$config['skin'] = 'elastic';
\$config['enable_installer'] = false;
\$config['log_driver'] = 'syslog';
\$config['syslog_id'] = 'lomp-webmail';
\$config['log_logins'] = true;
\$config['log_dir'] = '${WM_LOG_DIR}/';
\$config['temp_dir'] = '${WM_VAR}/temp/';
\$config['temp_dir_ttl'] = '48h';
\$config['session_lifetime'] = 30;
\$config['session_samesite'] = 'Lax';
// the address of a request through Cloudflare changes between edges, so binding a session
// to it logs people out for no reason
\$config['ip_check'] = false;
\$config['x_frame_options'] = 'sameorigin';

// Only these host names may reach it. An empty list would accept any Host header, which is
// how a password reset link ends up pointing at somebody else's server.
\$config['trusted_host_patterns'] = [
${hosts}];

// TLS ends at Cloudflare, so PHP does not see a secure connection and would build http://
// links and set cookies without Secure.
\$config['use_https'] = true;
\$config['proxy_whitelist'] = [
${proxies}];

\$config['plugins'] = ['archive', 'zipdownload', 'managesieve', 'password'];

// Changing one's own password. The plugin checks the current one against the session before
// it calls anything, and the helper behind the driver checks it again against the stored
// hash: the webmail never writes the password file itself.
\$config['password_driver'] = 'lomp';
\$config['password_lomp_cmd'] = '/usr/bin/sudo -n ${MAIL_PW_HELPER}';
\$config['password_confirm_current'] = true;
\$config['password_minimum_length'] = ${MAIL_PW_MIN};
\$config['password_force_save'] = false;
\$config['password_log'] = true;
// Dovecot's ManageSieve, for holiday replies and filters
\$config['managesieve_host'] = '127.0.0.1:4190';
\$config['managesieve_script_name'] = 'roundcube';
EOF
  return 0
}

# =============================================================================
#  Installing
# =============================================================================
# Ownership, once and for all: root owns the code and the configuration, the webmail user
# owns nothing but the two directories it has to write into. A release directory it cannot
# write to is a release it cannot be made to modify.
lib_webmail_dirs_ensure() {
  lib_mkdir "$WM_ROOT"     0755 root:root
  lib_mkdir "$WM_RELEASES" 0755 root:root
  lib_mkdir "$WM_ETC"      0755 root:root
  lib_mkdir "$WM_VAR"      0750 "root:${WM_USER}"
  lib_mkdir "${WM_VAR}/temp" 0750 "${WM_USER}:${WM_USER}"
  # OpenLiteSpeed opens the vhost logs here as root. A directory the webmail user could write
  # would let it replace a log file with a symlink to anything on the system and have root
  # append attacker-chosen text to it - the access log carries the User-Agent verbatim. The
  # webmail itself logs to syslog and never writes here.
  lib_mkdir "$WM_LOG_DIR"  0750 root:root
  return 0
}

# The configuration is one file outside the release directories, and every release links to
# it. An update therefore cannot lose it, and upstream's updater - which rewrites the file
# when an option is renamed - writes through the link into the one place it is kept.
lib_webmail_config_apply() {
  local rel=""
  # nothing to write before there is a database and a key. The renderer fails in that case,
  # and a failure on the left of a pipe would put an EMPTY configuration in place.
  _wm_info_load || return 0
  lib_webmail_render_config | lib_write_file "$WM_CONF" 0640 "root:${WM_USER}" secret || return 1
  if (( OPT_DRY_RUN )); then return 0; fi
  # The password UI is advertised by this very configuration, so what it needs goes in with
  # it: the driver into the release that is running (a release installed before this version
  # of lomp has none) and the helper with its sudo rule.
  lib_webmail_pw_driver_install "$WM_CURRENT" || true
  lib_mail_pw_helper_apply on || lib_warn "the password helper was not installed: ${MAIL_LAST_ERROR}"
  # The configuration is a PHP file, so OPcache holds it: with revalidate_freq at 60 the
  # running workers would answer from the old one for up to a minute - long enough for the
  # domain just switched on to fail every login. The workers are the only processes this user
  # has, and OpenLiteSpeed starts a new one on the next request.
  if (( LIB_FILE_CHANGED )) && lib_have pkill; then
    pkill -u "$WM_USER" lsphp >/dev/null 2>&1 || true
  fi
  for rel in "${WM_RELEASES}"/*; do
    [[ -d "$rel" ]] || continue
    [[ -L "${rel}/config/config.inc.php" ]] && continue
    rm -f "${rel}/config/config.inc.php"
    ln -s "$WM_CONF" "${rel}/config/config.inc.php"
  done
  return 0
}

# Roundcube's own schema. Created once; an update migrates it instead.
_wm_db_schema_ensure() {   # release-dir
  local rel="$1" php="" n=""
  _wm_info_load || return 1
  n="$(lib_db_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${WM_DB_NAME}' AND table_name='users'" 2>/dev/null || printf '0')"
  [[ "$n" == "1" ]] && return 0
  php="$(lib_php_cli "$(lib_webmail_php_version)")"
  [[ -x "$php" ]] || { WM_LAST_ERROR="no PHP command line binary for the webmail"; return 1; }
  ( cd "$rel" && lib_run "$php" bin/initdb.sh --dir=SQL ) \
    || { WM_LAST_ERROR="the webmail database schema could not be created"; return 1; }
  lib_log_write INFO "webmail schema created in ${WM_DB_NAME}"
  return 0
}

# Does this release answer at all? Asked of the code, not of the web server: the entry point
# is loaded with the real configuration, and anything fatal in it shows up here rather than
# as a blank page after the symlink has already moved.
_wm_smoke_test() {   # release-dir
  local rel="$1" php="" out=""
  php="$(lib_php_cli "$(lib_webmail_php_version)")"
  [[ -x "$php" ]] || { WM_LAST_ERROR="no PHP command line binary for the webmail"; return 1; }
  out="$("$php" -r '
    define("INSTALL_PATH", $argv[1]."/");
    require INSTALL_PATH."program/include/iniset.php";
    $rc = rcmail::get_instance();
    echo "version=".RCMAIL_VERSION." db=".(is_object($rc->get_dbh()) ? "ok" : "no");
  ' "$rel" 2>&1)" || { WM_LAST_ERROR="the webmail does not start: ${out}"; return 1; }
  [[ "$out" == version=*db=ok* ]] || { WM_LAST_ERROR="the webmail does not start: ${out}"; return 1; }
  return 0
}

lib_webmail_install() {   # [version]
  local ver="${1:-$WM_VERSION}" rel="" php=""
  lib_mail_installed || lib_die "The mail server is not installed" \
    "the webmail is the front end of this machine's own mail" "lomp install --with-mail"
  php="$(lib_webmail_php_version)" || lib_die "No usable PHP for the webmail" \
    "Roundcube ${WM_BRANCH} needs PHP ${WM_PHP_MIN} to ${WM_PHP_MAX}; this server has $(lib_php_installed_versions | tr '\n' ' ')" \
    "install one: lomp install --php 8.3"
  if (( OPT_DRY_RUN )); then
    lib_info "[dry-run] would install Roundcube ${ver} under ${WM_ROOT} and run it on LSPHP ${php}"
    lib_webmail_dirs_ensure
    _wm_info_ensure || true
    lib_webmail_config_apply || true
    return 0
  fi
  lib_webmail_dirs_ensure
  _wm_info_ensure || lib_die "The webmail database could not be prepared" "${WM_LAST_ERROR}" "lomp doctor"
  lib_info "Fetching Roundcube ${ver} and checking its signature"
  rel="$(_wm_fetch_release "$ver")" || lib_die "Roundcube ${ver} could not be installed" "${WM_LAST_ERROR}" \
    "check the network, then run: lomp webmail update"
  lib_webmail_config_apply || lib_die "The webmail configuration could not be written" "${WM_LAST_ERROR}" "lomp doctor"
  _wm_db_schema_ensure "$rel" || lib_die "The webmail database could not be prepared" "${WM_LAST_ERROR}" "lomp doctor"
  _wm_smoke_test "$rel" || lib_die "Roundcube ${ver} does not start" "${WM_LAST_ERROR}" "lomp doctor"
  _wm_current_set "$rel" || lib_die "The webmail could not be switched on" "${WM_LAST_ERROR}" "ls -l ${WM_CURRENT}"
  lib_manifest_set '.components.webmail.version' "$ver"
  lib_manifest_set '.components.webmail.php' "$php"
  lib_webmail_cron_ensure
  lib_ok "Webmail ready (Roundcube ${ver} on LSPHP ${php})"
  return 0
}

# =============================================================================
#  Updating
# =============================================================================
# Roundcube publishes a security release every few weeks, so this runs by itself. The new
# version is unpacked next to the old one and has to start before "current" is moved; if it
# does not, the symlink never moves and the running webmail is untouched.
lib_webmail_update() {   # [version]
  local want="${1:-}" cur="" rel="" php="" old=""
  lib_webmail_installed || { WM_LAST_ERROR="the webmail is not installed"; return 1; }
  cur="$(lib_webmail_version)" || cur=""
  # before asking anything of the network: a dry run sends no request either
  if (( OPT_DRY_RUN )); then
    lib_info "[dry-run] would look for a newer Roundcube ${WM_BRANCH}.x and install it (currently ${cur})"
    return 0
  fi
  if [[ -z "$want" ]]; then
    want="$(lib_webmail_latest)" || { lib_warn "Could not ask for the newest release: ${WM_LAST_ERROR}"; return 1; }
  fi
  if [[ "$want" == "$cur" ]]; then
    lib_ok "Webmail is up to date (Roundcube ${cur})"
    return 0
  fi
  php="$(lib_php_cli "$(lib_webmail_php_version)")"
  lib_info "Updating the webmail from ${cur} to ${want}"
  rel="$(_wm_fetch_release "$want")" || { lib_warn "Roundcube ${want} was not installed: ${WM_LAST_ERROR}"; return 1; }
  rm -f "${rel}/config/config.inc.php"
  ln -s "$WM_CONF" "${rel}/config/config.inc.php"
  # upstream's updater migrates the database and, when an option was renamed, rewrites the
  # configuration. It writes through the symlink into the one live file, so a copy is taken
  # first - and put back on every path that gives up, or the old release would go on reading
  # a configuration the new one rewrote.
  cp -a "$WM_CONF" "${WM_CONF}.before" 2>/dev/null || true
  if ! ( cd "$rel" && lib_run "$php" bin/update.sh --version="${cur}" -y ); then
    lib_warn "Roundcube's own update step failed; the running webmail is untouched"
    _wm_config_restore
    rm -rf "$rel"
    WM_LAST_ERROR="bin/update.sh failed"
    return 1
  fi
  if ! _wm_smoke_test "$rel"; then
    lib_warn "Roundcube ${want} does not start (${WM_LAST_ERROR}); the running webmail is untouched"
    _wm_config_restore
    rm -rf "$rel"
    return 1
  fi
  # Upstream's updater, when it finds a configuration key that has been renamed, first copies
  # the live configuration next to itself as config.old.php - through the symlink, so the copy
  # holds the real thing - with root's umask, inside a release tree every user of this machine
  # can read. Nothing here would ever have removed it. The keys lompstack writes are current,
  # so that branch is not reached today; it is one upstream rename away from being reached, and
  # what it would leave behind is the database password and the key that decrypts every logged
  # in mailbox's IMAP password. So: the copy goes, and the directory stops being world-readable.
  rm -f "${rel}/config/"*.old.php
  chown "root:${WM_USER}" "${rel}/config" 2>/dev/null || true
  chmod 0750 "${rel}/config" 2>/dev/null || true
  old="$(readlink -f "$WM_CURRENT" 2>/dev/null || true)"
  _wm_current_set "$rel" || { lib_warn "the webmail could not be switched to ${want}: ${WM_LAST_ERROR}"; rm -rf "$rel"; return 1; }
  rm -f "${WM_CONF}.before"
  # upstream's updater regenerates the configuration from its own defaults when an option was
  # renamed, so the last word on what is in it belongs to this tool and not to that script
  lib_webmail_config_apply || lib_warn "the webmail configuration could not be rewritten after the update"
  # the PHP workers hold a resolved path to the old directory in their realpath cache
  lib_ols_restart || lib_warn "OpenLiteSpeed did not restart; run: systemctl restart lsws"
  lib_manifest_set '.components.webmail.version' "$want"
  lib_ok "Webmail updated to Roundcube ${want}"
  # one release back is kept, to move the symlink onto if something only shows up later
  _wm_prune_releases "$rel" "$old"
  return 0
}

# Put the configuration back the way it was before upstream's updater rewrote it. Its
# defaults are all the unsafe direction - no trusted hosts at all, the published example
# des_key, use_https off - so a release that is thrown away must not leave its idea of the
# configuration behind for the release that is still running.
_wm_config_restore() {
  [[ -s "${WM_CONF}.before" ]] || return 0
  cp -a "${WM_CONF}.before" "$WM_CONF" 2>/dev/null || true
  rm -f "${WM_CONF}.before"
  if lib_have pkill; then pkill -u "$WM_USER" lsphp >/dev/null 2>&1 || true; fi
  return 0
}

# Move "current" onto a release, and say so when it does not move. An "ln && mv" pair is
# exempt from errexit, so a failure here would otherwise be announced as success and the
# vhost would go on serving whatever the old path holds.
_wm_current_set() {   # release-dir
  local rel="$1"
  if ! ln -sfn "$rel" "${WM_CURRENT}.new"; then
    WM_LAST_ERROR="could not create ${WM_CURRENT}.new"; return 1
  fi
  if ! mv -Tf "${WM_CURRENT}.new" "$WM_CURRENT"; then
    rm -f "${WM_CURRENT}.new"
    WM_LAST_ERROR="${WM_CURRENT} could not be pointed at ${rel##*/} (is it a real directory?)"
    return 1
  fi
  [[ "$(readlink -f "$WM_CURRENT")" == "$rel" ]] || { WM_LAST_ERROR="${WM_CURRENT} does not point at ${rel}"; return 1; }
  return 0
}

_wm_prune_releases() {   # keep... - everything else goes
  local keep=("$@") d="" k="" hit=0
  for d in "${WM_RELEASES}"/*; do
    [[ -d "$d" ]] || continue
    hit=0
    for k in "${keep[@]}"; do [[ -n "$k" && "$d" == "$k" ]] && hit=1; done
    (( hit )) && continue
    rm -rf "$d"
    lib_log_write INFO "old webmail release removed: ${d##*/}"
  done
  return 0
}

# What the daily job does: throw away what Roundcube marked deleted, expire its temporary
# files, and take a patch release when there is one.
lib_webmail_maintain() {
  local php="" rel=""
  lib_webmail_installed || return 0
  # cleandb deletes rows for good and gc expires live sessions, so neither runs in a dry run
  if (( OPT_DRY_RUN )); then
    lib_info "[dry-run] would clean the webmail database, expire its temporary files and look for a newer release"
    return 0
  fi
  rel="$(readlink -f "$WM_CURRENT")"
  php="$(lib_php_cli "$(lib_webmail_php_version)")"
  if [[ -x "$php" ]]; then
    ( cd "$rel" && "$php" bin/cleandb.sh >/dev/null 2>&1 ) || lib_warn "webmail cleandb failed"
    ( cd "$rel" && "$php" bin/gc.sh      >/dev/null 2>&1 ) || lib_warn "webmail garbage collection failed"
  fi
  lib_webmail_update || true
  return 0
}

lib_webmail_cron_ensure() {
  lib_cron_set "webmail" "30 4 * * * root ${BIN_LINK} webmail maintain --quiet"
  return 0
}

# =============================================================================
#  OpenLiteSpeed: one PHP process for every webmail, one vhost per domain
# =============================================================================
# The PHP lives at server level and is shared: a server with twenty domains runs one set of
# webmail PHP children, not twenty. It runs as lompwebmail, which owns no site and no mail,
# so a hole in Roundcube reaches neither.
#
# memSoftLimit is an address space limit (RLIMIT_AS), not an allowance: LSPHP maps the whole
# OPcache - 512 MB plus 64 MB of interned strings, from the php.ini this tool writes - before
# it runs a line of code. A limit under that does not make the webmail smaller, it makes
# every request answer 503 with "Unable to allocate shared memory segment" in the log, so it
# is the same figure the site workers use. What bounds the memory is PHP_LSAPI_CHILDREN.
WM_EXTPROC="lsphp_webmail"

lib_webmail_render_extprocessor() {
  local php=""
  php="$(lib_php_bin "$(lib_webmail_php_version)")"
  cat <<EOF
extprocessor ${WM_EXTPROC} {
  type                    lsapi
  address                 UDS://tmp/lshttpd/${WM_EXTPROC}.sock
  maxConns                4
  env                     PHP_LSAPI_CHILDREN=4
  env                     LSAPI_AVOID_FORK=200M
  env                     PHP_LSAPI_MAX_REQUESTS=1000
  initTimeout             60
  retryTimeout            0
  persistConn             1
  pcKeepAliveTimeout      1
  respBuffer              0
  autoStart               1
  path                    ${php}
  extUser                 ${WM_USER}
  extGroup                ${WM_USER}
  memSoftLimit            2047M
  memHardLimit            2047M
  procSoftLimit           40
  procHardLimit           60
}
EOF
}

# setUIDMode 0: the vhost has no user of its own. The PHP that serves it comes from the
# server-level processor, which names lompwebmail itself, and the code stays owned by root so
# that the webmail cannot rewrite it. OpenLiteSpeed notes in its log that the document root's
# owner is uid 0 and declines to use it for suEXEC; nothing here asks it to.
lib_webmail_render_vhost_block() {   # domain
  cat <<EOF
virtualhost $(lib_webmail_vhost_name "$1") {
  vhRoot                  ${WM_ROOT}/
  configFile              conf/vhosts/$(lib_webmail_vhost_name "$1")/vhconf.conf
  allowSymbolLink         1
  enableScript            1
  restrained              1
  setUIDMode              0
}
EOF
}

# The vhost itself. docRoot goes through "current", so an update that moves the symlink is
# served without touching this file.
lib_webmail_render_vhconf() {   # domain
  local d="$1" host="" cert="" name=""
  host="$(lib_webmail_host "$d")"
  name="$(lib_webmail_vhost_name "$d")"
  cert="${SSL_DEPLOY_DIR}/$(lib_mail_cert_name "$d")"
  cat <<EOF
# Managed by lompstack - the webmail of ${d}. Regenerated on every change; do not edit.
docRoot                   \$VH_ROOT/current/public_html/
vhDomain                  ${host}
enableGzip                1
enableIpGeo               0

errorlog ${WM_LOG_DIR}/${name}.error.log {
  useServer               0
  logLevel                WARN
  rollingSize             10M
  keepDays                30
}

accesslog ${WM_LOG_DIR}/${name}.access.log {
  useServer               0
  logReferer              0
  logUserAgent            1
  rollingSize             10M
  keepDays                30
  compressArchive         1
}

index  {
  useServer               0
  indexFiles              index.php
  autoIndex               0
}

scripthandler  {
  add                     lsapi:${WM_EXTPROC} php
}

phpIniOverride  {
  php_admin_value memory_limit 256M
  php_admin_value upload_max_filesize 32M
  php_admin_value post_max_size 40M
  php_admin_value sys_temp_dir ${WM_VAR}/temp
  php_admin_value upload_tmp_dir ${WM_VAR}/temp
  php_admin_value expose_php 0
}

rewrite  {
  enable                  1
  autoLoadHtaccess        0
  logLevel                0
  rules                   <<<END_rules
RewriteRule ^/?\.(?!well-known/) - [F,L]
RewriteCond %{HTTPS} !on
RewriteCond %{HTTP:X-Forwarded-Proto} !https
RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
RewriteRule ^(.*)\$ https://%{HTTP_HOST}\$1 [R=301,L]
  END_rules
}

context /.well-known/acme-challenge/ {
  location                ${ACME_ROOT}/.well-known/acme-challenge/
  allowBrowse             1
  addDefaultCharset       off
}

context / {
  location                \$VH_ROOT/current/public_html/
  allowBrowse             1
  addDefaultCharset       off
  extraHeaders            <<<END_extraHeaders
X-Content-Type-Options: nosniff
Referrer-Policy: strict-origin-when-cross-origin
Strict-Transport-Security: max-age=31536000; includeSubDomains
  END_extraHeaders

  rewrite  {
    enable                1
    inherit               1
  }
}
EOF
  if [[ -s "${cert}/fullchain.pem" && -s "${cert}/privkey.pem" ]]; then
    printf '\n'
    lib_ols_render_vhssl "${cert}/privkey.pem" "${cert}/fullchain.pem" 1
  fi
  return 0
}

lib_webmail_vhost_apply() {   # domain
  local d="$1" name="" dir="" host=""
  lib_ols_is_installed || return 0
  name="$(lib_webmail_vhost_name "$d")"
  dir="${LSWS_VHOSTS_DIR}/${name}"
  host="$(lib_webmail_host "$d")"
  lib_ols_change_begin
  lib_mkdir "$dir" 0750 lsadm:lsadm
  lib_webmail_render_vhconf "$d" | lib_write_file "${dir}/vhconf.conf" 0640 lsadm:lsadm
  (( LIB_FILE_CHANGED )) && OLS_PENDING_RELOAD=1
  lib_ols_tx_begin
  lib_webmail_render_extprocessor      | lib_ols_tx_block_put extprocessor "$WM_EXTPROC"
  lib_webmail_render_vhost_block "$d"  | lib_ols_tx_block_put virtualhost  "$name"
  lib_ols_tx_map_set "$OLS_LISTENER_HTTP"  "$name" "$host"
  lib_ols_tx_map_set "$OLS_LISTENER_HTTPS" "$name" "$host"
  lib_ols_tx_commit
  lib_ols_change_commit "webmail vhost for ${d}"
  return 0
}

lib_webmail_vhost_remove() {   # domain
  local d="$1" name="" dir=""
  lib_ols_is_installed || return 0
  name="$(lib_webmail_vhost_name "$d")"
  dir="${LSWS_VHOSTS_DIR}/${name}"
  lib_ols_change_begin
  lib_ols_tx_begin
  lib_ols_tx_map_del "$OLS_LISTENER_HTTP"  "$name"
  lib_ols_tx_map_del "$OLS_LISTENER_HTTPS" "$name"
  lib_ols_tx_block_exists virtualhost "$name" && lib_ols_tx_block_remove virtualhost "$name"
  # the shared PHP goes when the last webmail does: it costs four processes
  if [[ -z "$(lib_webmail_domains | grep -vxF "$d" || true)" ]]; then
    lib_ols_tx_block_exists extprocessor "$WM_EXTPROC" && lib_ols_tx_block_remove extprocessor "$WM_EXTPROC"
  fi
  lib_ols_tx_commit
  if [[ -d "$dir" ]] && (( ! OPT_DRY_RUN )); then
    lib_rm "$dir"
    OLS_PENDING_RELOAD=1
  fi
  lib_ols_change_commit "remove the webmail vhost of ${d}"
  return 0
}

# =============================================================================
#  Per domain: on, off
# =============================================================================
# The webmail sends through a Postfix service on 127.0.0.1:10587 and writes its filters over
# ManageSieve on 127.0.0.1:4190. Both arrived with the webmail; a server whose mail was
# installed before that and then self-updated still has the master.cf and the Dovecot
# configuration of the older release, because self-update deliberately reconfigures nothing.
# Switching a webmail on there used to produce one that could read mail and not send a single
# message, with nothing anywhere saying why. So the mail configuration is brought up to this
# release first - which rewrites nothing when it is already current.
_wm_mail_stack_current() {
  local host=""
  (( OPT_DRY_RUN )) && return 0
  lib_mail_installed || return 0
  if grep -q '10587' "$MAIL_POSTFIX_MASTER" 2>/dev/null \
     && grep -q 'managesieve-login' "$MAIL_DOVECOT_LOCAL" 2>/dev/null; then
    return 0
  fi
  lib_info "The mail configuration on this server is older than the webmail; bringing it up to date"
  host="$(lib_mail_host)"
  if ! lib_mail_apply "$host"; then
    WM_LAST_ERROR="the mail configuration could not be brought up to date: ${MAIL_LAST_ERROR}"
    return 1
  fi
  return 0
}

lib_webmail_domain_enable() {   # domain
  local d="$1"
  lib_mail_domain_enabled "$d" || { WM_LAST_ERROR="${d} has no mail"; return 1; }
  _wm_mail_stack_current || return 1
  lib_webmail_installed || lib_webmail_install
  lib_webmail_dirs_ensure      # also puts right an owner an older release of lomp set
  # the one thing the webmail may ask root to do, and the rule that lets it
  lib_mail_pw_helper_apply on || lib_warn "the password helper was not installed: ${MAIL_LAST_ERROR}"
  # The flag has to go in first: the configuration this domain needs is rendered from it, and
  # so is the certificate's name list. It is registered for rollback at the same moment, so a
  # virtual host OpenLiteSpeed refuses does not leave a domain that says it has a webmail
  # while nothing serves one.
  if (( ! OPT_DRY_RUN )); then
    lib_json_set "$(lib_domain_json "$d")" '.mail.webmail = true | .mail.webmail_host = $h' --arg h "$(lib_webmail_host "$d")"
    lib_rollback_push "lib_json_set '$(lib_domain_json "$d")' 'del(.mail.webmail) | del(.mail.webmail_host)'"
  fi
  lib_webmail_config_apply || { WM_LAST_ERROR="the webmail configuration could not be written"; return 1; }
  lib_webmail_cert_ensure "$d"
  lib_webmail_vhost_apply "$d"
  # it is served: the state may stand on its own now
  (( OPT_DRY_RUN )) || lib_rollback_drop "lib_json_set '$(lib_domain_json "$d")' 'del(.mail.webmail) | del(.mail.webmail_host)'"
  lib_ok "Webmail for ${d}: https://$(lib_webmail_host "$d")"
  return 0
}

# Take webmail.<domain> out of Cloudflare, if lompstack is what put it there. Only records
# carrying lompstack's own comment are touched: somebody may be pointing that name somewhere on
# purpose, and a name this tool did not write is not this tool's to delete.
_wm_dns_record_remove() {   # domain
  local d="$1" host="" zone="" have="" id="" gone=0
  [[ -n "$(lib_cf_token)" ]] || return 0
  host="$(lib_webmail_host "$d")"
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would remove the A record for ${host} from Cloudflare"; return 0; fi
  if ! zone="$(lib_cf_zone_id "$host")"; then
    lib_warn "the Cloudflare zone of ${d} could not be looked up: ${CF_LAST_ERROR:-no zone found}"
    lib_note "${host} is still published; remove it by hand when the webmail is gone"
    return 0
  fi
  if ! have="$(lib_cf_records "$zone" A "$host")"; then
    lib_warn "could not read A ${host} from Cloudflare: ${CF_LAST_ERROR}; it may still be there"
    return 0
  fi
  while read -r id; do
    [[ -n "$id" ]] || continue
    if lib_cf_record_delete "$zone" "$id"; then gone=$((gone + 1)); else lib_warn "could not remove A ${host}: ${CF_LAST_ERROR}"; fi
  done < <(jq -r --arg tag "$CF_RECORD_TAG" '.[] | select((.comment // "") == $tag) | .id' <<<"$have" || true)
  (( gone > 0 )) && lib_ok "${host} was removed from DNS"
  return 0
}

lib_webmail_domain_disable() {   # domain
  local d="$1"
  # a domain that never had one, or a machine with no webmail at all, is not a failure. The
  # virtual host counts as much as the flag: whichever is there has to go, or a removal would
  # leave one of them behind for the next domain of that name to inherit.
  if [[ "$(lib_json_get "$(lib_domain_json "$d")" '.mail.webmail')" != "true" \
        && ! -d "${LSWS_VHOSTS_DIR}/$(lib_webmail_vhost_name "$d")" ]]; then
    return 0
  fi
  # The record goes BEFORE the flag does. What lompstack published for a domain is worked out
  # from the state, and the webmail's name is in that list only while the state still says
  # there is a webmail - so once the flag is gone, nothing could ever remove webmail.<domain>
  # again, not even "mail disable --dns-cleanup". It would stay in the zone pointing at this
  # server for good.
  _wm_dns_record_remove "$d"
  lib_webmail_vhost_remove "$d"
  (( OPT_DRY_RUN )) || lib_json_set "$(lib_domain_json "$d")" 'del(.mail.webmail) | del(.mail.webmail_host)'
  lib_webmail_config_apply || true
  # nothing is left that could ask root to change a password
  if [[ -z "$(lib_webmail_domains)" ]]; then
    lib_mail_pw_helper_apply off
  fi
  return 0
}

# The certificate of a domain's mail covers its webmail as well: one lineage, two names, so
# there is one thing to renew and one thing that can expire. lib_mail_domain_cert_ensure reads
# the same flag this function has just set, asks for both names and, when they do not come,
# leaves the cron that keeps asking - so there is one place that knows how to get them.
lib_webmail_cert_ensure() {   # domain
  lib_mail_domain_cert_ensure "$1"
}

# =============================================================================
#  fail2ban
# =============================================================================
# Roundcube's own login limit counts per account and ignores the address a request comes
# from, so it does nothing against somebody trying one password against many names. That is
# what this jail is for. It reads the journal, because the webmail logs to syslog.
WM_JAIL_FILE="${WM_JAIL_FILE:-/etc/fail2ban/jail.d/server-setup-webmail.conf}"
WM_FILTER_FILE="${WM_FILTER_FILE:-/etc/fail2ban/filter.d/lomp-webmail.conf}"

# The line Roundcube writes is, verbatim:
#   lomp-webmail[2624]: <8htuns83> Failed login for user@example.com from 127.0.0.1 in session ...
# __prefix_line comes from common.conf and covers the part the journal itself adds, so the
# INCLUDES section is not decoration: without it fail2ban cannot expand the pattern, and a
# filter it cannot expand stops the WHOLE service - every jail, ssh included.
lib_webmail_render_filter() {
  cat <<'EOF'
# Managed by lompstack - failed logins as Roundcube writes them to syslog
[INCLUDES]
before = common.conf

[Definition]
_daemon = lomp-webmail
failregex = ^%(__prefix_line)s(<[^>]+> )?(IMAP Error: )?(Login failed|Failed login) for .* from <HOST>
ignoreregex =
journalmatch = SYSLOG_IDENTIFIER=lomp-webmail
EOF
}

lib_webmail_render_jail() {
  cat <<EOF
# Managed by lompstack - webmail jail (rewritten when a webmail is enabled or disabled)

[lomp-webmail]
enabled = true
filter = lomp-webmail
backend = systemd
port = http,https
maxretry = 5
findtime = 10m
bantime = 1h
$(lib_cf_fail2ban_action_lines 2>/dev/null || true)
EOF
}

# fail2ban reads every file in jail.d and filter.d at start, and refuses to start at all when
# one of them is wrong - taking the SSH jail down with it. So the pair is tested before
# fail2ban is asked to use it, and taken away again if the test fails.
lib_webmail_fail2ban_apply() {
  local changed=0 out=""
  lib_pkg_installed fail2ban || return 0
  lib_webmail_render_filter | lib_write_file "$WM_FILTER_FILE" 0644 root:root
  changed=$(( changed + LIB_FILE_CHANGED ))
  lib_webmail_render_jail   | lib_write_file "$WM_JAIL_FILE"   0644 root:root
  changed=$(( changed + LIB_FILE_CHANGED ))
  (( changed )) || return 0
  (( OPT_DRY_RUN )) && return 0
  if lib_have fail2ban-client; then
    if ! out="$(fail2ban-client --test 2>&1)"; then
      rm -f "$WM_FILTER_FILE" "$WM_JAIL_FILE"
      lib_warn "the webmail's fail2ban jail was refused and has been removed: $(tail -1 <<<"$out")"
      return 1
    fi
  fi
  lib_systemctl reload fail2ban 2>/dev/null || lib_systemctl restart fail2ban 2>/dev/null || true
  return 0
}

# =============================================================================
#  Status, removal, the command
# =============================================================================
lib_webmail_status() {
  local d="" n=0
  if ! lib_webmail_installed; then
    lib_print_kv "Webmail" "not installed (it comes with the first 'lomp mail webmail on <domain>')"
    return 0
  fi
  lib_print_kv "Webmail" "Roundcube $(lib_webmail_version) on LSPHP $(lib_webmail_php_version 2>/dev/null || printf '?')"
  while read -r d; do
    [[ -n "$d" ]] || continue
    n=$((n + 1))
    # the name has to be ON the certificate, not merely somewhere in the lineage: a browser
    # that gets the mail host's certificate for webmail.<domain> shows a warning page
    if lib_ssl_cert_covers "$(lib_mail_cert_name "$d")" "$(lib_webmail_host "$d")"; then
      lib_print_kv "  https://$(lib_webmail_host "$d")" "certificate ok ($(lib_ssl_days_left "$(lib_mail_cert_name "$d")") days)"
    else
      lib_print_kv "  https://$(lib_webmail_host "$d")" "no certificate for this name yet (lomp mail cert ${d})"
    fi
  done < <(lib_webmail_domains)
  (( n > 0 )) || lib_print_kv "  domains" "none yet (lomp mail webmail on example.com)"
  return 0
}

lib_webmail_uninstall() {
  local d=""
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_webmail_domain_disable "$d"
  done < <(lib_webmail_domains)
  lib_cron_remove "webmail"
  lib_mail_pw_helper_apply off
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would remove ${WM_ROOT}, ${WM_ETC} and ${WM_VAR}"; return 0; fi
  lib_rm "$WM_ROOT"
  lib_rm "$WM_VAR"
  lib_rm "$WM_ETC"
  rm -f "$WM_JAIL_FILE" "$WM_FILTER_FILE"
  lib_json_set "${STATE_DIR}/manifest.json" 'del(.components.webmail) | .updated_at = $ts' --arg ts "$(lib_iso_now)"
  lib_ok "The webmail is gone. Its database and ${WM_INFO} were kept: 'lomp webmail purge' takes those too"
  return 0
}

lib_webmail_purge_db() {
  _wm_info_load || return 0
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would drop the webmail database ${WM_DB_NAME}"; return 0; fi
  lib_db_sql_secret "drop the webmail database" \
    "DROP DATABASE IF EXISTS \`${WM_DB_NAME}\`; DROP USER IF EXISTS '${WM_DB_USER}'@'127.0.0.1'; FLUSH PRIVILEGES;" || true
  rm -f "$WM_INFO"
  lib_ok "The webmail database and its credentials are gone"
  return 0
}

lib_webmail_main() {
  local a="${1:-status}"
  shift || true
  case "$a" in
    status|"")      lib_webmail_status ;;
    install)        lib_webmail_install "${1:-}" ;;
    update)         lib_webmail_update "${1:-}" ;;
    maintain)       lib_webmail_maintain ;;
    uninstall)      lib_webmail_uninstall ;;
    purge)          lib_webmail_uninstall; lib_webmail_purge_db ;;
    help|-h|--help) lib_usage | grep -A 8 '^  webmail ' || lib_usage ;;
    *) lib_die "Unknown webmail command: ${a}" "" "lomp webmail status|update|uninstall" ;;
  esac
  return 0
}

# The password plugin talks to a driver, and the drivers Roundcube ships either speak to
# something we do not run or change a password without being told the old one. This one hands
# all three - the address, the current password and the new one - to the helper on standard
# input, so the helper can insist on the current password before it changes anything: a
# webmail somebody has taken over still cannot change a password it does not already know.
lib_webmail_render_pw_driver() {
  cat <<'EOF'
<?php
// Managed by lompstack - rewritten whenever a release is installed; do not edit.
class rcube_lomp_password
{
    public function save($currpass, $newpass, $username)
    {
        $cmd = rcmail::get_instance()->config->get('password_lomp_cmd');
        if (empty($cmd)) {
            rcube::raise_error("Password plugin: password_lomp_cmd is not set", true);
            return PASSWORD_ERROR;
        }
        $handle = popen($cmd, 'w');
        if (!$handle) {
            rcube::raise_error("Password plugin: cannot run {$cmd}", true);
            return PASSWORD_ERROR;
        }
        // one line each, in the order the helper reads them
        fwrite($handle, $username . "\n" . $currpass . "\n" . $newpass . "\n");
        $rc = pclose($handle);
        if ($rc === 0) {
            return PASSWORD_SUCCESS;
        }
        rcube::raise_error("Password plugin: the helper refused the change (exit {$rc})", true);
        return PASSWORD_ERROR;
    }
}
EOF
}

# The driver belongs to the release, so it is written into every release as it is unpacked.
lib_webmail_pw_driver_install() {   # release-dir
  local rel="${1:-$WM_CURRENT}" dir=""
  dir="${rel}/plugins/password/drivers"
  [[ -d "$dir" ]] || return 0
  lib_webmail_render_pw_driver | lib_write_file "${dir}/lomp.php" 0644 root:root
  return 0
}
