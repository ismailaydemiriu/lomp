# lomp

[![CI](https://github.com/ismailaydemiriu/lomp/actions/workflows/ci.yml/badge.svg)](https://github.com/ismailaydemiriu/lomp/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Ubuntu 22.04 | 24.04](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)

**LOMP** is the stack this installs, the way LAMP and LEMP name theirs:

| | |
|---|---|
| **L** | **Linux** — Ubuntu 22.04 or 24.04 |
| **O** | **OpenLiteSpeed** — the web server, from the official LiteSpeed repository |
| **M** | **MariaDB** — the database |
| **P** | **PHP** — as LSPHP, OpenLiteSpeed's LSAPI build |

LAMP puts Apache in the O slot and LEMP puts Nginx (*engine-x*) there. OpenLiteSpeed gives
you Apache's `.htaccess` compatibility with event-driven performance closer to Nginx, plus
HTTP/3 and a built-in page cache — which is why this stack exists as its own letter.

One script turns a bare Ubuntu VPS into a production host for dynamic, database-heavy
sites, and manages those sites afterwards.

```bash
sudo ./setup.sh install --email you@example.com
sudo ./setup.sh add example.com --www --wordpress
```

Not a demo script. Every change is idempotent, backed up before it is applied, verified
after it is applied, and rolled back if the verification fails.

---

## What you get

| Layer | What is installed and tuned |
|---|---|
| Web server | OpenLiteSpeed from the official LiteSpeed repository, HTTP/2, HTTP/3 (QUIC), Brotli/gzip, catch-all vhost that returns 403 for unknown hostnames |
| PHP | LSPHP (default 8.3, any version per site) with curl, mbstring, mysqli, PDO (MySQL and SQLite), sqlite3, gd, imagick, xml, zip, intl, bcmath, soap, opcache, redis, apcu, fileinfo, exif |
| Database | MariaDB bound to 127.0.0.1, hardened, InnoDB tuned to your RAM and disk type, slow query log on |
| Cache | Redis on localhost with a generated password, `allkeys-lru`, memory capped by RAM share |
| TLS | Let's Encrypt via certbot, shared ACME webroot, TLS 1.2/1.3 only, HSTS, auto-renew with an OpenLiteSpeed deploy hook |
| Security | UFW, Fail2ban (sshd + recidive + WordPress/scanner jails), sshd drop-in hardening, unattended security updates |
| Operations | Backups with retention/encryption/remote upload, daily health check, e-mail / Telegram / webhook alerts, `status` and `doctor` |
| Optional | Node.js + PM2, Python venv tooling, Netdata, Cloudflare real-client-IP mode, a mail server with webmail (Postfix + Dovecot + Rspamd + Roundcube). None of these is installed unless you ask for it, on the command line or from the menu. |
| Mail only | `install --mail-only` makes a server that carries mail and nothing else: every domain's mailboxes on one machine, their web sites wherever they are. See [A server for mail alone](#a-server-for-mail-alone). |

Everything is sized from the machine it runs on: CPU count, RAM, and whether the disk is
NVMe, SSD or spinning rust all feed into the OpenLiteSpeed, PHP, MariaDB and Redis settings.

---

## Requirements

- Ubuntu **22.04 (jammy)** or **24.04 (noble)**, x86_64 or arm64
- Root or sudo
- 1 GB RAM minimum, 2 GB+ recommended
- Ports 80 and 443 reachable from the internet (needed for certificates)
- A domain whose DNS A record already points at the server, if you want TLS on day one

---

## Installation

### Quick start

On a bare Ubuntu 22.04 / 24.04 server, as root. Clone and provision in one line:

```bash
apt-get update && apt-get install -y git && git clone https://github.com/ismailaydemiriu/lomp.git /opt/lomp && cd /opt/lomp && chmod +x setup.sh && ./setup.sh install --email you@example.com --backup-schedule "daily 03:00"
```

Put your own address in `--email`; it is used for Let's Encrypt and for alerts. The
step-by-step version below explains what each part does and how to preview the whole run
first with `--dry-run`.

### 1. Connect to the server

```bash
ssh root@YOUR_SERVER_IP
```

### 2. Get the code

```bash
apt-get update && apt-get install -y git
git clone https://github.com/ismailaydemiriu/lomp.git /opt/lomp
cd /opt/lomp
chmod +x setup.sh
```

Ubuntu server images do not ship git, and it is needed both to fetch the code and by
`self-update` later, so it is installed here and kept as one of the base packages.

### 3. See what it would do (optional but recommended)

Nothing is changed in this mode, you just get the full plan and the diffs:

```bash
sudo ./setup.sh install --dry-run --email you@example.com
```

### 4. Run the installation

```bash
sudo ./setup.sh install --email you@example.com --backup-schedule "daily 03:00"
```

Add `--non-interactive` to run it unattended, for example from cloud-init. The run takes a
few minutes and prints a numbered `[step/total]` progress line for every stage. The very
first step installs the `lomp` command itself, so if a later step fails you can still run
`sudo lomp doctor` to find out why.

By default the WebAdmin panel is **not** exposed to the internet at all: the listener binds
to localhost and no firewall port is opened. You reach it through an SSH tunnel, which needs
no static IP. See [WebAdmin access](#webadmin-access) if you want to change that.

Useful extras:

```bash
# Node.js app hosting, Python tooling, Cloudflare in front, custom PHP.
# These are opt-in: without the flags nothing extra is installed. They can also be
# added later, from "Optional components" in the menu or by re-running install.
sudo ./setup.sh install --with-node --with-python --cloudflare --php 8.3

# A mail server for the sites on this machine (see "Mail" below for what it needs first)
sudo ./setup.sh install --with-mail --mail-hostname mail.example.com

# Or a server for mail alone: no sites, the mail of all your domains (see "A server for mail alone")
sudo ./setup.sh install --mail-only --mail-hostname mail.example.com --email you@example.com

# Change the SSH port safely (UFW is opened first, sshd is tested before it is restarted)
sudo ./setup.sh install --ssh-port 2222
```

### 5. Check the result

```bash
sudo lomp            # interactive menu
sudo lomp status     # services, versions, resources, sites
sudo lomp doctor     # deep health check, exits non-zero if something is broken
```

Running `lomp` with no arguments on a terminal opens a menu covering the everyday
operations: add or remove a site, credentials, logs, backups, the panel, updates. Every
entry just runs the corresponding command, so nothing is hidden from you. Piped or with
`--non-interactive` it prints the command reference instead, so scripts and cron are
unaffected.

lompstack speaks Turkish and English. The first time `install` or the menu runs on a
terminal it asks which one, once, and keeps the answer in `/root/.server-setup/lang`; **28 →
Language** in the menu changes it (and offers a third view of the menu with both side by
side). The menu follows it, and so does what the commands print on a terminal - as far as the
messages have been translated: adding and removing a site, Node.js applications and proxies so
far; everything else still comes in English. `LOMP_LANG=tr|en` sets it for one run.

What a script reads never changes: piped or redirected output, `--json`, cron mails and
`/var/log/server_setup.log` are always English. The Turkish texts are two tables, one line per
text: `MENU_TR` at the end of `lib/menu.sh` (a menu text without a line there fails the unit
suite) and `LIB_TR_PAIRS` in `lib/lang.sh` (a message without a line there, or one whose
English wording changed, is simply shown in English).

After installation the script is available system-wide as `lomp` (or the longer
`lompstack`), so you do not need to stay in the clone directory.

### 6. Reach the WebAdmin panel

```bash
sudo lomp panel
```

That opens the panel for the address you are connected from, for one hour, and prints the
URL together with the user name and password. It closes again on its own.

If you would rather not open any port at all, `sudo lomp panel status` prints an SSH
tunnel command to run on **your own computer**, after which the panel is at
`https://127.0.0.1:7080`:

```bash
ssh -N -L 7080:127.0.0.1:7080 root@YOUR_SERVER_IP
```

Credentials live in `/root/.server-setup/` with mode 0600 and are never written to the log.

### 7. Add your first site

```bash
sudo lomp add example.com --www
```

This creates the system user, the directory tree, the vhost, requests a certificate and
runs a smoke test. Upload your files to `/home/example.com/public_html/`.

Files uploaded as root (WinSCP or scp logged in as root, an archive root unpacked) arrive as
root's. PHP runs as the site's own user (`example_com`), so until the files are handed over it
cannot change them: WordPress cannot update itself or store an upload. lomp hands them over by
itself: every minute it looks through each site's home for what is not the site's own and
gives it to the site's user. To have it done right now, or to see why a site's files were not
handed over:

```bash
sudo lomp fix-owner example.com     # or --all for every site; item 21 in the menu does the same
```

Only what belongs to someone else changes; `logs` stays root's and the file modes stay as they
are. A device node and a file that has a second name somewhere are never handed over, by
hand or by itself: the command lists them, and `doctor` names a site the automatic hand-over
stopped at.

If root keeps files of its own in a site on purpose - a `wp-config.php` that PHP may read but
not change, say - the automatic hand-over would give them to the site within a minute. Switch
it off on such a server, and files change hands only when you run the command:

```bash
sudo lomp fix-owner --auto off      # --auto on starts it again
```

If DNS is not ready yet, add the site without TLS and issue the certificate later:

```bash
sudo lomp add example.com --no-ssl
# ... point the DNS records at the server, then:
sudo lomp renew-ssl example.com
```

A WordPress that was installed before its certificate has `http://` as its stored address.
`renew-ssl` puts that right: `home` and `siteurl` become `https://` when they are the plain
`http://` address of the site (with or without `www`, as stored), and so does the admin address
`lomp credentials` prints. An address somebody set - another host, a port, a directory - is
named and left alone. Links inside posts are not rewritten: WordPress and the redirect turn
them into `https://` as they are served, and `renew-ssl` says how many there are and prints
the `wp search-replace` command for rewriting them for good. If wp-cli fails, that is a
warning; the certificate is in place either way, and the next `renew-ssl` looks again.

---

## Everyday commands

```bash
sudo lomp add shop.example.com --wordpress          # WordPress with database and cache
sudo lomp wordpress blog.example.com                # only WordPress's files, into a site that is
                                                    # there; you finish the setup in the browser
sudo lomp add api.example.com --proxy 127.0.0.1:3000 # Node/Python app behind OpenLiteSpeed
sudo lomp proxy add example.com /api/ 127.0.0.1:3001 # an app under a path of an existing site
sudo lomp add node.example.com --node                # Node.js app run by PM2 (see below)
sudo lomp app worker node.example.com add queue --start "node worker.js"   # a worker next to it
sudo lomp add cdn.example.com --static              # static site, no PHP
sudo lomp db shop.example.com                       # create or show the database
sudo lomp db list                                   # every site's database, user and size
sudo lomp db passwd shop.example.com                # a new random password for its database user
sudo lomp credentials shop.example.com              # database / WordPress / SSL details
sudo lomp list                                      # all sites in a table
sudo lomp logs shop.example.com                     # tail access and error logs
sudo lomp fix-owner --all                           # files uploaded as root to each site's user, now
                                                    # (it happens by itself within a minute)
sudo lomp backup --all --encrypt                    # back up every site
sudo lomp restore shop.example.com --file /var/backups/server-setup/shop.example.com/....tar.gz
sudo lomp renew-ssl --all                           # renew every certificate
sudo lomp ssl                                       # which certificates exist, days left, and
                                                    # whether renewal is automatic (changes nothing)
sudo lomp renew-ssl --missing                       # a certificate for every site that has none
sudo lomp ssl test                                  # rehearse the renewals (certbot renew --dry-run)
sudo lomp ssl fix                                   # switch automatic renewal back on
sudo lomp panel                                     # open the WebAdmin panel for your address
sudo lomp self-update                               # pull the latest code and apply what it
                                                    # changes on the server (no packages)
sudo lomp optimize                                  # re-measure hardware, show a diff, re-tune
sudo lomp harden --all                              # limit what a PHP shell in a site can do
sudo lomp scan --all                                # look through every site's PHP for a shell
sudo lomp php-cleanup                               # undo an "apt-get install lsphp83*": purge the
                                                    # compiler, debug symbols and the rest it added
                                                    # beyond lomp's own PHP packages (asks first)
sudo lomp update                                    # safe package update, ordered restarts, and
                                                    # what a newer release changes (scheduled
                                                    # tasks, site homes and logs)
sudo lomp remove old.example.com --keep-db          # remove a site, keep its database
sudo lomp rename example.com example.net            # the site under another domain name; the old
                                                    # one sends everything on with a 301
sudo lomp redirect add old-name.com example.net --www   # a name that only redirects, no site
```

Global flags work everywhere: `--yes`, `--dry-run`, `--quiet`, `--verbose`, `--no-color`,
`--json` (for `status`, `doctor`, `list`), `--non-interactive`.

`sudo ./setup.sh help` prints the complete reference.

### Updating lomp

```bash
sudo lomp self-update     # pull main into /opt/lomp, install it, and apply what it changes
sudo lomp update          # upgrade the packages too (and apply the same changes)
```

`self-update` hands over to the copy it just installed, which applies what the new release
changes on a server an older one set up: scheduled tasks, site homes closed to the other sites'
users, site logs. No package is touched; that is `update`. A release older than 1.0.68 does not
do this last step by itself: on such a server run `sudo lomp update` once after `self-update`.

The version is `1.0.<n>`, where `n` counts the commits on `main` since 1.0.0. Every change that
reaches `main` raises it, and nobody edits it by hand. `self-update` shows the step, e.g.
`Checkout updated: 1.0.60 (a48af2a) -> 1.0.63 (5c1e2f0)`, and `lomp --version` prints the
installed version. A copy whose commits cannot be counted (a shallow clone, or a directory that is
not a git checkout) shows `1.0.x`.

### Site options worth knowing

| Flag | Effect |
|---|---|
| `--www` | Also serve `www.<domain>` and redirect it to the apex (`--www-primary` flips the direction) |
| `--php 8.2` | Use another LSPHP version for this site; it is installed on demand |
| `--memory 512M --upload 128M` | Per-site PHP limits, applied in the vhost |
| `--php-children N` | LSAPI workers for this site |
| `--proxy HOST:PORT` | Reverse proxy mode, TLS terminates in OpenLiteSpeed; WebSocket upgrades (Socket.IO, ws) are passed through on every path, no extra flag needed |
| `--wordpress` | Download and install WordPress, create the database, enable LiteSpeed Cache, register WP-Cron |
| `--no-db` | Skip the database. Every site otherwise gets its own MariaDB database and user — `example.com` becomes `example_db` / `example_user` with a 32-character random password, printed once when the site is created and available afterwards from `credentials` |
| `--wildcard` | Also request `*.<domain>` over DNS-01 (needs a stored Cloudflare API token) |
| `--staging` | Use the Let's Encrypt staging CA while you are testing |

### Moving a site to another domain name

```bash
sudo lomp rename example.com example.net     # item 26 in the menu does the same
```

A site is its name here: its home, its Linux user, its log directory and its certificate are
all called after it. `rename` moves the site to the new name as it is and leaves the old name
behind as a redirect:

- `/home/example.com` becomes `/home/example.net` - renamed in place, nothing is copied - and
  the user `example_com` becomes `example_net` with the same uid, so no file changes its owner.
  Logs, PHP settings, hardening, path proxies and backups follow.
- The database keeps its name, its user and its password: nothing in `wp-config.php` or in an
  application's own configuration has to change for it.
- `example.net` gets a certificate of its own. Point its DNS at the server **before** the
  rename and it is there right away; otherwise the site answers over HTTP only until
  `lomp renew-ssl example.net`, which a WordPress that expects HTTPS does not take well.
- A WordPress has the addresses in its database rewritten (`wp search-replace`, serialized data
  included): `//example.com` and `//www.example.com`, and the old home directory where a plugin
  stored it as a path. Mail addresses at the old domain are left alone. `--no-search-replace`
  skips this.
- `example.com` (and `www.` if the site had it) keeps its certificate and answers every request
  with a `301` to the same path on the new name, over HTTP and HTTPS. Keep its DNS pointing at
  the server for as long as that should work. `--no-redirect` drops the old name instead.

A safety backup is written first, and the site is away for about a minute. If anything fails
before the site answers under its new name, everything is put back under the old one. At the
end the command lists the configuration files in the document root that still mention the old
name (an address or the old path in `wp-config.php`, `.htaccess`, `.env`, ...): those are yours
to look at.

A site that runs a Node.js application is moved too. Its PM2 service is named after the user and
runs out of the home, so it is taken down before the move and set up again afterwards the way
a restore does it: dependencies installed again, the build run, PM2 started under the unit of
the new user, scheduled jobs back in cron. The port and the variables stay; a variable that
still mentions the old domain is pointed out (`lomp app env example.net list`).

Mail moves with the site. A site whose mail was switched on for the site itself has every
mailbox taken to the new domain - `info@example.com` becomes `info@example.net`, with its mail,
its password and its quota - and every alias copied there. At the old domain each address is
left as an alias of its new one, so mail to an old address still arrives and the mailbox may
still send as it; `example.com` stays a mail domain for that, with the DKIM key its earlier
mail was signed with (keep its MX pointing here). People sign in with their new address from
then on, in their mail program and in the webmail, whose address book and settings follow.
For mail from outside to reach `@example.net` directly, its DNS needs the usual records:
`lomp mail dns example.net` (written into Cloudflare by itself when a token is stored). A
mailbox whose new address is already taken stays where it is and is named.

`--keep-mail` leaves the mail at the old domain instead: `example.com` becomes a mail domain of
its own with everything as it was, and the site starts without mail under its new name. That is
also what happens to mail that is switched off, and to a domain whose mail was added on its own
(`mail domain add`) - that mail was never the site's.

A site that is registered under a name which is no domain name - `shop_old`, `staging`:
`restore` made such sites until 1.0.87 - gets its domain name the same way, with
`lomp rename shop_old shop.example.com`. Nothing could ever ask the server for such a name, so
no redirect is left under it. A WordPress never said that name either: what is rewritten in its
database is the name WordPress itself gives as its address - the one the site had where its
archive was made - and nothing when that is the new name already.

A redirect is also available on its own, for a name that never was a site here:

```bash
sudo lomp redirect add old-name.com example.net --www   # 301, path and query string kept
sudo lomp redirect list
sudo lomp redirect del old-name.com
```

It gets no Linux user and no files - only a virtual host and, once its DNS points here, a
certificate (run `redirect add` again to fetch it). It follows its target: `https://` once the
target has a certificate, `www.` in front when that is the target's main name. `lomp list`,
`lomp ssl` and `lomp doctor` show redirects next to the sites, and `add` refuses a name that
redirects until `redirect del` frees it.

### Bringing sites from another server

```bash
sudo lomp import root@203.0.113.10                 # item 29 in the menu does the same
sudo lomp import root@203.0.113.10 --list          # only show what is there
sudo lomp import root@203.0.113.10 --only example.com,shop.example.com
sudo lomp import root@203.0.113.10 --all --no-create      # only the sites that already exist here
sudo lomp import root@203.0.113.10 --path /usr/local/lsws/Example/html --as example.com
```

`import` logs in to the other server over SSH - ssh asks for the password itself, once; `--key
FILE`, `--password-file FILE` and `--port N` are there for the rest - and looks at what it
serves: the virtual hosts of an OpenLiteSpeed (lomp, CyberPanel, a plain install), by the names
its listeners map to them, and the directories under `/home`, `/var/www`, `/www/wwwroot` and
`/var/www/vhosts` that are named after a domain. It lists them with their size, what they are
(static, PHP, WordPress), the database a WordPress names and whether a site of that name is
here already, and asks which ones to bring. Then, for each:

- a site that is not here yet is added, without a certificate - the DNS still points to the
  other server. With `--no-create` such a site is left out instead: add the ones you want
  yourself first, the way you want them, and only those are filled;
- a site that is here already is backed up first (`pre-import` in its backups); files with the
  same name are replaced, the others stay;
- the files are packed there and unpacked into `public_html` here by the site's own user, so
  nothing arrives owned by root. A WordPress page cache (`wp-content/cache`) is left behind;
- the database of a WordPress is dumped there - as the account you logged in with, or with the
  login in its `wp-config.php` when that account cannot open it - checked for being complete,
  and imported into the site's database here; `wp-config.php` then gets the name, user and
  password of the database on this server. Tables in MySQL 8's `utf8mb4_0900_ai_ci` become
  `utf8mb4_unicode_520_ci`, which MariaDB has;
- a WordPress whose own address is `www.<domain>` gets a site that answers there.

A directory that is served under no name - `/usr/local/lsws/Example/html`, `/var/www/html`, a
user's `public_html` - is listed apart; `--path DIR --as DOMAIN` brings it as that domain, and
`--db NAME` with it the database of an application that is no WordPress (its own configuration
file is yours to point at the new database: `lomp credentials <domain>`).

**The mailboxes of a domain come with it** when this server runs mail (`install --with-mail`)
and you logged in there as root:

```bash
sudo lomp import root@203.0.113.10 --only example.com               # the site and its mailboxes
sudo lomp import root@203.0.113.10 --only example.com --only-mail   # the mailboxes alone
sudo lomp import root@203.0.113.10 --all --no-mail                  # the sites alone
```

- the addresses are the ones the other server's Dovecot knows (`doveadm user '*'`), and the mail
  is what lies in each one's Maildir - other mail stores (mbox, mdbox) are not read;
- mail is switched on for the domain here with its DNS left alone: no MX, SPF or DKIM record is
  written, so mail goes on arriving at the other server until you move it (`lomp mail dns
  <domain>` shows the records, and writes them with `--apply`);
- a mailbox keeps the password it had when the other server is a lomp or a CyberPanel, whose
  password hashes can be read. Anywhere else, and for a password that was kept in the clear,
  it gets a new one, printed once at the end and never logged;
- the mail is unpacked beside the mailbox by the mail user and merged into it: messages that
  are not here yet are added with their folders and flags, nothing here is deleted, and a
  second run adds only what is new. A mailbox larger than half the usual quota gets twice
  its size as quota;
- a domain that has mailboxes there and no site is listed as `mail` and becomes a mail domain
  here; on a server installed for mail alone that is what every chosen domain becomes, and
  its site stays where it is;
- the domain's aliases and forwarders come too, catch-alls included: lomp's own, CyberPanel's
  (`e_forwardings`), and the ones in the text files Postfix looks its virtual aliases up in
  (`virtual_alias_maps`; aliases kept in a database of another panel are not read). An alias
  this server already has for the domain stays as it is here. An address that is a mailbox
  here is not made an alias as well - "keep a copy and forward" on the other server is one of
  those - and the run names each one with where its mail went there, for you to decide;
- a domain that only forwards - aliases and no mailbox - becomes a mail domain here like one
  with mailboxes;
- sieve filters and what a webmail keeps (address books) are not copied.

**A site that is added gets the PHP version it runs there** - read from the other server's
OpenLiteSpeed configuration, so known for a lomp, a CyberPanel or a plain OpenLiteSpeed and not
for a site found by its directory alone - when this server has that LSPHP or can install it;
otherwise it gets the usual one and the run says so. A site that is here already keeps its own,
and the run names the difference.

**Its cron jobs come with it** and run here as the site's own user, never as root:

- every line of the crontab of the account that owns the site's files, when the site lies in
  that account's home (CyberPanel, a lomp, a user's `public_html`);
- from every other crontab - root's, `/etc/crontab`, the files in `/etc/cron.d` - the lines
  that name the site's directory or its domain. What lomp schedules itself on a server it
  runs is left out;
- the site's directory there becomes its directory here, and an LSPHP named by its version
  (`/usr/local/lsws/lsphp74/bin/php`) becomes the site's own PHP; anything else in a command
  is taken as it is, so a job that reaches for a path outside the site will fail here;
- `@reboot` lines and lines cron here could not read are not taken;
- **they go on running on the other server too.** Until the site has moved, a job runs in both
  places against two copies of the site - take a job that sends mail or charges somebody out
  on one side first. `sudo lomp import cron <domain>` lists what a site was given and
  `--clear` removes it; `--no-cron` brings a site without them. A second import replaces the
  list with what the other server has then; `rename` and `remove` take the jobs along.

The other server is only read. Certificates are not copied, and neither is
anything outside a site's document root. The sites answer over HTTP here until the DNS of a
domain points to this server; then `sudo lomp renew-ssl <domain>` gets its certificate. Running
the import again for a site brings what changed in the meantime - worth doing once more just
before the DNS moves, and once more for the mail (`--only-mail`) after the MX has moved.

### WordPress into a site that is already there

`add --wordpress` installs WordPress whole. To do the installation yourself in the browser, add
the site as a PHP site and let lomp fetch the files:

```bash
sudo lomp wordpress example.com     # item 25 in the menu does the same
```

It downloads `https://wordpress.org/latest.zip`, checks it against the checksum wordpress.org
publishes, and unpacks it straight into `/home/example.com/public_html` as the site's own user:
every file is `example_com`'s, directories 0755 and files 0644, so WordPress can write its
`wp-config.php` and update itself. Then it prints the address to open and the site's database
login, which the installer asks for.

A document root that already holds something is asked about first: WordPress's files replace the
ones with the same name, the rest stays, and what root uploaded there is handed to the site's
user first (as `fix-owner` does). A site that already has a `wp-config.php` is left alone.

WordPress's installer ends by giving its new `wp-config.php` the mode 0666. lomp closes it to
0640 - what `add --wordpress` gives it - within a minute: the check cron runs every minute
looks at the `wp-config.php` in the document root of every PHP and WordPress site, whichever
way WordPress got there, and closes one that carries more than 0640, as the site's user. One
that root uploaded (WinSCP logged in as root) has become the site's a moment earlier, with the
rest of the upload (see `fix-owner` above); with that switched off it stays root's and open,
because closed as root's, PHP could no longer read it. A file you closed further yourself
(0600) is left as it is.

### .htaccess

PHP and WordPress sites read `.htaccess`, within two limits that come from OpenLiteSpeed:

- Only rewrite rules count (`RewriteEngine`, `RewriteBase`, `RewriteCond`, `RewriteRule`).
  `Header`, `php_value`, `Deny from all`, `Require`, `Options`, `AuthType` and the like are
  ignored. lompstack sets the security headers, the PHP limits and the file protection in the
  virtual host instead, and WordPress sites refuse to run any PHP file under
  `wp-content/uploads`.
- A `.htaccess` is read when OpenLiteSpeed loads, not when it changes. A cron job checks every
  minute and reloads OpenLiteSpeed once a `.htaccess` has arrived or changed - a new site
  uploaded or unpacked with its original file dates, a WordPress permalink setting, a plugin, a
  hand edit - so a change takes effect within about a minute. A reload
  restarts the server, which pauses every site for a moment; `doctor` lists a change that is
  still waiting.

Static and Node.js sites do not read `.htaccess` at all.

### Path proxies

Publish an application under a path of any site, next to WordPress, PHP or static files:

```bash
sudo lomp proxy add example.com /api/ 127.0.0.1:3001   # example.com/api/... -> the app
sudo lomp proxy list                                   # every path proxy, and whether its app answers
sudo lomp proxy remove example.com /api/
```

OpenLiteSpeed forwards the full path, prefix included, so the application must serve its
routes under `/api`. WebSocket upgrades on that path are passed through as well. The rest of
the site is untouched, a failed configuration test rolls the change back, and `doctor` warns
when nothing listens on a target.

### What a proxied application is told about the visitor

This holds for a reverse proxy site (`--proxy`), a path proxy and a Node.js site alike. The
application's connections all come from OpenLiteSpeed, so the peer address it sees is always
`127.0.0.1`; the visitor is in the request headers:

| Header | What OpenLiteSpeed sends |
|---|---|
| `X-Forwarded-For` | The visitor's address as the **last** entry. Anything the client sent under that name stays in front of it, so the first entry is whatever the client likes. With Cloudflare mode on, the last entry of a request that came through Cloudflare is the visitor Cloudflare names, not Cloudflare's own address. |
| `X-Forwarded-Proto` | `https` when the connection to OpenLiteSpeed is TLS; over plain HTTP nothing is added. A value the client sent stays in front here too (`https, https`, or `http, https`). |
| `X-Forwarded-Host` | The requested host name, after anything the client sent under that name. Not sent with a WebSocket upgrade. |
| `Host` | The site's name, as requested. |
| `X-Real-IP`, `Forwarded`, `CF-Connecting-IP` | Never set by OpenLiteSpeed and passed on as the client sent them. |

What follows from it:

- Take the visitor's address from the last entry of `X-Forwarded-For`. In Express that is
  `app.set('trust proxy', 'loopback')` and then `req.ip`; other frameworks have the same
  setting under "trusted proxies", with `127.0.0.1` as the one proxy to trust. Not
  `app.set('trust proxy', true)`: that takes the first entry, the one the client writes
  (seen with Express 4 and 5: `req.ip` was the forged address). Without the setting `req.ip`
  is `127.0.0.1` for everyone.
- Do not read `X-Real-IP` or `Forwarded`: a visitor can write anything there. The same goes
  for `CF-Connecting-IP`, unless the origin is closed to everyone but Cloudflare (see
  "Closing the origin").
- `X-Forwarded-Proto` says `https` truthfully on a TLS connection, but a client on plain HTTP
  can claim it as well, and so can a client claim a host in `X-Forwarded-Host`. A site with a
  certificate sends plain HTTP to HTTPS before the application is asked, except for requests
  that carry `X-Forwarded-Proto: https` (that is how Cloudflare's "Flexible" mode gets
  through). Build links from `Host` or from a name you configure, not from `X-Forwarded-Host`:
  with `trust proxy` set, Express's `req.hostname` is that header's first value, so a request
  sent with `X-Forwarded-Host: evil.example` gets `evil.example` there. `req.headers.host`
  stays the site's name.
- A WebSocket upgrade (`ws://` and `wss://`, on the site and on a path proxy) carries the
  same `X-Forwarded-For` and `X-Forwarded-Proto` as any other request. It always travels
  over HTTP/1.1: OpenLiteSpeed 1.9.2 announces WebSockets neither over HTTP/2 nor over HTTP/3
  (the extended CONNECT of RFC 8441 and RFC 9220) and refuses one that is tried anyway, so a
  browser opens a connection of its own for `wss://`, next to the HTTP/2 or HTTP/3 one that
  carries the pages.
- OpenLiteSpeed has no setting that removes or replaces these headers on the way to the
  application (tried on 1.9.2), so the rules above are the application's to keep.
- A request made on the server itself (`curl -H 'Host: example.com' http://127.0.0.1/`) arrives
  without `X-Forwarded-For`: OpenLiteSpeed leaves it out for its own machine. Test from
  another machine before concluding the header is missing.

How this was measured: on OpenLiteSpeed 1.9.2, from a client with an address of its own, over
HTTP/1.1, HTTP/2 and HTTP/3. The Cloudflare lines were measured with Cloudflare imitated, not
through Cloudflare itself: Cloudflare mode switched on, the test client's address marked as a
trusted proxy, and the headers Cloudflare sends (`CF-Connecting-IP`, `X-Forwarded-For`,
`X-Forwarded-Proto`) written by hand. A request that really came through Cloudflare's edge
has not been looked at.

### Node.js applications (PM2)

A Node.js site is a reverse proxy site whose application lompstack runs for you with PM2:

```bash
sudo lomp add app.example.com --node                  # takes a free port from 3000 up
# put the code into /home/app.example.com/app (owned by the site user), then:
sudo lomp app deploy app.example.com                  # npm ci (or pnpm / yarn), build, restart
sudo lomp app list                                    # status, CPU, memory, uptime, restarts
sudo lomp app logs app.example.com                    # follow the application's output
sudo lomp app restart app.example.com
printf '%s' 'the-secret' | sudo lomp app env app.example.com set API_KEY
sudo lomp app env app.example.com import-db           # DB_* and DATABASE_URL of the site's database
sudo lomp app set app.example.com --script dist/main.js --memory 512M
sudo lomp app deploy-key app.example.com              # a read-only key for a private repository
sudo lomp app deploy app.example.com --git git@github.com:owner/repo.git --branch main
```

`app deploy --git` clones into the empty app directory the first time; later deploys fetch the
branch and reset the tracked files to it, and leave files git does not track (uploads, build
output) alone. Dependencies are reinstalled only when `package.json` or the lockfile changed,
the build runs with a memory limit so it cannot push the database into the OOM killer, and the
output of the last deploy is kept with secrets masked (`app status` shows where). A repository
URL with a password or token in it is refused: use the deploy key.

- Every Node.js site runs its own PM2 daemon as the site's Linux user, started at boot by
  `pm2-<site>.service`. Nothing runs as root, and one site cannot touch another site's
  processes. The price is roughly 50-80 MB of memory per Node.js site.
- The application gets its port in `PORT` and must listen on it; 127.0.0.1 is enough.
  `npm start` is the default. When that script is plain `node <file>`, PM2 runs node itself,
  so a `--memory` limit watches the application rather than npm.
- Environment values are stored root-only and handed to the application through PM2. They
  are never written to the log, and `env set` never takes them from the command line.
- WebSocket upgrades are passed through. Behind OpenLiteSpeed, Express needs
  `app.set('trust proxy', 'loopback')`: `req.ip` is then the visitor's address and
  `req.protocol` is `https` on a TLS connection. See "What a proxied application is told
  about the visitor" above for what exactly arrives, and what not to rely on.

#### Workers and scheduled jobs

Background processes of an application run under the same PM2, as the same user and with the
same environment:

```bash
sudo lomp app worker app.example.com add queue --start "node worker.js"         # queue consumer, bot
sudo lomp app worker app.example.com add ws --start "node ws.js" --port 3101    # one that listens gets PORT
sudo lomp app worker app.example.com add cleanup --cron "*/15 * * * *" --start "npm run cleanup"
sudo lomp app worker app.example.com list                                       # status, restarts, schedules
sudo lomp app worker app.example.com run cleanup                                # run a job now
sudo lomp app restart app.example.com --process queue                           # one process at a time
sudo lomp app logs app.example.com --process queue
```

- A worker that keeps crashing does not take the web process down, and `doctor` reports it.
- A scheduled job is started by cron, not by PM2. A run never overlaps the previous one, is
  stopped after `--timeout` (default 1 hour), and writes to `~/.pm2/logs/<name>-job.log`. The
  schedule is checked before it is written: a single malformed line makes cron ignore the whole
  file, backups and certificate renewals included.
- `app stop` and `app start` act on the application and all its workers; `--process web` or
  `--process <name>` narrows that down. A deploy restarts what runs and leaves what was stopped
  on purpose stopped.
- Secrets belong in `app env`, not in `--start`: a start command shows up in every process list.

---

## WebAdmin access

The OpenLiteSpeed panel is a login form on port 7080. Leaving it open to the internet is an
invitation, and pinning it to one IP address does not work for the many administrators whose
home connection gets a new address every day. So there are three modes, and the safe one is
the default.

| `--admin-access` | Behaviour | Good for |
|---|---|---|
| `tunnel` *(default)* | Listener bound to `127.0.0.1`, no firewall port. Reached over an SSH tunnel. | Everyone, especially dynamic IPs |
| `ip` | Only the address given with `--admin-ip` may connect. | A real static address |
| `open` | Anyone may connect. You get a warning. | Lab machines only |

```bash
sudo ./setup.sh install                          # tunnel (default)
sudo ./setup.sh install --admin-ip 203.0.113.5   # implies --admin-access ip
sudo ./setup.sh install --admin-ip auto          # takes the IP of your current SSH session
sudo ./setup.sh install --admin-access open      # exposed, warned about
```

For day-to-day use with a dynamic IP, open the port only while you need it:

```bash
sudo lomp panel                 # opens it for your current SSH address for 60 minutes
sudo lomp panel --minutes 15    # shorter window
sudo lomp panel --ip 1.2.3.4    # somebody else's address
sudo lomp panel status          # current state and the SSH tunnel command
sudo lomp panel close           # shut it again right now
```

Bare `panel` prints the URL, the user and the password, so you can paste the address
straight into a browser. Under the hood it rebinds the listener, adds one firewall rule for
that single address, and schedules a systemd timer that closes everything again on its own.
If your address changed since yesterday it does not matter: it is read from the SSH session
you are already in.

## How a site is laid out

```
/home/<domain>/               0710  <user>:<user>     one Linux user per site, nologin shell
├── public_html/              0755  document root
├── private/                  0700  sessions, temp uploads, secrets - never served
├── logs -> /var/log/lomp-sites/<domain>/   access.log, error.log with PHP's errors
├── backups/                  0700
├── app/                      proxy mode only: your Node/Python application
└── .pm2/                     0700  Node.js sites: PM2 state, ecosystem file, logs, job scripts
```

PHP runs as the site's own user through a per-vhost LSAPI processor, and the home is closed to
every other account (0710; an ACL lets OpenLiteSpeed's `nobody` pass through to serve
`public_html`), so one compromised site cannot read another site's files - not even the
world-readable ones, such as a `config.php` with a database password in it. Servers set up by
an older release had homes at 0711, which let another site's PHP in; `self-update` or `update`
closes them, and `doctor` names a home that is open. Directory listing is off, and requests for dotfiles,
`.git`, `.env`, `*.sql`, `*.bak` and `wp-config.php` are refused. A WordPress installed in the
browser leaves its `wp-config.php` at 0666: within a minute lomp closes it to 0640, in every PHP
and WordPress site, once it is the site's own - which what root uploads becomes within the
same minute. `doctor`, and the daily health check with it, warns about one that its group or
others may still write to, and about a site whose uploads could not be handed over.

### What a PHP shell in a site can do

Separate users keep one site out of another's files. `lomp harden` limits what code that got
into a site can do from there. New sites start with it; for the sites an older release made, run
`sudo lomp harden --all` once (`doctor` says which are left).

- **No process execution from PHP.** `exec`, `shell_exec`, `system`, `passthru`, `proc_open`,
  `popen`, `pcntl_exec`, `putenv` and `dl` are disabled for the site's web PHP, and
  `open_basedir` keeps it to the site's home, its logs and `/tmp`. The site's `lsphp` reads this
  from its own ini directory (`/etc/lompstack/php/<domain>/`, root's, set through
  `PHP_INI_SCAN_DIR`): `disable_functions` is only read when PHP starts, so a
  `phpIniOverride` line would show the value and disable nothing. WP-CLI and cron jobs use the
  command-line PHP and are not affected. An application that needs these functions gets them
  back with `sudo lomp harden <domain> --allow-exec`.
- **No scripts in upload directories.** A request for a `.php`, `.phtml` or `.phar` below
  `uploads/`, `upload/`, `files/`, `media/`, `cache/`, `tmp/` or `temp/` is answered 403, so an
  uploaded script never runs (`--allow-upload-php` turns it off for a site; a WordPress site
  always has it for `wp-content/uploads`).
- **Site firewall.** A site's user reaches only DNS, the web server, MariaDB, Redis and the
  site's own application on this machine - not the WebAdmin panel, SSH, another site's
  application or anything else that listens locally. It is two iptables chains of lomp's own
  beside UFW's, loaded at boot by `lomp-site-firewall.service`; `lomp harden --firewall off`
  removes it. Connections to the internet are not restricted.

`harden` checks each site before and after, and names one that answered before and no longer
does. `sudo lomp harden status` shows what is set. It narrows what a shell can do; it does not
find or remove one.

### Looking for a shell

`sudo lomp scan example.com` (or `--all`; item 24 in the menu) reads a site's scripts - `.php`,
`.phtml`, `.phar`, `.inc`, and `.htaccess`, `.user.ini` and icons beside them - and lists the
files to open, with the line and the text found there. It changes nothing.

- **STRONG**: `eval` of decoded data (`eval(base64_decode(...))`) or of what the request sent, a
  command or an `include` made of what the request sent, a function named by the request, PHP
  code in an icon, the name of a known shell.
- **LOOK**: packed or hidden code (decoding inside decoding, a long encoded string, `\x`
  escapes, `chr()` chains), a script in an upload directory, request data written to a file,
  `auto_prepend_file` in `.htaccess` or `.user.ini`.

`--wide` also lists every file that uses `eval`, `base64_decode`, `exec`, `system`,
`shell_exec`, `passthru`, `popen`, `proc_open`, `assert` or `create_function`; plugins use them
too, so on a WordPress site that is a long list. A match is a reason to open the file, not a
verdict, and a file without one is not proven clean: the scan knows the common shapes, not
every way to hide code.

The logs themselves are in `/var/log/lomp-sites/<domain>/` (0750 root:`<user>`, rotated daily
by logrotate, 14 days kept), and `logs` in the home is a link there. OpenLiteSpeed opens a
site's logs as root, so no directory on the way to them may belong to the site user, who owns
the home: a `logs/` kept in it could be swapped for a link, and root would create and hand over
log files wherever that pointed. The site user can read its logs but not change them, and an
ACL lets OpenLiteSpeed's worker processes (`nobody`) in to write them. Nothing run as root goes
through the link, so a site user who replaces it only changes where its own shortcut leads.
Servers set up by an older release kept the logs in the home; `sudo lomp update` moves them,
with their history, and puts the link in their place. Until it has, `self-update` alone leaves
them where they are, and logrotate and fail2ban keep reading them there. The logs now take up
space on the filesystem that holds `/var/log`, not the one with `/home`.

---

## Fixed paths

| Path | Contents |
|---|---|
| `/root/.server-setup/` | State and credentials, mode 0700 (`manifest.json`, `domains/<domain>/…`, archives) |
| `/home/<domain>/` | Site files |
| `/var/log/lomp-sites/<domain>/` | The site's `access.log` and `error.log` (`/home/<domain>/logs` links here) |
| `/usr/local/lsws/conf/vhosts/<domain>/` | Generated vhost configuration |
| `/usr/local/lsws/logs/` | OpenLiteSpeed's own logs (the WebAdmin's are in `admin/logs/`), the server log written at NOTICE rather than the package's DEBUG. OpenLiteSpeed rolls them at 10 MB; a daily job deletes the rolled files once they are older than 14 days |
| `/etc/sysctl.d/99-production-server.conf` | Kernel tuning |
| `/etc/security/limits.d/99-production-server.conf` | Open file and process limits |
| `/etc/mysql/mariadb.conf.d/60-production-tuned.cnf` | MariaDB tuning |
| `/etc/fail2ban/jail.d/server-setup.conf` | Fail2ban jails |
| `/etc/cron.d/server-setup` | All scheduled tasks, in one place |
| `/etc/letsencrypt/renewal-hooks/deploy/99-server-setup-ols.sh` | Certificate deploy hook |
| `/var/log/server_setup.log` | Operation log, mode 0600, secrets masked |
| `/var/backups/server-setup/` | Local backups |

These names are part of the public contract and stay stable across releases.

---

## Cloudflare

Enable it globally at install time, or per site:

```bash
sudo lomp install --cloudflare
sudo lomp add example.com --cloudflare
```

The published Cloudflare ranges are downloaded and marked as trusted proxies, and only
those ranges are allowed to set the client IP header. Access logs and Fail2ban then see
real visitor addresses instead of Cloudflare's. The list refreshes weekly; if a download
fails the previous list is kept and you get an alert.

With an API token you also get DNS-01 certificates (including wildcards) for proxied
domains, and Fail2ban bans are mirrored to the Cloudflare edge:

```bash
printf '%s' "$CF_TOKEN" | sudo lomp install --cf-api-token -
```

`-` reads the token from standard input. Passing it as `--cf-api-token YOUR_TOKEN` also
works, but then it sits in the process list while the command runs, where every user of the
server can read it.

The token needs `Zone → DNS → Edit` and `Account → Firewall Access Rules → Edit`, and is
stored with mode 0600. It never reaches a command line afterwards either: API calls get it
through curl's configuration on stdin, and Fail2ban's ban action reads it from a 0600 header
file. Set your Cloudflare SSL mode to **Full (strict)** once certificates are issued:
`sudo lomp ssl` lists every site's certificate and says when that is safe.

### Closing the origin

With the sites behind Cloudflare, anyone who learns the server's address can still reach it
directly and walk around the edge:

```bash
sudo lomp firewall --web-cloudflare-only   # 80 and 443 answer Cloudflare's ranges only
sudo lomp firewall status
sudo lomp firewall --web-open              # undo it
```

Every site then has to be proxied (orange cloud) or it stops answering. SSH, the mail ports and
the WebAdmin port are untouched. Because port 80 no longer answers Let's Encrypt, certificates
switch to DNS-01, which is why this needs the API token; the weekly IP refresh keeps the rules
in step with Cloudflare's ranges.

There is no bundled WAF or ModSecurity: that job belongs to the edge.

---

## Mail

A mail server for the sites on this machine - or for domains whose sites are somewhere else, on
a server that does nothing but mail: Postfix for SMTP, Dovecot for IMAP and delivery, Rspamd
for spam filtering and DKIM. It is opt-in and changes nothing about the web stack.

```bash
sudo lomp install --with-mail --mail-hostname mail.example.com
sudo lomp mail status        # what runs, reverse DNS, whether outgoing port 25 is open
sudo lomp mail test
```

Three things have to be true before mail leaves this server, and only two of them are
lompstack's to arrange:

1. **A name of its own.** `mail.example.com` needs an A record pointing at this server. It is
   the name in HELO and in the certificate, and it stays the same however many sites you add.
2. **A PTR record.** Your provider (OVH, Hetzner, Contabo …) sets the reverse name of the
   server's IP to exactly that name. Nothing on the server can do this for you; `lomp mail
   test` tells you whether it is right.
3. **Outgoing port 25.** Many providers block it on new servers. `lomp mail test` finds out,
   and where it is blocked you can send through somebody else's server instead:

```bash
printf '%s' "$PASS" | sudo lomp mail relay set --host smtp.example.net --port 587 \
    --user you@example.net --spf-include spf.example.net
sudo lomp mail relay off
```

The password is read from standard input and lands in one 0600 file that Postfix reads; it is
never an argument and never reaches the log. Mail still carries this server's own DKIM
signature when it goes through a relay.

`--spf-include` is the name your provider tells you to put in SPF - `amazonses.com` for SES,
`sendgrid.net` for SendGrid - and without it no include is published at all. lomp does not
guess it: an include pointing at a name that has no SPF record makes the *whole* record a
permerror, so a wrong guess is worse than nothing. Changing the relay changes what every mail
domain's SPF record has to say, and lomp prints the domains to publish again.

The relay's certificate is verified against the name you gave (`--tls secure`, the default). A
relay whose certificate no public authority signed needs `--tls encrypt`, which requires TLS but
checks nothing - anything that can answer for that name is then handed the credentials.

What the configuration insists on:

- **Port 25 offers no way to log in**, and no message is relayed to a third party without an
  authenticated sender - not even from the server itself. A site that gets broken into can
  open `127.0.0.1:25`, so "it came from this machine" is not a reason to send anything.
- **Sites do not use PHP `mail()`.** Only root may hand a message to `sendmail`; a site sends
  through SMTP with the credentials of a mailbox, like any other client.
- **A sender must own the address it claims**: submission ports check the login against the
  address in `MAIL FROM`.
- **A Linux account is not a mailbox.** Dovecot's system-user login is switched off; mailboxes
  live in one file of BLF-CRYPT hashes, and mail itself under `/var/vmail`, owned by a user no
  site belongs to.
- **Only four ports answer**: 25, 465, 587 and 993. There is no plain-text 143 and no
  cleartext submission port, not even on loopback — Dovecot treats a local connection as
  already secure, which would make one a password oracle for every user of the machine. They
  arrive with the webmail, which needs them, and with the rule about who may open them.
- **The spam filter has no port either.** Its milter is a socket whose group holds Postfix and
  Rspamd and nobody else; its web interface is a socket only root and Rspamd can open. Whoever
  speaks the milter protocol decides which account a message comes from, and that is what a
  DKIM signature is based on.

### Giving a domain its own mail

```bash
sudo lomp mail enable example.com --mailbox info --quota 2G   # or: lomp add example.com --mail
printf '%s' "$PASS" | sudo lomp mail box add sales@example.com
sudo lomp mail alias add contact@example.com info@example.com
sudo lomp mail dns example.com            # what to put in DNS
sudo lomp mail dns example.com --check    # and whether it is there yet
```

Enabling mail for a domain creates its DKIM key, asks for a certificate for `mail.example.com`,
points `postmaster@`, `abuse@` and `dmarc@` at the first mailbox, and prints the records to
publish: an A record for `mail.example.com`, an MX, one SPF record, the DKIM key, and a DMARC
record that starts at `p=none` so you can read the reports before tightening it. **All of them
are DNS only** — a proxied MX or mail name cannot receive mail.

A mailbox password is read from standard input or a hidden prompt and only its hash is stored;
nothing on the server can print it back. Mailboxes are reached at `mail.<domain>` — IMAP on 993,
submission on 465 or 587, user name the full address — and `lomp credentials <domain>` shows the
settings. `lomp mail disable` stops both delivery and login for a domain while keeping every message on
disk — enabling it again restores the mailboxes with the passwords they had. Removing the site
removes its mailboxes, its mail, its key and its certificate, whether or not mail was switched
off first; the safety backup does not include mail, and `remove` says so before it asks.

With a Cloudflare API token stored, lomp can write those records itself:

```bash
sudo lomp mail dns example.com --apply                  # writes them into Cloudflare
sudo lomp mail dns example.com --apply --replace-mx     # and takes over another provider's MX
sudo lomp mail disable example.com --dns-cleanup        # removes only what lomp wrote
```

It never touches a record it did not write. A domain that already has an MX pointing at another
provider, or an SPF record of its own, is reported and left alone — two SPF records fail for
every receiver, and moving somebody's mail is not a thing a provisioning script should do by
itself. `lomp mail enable` does the same automatically when a token is there.

### A domain that has its mail here and no site here

A mail domain does not have to be a site. One whose web site lives on another server — or that
has no site at all — is added for its mail alone:

```bash
sudo lomp mail domain add example.com --mailbox info --quota 2G
sudo lomp mail domain list                 # every domain with mail: site or mail only
sudo lomp mail domain del example.com      # the domain and all of its mail, after a last backup
```

It gets what a site's mail gets — DKIM key, certificate for `mail.example.com`, the DNS records,
mailboxes, aliases, webmail, backups — and nothing a site would bring: no Linux user, no home
directory, no virtual host. Its record is kept apart from the sites' registry, so nothing that
walks the sites (logs, fail2ban, the minute jobs) ever meets it. Every other `mail` command
works on it as it does on a site: `mail box add`, `mail alias add`, `mail dns`, `mail webmail on`,
`mail disable`, `mail backup`.

A site that sends mail from another server — a WordPress contact form, say — does it the way
any mail client does: SMTP to `mail.example.com` on 465 or 587, with a mailbox's address and
password. The SPF record lomp publishes names this server alone, so that is also the only way
such mail passes.

### One inbox for several domains

A domain does not need a mailbox of its own. Its addresses can be delivered into one that
exists already, and that mailbox may send as them:

```bash
sudo lomp mail domain add first.com --mailbox me                       # the mailbox: me@first.com
sudo lomp mail domain add second.com --to me@first.com --address info,sales
sudo lomp mail domain add third.com  --to me@first.com --catch-all     # every address of third.com
sudo lomp mail alias add orders@second.com me@first.com                # one more, later
```

`info@second.com` and `sales@second.com` now arrive in `me@first.com`, and so does anything at
all sent to `third.com`. `--to` works with `mail enable` too, for a site. Three things make it
one inbox rather than a pile of forwards:

- **The mailbox may answer as each of those addresses.** Postfix's sender table is built from
  the aliases: an address that is delivered into a mailbox on this server is one that mailbox
  may send as, and no other login may.
- **That mail leaves signed for the right domain.** The message is signed with the key of the
  domain in `From:`, not the domain of the login — which is safe because Postfix has already
  refused every sender address the login does not own, and `From:` has to be of the same domain
  as that sender.
- **The webmail knows the addresses.** Roundcube answers from the identity a message was written
  to, so somebody has to create one per address. A small plugin does it when the mailbox's owner
  signs in, from a list lomp renders out of the aliases. It adds and never removes; `postmaster`,
  `abuse` and `dmarc` are left out, and a catch-all has no address to offer.

A catch-all (`--catch-all`, or `lomp mail alias add @example.com you@first.com`) takes whatever
anybody makes up before the `@`, spam included, which is why it has to be asked for by name. A
mailbox in the same domain keeps its own mail: an address with a line of its own wins.

### A server for mail alone

```bash
sudo ./setup.sh install --mail-only --mail-hostname mail.example.com --email you@example.com
sudo lomp                         # the menu of such a server is the mail menu
```

`--mail-only` installs the same mail server on a machine that hosts no site: one VPS for the
mail of all your domains, with their web sites wherever they already are. OpenLiteSpeed, one
PHP and MariaDB are still installed — the webmail is a web application and keeps its settings
in a database — but they are sized for that and nothing else, and the memory a site's database
would get is left to the mail filter. On such a server:

- a domain is added with `lomp mail domain add`; `lomp add` refuses, and says so;
- `lomp backup --all`, and the schedule that runs it, back up every mail domain — its
  mailboxes with their password hashes, aliases, DKIM key and mail, in one archive each;
- `lomp status`, `doctor`, `update` and `self-update` work as on any server.

Before buying the machine, ask the provider two things: whether **outgoing port 25** is open
(many keep it closed on new servers), and whether you can set the **PTR record** of its
address. Without the first, mail only leaves through a relay; without the second, the large
receivers file it as spam. `lomp mail test` checks both. Give it at least 2 GB of RAM — the
installer refuses mail below 1.8 GB — and Ubuntu 22.04 or 24.04.

The role is kept across re-runs of `install`. `lomp install --role web` turns the machine back
into an ordinary server that may host sites as well; a server that already hosts sites cannot be
declared mail-only.

### Webmail

```bash
sudo lomp mail webmail on example.com
```

That is all of it: `webmail.example.com` serves Roundcube, and people sign in with their full
address and their mailbox password. Every domain shares one installation and one PHP process,
so the twentieth webmail costs a virtual host and nothing else.

It is not a site. The code belongs to root and runs as its own user, which owns no site, no
mail and no key; it reaches Dovecot and Postfix over the loopback only, and the port it submits
through exists for it alone. The release comes from upstream's own tarball, checked against a
pinned signing key before anything is unpacked, and lives in a directory per version with
`current` pointing at the one in use - an update that does not start never gets the symlink.
Roundcube publishes a security release every few weeks, so a daily job takes them:

```bash
sudo lomp webmail status
sudo lomp webmail update          # also runs by itself, 04:30
```

Roundcube's own login limit counts per account and ignores the address a request came from, so
failed logins go to the journal and fail2ban bans by IP - through Cloudflare's API when the
site is proxied, so the ban happens at the edge.

Roundcube keeps things of its own for every mailbox that has signed in - the address book, the
identities and their signatures, saved searches, settings - in its own database, under the
mailbox's address. They go when the mailbox does: `mail box del`, `mail disable --delete-data`,
`mail domain del` and `remove` take them along, so a mailbox made later under the same address
starts empty instead of with the previous owner's contacts. `mail disable` on its own keeps
them with everything else, for `mail enable` to bring back, and a `mail restore` removes none.
They are in no backup: a mailbox that is deleted and then restored from an archive has its mail
again, and an empty address book.

```bash
sudo lomp webmail forget info@example.com   # a mailbox that went before lomp did this by
sudo lomp webmail forget @example.com       # itself, or while the database was down
sudo lomp webmail forget --gone             # every such address: the list, then one question
```

`forget` refuses an address that still has a mailbox, live or switched off.

Which addresses those are is not something to remember: `lomp doctor`, and the daily health
check with it, warns when the webmail still keeps something for an address that has no mailbox
any more, and names the first few. `forget --gone` lists all of them and asks before it removes
them; with `--dry-run` it only lists, and `--yes` answers the question in a script. Both read
the same list, and neither guesses: when the mailbox file is missing or names no mailbox at
all, they say that it cannot be told instead of calling every user of the webmail left over.

### Rotating a DKIM key

A signing key is published in DNS, so it cannot simply be replaced: the moment a new key signs
a message, every receiver still holding the old record fails it. Rotation is therefore two
steps with DNS in between, and lomp does the waiting:

```bash
sudo lomp mail dkim rotate example.com    # a second key, and the record to publish
sudo lomp mail dkim status example.com
```

The domain goes on signing with the old key. An hourly job checks whether the new record has
appeared and whether it really carries the new key; only then does signing move to it. The old
key is kept a week after that, because a message sent an hour ago may still be in somebody's
queue, and is then removed with a note that its record can go too. `--abort` calls the whole
thing off.

### Changing a password from the webmail

People can change their own password in the webmail, under Settings. The webmail does not
write the password file: it hands the address, the current password and the new one to a single
helper through `sudo`, with a rule that allows that one command and nothing else. The helper
checks the current password against the stored hash before it changes anything, so a webmail
somebody has taken over still cannot change a password it does not already know, and it writes
through the same command an operator would use.

### Backing the mail up

A domain's mail is backed up with the site, into an archive of its own next to it:

```bash
sudo lomp backup example.com              # the site, and its mail beside it
sudo lomp mail backup example.com         # only the mail
sudo lomp mail restore example.com        # from the newest mail archive
sudo lomp restore example.com --file <site archive>   # both, in one go
```

Two archives because a mailbox is measured in gigabytes where a site is measured in megabytes:
the site keeps seven copies, the mail keeps two. The copy is made by Dovecot itself rather than
by tar - a message delivered while tar reads a Maildir lands in an archive describing a state
the mailbox was never in - and it holds the mailbox lines with their password hashes, the
aliases, the DKIM key and the mail. Restoring gives back the same passwords and the same DKIM
key, so mail signed before the restore still verifies and nobody has to change a mail client.

A domain whose mail is switched off is backed up too, and this is the one case where the mail
is read straight off the disk: its mailboxes are no longer Dovecot users, so there is nothing
to copy them through - and no message can arrive while it is read, because a domain that is off
is not a destination. The archive says which of the two ways it was taken, and a restore
follows it.

A restore makes a mailbox an exact copy of the archive, so anything that arrived after the
backup is deleted by it. A mailbox that still holds mail is therefore asked about first, and
left alone if the answer is no; an empty one - the disaster case - is filled without a
question. `--yes` answers it in a script. The archive also decides which mailboxes the domain
has: an address added after the backup was taken does not survive the restore as a login.

A mail domain that is no site has only this archive, and `lomp backup example.com` or
`lomp backup --all` writes it. Moving a mail server to a new machine is therefore: install it
there, copy the archives into `/var/backups/server-setup/<domain>/`, and run
`lomp mail restore <domain>` for each — a domain the new server has never heard of is added
as a mail domain by the restore itself. An archive made with `--encrypt` is restored the same
way, with the key in `/root/.server-setup/backup.key`.

---

## Backups

```bash
sudo lomp backup example.com                   # one site
sudo lomp backup --all --encrypt --keep 14     # everything, encrypted, keep 14
sudo lomp backup --configure-remote            # set up an rsync or rclone target
sudo lomp backup --all --remote                # and push them off the box
sudo lomp backup --schedule "daily 03:00" --keep 14   # every site, every night, by cron
sudo lomp backup --schedule off                # stop the automatic backups
```

`--schedule` also takes `"weekly sun 04:00"`, `hourly` or a five-field cron expression, and
keeps the `--encrypt`, `--remote`, `--keep` and `--no-mail` given with it for every run. The
menu has the same under **12 → Automatic backups**, and `install --backup-schedule` sets it at
installation time.

An archive holds `public_html` and `private`, a consistent database dump
(`--single-transaction`), the vhost configuration, the site state files, a manifest and
SHA-256 checksums. `--encrypt` uses AES-256 with PBKDF2 and the key in
`/root/.server-setup/backup.key` — **copy that key off the server**, it is deliberately not
part of any backup.

Restores take a safety backup of the current state first:

```bash
sudo lomp restore example.com --file /var/backups/server-setup/example.com/example.com-20260914-030000.tar.gz
```

A restore can also rebuild a site that no longer exists on the machine, which makes the
archives usable for moving a site to a new server.

---

## Monitoring and alerts

`doctor` verifies services, the OpenLiteSpeed configuration, MariaDB connectivity, every
site over HTTP, certificate expiry, disk thresholds, timers, fail2ban jails, and whether
the recorded state still matches the real configuration. It also greps the log for
credential leaks. A daily timer runs it and notifies you when something is wrong.

```bash
sudo lomp notify --email you@example.com --smtp-host smtp.example.com \
     --smtp-port 587 --smtp-user you@example.com --smtp-pass 'app-password' --test

sudo lomp notify --telegram-token 123456:ABC --telegram-chat 987654321 --test
sudo lomp notify --webhook https://hooks.slack.com/services/... --test
sudo lomp notify --ssh-login on       # alert on every interactive SSH login
```

You get alerts for: installation finished, backup failed, certificate renewal failed, disk
threshold crossed, a service went down.

---

## Safety model

- Every configuration file is copied to a timestamped backup before it is modified.
- OpenLiteSpeed changes are transactional: snapshot → edit → `openlitespeed -t` → graceful
  reload → HTTP probe. Any failure restores the snapshot and the server keeps serving.
- MariaDB and Redis tuning is verified with a ping after the restart; a bad value restores
  the previous file and brings the service back with it.
- `add` unwinds everything it created (user, directories, vhost, database, certificate,
  state) if any step fails.
- DNS or certificate problems never fail `add`. The site stays on HTTP and tells you to run
  `renew-ssl` once DNS is fixed.
- SSH is never locked out: `sshd -t` must pass before anything is applied, password login is
  only disabled when an `authorized_keys` file exists, and a port change opens the new port
  in UFW while leaving the old one allowed.
- `--dry-run` prints diffs and commands and changes nothing at all.
- Only one instance can run at a time (`flock`), and every command is safe to re-run.

---

## Development

```bash
bash -n setup.sh lib/*.sh                     # syntax
shellcheck -S error -x setup.sh lib/*.sh      # static analysis, must be clean
bash tests/unit.sh                            # 200+ unit tests, no root, no network
```

The unit suite covers the configuration parser, the template renderer, resource
calculations, secret masking, state handling and argument parsing. CI runs it on Ubuntu
22.04 and 24.04 with both gawk and mawk.

On a **throwaway** VPS you can run the full acceptance test, which installs everything,
creates a site, breaks the configuration on purpose to prove the rollback works, and
removes the site again:

```bash
LOMPSTACK_INTEGRATION=yes bash tests/integration.sh
```

`rename` has end-to-end tests of its own, for a server that is already installed. They add,
rename and remove real sites under `.invalid` names and leave the server as they found it; each
says what it needs (mail, swaks, the webmail) and stops when that is missing:

```bash
LOMPSTACK_INTEGRATION=yes bash tests/e2e-rename.sh            # a WordPress site, the redirect, rollback, the menu
LOMPSTACK_INTEGRATION=yes bash tests/e2e-rename-app-mail.sh   # a Node.js application; mailboxes that follow the site
LOMPSTACK_INTEGRATION=yes bash tests/e2e-rename-webmail.sh    # what Roundcube keeps for a mailbox
```

One more of the same kind is for a WordPress that gets its certificate after it was installed
(certbot and the DNS answer are stand-ins for the test's two names under `lomptest.net`):

```bash
LOMPSTACK_INTEGRATION=yes bash tests/e2e-wp-https.sh          # http:// to https:// in the database, by renew-ssl and by rename
```

`add` has one for a WordPress site with `--www-primary`, and for what an `add` that fails
half way leaves behind (nothing, the Linux user included):

```bash
LOMPSTACK_INTEGRATION=yes bash tests/e2e-www-primary.sh
```

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

---

## Module layout

| File | Responsibility |
|---|---|
| `setup.sh` | Configuration block, global flags, command dispatch |
| `lib/common.sh` | Logging and masking, locking, error handling and rollback, file/apt/systemd helpers, JSON state |
| `lib/system.sh` | Hardware analysis, resource profile, sysctl and limits, swap, timezone |
| `lib/install.sh` | `install`, `update`, `optimize`, UFW, SSH hardening, Fail2ban, cron, optional runtimes |
| `lib/ols.sh` | OpenLiteSpeed: transactional config editing, snapshots, config test, templates, WebAdmin |
| `lib/php.sh` | LSPHP versions, extensions, php.ini tuning |
| `lib/db.sh` | MariaDB install, hardening, tuning, per-site databases, Redis |
| `lib/ssl.sh` | certbot, DNS checks, certificate deployment, renewal hook |
| `lib/domain.sh` | Site lifecycle, users and directories, WordPress, logrotate and jail regeneration |
| `lib/harden.sh` | `harden`: per-site PHP limits, the site firewall |
| `lib/scan.sh` | `scan`: looks through a site's PHP files for what web shells are made of |
| `lib/proxy.sh` | Path proxies: an application under a path of any site |
| `lib/app.sh` | Node.js applications: one PM2 daemon per site as the site user, systemd units, deploy, environment, workers and scheduled jobs |
| `lib/mail.sh` | Mail: Postfix, Dovecot, Rspamd and their configuration, the mail host's certificate, relay, deliverability checks |
| `lib/webmail.sh` | Webmail: the verified Roundcube release, its own PHP and user, a vhost per domain, updates |
| `lib/cloudflare.sh` | Trusted proxy ranges, real client IP, API token, edge bans |
| `lib/backup.sh` | Backup, restore, retention, encryption, remotes, scheduling |
| `lib/monitor.sh` | `status`, `doctor`, health check, notifications |
| `lib/rename.sh` | `rename`: a site under another domain name; `redirect`: a name that only sends its visitors on |
| `lib/import.sh` | `import`: the sites of another server, brought here over SSH |
| `lib/menu.sh` | Command reference and the interactive menu |

---

## Troubleshooting

| Symptom | What to do |
|---|---|
| A command failed | The error names the cause, the fix and the log line. Start with `sudo lomp doctor`. |
| Certificate not issued | `dig +short example.com` must return the server IP. Behind Cloudflare, use `--cf-api-token` for DNS-01. |
| Site returns 403 | The hostname is not mapped to a vhost, so the catch-all answered. Check `sudo lomp list`. |
| PHP file downloads instead of running | The site was created with `--static`. Recreate it, or check the handler in the vhost. |
| Locked out after an SSH change | Use the provider's console, `ufw allow 22/tcp`, and remove `/etc/ssh/sshd_config.d/99-server-setup.conf`. |

Full log, with secrets masked: `/var/log/server_setup.log`.

---

## License

MIT — see [LICENSE](LICENSE).
