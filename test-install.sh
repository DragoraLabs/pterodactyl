#!/usr/bin/env bash
# Pterodactyl All-in-One Installer - FIXED VERSION (2026)

set -euo pipefail
IFS=$'\n\t'

# Colors
RED='\033[1;31m' GREEN='\033[1;32m' YELLOW='\033[1;33m' BLUE='\033[1;34m' NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && err "Run as root"

clear
echo -e "${GREEN}Pterodactyl Installer (Fixed)${NC}"

# ─── OS DETECTION ─────────────────────────────
. /etc/os-release

case "$ID" in
    ubuntu|debian)
        OS_FAMILY="debian"
        ;;
    rocky|almalinux|centos|rhel)
        OS_FAMILY="rhel"
        ;;
    *)
        err "Unsupported OS"
        ;;
esac

ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] && ARCH_TAG="amd64" || ARCH_TAG="arm64"

# ─── FIXED PACKAGE INSTALL FUNCTION ───────────
install_pkgs() {
    if [[ $OS_FAMILY == "debian" ]]; then
        apt-get update -yqq
        apt-get install -yqq "$@" || err "Package install failed"
    else
        dnf install -y "$@" || err "Package install failed"
    fi
}

# ─── WINGS INSTALL ────────────────────────────
install_wings() {
    clear
    echo -e "${GREEN}→ Installing Wings${NC}\n"

    log "Installing Docker..."

    if [[ $OS_FAMILY == "debian" ]]; then
        install_pkgs curl wget tar unzip ca-certificates gnupg lsb-release docker.io
    else
        dnf install -y yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        install_pkgs docker-ce docker-ce-cli containerd.io
    fi

    systemctl enable --now docker

    log "Creating directories..."
    mkdir -p /etc/pterodactyl /var/lib/pterodactyl/{volumes,logs}
    chmod 755 /etc/pterodactyl /var/lib/pterodactyl

    log "Downloading Wings..."
    curl -L "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH_TAG}" -o /usr/local/bin/wings
    chmod +x /usr/local/bin/wings

    log "Generating SSL..."
    mkdir -p /etc/pterodactyl/ssl
    openssl req -new -x509 -nodes -days 3650 -newkey rsa:4096 \
        -keyout /etc/pterodactyl/ssl/privkey.pem \
        -out /etc/pterodactyl/ssl/fullchain.pem \
        -subj "/CN=$(hostname -f)"

    echo ""
    echo "Enter details from Panel → Nodes"

    read -p "Panel URL (https://panel.domain.com): " PANEL_URL
    read -p "Wings Port [8080]: " WINGS_PORT; WINGS_PORT=${WINGS_PORT:-8080}
    read -p "SFTP Port [2022]: " SFTP_PORT; SFTP_PORT=${SFTP_PORT:-2022}
    read -p "Node UUID: " UUID
    read -p "Token ID: " TOKEN_ID
    read -p "Token: " TOKEN

cat > /etc/pterodactyl/config.yml <<EOF
uuid: "$UUID"
token_id: $TOKEN_ID
token: "$TOKEN"

api:
  host: 0.0.0.0
  port: $WINGS_PORT
  ssl:
    enabled: true
    cert: /etc/pterodactyl/ssl/fullchain.pem
    key: /etc/pterodactyl/ssl/privkey.pem

system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: $SFTP_PORT

remote: "$PANEL_URL"
EOF

    log "Creating service..."

cat > /etc/systemd/system/wings.service <<EOF
[Unit]
Description=Pterodactyl Wings
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/var/lib/pterodactyl
ExecStart=/usr/local/bin/wings
Restart=always
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now wings

    ok "Wings installed successfully!"
    echo ""
    echo "Check status: systemctl status wings"
    echo "Logs: journalctl -u wings -f"
}

# ─── MENU ────────────────────────────────────
menu() {
    echo ""
    echo "1) Install Wings"
    echo "2) Exit"
    read -p "Choose: " CHOICE

    case $CHOICE in
        1) install_wings ;;
        2) exit ;;
        *) menu ;;
    esac
}

menu
