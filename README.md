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
| Optional | Node.js + PM2, Python venv tooling, Netdata, Cloudflare real-client-IP mode. None of these is installed unless you ask for it, on the command line or from the menu. |

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
| `--proxy HOST:PORT` | Reverse proxy mode, TLS terminates in OpenLiteSpeed; add `--ws-path /socket.io` for WebSockets |
| `--wordpress` | Download and install WordPress, create the database, enable LiteSpeed Cache, register WP-Cron |
| `--no-db` | Skip the database. Every site otherwise gets its own MariaDB database and user — `example.com` becomes `example_db` / `example_user` with a 32-character random password, printed once when the site is created and available afterwards from `credentials` |
| `--wildcard` | Also request `*.<domain>` over DNS-01 (needs a stored Cloudflare API token) |
| `--staging` | Use the Let's Encrypt staging CA while you are testing |

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
└── app/                      proxy mode only: your Node/Python application
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
sudo lomp install --cf-api-token YOUR_TOKEN
```

The token needs `Zone → DNS → Edit` and `Account → Firewall Access Rules → Edit`, and is
stored with mode 0600. Set your Cloudflare SSL mode to **Full (strict)** once certificates
are issued.

There is no bundled WAF or ModSecurity: that job belongs to the edge.

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
