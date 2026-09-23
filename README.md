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
| PHP | LSPHP (default 8.3, any version per site) with curl, mbstring, mysqli, PDO, gd, imagick, xml, zip, intl, bcmath, soap, opcache, redis, fileinfo, exif |
| Database | MariaDB bound to 127.0.0.1, hardened, InnoDB tuned to your RAM and disk type, slow query log on |
| Cache | Redis on localhost with a generated password, `allkeys-lru`, memory capped by RAM share |
| TLS | Let's Encrypt via certbot, shared ACME webroot, TLS 1.2/1.3 only, HSTS, auto-renew with an OpenLiteSpeed deploy hook |
| Security | UFW, Fail2ban (sshd + recidive + WordPress/scanner jails), sshd drop-in hardening, unattended security updates |
| Operations | Backups with retention/encryption/remote upload, daily health check, e-mail / Telegram / webhook alerts, `status` and `doctor` |
| Optional | Node.js + PM2, Python venv tooling, Netdata, Cloudflare real-client-IP mode, a mail server (Postfix + Dovecot + Rspamd). None of these is installed unless you ask for it, on the command line or from the menu. |

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

If DNS is not ready yet, add the site without TLS and issue the certificate later:

```bash
sudo lomp add example.com --no-ssl
# ... point the DNS records at the server, then:
sudo lomp renew-ssl example.com
```

---

## Everyday commands

```bash
sudo lomp add shop.example.com --wordpress          # WordPress with database and cache
sudo lomp add api.example.com --proxy 127.0.0.1:3000 # Node/Python app behind OpenLiteSpeed
sudo lomp proxy add example.com /api/ 127.0.0.1:3001 # an app under a path of an existing site
sudo lomp add node.example.com --node                # Node.js app run by PM2 (see below)
sudo lomp app worker node.example.com add queue --start "node worker.js"   # a worker next to it
sudo lomp add cdn.example.com --static              # static site, no PHP
sudo lomp db shop.example.com                       # create or show the database
sudo lomp db list                                   # every site's database, user and size
sudo lomp credentials shop.example.com              # database / WordPress / SSL details
sudo lomp list                                      # all sites in a table
sudo lomp logs shop.example.com                     # tail access and error logs
sudo lomp backup --all --encrypt                    # back up every site
sudo lomp restore shop.example.com --file /var/backups/server-setup/shop.example.com/....tar.gz
sudo lomp renew-ssl --all                           # renew every certificate
sudo lomp panel                                     # open the WebAdmin panel for your address
sudo lomp self-update                               # pull the latest code, server untouched
sudo lomp optimize                                  # re-measure hardware, show a diff, re-tune
sudo lomp update                                    # safe package update, ordered restarts
sudo lomp remove old.example.com --keep-db          # remove a site, keep its database
```

Global flags work everywhere: `--yes`, `--dry-run`, `--quiet`, `--verbose`, `--no-color`,
`--json` (for `status`, `doctor`, `list`), `--non-interactive`.

`sudo ./setup.sh help` prints the complete reference.

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

### .htaccess

PHP and WordPress sites read `.htaccess`, within two limits that come from OpenLiteSpeed:

- Only rewrite rules count (`RewriteEngine`, `RewriteBase`, `RewriteCond`, `RewriteRule`).
  `Header`, `php_value`, `Deny from all`, `Require`, `Options`, `AuthType` and the like are
  ignored. lompstack sets the security headers, the PHP limits and the file protection in the
  virtual host instead, and WordPress sites refuse to run any PHP file under
  `wp-content/uploads`.
- A `.htaccess` is read when OpenLiteSpeed loads, not when it changes. A cron job checks every
  minute and reloads OpenLiteSpeed once a `.htaccess` has changed - a WordPress permalink
  setting, a plugin, a hand edit - so a change takes effect within about a minute. A reload
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
  `app.set('trust proxy', 'loopback')` to see HTTPS and the client's address.

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
/home/<domain>/               0711  <user>:<user>     one Linux user per site, nologin shell
├── public_html/              0755  document root
├── private/                  0700  sessions, temp uploads, secrets - never served
├── logs/                     0750  access.log, error.log (rotated by logrotate)
├── backups/                  0700
├── app/                      proxy mode only: your Node/Python application
└── .pm2/                     0700  Node.js sites: PM2 state, ecosystem file, logs, job scripts
```

PHP runs as the site's own user through a per-vhost LSAPI processor, so one compromised
site cannot read another site's files. Directory listing is off, and requests for dotfiles,
`.git`, `.env`, `*.sql`, `*.bak` and `wp-config.php` are refused.

---

## Fixed paths

| Path | Contents |
|---|---|
| `/root/.server-setup/` | State and credentials, mode 0700 (`manifest.json`, `domains/<domain>/…`, archives) |
| `/home/<domain>/` | Site files |
| `/usr/local/lsws/conf/vhosts/<domain>/` | Generated vhost configuration |
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
file. Set your Cloudflare SSL mode to **Full (strict)** once certificates are issued.

There is no bundled WAF or ModSecurity: that job belongs to the edge.

---

## Mail

A mail server for the sites on this machine: Postfix for SMTP, Dovecot for IMAP and delivery,
Rspamd for spam filtering and DKIM. It is opt-in and changes nothing about the web stack.

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
printf '%s' "$PASS" | sudo lomp mail relay set --host smtp.example.net --port 587 --user you@example.net
sudo lomp mail relay off
```

The password is read from standard input and lands in one 0600 file that Postfix reads; it is
never an argument and never reaches the log. Mail still carries this server's own DKIM
signature when it goes through a relay.

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

A restore makes a mailbox an exact copy of the archive, so anything that arrived after the
backup is deleted by it. A mailbox that still holds mail is therefore asked about first, and
left alone if the answer is no; an empty one - the disaster case - is filled without a
question. `--yes` answers it in a script.

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

---

## Backups

```bash
sudo lomp backup example.com                   # one site
sudo lomp backup --all --encrypt --keep 14     # everything, encrypted, keep 14
sudo lomp backup --configure-remote            # set up an rsync or rclone target
sudo lomp backup --all --remote                # and push them off the box
```

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
| `lib/proxy.sh` | Path proxies: an application under a path of any site |
| `lib/app.sh` | Node.js applications: one PM2 daemon per site as the site user, systemd units, deploy, environment, workers and scheduled jobs |
| `lib/mail.sh` | Mail: Postfix, Dovecot, Rspamd and their configuration, the mail host's certificate, relay, deliverability checks |
| `lib/webmail.sh` | Webmail: the verified Roundcube release, its own PHP and user, a vhost per domain, updates |
| `lib/cloudflare.sh` | Trusted proxy ranges, real client IP, API token, edge bans |
| `lib/backup.sh` | Backup, restore, retention, encryption, remotes, scheduling |
| `lib/monitor.sh` | `status`, `doctor`, health check, notifications |
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
