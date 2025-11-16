#!/bin/bash
set -e

echo ""
echo "----------------------------------------"
echo "   Pterodactyl Panel Auto-Installer"
echo "   Supported: Debian 10/11/12, Ubuntu 20.04/22.04/24.04, WSL2"
echo "----------------------------------------"
echo ""

# Detect OS
OS=$(lsb_release -is 2>/dev/null || echo "Unknown")
VER=$(lsb_release -rs 2>/dev/null || echo "Unknown")

echo "Detected OS: $OS $VER"

# Update
apt update -y
apt upgrade -y

# Install basic tools
apt install -y curl zip unzip tar git software-properties-common ca-certificates

# ========================================
# PHP 8.2 INSTALL
# ========================================
echo ""
echo ">> Installing PHP 8.2"

add-apt-repository ppa:ondrej/php -y
apt update -y

apt install -y \
php8.2 php8.2-cli php8.2-fpm php8.2-common php8.2-gd php8.2-mysql \
php8.2-mbstring php8.2-bcmath php8.2-xml php8.2-curl php8.2-zip php8.2-intl php8.2-sqlite3

systemctl enable --now php8.2-fpm

# ========================================
# MARIADB INSTALL
# ========================================
echo ""
echo ">> Installing MariaDB"

apt install -y mariadb-server
systemctl enable --now mariadb

echo ">> Creating MySQL user & database"

mysql -u root <<EOF
CREATE DATABASE panel;
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY 'StrongPassword123!';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

# ========================================
# REDIS INSTALL
# ========================================
echo ""
echo ">> Installing Redis"
apt install -y redis-server
systemctl enable --now redis-server

# ========================================
# COMPOSER INSTALL
# ========================================
echo ""
echo ">> Installing Composer"

curl -sS https://getcomposer.org/installer -o composer-setup.php
php composer-setup.php --install-dir=/usr/local/bin --filename=composer
rm composer-setup.php

# ========================================
# PANEL INSTALL
# ========================================
echo ""
echo ">> Installing Pterodactyl Panel"

mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz

composer install --no-dev --optimize-autoloader

cp .env.example .env
php artisan key:generate --force

# Update .env
sed -i "s|APP_URL=.*|APP_URL=https://panel.example.com|" .env
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=StrongPassword123!/" .env
sed -i "s/DB_USERNAME=.*/DB_USERNAME=pterodactyl/" .env
sed -i "s/DB_DATABASE=.*/DB_DATABASE=panel/" .env

php artisan migrate --seed --force

# ========================================
# CREATE ADMIN USER
# ========================================
echo ""
echo ">> Creating admin user"

php artisan p:user:make <<EOF
admin
admin@example.com
Admin1234
Admin1234
1
EOF

# ========================================
# QUEUE WORKER SERVICE
# ========================================
echo ""
echo ">> Creating queue worker service"

cat <<EOF > /etc/systemd/system/pteroq.service
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now pteroq

# ========================================
# NGINX CONFIG
# ========================================
echo ""
echo ">> Installing NGINX"

apt install -y nginx
systemctl enable --now nginx

rm -f /etc/nginx/sites-enabled/default

cat <<EOF > /etc/nginx/sites-available/pterodactyl.conf
server {
    listen 80;
    server_name panel.example.com;

    root /var/www/pterodactyl/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_index index.php;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t && systemctl restart nginx

echo ""
echo "----------------------------------------"
echo " INSTALLATION COMPLETE!"
echo ""
echo " Login: https://panel.example.com"
echo " Email: admin@example.com"
echo " Pass : Admin1234"
echo "----------------------------------------"
