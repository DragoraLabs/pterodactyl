#!/bin/bash
# ==================================================
#  PTERODACTYL PANEL‑ONLY (HTTP on 8080 + HTTPS redirect)
#  Debian 11 (Bullseye) – ARCHIVED backports + DB reset
#  No Wings | Self‑signed SSL ready
# ==================================================

set -euo pipefail

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

clear
echo -e "${GREEN}PTERODACTYL PANEL‑ONLY (HTTP on 8080 + HTTPS redirect)${NC}\n"

# === Input ===
read -p "Panel FQDN (e.g. node.gamerhost.qzz.io): " FQDN
[[ -z "$FQDN" ]] && error "FQDN required!"

read -p "Email (for alerts): " EMAIL
[[ -z "$EMAIL" ]] && error "Email required!"

read -p "Admin Username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -p "Admin Email [admin@$FQDN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}

read -s -p "Admin Password (blank = random): " ADMIN_PASS
echo
[[ -z "$ADMIN_PASS" ]] && ADMIN_PASS=$(openssl rand -base64 18) && warn "Random password generated!"

DB_PASS=$(openssl rand -base64 32)
TIMEZONE="Asia/Kolkata"
PANEL_PORT=8080

echo -e "\n${BLUE}Starting with:${NC}"
echo "   FQDN: $FQDN | Port: $PANEL_PORT | Admin: $ADMIN_USER"
read -p "Press Enter to begin..."

# === 1. Remove dead backports ===
log "Removing dead backports..."
rm -f /etc/apt/sources.list.d/backports.list /etc/apt/sources.list.d/bullseye-backports.list 2>/dev/null || true
sed -i '/bullseye-backports/d' /etc/apt/sources.list 2>/dev/null || true

# === 2. Add archived backports ===
log "Adding archived Debian backports..."
cat > /etc/apt/sources.list.d/bullseye-backports.list <<EOF
deb http://archive.debian.org/debian bullseye-backports main contrib non-free
EOF

# === 3. Disable expired key check ===
log "Disabling expired repo key check..."
echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

# === Update & install PHP 8.1 ===
log "Updating package list & installing PHP 8.1..."
apt update
apt install -y -t bullseye-backports \
    php8.1 php8.1-{cli,fpm,curl,mbstring,xml,bcmath,zip,gd,mysql}

# === Install other deps ===
log "Installing Nginx, MariaDB, Redis, Composer..."
apt install -y \
    curl wget ca-certificates \
    nginx mariadb-server mariadb-client redis-server unzip git tar

# === 4. Reset DB if exists ===
log "Dropping & recreating database..."
systemctl start mariadb
mysql <<SQL
DROP DATABASE IF EXISTS pterodactyl;
CREATE DATABASE pterodactyl;
DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL ON pterodactyl.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# === Composer ===
log "Installing Composer..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# === Panel download ===
log "Creating /var/www/pterodactyl..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
chmod -R 755 storage bootstrap/cache

# === .env ===
cat > .env <<ENV
APP_URL=http://$FQDN:$PANEL_PORT
APP_TIMEZONE=$TIMEZONE
APP_SERVICE_AUTHOR=noreply@$FQDN
DB_PASSWORD=$DB_PASS
CACHE_DRIVER=redis
SESSION_DRIVER=redis
QUEUE_DRIVER=redis
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379
MAIL_FROM_ADDRESS=noreply@$FQDN
MAIL_FROM_NAME="Pterodactyl Panel"
ENV

cp .env.example .env
chown -R www-data:www-data /var/www/pterodactyl

# === Install Panel ===
log "Running Composer & migrations..."
composer install --no-dev --optimize-autoloader --no-interaction
php artisan key:generate --force
php artisan migrate --seed --force
php artisan p:user:make \
    --email "$ADMIN_EMAIL" \
    --username "$ADMIN_USER" \
    --admin 1 \
    --password "$ADMIN_PASS" \
    --no-interaction

# === Self‑signed SSL ===
log "Generating self‑signed SSL certs..."
mkdir -p /etc/letsencrypt/live/$FQDN
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/C=IN/ST=NA/L=NA/O=GameHost/CN=$FQDN" \
  -keyout /etc/letsencrypt/live/$FQDN/privkey.pem \
  -out /etc/letsencrypt/live/$FQDN/fullchain.pem

# === 5. Remove default Nginx config ===
log "Removing default Nginx config..."
rm -f /etc/nginx/sites-enabled/default

# === 6. New Nginx config (HTTP 8080 → HTTPS 443 redirect) ===
log "Writing new Nginx config..."
cat > /etc/nginx/sites-available/pterodactyl.conf <<NGINX
server {
    listen 80;
    server_name $FQDN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $FQDN;

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    ssl_certificate /etc/letsencrypt/live/$FQDN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$FQDN/privkey.pem;
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

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
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
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINX

# === Enable config ===
ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# === Panel on 8080 (reverse proxy) ===
log "Adding reverse proxy on port 8080..."
cat > /etc/nginx/sites-available/pterodactyl-8080 <<PROXY
server {
    listen $PANEL_PORT;
    server_name $FQDN;

    location / {
        proxy_pass http://127.0.0.1:9000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
PROXY

ln -sf /etc/nginx/sites-available/pterodactyl-8080 /etc/nginx/sites-enabled/
systemctl reload nginx

# === Firewall ===
log "Opening ports 80, 443, 8080..."
ufw allow 80,443,8080 || true
ufw reload || true

# === Final Output ===
clear
success "PTERODACTYL PANEL INSTALLED!"
echo
echo "=========================================="
echo "   LOGIN DETAILS (SAVE THIS!)"
echo "=========================================="
echo "HTTP (Panel): http://$FQDN:$PANEL_PORT"
echo "HTTPS (Main): https://$FQDN"
echo "Username: $ADMIN_USER"
echo "Email: $ADMIN_EMAIL"
echo "Password: $ADMIN_PASS"
echo
echo "Self‑signed SSL used. For real SSL:"
echo "   certbot --nginx -d $FQDN"
echo "=========================================="
