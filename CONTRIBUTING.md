# Contributing to lomp

Thanks for taking the time. This project touches production servers, so the bar for
changes is "would a staff SRE run this on their own box".

## Ground rules

1. **Every change must be idempotent.** Running a command twice must produce the same
   system state and report "already configured" the second time.
2. **Never break a running service.** Config changes go through the existing pattern:
   snapshot → edit → test → reload → verify → restore on failure.
3. **Never log a secret.** Passwords and tokens go through `lib_run_secret` /
   `lib_db_sql_secret`, and `lib_mask_secrets` must cover any new pattern you introduce.
4. **Support `--dry-run`.** A new action must print what it would do and change nothing.
5. **Support the fixed paths.** See the path table in the README; they are part of the
   public contract and are not renamed casually.

## Code style

- Bash 5, `set -Eeuo pipefail`, `shopt -s lastpipe` (already set in `setup.sh`).
- Module functions are prefixed `lib_`; private helpers start with `_`.
- Module globals are declared with `declare -g` (modules are sourced from inside a
  function, so a plain `declare` would be function-local).
- Write files with `lib_write_file` (atomic, backs up the old version, dry-run aware),
  not with `>` redirection.
- Register cron entries with `lib_cron_set` / `lib_cron_remove` (`lib_cron_replace_prefix` for a
  group, such as one site's jobs), never by editing `/etc/cron.d/server-setup` directly. A
  schedule must be validated first: cron ignores the whole file when one line is malformed.
- User-facing text is English; the log file must stay greppable.

## Before you open a pull request

```bash
bash -n setup.sh lib/*.sh                     # syntax
shellcheck -S error -x setup.sh lib/*.sh      # must be clean
bash tests/unit.sh                            # must be 100% green, no root needed
```

If your change touches installation, provisioning or removal, also run the destructive
acceptance test on a **throwaway** VPS:

```bash
LOMPSTACK_INTEGRATION=yes bash tests/integration.sh
```

Add a unit test for any new pure function (parsing, rendering, calculation). The unit
suite runs without root and without network, and CI runs it on Ubuntu 22.04 and 24.04.

## Reporting bugs

Include: Ubuntu version, the exact command, the relevant part of
`/var/log/server_setup.log` (it is already secret-masked, but skim it anyway), and the
output of `sudo lomp doctor`.

## Security issues

Do not open a public issue for a vulnerability. Contact the maintainer privately first.
