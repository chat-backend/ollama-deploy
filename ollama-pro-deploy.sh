#!/bin/bash

########################################
# PRO+ Ollama Deploy Script (Version 10)
# - Multi-domain
# - Auto-update mode
# - Auto SSL renew
# - Cluster / Load Balancing (multi-node Ollama)
# - Per-node health-check & failover
# - Auto-scaling via backends config file
# - Zero-downtime: only nginx reload (no restart)
# - Project config: API_KEY + TOKEN_SECRET + BASE_LINK (config v0.7)
# - Hot-swap node (add/remove backend at runtime)
# - Live draining (ngừng nhận request mới, giữ kết nối đang chạy)
# - Rolling restart từng node (zero-downtime)
# - Auto-drain khi node load cao (CPU)
# - Hooks scale-out / scale-in (tùy hạ tầng)
# - Tuned Ollama runtime (temperature, top_p, top_k, num_predict, stream)
########################################

DOMAINS=("api.aiallplatform.com")

BACKENDS_CONFIG="/etc/ollama/backends.conf"
DRAIN_CONFIG="/etc/ollama/backends.drain"
DEFAULT_BACKENDS=("127.0.0.1:11434")

EMAIL="openaimanage@gmail.com"
LOG_FILE="/var/log/ollama-deploy.log"

CONFIG_DIR="/etc/ollama"
PROJECT_CONFIG_FILE="$CONFIG_DIR/project.conf"
API_KEY_FILE="$CONFIG_DIR/api_key"
SCRIPT_PATH="/usr/local/bin/ollama-pro-deploy.sh"
UPSTREAM_FILE="/etc/nginx/conf.d/ollama-upstream.conf"
HEALTH_SCRIPT="/usr/local/bin/ollama-cluster-health.sh"
AUTO_DRAIN_SCRIPT="/usr/local/bin/ollama-auto-drain.sh"

CPU_THRESHOLD=85   # % CPU để auto-drain
SCALE_OUT_THRESHOLD=90
SCALE_IN_THRESHOLD=30

# Ollama runtime tuning
OLLAMA_TEMPERATURE=0.7
OLLAMA_TOP_P=1.0
OLLAMA_TOP_K=40
OLLAMA_NUM_PREDICT=12000
OLLAMA_STREAM=1

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

check_health_script() {
  if [ ! -f "$HEALTH_SCRIPT" ]; then
    log "⚠ HEALTH_SCRIPT not found → cluster health not initialized yet."
    return 1
  fi
  return 0
}

########################################
# Project config (API_KEY, TOKEN_SECRET, BASE_LINK, VERSION=0.7)
########################################

init_project_config() {
  mkdir -p "$CONFIG_DIR"

  if [ ! -f "$PROJECT_CONFIG_FILE" ]; then
    log "Creating new project config (v0.7)..."

    API_KEY_VALUE=$(openssl rand -hex 64)
    TOKEN_SECRET_VALUE=$(openssl rand -hex 64)
    BASE_LINK_VALUE="https://${DOMAINS[0]}/ollama"

    cat <<EOF >"$PROJECT_CONFIG_FILE"
CONFIG_VERSION=0.7
API_KEY=$API_KEY_VALUE
TOKEN_SECRET=$TOKEN_SECRET_VALUE
BASE_LINK=$BASE_LINK_VALUE
EOF
  else
    log "Using existing project config at $PROJECT_CONFIG_FILE"
  fi

  # shellcheck disable=SC1090
  . "$PROJECT_CONFIG_FILE"

  echo "OLLAMA_API_KEY=$API_KEY" >"$API_KEY_FILE"

  log "Project config loaded:"
  log "  CONFIG_VERSION=$CONFIG_VERSION"
  log "  API_KEY=$API_KEY"
  log "  TOKEN_SECRET=$TOKEN_SECRET"
  log "  BASE_LINK=$BASE_LINK"
}

########################################
# Backends loading (auto-scaling via config)
########################################

load_backends() {
  if [ -f "$BACKENDS_CONFIG" ]; then
    mapfile -t BACKENDS <"$BACKENDS_CONFIG"
  else
    BACKENDS=("${DEFAULT_BACKENDS[@]}")
    mkdir -p "$(dirname "$BACKENDS_CONFIG")"
    printf "%s\n" "${BACKENDS[@]}" >"$BACKENDS_CONFIG"
  fi
  log "Loaded backends: ${BACKENDS[*]}"
}

load_drain_list() {
  if [ -f "$DRAIN_CONFIG" ]; then
    mapfile -t DRAIN_BACKENDS <"$DRAIN_CONFIG"
  else
    DRAIN_BACKENDS=()
  fi
}

is_draining() {
  local BE="$1"
  for d in "${DRAIN_BACKENDS[@]}"; do
    if [ "$d" = "$BE" ]; then
      return 0
    fi
  done
  return 1
}

########################################
# Backend management (hot-swap + drain)
########################################

add_backend() {
  local BE="$1"
  touch "$BACKENDS_CONFIG"

  if grep -qx "$BE" "$BACKENDS_CONFIG"; then
    log "Backend $BE already exists."
    return
  fi

  echo "$BE" >>"$BACKENDS_CONFIG"
  log "Added backend: $BE"
}

remove_backend() {
  local BE="$1"

  if [ ! -f "$BACKENDS_CONFIG" ]; then
    log "No backends config to remove from."
    return
  fi

  grep -vx "$BE" "$BACKENDS_CONFIG" >"${BACKENDS_CONFIG}.tmp" || true
  mv "${BACKENDS_CONFIG}.tmp" "$BACKENDS_CONFIG"
  log "Removed backend: $BE"

  if [ -f "$DRAIN_CONFIG" ]; then
    grep -vx "$BE" "$DRAIN_CONFIG" >"${DRAIN_CONFIG}.tmp" || true
    mv "${DRAIN_CONFIG}.tmp" "$DRAIN_CONFIG"
  fi
}

drain_backend() {
  local BE="$1"
  touch "$DRAIN_CONFIG"

  if grep -qx "$BE" "$DRAIN_CONFIG"; then
    log "Backend $BE is already in draining state."
    return
  fi

  echo "$BE" >>"$DRAIN_CONFIG"
  log "Backend $BE marked as draining (no new traffic)."
}

undrain_backend() {
  local BE="$1"

  if [ ! -f "$DRAIN_CONFIG" ]; then
    log "No drain config file."
    return
  fi

  grep -vx "$BE" "$DRAIN_CONFIG" >"${DRAIN_CONFIG}.tmp" || true
  mv "${DRAIN_CONFIG}.tmp" "$DRAIN_CONFIG"
  log "Backend $BE removed from draining state."
}

########################################
# Rolling restart từng node (zero-downtime)
########################################

rolling_restart() {
  require_root
  load_backends

  log "Starting rolling restart for backends: ${BACKENDS[*]}"

  for BE in "${BACKENDS[@]}"; do
    local HOST
    local PORT
    HOST="${BE%%:*}"
    PORT="${BE##*:}"

    log "Rolling restart backend: $BE"

    drain_backend "$BE"
    if check_health_script; then
      "$HEALTH_SCRIPT" || true
    fi

    if [ "$HOST" = "127.0.0.1" ] || [ "$HOST" = "localhost" ]; then
      log "Restarting local Ollama service for $BE..."
      systemctl restart ollama || log "Failed to restart local ollama for $BE"
    else
      log "Please restart remote node manually or via SSH for $BE (not automated here)."
    fi

    sleep 5

    if curl -fsS --max-time 10 "http://$BE/api/health" >/dev/null 2>&1; then
      log "Backend $BE is healthy again."
      undrain_backend "$BE"
      if check_health_script; then
        "$HEALTH_SCRIPT" || true
      fi
    else
      log "Backend $BE is still unhealthy after restart. Keeping it drained."
    fi
  done

  log "Rolling restart completed."
}

########################################
# Auto-drain & scale hooks
########################################

setup_auto_drain_script() {
  log "Setting up auto-drain script (V12)..."

  cat <<'EOF' >"/usr/local/bin/ollama-auto-drain.sh"
#!/bin/bash

LOG_FILE="/var/log/ollama-auto-drain.log"
BACKENDS_CONFIG="/etc/ollama/backends.conf"
DRAIN_CONFIG="/etc/ollama/backends.drain"
CPU_DRAIN_THRESHOLD=85
CPU_UNDRAIN_THRESHOLD=60
STATE_DIR="/var/lib/ollama-auto-drain"
SCRIPT_PATH="/usr/local/bin/ollama-pro-deploy.sh"

mkdir -p "$STATE_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

if [ ! -f "$BACKENDS_CONFIG" ]; then
  log "No backends config found."
  exit 0
fi

mapfile -t BACKENDS <"$BACKENDS_CONFIG"

DRAIN_BACKENDS=()
if [ -f "$DRAIN_CONFIG" ]; then
  mapfile -t DRAIN_BACKENDS <"$DRAIN_CONFIG"
fi

is_draining() {
  local BE="$1"
  for d in "${DRAIN_BACKENDS[@]}"; do
    if [ "$d" = "$BE" ]; then return 0; fi
  done
  return 1
}

for BE in "${BACKENDS[@]}"; do
  HOST="${BE%%:*}"
  METRICS_URL="http://$HOST:9100/metrics"
  HEALTH_URL="http://$BE/api/health"
  STATE_FILE="$STATE_DIR/cpu_$HOST.state"

  # Nếu chỉ có 1 backend → không bao giờ drain
  if [ ${#BACKENDS[@]} -eq 1 ]; then
    log "Single-backend mode → skipping drain logic"
    exit 0
  fi

  # Kiểm tra backend sống hay chết
  if ! curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null; then
    log "Backend $BE is UNHEALTHY → draining"
    $SCRIPT_PATH --drain-backend "$BE"
    continue
  fi

  # Kiểm tra Node Exporter
  if ! curl -fsS --max-time 2 "$METRICS_URL" >/dev/null; then
    log "Node Exporter unreachable for $BE → draining"
    $SCRIPT_PATH --drain-backend "$BE"
    continue
  fi

  # Lấy snapshot CPU
  CURRENT_SNAPSHOT=$(curl -fsS --max-time 3 "$METRICS_URL" | \
    awk '
      /node_cpu_seconds_total{.*mode="idle"/ { idle += $3 }
      /node_cpu_seconds_total{.*mode!="idle"/ { busy += $3 }
      END { print idle" "busy }
    ')


  CURRENT_IDLE=$(echo "$CURRENT_SNAPSHOT" | awk '{print $1}')
  CURRENT_BUSY=$(echo "$CURRENT_SNAPSHOT" | awk '{print $2}')

  if [ -z "$CURRENT_IDLE" ] || [ -z "$CURRENT_BUSY" ]; then
    log "Cannot read CPU metrics for $BE"
    continue
  fi

  # Lần đầu → lưu state
  if [ ! -f "$STATE_FILE" ]; then
    echo "$CURRENT_IDLE $CURRENT_BUSY" >"$STATE_FILE"
    log "Init CPU state for $BE → waiting next cycle"
    continue
  fi

  read -r PREV_IDLE PREV_BUSY <"$STATE_FILE"

  DELTA_IDLE=$(awk -v c="$CURRENT_IDLE" -v p="$PREV_IDLE" 'BEGIN {print c-p}')
  DELTA_BUSY=$(awk -v c="$CURRENT_BUSY" -v p="$PREV_BUSY" 'BEGIN {print c-p}')
  DELTA_TOTAL=$(awk -v i="$DELTA_IDLE" -v b="$DELTA_BUSY" 'BEGIN {print i+b}')

  if (( $(echo "$DELTA_TOTAL <= 0" | bc -l) )); then
    echo "$CURRENT_IDLE $CURRENT_BUSY" >"$STATE_FILE"
    continue
  fi

  CPU_PERCENT=$(awk -v busy="$DELTA_BUSY" -v total="$DELTA_TOTAL" \
    'BEGIN {printf "%.0f", (busy/total)*100}')

  log "Backend $BE CPU≈${CPU_PERCENT}% (delta-based)"

  echo "$CURRENT_IDLE $CURRENT_BUSY" >"$STATE_FILE"

  # Drain logic
  if [ "$CPU_PERCENT" -ge "$CPU_DRAIN_THRESHOLD" ]; then
    if ! is_draining "$BE"; then
      log "High load → draining $BE"
      $SCRIPT_PATH --drain-backend "$BE"
    else
      log "$BE already draining"
    fi
    continue
  fi

  # Undrain logic
  if [ "$CPU_PERCENT" -le "$CPU_UNDRAIN_THRESHOLD" ]; then
    if is_draining "$BE"; then
      log "CPU normal → undraining $BE"
      $SCRIPT_PATH --undrain-backend "$BE"
    fi
    continue
  fi

  log "$BE in mid-range CPU → no change"
done
EOF

  chmod +x "$AUTO_DRAIN_SCRIPT"

  cat <<EOF >/etc/cron.d/ollama-auto-drain
* * * * * root $AUTO_DRAIN_SCRIPT
EOF
}

########################################
# Pre-checks
########################################

check_dns() {
  for DOMAIN in "${DOMAINS[@]}"; do
    log "Checking DNS for $DOMAIN..."
    if ! getent hosts "$DOMAIN" >/dev/null; then
      log "ERROR: DNS for $DOMAIN not resolved. Fix DNS first."
      exit 1
    fi
    log "DNS OK for $DOMAIN."
  done
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
# System update / Auto-update
########################################

update_system() {
  log "Updating system packages..."
  run "apt update -y"
  run "apt upgrade -y"
}

auto_update_mode() {
  log "🔁 Running in AUTO-UPDATE mode..."
  update_system

  if command -v ollama >/dev/null 2>&1; then
    log "Updating Ollama (if new version available)..."
    run "curl -fsSL https://ollama.com/install.sh | sh"
  fi

  log "Reloading services: ollama, nginx, node_exporter, fail2ban..."
  systemctl reload ollama 2>/dev/null || systemctl restart ollama || true

  if nginx -t >/dev/null 2>&1; then
    nginx -s reload || log "WARN: nginx reload failed"
  fi

  systemctl reload node_exporter 2>/dev/null || systemctl restart node_exporter || true
  systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban || true

  log "AUTO-UPDATE completed."
  exit 0
}

########################################
# Ollama install & service (local node)
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

  log "Configuring Ollama systemd service (V10)..."

  cat <<EOF >"$SERVICE_FILE"
[Unit]
Description=Ollama Server
After=network.target

[Service]
ExecStart=/usr/local/bin/ollama serve
Restart=always
User=root

Environment=OLLAMA_NUM_THREADS=4
Environment=OLLAMA_TEMPERATURE=${OLLAMA_TEMPERATURE}
Environment=OLLAMA_TOP_P=${OLLAMA_TOP_P}
Environment=OLLAMA_TOP_K=${OLLAMA_TOP_K}
Environment=OLLAMA_NUM_PREDICT=${OLLAMA_NUM_PREDICT}
Environment=OLLAMA_STREAM=${OLLAMA_STREAM}

[Install]
WantedBy=multi-user.target
EOF

  run "systemctl daemon-reload"
  run "systemctl enable ollama"
  run "systemctl restart ollama"
  log "Ollama service configured and running with tuned parameters (V10)."
}

########################################
# Certbot & SSL (multi-domain)
########################################

install_certbot() {
  if command -v certbot >/dev/null 2>&1; then
    log "Certbot already installed."
  else
    log "Installing Certbot..."
    run "apt install certbot -y"
  fi
}

issue_ssl_for_domain() {
  local DOMAIN="$1"
  log "Requesting SSL certificate for $DOMAIN..."

  # FIX: Không chạy certbot nếu cert đã tồn tại
  if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    log "SSL for $DOMAIN already exists → skipping certbot."
    return
  fi

  # Tắt nginx để standalone certbot chạy
  if systemctl is-active --quiet nginx; then
    log "Stopping nginx temporarily for standalone Certbot..."
    run "systemctl stop nginx"
  fi

  run "certbot certonly --standalone -d \"$DOMAIN\" --non-interactive --agree-tos -m \"$EMAIL\""

  log "SSL certificate obtained for $DOMAIN."
}

setup_certbot_renew_cron() {
  log "Setting up daily SSL auto-renew (cron)..."

  cat <<EOF >/etc/cron.daily/certbot-renew
#!/bin/bash
/usr/bin/certbot renew --quiet
EOF

  chmod +x /etc/cron.daily/certbot-renew
}

########################################
# Nginx install & config (multi-domain, cluster)
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

generate_upstream_block() {
  log "Creating/updating Nginx upstream cluster config..."

  cat <<EOF >"$UPSTREAM_FILE"
upstream ollama_cluster {
    least_conn;
EOF

  for BE in "${BACKENDS[@]}"; do
    echo "    server $BE max_fails=3 fail_timeout=30s;" >>"$UPSTREAM_FILE"
  done

  cat <<EOF >>"$UPSTREAM_FILE"
}
EOF
}

configure_nginx_site_for_domain() {
  local DOMAIN="$1"
  local SITE_FILE="/etc/nginx/sites-available/ollama-$DOMAIN"

  log "Creating/updating Nginx site for Ollama on $DOMAIN..."

  . "$PROJECT_CONFIG_FILE"

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

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Authorization, Content-Type, x-api-key" always;

    if (\$request_method = OPTIONS) {
        return 204;
    }

    location = /ollama/api/health {
        proxy_pass http://ollama_cluster/api/health;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 60;
        proxy_send_timeout 60;
        proxy_buffering off;
    }

    location /ollama {
        if (\$http_x_api_key = "") {
            return 401;
        }

        if (\$http_x_api_key != "$API_KEY") {
            return 403;
        }

        proxy_pass http://ollama_cluster;
        proxy_http_version 1.1;

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

  run "ln -sf /etc/nginx/sites-available/ollama-$DOMAIN /etc/nginx/sites-enabled/ollama-$DOMAIN"
}

reload_nginx() {
  log "Testing Nginx config..."
  if nginx -t; then
    log "Reloading Nginx..."
    nginx -s reload || log "WARN: nginx reload failed (but config is valid)"
  else
    log "ERROR: Nginx config invalid. Not reloading."
  fi
}

########################################
# Cluster health-check & dynamic upstream
########################################

setup_cluster_health_script() {
  log "Setting up cluster health-check script..."

  cat <<'EOF' >"/usr/local/bin/ollama-cluster-health.sh"
#!/bin/bash

LOG_FILE="/var/log/ollama-cluster-health.log"
BACKENDS_CONFIG="/etc/ollama/backends.conf"
DRAIN_CONFIG="/etc/ollama/backends.drain"
UPSTREAM_FILE="/etc/nginx/conf.d/ollama-upstream.conf"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

if [ ! -f "$BACKENDS_CONFIG" ]; then
  log "No backends config found at $BACKENDS_CONFIG"
  exit 0
fi

mapfile -t BACKENDS <"$BACKENDS_CONFIG"

DRAIN_BACKENDS=()
if [ -f "$DRAIN_CONFIG" ]; then
  mapfile -t DRAIN_BACKENDS <"$DRAIN_CONFIG"
fi

is_draining() {
  local BE="$1"
  for d in "${DRAIN_BACKENDS[@]}"; do
    if [ "$d" = "$BE" ]; then return 0; fi
  done
  return 1
}

HEALTHY_BACKENDS=()

for BE in "${BACKENDS[@]}"; do
  if is_draining "$BE"; then
    log "Backend draining (skip new traffic): $BE"
    continue
  fi

  URL="http://$BE/api/health"
  if curl -fsS --max-time 3 "$URL" >/dev/null; then
    log "Backend healthy: $BE"
    HEALTHY_BACKENDS+=("$BE")
  else
    log "Backend UNHEALTHY: $BE"
  fi
done

if [ ${#HEALTHY_BACKENDS[@]} -eq 0 ]; then
  log "No healthy backends found. Keeping previous upstream."
  exit 0
fi

log "Updating upstream with healthy backends: ${HEALTHY_BACKENDS[*]}"

{
  echo "upstream ollama_cluster {"
  echo "    least_conn;"
  for BE in "${HEALTHY_BACKENDS[@]}"; do
    echo "    server $BE max_fails=3 fail_timeout=30s;"
  done
  echo "}"
} >"$UPSTREAM_FILE"

if nginx -t >/dev/null 2>&1; then
  nginx -s reload || log "WARN: nginx reload failed"
else
  log "ERROR: invalid nginx config"
fi
EOF

  chmod +x "$HEALTH_SCRIPT"
}

setup_cluster_health_cron() {
  log "Setting up per-node health-check cron (every minute)..."

  cat <<EOF >/etc/cron.d/ollama-cluster-health
* * * * * root $HEALTH_SCRIPT
EOF
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

  cd /tmp || exit 1
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

setup_auto_update_cron() {
  log "Setting up weekly auto-update (cron)..."

  cat <<EOF >/etc/cron.weekly/ollama-auto-update
#!/bin/bash
$SCRIPT_PATH --update
EOF

  chmod +x /etc/cron.weekly/ollama-auto-update
}

########################################
# Main
########################################

usage() {
  cat <<EOF
Usage: $0 [command]

Commands:
  (no args)           Full deploy / install
  --update            Auto-update mode
  --add-backend HOST:PORT
  --remove-backend HOST:PORT
  --drain-backend HOST:PORT
  --undrain-backend HOST:PORT
  --rolling-restart   Rolling restart all backends (zero-downtime)
EOF
}

main() {
  require_root

  case "$1" in
    --update)
      auto_update_mode
      ;;
    --add-backend)
      add_backend "$2"
      if check_health_script; then
        "$HEALTH_SCRIPT" 2>/dev/null || true
      fi
      exit 0
      ;;
    --remove-backend)
      remove_backend "$2"
      if check_health_script; then
        "$HEALTH_SCRIPT" 2>/dev/null || true
      fi
      exit 0
      ;;
    --drain-backend)
      drain_backend "$2"
      if check_health_script; then
        "$HEALTH_SCRIPT" 2>/dev/null || true
      fi
      exit 0
      ;;
    --undrain-backend)
      undrain_backend "$2"
      if check_health_script; then
        "$HEALTH_SCRIPT" 2>/dev/null || true
      fi
      exit 0
      ;;
    --rolling-restart)
      if ! check_health_script; then
        log "❌ Cannot perform rolling restart — HEALTH_SCRIPT missing."
        exit 1
      fi
      rolling_restart
      exit 0
      ;;
    "" )
      ;;
    *)
      usage
      exit 1
      ;;
  esac

  log "🚀 Starting PRO+ Ollama deployment (V10) for domains: ${DOMAINS[*]}"

  init_project_config
  load_backends
  log "🔗 Cluster backends (from config): ${BACKENDS[*]}"

  check_dns
  check_port_80
  update_system

  install_ollama
  configure_ollama_service

  install_certbot
  install_nginx
  harden_nginx_global
  generate_upstream_block

  for DOMAIN in "${DOMAINS[@]}"; do
    issue_ssl_for_domain "$DOMAIN"
    configure_nginx_site_for_domain "$DOMAIN"
  done

  reload_nginx

  setup_autoload_model
  setup_fail2ban
  setup_monitoring
  setup_backup
  setup_firewall
  setup_certbot_renew_cron
  setup_auto_update_cron
  setup_cluster_health_script
  setup_cluster_health_cron
  setup_auto_drain_script

  # shellcheck disable=SC1090
  . "$PROJECT_CONFIG_FILE"

  for DOMAIN in "${DOMAINS[@]}"; do
    log "🎉 DONE! Your PRO+ Ollama Cluster is live on: https://$DOMAIN/ollama"
    log "👉 Tags:   https://$DOMAIN/ollama/api/tags"
    log "👉 Health: https://$DOMAIN/ollama/api/health"
  done

  log "👉 Project config (v$CONFIG_VERSION):"
  log "    BASE_LINK=$BASE_LINK"
  log "    API_KEY=$API_KEY"
  log "    TOKEN_SECRET=$TOKEN_SECRET"
  log "👉 Use this in your Gateway (example):"
  log "    OLLAMA_URL_ONLINE=$BASE_LINK"
  log "    x-api-key: $API_KEY"

  scale_out_hook
  scale_in_hook
}

main "$@"
