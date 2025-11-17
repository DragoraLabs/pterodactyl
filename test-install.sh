#!/bin/bash

clear
echo "============================================"
echo "        Pterodactyl Auto-Installer"
echo "============================================"

OS=""
if [ -f /etc/debian_version ]; then
    if grep -qi "11" /etc/os-release; then OS="debian11"; fi
    if grep -qi "12" /etc/os-release; then OS="debian12"; fi
fi
if grep -qi "ubuntu" /etc/os-release; then
    if grep -qi "22.04" /etc/os-release; then OS="ubuntu22"; fi
    if grep -qi "24.04" /etc/os-release; then OS="ubuntu24"; fi
fi

if [ "$OS" = "" ]; then
    echo "Unsupported OS"; exit 1
fi

clear
echo "Detected OS: $OS"
echo
echo "1) Panel only"
echo "2) Panel + Node (coming soon)"
read -rp "Choose option: " INSTALL_MODE

if [ "$INSTALL_MODE" != "1" ]; then
    echo "Node installer will be added soon."
fi

read -rp "Panel Domain: " DOMAIN
read -rp "Admin Email: " ADMIN_EMAIL
read -rp "Admin Username: " ADMIN_USER
read -rp "First Name: " FIRST
read -rp "Last Name: " LAST

read -rp "Are you using Cloudflare? (yes/no): " CF

apt update -y
apt install -y software-properties-common curl apt-transport-https ca-certificates gnupg unzip git

if [[ "$OS" == ubuntu22 || "$OS" == ubuntu24 ]]; then
    add-apt-repository ppa:ondrej/php -y
fi

apt update -y
apt install -y php8.2 php8.2-{cli,gd,curl,mbstring,mysql,zip,bz2,intl,fpm,xml} mariadb-server nginx redis-server

systemctl enable mysql --now
systemctl enable redis-server --now
systemctl enable php8.2-fpm --now
systemctl enable nginx --now

DB_PASS=$(openssl rand -hex 12)
mysql -u root -e "CREATE DATABASE panel;"
mysql -u root -e "CREATE USER 'ptero'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';"
mysql -u root -e "GRANT ALL PRIVILEGES ON panel.* TO 'ptero'@'127.0.0.1'; FLUSH PRIVILEGES;"

cd /var/www
mkdir pterodactyl
cd pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/
cp .env.example .env

curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer

echo yes | composer install --no-dev --optimize-autoloader

php artisan key:generate --force
php artisan p:environment:setup --author="$ADMIN_EMAIL" --url="https://$DOMAIN" --timezone="Asia/Kolkata" --cache="redis" --session="redis" --queue="redis" --email="smtp"
php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="panel" --username="ptero" --password="$DB_PASS"
php artisan migrate --seed --force

php artisan p:user:make \
 --email="$ADMIN_EMAIL" \
 --username="$ADMIN_USER" \
 --name-first="$FIRST" \
 --name-last="$LAST" \
 --password="$(openssl rand -hex 8)" \
 --admin=1 \
 --no-interaction

if [ "$CF" = "yes" ]; then
    CF_NOTE="Set Service Type: URL, HTTPS://localhost:443, TLS Verify: Off"
else
    CF_NOTE="No Cloudflare settings needed."
fi

cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
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

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;
    }
}
EOF

ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf

apt install -y certbot python3-certbot-nginx
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL"

systemctl restart nginx

echo
echo "============================================"
echo "Installation Completed"
echo "Panel: https://$DOMAIN"
echo "$CF_NOTE"
echo "============================================"
