#!/bin/bash
# ServMon Installer - Universal Linux
# Soporta: Debian, Ubuntu, CentOS, RHEL, Rocky, AlmaLinux, Fedora

set -e

INSTALL_DIR="/opt/servmon"
SERVICE_NAME="servmon-agent"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        error "No se puede detectar el sistema operativo"
    fi
    log "Sistema detectado: $OS $VERSION"
}

install_dependencies() {
    log "Instalando dependencias..."
    
    case $OS in
        debian|ubuntu)
            apt-get update -qq
            apt-get install -y -qq curl bc ss util-linux coreutils procps findutils
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &> /dev/null; then
                dnf install -y -q curl bc iproute util-linux coreutils procps-ng findutils
            else
                yum install -y -q curl bc iproute util-linux coreutils procps-ng findutils
            fi
            ;;
        *)
            warn "OS no reconocido, intentando con gestor de paquetes genérico"
            ;;
    esac
    
    # Verificar que bc esté disponible
    if ! command -v bc &> /dev/null; then
        warn "bc no está instalado. Algunas métricas pueden no funcionar."
    fi
}

create_directories() {
    log "Creando directorios..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "/var/log"
    touch "/var/log/servmon.log"
}

install_files() {
    log "Instalando archivos..."
    
    # Copiar script principal desde el repositorio si está disponible
    if [[ -f "$(dirname "$0")/sermos.sh" ]]; then
        cp "$(dirname "$0")/sermos.sh" "$INSTALL_DIR/servmon.sh"
    else
        error "No se encontró serMons.sh en el mismo directorio del instalador"
    fi
    
    chmod +x "$INSTALL_DIR/servmon.sh"
    
    # Crear config por defecto
    cat > "$INSTALL_DIR/config.ini" <<EOF
API_ENDPOINT=""
API_KEY=""
INTERVAL=60
HEAVY_FILE_THRESHOLD=100
COLLECT_CPU=true
COLLECT_MEMORY=true
COLLECT_DISK=true
COLLECT_NETWORK=true
COLLECT_PORTS=true
COLLECT_PROCESSES=true
EOF
    
    chmod 640 "$INSTALL_DIR/config.ini"
}

install_service() {
    log "Instalando servicio systemd..."
    
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=ServMon Agent - Linux Server Monitoring
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/servmon.sh
Restart=always
RestartSec=10
StandardOutput=append:/var/log/servmon.log
StandardError=append:/var/log/servmon.log
PIDFile=/var/run/servmon.pid
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
}

configure_api() {
    echo ""
    read -p "¿Deseas configurar el endpoint de la API ahora? (y/n): " configure_now
    
    if [[ "$configure_now" == "y" || "$configure_now" == "Y" ]]; then
        read -p "URL del endpoint API: " api_url
        read -p "API Key: " api_key
        
        sed -i "s|API_ENDPOINT=\"\"|API_ENDPOINT=\"$api_url\"|" "$INSTALL_DIR/config.ini"
        sed -i "s|API_KEY=\"\"|API_KEY=\"$api_key\"|" "$INSTALL_DIR/config.ini"
        
        log "API configurada correctamente"
    else
        warn "Puedes configurar la API editando $INSTALL_DIR/config.ini"
    fi
}

start_service() {
    log "Iniciando servicio..."
    systemctl start "$SERVICE_NAME"
    sleep 2
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "Servicio iniciado correctamente"
        systemctl status "$SERVICE_NAME" --no-pager
    else
        error "El servicio no se pudo iniciar. Revisa los logs: journalctl -u $SERVICE_NAME"
    fi
}

show_info() {
    echo ""
    echo "=========================================="
    echo "  ServMon Agent - Instalación Completa"
    echo "=========================================="
    echo ""
    echo "Directorio: $INSTALL_DIR"
    echo "Config:     $INSTALL_DIR/config.ini"
    echo "Logs:       /var/log/servmon.log"
    echo "Métricas:   /var/log/servmon-metrics-*.json"
    echo ""
    echo "Comandos útiles:"
    echo "  systemctl status $SERVICE_NAME"
    echo "  systemctl restart $SERVICE_NAME"
    echo "  journalctl -u $SERVICE_NAME -f"
    echo "  tail -f /var/log/servmon.log"
    echo ""
    echo "Para desinstalar: ./install.sh --uninstall"
    echo ""
}

uninstall() {
    log "Desinstalando ServMon..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    log "ServMon desinstalado"
}

# Main
if [[ "$1" == "--uninstall" ]]; then
    uninstall
    exit 0
fi

detect_os
install_dependencies
create_directories
install_files
install_service
configure_api
start_service
show_info

log "Instalación completada exitosamente"