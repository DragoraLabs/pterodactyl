#!/usr/bin/env bash
# Pterodactyl All-in-One Installer - Fixed 2026 Edition
set -euo pipefail
IFS=$'\n\t'

# Colors
RED='\033[1;31m' GREEN='\033[1;32m' YELLOW='\033[1;33m' BLUE='\033[1;34m' NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && err "This script must be run as root (sudo)."

clear
echo -e "${GREEN}Pterodactyl All-in-One Installer — Fixed 2026 Edition${NC}"

# ─── OS Detection ─────────────────────────────────────
if [[ -f /etc/os-release ]]; then
    . /etc/os-release 2>/dev/null || err "Cannot read /etc/os-release"
else
    err "Cannot detect operating system"
fi

ID="${ID:-unknown}"
VERSION_ID="${VERSION_ID:-unknown}"
CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"

log "Detected: $PRETTY_NAME"

case "$ID" in
    ubuntu|debian)
        OS_FAMILY="debian"
        PKG_UPDATE="apt-get update -yqq"
        PKG_INSTALL="apt-get install -yqq"
        DOCKER_PKG="docker.io"
        ;;
    rocky|almalinux|rhel|centos)
        OS_FAMILY="rhel"
        PKG_UPDATE="dnf makecache -q && dnf update -y -q"
        PKG_INSTALL="dnf install -y -q"
        DOCKER_PKG="docker-ce docker-ce-cli containerd.io"
        ;;
    *)
        err "Unsupported distribution: $ID $VERSION_ID"
        ;;
esac

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_TAG="amd64" ;;
    aarch64) ARCH_TAG="arm64" ;;
    *) err "Unsupported architecture: $ARCH" ;;
esac

# Robust package installer
install_pkgs() {
    $PKG_INSTALL "$@" || err "Package installation failed"
}

# ─── Wings Installation (Fixed) ─────────────────────────────────
install_wings() {
    clear
    echo -e "${GREEN}→ Install Wings${NC}\n"

    log "Updating package cache..."
    $PKG_UPDATE

    log "Installing Docker..."
    if [[ $OS_FAMILY == "debian" ]]; then
        # Proper Docker install for Ubuntu/Debian
        install_pkgs ca-certificates curl gnupg lsb-release
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        $PKG_UPDATE
        install_pkgs docker-ce docker-ce-cli containerd.io
    else
        $PKG_INSTALL yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        install_pkgs $DOCKER_PKG
    fi

    systemctl enable --now docker
    log "Docker installed and started."

    # Rest of Wings installation (unchanged but cleaner)
    mkdir -p /etc/pterodactyl /var/lib/pterodactyl/{volumes,logs}
    chmod 755 /etc/pterodactyl /var/lib/pterodactyl

    curl -L "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH_TAG}" -o /usr/local/bin/wings
    chmod +x /usr/local/bin/wings

    # Self-signed cert
    mkdir -p /etc/pterodactyl/ssl
    openssl req -new -x509 -nodes -days 3650 -newkey rsa:4096 \
      -keyout /etc/pterodactyl/ssl/privkey.pem \
      -out /etc/pterodactyl/ssl/fullchain.pem \
      -subj "/CN=$(hostname -f)" 2>/dev/null || true

    echo -e "\n${GREEN}Enter details from Panel → Nodes → Create Node${NC}\n"
    read -p "Panel URL[](https://...): " PANEL_URL
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

    cat > /etc/systemd/system/wings.service <<EOF
[Unit]
Description=Pterodactyl Wings Daemon
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
    echo "Check status : systemctl status wings"
    echo "Logs         : journalctl -u wings -f"
    read -p "Press Enter to return to menu..." dummy
    menu
}

# Keep your other functions (install_panel, etc.) as they are, or apply similar PKG fixes there.

# ─── Menu (unchanged) ─────────────────────────────────
menu() {
    echo -e "\n${GREEN}Select Option:${NC}
 1) Install Pterodactyl Panel
 2) Install Wings
 3) Exit
"
    read -p "Choose [1-3]: " CHOICE
    case $CHOICE in
        1) install_panel ;;
        2) install_wings ;;
        3) exit 0 ;;
        *) menu ;;
    esac
}

# Start
menu
