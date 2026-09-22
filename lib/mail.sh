#!/usr/bin/env bash
# lib/mail.sh - e-mail for the sites of this server: Postfix (SMTP), Dovecot (IMAP, LMTP and
#               authentication), Rspamd (spam filtering, DKIM) and a webmail, enabled per site.
#
# This file holds the paths, the state accessors and the pure validators the rest of the mail
# work is built on. The stack itself, the per-domain commands and the webmail follow in the
# next phases; nothing here starts a service or writes a configuration file.
#
#   users     /etc/dovecot/lomp/passwd     0640 root:dovecot, BLF-CRYPT hashes, no system users
#   mail      /var/vmail/<domain>/<local>/Maildir, owned by one unmapped "vmail" user, so a
#             site user can never read another site's - or its own - mail from the filesystem
#   state     domain.json .mail{...} carries no secret; STATE_DIR/mail/* is root-only
#   listeners public 25/465/587/993, everything else on loopback (see the install phase)

MAIL_VMAIL_USER="${MAIL_VMAIL_USER:-vmail}"
MAIL_VMAIL_HOME="${MAIL_VMAIL_HOME:-/var/vmail}"
MAIL_WEBMAIL_USER="${MAIL_WEBMAIL_USER:-lompwebmail}"
MAIL_POSTFIX_DIR="${MAIL_POSTFIX_DIR:-/etc/postfix/lomp}"
MAIL_DOVECOT_DIR="${MAIL_DOVECOT_DIR:-/etc/dovecot/lomp}"
MAIL_PASSWD_FILE="${MAIL_PASSWD_FILE:-${MAIL_DOVECOT_DIR}/passwd}"
MAIL_RSPAMD_DIR="${MAIL_RSPAMD_DIR:-/etc/rspamd/local.d}"
MAIL_DKIM_DIR="${MAIL_DKIM_DIR:-/var/lib/rspamd/dkim}"
MAIL_STATE_DIR="${MAIL_STATE_DIR:-${STATE_DIR}/mail}"
MAIL_CERT_NAME="${MAIL_CERT_NAME:-_mailhost}"        # certbot lineage for MAIL_HOST itself

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
lib_mail_local_valid() {
  local l="$1"
  [[ "$l" =~ ^[a-z0-9]([a-z0-9._+-]{0,62}[a-z0-9])?$ ]] || return 1
  [[ "$l" != *..* ]]
}

lib_mail_address_valid() {   # user@domain
  local addr="${1,,}"
  [[ "$addr" == *@* && "$addr" != *@*@* ]] || return 1
  lib_mail_local_valid "${addr%%@*}" && lib_domain_valid "${addr#*@}"
}

# A mailbox quota as Dovecot writes it: a plain size with a unit, or 0 for "no limit".
lib_mail_quota_valid() { [[ "$1" == "0" || "$1" =~ ^[1-9][0-9]{0,5}[MG]$ ]]; }
