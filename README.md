# vps-infra

Server infrastructure for VPS servers hosting multiple apps: an Ansible playbook that configures every server, and a global Traefik reverse proxy with automatic SSL.

## What the playbook sets up

| Role | Details |
|---|---|
| `base` | Base packages, unattended security upgrades (no auto-reboot), 2 GB swap, SYN cookies |
| `users` | `ansible` admin user with passwordless sudo, one deploy user per app in the `docker` group (no sudo), SSH keys merged (existing keys are kept) |
| `docker` | Docker from the official apt repository, [docker-rollout](https://github.com/Wowu/docker-rollout) at a pinned version |
| `firewall` | iptables + ip6tables: SYN flood protection, SSH rate limit on `INPUT`, HTTP/HTTPS rate limit on `DOCKER-USER` |
| `traefik` | Traefik on ports 80/443 in `/opt/vps-infra/traefik`, access logs rotated daily (14 days) |
| `fail2ban` | SSH jail (10 failures / 5 min), plus a Traefik jail (20 errors / 5 min) that bans in `DOCKER-USER`, incremental bans up to 30 days |
| `ssh` | Password and root login disabled |

Docker-published ports bypass the `INPUT` chain, so all rules and bans for web traffic live in `DOCKER-USER`.

## Requirements

- Python 3.12+ and [uv](https://docs.astral.sh/uv/) (or pip) on the machine that runs Ansible
- Ubuntu 24.04 servers, reachable over SSH

```bash
uv tool install ansible-core==2.21.5
ansible-galaxy collection install -r requirements.yml
```

## Inventory

The repository is public, so the real inventory is never committed. Copy the example and fill in your servers:

```bash
cp inventory.example.yml inventory.yml
```

```yaml
vps:
  hosts:
    blog:
      ansible_host: 203.0.113.10
      deploy_users:
        - name: blog
          authorized_keys:
            - ssh-ed25519 AAAA... blog-github-actions
  vars:
    ansible_user: ansible
    acme_email: you@example.com
    admin_authorized_keys:
      - ssh-ed25519 AAAA... ansible-ci
      - ssh-ed25519 AAAA... laptop
```

- `admin_authorized_keys`: keys for the `ansible` user. Required, because root login gets disabled.
- `deploy_users`: one user per app on that server, with the keys its GitHub Actions deploy with. Each user is added to the `docker` group. Removing a user from the list doesn't delete it from the server.

Membership in the `docker` group is equivalent to root, so separate deploy users keep apps organized and keys revocable per app, but they don't isolate apps from each other.

Defaults such as `swap_size_mb` or the fail2ban limits live in `group_vars/vps.yml`. To change one for a single server, set it as a host variable, e.g. `swap_size_mb: 4096` under that host. Group variables in the inventory don't override `group_vars/`.

## Usage

```bash
ansible-playbook site.yml --check --diff     # preview changes on all servers
ansible-playbook site.yml                    # apply
ansible-playbook site.yml --limit blog       # one server only
```

Rerunning is safe: tasks only change what differs, and services restart only when their configuration changed.

## Bootstrap a new VPS

On a fresh server only root (or the provider's sudo user) exists. Run the playbook once as that user, it creates the `ansible` user:

```bash
ansible-playbook site.yml --limit blog -e ansible_user=root
```

Every later run uses `ansible_user: ansible` from the inventory.

## Migrate a server set up with `setup.sh`

Existing servers keep Traefik in `/opt/vps-infra/traefik`, so certificates and the running container are reused.

1. Add the server to `inventory.yml`.
2. Preview the changes as root: `ansible-playbook site.yml --limit blog -e ansible_user=root --check --diff`
3. Apply: `ansible-playbook site.yml --limit blog -e ansible_user=root`
4. Check that `ssh ansible@<server-ip>` works. Root login is disabled from now on.

## Server access

- SSH as `ansible` and use `sudo` (or `sudo -i`) for root.
- Root SSH login is disabled, which also breaks the DigitalOcean Droplet Console, because it logs in as root. Open the console, then change `os_user=root` to `os_user=ansible` in its URL and bookmark it.
- The SSH jail bans an IP after 10 failed logins in 5 minutes, and a single refused root login counts as about 3. If you get banned, connect from another network (phone hotspot, VPN) and run `sudo fail2ban-client set sshd unbanip <ip>`.

## GitHub Actions

The `Ansible` workflow runs the playbook from GitHub. Start it manually from the Actions tab:

- `apply` unchecked: `--check --diff`, shows what would change
- `apply` checked: applies the changes
- `limit`: optional host pattern, e.g. `blog`

Secrets in the `production` environment:

| Secret | Content |
|---|---|
| `ANSIBLE_INVENTORY` | the full `inventory.yml` |
| `ANSIBLE_SSH_PRIVATE_KEY` | private key matching one of the `admin_authorized_keys` |
| `SSH_KNOWN_HOSTS` | output of `ssh-keyscan <server-ip> ...` for every server |

## Linting

[pre-commit](https://pre-commit.com/) runs `ansible-lint` before every commit, and the `Pre-commit` workflow runs the same hooks on every push and pull request.

```bash
pre-commit install             # run the hooks on every commit
pre-commit run --all-files     # run them on demand
```

## How it works

One Traefik instance handles all incoming traffic on ports 80/443. Each app joins the `traefik-public` Docker network and declares its domain via labels. Traefik discovers containers automatically and issues SSL certs on demand.

```
Internet -> Traefik (80/443) -> app1 container (app1.com)
                             -> app2 container (app2.com)
                             -> app3 container (app3.com)
```

## Adding an app

In the app's `docker-compose.yml`:

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

Point the domain's A record to the VPS IP. Traefik issues the SSL cert automatically on first request.

## DNS setup

All domains point to the same VPS IP:

```
app1.com  ->  A  ->  <VPS_IP>
app2.com  ->  A  ->  <VPS_IP>
app3.com  ->  A  ->  <VPS_IP>
```
