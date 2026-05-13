#!/bin/bash
# Bootstrap a fresh Ubuntu/Debian VPS.
# Run as root: DEPLOY_USER=deploy ACME_EMAIL=you@email.com bash setup.sh
#
# Variables:
#   DEPLOY_USER  - non-root user to create (default: deploy)
#   ACME_EMAIL   - email for Let's Encrypt notifications (required)
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
ACME_EMAIL="${ACME_EMAIL:?ACME_EMAIL is required. Run: ACME_EMAIL=you@email.com bash setup.sh}"

export DEBIAN_FRONTEND=noninteractive

echo "-> Recovering any interrupted dpkg operations"
dpkg --configure -a

echo "-> Updating system packages"
apt-get update -q && apt-get upgrade -y -q -o Dpkg::Options::="--force-confold"

echo "-> Installing packages"
apt-get install -y -q curl git fail2ban unattended-upgrades logrotate

echo "-> Installing Docker"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable docker
systemctl start docker

echo "-> Installing docker-rollout CLI plugin (system-wide)"
PLUGIN_DIR="/usr/local/lib/docker/cli-plugins"
mkdir -p "$PLUGIN_DIR"
if [ ! -x "$PLUGIN_DIR/docker-rollout" ]; then
  curl -fsSL https://raw.githubusercontent.com/Wowu/docker-rollout/main/docker-rollout \
    -o "$PLUGIN_DIR/docker-rollout"
  chmod +x "$PLUGIN_DIR/docker-rollout"
fi

echo "-> Enabling unattended security upgrades"
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local << 'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
systemctl enable unattended-upgrades
systemctl start unattended-upgrades

echo "-> Creating deploy user: $DEPLOY_USER"
if ! id "$DEPLOY_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"

# Copy root SSH authorized_keys to deploy user
if [ -f /root/.ssh/authorized_keys ]; then
  mkdir -p /home/"$DEPLOY_USER"/.ssh
  cp /root/.ssh/authorized_keys /home/"$DEPLOY_USER"/.ssh/authorized_keys
  chown -R "$DEPLOY_USER":"$DEPLOY_USER" /home/"$DEPLOY_USER"/.ssh
  chmod 700 /home/"$DEPLOY_USER"/.ssh
  chmod 600 /home/"$DEPLOY_USER"/.ssh/authorized_keys
fi

echo "-> Configuring swap (2 GB)"
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "-> Enabling SYN cookies (kernel SYN flood mitigation)"
# || true: sysctl -w can fail in some VPS environments; conf file persists the setting anyway
sysctl -w net.ipv4.tcp_syncookies=1 || true
cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
net.ipv4.tcp_syncookies = 1
EOF

echo "-> Writing iptables hardening script"
# Rules live in a standalone script run by systemd on each boot, after Docker starts.
# This avoids iptables-persistent conflicts with Docker's dynamic chain management.
cat > /usr/local/bin/iptables-hardening.sh << 'EOF'
#!/bin/bash
# Applied on boot by systemd, after Docker starts.
set -e

apply_rules() {
  local ipt=$1  # iptables or ip6tables

  # Flush only INPUT - never touch DOCKER/DOCKER-USER chains
  $ipt -F INPUT

  # Default policies
  $ipt -P INPUT DROP
  $ipt -P OUTPUT ACCEPT
  $ipt -P FORWARD ACCEPT  # Required for Docker container networking

  # Allow established and related connections
  $ipt -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # Allow loopback
  $ipt -A INPUT -i lo -j ACCEPT

  # Drop invalid packets
  $ipt -A INPUT -m conntrack --ctstate INVALID -j DROP

  # Drop new TCP connections not in SYN state (prevents certain scans)
  $ipt -A INPUT -p tcp ! --syn -m conntrack --ctstate NEW -j DROP

  # SYN flood: drop IPs sending MORE THAN 50 SYN/sec (burst 200)
  # --hashlimit-above matches when rate EXCEEDS the limit
  $ipt -A INPUT -p tcp --syn \
    -m hashlimit --hashlimit-name syn-flood \
    --hashlimit-above 50/second --hashlimit-burst 200 \
    --hashlimit-mode srcip -j DROP

  # SSH: accept up to 5 connections/min per IP (burst 5), drop the rest
  $ipt -A INPUT -p tcp --dport 22 \
    -m hashlimit --hashlimit-name ssh-limit \
    --hashlimit 5/minute --hashlimit-burst 5 \
    --hashlimit-mode srcip -j ACCEPT
  $ipt -A INPUT -p tcp --dport 22 -j DROP

  # HTTP: accept up to 100 new connections/min per IP (burst 200), drop the rest
  $ipt -A INPUT -p tcp --dport 80 \
    -m hashlimit --hashlimit-name http-limit \
    --hashlimit 100/minute --hashlimit-burst 200 \
    --hashlimit-mode srcip -j ACCEPT
  $ipt -A INPUT -p tcp --dport 80 -j DROP

  # HTTPS: same as HTTP
  $ipt -A INPUT -p tcp --dport 443 \
    -m hashlimit --hashlimit-name https-limit \
    --hashlimit 100/minute --hashlimit-burst 200 \
    --hashlimit-mode srcip -j ACCEPT
  $ipt -A INPUT -p tcp --dport 443 -j DROP
}

apply_rules iptables
apply_rules ip6tables

# IPv6 ICMP must be fully allowed - required for neighbor discovery and other IPv6 mechanisms
ip6tables -A INPUT -p ipv6-icmp -j ACCEPT

# IPv4 ICMP ping (rate limited, not blocked entirely)
iptables -A INPUT -p icmp --icmp-type echo-request \
  -m hashlimit --hashlimit-name icmp-limit \
  --hashlimit 5/second --hashlimit-burst 10 \
  --hashlimit-mode srcip -j ACCEPT
EOF
chmod +x /usr/local/bin/iptables-hardening.sh

echo "-> Creating iptables systemd service"
cat > /etc/systemd/system/iptables-hardening.service << 'EOF'
[Unit]
Description=iptables hardening rules
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/iptables-hardening.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable iptables-hardening.service
systemctl start iptables-hardening.service

echo "-> Configuring fail2ban"
cat > /etc/fail2ban/filter.d/traefik-http.conf << 'EOF'
[Definition]
failregex = ^.*"ClientHost":"<HOST>".*"DownstreamStatus":(4[0-9]{2}|5[0-9]{2}).*$
ignoreregex = ^.*"DownstreamStatus":200.*$
EOF

TRAEFIK_LOG="/opt/vps-infra/traefik/logs/access.log"

cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
# Base ban: 1 day. Incremental: each repeat doubles ban time, max 30 days.
# 1st ban = 1d, 2nd = 2d, 3rd = 4d ... max = 30d
bantime           = 1d
findtime          = 10m
maxretry          = 5
bantime.increment = true
bantime.factor    = 1
bantime.formula   = ban.Time * (1<<(ban.Count if ban.Count<20 else 20)) * banFactor
bantime.maxtime   = 30d

[sshd]
enabled  = true
port     = ssh
maxretry = 3
findtime = 5m
bantime  = 1d

[traefik-http]
enabled  = true
filter   = traefik-http
logpath  = $TRAEFIK_LOG
maxretry = 20
findtime = 5m
bantime  = 1h
EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo "-> Configuring logrotate for Traefik access logs"
cat > /etc/logrotate.d/traefik << EOF
$TRAEFIK_LOG {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

echo "-> Hardening SSH"
if [ -f /home/"$DEPLOY_USER"/.ssh/authorized_keys ]; then
  sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
  systemctl restart sshd 2>/dev/null || systemctl restart ssh
  echo "   SSH hardened: password auth disabled, root login disabled"
else
  echo "   WARNING: no authorized_keys found - skipping SSH hardening to prevent lockout"
fi

echo "-> Setting up Traefik"
INFRA_DIR="/opt/vps-infra"
if [ ! -d "$INFRA_DIR/.git" ]; then
  if ! git clone https://github.com/h0pers/vps-infra.git "$INFRA_DIR"; then
    echo "ERROR: failed to clone vps-infra - check network and repo access"
    exit 1
  fi
else
  echo "   /opt/vps-infra exists - pulling latest"
  git -C "$INFRA_DIR" pull --ff-only || echo "   WARNING: git pull failed - continuing with current state"
fi
mkdir -p "$INFRA_DIR/traefik/logs"
chown -R root:root "$INFRA_DIR"
chmod -R u=rwX,g=rX,o=rX "$INFRA_DIR"
echo "ACME_EMAIL=$ACME_EMAIL" > "$INFRA_DIR/traefik/.env"
chmod 644 "$INFRA_DIR/traefik/.env"
docker compose -f "$INFRA_DIR/traefik/docker-compose.yml" up -d

echo ""
echo "-> Done."
echo "   Login: ssh $DEPLOY_USER@<server-ip>"
echo "   Traefik: running on 80/443"
echo "   fail2ban: SSH (3/5min) + HTTP (20 errors/5min), incremental banning up to 30d"
echo "   iptables + ip6tables: SYN flood + rate limiting on 22/80/443"
echo "   unattended-upgrades: security patches applied automatically"