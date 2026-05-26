#!/bin/sh
# Install goflow2 on Alpine Linux with OpenRC
# This script installs the latest release from https://github.com/Rid-lin/goflow2/releases
# and sets up an OpenRC service with environment variable support.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Default installation directory
INSTALL_DIR="/opt/goflow2"
BINARY_NAME="goflow2"
SERVICE_NAME="goflow2"
USER_NAME="goflow2"
GROUP_NAME="goflow2"

# Determine architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        ARCH="amd64"
        ;;
    aarch64)
        ARCH="arm64"
        ;;
    *)
        log_error "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

log_info "Detected architecture: $ARCH"

# Install dependencies
log_info "Installing required packages..."
apk add --no-cache wget jq

# Get latest release version from GitHub API using jq
log_info "Fetching latest release version..."
LATEST_VERSION=$(wget -q -O - https://api.github.com/repos/Rid-lin/goflow2/releases/latest | jq -r '.tag_name')
if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ]; then
    log_error "Failed to fetch latest version"
    exit 1
fi
log_info "Latest version: $LATEST_VERSION"

# Construct download URL
DOWNLOAD_URL="https://github.com/Rid-lin/goflow2/releases/download/${LATEST_VERSION}/goflow2"
log_info "Download URL: $DOWNLOAD_URL"

# Create installation directory
log_info "Creating installation directory $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

# Create user and group if they don't exist
if ! getent group "$GROUP_NAME" > /dev/null; then
    log_info "Creating group $GROUP_NAME..."
    addgroup -S "$GROUP_NAME"
fi
if ! id -u "$USER_NAME" > /dev/null; then
    log_info "Creating user $USER_NAME..."
    adduser -S -D -H -G "$GROUP_NAME" -h "$INSTALL_DIR" -s /bin/false "$USER_NAME"
fi

# Download binary (file is not compressed, no extraction needed)
log_info "Downloading goflow2..."
cd /tmp
wget -q -O goflow2 "$DOWNLOAD_URL"

# Move binary to installation directory
mv goflow2 "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/goflow2"

# Create wrapper script to load .env
WRAPPER_SCRIPT="$INSTALL_DIR/goflow2-wrapper.sh"
log_info "Creating wrapper script $WRAPPER_SCRIPT..."
cat > "$WRAPPER_SCRIPT" <<'EOF'
#!/bin/sh
# Wrapper for goflow2 that loads environment variables from .env

set -a
if [ -f "$(dirname "$0")/.env" ]; then
    . "$(dirname "$0")/.env"
fi
set +a

exec "$(dirname "$0")/goflow2" "$@"
EOF
chmod +x "$WRAPPER_SCRIPT"
chown "$USER_NAME:$GROUP_NAME" "$WRAPPER_SCRIPT"

# Set ownership
log_info "Setting ownership of $INSTALL_DIR to $USER_NAME:$GROUP_NAME..."
chown -R "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR"

# Copy environment example from script directory if available
SCRIPT_DIR=$(dirname "$(realpath "$0")")
if [ -f "$SCRIPT_DIR/.env.example" ] && [ ! -f "$INSTALL_DIR/.env.example" ]; then
    log_info "Copying .env.example from script directory to $INSTALL_DIR..."
    cp "$SCRIPT_DIR/.env.example" "$INSTALL_DIR/.env.example"
    chown "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR/.env.example"
fi

# Copy environment example if .env doesn't exist
if [ -f "$INSTALL_DIR/.env.example" ] && [ ! -f "$INSTALL_DIR/.env" ]; then
    log_info "Copying .env.example to .env..."
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    chown "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR/.env"
    log_warn "Please edit $INSTALL_DIR/.env to configure your environment"
fi

# Create OpenRC service file
SERVICE_FILE="/etc/init.d/$SERVICE_NAME"
log_info "Creating OpenRC service at $SERVICE_FILE..."

cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="goflow2"
description="GoFlow2 NetFlow/sFlow/IPFIX collector"
command="$WRAPPER_SCRIPT"
command_args=""
command_user="$USER_NAME:$GROUP_NAME"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
start_stop_daemon_args="--chdir $INSTALL_DIR"

depend() {
    need net
    after firewall
}

start_pre() {
    # Ensure .env exists (optional)
    if [ ! -f "$INSTALL_DIR/.env" ]; then
        ewarn "No .env file found at $INSTALL_DIR/.env"
    fi
    # Note: The wrapper script loads .env automatically
}

stop_post() {
    rm -f "\$pidfile"
}
EOF

chmod +x "$SERVICE_FILE"

# Enable and start service
log_info "Enabling $SERVICE_NAME service..."
rc-update add "$SERVICE_NAME" default

log_info "Starting $SERVICE_NAME service..."
rc-service "$SERVICE_NAME" start

# Verify service status
if rc-service "$SERVICE_NAME" status > /dev/null 2>&1; then
    log_info "Service $SERVICE_NAME started successfully"
else
    log_warn "Service may not be running. Check logs with: rc-service $SERVICE_NAME status"
fi

log_info "Installation complete!"
log_info "Installation directory: $INSTALL_DIR"
log_info "Service name: $SERVICE_NAME"
log_info "Manage service with: rc-service $SERVICE_NAME {start|stop|restart|status}"
log_info "Edit configuration: $INSTALL_DIR/.env"
log_info "Logs: tail -f /var/log/$SERVICE_NAME.log"