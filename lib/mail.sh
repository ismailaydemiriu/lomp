#!/usr/bin/env bash
# lib/mail.sh - e-mail for the sites of this server: Postfix (SMTP), Dovecot (IMAP, LMTP and
#               authentication), Rspamd (spam filtering, DKIM) and a webmail, enabled per site.
#
#   users     /etc/dovecot/lomp/passwd     0640 root:dovecot, BLF-CRYPT hashes, no system users
#   mail      /var/vmail/<domain>/<local>/Maildir, owned by one unmapped "vmail" user, so a
#             site user can never read another site's - or its own - mail from the filesystem
#   state     domain.json .mail{...} carries no secret; STATE_DIR/mail/* is root-only
#   ports     public 25, 465, 587 and 993, and 5335 on loopback for the resolver. Nothing else
#             binds a port: the milter, Rspamd's interface and its Redis are unix sockets, and
#             there is no plain-text IMAP and no cleartext submission port to guess at
#
# lomp owns main.cf and master.cf whole: the package's own files are archived on the first
# install, and every later change goes through the renderers below. They are pure - they take
# what they need as arguments and print to standard output - so the tests can read every line
# this server will run without installing anything.

MAIL_VMAIL_USER="${MAIL_VMAIL_USER:-vmail}"
MAIL_VMAIL_HOME="${MAIL_VMAIL_HOME:-/var/vmail}"
MAIL_WEBMAIL_USER="${MAIL_WEBMAIL_USER:-lompwebmail}"
MAIL_POSTFIX_DIR="${MAIL_POSTFIX_DIR:-/etc/postfix/lomp}"
MAIL_POSTFIX_MAIN="${MAIL_POSTFIX_MAIN:-/etc/postfix/main.cf}"
MAIL_POSTFIX_MASTER="${MAIL_POSTFIX_MASTER:-/etc/postfix/master.cf}"
MAIL_DOVECOT_DIR="${MAIL_DOVECOT_DIR:-/etc/dovecot/lomp}"
MAIL_DOVECOT_LOCAL="${MAIL_DOVECOT_LOCAL:-/etc/dovecot/local.conf}"
MAIL_DOVECOT_10AUTH="${MAIL_DOVECOT_10AUTH:-/etc/dovecot/conf.d/10-auth.conf}"
MAIL_PASSWD_FILE="${MAIL_PASSWD_FILE:-${MAIL_DOVECOT_DIR}/passwd}"
MAIL_SIEVE_DIR="${MAIL_SIEVE_DIR:-/etc/dovecot/sieve}"   # the delivery user has to read these
MAIL_RSPAMD_DIR="${MAIL_RSPAMD_DIR:-/etc/rspamd/local.d}"
MAIL_RSPAMD_LOMP="${MAIL_RSPAMD_LOMP:-/etc/rspamd/lomp}"
MAIL_DKIM_DIR="${MAIL_DKIM_DIR:-/var/lib/rspamd/dkim}"
MAIL_APT_LIST="${MAIL_APT_LIST:-/etc/apt/sources.list.d/lomp-rspamd.list}"
MAIL_RSPAMD_KEY="${MAIL_RSPAMD_KEY:-/etc/apt/keyrings/rspamd.gpg}"
MAIL_REDIS_CONF="${MAIL_REDIS_CONF:-/etc/lomp-redis-rspamd.conf}"
MAIL_MILTER_SOCK="${MAIL_MILTER_SOCK:-/run/rspamd/milter.sock}"
# Rspamd runs as _rspamd and Postfix as postfix; the milter socket belongs to a group that
# holds both of them and nobody else, which is how one reaches the other and no site can.
MAIL_MILTER_GROUP="${MAIL_MILTER_GROUP:-lompmilter}"
MAIL_REDIS_UNIT="${MAIL_REDIS_UNIT:-/etc/systemd/system/lomp-redis-rspamd.service}"
MAIL_REDIS_SOCK="${MAIL_REDIS_SOCK:-/run/lomp-redis-rspamd/redis.sock}"
MAIL_REDIS_DATA="${MAIL_REDIS_DATA:-/var/lib/lomp-redis-rspamd}"
MAIL_UNBOUND_CONF="${MAIL_UNBOUND_CONF:-/etc/unbound/unbound.conf.d/lomp-mail.conf}"
MAIL_RSPAMD_DROPIN="${MAIL_RSPAMD_DROPIN:-/etc/systemd/system/rspamd.service.d/10-lompstack.conf}"
MAIL_JAIL_FILE="${MAIL_JAIL_FILE:-/etc/fail2ban/jail.d/server-setup-mail.conf}"
MAIL_SNI_MAP="${MAIL_SNI_MAP:-${MAIL_POSTFIX_DIR}/sni}"
MAIL_SASL_MAP="${MAIL_SASL_MAP:-${MAIL_POSTFIX_DIR}/sasl_passwd}"
MAIL_STATE_DIR="${MAIL_STATE_DIR:-${STATE_DIR}/mail}"
MAIL_RELAY_INFO="${MAIL_RELAY_INFO:-${MAIL_STATE_DIR}/relay.info}"
MAIL_CERT_NAME="${MAIL_CERT_NAME:-_mailhost}"        # certbot lineage for MAIL_HOST itself
MAIL_QUOTA_DEFAULT="${MAIL_QUOTA_DEFAULT:-1G}"
MAIL_MSG_SIZE_MB="${MAIL_MSG_SIZE_MB:-25}"
MAIL_MIN_RAM_MB="${MAIL_MIN_RAM_MB:-1800}"
MAIL_LAST_ERROR=""

# =============================================================================
#  State
# =============================================================================
# The mail stack is installed when the manifest says Postfix was put there by lompstack. The
# package alone does not count: Ubuntu images arrive with a local-only Postfix often enough.
lib_mail_installed() { [[ -n "$(lib_manifest_get '.components.mail.postfix')" ]]; }

# The one name this server presents in HELO and in its PTR record. Every site's mail goes out
# through it, so it stays the same when sites come and go.
lib_mail_host() { lib_manifest_get '.mail.hostname'; }

# The certbot lineage holding mail.<domain> (and webmail.<domain>) for one site. The leading
# underscore is what keeps it apart from the site's own lineage: lib_domain_valid refuses a
# name starting with one, so no site can ever claim it.
lib_mail_cert_name() { printf '_mail_%s' "$(lib_domain_ident "$1")"; }

# The part of an address before the @. Checked before it reaches a map, a file name or a path.
# No "+": Postfix delivers user+anything@domain to user@domain (recipient_delimiter), so a
# mailbox called info+news would take mail that was meant to reach info.
lib_mail_local_valid() {
  local l="$1"
  [[ "$l" =~ ^[a-z0-9]([a-z0-9._-]{0,62}[a-z0-9])?$ ]] || return 1
  [[ "$l" != *..* ]]
}

lib_mail_address_valid() {   # user@domain
  local addr="${1,,}"
  [[ "$addr" == *@* && "$addr" != *@*@* ]] || return 1
  lib_mail_local_valid "${addr%%@*}" && lib_domain_valid "${addr#*@}"
}

# A mailbox quota as Dovecot writes it: a plain size with a unit, or 0 for "no limit".
lib_mail_quota_valid() { [[ "$1" == "0" || "$1" =~ ^[1-9][0-9]{0,5}[MG]$ ]]; }

# A host name a certificate or a relay can be pointed at: a domain, or a name under one.
lib_mail_hostname_valid() {
  local h="${1,,}"
  [[ ${#h} -le 253 ]] || return 1
  [[ "$h" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.){1,}[a-z]{2,63}$ ]]
}

# Postfix table type. hash comes from the Berkeley DB support that Ubuntu's package has today;
# should a future package drop it, lmdb is there and every map path stays the same.
lib_mail_map_type() {
  local m=""
  m="$(postconf -m 2>/dev/null || true)"
  if   grep -qx 'hash' <<<"$m"; then printf 'hash'
  elif grep -qx 'lmdb' <<<"$m"; then printf 'lmdb'
  else printf 'hash'; fi
}

# The password Rspamd's own interface asks for, generated once and kept where the operator can
# read it back. rspamadm hashes a password only from a terminal, and a password given on a
# command line is readable by every user here - so it is stored, not hashed.
# It is put in a variable rather than printed: a secret that travels through a command
# substitution travels with whatever else the functions inside it happened to print.
MAIL_CONTROLLER_PW=""
lib_mail_controller_password_load() {
  local f="${MAIL_STATE_DIR}/rspamd-controller.info"
  MAIL_CONTROLLER_PW=""
  if [[ -s "$f" ]]; then
    MAIL_CONTROLLER_PW="$(awk -F= '$1=="PASSWORD"{sub(/^[^=]*=/,""); print; exit}' "$f" || true)"
    return 0
  fi
  (( OPT_DRY_RUN )) && return 0
  MAIL_CONTROLLER_PW="$(lib_random_password 24)"
  lib_mkdir "$MAIL_STATE_DIR" 0700 root:root
  printf 'PASSWORD=%s\nAT=%s\n' "$MAIL_CONTROLLER_PW" "$(lib_iso_now)" | lib_write_file "$f" 0600 root:root secret
  return 0
}

# Which resolver Rspamd asks. lompstack runs its own unbound on 5335 where it installed one;
# on a server that already had unbound, that one stays in charge and nothing of its
# configuration is touched - Rspamd then asks it on the usual port.
lib_mail_resolver() {
  local v=""
  v="$(lib_manifest_get '.mail.resolver')"
  printf '%s' "${v:-lomp}"
}

lib_mail_relay_get() {   # field: host|port|user  -> value, empty when no relay is set
  [[ -s "$MAIL_RELAY_INFO" ]] || { printf ''; return 0; }
  awk -F= -v k="${1^^}" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$MAIL_RELAY_INFO" || true
}

# =============================================================================
#  Renderers (pure: arguments in, configuration on stdout)
# =============================================================================
# main.cf. The whole file, because a mail server assembled from package defaults plus a few
# postconf calls is a mail server nobody can read in one sitting.
lib_mail_render_postfix_main() {   # host maptype [ipv4|all] [relay-host] [relay-port]
  local host="$1" t="${2:-hash}" proto="${3:-ipv4}" rhost="${4:-}" rport="${5:-587}"
  printf '# Managed by lompstack - rewritten by "lomp mail regenerate"; local edits are lost.\n'
  printf '# The package'"'"'s own main.cf was archived under %s/archive on the first install.\n\n' "$STATE_DIR"
  printf 'compatibility_level = 3.6\n'
  printf 'myhostname = %s\n' "$host"
  printf 'mydomain = %s\n' "${host#*.}"
  cat <<'EOF'
myorigin = $myhostname
# This machine's own name is a destination, or the mail cron, certbot and fail2ban send to
# root would be posted back to this server over SMTP and refused as a relay. Only the names
# in /etc/aliases are accepted there - local_recipient_maps below sees to that.
mydestination = $myhostname, localhost.$mydomain, localhost
mynetworks = 127.0.0.0/8
inet_interfaces = all
EOF
  printf 'inet_protocols = %s\n' "$proto"
  [[ "$proto" == "all" ]] && printf 'smtp_address_preference = ipv4\n'
  cat <<'EOF'
biff = no
append_dot_mydomain = no
readme_directory = no
html_directory = no
recipient_delimiter = +
mailbox_size_limit = 0
maximal_queue_lifetime = 3d
bounce_queue_lifetime = 1d
EOF
  printf 'alias_maps = %s:/etc/aliases\nalias_database = %s:/etc/aliases\n' "$t" "$t"
  printf 'message_size_limit = %s\n' "$(( MAIL_MSG_SIZE_MB * 1024 * 1024 ))"
  cat <<'EOF'

# Mail for a site is delivered by Dovecot over LMTP. Postfix never writes into /var/vmail:
# one program owns the mailbox format, and a delivery that fails a quota fails at the door.
EOF
  printf 'virtual_mailbox_domains = %s:%s/vdomains\n' "$t" "$MAIL_POSTFIX_DIR"
  printf 'virtual_mailbox_maps = %s:%s/vmailbox\n' "$t" "$MAIL_POSTFIX_DIR"
  printf 'virtual_alias_maps = %s:%s/valias\n' "$t" "$MAIL_POSTFIX_DIR"
  printf 'virtual_mailbox_base = %s\n' "$MAIL_VMAIL_HOME"
  cat <<'EOF'
virtual_transport = lmtp:unix:private/dovecot-lmtp
local_recipient_maps = $alias_maps

# Authentication is Dovecot's, and it never happens on port 25 (see master.cf) or without TLS.
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = no
smtpd_sasl_security_options = noanonymous
smtpd_tls_auth_only = yes
EOF
  printf 'smtpd_sender_login_maps = %s:%s/senders\n' "$t" "$MAIL_POSTFIX_DIR"
  cat <<'EOF'

# A message leaves this server for somebody else only when the sender authenticated. Being on
# this machine is not enough on purpose: a site that gets broken into can reach 127.0.0.1:25
# as easily as anything else, and "permit_mynetworks" here would make that an open relay in
# the server's own name. Mail to a mailbox that lives here is still accepted from loopback,
# which is what a contact form needs.
smtpd_relay_restrictions = permit_sasl_authenticated, reject_unauth_destination
# A sender address this server hosts may only be used by the account that owns it. The rule
# lives on the submission ports (master.cf), not here: port 25 offers no authentication, and
# Postfix skips the check - loudly, on every connection - where SASL is switched off.
# Being on this machine is not on the list below either: a contact form still reaches a
# mailbox here, but it goes past the same quota check as everyone else.
smtpd_recipient_restrictions =
    permit_sasl_authenticated,
    reject_unlisted_recipient,
    reject_unauth_destination,
    check_policy_service unix:private/quota-status
smtpd_helo_required = yes
smtpd_helo_restrictions = permit_mynetworks, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname
smtpd_data_restrictions = reject_unauth_pipelining
disable_vrfy_command = yes
strict_rfc821_envelopes = yes
smtpd_client_connection_rate_limit = 30
smtpd_client_auth_rate_limit = 10
anvil_rate_time_unit = 60s

# Only root may hand a message to sendmail(1). A site's PHP has no way to send mail as
# somebody else; a site authenticates on 127.0.0.1:587 like any other client.
authorized_submit_users = root
EOF
  cat <<'EOF'

# TLS. The chain is the mail host's own certificate; a site's mail name is served from the
# SNI map, whose file holds private keys and is therefore readable by root alone.
EOF
  printf 'smtpd_tls_chain_files = %s/%s/privkey.pem, %s/%s/fullchain.pem\n' "$SSL_DEPLOY_DIR" "$MAIL_CERT_NAME" "$SSL_DEPLOY_DIR" "$MAIL_CERT_NAME"
  printf 'tls_server_sni_maps = %s:%s\n' "$t" "$MAIL_SNI_MAP"
  cat <<'EOF'
smtpd_tls_security_level = may
smtpd_tls_protocols = >=TLSv1.2
smtpd_tls_mandatory_protocols = >=TLSv1.2
smtpd_tls_mandatory_ciphers = medium
smtpd_tls_loglevel = 0
smtpd_tls_session_cache_database = btree:${data_directory}/smtpd_scache
smtp_tls_protocols = >=TLSv1.2
smtp_tls_CApath = /etc/ssl/certs
smtp_tls_session_cache_database = btree:${data_directory}/smtp_scache
tls_preempt_cipherlist = no

# Rspamd signs outgoing mail and scores incoming mail. What happens when it is down differs
# per port and is set in master.cf: incoming mail is accepted, outgoing mail waits.
# The milter is a socket, not a port: the milter protocol is what tells Rspamd who
# authenticated, and on a TCP port any user of this machine could claim to be anyone and walk
# away with a DKIM signature for a domain they do not own.
EOF
  printf 'smtpd_milters = unix:%s\n' "$MAIL_MILTER_SOCK"
  cat <<'EOF'
non_smtpd_milters = $smtpd_milters
milter_protocol = 6
milter_mail_macros = i {mail_addr} {client_addr} {client_name} {auth_authen}
milter_default_action = accept
EOF
  if [[ -n "$rhost" ]]; then
    printf '\n# Outgoing mail goes through a relay because this server cannot reach port 25 itself.\n'
    printf '# The credentials live in %s (0600), never here.\n' "$MAIL_SASL_MAP"
    printf 'relayhost = [%s]:%s\n' "$rhost" "$rport"
    printf 'smtp_sasl_auth_enable = yes\n'
    printf 'smtp_sasl_password_maps = %s:%s\n' "$t" "$MAIL_SASL_MAP"
    printf 'smtp_sasl_security_options = noanonymous\n'
    printf 'smtp_sasl_tls_security_options = noanonymous\n'
    # a password may not travel in the clear, so this one is not "may" like the direct case
    printf 'smtp_tls_security_level = encrypt\n'
  else
    printf 'smtp_tls_security_level = may\n'
  fi
  return 0
}

# master.cf. Three things matter here and nowhere else: port 25 never offers AUTH, every
# submission port demands it, and a message may only claim a sender its account owns.
lib_mail_render_postfix_master() {
  cat <<'EOF'
# Managed by lompstack - rewritten by "lomp mail regenerate"; local edits are lost.
#
# chroot is off on purpose. Postfix reads the certificates and the tables before it drops
# privileges either way, and a chroot here only means a second copy of /etc to keep in step.
#
# service     type  private unpriv  chroot  wakeup  maxproc command + args
smtp          inet  n       -       n       -       -       smtpd
  -o syslog_name=postfix/smtp
  -o milter_default_action=accept
submission    inet  n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o smtpd_sender_restrictions=reject_authenticated_sender_login_mismatch
  -o milter_default_action=tempfail
smtps         inet  n       -       n       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o smtpd_sender_restrictions=reject_authenticated_sender_login_mismatch
  -o milter_default_action=tempfail
# The webmail submits here, and only the webmail: the port is bound to the loopback and no
# rule opens it. It is the one place without TLS, because the connection never leaves the
# machine - but it still authenticates, and it still may only send as the account it logged
# in with, so a compromised webmail is no better placed than a stolen password.
127.0.0.1:10587 inet  n     -       n       -       -       smtpd
  -o syslog_name=postfix/webmail
  -o smtpd_tls_security_level=none
  -o smtpd_tls_auth_only=no
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_sasl_security_options=noanonymous
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o smtpd_sender_restrictions=reject_authenticated_sender_login_mismatch
  -o milter_default_action=tempfail
pickup        unix  n       -       n       60      1       pickup
cleanup       unix  n       -       n       -       0       cleanup
qmgr          unix  n       -       n       300     1       qmgr
tlsmgr        unix  -       -       n       1000?   1       tlsmgr
rewrite       unix  -       -       n       -       -       trivial-rewrite
bounce        unix  -       -       n       -       0       bounce
defer         unix  -       -       n       -       0       bounce
trace         unix  -       -       n       -       0       bounce
verify        unix  -       -       n       -       1       verify
flush         unix  n       -       n       1000?   0       flush
proxymap      unix  -       -       n       -       -       proxymap
proxywrite    unix  -       -       n       -       1       proxymap
smtp          unix  -       -       n       -       -       smtp
relay         unix  -       -       n       -       -       smtp
showq         unix  n       -       n       -       -       showq
error         unix  -       -       n       -       -       error
retry         unix  -       -       n       -       -       error
discard       unix  -       -       n       -       -       discard
local         unix  -       n       n       -       -       local
virtual       unix  -       n       n       -       -       virtual
lmtp          unix  -       -       n       -       -       lmtp
anvil         unix  -       -       n       -       1       anvil
scache        unix  -       -       n       -       1       scache
postlog       unix-dgram n  -       n       -       1       postlogd
EOF
}

# Dovecot 2.3. Everything lompstack decides is in this one file plus the two it includes;
# the package's conf.d keeps its defaults, except for the system-user login it no longer does.
lib_mail_render_dovecot_local() {   # host
  local host="$1"
  printf '# Managed by lompstack - rewritten by "lomp mail regenerate"; local edits are lost.\n\n'
  # sieve is named here because this line overrides the one the managesieved package drops
  # into protocols.d: without it the ManageSieve service never starts, and the filters and
  # holiday replies the webmail offers have nothing to talk to
  printf 'protocols = imap lmtp sieve\n'
  printf 'listen = *, ::\n'
  printf 'mail_location = maildir:%s/%%Ld/%%Ln/Maildir\n' "$MAIL_VMAIL_HOME"
  printf 'mail_plugins = $mail_plugins quota\n'
  printf 'mailbox_list_index = yes\n'
  printf 'auth_mechanisms = plain login\n'
  printf 'auth_username_format = %%Lu\n'
  printf 'disable_plaintext_auth = yes\n'
  printf '!include %s/auth-passwdfile.conf\n' "$MAIL_DOVECOT_DIR"
  printf '\n'
  printf 'ssl = required\n'
  printf 'ssl_cert = <%s/%s/fullchain.pem\n' "$SSL_DEPLOY_DIR" "$MAIL_CERT_NAME"
  printf 'ssl_key = <%s/%s/privkey.pem\n' "$SSL_DEPLOY_DIR" "$MAIL_CERT_NAME"
  printf 'ssl_min_protocol = TLSv1.2\n'
  printf 'ssl_prefer_server_ciphers = no\n'
  printf '# one "local_name mail.<domain>" block per site, written when its mail is enabled\n'
  printf '!include_try %s/sni.conf\n' "$MAIL_DOVECOT_DIR"
  cat <<'EOF'

namespace inbox {
  inbox = yes
  separator = /
  mailbox Drafts {
    special_use = \Drafts
    auto = subscribe
  }
  mailbox Junk {
    special_use = \Junk
    auto = subscribe
  }
  mailbox Sent {
    special_use = \Sent
    auto = subscribe
  }
  mailbox Trash {
    special_use = \Trash
    auto = subscribe
  }
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
EOF
  printf '  unix_listener auth-userdb {\n    mode = 0660\n    user = %s\n    group = %s\n  }\n}\n' "$MAIL_VMAIL_USER" "$MAIL_VMAIL_USER"
  cat <<'EOF'

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

# Postfix asks this before it accepts a message, so a full mailbox is refused at the door
# instead of bouncing afterwards to a sender who never sent it.
service quota-status {
  executable = quota-status -p postfix
  unix_listener /var/spool/postfix/private/quota-status {
    mode = 0660
    user = postfix
    group = postfix
  }
  client_limit = 1
}

# Only IMAPS. A plain-text 143 on loopback is a password oracle for every user of this
# machine - Dovecot treats a local connection as already secure - so it stays closed even
# now that there is a webmail: the webmail speaks TLS to 993 like any other client.
service imap-login {
  inet_listener imap {
    port = 0
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}

# ManageSieve, for the filters and the holiday reply the webmail offers. On the loopback
# only: it carries a password, and the only thing on this machine that speaks it is the
# webmail. A mail client from outside uses none of it.
service managesieve-login {
  inet_listener sieve {
    address = 127.0.0.1
    port = 4190
  }
}

protocol imap {
  mail_max_userip_connections = 10
  mail_plugins = $mail_plugins imap_quota
}

protocol lmtp {
  mail_plugins = $mail_plugins sieve
EOF
  printf '  postmaster_address = postmaster@%s\n}\n' "$host"
  cat <<'EOF'

plugin {
  quota = count:User quota
  quota_vsizes = yes
EOF
  printf '  quota_rule = *:storage=%s\n' "$MAIL_QUOTA_DEFAULT"
  cat <<'EOF'
  quota_grace = 10%%
  quota_status_success = DUNNO
  quota_status_nouser = DUNNO
  quota_status_overquota = "552 5.2.2 Mailbox is over quota"
EOF
  printf '  sieve = file:%s/%%Ld/%%Ln/sieve;active=%s/%%Ld/%%Ln/.dovecot.sieve\n' "$MAIL_VMAIL_HOME" "$MAIL_VMAIL_HOME"
  printf '  sieve_before = %s/spam-to-junk.sieve\n' "$MAIL_SIEVE_DIR"
  cat <<'EOF'
  sieve_max_redirects = 4
  sieve_redirect_envelope_from = orig_recipient
}
EOF
}

# The user store. One file, one format, and no driver that could reach a system account.
lib_mail_render_dovecot_auth() {
  printf '# Managed by lompstack - the only place a mailbox password is checked.\n'
  printf '# Lines are written by "lomp mail box add"; they hold a BLF-CRYPT hash, never a password.\n\n'
  printf 'passdb {\n  driver = passwd-file\n  args = scheme=BLF-CRYPT username_format=%%Lu %s\n}\n\n' "$MAIL_PASSWD_FILE"
  printf 'userdb {\n  driver = passwd-file\n  args = username_format=%%Lu %s\n' "$MAIL_PASSWD_FILE"
  printf '  default_fields = uid=%s gid=%s home=%s/%%Ld/%%Ln\n}\n' "$MAIL_VMAIL_USER" "$MAIL_VMAIL_USER" "$MAIL_VMAIL_HOME"
}

# Mail Rspamd scored as spam goes to Junk instead of the inbox. Nothing is deleted here: a
# false positive the user never sees is worse than one they can drag back.
lib_mail_render_sieve_spam() {
  cat <<'EOF'
# Managed by lompstack
require ["fileinto", "mailbox"];

if header :contains "X-Spam" "Yes" {
  fileinto :create "Junk";
  stop;
}
EOF
}

lib_mail_render_rspamd_worker_proxy() {
  cat <<'EOF'
# Managed by lompstack - the milter Postfix talks to; it scans in this same process.
# It listens on a socket only Postfix can open, because whoever speaks this protocol decides
# which account a message comes from, and that is what DKIM signing is based on.
milter = yes;
timeout = 120s;
upstream "local" {
  default = yes;
  self_scan = yes;
}
count = 1;
max_retries = 5;
discard_on_reject = false;
quarantine_on_reject = false;
spam_header = "X-Spam";
reject_message = "Spam message rejected";
EOF
  printf 'bind_socket = "%s mode=0660 owner=_rspamd group=%s";\n' "$MAIL_MILTER_SOCK" "$MAIL_MILTER_GROUP"
}

lib_mail_render_rspamd_worker_controller() {   # password
  local pw="${1:-}"
  cat <<'EOF'
# Managed by lompstack - the interface answers on a socket only root and _rspamd can open, so
# there is no port for anyone to find. Rspamd asks for the password even over that socket, so
# one is set here; this file is readable by root and Rspamd alone, and "lomp credentials"
# prints the same password from the state directory.
bind_socket = "/run/rspamd/controller.sock mode=0660 owner=_rspamd";
secure_ip = [];
allow_file_and_shm_inputs = false;
EOF
  if [[ -n "$pw" ]]; then
    printf 'password = "%s";\nenable_password = "%s";\n' "$pw" "$pw"
  fi
}

lib_mail_render_rspamd_options() {   # [nameserver]
  local ns="${1:-127.0.0.1:5335}"
  printf '# Managed by lompstack - DNS goes to a resolver on this machine, so a blocklist answer\n'
  printf '# is ours to read and not the provider'"'"'s to log.\n'
  printf 'dns {\n  nameserver = ["%s"];\n  timeout = 1s;\n  sockets = 16;\n}\n' "$ns"
  printf 'local_networks = [127.0.0.0/8, ::1/128];\n'
}

lib_mail_render_rspamd_redis() {
  printf '# Managed by lompstack - Rspamd keeps its counters and its learning in its own Redis.\n'
  printf 'servers = "%s";\n' "$MAIL_REDIS_SOCK"
  printf 'timeout = 1s;\n'
}

lib_mail_render_rspamd_dkim() {   # "dkim_signing" or "arc"
  local what="${1:-dkim_signing}"
  printf '# Managed by lompstack - %s for the domains of this server.\n' "$what"
  printf '# Only an authenticated sender gets a signature, and only for the domain in From:.\n'
  printf 'path = "%s/$domain.$selector.key";\n' "$MAIL_DKIM_DIR"
  printf 'selector_map = "%s/dkim_selectors.map";\n' "$MAIL_RSPAMD_LOMP"
  cat <<'EOF'
sign_authenticated = true;
sign_local = false;
use_domain = "header";
allow_hdrfrom_mismatch = false;
allow_hdrfrom_mismatch_sign_networks = false;
allow_username_mismatch = false;
use_esld = false;
check_pubkey = false;
EOF
}

lib_mail_render_rspamd_actions() {
  cat <<'EOF'
# Managed by lompstack - what a score does. Rejecting below 15 loses real mail.
reject = 15;
add_header = 6;
greylist = 4;
EOF
}

lib_mail_render_rspamd_ratelimit() {
  cat <<'EOF'
# Managed by lompstack - a compromised site cannot turn this server into a spam source
# overnight: one account may send 100 messages an hour, and the burst is no larger.
# The bucket is keyed on the authenticated user, which is the only kind of sender this server
# relays for - so it covers exactly the mail that could run away with us.
rates {
  user = {
    bucket = [
      {
        burst = 100;
        rate = "100 / 1h";
      }
    ];
  }
}
whitelisted_rcpts = "postmaster,mailer-daemon";
EOF
}

lib_mail_render_rspamd_classifier() {   # enabled(0/1)
  local on="${1:-0}"
  printf '# Managed by lompstack - statistical filtering.\n'
  if (( on )); then
    cat <<'EOF'
autolearn = [-5, 10];
backend = "redis";
new_schema = true;
expire = 8640000;
EOF
  else
    printf '# Off on a server this size: an untrained classifier scores worse than none.\n'
    printf 'autolearn = false;\n'
  fi
}

lib_mail_render_rspamd_worker_normal() {
  printf '# Managed by lompstack - the scanning worker is not used; the proxy scans itself.\n'
  printf '# "enabled = false" is what actually keeps it from binding a port of its own.\n'
  printf 'enabled = false;\n'
  printf 'count = 0;\n'
}

lib_mail_render_redis_conf() {
  printf '# Managed by lompstack - Rspamd'"'"'s own Redis. It answers on a socket, not on a port,\n'
  printf '# so the cache the web sites use and the one the mail filter uses never meet.\n'
  printf 'port 0\n'
  printf 'unixsocket %s\n' "$MAIL_REDIS_SOCK"
  printf 'unixsocketperm 700\n'
  printf 'pidfile /run/lomp-redis-rspamd/redis.pid\n'
  printf 'dir %s\n' "$MAIL_REDIS_DATA"
  printf 'dbfilename dump.rdb\n'
  printf 'save 900 1\n'
  printf 'appendonly no\n'
  printf 'maxmemory 64mb\n'
  printf 'maxmemory-policy volatile-lru\n'
  printf 'loglevel notice\n'
  printf 'logfile ""\n'
  printf 'daemonize no\n'
  printf 'supervised systemd\n'
}

lib_mail_render_redis_unit() {
  printf '[Unit]\n'
  printf 'Description=Redis for Rspamd (lompstack)\n'
  printf 'After=network.target\n'
  # Rspamd's counters and its learning live here, so it has to be up first
  printf 'Before=rspamd.service\n\n'
  printf '[Service]\n'
  printf 'Type=notify\n'
  printf 'ExecStart=/usr/bin/redis-server %s\n' "$MAIL_REDIS_CONF"
  printf 'User=_rspamd\nGroup=_rspamd\n'
  printf 'RuntimeDirectory=lomp-redis-rspamd\nRuntimeDirectoryMode=0755\n'
  # the dataset on disk is as readable as the socket: what the filter knows about this
  # server's mail is nobody else's business
  printf 'StateDirectory=lomp-redis-rspamd\nStateDirectoryMode=0700\nUMask=0077\n'
  printf 'Restart=always\nRestartSec=3\n'
  printf 'LimitNOFILE=10032\n'
  printf 'NoNewPrivileges=yes\nPrivateTmp=yes\nProtectSystem=strict\nProtectHome=yes\n'
  printf 'ReadWritePaths=%s\n' "$MAIL_REDIS_DATA"
  printf '\n[Install]\nWantedBy=multi-user.target\n'
}

# A resolver for Rspamd alone, on a port nothing else uses. Everything here is a "server:"
# setting, and on a machine that already runs unbound those are global - so this file says as
# little as it can get away with and leaves the rest of that server's tuning alone.
# Rspamd asks its Redis and its resolver from the first second it runs. Without this, a reboot
# starts all three at once and the first minute of mail is filtered with no counters and no
# blocklist answers.
lib_mail_render_rspamd_dropin() {
  local after="lomp-redis-rspamd.service"
  [[ "$(lib_mail_resolver)" == "lomp" ]] && after="${after} unbound.service"
  printf '# Managed by lompstack\n[Unit]\nAfter=%s\nWants=%s\n' "$after" "$after"
}

lib_mail_render_unbound() {
  cat <<'EOF'
# Managed by lompstack - the resolver Rspamd asks; blocklists want to be queried directly.
server:
  interface: 127.0.0.1@5335
  access-control: 0.0.0.0/0 refuse
  access-control: 127.0.0.0/8 allow
  hide-identity: yes
  hide-version: yes
  qname-minimisation: yes
  prefetch: yes
EOF
}

# fail2ban for the mail ports. The filters are the ones fail2ban ships; what lompstack adds is
# the journal match, without which a systemd-only Ubuntu gives the jail an empty log to watch.
# The addresses never to ban come from the [DEFAULT] section of the base jail file, which
# fail2ban applies to these jails too - there is nothing to repeat here.
lib_mail_render_jails() {
  cat <<'EOF'
# Managed by lompstack - mail jails (rewritten by "lomp mail regenerate")

[postfix]
enabled = true
mode = auth
backend = systemd
journalmatch = _SYSTEMD_UNIT=postfix@-.service
port = smtp,465,submission
maxretry = 5
findtime = 10m
bantime = 1h

[dovecot]
enabled = true
backend = systemd
journalmatch = _SYSTEMD_UNIT=dovecot.service
port = imap,imaps,submission,465,sieve
maxretry = 5
findtime = 10m
bantime = 1h
EOF
}

MAIL_CHANGED=0

# =============================================================================
#  Installation
# =============================================================================
# Which name this server presents to the world. It goes into HELO, into the PTR record the
# provider sets and into the certificate, so it is chosen once and then left alone.
# Prints the name, or returns 1 with the reason in MAIL_LAST_ERROR. It does not call lib_die
# itself: it runs inside a command substitution, where a die would report the failure from
# inside the subshell and then again from the assignment that adopted its status.
lib_mail_host_resolve() {   # [wanted]
  local want="${1:-}" cur="" fqdn=""
  cur="$(lib_mail_host)"
  if [[ -n "$want" ]]; then
    if ! lib_mail_name_usable "$want"; then
      MAIL_LAST_ERROR="'${want}' is not a name this server can send mail as: it has to be a name under a domain you control, like mail.example.com"
      return 1
    fi
    if [[ -n "$cur" && "$cur" != "${want,,}" ]]; then
      lib_warn "This server already sends mail as ${cur}; changing it to ${want} means a new PTR record and new certificates"
    fi
    printf '%s' "${want,,}"
    return 0
  fi
  if [[ -n "$cur" ]]; then printf '%s' "$cur"; return 0; fi
  fqdn="$(hostname -f 2>/dev/null || true)"
  if lib_mail_name_usable "${fqdn:-}"; then
    printf '%s' "${fqdn,,}"
    return 0
  fi
  MAIL_LAST_ERROR="the system host name ('${fqdn:-none}') is not a name under a domain you control, and mail needs one for HELO and for the PTR record"
  return 1
}

# A name mail can be sent as. The local names a fresh VPS image comes with look valid and are
# not: certbot cannot issue for them and every recipient rejects the HELO.
lib_mail_name_usable() {
  local h="${1,,}"
  lib_mail_hostname_valid "$h" || return 1
  case "$h" in
    *.localdomain|*.local|*.localhost|localhost.*|*.internal|*.lan|*.home|*.invalid|*.test|*.example) return 1 ;;
  esac
  return 0
}

lib_mail_repo_setup() {
  lib_apt_key_install "https://rspamd.com/apt-stable/gpg.key" "$MAIL_RSPAMD_KEY"
  printf 'deb [signed-by=%s] https://rspamd.com/apt-stable/ %s main\n' "$MAIL_RSPAMD_KEY" "$OS_CODENAME" \
    | lib_write_file "$MAIL_APT_LIST" 0644 root:root
  (( LIB_FILE_CHANGED )) && LIB_APT_UPDATED=0
  lib_ok "Rspamd repository configured (${OS_CODENAME})"
}

# The two users that own mail and webmail. No site user is ever put in either group: a site
# that gets broken into finds /var/vmail unreadable, including its own domain's mail.
lib_mail_users_ensure() {
  local u=""
  # the group that lets Postfix and Rspamd talk over a socket, and nobody else listen in
  if ! getent group "$MAIL_MILTER_GROUP" >/dev/null 2>&1; then
    if (( OPT_DRY_RUN )); then lib_info "[dry-run] would create the group ${MAIL_MILTER_GROUP}"
    else lib_run groupadd --system "$MAIL_MILTER_GROUP" || lib_die "groupadd ${MAIL_MILTER_GROUP} failed" "" "check /etc/group"; fi
  fi
  if (( ! OPT_DRY_RUN )); then
    for u in _rspamd postfix; do
      id -u "$u" >/dev/null 2>&1 || continue
      id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx "$MAIL_MILTER_GROUP" && continue
      # a process learns its groups when it starts, so this has to reach a restart
      MAIL_CHANGED=1
      lib_run usermod -aG "$MAIL_MILTER_GROUP" "$u" || lib_warn "could not put ${u} in the ${MAIL_MILTER_GROUP} group"
    done
  fi
  for u in "$MAIL_VMAIL_USER" "$MAIL_WEBMAIL_USER"; do
    id -u "$u" >/dev/null 2>&1 && continue
    if (( OPT_DRY_RUN )); then lib_info "[dry-run] would create the system user ${u}"; continue; fi
    if [[ "$u" == "$MAIL_VMAIL_USER" ]]; then
      lib_run useradd --system -M -d "$MAIL_VMAIL_HOME" -s /usr/sbin/nologin -U -c "lompstack mail storage" "$u" \
        || lib_die "useradd ${u} failed" "" "check /etc/passwd"
    else
      lib_run useradd --system -M -d /nonexistent -s /usr/sbin/nologin -U -c "lompstack webmail" "$u" \
        || lib_die "useradd ${u} failed" "" "check /etc/passwd"
    fi
    lib_ok "System user ${u} created"
  done
  return 0
}

lib_mail_dirs_ensure() {
  lib_mkdir "$MAIL_VMAIL_HOME" 0750 "${MAIL_VMAIL_USER}:${MAIL_VMAIL_USER}"
  lib_mkdir "$MAIL_POSTFIX_DIR" 0750 root:postfix
  # the mailbox hashes live here, so nobody but Dovecot gets to look inside
  lib_mkdir "$MAIL_DOVECOT_DIR" 0750 root:dovecot
  lib_mkdir "$MAIL_SIEVE_DIR" 0755 root:root
  lib_mkdir "$MAIL_RSPAMD_LOMP" 0755 root:root
  lib_mkdir "$MAIL_DKIM_DIR" 0750 root:_rspamd
  lib_mkdir "$MAIL_STATE_DIR" 0700 root:root
  # a server installed before StateDirectoryMode was set keeps the mode systemd gave it
  if (( ! OPT_DRY_RUN )) && [[ -d "$MAIL_REDIS_DATA" ]]; then chmod 0700 "$MAIL_REDIS_DATA" 2>/dev/null || true; fi
  return 0
}

lib_mail_dovecot_version() { dovecot --version 2>/dev/null | awk '{print $1; exit}' || true; }

# lompstack writes Dovecot 2.3 configuration. 2.4 renamed enough of it that a file written for
# 2.3 does not start there, so an unexpected major is refused instead of half-applied.
lib_mail_dovecot_gate() {
  local v=""
  (( OPT_DRY_RUN )) && return 0
  v="$(lib_mail_dovecot_version)"
  [[ -n "$v" ]] || return 0
  case "$v" in
    2.3.*) return 0 ;;
    *) lib_die "Dovecot ${v} is not supported yet" \
         "lompstack writes Dovecot 2.3 configuration; this system has ${v}" \
         "stay on Ubuntu 22.04/24.04 for mail until lompstack speaks 2.4" ;;
  esac
}

# Dovecot's packaged configuration lets a system user log in with their Linux password. On a
# server whose users are sites, that is a second front door into every account, so the include
# that brings it in is commented out. doctor fails if it ever comes back.
lib_mail_pam_disable() {
  local f="$MAIL_DOVECOT_10AUTH"
  [[ -f "$f" ]] || return 0
  grep -qE '^[[:space:]]*!include auth-system\.conf\.ext' "$f" || return 0
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would switch off system-user authentication in ${f}"; return 0; fi
  lib_backup_config "$f" >/dev/null
  sed -i 's|^\([[:space:]]*\)\(!include auth-system\.conf\.ext\)|\1#\2   # lompstack: no system user authenticates to IMAP|' "$f"
  MAIL_CHANGED=1
  lib_ok "System-user authentication switched off in Dovecot"
}

lib_mail_postmap() {   # file [-F] [force]
  local f="$1" flag="${2:-}" force="${3:-}" t=""
  (( OPT_DRY_RUN )) && { lib_info "[dry-run] would rebuild the Postfix map ${f}"; return 0; }
  lib_have postmap || return 0
  # a table no older than its source is already up to date. Rebuilding it anyway would write
  # a different file every run - Berkeley DB pages differ even for identical content - and
  # two runs of the same install would stop looking the same.
  # "force" is for the SNI table: postmap -F copies the certificates INTO it, so what it
  # should hold changes on renewal without the file it is built from being touched.
  if [[ -z "$force" ]]; then
    if [[ -f "${f}.db" ]] && ! [[ "$f" -nt "${f}.db" ]]; then return 0; fi
    if [[ -f "${f}.lmdb" ]] && ! [[ "$f" -nt "${f}.lmdb" ]]; then return 0; fi
  fi
  t="$(lib_mail_map_type)"
  if [[ -n "$flag" ]]; then
    lib_run postmap "$flag" "${t}:${f}" || { MAIL_LAST_ERROR="postmap failed for ${f}"; return 1; }
  else
    lib_run postmap "${t}:${f}" || { MAIL_LAST_ERROR="postmap failed for ${f}"; return 1; }
  fi
  return 0
}

# The lookup tables Postfix reads. They start empty; enabling a domain fills them.
lib_mail_maps_ensure() {
  local f=""
  for f in vdomains vmailbox valias senders; do
    if [[ ! -f "${MAIL_POSTFIX_DIR}/${f}" ]]; then
      printf '# Managed by lompstack - written when a domain gets mail\n' \
        | lib_write_file "${MAIL_POSTFIX_DIR}/${f}" 0640 root:postfix
    fi
    lib_mail_postmap "${MAIL_POSTFIX_DIR}/${f}" || return 1
  done
  # the SNI map carries private keys, so it belongs to root alone and is built with postmap -F
  if [[ ! -f "$MAIL_SNI_MAP" ]]; then
    printf '# Managed by lompstack - one entry per mail name, written when a domain gets mail\n' \
      | lib_write_file "$MAIL_SNI_MAP" 0600 root:root secret
  fi
  lib_mail_postmap "$MAIL_SNI_MAP" -F || return 1
  # postmap -F copies the private keys themselves into the table it builds, so the table is
  # as secret as the keys are
  if (( ! OPT_DRY_RUN )); then
    chmod 0600 "${MAIL_SNI_MAP}.db" 2>/dev/null || true
    chmod 0600 "${MAIL_SNI_MAP}.lmdb" 2>/dev/null || true
  fi
  return 0
}

# Mail to root and postmaster has to land somewhere a person reads.
lib_mail_aliases_ensure() {
  local to="${DEFAULT_EMAIL:-}" f="/etc/aliases"
  (( OPT_DRY_RUN )) && { lib_info "[dry-run] would forward root's mail in ${f}"; return 0; }
  [[ -f "$f" ]] || printf '# Managed by the mail system\n' >"$f"
  lib_append_line_once "$f" "postmaster: root"
  # one "root:" line, not one per address the operator has ever used: a second one leaves the
  # old address receiving this server's mail forever
  if [[ -n "$to" ]]; then
    sed -i '/^[[:space:]]*root:[[:space:]]/d' "$f"
    printf 'root: %s\n' "$to" >>"$f"
  fi
  if lib_have newaliases; then lib_run newaliases || lib_warn "newaliases failed (see log)"; fi
  return 0
}

# Postfix and Dovecot refuse to start without a certificate, and the real one can take a
# minute or a day (a DNS record may still be missing). A self-signed one keeps the service up
# meanwhile; it is replaced the moment certbot succeeds.
lib_mail_cert_fallback() {   # host
  local host="$1" dir="${SSL_DEPLOY_DIR}/${MAIL_CERT_NAME}"
  if [[ -s "${dir}/fullchain.pem" && -s "${dir}/privkey.pem" ]]; then return 0; fi
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would create a temporary self-signed certificate for ${host}"; return 0; fi
  lib_mkdir "$SSL_DEPLOY_DIR" 0700 root:root
  lib_mkdir "$dir" 0700 root:root
  ( umask 077
    openssl req -x509 -nodes -days 3650 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -subj "/CN=${host}" -keyout "${dir}/privkey.pem" -out "${dir}/fullchain.pem" ) >/dev/null 2>&1 \
    || { MAIL_LAST_ERROR="could not create the temporary certificate for ${host}"; return 1; }
  chmod 0600 "${dir}/privkey.pem" "${dir}/fullchain.pem"
  lib_warn "Using a self-signed certificate for ${host} until Let's Encrypt answers (clients will warn until then)"
  return 0
}

# Ask for the real certificate. A failure is not fatal: the stack runs on the temporary one
# and a cron entry keeps trying every six hours until it succeeds, then removes itself.
lib_mail_cert_ensure() {   # host
  local host="$1" names=""
  [[ -n "$host" ]] || return 0
  # an existing lineage counts only when it actually covers the name this server sends as -
  # changing the mail host otherwise leaves the old certificate in place for good
  if lib_ssl_cert_exists "$MAIL_CERT_NAME"; then
    names="$(openssl x509 -noout -ext subjectAltName -in "${LE_LIVE}/${MAIL_CERT_NAME}/fullchain.pem" 2>/dev/null | tr ',' '\n' | sed -n 's/.*DNS://p' | tr -d ' ' | tr '\n' ' ' || true)"
    if [[ " $names " == *" ${host} "* ]]; then
      lib_ssl_deploy_files "$MAIL_CERT_NAME" || lib_warn "certificate ${MAIL_CERT_NAME} could not be deployed: ${SSL_LAST_ERROR}"
      lib_cron_remove "mail-cert"
      (( OPT_DRY_RUN )) || lib_systemctl reload postfix dovecot >/dev/null 2>&1 || true
      lib_ok "Certificate for ${host} in place ($(lib_ssl_days_left "$MAIL_CERT_NAME") days left)"
      return 0
    fi
    lib_info "The certificate ${MAIL_CERT_NAME} covers ${names:-nothing}, not ${host}; asking for one that does"
  fi
  if lib_ssl_obtain_names "$MAIL_CERT_NAME" "$host"; then
    lib_cron_remove "mail-cert"
    lib_systemctl reload postfix dovecot >/dev/null 2>&1 || true
    return 0
  fi
  lib_warn "No certificate for ${host} yet: ${SSL_LAST_ERROR}"
  lib_note "Point an A record at this server for ${host}, then run: lomp mail cert"
  lib_cron_set "mail-cert" "23 */6 * * * root ${BIN_LINK} mail cert --quiet"
  return 0
}

lib_mail_firewall() {
  local p=""
  lib_have ufw || return 0
  for p in 25 465 587 993; do
    lib_ufw_rule allow "${p}/tcp" comment "lompstack mail" || lib_warn "could not add the UFW rule for ${p}/tcp"
  done
  lib_ok "Mail ports opened in the firewall (25, 465, 587, 993)"
}

# =============================================================================
#  Applying the configuration
# =============================================================================
# The files this module owns. One list, walked by the writing, the snapshot and the rollback
# alike, so a file cannot be written without also being saved and taken away again.
lib_mail_managed_files() {
  printf '%s\n' \
    "$MAIL_POSTFIX_MAIN" "$MAIL_POSTFIX_MASTER" \
    "$MAIL_DOVECOT_LOCAL" "${MAIL_DOVECOT_DIR}/auth-passwdfile.conf" "$MAIL_DOVECOT_10AUTH" \
    "${MAIL_SIEVE_DIR}/spam-to-junk.sieve" \
    "${MAIL_RSPAMD_DIR}/worker-proxy.inc" "${MAIL_RSPAMD_DIR}/worker-normal.inc" \
    "${MAIL_RSPAMD_DIR}/worker-controller.inc" "${MAIL_RSPAMD_DIR}/options.inc" \
    "${MAIL_RSPAMD_DIR}/redis.conf" "${MAIL_RSPAMD_DIR}/dkim_signing.conf" \
    "${MAIL_RSPAMD_DIR}/arc.conf" "${MAIL_RSPAMD_DIR}/actions.conf" \
    "${MAIL_RSPAMD_DIR}/ratelimit.conf" "${MAIL_RSPAMD_DIR}/classifier-bayes.conf" \
    "$MAIL_REDIS_CONF" "$MAIL_REDIS_UNIT" "$MAIL_RSPAMD_DROPIN" "$MAIL_UNBOUND_CONF" "$MAIL_JAIL_FILE"
}

MAIL_SNAPSHOT=""      # archive holding the managed files as they were before this run
MAIL_CREATED=()       # managed files this run created, which a rollback has to take away

# Save what is about to be overwritten, and remember what does not exist yet.
lib_mail_snapshot() {
  local f="" out="" rel=()
  MAIL_SNAPSHOT=""
  MAIL_CREATED=()
  (( OPT_DRY_RUN )) && return 0
  while read -r f; do
    [[ -n "$f" ]] || continue
    if [[ -e "$f" ]]; then rel+=("${f#/}"); else MAIL_CREATED+=("$f"); fi
  done < <(lib_mail_managed_files)
  ((${#rel[@]})) || return 0          # a first install has nothing to save
  out="${STATE_DIR}/archive/mail-conf-$(lib_ts).tar.gz"
  mkdir -p "${STATE_DIR}/archive" && chmod 0700 "${STATE_DIR}/archive"
  if ! ( umask 077; tar czf "$out" -C / "${rel[@]}" 2>/dev/null ); then
    MAIL_LAST_ERROR="the current mail configuration could not be saved to ${out}"
    return 1
  fi
  chmod 0600 "$out" 2>/dev/null || true
  MAIL_SNAPSHOT="$out"
  # one of these is written on every apply and only the newest few are ever of any use; a
  # server that re-runs the installer nightly should not fill its disk with them
  ls -1t "${STATE_DIR}/archive"/mail-conf-*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f || true
  return 0
}

# Put the previous state back: first take away the files this run created - tar only
# overwrites, it never deletes - then extract what was saved.
lib_mail_restore_snapshot() {
  local f=""
  (( OPT_DRY_RUN )) && return 0
  if ((${#MAIL_CREATED[@]})); then
    for f in "${MAIL_CREATED[@]}"; do rm -f "$f"; done
  fi
  [[ -n "$MAIL_SNAPSHOT" && -s "$MAIL_SNAPSHOT" ]] || return 0
  tar xzf "$MAIL_SNAPSHOT" -C / 2>/dev/null || return 1
  lib_log_write WARN "mail configuration restored from ${MAIL_SNAPSHOT}"
  return 0
}

_mail_changed_note() { if (( LIB_FILE_CHANGED )); then MAIL_CHANGED=1; fi; return 0; }

# Every configuration file of the stack, from the renderers. Sets MAIL_CHANGED when at least
# one file is new or different.
lib_mail_configs_write() {   # host
  local host="$1" t="" proto="ipv4" rhost="" rport=""
  t="$(lib_mail_map_type)"
  rhost="$(lib_mail_relay_get host)"
  rport="$(lib_mail_relay_get port)"
  # "mail regenerate" and "mail relay" do not go through the installer, so the machine has not
  # been measured yet; without this the classifier would be rewritten as if the server had no
  # memory at all
  (( SYS_RAM_MB > 0 )) || lib_system_analyze --no-net

  lib_mail_render_postfix_main "$host" "$t" "$proto" "$rhost" "${rport:-587}" | lib_write_file "$MAIL_POSTFIX_MAIN" 0644 root:root
  _mail_changed_note
  lib_mail_render_postfix_master | lib_write_file "$MAIL_POSTFIX_MASTER" 0644 root:root
  _mail_changed_note
  lib_mail_render_dovecot_local "$host" | lib_write_file "$MAIL_DOVECOT_LOCAL" 0644 root:root
  _mail_changed_note
  lib_mail_render_dovecot_auth | lib_write_file "${MAIL_DOVECOT_DIR}/auth-passwdfile.conf" 0644 root:root
  _mail_changed_note
  lib_mail_render_sieve_spam | lib_write_file "${MAIL_SIEVE_DIR}/spam-to-junk.sieve" 0644 root:root
  _mail_changed_note
  # Pigeonhole compiles a global script into the directory it sits in, as the delivery user -
  # which cannot write there. Compiled here instead, once, by root.
  if (( LIB_FILE_CHANGED )) && (( ! OPT_DRY_RUN )) && lib_have sievec; then
    lib_run sievec "${MAIL_SIEVE_DIR}/spam-to-junk.sieve" || lib_warn "the spam-to-Junk rule could not be compiled (sievec)"
  fi
  lib_mail_render_rspamd_worker_proxy | lib_write_file "${MAIL_RSPAMD_DIR}/worker-proxy.inc" 0644 root:root
  _mail_changed_note
  lib_mail_render_rspamd_worker_normal | lib_write_file "${MAIL_RSPAMD_DIR}/worker-normal.inc" 0644 root:root
  _mail_changed_note
  lib_mail_controller_password_load
  lib_mail_render_rspamd_worker_controller "$MAIL_CONTROLLER_PW" \
    | lib_write_file "${MAIL_RSPAMD_DIR}/worker-controller.inc" 0640 root:_rspamd secret
  _mail_changed_note
  if [[ "$(lib_mail_resolver)" == "lomp" ]]; then
    lib_mail_render_rspamd_options "127.0.0.1:5335" | lib_write_file "${MAIL_RSPAMD_DIR}/options.inc" 0644 root:root
    _mail_changed_note
    lib_mail_render_unbound | lib_write_file "$MAIL_UNBOUND_CONF" 0644 root:root
    _mail_changed_note
  else
    lib_mail_render_rspamd_options "127.0.0.1:53" | lib_write_file "${MAIL_RSPAMD_DIR}/options.inc" 0644 root:root
    _mail_changed_note
  fi
  lib_mail_render_rspamd_redis | lib_write_file "${MAIL_RSPAMD_DIR}/redis.conf" 0644 root:root
  _mail_changed_note
  lib_mail_render_rspamd_dkim dkim_signing | lib_write_file "${MAIL_RSPAMD_DIR}/dkim_signing.conf" 0644 root:root
  _mail_changed_note
  lib_mail_render_rspamd_dkim arc | lib_write_file "${MAIL_RSPAMD_DIR}/arc.conf" 0644 root:root
  _mail_changed_note
  lib_mail_render_rspamd_actions | lib_write_file "${MAIL_RSPAMD_DIR}/actions.conf" 0644 root:root
  _mail_changed_note
  lib_mail_render_rspamd_ratelimit | lib_write_file "${MAIL_RSPAMD_DIR}/ratelimit.conf" 0644 root:root
  _mail_changed_note
  lib_mail_render_rspamd_classifier "$(( SYS_RAM_MB > 4096 ? 1 : 0 ))" | lib_write_file "${MAIL_RSPAMD_DIR}/classifier-bayes.conf" 0644 root:root
  _mail_changed_note
  if [[ ! -f "${MAIL_RSPAMD_LOMP}/dkim_selectors.map" ]]; then
    printf '# Managed by lompstack - "<domain> <selector>", one line per domain with mail\n' \
      | lib_write_file "${MAIL_RSPAMD_LOMP}/dkim_selectors.map" 0644 root:root
    _mail_changed_note
  fi
  # 0644: the Redis that Rspamd owns runs as _rspamd and has to read its own configuration.
  # There is nothing secret in it - the instance answers on a socket only that user can open.
  lib_mail_render_redis_conf | lib_write_file "$MAIL_REDIS_CONF" 0644 root:root
  _mail_changed_note
  lib_mail_render_redis_unit | lib_write_file "$MAIL_REDIS_UNIT" 0644 root:root
  _mail_changed_note
  lib_mkdir "$(dirname "$MAIL_RSPAMD_DROPIN")" 0755 root:root
  lib_mail_render_rspamd_dropin | lib_write_file "$MAIL_RSPAMD_DROPIN" 0644 root:root
  _mail_changed_note
  lib_mail_render_jails | lib_write_file "$MAIL_JAIL_FILE" 0644 root:root
  _mail_changed_note
  # the user store exists from the first install; without it Dovecot refuses to start
  if [[ ! -f "$MAIL_PASSWD_FILE" ]]; then
    printf '' | lib_write_file "$MAIL_PASSWD_FILE" 0640 root:dovecot secret
    _mail_changed_note
  fi
  return 0
}

# Does the configuration on disk parse? Each program is asked in its own words; whichever
# says no says why in MAIL_LAST_ERROR, and nothing is reloaded.
lib_mail_verify_configs() {
  local out="" t=""
  (( OPT_DRY_RUN )) && return 0
  if lib_have postfix; then
    # "postfix check" says plenty on a healthy system - it reports the permissions it fixed
    # and the copies it keeps inside the chroot. Only its exit status and a fatal or error
    # line mean the configuration will not run; the rest goes to the log.
    t="$(lib_mktemp)"
    if ! postfix check >"$t" 2>&1; then
      MAIL_LAST_ERROR="postfix check: $(tr '\n' ' ' <"$t" | cut -c1-300)"
      rm -f "$t"
      return 1
    fi
    if grep -qiE '(^|: )(fatal|error):' "$t"; then
      MAIL_LAST_ERROR="postfix check: $(grep -iE '(fatal|error):' "$t" | head -n 2 | tr '\n' ' ')"
      rm -f "$t"
      return 1
    fi
    if [[ -s "$t" ]]; then lib_log_write INFO "postfix check: $(tr '\n' ' ' <"$t")"; fi
    rm -f "$t"
  fi
  if lib_have doveconf; then
    doveconf -n >/dev/null 2>&1 || { MAIL_LAST_ERROR="doveconf -n refused the Dovecot configuration"; return 1; }
  fi
  if lib_have rspamadm; then
    rspamadm configtest >/dev/null 2>&1 || { MAIL_LAST_ERROR="rspamadm configtest refused the Rspamd configuration"; return 1; }
  fi
  return 0
}

lib_mail_services() {
  printf '%s\n' lomp-redis-rspamd
  [[ "$(lib_mail_resolver)" == "lomp" ]] && printf 'unbound\n'
  printf '%s\n' rspamd dovecot postfix
}

# Are they all up? This is what decides, together with MAIL_CHANGED, whether a run that
# changed nothing still has to restart anything.
lib_mail_services_active() {
  local s=""
  while read -r s; do
    [[ -n "$s" ]] || continue
    lib_service_exists "$s" || continue
    lib_service_active "$s" || return 1
  done < <(lib_mail_services)
  return 0
}

lib_mail_services_apply() {
  local s="" p=""
  (( OPT_DRY_RUN )) && { lib_info "[dry-run] would enable and restart: $(lib_mail_services | tr '\n' ' ')"; return 0; }
  lib_systemctl daemon-reload >/dev/null 2>&1 || true
  while read -r s; do
    [[ -n "$s" ]] || continue
    lib_service_exists "$s" || continue
    lib_systemctl enable "$s" >/dev/null 2>&1 || true
    lib_run systemctl restart "$s" || { MAIL_LAST_ERROR="${s} did not start (systemctl status ${s})"; return 1; }
  done < <(lib_mail_services)
  # a service that starts and then dies takes a moment to do it
  sleep 2
  while read -r s; do
    [[ -n "$s" ]] || continue
    lib_service_exists "$s" || continue
    lib_service_active "$s" || { MAIL_LAST_ERROR="${s} stopped right after starting (journalctl -u ${s})"; return 1; }
  done < <(lib_mail_services)
  for p in 25 587 993; do
    lib_port_listening "$p" || { MAIL_LAST_ERROR="nothing is listening on port ${p}"; return 1; }
  done
  return 0
}

# Undo an apply that did not work out: take the files away, put the old ones back, and get
# whatever is installed running again on the configuration that used to work.
_mail_apply_rollback() {   # reason
  local s="" dead=()
  lib_warn "$1"
  if ! lib_mail_restore_snapshot; then
    lib_warn "The previous mail configuration could NOT be put back; the stack is as this run left it"
    return 0
  fi
  lib_warn "The previous mail configuration was put back${MAIL_SNAPSHOT:+ (${MAIL_SNAPSHOT})}"
  (( OPT_DRY_RUN )) && return 0
  # every service, not only the two at the end of the list: the apply stops at the first one
  # that fails, so the ones already restarted are running on files that have just been taken
  # away from them. Unit files were restored too, hence the daemon-reload.
  systemctl daemon-reload >/dev/null 2>&1 || true
  while read -r s; do
    [[ -n "$s" ]] || continue
    lib_service_exists "$s" || continue
    systemctl restart "$s" >/dev/null 2>&1 || dead+=("$s")
  done < <(lib_mail_services)
  if lib_service_active fail2ban; then fail2ban-client reload >/dev/null 2>&1 || true; fi
  if ((${#dead[@]})); then
    lib_warn "These did not come back on the previous configuration either: ${dead[*]} (journalctl -u ${dead[0]})"
  else
    lib_ok "The mail stack is running again on the configuration that worked"
  fi
  return 0
}

# Write, test, restart - and if any of it fails, put the previous configuration back and say
# so. A half-applied mail server is worse than none: it accepts mail it cannot deliver.
lib_mail_apply() {   # host
  local host="$1"
  [[ -n "$host" ]] || { MAIL_LAST_ERROR="no mail host is set"; return 1; }
  # re-asserted on every apply, not only at install: a dovecot-core upgrade that restores its
  # own conffile would otherwise hand every Linux account an IMAP login again
  # MAIL_CHANGED is raised by everything that changes something the services read, not only by
  # the renderers: an edit made with sed still has to reach a running Dovecot.
  MAIL_CHANGED=0
  lib_mail_pam_disable
  if ! lib_mail_snapshot; then
    lib_warn "Nothing was changed: ${MAIL_LAST_ERROR}"
    return 1
  fi
  # also on the run's own rollback stack, so a failure that ends the command outright - a full
  # disk while a file is being written, say - still puts the mail configuration back
  lib_rollback_push "lib_mail_restore_snapshot"
  lib_mail_configs_write "$host"
  if ! lib_mail_maps_ensure; then
    lib_rollback_drop "lib_mail_restore_snapshot"
    _mail_apply_rollback "A Postfix lookup table could not be built: ${MAIL_LAST_ERROR}"
    return 1
  fi
  if ! lib_mail_verify_configs; then
    lib_rollback_drop "lib_mail_restore_snapshot"
    _mail_apply_rollback "The mail configuration was refused: ${MAIL_LAST_ERROR}"
    return 1
  fi
  if (( MAIL_CHANGED )) || ! lib_mail_services_active; then
    if ! lib_mail_services_apply; then
      lib_rollback_drop "lib_mail_restore_snapshot"
      _mail_apply_rollback "The mail stack did not come up: ${MAIL_LAST_ERROR}"
      return 1
    fi
    # the jail file is one of the managed files, so every path that rewrites it - regenerate
    # and relay as much as install - has to put it into effect
    if (( ! OPT_DRY_RUN )) && lib_service_active fail2ban; then
      lib_run fail2ban-client reload >/dev/null 2>&1 || lib_warn "fail2ban reload failed (see log)"
    fi
  else
    lib_info "Mail configuration unchanged; the stack was left running"
  fi
  lib_rollback_drop "lib_mail_restore_snapshot"
  return 0
}

# =============================================================================
#  install
# =============================================================================
lib_mail_install() {   # [hostname]
  local host=""
  host="$(lib_mail_host_resolve "${1:-}")" || lib_die "This server has no name to send mail as" \
    "$MAIL_LAST_ERROR" "lomp install --with-mail --mail-hostname mail.example.com"
  if (( ! OPT_DRY_RUN )) && (( SYS_RAM_MB > 0 && SYS_RAM_MB < MAIL_MIN_RAM_MB )); then
    lib_die "Not enough memory for a mail server (${SYS_RAM_MB} MB)" \
      "Postfix, Dovecot and Rspamd together want about 400 MB on top of the web stack" \
      "install mail on a server with at least 2 GB"
  fi
  lib_info "Installing the mail stack for ${host}"
  # a resolver that was here before lompstack is somebody else's to configure: the mail stack
  # then asks it on the usual port instead of standing up a second one
  if (( ! OPT_DRY_RUN )) && [[ -z "$(lib_manifest_get '.mail.resolver')" ]]; then
    if lib_pkg_installed unbound; then lib_manifest_set '.mail.resolver' 'system'
    else lib_manifest_set '.mail.resolver' 'lomp'; fi
  fi
  lib_mail_repo_setup
  if (( ! OPT_DRY_RUN )); then
    printf 'postfix postfix/main_mailer_type select Internet Site\npostfix postfix/mailname string %s\n' "$host" \
      | debconf-set-selections 2>/dev/null || true
  fi
  # dns-root-data and unbound-anchor are what unbound needs for the DNSSEC root key. They are
  # only "recommended" packages, and lompstack installs without recommends, so unbound would
  # refuse to start on a file that was never created.
  lib_apt_install postfix postfix-lmdb dovecot-core dovecot-imapd dovecot-lmtpd dovecot-sieve \
    dovecot-managesieved rspamd redis-server unbound unbound-anchor dns-root-data \
    || lib_die "The mail packages could not be installed" "apt error" "check ${LOG_FILE} and the Rspamd repository"
  lib_mail_dovecot_gate
  lib_mail_users_ensure
  lib_mail_dirs_ensure
  lib_mail_pam_disable
  lib_mail_cert_fallback "$host" || lib_warn "$MAIL_LAST_ERROR"
  if ! lib_mail_apply "$host"; then
    lib_die "The mail stack could not be started" "${MAIL_LAST_ERROR}" "lomp doctor, then lomp mail status"
  fi
  lib_mail_aliases_ensure
  lib_mail_firewall
  if (( ! OPT_DRY_RUN )); then
    lib_manifest_set '.mail.hostname' "$host"
    lib_manifest_set '.components.mail.postfix' "$(lib_pkg_version postfix)"
    lib_manifest_set '.components.mail.dovecot' "$(lib_pkg_version dovecot-core)"
    lib_manifest_set '.components.mail.rspamd' "$(lib_pkg_version rspamd)"
  fi
  lib_mail_cert_ensure "$host"
  lib_ok "Mail stack ready as ${host}"
  lib_note "No domain sends or receives mail yet: give one its own mail with 'lomp mail enable example.com'"
  (( OPT_DRY_RUN )) || lib_mail_test_report brief
  return 0
}

# Used by the commands that need mail to be there. It installs on demand, with a question,
# because adding a site should not quietly turn a web server into a mail server.
lib_mail_ensure() {
  lib_mail_installed && return 0
  if ! lib_confirm "The mail stack (Postfix, Dovecot, Rspamd) is not installed yet. Install it now?"; then
    MAIL_LAST_ERROR="mail stack not installed"
    return 1
  fi
  lib_mail_install ""
}

# =============================================================================
#  Deliverability: can this server actually send?
# =============================================================================
# A provider that blocks outgoing port 25 is the most common reason mail does not leave a new
# server, and nothing in the configuration shows it. The answer is cached for a day.
lib_mail_port25_probe() {   # -> open|blocked|unknown
  local cache="${MAIL_STATE_DIR}/port25.info" age="" h="" ok=0 tmp=""
  if [[ -s "$cache" ]]; then
    age="$(lib_file_age_days "$cache")"
    if [[ -n "$age" ]] && (( age < 1 )); then
      awk -F= '$1=="RESULT"{print $2; exit}' "$cache" || true
      return 0
    fi
  fi
  if (( OPT_DRY_RUN )); then printf 'unknown'; return 0; fi
  for h in gmail-smtp-in.l.google.com mx1.hotmail.com; do
    if lib_tcp_open "$h" 25 6; then ok=1; break; fi
  done
  lib_mkdir "$MAIL_STATE_DIR" 0700 root:root
  # written through a rename: "mail status" does not take the global lock, so two of them
  # running at once must not leave half a line behind
  tmp="${cache}.$$"
  if (( ok )); then printf 'RESULT=open\nAT=%s\n' "$(lib_iso_now)" >"$tmp"
  else printf 'RESULT=blocked\nAT=%s\n' "$(lib_iso_now)" >"$tmp"; fi
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp"
  if (( ok )); then printf 'open'; else printf 'blocked'; fi
  return 0
}

# The receiving side checks that the address the mail comes from has a name, and that the name
# points back. Only the provider can set the first half, so lomp checks it and says what to do.
lib_mail_ptr_check() {   # host -> 0 ok, 1 mismatch (detail in MAIL_LAST_ERROR)
  local host="$1" ip="" ptr="" fwd=""
  lib_system_analyze
  ip="${SYS_PUBLIC_IPV4:-}"
  [[ -n "$ip" ]] || { MAIL_LAST_ERROR="the public IPv4 address of this server is unknown"; return 1; }
  ptr="$(dig +short -x "$ip" 2>/dev/null | head -n 1 | sed 's/\.$//' || true)"
  [[ -n "$ptr" ]] || { MAIL_LAST_ERROR="${ip} has no PTR record; set it to ${host} in your provider's panel"; return 1; }
  if [[ "${ptr,,}" != "${host,,}" ]]; then
    MAIL_LAST_ERROR="${ip} says it is ${ptr}, not ${host}; set the PTR record to ${host} in your provider's panel"
    return 1
  fi
  fwd="$(lib_resolve A "$host" | tr '\n' ' ')"
  if [[ " $fwd " != *" ${ip} "* ]]; then
    MAIL_LAST_ERROR="${host} does not resolve to ${ip} (found: ${fwd:-nothing}); add an A record for ${host}"
    return 1
  fi
  return 0
}

lib_mail_test_report() {   # [brief]
  local brief="${1:-}" host="" p25="" s=""
  host="$(lib_mail_host)"
  if [[ -z "$host" ]]; then lib_warn "Mail is not installed yet (lomp install --with-mail)"; return 1; fi
  if [[ -z "$brief" ]]; then
    lib_heading "Mail"
    lib_print_kv "Sends mail as" "$host"
    while read -r s; do
      [[ -n "$s" ]] || continue
      lib_service_exists "$s" || continue
      if lib_service_active "$s"; then lib_print_kv "$s" "running"; else lib_print_kv "$s" "STOPPED"; fi
    done < <(lib_mail_services)
  fi
  if lib_mail_ptr_check "$host"; then
    lib_ok "Reverse DNS agrees: ${host}"
  else
    lib_warn "Reverse DNS: ${MAIL_LAST_ERROR}"
  fi
  p25="$(lib_mail_port25_probe)"
  case "$p25" in
    open)    lib_ok "Outgoing port 25 is open" ;;
    blocked) lib_warn "Outgoing port 25 is blocked: this server cannot deliver mail directly"
             lib_note "Ask the provider to open it, or send through a relay:"
             lib_note "  printf '%s' \"\$PASS\" | lomp mail relay set --host smtp.example.net --user you@example.net" ;;
    *)       lib_note "Outgoing port 25 was not tested" ;;
  esac
  if [[ -n "$(lib_mail_relay_get host)" ]]; then
    lib_print_kv "Relay" "$(lib_mail_relay_get host):$(lib_mail_relay_get port) as $(lib_mail_relay_get user)"
  fi
  return 0
}

# =============================================================================
#  Relay
# =============================================================================
# Where port 25 is blocked, outgoing mail goes through somebody else's server. The password
# reaches Postfix through a 0600 map and is never an argument, so it stays out of the process
# list; the signature is still this server's own, because Rspamd signs before the handover.
lib_mail_relay_set() {   # host port user   (password on stdin)
  local rhost="$1" rport="${2:-587}" ruser="$3" pass=""
  lib_mail_hostname_valid "$rhost" || lib_die "Invalid relay host '${rhost:-none}'" "" "--host smtp.example.net"
  { [[ "$rport" =~ ^[0-9]{1,5}$ ]] && (( rport >= 1 && rport <= 65535 )); } \
    || lib_die "Invalid relay port '${rport}'" "" "--port 587"
  # the user name becomes a key in the credential map, where a space or a colon would split
  # the entry and SASL would fail with nothing in the log to explain it
  [[ "$ruser" =~ ^[A-Za-z0-9._%+@-]{1,128}$ ]] \
    || lib_die "Invalid relay user '${ruser:-none}'" \
       "the name may hold letters, digits and . _ % + @ - only" "--user you@example.net"
  IFS= read -r pass || true
  [[ -n "$pass" ]] || lib_die "No relay password on standard input" \
    "the password is read from stdin so it never appears in the process list" \
    "printf '%s' \"\$PASS\" | lomp mail relay set --host smtp.example.net --user you@example.net"
  if (( OPT_DRY_RUN )); then
    lib_info "[dry-run] would send outgoing mail through ${rhost}:${rport} as ${ruser}"
    return 0
  fi
  lib_mkdir "$MAIL_POSTFIX_DIR" 0750 root:postfix
  printf '[%s]:%s %s:%s\n' "$rhost" "$rport" "$ruser" "$pass" | lib_write_file "$MAIL_SASL_MAP" 0600 root:root secret
  lib_mail_postmap "$MAIL_SASL_MAP" || lib_die "postmap failed for ${MAIL_SASL_MAP}" "" "check ${LOG_FILE}"
  chmod 0600 "${MAIL_SASL_MAP}.db" 2>/dev/null || true
  chmod 0600 "${MAIL_SASL_MAP}.lmdb" 2>/dev/null || true
  lib_mkdir "$MAIL_STATE_DIR" 0700 root:root
  printf 'HOST=%s\nPORT=%s\nUSER=%s\nAT=%s\n' "$rhost" "$rport" "$ruser" "$(lib_iso_now)" \
    | lib_write_file "$MAIL_RELAY_INFO" 0600 root:root
  if ! lib_mail_apply "$(lib_mail_host)"; then
    lib_die "The relay could not be put into effect" "${MAIL_LAST_ERROR}" "lomp mail status"
  fi
  lib_manifest_set_json '.mail.relay' "$(jq -n --arg h "$rhost" --arg p "$rport" --arg u "$ruser" '{host:$h, port:$p, user:$u}')"
  lib_ok "Outgoing mail now goes through ${rhost}:${rport} as ${ruser}"
}

lib_mail_relay_off() {
  if [[ ! -s "$MAIL_RELAY_INFO" ]]; then lib_info "No relay is configured"; return 0; fi
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would send mail directly again"; return 0; fi
  lib_rm "$MAIL_RELAY_INFO" "$MAIL_SASL_MAP" "${MAIL_SASL_MAP}.db" "${MAIL_SASL_MAP}.lmdb"
  if ! lib_mail_apply "$(lib_mail_host)"; then
    lib_die "The relay could not be removed" "${MAIL_LAST_ERROR}" "lomp mail status"
  fi
  lib_json_set "$STATE_DIR/manifest.json" 'del(.mail.relay)'
  lib_ok "Outgoing mail goes directly again"
}


# =============================================================================
#  A domain of its own: mailboxes, aliases, DKIM, its certificate
# =============================================================================
# Everything below works the same way: the state is the mailbox file, the alias files and
# domain.json, and every table Postfix, Dovecot and Rspamd read is RENDERED from that state,
# whole, every time. Nothing is patched line by line. That is what keeps two entries for the
# same address out of the tables - postmap keeps the first of a duplicate pair and only warns,
# so an address that is both a mailbox and an alias target would silently lose half its rights.

MAIL_ALIAS_DIR="${MAIL_ALIAS_DIR:-${MAIL_STATE_DIR}/aliases}"
MAIL_DISABLED_DIR="${MAIL_DISABLED_DIR:-${MAIL_STATE_DIR}/disabled}"

# Does this domain still have mail on this server, whatever domain.json says? A mailbox line
# is a live login on its own - Dovecot's user store has no per-domain switch - so "is mail
# enabled" is the wrong question to ask before taking things away.
lib_mail_domain_has_traces() {   # domain
  local d="$1"
  [[ -n "$(lib_mail_boxes "$d")" ]] && return 0
  [[ -s "$(lib_mail_alias_file "$d")" ]] && return 0
  [[ -s "${MAIL_DISABLED_DIR}/${d}.passwd" ]] && return 0
  [[ -d "${MAIL_VMAIL_HOME}/${d}" ]] && return 0
  compgen -G "${MAIL_DKIM_DIR}/${d}.*.key" >/dev/null 2>&1 && return 0
  # a webmail is a trace too: its virtual host would otherwise outlive the site it belongs to,
  # naming a certificate that has just been deleted
  [[ -d "${LSWS_VHOSTS_DIR}/$(lib_webmail_vhost_name "$d")" ]] && return 0
  return 1
}

lib_mail_domain_enabled() { [[ "$(lib_json_get "$(lib_domain_json "$1")" '.mail.enabled')" == "true" ]]; }

# Every domain whose mail is on, in a stable order.
lib_mail_domains() {
  local d=""
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_mail_domain_enabled "$d" && printf '%s\n' "$d"
  done < <(lib_domains_list)
  return 0
}

# The DKIM selector of a domain: whatever it was signed with, or a new dated one.
lib_mail_selector() {
  local d="$1" s=""
  s="$(lib_json_get "$(lib_domain_json "$d")" '.mail.selector')"
  printf '%s' "${s:-lomp$(date -u +%Y%m)}"
}

lib_mail_alias_file() { printf '%s/%s' "$MAIL_ALIAS_DIR" "$1"; }

# Mailbox addresses of one domain (or all), read from the one file that holds them.
lib_mail_boxes() {   # [domain]
  local d="${1:-}"
  [[ -s "$MAIL_PASSWD_FILE" ]] || return 0
  # compared, not matched: a domain is not a regular expression, and awk would read the dots
  # in it as "any character" (and warn about the @)
  if [[ -n "$d" ]]; then
    awk -F: -v d="$d" 'index($1, "@") > 0 && substr($1, index($1, "@") + 1) == d {print $1}' "$MAIL_PASSWD_FILE" || true
  else
    awk -F: 'index($1, "@") > 0 {print $1}' "$MAIL_PASSWD_FILE" || true
  fi
}

lib_mail_box_exists() { lib_mail_boxes | grep -qxF "${1,,}"; }

lib_mail_box_quota() {   # address -> the quota rule's size, or the default
  local a="${1,,}" v=""
  [[ -s "$MAIL_PASSWD_FILE" ]] || { printf '%s' "$MAIL_QUOTA_DEFAULT"; return 0; }
  # not field 8: the rule itself carries a colon (storage=...), so the size sits in field 9
  v="$(awk -F: -v u="$a" '$1 == u' "$MAIL_PASSWD_FILE" | sed -n 's/.*storage=\([^ :]*\).*/\1/p' | head -1 || true)"
  printf '%s' "${v:-$MAIL_QUOTA_DEFAULT}"
}

# =============================================================================
#  Passwords
# =============================================================================
# doveadm reads the password from standard input, twice - and when the two reads do not match
# it does not fail: it loops, reads end-of-file twice, and hashes the EMPTY password with a
# zero exit status. A carriage return is enough to de-synchronise it. So the password is
# checked first, and the hash is checked afterwards against the password it should match.
lib_mail_hash_password() {   # password -> hash on stdout
  local pw="$1" hash="" bytes=0
  [[ -n "$pw" ]] || { MAIL_LAST_ERROR="the password is empty"; return 1; }
  if [[ "$pw" == *$'\n'* || "$pw" == *$'\r'* ]]; then
    MAIL_LAST_ERROR="the password may not contain a line break"
    return 1
  fi
  bytes="$(printf '%s' "$pw" | wc -c | tr -d ' ')"
  if (( bytes < 8 )); then MAIL_LAST_ERROR="the password is shorter than 8 characters"; return 1; fi
  if (( bytes > 72 )); then MAIL_LAST_ERROR="bcrypt ignores everything past 72 bytes; use a shorter password"; return 1; fi
  lib_have doveadm || { MAIL_LAST_ERROR="doveadm is missing (is Dovecot installed?)"; return 1; }
  hash="$(printf '%s\n%s\n' "$pw" "$pw" | doveadm pw -s BLF-CRYPT 2>/dev/null || true)"
  [[ "$hash" == '{BLF-CRYPT}'* ]] || { MAIL_LAST_ERROR="doveadm could not hash the password"; return 1; }
  # the hash of an empty password verifies against an empty password, not against this one
  printf '%s\n' "$pw" | doveadm pw -t "$hash" >/dev/null 2>&1 \
    || { MAIL_LAST_ERROR="the hash doveadm produced does not match the password given"; return 1; }
  printf '%s' "$hash"
}

# Read a password from stdin when it is a pipe, or ask for it twice without echo.
lib_mail_read_password() {   # -> password on stdout
  local p1="" p2=""
  if [[ ! -t 0 ]]; then
    IFS= read -r p1 || true
    printf '%s' "$p1"
    return 0
  fi
  read -r -s -p "Password: " p1 </dev/tty >/dev/tty 2>&1 || true
  printf '\n' >/dev/tty
  read -r -s -p "Again: " p2 </dev/tty >/dev/tty 2>&1 || true
  printf '\n' >/dev/tty
  [[ "$p1" == "$p2" ]] || { MAIL_LAST_ERROR="the two passwords did not match"; return 1; }
  printf '%s' "$p1"
}

# =============================================================================
#  The generated tables
# =============================================================================
# One line per domain. The value is required and never read, so it says what it is.
lib_mail_render_vdomains() {
  local d=""
  printf '# Managed by lompstack - the domains this server takes mail for\n'
  while read -r d; do [[ -n "$d" ]] && printf '%s\tvirtual\n' "$d"; done < <(lib_mail_domains)
  return 0
}

# Every mailbox that belongs to a domain whose mail is on. Postfix never uses the value as a
# path here - Dovecot's LMTP decides where the mail goes - but it says what it would be.
lib_mail_render_vmailbox() {
  local d="" a=""
  printf '# Managed by lompstack - every mailbox on this server\n'
  while read -r d; do
    [[ -n "$d" ]] || continue
    while read -r a; do
      [[ -n "$a" ]] || continue
      printf '%s\t%s/%s/Maildir/\n' "$a" "$d" "${a%%@*}"
    done < <(lib_mail_boxes "$d")
  done < <(lib_mail_domains)
  return 0
}

lib_mail_render_valias() {
  local d="" f=""
  printf '# Managed by lompstack - aliases and forwards\n'
  while read -r d; do
    [[ -n "$d" ]] || continue
    f="$(lib_mail_alias_file "$d")"
    [[ -s "$f" ]] || continue
    grep -v '^[[:space:]]*#' "$f" | grep -v '^[[:space:]]*$' || true
  done < <(lib_mail_domains)
  return 0
}

# Which login may send as which address. One line per address, with every owner on it:
# postmap keeps the FIRST of two lines with the same key and only warns, so an address that
# is both a mailbox and an alias target would otherwise lose one of its owners.
lib_mail_render_senders() {
  local d="" a="" f="" alias="" targets="" t=""
  {
    while read -r d; do
      [[ -n "$d" ]] || continue
      while read -r a; do
        [[ -n "$a" ]] && printf '%s\t%s\n' "$a" "$a"
      done < <(lib_mail_boxes "$d")
      f="$(lib_mail_alias_file "$d")"
      [[ -s "$f" ]] || continue
      # an alias may be used as a sender by each LOCAL mailbox it points at. An address
      # somewhere else is not a login here and must not become one.
      while IFS=$'\t' read -r alias targets; do
        [[ -n "$alias" && "$alias" != \#* && -n "$targets" ]] || continue
        for t in ${targets//,/ }; do
          lib_mail_box_exists "$t" && printf '%s\t%s\n' "$alias" "$t"
        done
      done <"$f"
    done < <(lib_mail_domains)
  } | awk -F'\t' -v OFS='\t' '
      NF == 2 && $2 != "" {
        if (!($1 in seen)) { order[++n] = $1; seen[$1] = $2; next }
        if (index("," seen[$1] ",", "," $2 ",") == 0) seen[$1] = seen[$1] "," $2
      }
      END {
        print "# Managed by lompstack - which login may send as which address"
        for (i = 1; i <= n; i++) print order[i], seen[order[i]]
      }'
  return 0
}

# The certificate each mail name gets. The private key is named FIRST - the other way round
# postmap accepts the line and the handshake then dies with an alert instead of falling back.
lib_mail_render_sni() {
  local d="" ident="" dir="" host=""
  printf '# Managed by lompstack - per-name certificates (postmap -F copies the files in)\n'
  host="$(lib_mail_host)"
  if [[ -n "$host" && -s "${SSL_DEPLOY_DIR}/${MAIL_CERT_NAME}/privkey.pem" ]]; then
    printf '%s\t%s/%s/privkey.pem, %s/%s/fullchain.pem\n' "$host" "$SSL_DEPLOY_DIR" "$MAIL_CERT_NAME" "$SSL_DEPLOY_DIR" "$MAIL_CERT_NAME"
  fi
  while read -r d; do
    [[ -n "$d" ]] || continue
    ident="$(lib_mail_cert_name "$d")"
    dir="${SSL_DEPLOY_DIR}/${ident}"
    [[ -s "${dir}/privkey.pem" && -s "${dir}/fullchain.pem" ]] || continue
    printf 'mail.%s\t%s/privkey.pem, %s/fullchain.pem\n' "$d" "$dir" "$dir"
  done < <(lib_mail_domains)
  return 0
}

# The same names on the IMAP side. A block whose files are missing is a silent failure -
# doveconf says nothing and the name quietly falls back to the mail host's certificate - so
# only names whose certificate is really there get a block.
lib_mail_render_dovecot_sni() {
  local d="" ident="" dir=""
  printf '# Managed by lompstack - per-name certificates for IMAP\n'
  while read -r d; do
    [[ -n "$d" ]] || continue
    ident="$(lib_mail_cert_name "$d")"
    dir="${SSL_DEPLOY_DIR}/${ident}"
    [[ -s "${dir}/privkey.pem" && -s "${dir}/fullchain.pem" ]] || continue
    printf 'local_name "mail.%s" {\n  ssl_cert = <%s/fullchain.pem\n  ssl_key = <%s/privkey.pem\n}\n' "$d" "$dir" "$dir"
  done < <(lib_mail_domains)
  return 0
}

lib_mail_render_selectors() {
  local d=""
  printf '# Managed by lompstack - "<domain> <selector>", one line per domain with mail\n'
  while read -r d; do
    [[ -n "$d" ]] || continue
    [[ -s "${MAIL_DKIM_DIR}/${d}.$(lib_mail_selector "$d").key" ]] || continue
    printf '%s %s\n' "$d" "$(lib_mail_selector "$d")"
  done < <(lib_mail_domains)
  return 0
}

# =============================================================================
#  Putting the tables into effect
# =============================================================================
# Written, rebuilt and - where the daemon that reads them is a long-lived one - reloaded.
# virtual_mailbox_domains is read by trivial-rewrite, which qmgr keeps a connection to for
# ever, so a new domain is not taken in until Postfix is told; the rest are read by smtpd and
# cleanup, which are replaced every few connections.
lib_mail_tables_apply() {
  local changed=0 reload=0
  lib_mkdir "$MAIL_POSTFIX_DIR" 0750 root:postfix
  lib_mkdir "$MAIL_ALIAS_DIR" 0700 root:root

  lib_mail_render_vdomains | lib_write_file "${MAIL_POSTFIX_DIR}/vdomains" 0640 root:postfix
  (( LIB_FILE_CHANGED )) && { changed=1; reload=1; }
  lib_mail_render_vmailbox | lib_write_file "${MAIL_POSTFIX_DIR}/vmailbox" 0640 root:postfix
  (( LIB_FILE_CHANGED )) && changed=1
  lib_mail_render_valias | lib_write_file "${MAIL_POSTFIX_DIR}/valias" 0640 root:postfix
  (( LIB_FILE_CHANGED )) && changed=1
  lib_mail_render_senders | lib_write_file "${MAIL_POSTFIX_DIR}/senders" 0640 root:postfix
  (( LIB_FILE_CHANGED )) && changed=1
  lib_mail_render_sni | lib_write_file "$MAIL_SNI_MAP" 0600 root:root secret
  (( LIB_FILE_CHANGED )) && { changed=1; reload=1; }

  local f=""
  for f in vdomains vmailbox valias senders; do
    lib_mail_postmap "${MAIL_POSTFIX_DIR}/${f}" || return 1
  done
  # always rebuilt: postmap -F copies the certificates INTO the table, so a renewal changes
  # what the table should hold without touching the file it is built from
  lib_mail_postmap "$MAIL_SNI_MAP" -F force || return 1

  lib_mail_render_selectors | lib_write_file "${MAIL_RSPAMD_LOMP}/dkim_selectors.map" 0644 root:root
  (( LIB_FILE_CHANGED )) && changed=1      # Rspamd watches this file; no reload needed

  lib_mail_dovecot_sni_apply || return 1

  if (( reload )) && (( ! OPT_DRY_RUN )) && lib_service_active postfix; then
    lib_run postfix reload || lib_warn "postfix reload failed (see log)"
  fi
  (( changed )) && lib_log_write INFO "mail tables rebuilt"
  return 0
}

# Dovecot is the one that has to be handled carefully: a syntax error here makes "systemctl
# reload dovecot" exit non-zero, and systemd then stops the unit - the mail server goes down
# because of a certificate block. So the file is tested before anything is reloaded, and put
# back if the test fails.
lib_mail_dovecot_sni_apply() {
  local f="${MAIL_DOVECOT_DIR}/sni.conf" bak=""
  lib_mkdir "$MAIL_DOVECOT_DIR" 0750 root:dovecot
  if (( OPT_DRY_RUN )); then
    lib_mail_render_dovecot_sni | lib_write_file "$f" 0640 root:dovecot
    return 0
  fi
  [[ -f "$f" ]] && bak="$(lib_backup_config "$f")"
  lib_mail_render_dovecot_sni | lib_write_file "$f" 0640 root:dovecot
  (( LIB_FILE_CHANGED )) || return 0
  if lib_have doveconf && ! doveconf -n >/dev/null 2>&1; then
    if [[ -n "$bak" ]]; then cp -p "$bak" "$f"; else lib_rm "$f"; fi
    MAIL_LAST_ERROR="Dovecot refused the per-name certificate file; it was put back"
    return 1
  fi
  lib_service_active dovecot && { lib_run doveadm reload || lib_warn "dovecot reload failed (see log)"; }
  return 0
}

# =============================================================================
#  DKIM
# =============================================================================
# One key per domain, generated once. rspamadm exits 0 even when it could not write the key
# and prints the public record anyway, so the file is what gets trusted, not the exit status.
lib_mail_dkim_ensure() {   # domain
  local d="$1" sel="" key="" tmp=""
  sel="$(lib_mail_selector "$d")"
  key="${MAIL_DKIM_DIR}/${d}.${sel}.key"
  [[ -s "$key" ]] && return 0
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would create a DKIM key for ${d} (selector ${sel})"; return 0; fi
  lib_have rspamadm || { MAIL_LAST_ERROR="rspamadm is missing (is Rspamd installed?)"; return 1; }
  lib_mkdir "$MAIL_DKIM_DIR" 0750 root:_rspamd
  tmp="$(mktemp "${MAIL_DKIM_DIR}/.${d}.XXXXXX")" || { MAIL_LAST_ERROR="could not create a temporary file for the DKIM key"; return 1; }
  if ! rspamadm dkim_keygen -d "$d" -s "$sel" -b 2048 -t rsa -k "$tmp" -o dnskey >/dev/null 2>&1 \
     || [[ ! -s "$tmp" ]] || ! openssl rsa -in "$tmp" -noout -check >/dev/null 2>&1; then
    rm -f "$tmp"
    MAIL_LAST_ERROR="rspamadm could not generate a DKIM key for ${d}"
    return 1
  fi
  chown root:_rspamd "$tmp" 2>/dev/null || true
  chmod 0640 "$tmp"
  mv -f "$tmp" "$key"
  lib_ok "DKIM key for ${d} (selector ${sel})"
  return 0
}

# The public half, read from the private key rather than generated again: generating again
# would quietly replace a key whose public half is already published, and every message signed
# from then on would fail DKIM with nothing on this server to show for it.
lib_mail_dkim_public() {   # domain -> "v=DKIM1; k=rsa; p=..."
  local d="$1" key="" p=""
  key="${MAIL_DKIM_DIR}/${d}.$(lib_mail_selector "$d").key"
  [[ -s "$key" ]] || return 1
  p="$(openssl rsa -in "$key" -pubout 2>/dev/null | grep -v -- '-----' | tr -d '\n' || true)"
  [[ -n "$p" ]] || return 1
  printf 'v=DKIM1; k=rsa; p=%s' "$p"
}

# =============================================================================
#  The certificate of one domain's mail name
# =============================================================================
lib_mail_domain_cert_ensure() {   # domain
  local d="$1" cert="" name=""
  local -a names=()
  cert="$(lib_mail_cert_name "$d")"
  name="mail.${d}"
  names=("$name")
  # one lineage for every name this domain's mail answers to, the webmail included: two
  # certificates would mean two things to renew and two ways for one of them to expire
  [[ "$(lib_json_get "$(lib_domain_json "$d")" '.mail.webmail')" == "true" ]] && names+=("$(lib_webmail_host "$d")")
  # what the lineage COVERS, not merely that it exists: a webmail switched on later needs its
  # name added, and "the file is there" would answer yes for ever without it
  if lib_ssl_cert_covers "$cert" "${names[@]}"; then
    lib_ssl_deploy_files "$cert" || lib_warn "certificate ${cert} could not be deployed: ${SSL_LAST_ERROR}"
    lib_cron_remove "mail-cert:${d}"
    return 0
  fi
  if lib_ssl_obtain_names "$cert" "${names[@]}"; then
    lib_cron_remove "mail-cert:${d}"
    return 0
  fi
  lib_warn "No certificate for ${names[*]} yet: ${SSL_LAST_ERROR}"
  lib_note "Clients reach it under ${MAIL_HOST_SHOWN:-$(lib_mail_host)} meanwhile, which is a name they can trust"
  lib_note "Every name above needs a record that points here - ${names[*]} - and then: lomp mail cert ${d}"
  lib_cron_set "mail-cert:${d}" "41 */6 * * * root ${BIN_LINK} mail cert ${d} --quiet"
  return 0
}

# =============================================================================
#  enable / disable
# =============================================================================
lib_mail_enable_main() {   # domain [--mailbox NAME] [--quota Q]
  local d="" box="" quota="$MAIL_QUOTA_DEFAULT" a="" _first_box=""
  d="${1:-}"; shift || true
  lib_domain_valid "${d,,}" || lib_die "Invalid domain '${d:-none}'" "" "lomp mail enable example.com"
  d="${d,,}"
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --mailbox) box="${1:-}"; shift || true ;;
      --quota)   quota="${1:-}"; shift || true ;;
      --yes)     OPT_YES=1 ;;
      *) lib_die "Unknown option for 'mail enable': ${a}" "" "lomp mail help" ;;
    esac
  done
  # not in a dry run: the site it belongs to was only planned, never written
  if (( ! OPT_DRY_RUN )); then
    lib_domain_registered "$d" || lib_die "No site called ${d} on this server" \
      "mail is enabled for a site this server already hosts" "lomp add ${d}"
  fi
  lib_mail_quota_valid "$quota" || lib_die "Invalid quota '${quota}'" "a size with a unit, or 0 for no limit" "--quota 2G"
  [[ -z "$box" ]] || lib_mail_local_valid "$box" || lib_die "Invalid mailbox name '${box}'" "" "--mailbox info"
  lib_mail_installed || lib_mail_ensure || lib_die "Mail is not installed" "${MAIL_LAST_ERROR}" "lomp install --with-mail"

  lib_info "Turning on mail for ${d}"
  lib_mail_dkim_ensure "$d" || lib_die "The DKIM key could not be created" "${MAIL_LAST_ERROR}" "lomp mail status"
  if (( ! OPT_DRY_RUN )); then
    lib_json_set "$(lib_domain_json "$d")" \
      '.mail.enabled = true | .mail.host = $h | .mail.selector = $s | .mail.quota_default = $q | .mail.enabled_at = $ts' \
      --arg h "mail.${d}" --arg s "$(lib_mail_selector "$d")" --arg q "$quota" --arg ts "$(lib_iso_now)"
  fi
  # mailboxes that were put aside when mail was turned off come back with their passwords
  lib_mail_boxes_unpark "$d"
  if [[ -n "$box" ]]; then
    lib_mail_box_add_main "${box}@${d}" --quota "$quota"
  else
    # postmaster, abuse and dmarc point at the first mailbox there is; with none, they are
    # left for the first "mail box add" to set, because an alias to nowhere bounces
    _first_box="$(lib_mail_boxes "$d" | head -1)"
    [[ -n "$_first_box" ]] && lib_mail_domain_aliases_seed "$d" "$_first_box"
    lib_mail_tables_apply || lib_die "The mail tables could not be rebuilt" "${MAIL_LAST_ERROR}" "lomp mail status"
  fi
  lib_mail_domain_cert_ensure "$d"
  lib_mail_tables_apply || true          # the certificate may have arrived in the meantime
  lib_ok "Mail is on for ${d}"
  if [[ -z "$(lib_mail_boxes "$d")" ]]; then
    lib_warn "There is no mailbox yet, so every message to @${d} is refused"
    lib_note "Make one: lomp mail box add info@${d}"
  fi
  # with a token stored, the records go in by themselves - that is what the token is for -
  # and anything lompstack refuses to touch is printed for the operator
  if [[ -n "$(lib_cf_token)" ]]; then
    lib_mail_dns_apply "$d" || lib_mail_dns_print "$d"
  else
    lib_mail_dns_print "$d"
  fi
  return 0
}

lib_mail_disable_main() {   # domain [--keep-data|--delete-data] [--dns-cleanup]
  local d="" keep=1 cleanup=0 a=""
  d="${1:-}"; shift || true
  [[ -n "$d" ]] || lib_die "Which domain?" "" "lomp mail disable example.com"
  d="${d,,}"
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --keep-data) keep=1 ;;
      --delete-data) keep=0 ;;
      --dns-cleanup) cleanup=1 ;;
      --yes) OPT_YES=1 ;;
      *) lib_die "Unknown option for 'mail disable': ${a}" "" "lomp mail help" ;;
    esac
  done
  lib_mail_domain_enabled "$d" || { lib_info "Mail is already off for ${d}"; return 0; }
  if (( keep )); then
    lib_info "Turning mail off for ${d}; the mailboxes and their mail stay where they are"
  else
    lib_confirm "Delete every mailbox of ${d} and all of its mail?" n \
      || lib_die "Nothing was deleted" "" "run it without --delete-data to keep the mail"
  fi
  if (( ! OPT_DRY_RUN )); then
    lib_json_set "$(lib_domain_json "$d")" '.mail.enabled = false | .mail.disabled_at = $ts' --arg ts "$(lib_iso_now)"
  fi
  # anything still queued for this domain stops being a local destination the moment the table
  # is rewritten, and Postfix would try to deliver it to the internet instead
  _mail_warn_queued "$d"
  lib_cron_remove "mail-cert:${d}"
  # Only the records lompstack wrote, and only when asked: somebody else may be pointing that
  # name somewhere on purpose. This runs BEFORE the webmail is switched off, because the list
  # of records to remove is built from the state - and the webmail's own record is in it only
  # while the state still says there is a webmail.
  (( cleanup )) && lib_mail_dns_cleanup "$d"
  # the webmail is a way in to these mailboxes, so it goes with them
  lib_webmail_domain_disable "$d"
  if (( keep )); then
    # the mailbox lines are put aside, not left in place: Dovecot's user store has no
    # per-domain switch, so a line that stays is a login that still works. They come back
    # with their passwords when the domain is enabled again.
    lib_mail_boxes_park "$d"
  else
    lib_mail_domain_purge "$d"
  fi
  lib_mail_tables_apply || lib_die "The mail tables could not be rebuilt" "${MAIL_LAST_ERROR}" "lomp mail status"
  if (( keep )); then
    lib_ok "Mail is off for ${d}: no login and no delivery, and every message is still on disk"
    lib_note "\"lomp mail enable ${d}\" brings the mailboxes back with the passwords they had"
  else
    lib_ok "Mail is off for ${d} and its mailboxes are gone"
  fi
  return 0
}

# Move a domain's mailbox lines out of the live user store and into the state directory, and
# back again. What is parked keeps its password hash and its quota.
lib_mail_boxes_park() {   # domain
  local d="$1" f="" n=0 a=""
  f="${MAIL_DISABLED_DIR}/${d}.passwd"
  [[ -s "$MAIL_PASSWD_FILE" ]] || return 0
  n="$(lib_mail_boxes "$d" | wc -l | tr -d ' ')"
  (( n > 0 )) || return 0
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would put ${n} mailbox line(s) of ${d} aside"; return 0; fi
  lib_mkdir "$MAIL_DISABLED_DIR" 0700 root:root
  awk -F: -v d="$d" 'index($1, "@") > 0 && substr($1, index($1, "@") + 1) == d' "$MAIL_PASSWD_FILE" \
    | lib_write_file "$f" 0600 root:root secret
  awk -F: -v d="$d" '!(index($1, "@") > 0 && substr($1, index($1, "@") + 1) == d)' "$MAIL_PASSWD_FILE" \
    | lib_write_file "$MAIL_PASSWD_FILE" 0640 root:dovecot secret
  if lib_have doveadm && (( ! OPT_DRY_RUN )); then
    sleep 1
    # 68 is "nobody was logged in", which is the usual answer and not a failure
    while read -r a; do
      [[ -n "$a" ]] || continue
      doveadm kick "$a" >/dev/null 2>&1 || true
    done < <(awk -F: '{print $1}' "$f")
  fi
  return 0
}

lib_mail_boxes_unpark() {   # domain
  local d="$1" f="" tmp=""
  f="${MAIL_DISABLED_DIR}/${d}.passwd"
  [[ -s "$f" ]] || return 0
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would bring the mailboxes of ${d} back"; return 0; fi
  tmp="$(lib_mktemp)"
  { [[ -s "$MAIL_PASSWD_FILE" ]] && cat "$MAIL_PASSWD_FILE"; grep -v '^[[:space:]]*#' "$f"; } \
    | awk -F: '!seen[$1]++' | sort -t: -k1,1 >"$tmp"
  lib_write_file "$MAIL_PASSWD_FILE" 0640 root:dovecot secret <"$tmp"
  rm -f "$tmp"
  lib_rm "$f"
  return 0
}

# Mail still waiting to go out to a domain that is about to stop being one of ours.
_mail_warn_queued() {   # domain
  local n=0
  lib_have postqueue || return 0
  (( OPT_DRY_RUN )) && return 0
  n="$(postqueue -p 2>/dev/null | grep -c "@${1}$" || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  (( n > 0 )) && lib_warn "${n} message(s) for ${1} are still in the queue; they will be treated as mail for somewhere else now (lomp mail queue)"
  return 0
}

# Everything that belongs to one domain's mail, for "disable --delete-data" and for "remove".
lib_mail_domain_purge() {   # domain
  local d="$1" a="" sel=""
  sel="$(lib_mail_selector "$d")"
  # the webmail first: its vhost names a certificate that is about to be deleted
  lib_webmail_domain_disable "$d"
  while read -r a; do
    [[ -n "$a" ]] && lib_mail_box_remove "$a"
  done < <(lib_mail_boxes "$d")
  lib_rm "$(lib_mail_alias_file "$d")"
  lib_rm "${MAIL_DKIM_DIR}/${d}.${sel}.key"
  lib_rm "${MAIL_VMAIL_HOME}/${d}"
  lib_cron_remove "mail-cert:${d}"
  lib_ssl_delete "$(lib_mail_cert_name "$d")" 2>/dev/null || true
  return 0
}

# =============================================================================
#  Mailboxes
# =============================================================================
# The file is rewritten whole, with this address's line replaced: Dovecot keeps the FIRST of
# two lines with the same key, so a second line for the same mailbox would be a password
# nobody can use and a quota nobody sees.
lib_mail_passwd_set() {   # address hash quota
  local a="${1,,}" hash="$2" quota="$3" tmp=""
  tmp="$(lib_mktemp)"
  {
    [[ -s "$MAIL_PASSWD_FILE" ]] && awk -F: -v u="$a" '$1 != u' "$MAIL_PASSWD_FILE"
    printf '%s:%s::::::userdb_quota_rule=*:storage=%s\n' "$a" "$hash" "$quota"
  } | sort -t: -k1,1 >"$tmp"
  lib_write_file "$MAIL_PASSWD_FILE" 0640 root:dovecot secret <"$tmp"
  rm -f "$tmp"
  return 0
}

# Read a password and hash it, both in this shell so that a refusal can say why. The hash comes
# back in MAIL_HASH; the password itself is never assigned to anything that outlives the call.
MAIL_HASH=""
_mail_ask_password() {   # what (for the message only)
  local f="" rc=0
  MAIL_HASH=""
  f="$(lib_mktemp)"
  if ! lib_mail_read_password >"$f"; then rm -f "$f"; return 1; fi
  if ! lib_mail_hash_password "$(cat "$f")" >"${f}.h"; then rm -f "$f" "${f}.h"; return 1; fi
  MAIL_HASH="$(cat "${f}.h")"
  rm -f "$f" "${f}.h"
  [[ -n "$MAIL_HASH" ]] || { MAIL_LAST_ERROR="the password could not be hashed"; rc=1; }
  return "$rc"
}

lib_mail_box_add_main() {   # address [--quota Q]   (password on stdin or asked for)
  local a="" quota="" pw="" hash="" d="" opt=""
  a="${1:-}"; shift || true
  a="${a,,}"
  lib_mail_address_valid "$a" || lib_die "Invalid address '${a:-none}'" "" "lomp mail box add info@example.com"
  d="${a#*@}"
  while (($# > 0)); do
    opt="$1"; shift
    case "$opt" in
      --quota) quota="${1:-}"; shift || true ;;
      *) lib_die "Unknown option for 'mail box add': ${opt}" "" "lomp mail help" ;;
    esac
  done
  # in a dry run the domain was only planned, so its state does not say "enabled" yet
  if (( ! OPT_DRY_RUN )); then
    lib_mail_domain_enabled "$d" || lib_die "Mail is not on for ${d}" "" "lomp mail enable ${d}"
  fi
  [[ -n "$quota" ]] || quota="$(lib_json_get "$(lib_domain_json "$d")" '.mail.quota_default')"
  [[ -n "$quota" ]] || quota="$MAIL_QUOTA_DEFAULT"
  lib_mail_quota_valid "$quota" || lib_die "Invalid quota '${quota}'" "a bad value makes every delivery to this mailbox fail" "--quota 2G"
  if lib_mail_box_exists "$a"; then lib_die "${a} already exists" "" "lomp mail box passwd ${a}"; fi
  # the mirror of the check in "alias add": one address, one meaning. Postfix resolves the
  # alias first, so a mailbox of the same name would never see a message.
  if [[ -s "$(lib_mail_alias_file "$d")" ]] && awk -F'	' -v k="$a" '$1 == k {found=1} END{exit !found}' "$(lib_mail_alias_file "$d")"; then
    lib_die "${a} is already an alias" "an address is either a mailbox or an alias, never both" "lomp mail alias del ${a}"
  fi

  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would create the mailbox ${a} (${quota})"; return 0; fi
  # not "pw=$(lib_mail_read_password)": the helpers set MAIL_LAST_ERROR, and a command
  # substitution is a subshell, so the reason for the refusal would die with it
  _mail_ask_password "add ${a}" || lib_die "The mailbox was not created" "${MAIL_LAST_ERROR}" "printf '%s' \"\$PW\" | lomp mail box add ${a}"
  hash="$MAIL_HASH"
  MAIL_HASH=""
  lib_mail_passwd_set "$a" "$hash" "$quota"
  lib_mail_domain_aliases_seed "$d" "$a"
  lib_mail_tables_apply || lib_die "The mail tables could not be rebuilt" "${MAIL_LAST_ERROR}" "lomp mail status"
  lib_ok "Mailbox ${a} created (${quota})"
  lib_note "IMAP ${MAIL_CLIENT_HOST:-$(lib_mail_host)}:993 (SSL/TLS), SMTP ${MAIL_CLIENT_HOST:-$(lib_mail_host)}:465 (SSL/TLS), user name ${a}"
  return 0
}

lib_mail_box_passwd_main() {   # address
  local a="${1:-}" pw="" hash=""
  a="${a,,}"
  lib_mail_address_valid "$a" || lib_die "Invalid address '${a:-none}'" "" "lomp mail box passwd info@example.com"
  lib_mail_box_exists "$a" || lib_die "No such mailbox: ${a}" "" "lomp mail box list"
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would change the password of ${a}"; return 0; fi
  _mail_ask_password "passwd ${a}" || lib_die "The password was not changed" "${MAIL_LAST_ERROR}" "printf '%s' \"\$PW\" | lomp mail box passwd ${a}"
  hash="$MAIL_HASH"
  MAIL_HASH=""
  lib_mail_passwd_set "$a" "$hash" "$(lib_mail_box_quota "$a")"
  lib_ok "Password changed for ${a}"
  lib_note "Open sessions stay open until they reconnect: lomp mail box kick ${a} closes them now"
  return 0
}

lib_mail_box_quota_main() {   # address quota
  local a="${1:-}" q="${2:-}" hash=""
  a="${a,,}"
  lib_mail_address_valid "$a" || lib_die "Invalid address '${a:-none}'" "" "lomp mail box quota info@example.com 2G"
  lib_mail_quota_valid "$q" || lib_die "Invalid quota '${q:-none}'" "a bad value makes every delivery to this mailbox fail" "2G, 500M, or 0 for no limit"
  lib_mail_box_exists "$a" || lib_die "No such mailbox: ${a}" "" "lomp mail box list"
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would set the quota of ${a} to ${q}"; return 0; fi
  hash="$(awk -F: -v u="$a" '$1 == u {print $2}' "$MAIL_PASSWD_FILE" | head -1 || true)"
  [[ -n "$hash" ]] || lib_die "Could not read the stored password of ${a}" "" "lomp mail box passwd ${a}"
  lib_mail_passwd_set "$a" "$hash" "$q"
  lib_ok "Quota of ${a} is now ${q}"
  return 0
}

# The line goes first: from that moment no new session can start. Only then is what is still
# open closed, and only then does the mail go - otherwise a client with a saved password
# reconnects in the gap and recreates the mailbox under the directory just deleted.
lib_mail_box_remove() {   # address   (no questions; the callers ask)
  local a="${1,,}" d="" loc=""
  d="${a#*@}"; loc="${a%%@*}"
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would delete the mailbox ${a} and its mail"; return 0; fi
  if [[ -s "$MAIL_PASSWD_FILE" ]]; then
    awk -F: -v u="$a" '$1 != u' "$MAIL_PASSWD_FILE" | lib_write_file "$MAIL_PASSWD_FILE" 0640 root:dovecot secret
  fi
  sleep 1                                  # Dovecot re-reads the file about once a second
  if lib_have doveadm; then doveadm kick "$a" >/dev/null 2>&1 || true; fi   # 68 = nobody was logged in
  lib_rm "${MAIL_VMAIL_HOME}/${d}/${loc}"
  return 0
}

lib_mail_box_del_main() {   # address
  local a="${1:-}"
  a="${a,,}"
  lib_mail_address_valid "$a" || lib_die "Invalid address '${a:-none}'" "" "lomp mail box del info@example.com"
  lib_mail_box_exists "$a" || lib_die "No such mailbox: ${a}" "" "lomp mail box list"
  lib_confirm "Delete ${a} and every message in it?" n || lib_die "Nothing was deleted" "" ""
  lib_mail_box_remove "$a"
  lib_mail_alias_forget_target "${a#*@}" "$a"
  lib_mail_tables_apply || lib_warn "the mail tables could not be rebuilt: ${MAIL_LAST_ERROR}"
  lib_ok "${a} is gone"
  return 0
}

# An alias pointing at a mailbox that no longer exists is worse than no alias: Postfix accepts
# the message and bounces it afterwards. So a deleted mailbox is taken out of every alias, and
# an alias left with nowhere to go is removed.
lib_mail_alias_forget_target() {   # domain address
  local d="$1" gone="$2" f="" tmp="" changed=0
  f="$(lib_mail_alias_file "$d")"
  [[ -s "$f" ]] || return 0
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would take ${gone} out of the aliases of ${d}"; return 0; fi
  tmp="$(lib_mktemp)"
  awk -F'	' -v gone="$gone" -v OFS='	' '
    /^[[:space:]]*#/ { print; next }
    NF < 2 { next }
    {
      n = split($2, t, ","); out = ""
      for (i = 1; i <= n; i++) if (t[i] != gone) out = (out == "" ? t[i] : out "," t[i])
      if (out != "") print $1, out
    }' "$f" >"$tmp"
  if ! cmp -s "$tmp" "$f"; then changed=1; fi
  lib_write_file "$f" 0600 root:root <"$tmp"
  rm -f "$tmp"
  (( changed )) && lib_note "Aliases that pointed at ${gone} were updated"
  return 0
}

# Close the sessions a mailbox still has open. A password change does not end them: IMAP
# clients stay connected until they reconnect by themselves.
lib_mail_box_kick_main() {   # address
  local a="${1:-}"
  a="${a,,}"
  lib_mail_address_valid "$a" || lib_die "Invalid address '${a:-none}'" "" "lomp mail box kick info@example.com"
  lib_have doveadm || lib_die "doveadm is missing (is Dovecot installed?)" "" "lomp install --with-mail"
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would close the open sessions of ${a}"; return 0; fi
  # 68 is "nobody was logged in", which is the usual answer and not a failure
  doveadm kick "$a" >/dev/null 2>&1 || true
  lib_ok "Any open session of ${a} is closed"
  return 0
}

lib_mail_box_list_main() {   # [domain]
  local d="${1:-}" a="" q="" used=""
  if (( OPT_JSON )); then
    {
      while read -r a; do
        [[ -n "$a" ]] || continue
        printf '{"address":"%s","domain":"%s","quota":"%s"}\n' "$a" "${a#*@}" "$(lib_mail_box_quota "$a")"
      done < <(lib_mail_boxes "$d")
    } | jq -s '.'
    return 0
  fi
  printf '  %-34s %-10s %s\n' "MAILBOX" "QUOTA" "USED"
  while read -r a; do
    [[ -n "$a" ]] || continue
    q="$(lib_mail_box_quota "$a")"
    used="-"
    if lib_have doveadm && (( ! OPT_DRY_RUN )); then
      used="$(doveadm -f tab quota get -u "$a" 2>/dev/null | awk -F'\t' '$2=="STORAGE"{print $3}' | head -1 || true)"
      [[ -n "$used" ]] && used="$(( used / 1024 )) MB"
    fi
    printf '  %-34s %-10s %s\n' "$a" "$q" "${used:--}"
  done < <(lib_mail_boxes "$d")
  return 0
}

# =============================================================================
#  Aliases
# =============================================================================
lib_mail_alias_set() {   # domain alias targets   (empty targets removes it)
  local d="$1" alias="${2,,}" targets="${3:-}" f="" tmp=""
  f="$(lib_mail_alias_file "$d")"
  lib_mkdir "$MAIL_ALIAS_DIR" 0700 root:root
  if (( OPT_DRY_RUN )); then
    if [[ -n "$targets" ]]; then lib_info "[dry-run] would point ${alias} at ${targets}"
    else lib_info "[dry-run] would remove the alias ${alias}"; fi
    return 0
  fi
  tmp="$(lib_mktemp)"
  {
    printf '# Managed by lompstack - aliases of %s\n' "$d"
    if [[ -s "$f" ]]; then awk -F'\t' -v a="$alias" '!/^[[:space:]]*#/ && NF >= 2 && $1 != a' "$f"; fi
    [[ -n "$targets" ]] && printf '%s\t%s\n' "$alias" "$targets"
  } >"$tmp"
  lib_write_file "$f" 0600 root:root <"$tmp"
  rm -f "$tmp"
  return 0
}

lib_mail_alias_add_main() {   # alias target[,target...]
  local alias="${1:-}" targets="${2:-}" d="" t=""
  alias="${alias,,}"
  lib_mail_address_valid "$alias" || lib_die "Invalid alias '${alias:-none}'" "" "lomp mail alias add sales@example.com info@example.com"
  [[ -n "$targets" ]] || lib_die "Where should ${alias} go?" "" "lomp mail alias add ${alias} info@example.com"
  d="${alias#*@}"
  lib_mail_domain_enabled "$d" || lib_die "Mail is not on for ${d}" "" "lomp mail enable ${d}"
  local clean=""
  for t in ${targets//,/ }; do
    lib_mail_address_valid "$t" || lib_die "Invalid target '${t}'" "" "an address, or several separated by commas"
    clean="${clean:+${clean},}${t}"
  done
  [[ -n "$clean" ]] || lib_die "Where should ${alias} go?" "" "lomp mail alias add ${alias} info@${d}"
  if lib_mail_box_exists "$alias"; then lib_die "${alias} is a mailbox, not an alias" "" "lomp mail box del ${alias} first"; fi
  # what is stored is what was checked, token by token: the string the operator typed may hold
  # a line break, and a second line in that file is an entry for a domain nobody checked
  lib_mail_alias_set "$d" "$alias" "$clean"
  lib_mail_tables_apply || lib_die "The mail tables could not be rebuilt" "${MAIL_LAST_ERROR}" "lomp mail status"
  lib_ok "${alias} now goes to ${targets}"
  return 0
}

lib_mail_alias_del_main() {   # alias
  local alias="${1:-}" d="" f=""
  alias="${alias,,}"
  lib_mail_address_valid "$alias" || lib_die "Invalid alias '${alias:-none}'" "" "lomp mail alias del sales@example.com"
  d="${alias#*@}"
  f="$(lib_mail_alias_file "$d")"
  if [[ ! -s "$f" ]] || ! awk -F'	' -v k="$alias" '$1 == k {found=1} END{exit !found}' "$f"; then
    lib_die "No such alias: ${alias}" "" "lomp mail alias list ${d}"
  fi
  lib_mail_alias_set "$d" "$alias" ""
  lib_mail_tables_apply || lib_warn "the mail tables could not be rebuilt: ${MAIL_LAST_ERROR}"
  lib_ok "${alias} is gone"
  return 0
}

lib_mail_alias_list_main() {   # [domain]
  local d="" f=""
  if (( OPT_JSON )); then
    {
      while read -r d; do
        [[ -n "$d" ]] || continue
        f="$(lib_mail_alias_file "$d")"
        [[ -s "$f" ]] || continue
        awk -F'\t' -v d="$d" '!/^[[:space:]]*#/ && NF >= 2 {printf "{\"alias\":\"%s\",\"targets\":\"%s\",\"domain\":\"%s\"}\n", $1, $2, d}' "$f"
      done < <(if [[ -n "${1:-}" ]]; then printf '%s\n' "${1,,}"; else lib_mail_domains; fi)
    } | jq -s '.'
    return 0
  fi
  printf '  %-34s %s\n' "ALIAS" "GOES TO"
  while read -r d; do
    [[ -n "$d" ]] || continue
    f="$(lib_mail_alias_file "$d")"
    [[ -s "$f" ]] || continue
    awk -F'\t' '!/^[[:space:]]*#/ && NF >= 2 {printf "  %-34s %s\n", $1, $2}' "$f"
  done < <(if [[ -n "${1:-}" ]]; then printf '%s\n' "${1,,}"; else lib_mail_domains; fi)
  return 0
}

# =============================================================================
#  What has to be in DNS
# =============================================================================
# One function produces the table; printing, --json and --check all read it, so what the
# operator is told and what lomp checks can never drift apart.
# Fields: type <TAB> name <TAB> value <TAB> note
_mail_dns_records() {   # domain
  local d="$1" ip="" ipshow="" sel="" dkim="" relay=""
  # not --no-net: with it the analysis falls back to the address of the local interface, and on
  # a NAT'd server that is an address nobody on the internet can reach. Printed into an A
  # record and an SPF record it would be a mail server that quietly cannot be delivered to.
  lib_system_analyze >/dev/null 2>&1 || true
  ip="${SYS_PUBLIC_IPV4:-}"
  case "$ip" in
    10.*|127.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) ip="" ;;
  esac
  # spelled out here rather than inline: the word inside ${x:-word} is quote-processed even
  # within double quotes, so one apostrophe there swallows every line up to the next one
  ipshow="$ip"
  [[ -n "$ipshow" ]] || ipshow="<the IPv4 address of this server>"
  sel="$(lib_mail_selector "$d")"
  dkim="$(lib_mail_dkim_public "$d" || printf '')"
  printf 'A\tmail.%s\t%s\tDNS only - never proxied: a mail client has to reach this server itself\n' "$d" "$ipshow"
  printf 'MX\t%s\t10 mail.%s.\tthe dot at the end belongs to the record\n' "$d" "$d"
  relay="$(lib_mail_relay_get host)"
  if [[ -n "$relay" ]]; then
    # the mail leaves through somebody else's server, so their hosts have to be in the record
    # as well, or everything this domain sends fails SPF at the far end
    printf 'TXT\t%s\tv=spf1 ip4:%s include:%s ~all\tone SPF record per domain, never two; the include covers the relay this server sends through\n' "$d" "$ipshow" "${relay#*.}"
  else
    printf 'TXT\t%s\tv=spf1 ip4:%s ~all\tone SPF record per domain, never two\n' "$d" "$ipshow"
  fi
  if [[ -n "$dkim" ]]; then
    printf 'TXT\t%s._domainkey.%s\t%s\tpaste it as one line; the provider splits it\n' "$sel" "$d" "$dkim"
  else
    printf 'TXT\t%s._domainkey.%s\t<no DKIM key yet>\trun: lomp mail enable %s\n' "$sel" "$d" "$d"
  fi
  printf 'TXT\t_dmarc.%s\tv=DMARC1; p=none; rua=mailto:dmarc@%s; adkim=r; aspf=r\tstart at p=none and read the reports before tightening it\n' "$d" "$d"
  printf 'SRV\t_imaps._tcp.%s\t0 1 993 mail.%s.\toptional: mail clients find the settings by themselves\n' "$d" "$d"
  printf 'SRV\t_submissions._tcp.%s\t0 1 465 mail.%s.\toptional\n' "$d" "$d"
  printf 'SRV\t_imap._tcp.%s\t0 0 0 .\toptional: says there is no plain IMAP here\n' "$d"
  printf 'SRV\t_pop3._tcp.%s\t0 0 0 .\toptional: says there is no POP3 here\n' "$d"
  # The webmail is a web site and belongs behind the proxy, unlike everything above it: the
  # fifth field says so, and it is the only record of a mail domain that is orange-cloud.
  if [[ "$(lib_json_get "$(lib_domain_json "$d")" '.mail.webmail')" == "true" ]]; then
    printf 'A\twebmail.%s\t%s\ta web site, so this one IS proxied (orange cloud)\tproxied\n' "$d" "$ipshow"
  fi
  return 0
}

lib_mail_dns_print() {   # domain
  local d="$1" t="" n="" v="" note="" px=""
  lib_heading "DNS records for ${d}"
  lib_note "Add these at your DNS provider. At Cloudflare every mail record is grey-cloud (DNS only):"
  lib_note "a proxied MX or mail name cannot receive mail. The webmail is the exception and says so."
  printf '\n'
  while IFS=$'\t' read -r t n v note px; do
    [[ -n "$t" ]] || continue
    printf '  %-4s %-38s %s%s\n' "$t" "$n" "$v" "$( [[ "$px" == "proxied" ]] && printf '   [PROXIED]' || true)"
    [[ -n "$note" ]] && printf '       %s%s%s\n' "$C_DIM" "$note" "$C_RST"
  done < <(_mail_dns_records "$d")
  printf '\n'
  lib_note "And one your provider sets, not your DNS: the PTR record of $(lib_mail_host)'s address"
  lib_note "must say $(lib_mail_host). 'lomp mail test' tells you whether it does."
  return 0
}

lib_mail_dns_json() {   # domain
  local d="$1"
  _mail_dns_records "$d" | jq -R -s --arg domain "$d" '
    {domain: $domain,
     records: [ split("\n")[] | select(length > 0) | split("\t")
                | {type: .[0], name: .[1], value: .[2], note: .[3],
                   proxied: (.[4] // "" | . == "proxied")} ]}'
}

# What DNS actually says today. Asked of the zone's own name servers, because a record that
# was added a minute ago is not in a cache yet and "not there" and "wrong" are different
# answers to an operator.
_mail_dns_query() {   # type name -> the value(s), one per line
  local t="$1" n="$2" ns="" out=""
  lib_have dig || return 1
  ns="$(dig +short SOA "$n" 2>/dev/null | awk '{print $1; exit}' || true)"
  [[ -n "$ns" ]] || ns="$(dig +short SOA "${n#*.}" 2>/dev/null | awk '{print $1; exit}' || true)"
  if [[ -n "$ns" ]]; then out="$(dig +short "@${ns}" "$t" "$n" 2>/dev/null || true)"; fi
  [[ -n "$out" ]] || out="$(dig +short "$t" "$n" 2>/dev/null || true)"
  # a TXT record longer than 255 bytes comes back as several quoted strings
  printf '%s' "$out" | sed 's/" *"//g; s/^"//; s/"$//' || true
  return 0
}

# What DNS says today, judged the way a receiving server judges it: the lowest MX wins, and a
# second SPF record is the same as none.
_mail_dns_say() {   # colour type name detail
  printf '  %s%-4s %-38s %s%s\n' "$1" "$2" "$3" "$4" "$C_RST"
}

lib_mail_dns_check() {   # domain -> 0 when everything is in place
  local d="$1" t="" n="" v="" note="" px="" got="" bad=0 want="" best="" count=0
  lib_have dig || { lib_warn "dig is not installed; DNS cannot be checked"; return 1; }
  lib_heading "DNS check for ${d}"
  while IFS=$'\t' read -r t n v note px; do
    [[ -n "$t" ]] || continue
    [[ "$t" == "SRV" ]] && continue                      # optional, not worth an alarm
    [[ "$v" == "<no DKIM key yet>" ]] && continue
    got="$(_mail_dns_query "$t" "$n")"
    if [[ -z "$got" ]]; then
      _mail_dns_say "$C_YEL" "$t" "$n" "missing"
      bad=1
      continue
    fi
    case "$t" in
      MX)
        # a domain moving away from another provider usually keeps its old MX at a lower
        # number, and the lowest number is where the mail goes: "ours is in the list" is
        # not the question
        want="${v#* }"; want="${want%.}"
        best="$(sort -n <<<"$got" | head -1 | awk '{print $2}' | sed 's/[.]$//')"
        count="$(grep -c . <<<"$got" || true)"
        if [[ "$best" == "$want" ]]; then
          _mail_dns_say "$C_GRN" "$t" "$n" "ok"
          (( count > 1 )) && _mail_dns_say "$C_YEL" "$t" "$n" "another mail server is also listed: $(tr '\n' ' ' <<<"$got")"
        else
          _mail_dns_say "$C_RED" "$t" "$n" "mail goes to ${best:-somewhere else} first"
          bad=1
        fi
        ;;
      TXT)
        if [[ "$v" == v=spf1* ]]; then
          # two SPF records are the same as none: a receiver that finds both fails the check
          count="$(grep -c '^v=spf1' <<<"$got" || true)"
          if (( count > 1 )); then
            _mail_dns_say "$C_RED" "$t" "$n" "${count} SPF records; a domain may have only one"
            bad=1
          elif [[ "$got" == *"$v"* ]]; then
            _mail_dns_say "$C_GRN" "$t" "$n" "ok"
          else
            _mail_dns_say "$C_YEL" "$t" "$n" "says: $(tr '\n' ' ' <<<"$got" | cut -c1-60)"
            bad=1
          fi
        elif [[ "$got" == *"$v"* ]]; then
          _mail_dns_say "$C_GRN" "$t" "$n" "ok"
        else
          _mail_dns_say "$C_RED" "$t" "$n" "says: $(tr '\n' ' ' <<<"$got" | cut -c1-60)"
          bad=1
        fi
        ;;
      *)
        # A proxied name answers with Cloudflare's address on purpose, so what it should say
        # is "an address of Cloudflare's" and not this server's. Anything else is a name
        # pointing somewhere else entirely, which is exactly what has to be reported.
        if [[ "$px" == "proxied" ]]; then
          if lib_cf_ips_are_cloudflare "$(tr '\n' ' ' <<<"$got")"; then
            _mail_dns_say "$C_GRN" "$t" "$n" "proxied by Cloudflare, as it should be"
          elif [[ "$got" == *"${v%.}"* ]]; then
            _mail_dns_say "$C_YEL" "$t" "$n" "points here but is not proxied; turn the orange cloud on"
          else
            _mail_dns_say "$C_RED" "$t" "$n" "answers ${got//$'\n'/ }, which is neither this server nor Cloudflare"
            bad=1
          fi
        elif [[ "$got" == *"${v%.}"* ]]; then
          _mail_dns_say "$C_GRN" "$t" "$n" "ok"
        else
          _mail_dns_say "$C_RED" "$t" "$n" "says: $(tr '\n' ' ' <<<"$got")"
          bad=1
        fi
        ;;
    esac
  done < <(_mail_dns_records "$d")
  # a mail name behind Cloudflare's proxy answers with Cloudflare's address, and no mail
  # client can reach it there
  got="$(lib_resolve A "mail.${d}" | tr '\n' ' ')"
  if [[ -n "$got" ]] && lib_cf_ips_are_cloudflare "$got"; then
    _mail_dns_say "$C_RED" "A" "mail.${d}" "resolves to Cloudflare (${got% }): turn the proxy off for it"
    bad=1
  fi
  (( bad )) && lib_note "Add what is missing, then run this again; DNS takes a few minutes to spread."
  return "$bad"
}


# =============================================================================
#  Writing the records for the operator
# =============================================================================
# With a Cloudflare token stored, lomp can put the records there itself. Two rules decide
# everything below: it never touches a record it did not write, and it never guesses. A mail
# server that somebody else's MX already serves, or a domain that already has an SPF record,
# is reported and left alone - merging two SPF records or silently moving mail away from a
# provider is not a thing a provisioning script should do behind an operator's back.
MAIL_DNS_APPLIED=0
MAIL_DNS_CONFLICTS=0
MAIL_DNS_SKIPPED=0

_mail_dns_report() {   # status name detail
  case "$1" in
    applied)   printf '  %s%-9s%s %-38s %s\n' "$C_GRN" "written" "$C_RST" "$2" "$3" ;;
    same)      printf '  %s%-9s%s %-38s %s\n' "$C_DIM" "already" "$C_RST" "$2" "$3" ;;
    conflict)  printf '  %s%-9s%s %-38s %s\n' "$C_RED" "conflict" "$C_RST" "$2" "$3" ;;
    *)         printf '  %s%-9s%s %-38s %s\n' "$C_YEL" "skipped" "$C_RST" "$2" "$3" ;;
  esac
}

_mail_dns_conflict() {   # name detail   - report it and count it
  _mail_dns_report conflict "$1" "$2"
  MAIL_DNS_CONFLICTS=$((MAIL_DNS_CONFLICTS + 1))
  return 1
}

# A TXT value longer than 255 bytes is stored as several strings and comes back as
# "chunk" "chunk" - the DKIM record always does. Comparing that with what we mean to write
# would rewrite the key on every single run.
_mail_txt_norm() {
  local s="${1//\" \"/}"
  s="${s#\"}"; s="${s%\"}"
  printf '%s' "$s"
}

# One record. Returns 0 when the zone now says what it should.
_mail_dns_apply_one() {   # zone type name content [--replace-mx] [proxied]
  local z="$1" t="$2" n="$3" c="$4" replace="${5:-}" want_px="false"
  local existing="" mine="" others="" id="" cur="" prio=10 n_other=0 old=""
  [[ "${6:-}" == "proxied" ]] && want_px="true"
  if ! existing="$(lib_cf_records "$z" "$t" "$n")"; then
    _mail_dns_conflict "$n" "Cloudflare could not be read: ${CF_LAST_ERROR}"
    return 1
  fi
  # what lompstack itself wrote, and what somebody else put at the same name
  mine="$(jq -c --arg tag "$CF_RECORD_TAG" '[.[] | select((.comment // "") == $tag)][0] // empty' <<<"$existing" 2>/dev/null || true)"
  others="$(jq -c --arg tag "$CF_RECORD_TAG" '[.[] | select((.comment // "") != $tag)]' <<<"$existing" 2>/dev/null || printf '[]')"
  n_other="$(jq 'length' <<<"$others" 2>/dev/null || printf '0')"
  id="$(jq -r '.id // empty' <<<"${mine:-{\}}" 2>/dev/null || true)"

  case "$t" in
    MX)
      prio="${c%% *}"; c="${c#* }"; c="${c%.}"
      # Somebody else's mail server is in the zone: that is a decision, not a leftover. It
      # counts even when lompstack's own MX is there as well - the lowest preference wins, so
      # a foreign MX next to ours still takes every message the domain receives.
      if (( n_other > 0 )) && [[ "$replace" != "--replace-mx" ]]; then
        _mail_dns_conflict "$n" "another MX is set: $(jq -r '[.[] | "\(.priority) \(.content)"] | join(", ")' <<<"$others"); use --replace-mx to take it over"
        return 1
      fi
      cur="$(jq -r '"\(.priority) \(.content)"' <<<"${mine:-{\}}" 2>/dev/null || true)"
      if [[ "$cur" != "${prio} ${c}" && "$cur" != "${prio} ${c}." ]]; then
        lib_cf_record_write "$z" "$id" MX "$n" "$c" "$prio" || { _mail_dns_conflict "$n" "$CF_LAST_ERROR"; return 1; }
        _mail_dns_report applied "$n" "MX ${prio} ${c}"
        MAIL_DNS_APPLIED=$((MAIL_DNS_APPLIED + 1))
      elif (( n_other == 0 )); then
        _mail_dns_report same "$n" "MX ${prio} ${c}"
        return 0
      fi
      # ours is in the zone: only now do the others go. The other way round, a refused write
      # would leave the domain with no MX at all and every message to it bounced.
      if (( n_other > 0 )); then
        while read -r old; do
          [[ -n "$old" ]] || continue
          lib_cf_record_delete "$z" "$old" || lib_warn "could not remove the old MX ${old}: ${CF_LAST_ERROR}"
        done < <(jq -r '.[].id' <<<"$others" || true)
        _mail_dns_report applied "$n" "${n_other} MX record(s) of another provider removed"
      fi
      ;;
    TXT)
      if [[ "$c" == v=spf1* ]]; then
        # two SPF records are the same as none, so an existing one is never overwritten
        local other=""
        other="$(jq -r '[.[] | select(.content | startswith("v=spf1"))][0].content // empty' <<<"$others" 2>/dev/null || true)"
        if [[ -n "$other" ]]; then
          _mail_dns_conflict "$n" "this domain already has an SPF record: ${other}"
          lib_note "        merge it by hand; two SPF records fail for every receiver"
          return 1
        fi
      elif (( n_other > 0 )) && [[ -z "$mine" ]]; then
        # DMARC and DKIM live at a name of their own, so anything already there was put there
        # by somebody. A second record does not override it: two DMARC records mean the domain
        # has no policy at all, and a second key at one selector breaks the signature.
        _mail_dns_conflict "$n" "a record is already here: $(jq -r '.[0].content' <<<"$others" | cut -c1-40)"
        return 1
      fi
      cur="$(jq -r '.content // empty' <<<"${mine:-{\}}" 2>/dev/null || true)"
      if [[ "$(_mail_txt_norm "$cur")" == "$(_mail_txt_norm "$c")" ]]; then _mail_dns_report same "$n" "unchanged"; return 0; fi
      lib_cf_record_write "$z" "$id" TXT "$n" "$c" || { _mail_dns_conflict "$n" "$CF_LAST_ERROR"; return 1; }
      _mail_dns_report applied "$n" "$(printf '%.48s' "$c")..."
      MAIL_DNS_APPLIED=$((MAIL_DNS_APPLIED + 1))
      ;;
    A)
      if (( n_other > 0 )); then
        # A record somebody else made at this name. One that already says the right thing is
        # left exactly as it is; anything else is theirs to decide, not ours to overwrite -
        # and a second address here sends half of all mail connections to the wrong host.
        if [[ -z "$mine" && "$n_other" == "1" \
              && "$(jq -r '.[0].content' <<<"$others")" == "$c" \
              && "$(jq -r '.[0].proxied // false' <<<"$others")" == "$want_px" ]]; then
          _mail_dns_report same "$n" "$c"
          return 0
        fi
        _mail_dns_conflict "$n" "another A record is here: $(jq -r '[.[] | .content] | join(", ")' <<<"$others"); this name has to point at this server$( [[ "$want_px" == "false" ]] && printf ' and stay unproxied' || true)"
        return 1
      fi
      cur="$(jq -r '.content // empty' <<<"${mine:-{\}}" 2>/dev/null || true)"
      if [[ "$cur" == "$c" && "$(jq -r '.proxied // false' <<<"${mine:-{\}}" 2>/dev/null || printf 'x')" == "$want_px" ]]; then
        _mail_dns_report same "$n" "$c"
        return 0
      fi
      # A mail name behind the proxy answers with Cloudflare's address and no mail client can
      # reach it there. The webmail is the one name of a mail domain that belongs behind it.
      lib_cf_record_write "$z" "$id" A "$n" "$c" "" "$want_px" \
        || { _mail_dns_conflict "$n" "$CF_LAST_ERROR"; return 1; }
      _mail_dns_report applied "$n" "${c} ($( [[ "$want_px" == "true" ]] && printf 'proxied' || printf 'not proxied'))"
      MAIL_DNS_APPLIED=$((MAIL_DNS_APPLIED + 1))
      ;;
  esac
  return 0
}

lib_mail_dns_apply() {   # domain [--replace-mx]
  local d="$1" replace="${2:-}" t="" n="" v="" note="" px="" zone="" first=""
  [[ -n "$(lib_cf_token)" ]] || lib_die "No Cloudflare API token is stored" \
    "the records can only be written with one; they are printed instead" \
    "printf '%s' \"\$TOKEN\" | lomp install --cf-api-token -"
  MAIL_DNS_APPLIED=0
  MAIL_DNS_CONFLICTS=0
  MAIL_DNS_SKIPPED=0
  if (( OPT_DRY_RUN )); then
    lib_info "[dry-run] would write these records into Cloudflare (no request is sent):"
    lib_mail_dns_print "$d"
    return 0
  fi
  first="mail.${d}"
  # not lib_die: this is the last step of "mail enable", and a domain whose DNS lives
  # somewhere else must still be told what to put there
  if ! zone="$(lib_cf_zone_id "$first")"; then
    lib_warn "Cloudflare has no zone for ${d} that this token can see"
    lib_note "${CF_LAST_ERROR}; the records have to go in by hand"
    return 1
  fi
  lib_heading "Writing the DNS records of ${d}"
  while IFS=$'\t' read -r t n v note px; do
    [[ -n "$t" ]] || continue
    [[ "$t" == "SRV" ]] && continue                     # optional; nothing breaks without them
    # a value the table could not fill in ("<no DKIM key yet>", "<the IPv4 address of this
    # server>") is a placeholder for the reader. Published, it would be a live record saying
    # something that is not an address at all.
    if [[ "$v" == *"<"* ]]; then
      _mail_dns_report skipped "$n" "$v"
      MAIL_DNS_SKIPPED=$((MAIL_DNS_SKIPPED + 1))
      continue
    fi
    _mail_dns_apply_one "$zone" "$t" "$n" "$v" "$replace" "$px" || true
  done < <(_mail_dns_records "$d")
  lib_json_set "$(lib_domain_json "$d")" '.mail.dns_applied_at = $ts' --arg ts "$(lib_iso_now)" 2>/dev/null || true
  printf '\n'
  if (( MAIL_DNS_CONFLICTS > 0 || MAIL_DNS_SKIPPED > 0 )); then
    lib_warn "${MAIL_DNS_APPLIED} record(s) written, $((MAIL_DNS_CONFLICTS + MAIL_DNS_SKIPPED)) left for you: lomp mail dns ${d} shows what they should say"
    return 1
  fi
  lib_ok "${MAIL_DNS_APPLIED} record(s) written; the rest was already right"
  lib_note "Reverse DNS is still your provider's to set: lomp mail test"
  return 0
}

# Take away only what lompstack wrote. A record somebody added by hand stays, whatever it says.
lib_mail_dns_cleanup() {   # domain
  local d="$1" zone="" t="" n="" v="" note="" px="" gone=0 id="" have=""
  [[ -n "$(lib_cf_token)" ]] || return 0
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would remove the DNS records lompstack wrote for ${d}"; return 0; fi
  zone="$(lib_cf_zone_id "mail.${d}")" || return 0
  while IFS=$'\t' read -r t n v note px; do
    [[ -n "$t" ]] || continue
    [[ "$t" == "SRV" ]] && continue
    # a failed read is not an empty zone: saying nothing here would quietly leave records behind
    if ! have="$(lib_cf_records "$zone" "$t" "$n")"; then
      lib_warn "could not read ${t} ${n} from Cloudflare: ${CF_LAST_ERROR}; it may still be there"
      continue
    fi
    while read -r id; do
      [[ -n "$id" ]] || continue
      if lib_cf_record_delete "$zone" "$id"; then gone=$((gone + 1)); else lib_warn "could not remove ${t} ${n}: ${CF_LAST_ERROR}"; fi
    done < <(jq -r --arg tag "$CF_RECORD_TAG" '.[] | select((.comment // "") == $tag) | .id' <<<"$have" || true)
  done < <(_mail_dns_records "$d")
  (( gone > 0 )) && lib_ok "${gone} DNS record(s) that lompstack had written were removed"
  return 0
}

# postmaster, abuse and dmarc have to arrive somewhere: the first mailbox of the domain gets
# them unless the operator has already said otherwise.
lib_mail_domain_aliases_seed() {   # domain mailbox-address
  local d="$1" box="$2" f="" a=""
  f="$(lib_mail_alias_file "$d")"
  for a in postmaster abuse dmarc; do
    if [[ -s "$f" ]] && awk -F'\t' -v k="${a}@${d}" '$1 == k {found=1} END{exit !found}' "$f"; then continue; fi
    lib_mail_alias_set "$d" "${a}@${d}" "$box"
  done
  return 0
}

# =============================================================================
#  Commands
# =============================================================================
lib_mail_status_json() {
  local host="$1" services=""
  services="$(lib_mail_services | while read -r s; do
      [[ -n "$s" ]] || continue
      if lib_service_active "$s"; then printf '{"name":"%s","active":true}\n' "$s"; else printf '{"name":"%s","active":false}\n' "$s"; fi
    done | jq -s '.')"
  jq -n --arg h "$host" --arg p25 "$(lib_mail_port25_probe)" --arg relay "$(lib_mail_relay_get host)" \
     --argjson services "$services" \
     '{installed:true, hostname:$h, port25:$p25, relay:$relay, services:$services}'
}

lib_mail_status_main() {
  local host=""
  host="$(lib_mail_host)"
  if [[ -z "$host" ]]; then
    if (( OPT_JSON )); then printf '{"installed":false}\n'; else lib_info "Mail is not installed (lomp install --with-mail)"; fi
    return 0
  fi
  if (( OPT_JSON )); then lib_mail_status_json "$host"; return 0; fi
  lib_mail_test_report
  if lib_have postqueue; then lib_print_kv "Queue" "$(postqueue -p 2>/dev/null | tail -n 1 || printf 'empty')"; fi
  return 0
}

lib_mail_usage() {
  cat <<'EOF'
Usage: lomp mail <command>

  enable <domain> [--mailbox info] [--quota 2G]
                         give a site its own mail: DKIM key, certificate, DNS to add
  disable <domain> [--delete-data] [--dns-cleanup]
                         stop taking mail for it: no delivery and no login, but every message
                         stays on disk and enabling it again restores the mailboxes

  box add <user@domain> [--quota 2G]    the password is read from stdin or asked for, never
  box passwd <user@domain>              taken from the command line
  box quota <user@domain> <2G|0>
  box list [domain] | box del <user@domain> | box kick <user@domain>

  alias add <alias@domain> <target[,target]>   an address that goes somewhere else
  alias del <alias@domain> | alias list [domain]

  dns <domain> [--json] [--check]       what to put in DNS, and whether it is there yet
  dns <domain> --apply [--replace-mx]   write it into Cloudflare with the stored token
  cert [domain]                         ask again for a certificate that did not come

  status                 what the mail stack is doing, and whether it can send
  test                   check reverse DNS and whether outgoing port 25 is open
  queue                  show the Postfix queue
  regenerate             rewrite every mail configuration file and restart the stack
  relay set --host H [--port 587] --user U
                         send outgoing mail through another server; the password is read
                         from standard input, never from an argument
  relay off              send outgoing mail directly again
EOF
}

_mail_box_cmd() {
  local action="${1:-list}"
  shift || true
  case "$action" in
    add)    lib_mail_box_add_main "$@" ;;
    passwd) lib_mail_box_passwd_main "$@" ;;
    quota)  lib_mail_box_quota_main "$@" ;;
    del|delete|remove) lib_mail_box_del_main "$@" ;;
    kick)   lib_mail_box_kick_main "$@" ;;
    list)   lib_mail_box_list_main "${1:-}" ;;
    *)      lib_die "Unknown mailbox command: ${action}" "" "lomp mail box add info@example.com" ;;
  esac
}

_mail_alias_cmd() {
  local action="${1:-list}"
  shift || true
  case "$action" in
    add)  lib_mail_alias_add_main "$@" ;;
    del|delete|remove) lib_mail_alias_del_main "$@" ;;
    list) lib_mail_alias_list_main "${1:-}" ;;
    *)    lib_die "Unknown alias command: ${action}" "" "lomp mail alias add sales@example.com info@example.com" ;;
  esac
}

_mail_dns_cmd() {
  local d="${1:-}" a="" check=0 apply=0 replace=""
  shift || true
  [[ -n "$d" ]] || lib_die "Which domain?" "" "lomp mail dns example.com"
  d="${d,,}"
  lib_domain_registered "$d" || lib_die "No site called ${d} on this server" "" "lomp list"
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --check) check=1 ;;
      --apply) apply=1 ;;
      --replace-mx) replace="--replace-mx"; apply=1 ;;
      --json)  OPT_JSON=1 ;;
      *) lib_die "Unknown option for 'mail dns': ${a}" "" "lomp mail dns example.com --check" ;;
    esac
  done
  if (( OPT_JSON )); then lib_mail_dns_json "$d"; return 0; fi
  if (( apply )); then
    lib_mail_domain_enabled "$d" || lib_die "Mail is not on for ${d}" "" "lomp mail enable ${d}"
    lib_mail_dns_apply "$d" "$replace" || exit 1
    return 0
  fi
  if (( check )); then lib_mail_dns_check "$d" || exit 1; return 0; fi
  lib_mail_dns_print "$d"
}

_mail_relay_cmd() {
  local action="${1:-}" rhost="" rport="587" ruser="" a=""
  shift || true
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --host) rhost="${1:-}"; shift || true ;;
      --port) rport="${1:-587}"; shift || true ;;
      --user) ruser="${1:-}"; shift || true ;;
      *) lib_die "Unknown option for 'mail relay': ${a}" "" "lomp mail help" ;;
    esac
  done
  lib_mail_installed || lib_die "Mail is not installed" "" "lomp install --with-mail"
  case "$action" in
    set) lib_mail_relay_set "$rhost" "$rport" "$ruser" ;;
    off) lib_mail_relay_off ;;
    *)   lib_die "Unknown relay command: ${action:-none}" "" "lomp mail relay set --host smtp.example.net --user you@example.net" ;;
  esac
}

# The webmail of one domain. It is a mail command because that is where an operator looks
# for it, but everything it does lives in lib/webmail.sh.
_mail_webmail_cmd() {   # on|off|status <domain>
  local a="${1:-status}" d="${2:-}"
  d="${d,,}"
  case "$a" in
    on)
      [[ -n "$d" ]] || lib_die "Which domain?" "" "lomp mail webmail on example.com"
      lib_mail_domain_enabled "$d" || lib_die "Mail is not on for ${d}" "" "lomp mail enable ${d}"
      lib_webmail_domain_enable "$d" || lib_die "The webmail could not be set up for ${d}" "${WM_LAST_ERROR}" "lomp doctor"
      # a jail fail2ban refuses is a warning, not the end of the command: the webmail is up,
      # and what follows tells the operator what to put in DNS
      lib_webmail_fail2ban_apply || true
      lib_mail_dns_note "$d"
      ;;
    off)
      [[ -n "$d" ]] || lib_die "Which domain?" "" "lomp mail webmail off example.com"
      lib_webmail_domain_disable "$d"
      lib_ok "The webmail of ${d} is off; its mail is untouched"
      ;;
    status|"") lib_webmail_status ;;
    *) lib_die "Unknown webmail command: ${a}" "" "lomp mail webmail on|off <domain>" ;;
  esac
  return 0
}

# After a change that adds or removes a name, say what DNS needs - or write it.
lib_mail_dns_note() {   # domain
  local d="$1"
  if [[ -n "$(lib_cf_token)" ]]; then
    lib_mail_dns_apply "$d" || lib_mail_dns_print "$d"
  else
    lib_mail_dns_print "$d"
  fi
  return 0
}

lib_mail_main() {
  local sub="${1:-status}"
  shift || true
  case "$sub" in
    status)     lib_mail_status_main "$@" ;;
    test)       lib_mail_installed || lib_die "Mail is not installed" "" "lomp install --with-mail"
                lib_mail_test_report ;;
    queue)      lib_have postqueue || lib_die "Postfix is not installed" "" "lomp install --with-mail"
                postqueue -p || lib_warn "The Postfix queue could not be read (is postfix running?)" ;;
    enable)     lib_mail_enable_main "$@" ;;
    disable)    lib_mail_installed || lib_die "Mail is not installed" "" "lomp install --with-mail"
                lib_mail_disable_main "$@" ;;
    box)        lib_mail_installed || lib_die "Mail is not installed" "" "lomp install --with-mail"
                _mail_box_cmd "$@" ;;
    alias)      lib_mail_installed || lib_die "Mail is not installed" "" "lomp install --with-mail"
                _mail_alias_cmd "$@" ;;
    dns)        lib_mail_installed || lib_die "Mail is not installed" "" "lomp install --with-mail"
                _mail_dns_cmd "$@" ;;
    cert)       lib_mail_installed || lib_die "Mail is not installed" "" "lomp install --with-mail"
                if [[ -n "${1:-}" && "${1:0:2}" != "--" ]]; then
                  lib_mail_domain_enabled "${1,,}" || lib_die "Mail is not on for ${1}" "" "lomp mail enable ${1}"
                  lib_mail_domain_cert_ensure "${1,,}"
                  lib_mail_tables_apply || lib_warn "the mail tables could not be rebuilt: ${MAIL_LAST_ERROR}"
                else
                  lib_mail_cert_ensure "$(lib_mail_host)"
                fi ;;
    regenerate) lib_mail_installed || lib_die "Mail is not installed" "" "lomp install --with-mail"
                lib_mail_dirs_ensure
                lib_mail_apply "$(lib_mail_host)" || lib_die "The mail configuration could not be applied" "${MAIL_LAST_ERROR}" "lomp mail status"
                lib_ok "Mail configuration rewritten and the stack restarted" ;;
    relay)      _mail_relay_cmd "$@" ;;
    webmail)    lib_mail_installed || lib_die "Mail is not installed" "" "lomp install --with-mail"
                _mail_webmail_cmd "$@" ;;
    help|-h|--help) lib_mail_usage ;;
    *)          lib_error "Unknown mail command: ${sub}"; printf '\n'; lib_mail_usage; exit 2 ;;
  esac
  return 0
}
