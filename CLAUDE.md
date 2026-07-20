# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Personal Ansible playbooks that configure Igor's own machines: two Linux desktops/laptops (`elsa`, `ood`), a home NAS/media server (`firefly`), and a mikr.us VPS (`mikrus`). There is no CI, no test suite, and no molecule setup — changes are validated with syntax checks and applied directly to real hosts defined in `inventory`.

## Commands

```bash
# Syntax-check a playbook (no ansible-lint installed in this environment)
ansible-playbook --syntax-check <playbook>.yml

# Dry run against a real host
ansible-playbook <playbook>.yml --check --diff

# Apply a playbook (targets are defined in ./inventory, e.g. elsa/firefly/ood/mikrus)
ansible-playbook <playbook>.yml

# firefly.yml loads vars/vault.yml, so it needs a vault secret
ansible-playbook firefly.yml --ask-vault-pass
# or
ansible-playbook firefly.yml --vault-password-file <path>

# Edit the vaulted secrets
ansible-vault edit vars/vault.yml

# Print all Ansible facts for a host (useful for checking a variable exists on a target)
ansible-playbook facts.yml
```

`ansible.cfg` sets `inventory = ./inventory`, fact caching to `/tmp/ansible-cache` (1hr TTL), and logs to `/tmp/ansible.log`. `.ansible-lint` skips `yaml[line-length]` and `package-latest` repo-wide (this repo intentionally uses `state: latest` for most apt installs) and excludes `roles/snapraid/meta`.

## Architecture

- **One playbook per host** at the repo root (`elsa.yml`, `firefly.yml`, `ood.yml`, `mikrus.yml`), each mapping to a `hosts:` group/name in `inventory` and composing a list of roles from `roles/`. There is no `site.yml` — playbooks are run individually per host.
- **`vars/main.yml`** holds shared, non-secret variables (package lists per role-purpose, `create_user`, `ssh_port`, etc.) and is loaded via `vars_files` by `elsa.yml`, `firefly.yml`, and `ood.yml`. `mikrus.yml` does not use the shared roles/vars — it's a standalone, inline-tasks playbook (based on the DigitalOcean "Initial Server Setup" tutorial) for a minimal VPS.
- **`vars/vault.yml`** is an `ansible-vault`-encrypted file holding secrets (e.g. the samba user password consumed by `roles/firefly/vars/main.yml`). Only `firefly.yml` loads it. If you add a role/playbook that references `vault.*`, remember to add `vars/vault.yml` to that playbook's `vars_files` or the variable will be undefined.
- **Roles are composed per playbook, not generic**: `linux_common` (base hardening: sudo/wheel group, user + SSH key, SSH port change, base packages, timezone) is the common first role for the three desktop/server playbooks. `linux_dev`, `linux_desktop`, `linux_photo`, `docker_host` are opt-in per host depending on its purpose (e.g. `ood.yml` swaps `docker_host` for `linux_photo` and comments it out rather than deleting it).
- **`firefly` role** is the NAS role: `roles/firefly/tasks/main.yml` chains `pre-tasks.yml` (mount data disks by LABEL under `/data/<name>`), `samba.yml` (Samba shares, driven by `samba_shares`/`no_shares` in `roles/firefly/vars/main.yml`), `post-tasks.yml` (hd-idle, WSDD), and `syncthing.yml`. Samba disk/share layout is host-specific and lives entirely in `roles/firefly/vars/main.yml` and `roles/firefly/defaults/main.yml`, not in tasks.
- **Docker services are deployed as `docker-compose.yml` files pushed via `ansible.builtin.copy`/`template`, then run with `community.docker.docker_compose_v2`** (roles `jellyfin`, `prometheus_server`, `home_assistant`). Compose files live under each role's `files/`. `docker_host` role installs the Docker Engine + compose plugin and must run before any of these.
- **`snapraid` role** is a third-party role (see `roles/snapraid/meta/main.yml`) with its own `defaults`/`vars` split: `roles/snapraid/vars/main.yml` defines host-specific disk layout (`snapraid_data_disks`, `snapraid_parity_disks`), while `roles/snapraid/defaults/main.yml` has the tunable runner behavior (schedule, healthchecks.io UUIDs, email alerting). It clones and builds `snapraid` and `snapraid-runner` from source via git rather than installing from apt.
- **`home_assistant` and `qemu_vm` roles exist but are not referenced by any playbook** — treat them as available-but-unwired; a playbook needs to add them to its `roles:` list to take effect.
- Task files consistently use fully-qualified module names (`ansible.builtin.*`, `community.docker.*`, `ansible.posix.*`) except in the two unused roles above — match that convention (FQCN) for any new/edited tasks.
- Disk/share mounting convention: filesystems are referenced by `LABEL=<name>` (not UUID/device path) and mounted under `/data/<name>` with `nodev,noexec,noatime,nofail,x-systemd.device-timeout=10`. Follow this pattern for any new mount points.
