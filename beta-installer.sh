#!/bin/bash
# Pterodactyl Panel Installer - Final Fixed Version (PHP 8.2)
set -euo pipefail
IFS=$'\n\t'

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log(){ echo -e "${BLUE}[INFO]${NC} $1"; }
ok(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

if [ "$EUID" -ne 0 ]; then
  err "Run this script as root"
fi

clear
echo -e "${GREEN}=== Pterodactyl Panel Installer (PHP 8.2) ===${NC}"

### 1️⃣ Domain
read -p "➡ Enter your panel domain (example: panel.example.com): " FQDN
[[ -z "$FQDN" ]] && err "Domain required"

### 2️⃣ Email
read -p "➡ Admin Email [admin@$FQDN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}

### 3️⃣ Username
read -p "➡ Admin Username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

### 4️⃣ First Name
read -p "➡ First Name [Admin]: " ADMIN_FIRST
ADMIN_FIRST=${ADMIN_FIRST:-Admin}

### 5️⃣ Last Name
read -p "➡ Last Name [User]: " ADMIN_LAST
ADMIN_LAST=${ADMIN_LAST:-User}

### 6️⃣ Auto-generate admin password?
read -p "➡ Auto-generate admin password? (yes/no): " AUTOPASS
if [[ "$AUTOPASS" == "yes" ]]; then
    ADMIN_PASS=$(openssl rand -base64 18)
    warn "Generated admin password: $ADMIN_PASS"
else
    read -s -p "➡ Enter Admin Password: " ADMIN_PASS
    echo
fi

# DB variables
DB_NAME="pterodactyl"
DB_USER="pterodactyl"
DB_PASS="$(openssl rand -base64 32)"
TIMEZONE="Asia/Kolkata"

log "Installing required packages..."
apt update -y
apt install -y software-properties-common curl wget git unzip tar lsb-release gnupg2 ca-certificates

### PHP 8.2 repo (Sury)
log "Adding PHP 8.2 repo..."
CODENAME=$(lsb_release -sc)
curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/sury-archive-keyring.gpg] https://packages.sury.org/php/ $CODENAME main" > /etc/apt/sources.list.d/sury-php.list
apt update -y

log "Installing PHP 8.2..."
apt install -y php8.2 php8.2-fpm php8.2-cli php8.2-mysql php8.2-mbstring php8.2-xml php8.2-curl php8.2-zip php8.2-gd php8.2-bcmath

log "Installing Nginx, MariaDB, Redis..."
apt install -y nginx mariadb-server mariadb-client redis-server

systemctl enable --now mariadb nginx php8.2-fpm redis-server

### DATABASE
log "Creating database..."
mysql -u root <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
CREATE DATABASE \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

### DOWNLOAD PANEL
log "Downloading Pterodactyl..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
rm panel.tar.gz
chmod -R 755 storage bootstrap/cache
cp .env.example .env

### UPDATE .env
log "Updating .env..."

sed -i "s|APP_URL=.*|APP_URL=https://$FQDN|" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=$DB_NAME|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=$DB_USER|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" .env
sed -i "s|APP_TIMEZONE=.*|APP_TIMEZONE=$TIMEZONE|" .env

# Important: Fix setup redirect
sed -i "s|APP_ENVIRONMENT_ONLY=true|APP_ENVIRONMENT_ONLY=false|" .env

### Composer install
log "Installing Composer..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
composer install --no-dev --optimize-autoloader

php artisan key:generate --force
php artisan migrate --seed --force

### ADMIN USER CREATION
log "Creating admin user..."

php artisan p:user:make \
    --email="$ADMIN_EMAIL" \
    --username="$ADMIN_USER" \
    --name-first="$ADMIN_FIRST" \
    --name-last="$ADMIN_LAST" \
    --password="$ADMIN_PASS" \
    --admin=1 \
    --no-interaction

### DETECT PHP-FPM SOCKET
PHP_SOCK=$(find /run/php -name "php8.2-fpm.sock" | head -n 1)
FASTCGI="unix:$PHP_SOCK"

### SSL
log "Generating self-signed SSL..."
mkdir -p /etc/certs/certs
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/CN=$FQDN" \
  -keyout /etc/certs/certs/privkey.pem \
  -out /etc/certs/certs/fullchain.pem

### NGINX CONFIG
log "Writing nginx config..."

cat >/etc/nginx/sites-available/pterodactyl.conf <<EOF
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

    ssl_certificate /etc/certs/certs/fullchain.pem;
    ssl_certificate_key /etc/certs/certs/privkey.pem;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_pass $FASTCGI;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/

nginx -t && systemctl restart nginx

clear
echo -e "${GREEN}=== INSTALL COMPLETE ===${NC}"
echo "Panel URL: https://$FQDN"
echo "Admin Email: $ADMIN_EMAIL"
echo "Admin Username: $ADMIN_USER"
echo "Admin Password: $ADMIN_PASS"
echo "DB User: $DB_USER"
echo "DB Pass: $DB_PASS"
echo "============================================="
echo ""
echo "============================================"
echo " Cloudflare Domain Check"
echo "============================================"
read -p "Are you using a Cloudflare-protected domain? (yes/no): " cf_answer

if [[ "$cf_answer" == "yes" || "$cf_answer" == "y" ]]; then
    echo ""
    echo "IMPORTANT: Update your panel domain Configuration"
    echo ""
    echo "Change this setting:"
    echo ""
    echo " Service Type (Required)"
    echo " URL (Required)  ->  HTTPS://"
    echo ""
    echo " Example values:"
    echo "   https://localhost:443"
    echo "   https://localhost:8001"
    echo ""
    echo " Additional application settings → TLS →"
    echo "    No TLS Verify  →  ON"
    echo ""
    echo "This is required because Cloudflare uses TLS proxying and will block requests without this fix."
    echo ""
else
    echo "Skipping Cloudflare TLS instructions..."
fi

