# Changelog

## 2.0.0

- `fail2ban` runs only the SSH jail. The Traefik jail, which banned on any 4xx/5xx response, is removed, along with `fail2ban_http_maxretry`, `fail2ban_http_findtime`, `fail2ban_http_bantime` and `fail2ban_traefik_log_path`.
- `fail2ban_ignoreip` lists IPs or CIDRs that are never banned.
- `firewall` blocks published container ports other than 80/443 from outside. List any others in `firewall_docker_allowed_ports`.
- `firewall` applies each IP family's rules in one `iptables-restore` transaction, so a failed run keeps the previous rules.
- `firewall` sets the `FORWARD` policy to `DROP`, as Docker does, and allows DHCP client replies.
- `firewall` no longer rate limits SSH or HTTP connections per IP, and `firewall_ssh_rate_per_minute`, `firewall_http_rate_per_minute` and `firewall_http_rate_burst` are removed.

Upgrading an existing server:

- Before the first run, check which ports your apps publish with `sudo docker ps --format '{{.Names}} {{.Ports}}'`. Ports other than 80/443 stop being reachable from outside unless listed in `firewall_docker_allowed_ports`.
- Remove the deleted variables from your inventory.
- The first run restarts fail2ban once, which removes the Traefik jail and its bans.

## 1.1.0

- `docker` writes `/etc/docker/daemon.json` with the `json-file` log driver capped at `docker_log_max_size` (`10m`) × `docker_log_max_file` (`3`) per container, so container logs no longer grow without limit.

Upgrading an existing server:

- The first run restarts Docker once, so every container restarts briefly.
- The limits apply only to containers created afterwards. Recreate Traefik once with `cd /opt/vps-infra/traefik && sudo docker compose up -d --force-recreate`. Apps pick up the limits on their next `docker rollout` deploy, or recreate them the same way.

## 1.0.0

- First release as the `h0pers.vps` collection: roles `base`, `users`, `docker`, `firewall`, `traefik`, `fail2ban`, `ssh` and the `h0pers.vps.site` playbook.
- Reusable `Ansible` workflow for repositories that hold the inventory.
