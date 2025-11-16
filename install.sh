#!/bin/bash
# Pterodactyl Panel Full Installer (Debian/Ubuntu)
# ==================================================

set -euo pipefail
IFS=$'\n\t'

RED='\033[1;31m'; GREEN='\033[1;32m'; BLUE='\033[1;34m'; NC='\033[0m'
log(){ echo -e "${BLUE}[INFO]${NC} $1"; }
ok(){ echo -e "${GREEN}[OK]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# Require root
if [ "$EUID" -ne 0 ]; then err "Run as root."; fi

clear
echo -e "${GREEN}Pterodactyl Panel Installer beta${NC}\n"

# ---------- User Input ----------
read -p "Panel Domain (FQDN, e.g., node.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && err "Domain required."

read -p "Admin Email [admin@$DOMAIN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$DOMAIN"}

read -p "Admin Username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -s -p "Admin Password (blank=random): " ADMIN_PASS
echo
if [[ -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS="$(openssl rand -base64 18)"
  log "Random admin password: $ADMIN_PASS"
fi

DB_PASS="$(openssl rand -base64 32)"
TIMEZONE="Asia/Kolkata"

# ---------- Install Dependencies ----------
log "Installing dependencies..."
apt-get update -y
apt-get install -y lsb-release gnupg2 software-properties-common curl wget unzip git mariadb-server mariadb-client redis-server nginx tar build-essential openssl || err "Dependencies failed"
ok "Dependencies installed."

# ---------- Install PHP 8.1 ----------
log "Installing PHP 8.1..."
add-apt-repository -y ppa:ondrej/php
apt-get update -y
apt-get install -y php8.1 php8.1-fpm php8.1-cli php8.1-mbstring php8.1-xml php8.1-curl php8.1-zip php8.1-gd php8.1-bcmath php8.1-mysql || err "PHP install failed"
ok "PHP installed."

# ---------- Setup Database ----------
log "Setting up MySQL database..."
systemctl enable --now mariadb
mysql <<SQL
DROP DATABASE IF EXISTS pterodactyl;
CREATE DATABASE pterodactyl;
DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON pterodactyl.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
ok "Database created. User: pterodactyl, Password: $DB_PASS"

# ---------- Download Panel ----------
log "Downloading Pterodactyl Panel..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -sL -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
cp .env.example .env
chmod -R 755 storage bootstrap/cache

# ---------- Update .env ----------
log "Updating .env file..."
sed -i "s|DB_DATABASE=.*|DB_DATABASE=pterodactyl|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=pterodactyl|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" .env
sed -i "s|APP_URL=.*|APP_URL=https://$DOMAIN|" .env
sed -i "s|APP_TIMEZONE=.*|APP_TIMEZONE=$TIMEZONE|" .env

# ---------- Composer & Migrations ----------
log "Installing PHP dependencies..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
composer install --no-dev --optimize-autoloader --no-interaction
php artisan key:generate --force
php artisan config:clear
php artisan cache:clear
php artisan migrate --seed --force

# ---------- Create Admin User ----------
log "Creating admin user..."
php artisan p:user:make \
  --email "$ADMIN_EMAIL" \
  --username "$ADMIN_USER" \
  --first-name "Admin" \
  --last-name "User" \
  --admin 1 \
  --password "$ADMIN_PASS" \
  --no-interaction

# ---------- SSL Certificate ----------
log "Generating self-signed SSL certificate..."
mkdir -p /etc/certs/certs
cd /etc/certs/certs
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
  -keyout privkey.pem \
  -out fullchain.pem
ok "SSL cert created in /etc/certs/certs"

# ---------- Nginx Configuration ----------
log "Configuring Nginx..."
rm -f /etc/nginx/sites-enabled/default

NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"
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
EOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t && systemctl restart nginx || warn "Nginx reload failed."
ok "Nginx configured."

# ---------- Finished ----------
clear
ok "PTERODACTYL PANEL INSTALL COMPLETE!"
echo "Domain: https://$DOMAIN"
echo "Admin Username: $ADMIN_USER"
echo "Admin Email: $ADMIN_EMAIL"
echo "Admin Password: $ADMIN_PASS"
echo "DB User: pterodactyl"
echo "DB Password: $DB_PASS"
echo "SSL folder: /etc/certs/certs"
