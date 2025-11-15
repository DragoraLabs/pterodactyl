#!/bin/bash
# ==============================================
#  YOUR Interactive Pterodactyl Installer
#  Asks for FQDN, Email, Admin — Auto DB + SSL
#  Target: Ubuntu 22.04 / 24.04 LTS
# ==============================================

set -euo pipefail

# Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# === Interactive Input ===
clear
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   YOUR PTERODACTYL INSTALLER${NC}"
echo -e "${GREEN}========================================${NC}"
echo

read -p "Enter Panel FQDN (e.g. panel.example.com): " FQDN
[[ -z "$FQDN" ]] && err "FQDN cannot be empty!"

read -p "Enter Email for SSL & Alerts: " EMAIL
[[ -z "$EMAIL" ]] && err "Email cannot be empty!"

read -p "Admin Username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -p "Admin Email [admin@$FQDN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}

read -s -p "Admin Password (leave blank for random): " ADMIN_PASSWORD
echo
if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD=$(openssl rand -base64 18)
    echo -e "${YELLOW}Generated random admin password!${NC}"
else
    [[ ${#ADMIN_PASSWORD} -lt 8 ]] && err "Password too short! Use 8+ chars."
fi

# Generate DB password
DB_PASS=$(openssl rand -base64 32)
TIMEZONE="Asia/Kolkata"

echo
echo -e "${BLUE}Configuration:${NC}"
echo "   FQDN: $FQDN"
echo "   Email: $EMAIL"
echo "   Admin: $ADMIN_USER ($ADMIN_EMAIL)"
echo "   DB Pass: (auto-generated)"
echo "   SSL: Let's Encrypt"
echo
read -p "Press Enter to begin installation..."

# === System Prep ===
log "Updating system..."
apt update && apt upgrade -y

log "Installing dependencies..."
apt install -y software-properties-common curl gnupg2 ca-certificates lsb-release

# PHP 8.3 for Ubuntu 24.04+
if lsb_release -rs | grep -q "24.04"; then
    add-apt-repository ppa:ondrej/php -y
fi

apt update
apt install -y php8.3 php8.3-{cli,fpm,curl,mbstring,xml,bcmath,zip,gd,mysql} \
    nginx mariadb-server mariadb-client redis-server unzip git tar snapd

# === MariaDB Setup ===
log "Securing MariaDB..."
systemctl start mariadb
mysql <<EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
CREATE DATABASE pterodactyl;
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON pterodactyl.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

# === Composer ===
log "Installing Composer..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# === Panel Download ===
log "Downloading Pterodactyl Panel..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache

# === .env Setup ===
log "Configuring .env..."
cat > .env <<EOF
APP_URL=https://$FQDN
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
EOF

cp .env.example .env
chown www-data:www-data -R /var/www/pterodactyl

# === Panel Install ===
log "Installing dependencies..."
cd /var/www/pterodactyl
composer install --no-dev --optimize-autoloader --no-interaction
php artisan key:generate --force
php artisan migrate --seed --force

log "Creating admin user..."
php artisan p:user:make \
    --email "$ADMIN_EMAIL" \
    --username "$ADMIN_USER" \
    --admin 1 \
    --password "$ADMIN_PASSWORD" \
    --no-interaction

# === Nginx Config ===
log "Configuring Nginx..."
cat > /etc/nginx/sites-available/pterodactyl <<EOF
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
    access_log /var/log/nginx/pterodactyl.access.log;
    error_log /var/log/nginx/pterodactyl.error.log;

    ssl_certificate /etc/letsencrypt/live/$FQDN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$FQDN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Frame-Options DENY;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
}
EOF

ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# === SSL with Certbot ===
log "Installing Certbot..."
snap install core; snap refresh core
snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot

log "Obtaining SSL certificate..."
certbot --nginx -d "$FQDN" --email "$EMAIL" --agree-tos --no-eff-email --redirect --non-interactive

# === Wings Daemon ===
log "Installing Wings..."
mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64
chmod +x /usr/local/bin/wings

cat > /etc/systemd/system/wings.service <<EOF
[Unit]
Description=Pterodactyl Wings Daemon
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now wings

# === Final Output ===
clear
success "PTERODACTYL INSTALLATION COMPLETE!"
echo
echo "=========================================="
echo "   LOGIN DETAILS"
echo "=========================================="
echo "URL: https://$FQDN"
echo "Username: $ADMIN_USER"
echo "Email: $ADMIN_EMAIL"
echo "Password: $ADMIN_PASSWORD"
echo
echo "Wings is running. Add node in panel:"
echo "   Admin → Nodes → Create New"
echo "   Token: journalctl -u wings -f"
echo
echo "Firewall (run manually):"
echo "   sudo ufw allow 80,443,22,8080,2022"
echo "   sudo ufw enable"
echo "=========================================="
echo "Save this output! Password shown only once."
