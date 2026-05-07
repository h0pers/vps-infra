# vps-infra

Server infrastructure for shared VPS hosting multiple apps. Includes one-command VPS bootstrap and a global Traefik reverse proxy with automatic SSL.

## Bootstrap a new VPS

Run as root on a fresh Ubuntu/Debian droplet:

```bash
curl -fsSL https://raw.githubusercontent.com/h0pers/vps-infra/master/setup.sh | \
  DEPLOY_USER=deploy ACME_EMAIL=you@email.com bash
```

What it sets up:

| Component | Details |
|---|---|
| Docker | Installed via get.docker.com |
| Deploy user | Non-root user added to docker group, SSH keys copied from root |
| Swap | 2 GB swapfile |
| iptables | SYN flood protection, rate limiting on ports 22/80/443, IPv4 + IPv6 |
| fail2ban | SSH (3 attempts/5 min) + Traefik HTTP (20 errors/5 min), incremental bans up to 30 days |
| SSH hardening | Password auth disabled, root login disabled |
| unattended-upgrades | Security patches applied automatically, no auto-reboot |
| Traefik | Started on ports 80/443, auto-starts on reboot |
| logrotate | Traefik access logs rotated daily, 14 days retained |

After setup, login as the deploy user:

```bash
ssh deploy@<server-ip>
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

## Manual Traefik setup (without setup.sh)

```bash
git clone git@github.com:h0pers/vps-infra.git ~/vps-infra
cp ~/vps-infra/traefik/.env.example ~/vps-infra/traefik/.env
# edit .env - set ACME_EMAIL
cd ~/vps-infra/traefik && docker compose up -d
```

## Environment variables

| Variable | Description |
|---|---|
| `ACME_EMAIL` | Email for Let's Encrypt notifications |
| `DEPLOY_USER` | Non-root user to create (default: `deploy`) |

Copy `traefik/.env.example` to `traefik/.env`. The `.env` file is gitignored - set it manually on each server.