#!/bin/bash

clear
echo "============================================"
echo "      Pterodactyl Full Auto-Installer       "
echo "============================================"
sleep 1

# -------------------------
# 1. Ask for basic inputs
# -------------------------

read -p "1️⃣ Enter your Panel Domain: " PANEL_DOMAIN
read -p "2️⃣ Admin Email: " ADMIN_EMAIL
read -p "3️⃣ Admin Username: " ADMIN_USER
read -p "4️⃣ Admin First Name: " ADMIN_FIRST
read -p "5️⃣ Admin Last Name: " ADMIN_LAST

echo ""
read -p "6️⃣ Auto-generate DB password? (yes/no): " AUTODB
DB_PASS=$(openssl rand -hex 16)

# -------------------------
# 2. Update system
# -------------------------
apt update -y
apt upgrade -y

# -------------------------
# 3. Install PHP 8.2
# -------------------------

apt install -y ca-certificates apt-transport-https software-properties-common curl zip unzip git

LC_ALL=C.UTF-8 add-apt-repository ppa:ondrej/php -y
apt update -y

apt install -y \
php8.2 php8.2-cli php8.2-common php8.2-gmp php8.2-curl php8.2-mysql \
php8.2-mbstring php8.2-xml php8.2-bcmath php8.2-json php8.2-fpm \
php8.2-zip php8.2-intl php8.2-readline

systemctl enable php8.2-fpm
systemctl start php8.2-fpm

# -------------------------
# 4. Install MariaDB
# -------------------------

apt install -y mariadb-server

systemctl enable mariadb
systemctl start mariadb

mysql -uroot <<MYSQL_SCRIPT
CREATE DATABASE panel;
CREATE USER 'panel'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON panel.* TO 'panel'@'127.0.0.1';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

echo "Database created with password: $DB_PASS"

# -------------------------
# 5. Install Composer
# -------------------------

export COMPOSER_ALLOW_SUPERUSER=1
curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer

# -------------------------
# 6. Install Pterodactyl
# -------------------------

mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

composer install --no-interaction --ansi --no-dev

cp .env.example .env

# Modify .env automatically
sed -i "s/APP_ENVIRONMENT_ONLY=true/APP_ENVIRONMENT_ONLY=false/" .env
sed -i "s|APP_URL=.*|APP_URL=https://$PANEL_DOMAIN|" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=panel|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=panel|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" .env

php artisan key:generate --force
php artisan migrate --seed --force

# -------------------------
# 7. Create admin user
# -------------------------

php artisan p:user:make \
--email="$ADMIN_EMAIL" \
--username="$ADMIN_USER" \
--name-first="$ADMIN_FIRST" \
--name-last="$ADMIN_LAST" \
--password="$(openssl rand -hex 12)" \
--admin=1 --no-interaction

# -------------------------
# 8. Setup SSL with certbot
# -------------------------

apt install -y certbot python3-certbot-nginx

certbot --nginx -d $PANEL_DOMAIN --non-interactive --agree-tos -m $ADMIN_EMAIL

# -------------------------
# 9. NGINX config
# -------------------------

cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name $PANEL_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $PANEL_DOMAIN;

    root /var/www/pterodactyl/public;
    index index.php;

    ssl_certificate /etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_intercept_errors off;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
systemctl restart nginx

# -------------------------
# 10. Ask Cloudflare
# -------------------------

read -p "🌐 Are you using Cloudflare? (yes/no): " CF

if [[ "$CF" == "yes" ]]; then
    echo ""
    echo "➡ Set your Node inside Wings to:"
    echo "Service Type: URL"
    echo "TLS: NO TLS VERIFY"
    echo "URL: https://localhost:443"
    echo ""
fi

# -------------------------
# DONE
# -------------------------

echo "============================================"
echo " Pterodactyl Panel Installed Successfully! "
echo " URL: https://$PANEL_DOMAIN"
echo " Database Password: $DB_PASS"
echo "============================================"
