#!/bin/bash

########################################
# PRO+ Ollama Deploy Script (Full)
########################################

DOMAIN="api.aiallplatform.com"
EMAIL="openaimanage@gmail.com"
LOG_FILE="/var/log/ollama-deploy.log"

########################################
# Helpers
########################################

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

run() {
  log "RUN: $*"
  eval "$@" >>"$LOG_FILE" 2>&1
  if [ $? -ne 0 ]; then
    log "ERROR: Command failed → $*"
    exit 1
  fi
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

########################################
# Pre-checks
########################################

check_dns() {
  log "Checking DNS for $DOMAIN..."
  if ! getent hosts "$DOMAIN" >/dev/null; then
    log "ERROR: DNS for $DOMAIN not resolved. Fix DNS first."
    exit 1
  fi
  log "DNS OK for $DOMAIN."
}

check_port_80() {
  log "Checking if port 80 is free..."
  if ss -tuln | grep -q ':80 '; then
    log "Port 80 is in use (likely by nginx). OK."
  else
    log "Port 80 appears free."
  fi
}

########################################
# System update
########################################

update_system() {
  log "Updating system packages..."
  run "apt update -y"
  run "apt upgrade -y"
}

########################################
# Ollama install & service
########################################

install_ollama() {
  if command -v ollama >/dev/null 2>&1; then
    log "Ollama already installed. Skipping install."
  else
    log "Installing Ollama..."
    run "curl -fsSL https://ollama.com/install.sh | sh"
  fi
}

configure_ollama_service() {
  local SERVICE_FILE="/etc/systemd/system/ollama.service"

  log "Configuring Ollama systemd service..."

  cat <<EOF >"$SERVICE_FILE"
[Unit]
Description=Ollama Server
After=network.target

[Service]
ExecStart=/usr/local/bin/ollama serve
Restart=always
User=root
Environment=OLLAMA_NUM_THREADS=4

[Install]
WantedBy=multi-user.target
EOF

  run "systemctl daemon-reload"
  run "systemctl enable ollama"
  run "systemctl restart ollama"
  log "Ollama service configured and running."
}

########################################
# Nginx install & config
########################################

install_nginx() {
  if command -v nginx >/dev/null 2>&1; then
    log "Nginx already installed."
  else
    log "Installing Nginx..."
    run "apt install nginx -y"
  fi
}

harden_nginx_global() {
  local NGINX_CONF="/etc/nginx/nginx.conf"

  log "Hardening Nginx global config..."
  sed -i 's/# server_tokens off;/server_tokens off;/g' "$NGINX_CONF" || true
  if ! grep -q "server_tokens off;" "$NGINX_CONF"; then
    echo "server_tokens off;" >>"$NGINX_CONF"
  fi
}

configure_nginx_site() {
  local SITE_FILE="/etc/nginx/sites-available/ollama"

  log "Creating/updating Nginx site for Ollama..."

  cat <<EOF >"$SITE_FILE"
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    client_max_body_size 50M;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    # CORS
    add_header Access-Control-Allow-Origin *;
    add_header Access-Control-Allow-Methods "GET, POST, OPTIONS";
    add_header Access-Control-Allow-Headers "Authorization, Content-Type, x-api-key";

    if (\$request_method = OPTIONS) {
        return 204;
    }

    location /ollama/ {
        proxy_pass http://127.0.0.1:11434/;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        proxy_buffering off;
    }
}
EOF

  run "ln -sf /etc/nginx/sites-available/ollama /etc/nginx/sites-enabled/ollama"
  run "nginx -t"
  run "systemctl restart nginx"
}

########################################
# Certbot & SSL
########################################

install_certbot() {
  if command -v certbot >/dev/null 2>&1; then
    log "Certbot already installed."
  else
    log "Installing Certbot..."
    run "apt install certbot python3-certbot-nginx -y"
  fi
}

issue_ssl() {
  log "Requesting SSL certificate..."
  run "certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL --redirect"
}

########################################
# PRO+ FEATURES
########################################

setup_autoload_model() {
  log "Setting up auto-load model..."

  cat <<EOF >/usr/local/bin/ollama-autoload.sh
#!/bin/bash
sleep 5
/usr/local/bin/ollama pull llama3
EOF

  chmod +x /usr/local/bin/ollama-autoload.sh

  cat <<EOF >/etc/systemd/system/ollama-autoload.service
[Unit]
Description=Auto-load Ollama model on boot
After=ollama.service

[Service]
ExecStart=/usr/local/bin/ollama-autoload.sh
Type=oneshot

[Install]
WantedBy=multi-user.target
EOF

  run "systemctl daemon-reload"
  run "systemctl enable ollama-autoload"
}

setup_api_key_protection() {
  log "Setting up API key protection..."

  API_KEY_FILE="/etc/ollama/api_key"
  mkdir -p /etc/ollama

  if [ ! -f "$API_KEY_FILE" ]; then
    echo "OLLAMA_API_KEY=$(openssl rand -hex 32)" > "$API_KEY_FILE"
  fi

  source "$API_KEY_FILE"
  log "API Key: $OLLAMA_API_KEY"

  sed -i '/location \/ollama\//a \
        if ($http_x_api_key != "'"$OLLAMA_API_KEY"'") { return 401; }' \
        /etc/nginx/sites-available/ollama

  run "nginx -t"
  run "systemctl restart nginx"
}

setup_fail2ban() {
  log "Installing Fail2ban..."
  run "apt install fail2ban -y"

  cat <<EOF >/etc/fail2ban/jail.d/nginx-ollama.conf
[nginx-ollama]
enabled = true
port = http,https
filter = nginx-ollama
logpath = /var/log/nginx/access.log
maxretry = 20
bantime = 3600
EOF

  cat <<EOF >/etc/fail2ban/filter.d/nginx-ollama.conf
[Definition]
failregex = ^<HOST> -.*"(GET|POST).*"
EOF

  run "systemctl restart fail2ban"
}

setup_monitoring() {
  log "Installing Node Exporter..."

  run "useradd -rs /bin/false node_exporter || true"

  cd /tmp
  curl -LO https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
  tar xvf node_exporter-1.7.0.linux-amd64.tar.gz
  cp node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/

  cat <<EOF >/etc/systemd/system/node_exporter.service
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=default.target
EOF

  run "systemctl daemon-reload"
  run "systemctl enable node_exporter"
  run "systemctl start node_exporter"
}

setup_backup() {
  log "Setting up daily backup..."

  mkdir -p /var/backups/ollama-models

  cat <<EOF >/etc/cron.daily/ollama-backup
#!/bin/bash
cp -r /root/.ollama/models /var/backups/ollama-models/
EOF

  chmod +x /etc/cron.daily/ollama-backup
}

setup_firewall() {
  log "Configuring firewall..."

  run "apt install ufw -y"
  run "ufw allow 22"
  run "ufw allow 80"
  run "ufw allow 443"
  run "ufw --force enable"
}

########################################
# Main
########################################

main() {
  require_root
  log "🚀 Starting PRO+ Ollama deployment for $DOMAIN"

  check_dns
  check_port_80
  update_system

  install_ollama
  configure_ollama_service

  install_nginx
  harden_nginx_global
  configure_nginx_site

  install_certbot
  issue_ssl

  setup_autoload_model
  setup_api_key_protection
  setup_fail2ban
  setup_monitoring
  setup_backup
  setup_firewall

  log "🎉 DONE! Your PRO+ Ollama Server is live:"
  log "👉 https://$DOMAIN/ollama/api/tags"
  log "👉 Use this in your Gateway:"
  log "    OLLAMA_URL_ONLINE=https://$DOMAIN/ollama"
}

main
