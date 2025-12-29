#!/bin/bash
# RTX Laptop Linux Power Management Setup
# Installs NVIDIA drivers and enables D3cold power states for hybrid graphics.
# Run with: sudo ./setup.sh

set -e

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo ./setup.sh)"
    exit 1
fi

# Get the user who invoked sudo (for user-specific config)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# ------------------------------------------------------------------------------
# Driver Installation (Ubuntu)
# ------------------------------------------------------------------------------

install_drivers() {
    echo "Installing NVIDIA drivers..."

    # Purge existing nvidia packages
    apt purge -y '^nvidia-.*' '^libnvidia-.*' 2>/dev/null || true
    apt autoremove -y

    apt update

    # Install open driver (nvidia-open is the open-source kernel modules)
    apt install -y nvidia-open

    echo "Driver installation complete."
}

# Check if drivers need installation
if ! command -v nvidia-smi &>/dev/null; then
    install_drivers
else
    DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    echo "NVIDIA driver $DRIVER_VERSION already installed."
    read -p "Reinstall drivers? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        install_drivers
    fi
fi

# ------------------------------------------------------------------------------
# Power Management Setup
# ------------------------------------------------------------------------------

# Detect NVIDIA GPU PCI address
GPU_PCI=$(lspci -D | grep -i 'nvidia.*3d\|nvidia.*vga' | head -1 | awk '{print $1}')
if [[ -z "$GPU_PCI" ]]; then
    echo "Error: No NVIDIA GPU found"
    exit 1
fi
echo "Found NVIDIA GPU at: $GPU_PCI"
echo ""

# 1. Demote NVIDIA EGL priority
if [[ -f /usr/share/glvnd/egl_vendor.d/10_nvidia.json ]]; then
    mv /usr/share/glvnd/egl_vendor.d/{10,90}_nvidia.json
    echo "[1/14] Demoted NVIDIA EGL priority"
else
    echo "[1/14] NVIDIA EGL priority already demoted (skipped)"
fi

# 2. Force Mesa EGL system-wide
if ! grep -q "__EGL_VENDOR_LIBRARY_FILENAMES" /etc/environment 2>/dev/null; then
    cat >> /etc/environment << 'EOF'

# Force Mesa/Intel for EGL, prevent nvidia from being used by gnome-shell
__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
EOF
    echo "[2/14] Added Mesa EGL environment variable"
else
    echo "[2/14] Mesa EGL environment variable already set (skipped)"
fi

# 3. Disable NVIDIA DRM modesetting
if [[ -f /etc/modprobe.d/nvidia-graphics-drivers-kms.conf ]]; then
    if grep -q "modeset=1" /etc/modprobe.d/nvidia-graphics-drivers-kms.conf; then
        sed -i 's/modeset=1/modeset=0/' /etc/modprobe.d/nvidia-graphics-drivers-kms.conf
        echo "[3/14] Disabled NVIDIA DRM modesetting"
    else
        echo "[3/14] NVIDIA DRM modesetting already disabled (skipped)"
    fi
else
    echo "[3/14] No nvidia-graphics-drivers-kms.conf found (skipped)"
fi

# 4. Fix nv_open_q CPU spin bug
touch /etc/modprobe.d/nvidia-graphics-drivers.conf
if ! grep -q "NVreg_EnableNonblockingOpen=0" /etc/modprobe.d/nvidia-graphics-drivers.conf; then
    cat >> /etc/modprobe.d/nvidia-graphics-drivers.conf << 'EOF'

# Fix nv_open_q CPU spin bug
# https://github.com/NVIDIA/open-gpu-kernel-modules/discussions/615
options nvidia NVreg_EnableNonblockingOpen=0
EOF
    echo "[4/14] Added nv_open_q CPU spin fix"
else
    echo "[4/14] nv_open_q fix already present (skipped)"
fi

# 5. Enable runtime PM via udev
cat > /etc/udev/rules.d/80-nvidia-pm.rules << 'EOF'
# Enable runtime power management for NVIDIA GPUs
# Vendor 0x10de = NVIDIA, Class 0x030200 = 3D controller
ACTION=="add|change|bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", ATTR{power/control}="auto"
EOF
echo "[5/14] Created udev rule for runtime PM"

# 6. Wake GPU before shutdown/sleep
cat > /etc/systemd/system/nvidia-wake.service << EOF
[Unit]
Description=Wake NVIDIA GPU before shutdown/sleep to prevent hangs
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target suspend.target hibernate.target hybrid-sleep.target nvidia-suspend.service nvidia-hibernate.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo on > /sys/bus/pci/devices/${GPU_PCI}/power/control; sleep 1'

[Install]
WantedBy=halt.target reboot.target shutdown.target suspend.target hibernate.target hybrid-sleep.target
EOF
systemctl daemon-reload
systemctl enable nvidia-wake.service
echo "[6/14] Created and enabled nvidia-wake service"

# 7. Fix hibernate resume (exclude nvidia from initramfs) + early i915 KMS
if [[ -d /etc/dracut.conf.d ]]; then
    # Ubuntu 25.04+ uses dracut
    echo 'omit_drivers+=" nvidia nvidia-drm nvidia-modeset nvidia-uvm "' > /etc/dracut.conf.d/nvidia-exclude.conf
    echo 'add_drivers+=" i915 "' > /etc/dracut.conf.d/i915.conf
    echo "[7/14] Excluded nvidia from initramfs, added early i915 (dracut)"
elif [[ -d /etc/initramfs-tools ]]; then
    # Ubuntu 24.04 uses initramfs-tools
    # Exclude nvidia modules from initramfs
    cat > /etc/initramfs-tools/hooks/exclude-nvidia << 'HOOK'
#!/bin/sh
# Exclude nvidia modules from initramfs for hibernate compatibility
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0;; esac

# Remove nvidia modules if they were added
rm -f "${DESTDIR}/lib/modules/$(uname -r)/kernel/drivers/video/nvidia"* 2>/dev/null || true
HOOK
    chmod +x /etc/initramfs-tools/hooks/exclude-nvidia
    # Add i915 for early KMS
    if ! grep -q "^i915$" /etc/initramfs-tools/modules 2>/dev/null; then
        echo "i915" >> /etc/initramfs-tools/modules
    fi
    echo "[7/14] Excluded nvidia from initramfs, added early i915 (initramfs-tools)"
else
    echo "[7/14] No initramfs config found (skipped)"
fi

# 8a. Restore runtime PM after boot
cat > /etc/systemd/system/nvidia-power-control.service << EOF
[Unit]
Description=Enable NVIDIA GPU runtime power management
After=multi-user.target tlp.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo auto > /sys/bus/pci/devices/${GPU_PCI}/power/control'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable nvidia-power-control.service
echo "[8a/14] Created and enabled nvidia-power-control service"

# 8b. Restore runtime PM after resume
mkdir -p /etc/systemd/system/nvidia-resume.service.d
cat > /etc/systemd/system/nvidia-resume.service.d/restore-pm.conf << EOF
[Service]
ExecStartPost=/bin/bash -c 'echo auto > /sys/bus/pci/devices/${GPU_PCI}/power/control'
EOF
echo "[8b/14] Added runtime PM restore to nvidia-resume service"

# 9. Disable nvidia-persistenced
if systemctl is-enabled nvidia-persistenced &>/dev/null; then
    systemctl disable nvidia-persistenced
    echo "[9/14] Disabled nvidia-persistenced"
else
    echo "[9/14] nvidia-persistenced already disabled (skipped)"
fi

# 10. Enable nvidia suspend/hibernate/resume services
systemctl enable nvidia-suspend nvidia-hibernate nvidia-resume 2>/dev/null || true
echo "[10/14] Enabled nvidia suspend/hibernate/resume services"

# 11. Disable nvidia-settings autostart (for the real user)
AUTOSTART_DIR="$REAL_HOME/.config/autostart"
mkdir -p "$AUTOSTART_DIR"
cat > "$AUTOSTART_DIR/nvidia-settings-autostart.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Hidden=true
EOF
chown -R "$REAL_USER:$REAL_USER" "$AUTOSTART_DIR"
echo "[11/14] Disabled nvidia-settings autostart"

# 12. Prevent Chrome from waking GPU
CHROME_DESKTOP="/usr/share/applications/google-chrome.desktop"
if [[ -f "$CHROME_DESKTOP" ]]; then
    if ! grep -q "__NV_PRIME_RENDER_OFFLOAD=0" "$CHROME_DESKTOP"; then
        sed -i 's|^Exec=/usr/bin/google-chrome-stable|Exec=env __NV_PRIME_RENDER_OFFLOAD=0 __GLX_VENDOR_LIBRARY_NAME=mesa /usr/bin/google-chrome-stable|' "$CHROME_DESKTOP"
        echo "[12/14] Patched Chrome to use Mesa"
    else
        echo "[12/14] Chrome already patched (skipped)"
    fi
else
    echo "[12/14] Chrome not installed (skipped)"
fi

# 13. Configure TLP (if installed)
if [[ -f /etc/tlp.conf ]]; then
    if ! grep -q 'RUNTIME_PM_ON_AC="auto"' /etc/tlp.conf; then
        sed -i '/^#*RUNTIME_PM_ON_AC/d' /etc/tlp.conf
        echo 'RUNTIME_PM_ON_AC="auto"' >> /etc/tlp.conf
        echo "[13/14] Configured TLP for runtime PM on AC"
    else
        echo "[13/14] TLP already configured (skipped)"
    fi
else
    echo "[13/14] TLP not installed (skipped)"
fi

# 14. Rebuild initramfs
echo ""
echo "[14/14] Rebuilding initramfs..."
update-initramfs -u 2>/dev/null || dracut --force 2>/dev/null || true

echo ""
echo "=========================================="
echo "Setup complete! Reboot to apply changes."
echo ""
echo "After reboot, verify with:"
echo "  cat /sys/bus/pci/devices/${GPU_PCI}/power/runtime_status"
echo "  # Should show 'suspended' when GPU is idle"
echo "=========================================="
