#!/bin/bash
# COMPLETE Pterodactyl Installer - Panel + Wings + Blueprint + Cloudflare Tunnel + Queue Worker
# Optimized for Debian 11 Bullseye - December 2025
set -euo pipefail
IFS=$'\n\t'

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && err "Run this script as root (sudo)."

clear
echo -e "${GREEN}Pterodactyl Complete Installer - Debian 11 Compatible${NC}"
echo "Date: December 30, 2025"

# Detect OS
. /etc/os-release
CODENAME="${VERSION_CODENAME:-$(lsb_release -sc 2>/dev/null || echo bullseye)}"
log "Detected: $NAME $VERSION_ID (codename: $CODENAME)"

menu() {
    echo -e "
${GREEN}Select Option:${NC}

 1) Install Pterodactyl Panel (port 8080 + HTTPS + Queue Worker)
 2) Install Wings (Node)
 3) Install Blueprint (theme/framework)
 4) Install Cloudflare Tunnel (cloudflared)
 5) System Info
 6) Exit
"
    read -p "Choose [1-6]: " CHOICE
    case $CHOICE in
        1) install_panel ;;
        2) install_wings ;;
        3) install_blueprint ;;
        4) install_cloudflare_tunnel ;;
        5) system_info ;;
        6) exit 0 ;;
        *) menu ;;
    esac
}

system_info() {
    echo -e "\n${GREEN}System Information${NC}"
    echo "OS: $PRETTY_NAME"
    echo "Kernel: $(uname -r)"
    echo "CPU: $(lscpu | grep 'Model name:' | cut -d: -f2 | xargs)"
    echo "Architecture: $(uname -m)"
    df -h /
    echo
    read -p "Press Enter to return..." dummy
    menu
}

install_panel() {
    clear
    echo -e "${GREEN}→ Install Pterodactyl Panel (HTTPS on port 8080 + Queue Worker)${NC}\n"

    read -p "Panel FQDN (e.g. panel.example.com): " FQDN
    [[ -z "$FQDN" ]] && err "FQDN is required!"

    read -p "Admin Email [admin@$FQDN]: " ADMIN_EMAIL
    ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}

    read -p "Admin Username [admin]: " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}

    read -s -p "Admin Password (blank = random): " ADMIN_PASS
    echo
    [[ -z "$ADMIN_PASS" ]] && ADMIN_PASS="$(openssl rand -base64 12)" && warn "Generated password: $ADMIN_PASS"

    read -p "Admin First Name [Admin]: " ADMIN_FIRST; ADMIN_FIRST=${ADMIN_FIRST:-Admin}
    read -p "Admin Last Name [User]: " ADMIN_LAST;   ADMIN_LAST=${ADMIN_LAST:-User}

    DB_PASS="$(openssl rand -hex 16)"
    TIMEZONE="Asia/Kolkata"
    PTERO_DIR="/var/www/pterodactyl"

    log "Cleaning old repositories..."
    rm -f /etc/apt/sources.list.d/*ondrej* /etc/apt/sources.list.d/*php* /etc/apt/sources.list.d/*sury* 2>/dev/null
    sed -i '/ondrej\/php/d;/sury.org/d;/ppa.launchpad.net/d;/resolute/d' /etc/apt/sources.list 2>/dev/null
    apt update -y || true

    log "Installing base dependencies..."
    apt install -y ca-certificates curl wget tar unzip git gnupg lsb-release apt-transport-https \
        nginx mariadb-server redis-server

    # PHP - Official Sury repo for Debian Bullseye
    log "Adding Sury PHP repository..."
    curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
    echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ bullseye main" > /etc/apt/sources.list.d/php-sury.list
    apt update -y || err "Repository update failed"

    echo "PHP Version:"
    echo "  1) 8.1   2) 8.2 (recommended)   3) 8.3"
    read -p "Select [2]: " PV; PV=${PV:-2}
    case $PV in 1) PHP_VER="8.1";; 2) PHP_VER="8.2";; 3) PHP_VER="8.3";; *) PHP_VER="8.2";; esac

    apt install -y php${PHP_VER} php${PHP_VER}-{fpm,cli,mysql,xml,curl,gd,zip,bcmath,mbstring,intl,tokenizer,common}
    systemctl enable --now php${PHP_VER}-fpm

    # Database
    log "Configuring MariaDB..."
    mysql -u root <<SQL
DROP DATABASE IF EXISTS pterodactyl;
CREATE DATABASE pterodactyl CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON pterodactyl.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

    # Panel
    log "Downloading Panel..."
    mkdir -p "$PTERO_DIR" && cd "$PTERO_DIR"
    curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
    tar -xzf panel.tar.gz && rm panel.tar.gz
    cp .env.example .env
    chown -R www-data:www-data .

    sed -i "s|^APP_URL=.*|APP_URL=https://$FQDN:8080|" .env
    sed -i "s|^APP_TIMEZONE=.*|APP_TIMEZONE=$TIMEZONE|" .env
    sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" .env
    sed -i "s|^DB_USERNAME=.*|DB_USERNAME=pterodactyl|" .env
    sed -i "s|^DB_DATABASE=.*|DB_DATABASE=pterodactyl|" .env
    sed -i "s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env
    sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env
    sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env

    log "Composer & migrations..."
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    composer install --no-dev --optimize-autoloader --no-interaction
    php artisan key:generate --force
    php artisan migrate --seed --force

    php artisan p:user:make \
      --email "$ADMIN_EMAIL" \
      --username "$ADMIN_USER" \
      --name-first "$ADMIN_FIRST" \
      --name-last "$ADMIN_LAST" \
      --password "$ADMIN_PASS" \
      --admin 1 --no-interaction || true

    # SSL
    mkdir -p /etc/certs/panel
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj "/CN=$FQDN" \
      -keyout /etc/certs/panel/privkey.pem -out /etc/certs/panel/fullchain.pem

    # Nginx
    cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 8080 ssl http2;
    server_name $FQDN _;
    root $PTERO_DIR/public;
    index index.php;
    ssl_certificate /etc/certs/panel/fullchain.pem;
    ssl_certificate_key /etc/certs/panel/privkey.pem;
    client_max_body_size 100M;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \\n post_max_size=100M";
    }
    location ~ /\.ht { deny all; }
}
EOF

    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
    nginx -t && systemctl restart nginx || err "Nginx failed"

    # pteroq.service
    log "Creating and starting pteroq.service (Queue Worker)..."
    cat > /etc/systemd/system/pteroq.service <<'EOF'
[Unit]
Description=Pterodactyl Panel Queue Worker
After=network.target

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --sleep=3 --tries=3 --max-time=3600
WorkingDirectory=/var/www/pterodactyl
TimeoutStartSec=0
StandardOutput=append:/var/log/pteroq.log
StandardError=append:/var/log/pteroq.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable pteroq.service
    systemctl start pteroq.service

    clear
    ok "Panel Installation Complete!"
    echo "URL:          https://$FQDN:8080"
    echo "Admin:        $ADMIN_USER / $ADMIN_EMAIL"
    echo "Password:     $ADMIN_PASS"
    echo "Queue Worker: systemctl status pteroq.service"
    echo "Logs:         /var/log/pteroq.log"
    echo
    read -p "Press Enter..." dummy
    menu
}

install_wings() {
    clear
    echo -e "${GREEN}→ Install Wings Daemon${NC}\n"

    read -p "Panel FQDN[](https://panel.example.com): " PANEL_URL
    [[ ! $PANEL_URL =~ ^https:// ]] && err "Must start with https://"

    read -p "Wings listen port [8080]: " WINGS_PORT
    WINGS_PORT=${WINGS_PORT:-8080}

    read -p "SFTP port [2022]: " SFTP_PORT
    SFTP_PORT=${SFTP_PORT:-2022}

    read -p "Node UUID: " UUID
    read -p "Token ID: " TOKEN_ID
    read -p "Token: " TOKEN

    apt install -y docker.io
    systemctl enable --now docker

    mkdir -p /etc/certs/wings
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
      -subj "/CN=$(hostname)" \
      -keyout /etc/certs/wings/privkey.pem \
      -out /etc/certs/wings/fullchain.pem

    curl -L "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$(uname -m)" -o /usr/local/bin/wings
    chmod +x /usr/local/bin/wings

    cat > /etc/pterodactyl/config.yml <<EOF
uuid: "$UUID"
token_id: $TOKEN_ID
token: "$TOKEN"

api:
  host: 0.0.0.0
  port: $WINGS_PORT
  ssl:
    enabled: true
    cert: /etc/certs/wings/fullchain.pem
    key: /etc/certs/wings/privkey.pem

system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: $SFTP_PORT

remote: "$PANEL_URL"
EOF

    cat > /etc/systemd/system/wings.service <<EOF
[Unit]
Description=Pterodactyl Wings
After=docker.service network.target
Requires=docker.service

[Service]
User=root
WorkingDirectory=/var/lib/pterodactyl
ExecStart=/usr/local/bin/wings
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now wings

    ok "Wings installed!"
    read -p "Press Enter..." dummy
    menu
}

install_blueprint() {
    clear
    echo -e "${GREEN}→ Install Blueprint Framework${NC}\n"

    read -p "Pterodactyl directory [/var/www/pterodactyl]: " PTERO_DIR
    PTERO_DIR=${PTERO_DIR:-/var/www/pterodactyl}

    [ ! -d "$PTERO_DIR/public" ] && err "Invalid Pterodactyl directory"

    cd "$PTERO_DIR" || err "Cannot access directory"

    apt install -y curl wget unzip
    wget "$(curl -s https://api.github.com/repos/BlueprintFramework/framework/releases/latest | grep browser_download_url | grep release.zip | cut -d\" -f4)" -O release.zip
    unzip -o release.zip
    rm release.zip

    apt install -y ca-certificates curl git gnupg unzip wget zip
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
    apt update
    apt install -y nodejs
    npm i -g yarn
    yarn install

    cat > .blueprintrc <<'EOF'
WEBUSER="www-data"
OWNERSHIP="www-data:www-data"
USERSHELL="/bin/bash"
EOF

    chmod +x blueprint.sh
    bash ./blueprint.sh

    ok "Blueprint installed!"
    read -p "Press Enter..." dummy
    menu
}

install_cloudflare_tunnel() {
    clear
    echo -e "${GREEN}→ Install Cloudflare Tunnel (cloudflared)${NC}\n"

    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' > /etc/apt/sources.list.d/cloudflared.list

    apt update && apt install -y cloudflared

    ok "cloudflared installed!"
    echo "To connect tunnel:"
    echo "1. Go to https://one.dash.cloudflare.com → Zero Trust → Networks → Tunnels"
    echo "2. Create tunnel → Cloudflared → copy token"
    echo

    read -p "Paste your tunnel token (or leave blank): " TOKEN

    if [[ -n "$TOKEN" ]]; then
        nohup cloudflared tunnel run --token "$TOKEN" >/var/log/cloudflared.log 2>&1 &
        ok "Tunnel started! Logs: /var/log/cloudflared.log"
    else
        warn "Run later: cloudflared tunnel run --token YOUR_TOKEN"
    fi

    read -p "Press Enter..." dummy
    menu
}

menu
