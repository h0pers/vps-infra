# h0pers.vps

Ansible collection that configures Ubuntu 24.04 VPS servers for Docker apps behind one shared Traefik reverse proxy with automatic SSL.

This repository holds code only. Your servers live in a separate, private repository that installs this collection at a pinned version.

## What it sets up

The `h0pers.vps.site` playbook runs these roles on the `vps` inventory group:

| Role | Details |
|---|---|
| `base` | Base packages, unattended security upgrades (no auto-reboot), swap, SYN cookies |
| `users` | `ansible` admin user with passwordless sudo, one deploy user per app in the `docker` group (no sudo), SSH keys merged (existing keys are kept) |
| `docker` | Docker from the official apt repository, [docker-rollout](https://github.com/Wowu/docker-rollout) at a pinned version |
| `firewall` | iptables + ip6tables: SYN flood protection, SSH rate limit on `INPUT`, HTTP/HTTPS rate limit on `DOCKER-USER` |
| `traefik` | Traefik on ports 80/443 in `/opt/vps-infra/traefik`, access logs rotated daily (14 days) |
| `fail2ban` | SSH jail (10 failures / 5 min), Traefik jail (20 errors / 5 min) that bans in `DOCKER-USER`, incremental bans up to 30 days |
| `ssh` | Password and root login disabled |

Docker-published ports bypass the `INPUT` chain, so all rules and bans for web traffic live in `DOCKER-USER`.

## Set up your servers repository

Create a private repository with four files:

```
inventory.yml                   # servers, see inventory.example.yml
known_hosts                     # their SSH host keys, see known_hosts.example
requirements.yml
.github/workflows/ansible.yml
```

`requirements.yml` pins this collection to a release tag:

```yaml
collections:
  - name: https://github.com/h0pers/vps-infra.git
    type: git
    version: v1.0.0
```

`.github/workflows/ansible.yml` calls the reusable workflow from this repository:

```yaml
name: Ansible

on:
  workflow_dispatch:
    inputs:
      apply:
        description: Apply changes (unchecked runs --check --diff)
        type: boolean
        default: false
      limit:
        description: Limit to hosts (e.g. blog or blog,shop)
        type: string
        default: ""

jobs:
  ansible:
    uses: h0pers/vps-infra/.github/workflows/ansible.yml@v1.0.0
    with:
      apply: ${{ inputs.apply }}
      limit: ${{ inputs.limit }}
```

Add one secret, `ANSIBLE_SSH_PRIVATE_KEY`, to the `production` environment of the servers repository: a private key used only by CI, whose public key is in `users_admin_authorized_keys`.

Keep the repository private: the inventory holds no secrets, but it lists server IPs and user names, and its workflow logs show them too.

## Inventory

```yaml
vps:
  hosts:
    blog:
      ansible_host: 203.0.113.10
      users_deploy_users:
        - name: blog
          authorized_keys:
            - ssh-ed25519 AAAA... blog-github-actions
  vars:
    ansible_user: ansible
    traefik_acme_email: you@example.com
    users_admin_authorized_keys:
      - ssh-ed25519 AAAA... ansible-ci
      - ssh-ed25519 AAAA... laptop
```

| Variable | Default | Description |
|---|---|---|
| `users_admin_authorized_keys` | `[]` | Keys for the admin user. Required, because root login gets disabled |
| `users_deploy_users` | `[]` | One user per app, `name` and `authorized_keys`. Removing a user from the list doesn't delete it from the server |
| `traefik_acme_email` | | Let's Encrypt account email. Required |
| `users_admin_user` | `ansible` | Admin user name |
| `base_swap_size_mb` | `2048` | Swap file size, applied only when the swap file is created |
| `firewall_ssh_rate_per_minute` | `5` | New SSH connections per minute per IP |
| `firewall_http_rate_per_minute` | `100` | New HTTP/HTTPS connections per minute per IP |
| `firewall_http_rate_burst` | `200` | Burst above the HTTP/HTTPS rate |
| `fail2ban_ssh_maxretry` | `10` | Failed SSH logins before a ban |
| `fail2ban_http_maxretry` | `20` | Traefik 4xx/5xx responses before a ban |

All defaults live in `roles/*/defaults/main.yml` and can be overridden per group or per host in the inventory.

Membership in the `docker` group is equivalent to root, so separate deploy users keep apps organized and keys revocable per app, but they don't isolate apps from each other.

## Usage

From the servers repository, start the `Ansible` workflow in the Actions tab. `apply` unchecked previews the changes with `--check --diff`, checked applies them.

To run it locally:

```bash
uv tool install ansible-core==2.21.5
ansible-galaxy collection install -r requirements.yml
ansible-playbook h0pers.vps.site -i inventory.yml --check --diff    # preview
ansible-playbook h0pers.vps.site -i inventory.yml                   # apply
```

Rerunning is safe: tasks only change what differs, and services restart only when their configuration changed.

## Bootstrap a new VPS

On a fresh server only root (or the provider's sudo user) exists. Run the playbook once as that user, it creates the `ansible` user:

```bash
ansible-playbook h0pers.vps.site -i inventory.yml --limit blog -e ansible_user=root
```

Every later run uses `ansible_user: ansible` from the inventory. Then check that `ssh ansible@<server-ip>` works, root login is disabled from now on.

## Server access

- SSH as `ansible` and use `sudo` (or `sudo -i`) for root.
- Root SSH login is disabled, which also breaks the DigitalOcean Droplet Console, because it logs in as root. Open the console, then change `os_user=root` to `os_user=ansible` in its URL and bookmark it.
- The SSH jail bans an IP after 10 failed logins in 5 minutes, and a single refused root login counts as about 3. If you get banned, connect from another network (phone hotspot, VPN) and run `sudo fail2ban-client set sshd unbanip <ip>`.

## Adding an app

One Traefik instance handles all traffic on ports 80/443. Each app joins the `traefik-public` Docker network and declares its domain with labels. In the app's `docker-compose.yml`:

```yaml
services:
  backend:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`myapp.com`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls.certresolver=le"
    networks:
      - default
      - traefik-public

networks:
  traefik-public:
    external: true
```

Point the domain's A record to the server IP. Traefik issues the SSL certificate on the first request.

## Development

[pre-commit](https://pre-commit.com/) runs `ansible-lint` before every commit, and the `Pre-commit` workflow runs the same hooks on every push and pull request.

```bash
pre-commit install             # run the hooks on every commit
pre-commit run --all-files     # run them on demand
```

To release, bump `version` in `galaxy.yml`, add an entry to `CHANGELOG.md`, and tag the merge commit `vX.Y.Z`.
