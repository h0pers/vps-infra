# Changelog

## 1.1.0

- `docker` writes `/etc/docker/daemon.json` with the `json-file` log driver capped at `docker_log_max_size` (`10m`) × `docker_log_max_file` (`3`) per container, so container logs no longer grow without limit.

Upgrading an existing server:

- The first run restarts Docker once, so every container restarts briefly.
- The limits apply only to containers created afterwards. Recreate Traefik once with `cd /opt/vps-infra/traefik && sudo docker compose up -d --force-recreate`. Apps pick up the limits on their next `docker rollout` deploy, or recreate them the same way.

## 1.0.0

- First release as the `h0pers.vps` collection: roles `base`, `users`, `docker`, `firewall`, `traefik`, `fail2ban`, `ssh` and the `h0pers.vps.site` playbook.
- Reusable `Ansible` workflow for repositories that hold the inventory.
