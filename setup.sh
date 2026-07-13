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

    # Add NVIDIA CUDA repository for latest drivers
    wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring.deb
    dpkg -i /tmp/cuda-keyring.deb
    apt modernize-sources || true
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

# Detect NVIDIA GPU PCI address.
# lspci prints "<addr> 3D controller: NVIDIA ..." -- the class precedes the
# vendor, so a 'nvidia.*3d' pattern never matches. Match either order.
GPU_PCI=$(lspci -D | grep -iE '(3d|vga)[^:]*controller.*nvidia|nvidia.*(3d|vga)' | head -1 | awk '{print $1}')
if [[ -z "$GPU_PCI" ]]; then
    echo "Error: No NVIDIA GPU found"
    exit 1
fi
echo "Found NVIDIA GPU at: $GPU_PCI"
echo ""

# 1. Demote NVIDIA EGL priority
# libglvnd loads EGL vendor JSONs in filename order; 10_nvidia.json wins over
# 50_mesa.json, so the desktop renders on (and wakes) the dGPU. A plain
# `mv 10->90` is NOT durable: libnvidia-gl upgrades RE-CREATE 10_nvidia.json,
# silently undoing the demotion (and a second mv then fails because 90_ exists).
# Use dpkg-divert so the package's own 10_nvidia.json is permanently redirected
# and never reappears at the winning filename across upgrades.
EGL_DIR=/usr/share/glvnd/egl_vendor.d
if ! dpkg-divert --list "$EGL_DIR/10_nvidia.json" | grep -q .; then
    # The divert renames 10_nvidia.json -> 90_nvidia.json. A prior manual
    # `mv 10->90` (plus a driver upgrade re-creating 10_) can leave BOTH files
    # present; dpkg-divert then refuses ("rename involves overwriting 90_").
    # 90_ is a byte-identical copy of the package's 10_, so remove the stale 90_
    # to free the rename target before diverting.
    if [[ -f "$EGL_DIR/10_nvidia.json" && -f "$EGL_DIR/90_nvidia.json" ]]; then
        rm -f "$EGL_DIR/90_nvidia.json"
    elif [[ ! -f "$EGL_DIR/10_nvidia.json" && -f "$EGL_DIR/90_nvidia.json" ]]; then
        # Only the renamed copy exists: restore it so divert --rename can act.
        mv "$EGL_DIR/90_nvidia.json" "$EGL_DIR/10_nvidia.json"
    fi
    dpkg-divert --add --rename --divert "$EGL_DIR/90_nvidia.json" \
        "$EGL_DIR/10_nvidia.json"
    echo "[1/14] Demoted NVIDIA EGL priority (dpkg-divert 10->90, upgrade-proof)"
else
    echo "[1/14] NVIDIA EGL already diverted (skipped)"
fi

# 2. Force Mesa GLX/PRIME system-wide (EGL is already handled by step 1's divert)
#
# Do NOT set __EGL_VENDOR_LIBRARY_FILENAMES here. It pins an absolute HOST path
# that leaks into confined snaps via /etc/environment (snap DBus-activated
# services inherit it), where that host path is invalid inside the snap mount
# namespace -> eglGetPlatformDisplayEXT finds no provider -> SIGABRT. Step 1's
# dpkg-divert (10_nvidia.json -> 90_nvidia.json) already makes 50_mesa.json the
# highest-priority EGL vendor system-wide, so the pin is redundant for the host
# and purely harmful to snaps. GLX + PRIME below are unaffected by confinement.
if ! grep -q "__GLX_VENDOR_LIBRARY_NAME" /etc/environment 2>/dev/null; then
    cat >> /etc/environment << 'EOF'

# Force Mesa for GLX, prevent nvidia from being used by gnome-shell and Chrome
# (including PWAs launched outside the patched system .desktop). EGL is forced
# to Mesa by the dpkg-divert in step 1, not here -- see note above.
__NV_PRIME_RENDER_OFFLOAD=0
__GLX_VENDOR_LIBRARY_NAME=mesa
EOF
    echo "[2/14] Added Mesa GLX/PRIME environment variables"
else
    echo "[2/14] Mesa GLX/PRIME environment variables already set (skipped)"
fi

# 3. Keep NVIDIA out of the desktop DRM stack (compute-only dGPU)
#
# The dGPU drives no display connectors here (all eDP/DP/HDMI are on the Intel
# iGPU). `options nvidia-drm modeset=0` is not enough: nvidia_drm can still load,
# create /dev/dri/card0, and be opened by GNOME. That repeated desktop probing has
# been observed immediately before Xid 62 / GSP PMU halt on this laptop. CUDA uses
# /dev/nvidia* and nvidia_uvm, so it does not need nvidia_drm.
KMS_SHADOW=/etc/modprobe.d/nvidia-kms.conf
cat > "$KMS_SHADOW" << 'EOF'
# Keep the compute dGPU out of the desktop DRM stack.
# modeset=0 alone still exposes /dev/dri/card*; blacklist nvidia_drm instead.
blacklist nvidia_drm
install nvidia_drm /bin/false
EOF
echo "[3/14] Blacklisted nvidia_drm so the desktop cannot open NVIDIA DRM nodes"

LEGACY_KMS=/etc/modprobe.d/nvidia-graphics-drivers-kms.conf
if [[ -f "$LEGACY_KMS" ]]; then
    sed -i 's/^options nvidia-drm/# options nvidia-drm/' "$LEGACY_KMS"
    echo "       (neutralized legacy $LEGACY_KMS)"
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

# 6. Remove wake-before-sleep workaround
# This service re-pokes the firmware power path before every sleep/shutdown. On
# this laptop, suspend/resume logs show NVIDIA ACPI D-notifier failures, so keep
# D3cold via runtime PM but avoid this extra transition.
systemctl disable --now nvidia-wake.service 2>/dev/null || true
rm -f /etc/systemd/system/nvidia-wake.service
echo "[6/14] Removed nvidia-wake service"

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

# Remove nvidia modules if they were added (check multiple possible paths)
# Guard against empty DESTDIR to avoid deleting from live system
[ -n "${DESTDIR}" ] && {
    rm -f "${DESTDIR}"/lib/modules/*/kernel/drivers/video/nvidia* 2>/dev/null || true
    rm -f "${DESTDIR}"/lib/modules/*/updates/dkms/nvidia* 2>/dev/null || true
    rm -f "${DESTDIR}"/lib/modules/*/kernel/drivers/gpu/nvidia* 2>/dev/null || true
}
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

# 8. Remove extra runtime-PM systemd pokes
# The udev rule already sets power/control=auto for NVIDIA 3D controllers. Extra
# boot/resume writes add more transitions through the flaky SBIOS power path.
systemctl disable --now nvidia-power-control.service 2>/dev/null || true
rm -f /etc/systemd/system/nvidia-power-control.service
rm -f /etc/systemd/system/nvidia-resume.service.d/restore-pm.conf
rmdir /etc/systemd/system/nvidia-resume.service.d 2>/dev/null || true
echo "[8/14] Removed extra runtime-PM boot/resume services"

# 9. Disable nvidia-persistenced
if systemctl is-enabled nvidia-persistenced &>/dev/null; then
    systemctl disable nvidia-persistenced
    echo "[9/14] Disabled nvidia-persistenced"
else
    echo "[9/14] nvidia-persistenced already disabled (skipped)"
fi

# 9b. Disable nvidia-powerd (Dynamic Boost daemon)
# This laptop's SBIOS does not expose the NVPCF ACPI interface and actively
# requests Dynamic Boost be disabled (powerd logs: "Client (presumably SBIOS)
# has requested to disable Dynamic Boost DC controller"). With powerd running,
# it polls this dead interface and floods the journal every ~22s with:
#   NVRM: GPU0 ... PRH failed to update thermal limit! @ platform_request_handler.c
# Dynamic Boost only rebalances CPU<->GPU watts while the GPU is active; it is
# useless for sustained compute and unavailable here regardless. Masking it
# removes the every-22s flood and releases the device handle.
#
# NOTE: masking powerd does NOT eliminate PRH messages entirely. The driver
# itself still probes the SBIOS thermal interface at init and on each D3cold
# wake, so a few PRH lines per boot remain (clustered at boot/wake, not the
# periodic flood). These are benign and unavoidable: there is no driver flag to
# disable the PlatformRequestHandler (modinfo nvidia exposes none), and the true
# fix is an LG BIOS that exposes NVPCF. D3cold/battery and suspend use separate
# subsystems and are unaffected.
#
# Use `mask`, not `disable`: the nvidia driver package ships a systemd preset
# (70-nvidia-driver.preset) that re-enables nvidia-powerd on every driver
# upgrade. `disable` only removes the symlink and is silently undone by the next
# `systemctl preset`. `mask` points the unit at /dev/null and survives presets
# and upgrades -- the durable form.
if [[ "$(systemctl is-enabled nvidia-powerd 2>/dev/null)" != "masked" ]]; then
    systemctl mask --now nvidia-powerd
    echo "[9b/14] Masked nvidia-powerd (SBIOS refuses Dynamic Boost; upgrade-proof)"
else
    echo "[9b/14] nvidia-powerd already masked (skipped)"
fi

# 10. Disable nvidia suspend/hibernate/resume services
# The 07:59 suspend/resume log showed NVIDIA ACPI D-notifier failures, and the
# later wedge followed repeated dGPU wakeups through the same power path.
systemctl disable --now nvidia-suspend nvidia-hibernate nvidia-resume 2>/dev/null || true
echo "[10/14] Disabled nvidia suspend/hibernate/resume services"

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
# Superseded by step 2: __NV_PRIME_RENDER_OFFLOAD and __GLX_VENDOR_LIBRARY_NAME
# are now set in /etc/environment, which covers PWA launchers and any other
# Chrome entry point. The per-.desktop patch below also gets wiped by every
# google-chrome-stable apt upgrade, so it's not worth maintaining.
# CHROME_DESKTOP="/usr/share/applications/google-chrome.desktop"
# if [[ -f "$CHROME_DESKTOP" ]]; then
#     if ! grep -q "__NV_PRIME_RENDER_OFFLOAD=0" "$CHROME_DESKTOP"; then
#         sed -i 's|^Exec=/usr/bin/google-chrome-stable|Exec=env __NV_PRIME_RENDER_OFFLOAD=0 __GLX_VENDOR_LIBRARY_NAME=mesa /usr/bin/google-chrome-stable|' "$CHROME_DESKTOP"
#         echo "[12/14] Patched Chrome to use Mesa"
#     else
#         echo "[12/14] Chrome already patched (skipped)"
#     fi
# else
#     echo "[12/14] Chrome not installed (skipped)"
# fi
echo "[12/14] Chrome bypass handled via /etc/environment (step 2)"

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
echo "After reboot, verify:"
echo "  cat /sys/bus/pci/devices/${GPU_PCI}/power/runtime_status  # 'suspended' when idle"
echo "  lsmod | grep '^nvidia_drm'                                # no output"
echo "  test ! -e /dev/dri/card0 || readlink /sys/class/drm/card0/device/driver"
echo "  dpkg-divert --list '*10_nvidia*'                          # divert listed"
echo "  systemctl is-enabled nvidia-powerd                       # masked"
echo "  systemctl is-enabled nvidia-suspend nvidia-resume         # disabled"
echo "=========================================="
