#!/bin/bash
# PTERODACTYL PANEL INSTALLER (Debian/Ubuntu)
set -euo pipefail
IFS=$'\n\t'

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log(){ echo -e "${BLUE}[INFO]${NC} $1"; }
ok(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

if [ "$EUID" -ne 0 ]; then err "Run as root."; fi

clear
echo -e "${GREEN}PTERODACTYL PANEL INSTALLER${NC}\n"

# ---------- User Input ----------
read -p "Panel FQDN (e.g. node.example.com): " FQDN
[[ -z "$FQDN" ]] && err "FQDN required."
read -p "Email (for alerts): " EMAIL
[[ -z "$EMAIL" ]] && err "Email required."
read -p "Admin Username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}
read -p "Admin Email [admin@$FQDN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}
read -s -p "Admin Password (blank=random): " ADMIN_PASS
echo
[[ -z "$ADMIN_PASS" ]] && ADMIN_PASS="$(openssl rand -base64 18)" && warn "Random admin password: $ADMIN_PASS"

DB_PASS="$(openssl rand -base64 32)"
TIMEZONE="Asia/Kolkata"

# ---------- Install base deps ----------
apt-get update -y
apt-get install -y ca-certificates curl wget lsb-release gnupg2 unzip git tar build-essential openssl software-properties-common nginx mariadb-server mariadb-client redis-server php8.1 php8.1-fpm php8.1-cli php8.1-mbstring php8.1-xml php8.1-curl php8.1-zip php8.1-gd php8.1-bcmath php8.1-mysql || err "Dependencies failed"
systemctl enable --now mariadb

# ---------- Database ----------
log "Creating MySQL database and user..."
mysql <<SQL || err "MySQL commands failed"
DROP DATABASE IF EXISTS pterodactyl;
CREATE DATABASE pterodactyl;
DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON pterodactyl.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
ok "Database created with password: $DB_PASS"

# ---------- Panel ----------
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -sL -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
chmod -R 755 storage bootstrap/cache
cp .env.example .env || true

# ---------- .env ----------
sed -i "s|DB_DATABASE=.*|DB_DATABASE=pterodactyl|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=pterodactyl|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" .env
sed -i "s|APP_URL=.*|APP_URL=https://$FQDN|" .env
sed -i "s|APP_TIMEZONE=.*|APP_TIMEZONE=$TIMEZONE|" .env
grep -q '^MAIL_FROM_ADDRESS' .env || echo "MAIL_FROM_ADDRESS=noreply@$FQDN" >> .env
grep -q '^MAIL_FROM_NAME' .env || echo "MAIL_FROM_NAME=\"Pterodactyl Panel\"" >> .env

chown -R www-data:www-data /var/www/pterodactyl

# ---------- Composer ----------
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
composer install --no-dev --optimize-autoloader --no-interaction
php artisan key:generate --force
php artisan config:clear
php artisan cache:clear
php artisan migrate --seed --force
php artisan p:user:make --email "$ADMIN_EMAIL" --username "$ADMIN_USER" --admin 1 --password "$ADMIN_PASS" --no-interaction

# ---------- SSL ----------
mkdir -p /etc/certs/certs
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
  -keyout /etc/certs/certs/privkey.pem \
  -out /etc/certs/certs/fullchain.pem

# ---------- Nginx ----------
rm -f /etc/nginx/sites-enabled/default
NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"
cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $FQDN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $FQDN;

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log /var/log/nginx/pterodactyl.app-error.log error;

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

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht { deny all; }
}
EOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pterodactyl.conf
systemctl restart nginx

# ---------- Done ----------
clear
ok "PTERODACTYL PANEL INSTALL COMPLETE"
echo "Panel HTTPS: https://$FQDN"
echo "Admin username: $ADMIN_USER"
echo "Admin email: $ADMIN_EMAIL"
echo "Admin password: $ADMIN_PASS"
echo "DB password: $DB_PASS"
echo "SSL cert: /etc/certs/certs/fullchain.pem"
echo "=========================================="
