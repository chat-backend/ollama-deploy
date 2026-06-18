#!/bin/bash

DOMAIN="api.aiall.com"
EMAIL="admin@aiall.com"

echo "🚀 Auto-deploy Ollama Server for $DOMAIN"

apt update -y && apt upgrade -y

curl -fsSL https://ollama.com/install.sh | sh

cat <<EOF >/etc/systemd/system/ollama.service
[Unit]
Description=Ollama Server
After=network.target

[Service]
ExecStart=/usr/local/bin/ollama serve
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl enable ollama
systemctl start ollama

apt install nginx -y

cat <<EOF >/etc/nginx/sites-available/ollama
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

    location /ollama/ {
        proxy_pass http://127.0.0.1:11434/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        proxy_buffering off;
    }

    add_header Access-Control-Allow-Origin *;
    add_header Access-Control-Allow-Methods "GET, POST, OPTIONS";
    add_header Access-Control-Allow-Headers "Authorization, Content-Type, x-api-key";

    if (\$request_method = OPTIONS) {
        return 204;
    }
}
EOF

ln -s /etc/nginx/sites-available/ollama /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

apt install certbot python3-certbot-nginx -y
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

echo "🎉 DONE! Your Ollama Server is live:"
echo "👉 https://$DOMAIN/ollama/api/tags"
echo "👉 Use this in your Gateway:"
echo "    OLLAMA_URL_ONLINE=https://$DOMAIN/ollama"
