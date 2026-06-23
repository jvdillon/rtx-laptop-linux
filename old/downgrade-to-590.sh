#!/bin/bash
# Downgrade nvidia from 595.x (broken on LG Gram RTX 5050: GSP heartbeat
# timeout / "PlatformRequestHandler failed to get target temp from SBIOS")
# back to 590.48.01-0ubuntu1, which was the last version known to suspend
# correctly on this laptop. See workaround-595-gsp-crash.sh for context.
#
# Constraints discovered on Ubuntu 26.04:
#   - 590.48.01 DKMS does not build on kernel >= 6.19 (uvm patch incomplete).
#     We're on 7.0.0-15-generic by default. The 6.17.0-29-generic kernel is
#     still installed and DOES build 590.48.01 cleanly.
#   - The .debs come from NVIDIA's CUDA ubuntu2404 repo (the only place that
#     still publishes real 590.48.01 binaries). 25.10's Ubuntu archive only
#     has transitional shells that pull 595.
#   - glibc 2.43 (26.04) is forward-compatible with the 24.04-built binaries.
#
# What this script does:
#   1. Refuses to run unless the booted kernel is 6.17.x.
#   2. Restricts DKMS auto-build to 6.x kernels so future kernel updates
#      don't trigger a 590 build failure on 7.x.
#   3. Purges the 595.x stack.
#   4. Installs the staged 590.48.01 .debs from ./590-debs/.
#   5. apt-mark holds the 590 metapackages and the 6.17 kernel.
#   6. Restores /etc/default/grub if absent and pins GRUB to default-boot
#      the 6.17 kernel.
#   7. Rebuilds initramfs + grub.cfg.
#
# Run with: sudo ./downgrade-to-590.sh
# Then reboot.

set -e

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo ./downgrade-to-590.sh)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBS_DIR="$SCRIPT_DIR/590-debs"
TARGET_VERSION="590.48.01-0ubuntu1"
KERNEL_REGEX="^6\\.(1[6-8])\\."   # accept 6.16, 6.17, 6.18

# ---- 0. Sanity checks ---------------------------------------------------

running="$(uname -r)"
if ! [[ "$running" =~ ^6\.17\. ]]; then
    cat <<EOF
Refusing to run.

The currently booted kernel is $running.
590.48.01 DKMS will not build on kernels >= 6.19.

Reboot and pick "Ubuntu, with Linux 6.17.0-29-generic" from the GRUB
advanced submenu, then re-run this script.
EOF
    exit 1
fi

if [[ ! -d "$DEBS_DIR" ]]; then
    echo "Missing $DEBS_DIR. Re-stage the 590.48.01 .debs first."
    exit 1
fi

needed=(nvidia-open nvidia-driver-open nvidia-dkms-open nvidia-kernel-source-open
        nvidia-kernel-common nvidia-firmware nvidia-modprobe nvidia-persistenced
        nvidia-settings xserver-xorg-video-nvidia libnvidia-gl libnvidia-compute
        libnvidia-decode libnvidia-encode libnvidia-extra libnvidia-fbc1
        libnvidia-cfg1 libnvidia-gpucomp)
missing=()
for p in "${needed[@]}"; do
    [[ -f "$DEBS_DIR/${p}_${TARGET_VERSION}_amd64.deb" ]] || missing+=("$p")
done
if (( ${#missing[@]} )); then
    echo "Missing staged .debs: ${missing[*]}"
    exit 1
fi

# ---- 1. Pin DKMS to 6.x kernels only ------------------------------------

mkdir -p /etc/dkms/framework.conf.d
cat > /etc/dkms/framework.conf.d/restrict-nvidia-to-6.conf <<EOF
# Prevent nvidia-590 DKMS autoinstall on kernels >= 6.19 (uvm patch
# incomplete). Re-applied automatically on every kernel install.
BUILD_EXCLUSIVE_KERNEL_REGEX="$KERNEL_REGEX"
EOF
echo "[1/7] DKMS restricted to kernels matching $KERNEL_REGEX"

# ---- 2. Purge 595.x and any leftover versioned 595 packages -------------

# `apt purge '^nvidia.*' '^libnvidia.*'` would also nuke libnvidia-egl-*
# helper libs (egl-gbm1, egl-wayland1/21, egl-xcb1, egl-xlib1) which are
# not version-tied to the driver. Keep them.
apt-mark unhold $(apt-mark showhold | grep -E '^(nvidia|libnvidia)' || true) 2>/dev/null || true
apt purge -y \
    'nvidia-open' 'nvidia-driver-open' 'nvidia-dkms-open' \
    'nvidia-kernel-source-open' 'nvidia-kernel-common' 'nvidia-firmware' \
    'nvidia-modprobe' 'nvidia-persistenced' 'nvidia-settings' \
    'nvidia-compute-utils-595' 'nvidia-utils-595' \
    'xserver-xorg-video-nvidia-595' \
    'libnvidia-cfg1' 'libnvidia-compute' 'libnvidia-decode' 'libnvidia-encode' \
    'libnvidia-fbc1' 'libnvidia-gl' 'libnvidia-gpucomp' \
    'libnvidia-cfg1-595' 'libnvidia-common-595' 'libnvidia-compute-595' \
    'libnvidia-decode-595' 'libnvidia-encode-595' 'libnvidia-extra-595' \
    'libnvidia-fbc1-595' 'libnvidia-gl-595' \
    'nvidia-firmware-595-595.58.03' 'nvidia-dkms-595-open' \
    'nvidia-driver-595-open' 'nvidia-kernel-common-595' \
    'nvidia-kernel-source-595-open' \
    2>/dev/null || true
apt autoremove -y || true
echo "[2/7] Purged 595.x stack"

# ---- 3. Install staged 590.48.01 .debs ----------------------------------

# Hold the version while installing so apt won't reach for the CUDA repo's
# 595.x candidate when resolving deps.
cat > /etc/apt/preferences.d/nvidia-pin-590 <<EOF
Package: nvidia-* libnvidia-*
Pin: version $TARGET_VERSION
Pin-Priority: 1001
EOF

apt install -y "$DEBS_DIR"/*.deb
rm /etc/apt/preferences.d/nvidia-pin-590
echo "[3/7] Installed 590.48.01"

# ---- 4. Hold metapackages and kernel ------------------------------------

apt-mark hold nvidia-open nvidia-driver-open nvidia-dkms-open \
              linux-image-6.17.0-29-generic
echo "[4/7] Held nvidia metapackages and 6.17 kernel"

# ---- 5. Restore /etc/default/grub if it's missing -----------------------

if [[ ! -f /etc/default/grub && -f /etc/default/grub.ucf-dist ]]; then
    cp /etc/default/grub.ucf-dist /etc/default/grub
    echo "[5a/7] Restored /etc/default/grub from .ucf-dist"
else
    echo "[5a/7] /etc/default/grub already present"
fi

# Re-apply install-ubuntu.sh kernel-cmdline customizations idempotently.
add_cmdline_token() {
    local token="$1"
    grep -q -- "$token" /etc/default/grub && return 0
    sed -i -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=\".*)\"$|\1 $token\"|" /etc/default/grub
}
add_cmdline_token "nohz_full=1-15"
add_cmdline_token "loglevel=3"
# resume= / resume_offset= come from /boot/grub/grub.cfg's existing entry;
# rederive to be safe (only if hibernate is configured).
if [[ -f /swap.img ]]; then
    DEVICE=$(findmnt -no SOURCE -T /swap.img)
    RESUME="UUID=$(findmnt -no UUID -T /swap.img)"
    RESUME_OFFSET=$(filefrag -v /swap.img | grep " 0:" | awk '{print $4}' | tr -d '.')
    sed -i -E \
        -e 's/ resume=[^ "]+//g' \
        -e 's/ resume_offset=[^ "]+//g' \
        -e "s|^(GRUB_CMDLINE_LINUX_DEFAULT=\".*)\"$|\1 resume=$RESUME resume_offset=$RESUME_OFFSET\"|" \
        /etc/default/grub
fi
echo "[5b/7] Kernel cmdline tokens re-applied"

# ---- 6. Pin default boot to 6.17 ----------------------------------------

# Use exact menuentry id so saved-default survives kernel reorderings.
SUBMENU_ID="$(grep -oE "menuentry_id_option 'gnulinux-advanced-[^']+'" /boot/grub/grub.cfg | head -1 | sed -E "s/.*'(.*)'/\1/")"
ENTRY_ID="$(grep -oE "menuentry_id_option 'gnulinux-6\.17\.0-29-generic-advanced-[^']+'" /boot/grub/grub.cfg | head -1 | sed -E "s/.*'(.*)'/\1/")"
if [[ -n "$SUBMENU_ID" && -n "$ENTRY_ID" ]]; then
    sed -i -E "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${SUBMENU_ID}>${ENTRY_ID}\"|" /etc/default/grub
    grep -q '^GRUB_DEFAULT=' /etc/default/grub || \
        echo "GRUB_DEFAULT=\"${SUBMENU_ID}>${ENTRY_ID}\"" >> /etc/default/grub
    echo "[6/7] GRUB_DEFAULT pinned to 6.17.0-29-generic"
else
    echo "[6/7] WARNING: could not locate 6.17 menuentry in grub.cfg; pick manually at boot"
fi

# ---- 7. Rebuild initramfs + grub.cfg ------------------------------------

update-initramfs -u -k 6.17.0-29-generic
update-grub
echo "[7/7] Rebuilt initramfs and grub.cfg"

cat <<EOF

==========================================
Downgrade complete. Reboot to apply.

After reboot, verify:
  uname -r                              # 6.17.0-29-generic
  dpkg-query -W -f='\${Version}\n' nvidia-open
                                        # 590.48.01-0ubuntu1
  journalctl -b -k | grep -iE 'GSP|Xid|SBIOS|heartbeat'
                                        # should be empty
  systemctl suspend                     # the actual test

To undo the kernel hold later when 590 builds on 7.x or a fixed 595+
ships:
  sudo apt-mark unhold nvidia-open nvidia-driver-open nvidia-dkms-open \\
                       linux-image-6.17.0-29-generic
  sudo rm /etc/dkms/framework.conf.d/restrict-nvidia-to-6.conf
==========================================
EOF
