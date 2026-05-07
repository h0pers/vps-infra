# vps-infra

Server infrastructure for shared VPS hosting multiple apps. Global Traefik reverse proxy with automatic SSL via Let's Encrypt.

## How it works

One Traefik instance handles all incoming traffic on ports 80/443. Each app joins the `traefik-public` Docker network and declares its domain via labels. Traefik discovers containers automatically and issues SSL certs on demand.

```
Internet → Traefik (80/443) → app1 container (app1.com)
                             → app2 container (app2.com)
                             → app3 container (app3.com)
```

## Bootstrap a new VPS

```bash
git clone git@github.com:h0pers/vps-infra.git ~/vps-infra
cp ~/vps-infra/traefik/.env.example ~/vps-infra/traefik/.env
# edit .env — set ACME_EMAIL
cd ~/vps-infra/traefik && docker compose up -d
```

Done. Traefik is running and will auto-start on server reboot.

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
app1.com  →  A  →  <VPS_IP>
app2.com  →  A  →  <VPS_IP>
app3.com  →  A  →  <VPS_IP>
```

## Environment variables

| Variable | Description |
|---|---|
| `ACME_EMAIL` | Email for Let's Encrypt notifications |

Copy `traefik/.env.example` to `traefik/.env` and fill in values. The `.env` file is gitignored — set it manually on each server.