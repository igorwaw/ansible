# Borg backups

## Overview

`roles/borg_client` backs up a host to `firefly` over SSH using
[BorgBackup](https://borgbackup.readthedocs.io/). `roles/borg_server` runs
retention (prune/compact) on firefly for all client repositories. Both roles
are applied via `ood.yml` and `firefly.yml` (firefly backs up itself as a
client of its own server, `borg_client` before `borg_server` in that
playbook's `roles:` list).

## Storage

- Repositories live under `/data/noshare/borg/<client>/`, one directory per
  client (`ood`, `firefly`), inventory hostname used as the directory name.
- `/data/noshare/borg` has the btrfs `nodatacow` (`chattr +C`) attribute set,
  applied idempotently before any client repo is created there. Borg writes
  many small segment files; btrfs COW causes serious fragmentation under that
  pattern (documented in Borg's own FAQ). Trade-off: this also disables
  btrfs checksumming/self-heal for that directory - acceptable here because
  Borg does its own chunk-level integrity checking (`borg check`).
- `/data/noshare` is shared with unrelated services (docker, grafana,
  jellyfin, syncthing, urbackup, photos); `borg_client` only touches its own
  `borg` subdirectory, never the mount root.

## Server-side accounts

- One dedicated Unix user per client: `borg-<client>` (e.g. `borg-ood`),
  created on firefly via `delegate_to` from `borg_client`'s tasks - so the
  account is provisioned regardless of which playbook runs first.
- Shell is `/bin/sh`, **not** `/usr/sbin/nologin`. sshd executes an
  `authorized_keys` `command=` restriction through the account's configured
  shell; `nologin` refuses to run anything (including the forced command),
  which breaks `borg serve` entirely regardless of the restriction. The
  actual security boundary is the `authorized_keys` line itself, not the
  shell.
- `authorized_keys` for each client's key: `command="borg serve
  --restrict-to-path /data/noshare/borg/<client> --append-only",restrict`.
  `restrict` (modern OpenSSH) disables port/agent/X11 forwarding and PTY
  allocation in one flag. `--append-only` means a compromised or malicious
  client can add archives but cannot delete or corrupt existing ones over
  the wire.
- Each client has its own dedicated ed25519 keypair (`/root/.ssh/borg_ed25519`
  on the client), generated once and never shared between clients.

## Retention (append-only implication)

Since `--append-only` blocks deletion at the `borg serve` layer, pruning has
to happen outside that transport. `borg_server`'s prune/compact script runs
locally on firefly (direct filesystem path, not `ssh://`), which bypasses
`--append-only` entirely (that flag only restricts the `borg serve` RPC
layer, not local filesystem access). It loops over `borg_clients`
(`vars/main.yml`) and looks up each one's passphrase from the `vault` dict
dynamically (`vault['vault_borg_passphrase_' + client]`), since prune/compact
need to decrypt repo metadata even for local access.

Shared policy: `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`
(`borg_keep_daily`/`borg_keep_weekly`/`borg_keep_monthly` in `vars/main.yml`).

The prune script runs as root (no `User=` on the service), since it needs
local filesystem access across every client's repository. `borg
prune`/`compact` can create or rewrite segment files as a side effect, which
then end up root-owned instead of owned by that client's dedicated
`borg-<client>` user - breaking that user's own SSH-restricted `borg serve`
access on the *next* client backup (`PermissionError` on the segment file).
The script `chown -R borg-<client>:borg-<client>` each client's repo
directory back after its prune/compact, every run.

For firefly's own self-backup repo specifically, the same root user on the
same host accesses it two different ways: via `ssh://` for the client
backup, via a local path here. Borg's relocation-safety check flags that
mismatch and prompts interactively - which a systemd service can't answer -
so the script sets `BORG_RELOCATED_REPO_ACCESS_IS_OK=yes`. Safe here since
we control both access paths intentionally; doesn't apply to `ood` (its
client and firefly's server are different root users on different hosts,
so there's no shared location cache to conflict).

## Encryption and secrets

- Encryption mode: `repokey-blake2` - key lives inside the repo, unlocked by
  passphrase only, nothing extra to separately back up/lose.
- One passphrase per client (not shared), stored in `vars/vault.yml` under
  the existing `vault:` top-level dict:
  `vault.vault_borg_passphrase_ood`, `vault.vault_borg_passphrase_firefly`.
- Each playbook maps its host's passphrase to the generic `borg_passphrase`
  var the role uses, e.g. in `ood.yml`:
  `borg_passphrase: "{{ vault.vault_borg_passphrase_ood }}"`.
- Passphrases are never put in a process environment variable or embedded in
  a script. Each is written to a `0600` root-only source file
  (`/etc/borg/borg-passphrase` on a client; `/etc/borg/prune-<client>-passphrase`
  per client on `borg_server`), referenced by the unit's `LoadCredential=`
  directive. systemd copies the file's content into a private,
  `0700`-service-owned, auto-cleaned-on-exit runtime directory
  (`$CREDENTIALS_DIRECTORY`) for just that invocation.
- The scripts set `BORG_PASSCOMMAND="cat ${CREDENTIALS_DIRECTORY}/<name>"`
  instead of `BORG_PASSPHRASE` - Borg runs that command each time it needs
  the passphrase, so the literal value never sits in the environment (visible
  via `/proc/<pid>/environ` and inherited by child processes the way
  `EnvironmentFile=`/`Environment=` would) or in the deployed script text.
  This means the prune script (which needs every client's passphrase) and
  the deployed backup script are both fully secret-free and safe to `cat`.
- Any Ansible task that writes one of the `0600` source files themselves is
  still marked `no_log: true`, since that's the one place the plaintext value
  passes through Ansible's own output/diff machinery.
- `repo_init.yml`'s one-off `borg init` command still sets `BORG_PASSPHRASE`
  directly in the task's `environment:` (also `no_log: true`) - this is a
  single ephemeral Ansible-run process, not a persisted file/script, so the
  `LoadCredential=` mechanism (a systemd unit feature) doesn't apply there.

## apt version pinning

`/etc/apt/preferences.d/borgbackup`:
```
Package: borgbackup
Pin: version 1.*
Pin-Priority: 990
```
Allows minor/patch upgrades within the 1.x series but blocks a future
Borg 2.x (different, incompatible repository format) from being installed
via `state: latest`. 

## Backup paths

- Role default (`roles/borg_client/defaults/main.yml`): `borg_backup_paths:
  [/etc]`, `borg_backup_excludes: []`.
- `ood.yml` overrides both (full replacement, not merge - Ansible list vars
  don't merge across scopes by default): `[/etc, /home/igor]`, excluding
  `/home/igor/CloudStation`, `/home/igor/.cache`,
  `/home/igor/.local/share/torbrowser`.

## Scheduling

systemd timers, not cron, on both roles - `Persistent=true` means a missed
run (host asleep/off at the scheduled time) executes on next boot/wake
instead of being silently skipped, which matters for `ood` (laptop, not
always on) and for firefly (could be down/rebooting at its scheduled time
too). `RandomizedDelaySec=600` avoids a fixed thundering-herd instant.

- firefly backup: `02:00` (+jitter)
- ood backup: `02:30` (+jitter) - runs after firefly's own backup under
  normal conditions; soft ordering only, since `Persistent=true` catch-up
  after sleep can't be strictly sequenced against firefly.
- firefly prune/compact: `03:00` (+jitter) - scheduled after both backup
  windows to avoid a repo-lock collision with a same-repo `borg create`
  still running (matters most for firefly's own self-backup repo).

## Handling ood being offline

`ood` travels and is often unreachable from firefly. The backup script sets
`BORG_RSH="ssh ... -o ConnectTimeout=10 -o BatchMode=yes ..."` so a dead
network fails fast, then distinguishes failure classes by inspecting
`borg create`'s combined output:
- Connection timeout/refused/unreachable/DNS failure → logged, exit 0
  (treated as "nothing to do this run", not a failure).
- Anything else (auth failure, disk full, repo corruption, etc.) → exit
  non-zero, a real failure.

This distinction matters: a blanket "swallow all errors while offline"
would also hide genuine problems that have nothing to do with network
reachability.

## Repository initialization

Idempotent: `repo_init.yml` `stat`s the repo's `config` file on firefly
(via `delegate_to`) before deciding whether to run `borg init
--encryption=repokey-blake2` from the client. Uses
`StrictHostKeyChecking=accept-new` since each client's dedicated key has
never connected as that user before (root's `known_hosts`, not the
interactively-verified `igor` user's).

## Key files and paths (per client)

| What | Path |
|---|---|
| Client SSH key | `/root/.ssh/borg_ed25519` (+ `.pub`) |
| Passphrase credential source file | `/etc/borg/borg-passphrase` (`0600`) |
| Backup script | `/usr/local/sbin/borg-backup.sh` (secret-free) |
| Backup service/timer | `/etc/systemd/system/borg-backup.{service,timer}` |
| Repo (on firefly) | `/data/noshare/borg/<client>/` |
| Server-side account | `borg-<client>` (shell `/bin/sh`, home `/home/borg-<client>`) |

Server-only (firefly):

| What | Path |
|---|---|
| Per-client passphrase credential source files | `/etc/borg/prune-<client>-passphrase` (`0600`) |
| Prune/compact script | `/usr/local/sbin/borg-prune.sh` (`0700`, secret-free) |
| Prune service/timer | `/etc/systemd/system/borg-prune.{service,timer}` |

## Known check-mode limitations

`ansible-playbook --check` cannot fully validate this feature end-to-end on
a from-scratch host: `authorized_key`, and `systemd_service` enable/start
for a unit that was only simulated (not really written), can't resolve
against state that check mode never actually created. These are expected
`--check` artifacts, not bugs - real runs create the dependencies for real
in task order.
