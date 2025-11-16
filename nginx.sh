#!/bin/bash
# Pterodactyl Panel Nginx + SSL Setup Script
# ------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# ---------- Variables ----------
read -p "Enter your Panel Domain (FQDN, e.g., node.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && echo "Domain is required." && exit 1

# ---------- Step 1: Create SSL folder ----------
echo "[INFO] Creating SSL folder..."
mkdir -p /etc/certs/certs
cd /etc/certs/certs

# ---------- Step 2: Generate self-signed SSL ----------
echo "[INFO] Generating self-signed SSL..."
openssl req \
  -new \
  -newkey rsa:4096 \
  -days 3650 \
  -nodes \
  -x509 \
  -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
  -keyout privkey.pem \
  -out fullchain.pem

echo "[OK] SSL generated at /etc/certs/certs"

# ---------- Step 3: Remove default Nginx ----------
echo "[INFO] Removing default Nginx site..."
rm -f /etc/nginx/sites-enabled/default

# ---------- Step 4: Create Nginx config ----------
NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"
echo "[INFO] Creating Nginx configuration..."

cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    ssl_certificate /etc/certs/certs/fullchain.pem;
    ssl_certificate_key /etc/certs/certs/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

echo "[OK] Nginx configuration created at $NGINX_CONF"

# ---------- Step 5: Enable site ----------
echo "[INFO] Enabling Nginx site..."
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pterodactyl.conf

# ---------- Step 6: Test and restart Nginx ----------
echo "[INFO] Testing Nginx configuration..."
nginx -t

echo "[INFO] Restarting Nginx..."
systemctl restart nginx

echo "[OK] Nginx setup complete. Your site should be available at https://$DOMAIN"
