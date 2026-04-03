#!/usr/bin/env bash
# =============================================================================
# DinoX — Build & Install script for Arch Linux
#
# Usage:
#   ./install.sh              Build and install DinoX
#   ./install.sh --clean      Remove build directory before building
#   ./install.sh --uninstall  Uninstall DinoX from the system
#   ./install.sh --deps-only  Install pacman dependencies only, then exit
#   ./install.sh --no-service Do not create the XDG autostart entry
#   ./install.sh --help       Show this help
#
# The script:
#   1. Checks and installs all required pacman packages
#   2. Configures the build with meson (prefix=/usr)
#   3. Compiles with ninja
#   4. Installs via sudo ninja install
#   5. Cleans up any conflicting /usr/local installation
#   6. Creates ~/.config/autostart/im.github.rallep71.DinoX.desktop
#      (XDG autostart — works with UWSM/Hyprland, GNOME, KDE, XFCE, etc.)
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Colours
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
info()    { echo -e "${CYAN}  •${NC} $*"; }
success() { echo -e "${GREEN}  ✔${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $*"; }
error()   { echo -e "${RED}  ✖${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

die() { error "$*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"

# -----------------------------------------------------------------------------
# Required pacman packages
# Format: "pacman_pkg_name[:pkg_config_name]"
# If pkg_config_name is provided, the package is considered present when
# pkg-config can find it — useful for libs installed from source.
# -----------------------------------------------------------------------------
PACMAN_DEPS=(
    # Build tools
    meson
    ninja
    cmake
    vala
    pkg-config
    git
    gcc
    # Core libraries
    glib2:glib-2.0
    gdk-pixbuf2:gdk-pixbuf-2.0
    gtk4:gtk4
    libadwaita:libadwaita-1
    libgee:gee-0.8
    # XMPP / networking
    libsoup3:libsoup-3.0
    gnutls:gnutls
    libsecret:libsecret-1
    icu:icu-uc
    # Audio / Video
    gstreamer:gstreamer-1.0
    gst-plugins-base:gstreamer-app-1.0
    gst-plugins-good
    gst-plugins-bad
    gst-plugins-ugly
    gst-libav
    libsrtp:libsrtp2
    # Crypto & OMEMO
    libgcrypt:libgcrypt
    libomemo-c:libomemo-c
    # File transfer / ICE
    libnice:nice
    # QR codes (OpenPGP plugin)
    qrencode:libqrencode
    # SQLCipher (encrypted DB)
    sqlcipher:sqlcipher
    # Misc
    json-glib:json-glib-1.0
    libcanberra:libcanberra
    gpgme:gpgme
    libdbusmenu-glib:dbusmenu-glib-0.4
    mosquitto:libmosquitto
    webrtc-audio-processing:webrtc-audio-processing-2
    # protobuf-c for libomemo-c
    protobuf-c:libprotobuf-c
)

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
DO_CLEAN=false
DO_UNINSTALL=false
DO_DEPS_ONLY=false
DO_SERVICE=true

for arg in "$@"; do
    case "$arg" in
        --clean)       DO_CLEAN=true ;;
        --uninstall)   DO_UNINSTALL=true ;;
        --deps-only)   DO_DEPS_ONLY=true ;;
        --no-service)  DO_SERVICE=false ;;
        --help|-h)
            sed -n '2,11p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown option: $arg  (use --help for usage)" ;;
    esac
done

# -----------------------------------------------------------------------------
# Uninstall
# -----------------------------------------------------------------------------
if $DO_UNINSTALL; then
    header "Uninstall DinoX"

    # Remove XDG autostart entry if present
    AUTOSTART_FILE="$HOME/.config/autostart/im.github.rallep71.DinoX.desktop"
    if [ -f "$AUTOSTART_FILE" ]; then
        info "Removing XDG autostart entry..."
        rm -f "$AUTOSTART_FILE"
        success "Autostart entry removed."
    fi

    # Stop the running instance if any
    if systemctl --user is-active --quiet dinox.service 2>/dev/null; then
        info "Stopping dinox.service..."
        systemctl --user stop dinox.service || true
    fi

    if [ ! -f "$BUILD_DIR/build.ninja" ]; then
        die "No build directory found at $BUILD_DIR — cannot uninstall."
    fi
    info "Running sudo ninja -C build uninstall..."
    sudo ninja -C "$BUILD_DIR" uninstall
    info "Removing any leftover /usr/local installation..."
    sudo rm -f  /usr/local/bin/dinox
    sudo rm -f  /usr/local/lib/libdino*
    sudo rm -f  /usr/local/lib/libxmpp-vala*
    sudo rm -f  /usr/local/lib/libqlite*
    sudo rm -f  /usr/local/lib/libcrypto-vala*
    sudo rm -rf /usr/local/lib/dino/
    sudo ldconfig
    success "DinoX uninstalled."
    exit 0
fi

# -----------------------------------------------------------------------------
# Banner
# -----------------------------------------------------------------------------
header "DinoX — Arch Linux Installer"
echo -e "  Project:  $SCRIPT_DIR"
echo -e "  Build:    $BUILD_DIR"
echo -e "  Clean:    $DO_CLEAN"
echo -e "  Service:  $DO_SERVICE"
echo ""

# -----------------------------------------------------------------------------
# 1. Check we are on Arch (pacman exists)
# -----------------------------------------------------------------------------
if ! command -v pacman &>/dev/null; then
    die "pacman not found. This script targets Arch Linux."
fi

# -----------------------------------------------------------------------------
# 2. Install pacman dependencies
# -----------------------------------------------------------------------------
header "Dependencies"

MISSING=()
for entry in "${PACMAN_DEPS[@]}"; do
    pkg="${entry%%:*}"          # pacman package name (before colon)
    pc="${entry#*:}"            # pkg-config name (after colon, or same as pkg if no colon)

    # Already installed via pacman?
    if pacman -Q "$pkg" &>/dev/null; then
        continue
    fi

    # Installed from source? Check via pkg-config (only when a pc name was given).
    if [ "$pc" != "$pkg" ] && command -v pkg-config &>/dev/null; then
        if pkg-config --exists "$pc" 2>/dev/null; then
            continue
        fi
    fi

    MISSING+=("$pkg")
done

if [ ${#MISSING[@]} -eq 0 ]; then
    success "All dependencies are already satisfied."
else
    warn "Missing packages: ${MISSING[*]}"
    info "Installing via pacman..."
    sudo pacman -S --needed --noconfirm "${MISSING[@]}"
    success "Dependencies installed."
fi

$DO_DEPS_ONLY && { success "Done (--deps-only)."; exit 0; }

# -----------------------------------------------------------------------------
# 3. Remove stale /usr/local installation that could shadow /usr
# -----------------------------------------------------------------------------
header "Cleanup"

STALE_FILES=(
    /usr/local/bin/dinox
    /usr/local/lib/libdino.so
    /usr/local/lib/libdino.so.0
    /usr/local/lib/libdino.so.0.0
    /usr/local/lib/libxmpp-vala.so
    /usr/local/lib/libxmpp-vala.so.0
    /usr/local/lib/libxmpp-vala.so.0.1
    /usr/local/lib/libqlite.so
    /usr/local/lib/libqlite.so.0
    /usr/local/lib/libqlite.so.0.1
    /usr/local/lib/libcrypto-vala.so
    /usr/local/lib/libcrypto-vala.so.0
    /usr/local/lib/libcrypto-vala.so.0.0
)
STALE_DIRS=(
    /usr/local/lib/dino
)

REMOVED_STALE=false
for f in "${STALE_FILES[@]}"; do
    if [ -e "$f" ]; then
        sudo rm -f "$f"
        REMOVED_STALE=true
    fi
done
for d in "${STALE_DIRS[@]}"; do
    if [ -d "$d" ]; then
        sudo rm -rf "$d"
        REMOVED_STALE=true
    fi
done

if $REMOVED_STALE; then
    sudo ldconfig
    warn "Removed stale /usr/local installation (would shadow the new build)."
else
    success "No stale /usr/local files found."
fi

# -----------------------------------------------------------------------------
# 4. Configure (meson setup)
# -----------------------------------------------------------------------------
header "Configure"

if $DO_CLEAN && [ -d "$BUILD_DIR" ]; then
    info "Removing existing build directory..."
    rm -rf "$BUILD_DIR"
    success "Build directory removed."
fi

if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    info "Running meson setup..."
    meson setup \
        --prefix=/usr \
        --buildtype=release \
        -Dset-install-rpath=false \
        "$BUILD_DIR" \
        "$SCRIPT_DIR"
    success "Meson configuration complete."
else
    info "Build directory already configured — skipping meson setup."
    info "  (use --clean to force reconfiguration)"
fi

# -----------------------------------------------------------------------------
# 5. Compile
# -----------------------------------------------------------------------------
header "Build"

BUILD_START=$(date +%s)
info "Running ninja ($(nproc) parallel jobs)..."
ninja -C "$BUILD_DIR" -j"$(nproc)"
BUILD_END=$(date +%s)
success "Build complete in $((BUILD_END - BUILD_START))s."

# -----------------------------------------------------------------------------
# 6. Install
# -----------------------------------------------------------------------------
header "Install"

info "Running sudo ninja install..."
sudo ninja -C "$BUILD_DIR" install
sudo ldconfig
success "DinoX installed to /usr."

# -----------------------------------------------------------------------------
# 7. XDG autostart entry
# -----------------------------------------------------------------------------
header "Autostart"

if $DO_SERVICE; then
    AUTOSTART_DIR="$HOME/.config/autostart"
    AUTOSTART_FILE="$AUTOSTART_DIR/im.github.rallep71.DinoX.desktop"
    mkdir -p "$AUTOSTART_DIR"
    cat > "$AUTOSTART_FILE" << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=DinoX
Comment=Start DinoX minimized to tray on login
Icon=im.github.rallep71.DinoX
Exec=dinox --minimized
Terminal=false
Categories=Network;Chat;InstantMessaging;
X-GNOME-Autostart-enabled=true
StartupNotify=false
DESKTOP
    success "XDG autostart entry created: $AUTOSTART_FILE"
    info "DinoX will start minimized to tray on next login."
    info "(systemd-xdg-autostart-generator will run it as part of graphical-session.target)"
else
    info "Skipping autostart setup (--no-service)."
fi

# -----------------------------------------------------------------------------
# 8. Verify
# -----------------------------------------------------------------------------
header "Verify"

DINOX_BIN="$(command -v dinox 2>/dev/null || true)"
if [ -z "$DINOX_BIN" ]; then
    warn "dinox not found in PATH after install. You may need to re-login or check /usr/bin."
else
    INSTALLED_AT="$DINOX_BIN"
    # Warn if PATH would resolve to an unexpected location
    if [[ "$INSTALLED_AT" != "/usr/bin/dinox" ]]; then
        warn "dinox resolves to $INSTALLED_AT — expected /usr/bin/dinox."
        warn "Check your PATH (ensure /usr/local/bin does not shadow /usr/bin)."
    else
        success "dinox → $INSTALLED_AT"
    fi
fi

PLUGINS_DIR="/usr/lib/dino/plugins"
if [ -d "$PLUGINS_DIR" ]; then
    PLUGIN_COUNT=$(find "$PLUGINS_DIR" -name "*.so" | wc -l)
    success "Plugins installed: $PLUGIN_COUNT .so files in $PLUGINS_DIR"
else
    warn "Plugin directory $PLUGINS_DIR not found."
fi

echo ""
echo -e "${GREEN}${BOLD}  DinoX installation complete!${NC}"
echo ""
echo -e "  Run:              ${BOLD}dinox${NC}"
echo -e "  Run minimized:    ${BOLD}dinox --minimized${NC}"
echo -e "  Autostart file:   ${BOLD}~/.config/autostart/im.github.rallep71.DinoX.desktop${NC}"
echo -e "  Disable autostart:${BOLD}rm ~/.config/autostart/im.github.rallep71.DinoX.desktop${NC}"
echo -e "  Uninstall:        ${BOLD}./install.sh --uninstall${NC}"
echo ""
