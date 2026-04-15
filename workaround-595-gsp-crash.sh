#!/bin/bash
# Workaround: NVIDIA GSP Firmware Crash (Xid 120) on RTX 5050 Mobile
#
# Problem:
#   The NVIDIA GPU's GSP (GPU System Processor) firmware crashes ~2 minutes
#   after boot, leaving the GPU unresponsive. This blocks nvidia-smi, CUDA,
#   and system suspend.
#
#   dmesg symptoms:
#     NVRM: GPU0 PlatformRequestHandler failed to get target temp from SBIOS
#     NVRM: GPU0 PRH failed to update thermal limit!
#     NVRM: GPU0 kgspHealthCheck_TU102: GSP-CrashCat Report
#     NVRM: Xid (PCI:0000:01:00): 120, GSP task panic
#     nvidia 0000:01:00.0: PM: failed to suspend async: error -5
#
#   After the crash:
#     /sys/bus/pci/devices/0000:01:00.0/power/runtime_status shows "error"
#     nvidia-smi hangs indefinitely
#
# Affected system:
#   LG gram 16Z90TR (RTX 5050 Mobile / Blackwell)
#   BIOS: A3ZJ3390 (07/16/2025)
#   Observed with: nvidia-open 595.45.04, 595.58.03 on kernel 6.17.0-19/20
#   Reproducible across reboots.
#
# Root cause analysis:
#   The "PlatformRequestHandler failed to get target temp from SBIOS" errors
#   indicate the driver cannot communicate with the laptop BIOS for thermal
#   management. This is a known class of issue with Blackwell mobile GPUs on
#   Linux, and multiple reports with RTX 5070/5080 laptops were resolved by
#   laptop BIOS/firmware updates.
#
#   Additionally, 595.45.04 is a BETA driver that Ubuntu's CUDA repository
#   ships as the latest version, which may contribute to instability.
#
# Fix (two steps):
#   1. Check for an LG BIOS update for the 16Z90TR — this is the most likely
#      root cause, as the SBIOS thermal interface is what's failing.
#   2. Downgrade nvidia driver to 590.48.01 (last stable) and pin to prevent
#      apt from upgrading back to 595.x beta.
#
# References:
#   - RTX 5070 Mobile GSP timeouts fixed by BIOS update (ASUS):
#     https://forums.developer.nvidia.com/t/rtx-5070-mobile-blackwell-gsp-timeouts-0x0000ca7d-xid-79-on-kernel-6-17-driver-580-126-ubuntu-24-04-4/360897
#   - RTX 5070 fixed by BIOS update (Linux Mint):
#     https://forums.linuxmint.com/viewtopic.php?t=451701
#   - RTX 5080 D3cold/suspend broken with nvidia-open:
#     https://forums.developer.nvidia.com/t/rtx-5080-nvidia-open-no-d3cold-hybrid-suspend-broken/336687
#   - 595.45.04 suspend crash (different root cause, SELinux-related):
#     https://forums.developer.nvidia.com/t/system-crashes-on-suspend-with-595-45-04/363397
#   - 595.45.04 is a beta driver:
#     https://linuxiac.com/nvidia-595-45-04-beta-linux-driver-released/
#   - 595 release feedback thread:
#     https://forums.developer.nvidia.com/t/595-release-feedback-discussion/362561
#
# Run with: sudo ./workaround-595-gsp-crash.sh
# Then reboot.

set -e

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo ./workaround-595-gsp-crash.sh)"
    exit 1
fi

TARGET_VERSION="590.48.01-0ubuntu1"

# Check current driver version
CURRENT=$(dpkg-query -W -f='${Version}' nvidia-open 2>/dev/null || echo "not installed")
echo "Current nvidia-open version: $CURRENT"
echo "Target nvidia-open version:  $TARGET_VERSION"
echo ""

if [[ "$CURRENT" == "$TARGET_VERSION" ]]; then
    echo "Already on target version. Ensuring packages are held."
    apt-mark hold nvidia-open nvidia-driver-open
    echo "Done. Packages held."
    exit 0
fi

echo "Downgrading nvidia-open from $CURRENT to $TARGET_VERSION..."
echo ""

# Downgrade all nvidia packages to the 590.48.01 versions.
apt install -y --allow-downgrades \
    nvidia-open="$TARGET_VERSION" \
    nvidia-driver-open="$TARGET_VERSION" \
    nvidia-dkms-open="$TARGET_VERSION" \
    nvidia-kernel-source-open="$TARGET_VERSION" \
    nvidia-kernel-common="$TARGET_VERSION" \
    nvidia-firmware="$TARGET_VERSION" \
    nvidia-modprobe="$TARGET_VERSION" \
    nvidia-persistenced="$TARGET_VERSION" \
    nvidia-settings="$TARGET_VERSION" \
    libnvidia-gl="$TARGET_VERSION" \
    libnvidia-compute="$TARGET_VERSION" \
    libnvidia-decode="$TARGET_VERSION" \
    libnvidia-encode="$TARGET_VERSION" \
    libnvidia-extra="$TARGET_VERSION" \
    libnvidia-fbc1="$TARGET_VERSION" \
    libnvidia-cfg1="$TARGET_VERSION" \
    libnvidia-common="$TARGET_VERSION" \
    libnvidia-gpucomp="$TARGET_VERSION" \
    xserver-xorg-video-nvidia="$TARGET_VERSION"

echo ""
echo "Pinning nvidia metapackages to prevent re-upgrade to 595.x..."
echo "(Deps are version-locked, so holding the top-level packages is sufficient.)"

apt-mark hold nvidia-open nvidia-driver-open

echo ""
echo "=========================================="
echo "Downgrade complete. Reboot to apply."
echo ""
echo "After reboot, verify:"
echo "  nvidia-smi                    # Should respond immediately"
echo "  journalctl -b | grep GSP     # Should show no CrashCat reports"
echo "  journalctl -b | grep 'Xid'   # Should show no Xid 120 errors"
echo ""
echo "NOTE: If GSP crashes persist on 590.48.01, the root cause is likely"
echo "the laptop BIOS. Check for an LG BIOS update for the 16Z90TR at:"
echo "  https://www.lg.com/us/support/software-firmware-drivers"
echo ""
echo "To undo the hold later (when a stable 595+ driver is released):"
echo "  sudo apt-mark unhold nvidia-open nvidia-driver-open"
echo "=========================================="
