#!/usr/bin/env bash
# Configure this Ubuntu laptop as an Intel-display, NVIDIA-compute system.
#
# This file has two jobs:
#   1. Bootstrap the NVIDIA open driver on a fresh Ubuntu install.
#   2. Record the power policy, the workarounds behind it, and their exit paths.
#
# Hardware policy:
#   - Intel drives the desktop and every physical display connector.
#   - NVIDIA is intended for explicit compute; fine runtime PM (0x02) and D3cold
#     are the desired steady state because they materially reduce idle power.
#   - NVIDIA's EGL and Vulkan manifests are disabled so desktop applications
#     cannot auto-select the dGPU through those graphics APIs.
#   - GStreamer's NVIDIA codec and HIP plugins are disabled because their
#     login-time scans open CUDA. Normal CUDA remains available through libcuda
#     and /dev/nvidia*; only NVIDIA/HIP acceleration inside GStreamer is absent.
#
# Temporary driver/firmware workarounds:
#   - Keep packaged fine runtime PM (0x02). A trial of coarse mode (0x01) caused
#     a boot-time RmInitAdapter lock deadlock and was reverted. Disabling runtime
#     PM (0x00) was considered but not boot-tested because it sacrifices D3cold.
#   - Nonblocking open is disabled until NVIDIA fixes the nv_open_q CPU spin.
#   - NVIDIA modules stay out of initramfs until hibernate restore is reliable.
#   - NVIDIA's system-sleep services stay disabled because this SBIOS produces
#     ACPI D-notifier failures on suspend/resume.
#   - nvidia-powerd stays masked because this SBIOS does not expose NVPCF.
#
# Fine runtime PM (0x02) remains the preferred policy because it preserves
# D3cold. When the remaining bugs are fixed, remove the other temporary overrides
# and initramfs exclusion, retest the official sleep services, and unmask powerd
# only if the BIOS exposes NVPCF.
#
# Run with: sudo ./setup.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must run as root: sudo ./setup.sh" >&2
    exit 1
fi
if [[ -z ${SUDO_USER:-} || $SUDO_USER == root ]]; then
    echo "Run this script from the desktop account with sudo ./setup.sh." >&2
    exit 1
fi

. /etc/os-release
if [[ ${ID:-} != ubuntu ]]; then
    echo "This setup supports Ubuntu only (found ${ID:-unknown})." >&2
    exit 1
fi

REAL_USER=$SUDO_USER
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6 || true)
if [[ -z $REAL_HOME ]]; then
    echo "Cannot resolve the home directory for $REAL_USER." >&2
    exit 1
fi

status() {
    printf '[%s] %s\n' "$1" "$2"
}

disable_unit_if_present() {
    local load_state
    load_state=$(systemctl show --property=LoadState --value "$1")
    case "$load_state" in
        loaded) systemctl disable --now "$1" ;;
        masked) systemctl stop "$1" ;;
        not-found) ;;
        *)
            echo "Cannot determine the state of $1 (LoadState=$load_state)." >&2
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Driver bootstrap
# ------------------------------------------------------------------------------
# A fresh install needs NVIDIA's CUDA repository because Blackwell requires the
# open kernel modules. This script deliberately does not purge broad nvidia-*
# package patterns. A fresh machine has nothing to purge, and a failed reinstall
# after a purge can leave the machine without a usable driver.
install_driver() {
    local repo="ubuntu${VERSION_ID//./}"
    local keyring
    case "$repo" in
        ubuntu2404|ubuntu2604) ;;
        *)
            echo "No CUDA repository configured for Ubuntu ${VERSION_ID}." >&2
            exit 1
            ;;
    esac

    status driver "Adding NVIDIA CUDA repository for $repo"
    apt-get update
    apt-get install -y ca-certificates wget
    keyring=$(mktemp /tmp/cuda-keyring.XXXXXX.deb)
    trap "rm -f -- '$keyring'" EXIT
    wget -q "https://developer.download.nvidia.com/compute/cuda/repos/$repo/x86_64/cuda-keyring_1.1-1_all.deb" \
        -O "$keyring"
    dpkg -i "$keyring"
    rm -f "$keyring"
    trap - EXIT
    apt-get update
    apt-get install -y nvidia-open
}

DRIVER_VERSION=$(modinfo -F version nvidia 2>/dev/null || true)
DRIVER_LICENSE=$(modinfo -F license nvidia 2>/dev/null || true)
if ! command -v nvidia-smi >/dev/null 2>&1; then
    if [[ -n $DRIVER_VERSION && $DRIVER_LICENSE != "Dual MIT/GPL" ]]; then
        echo "An unknown NVIDIA kernel module is already installed." >&2
        echo "Refusing to replace it automatically." >&2
        exit 1
    fi
    install_driver
fi

DRIVER_VERSION=
for module in nvidia nvidia_uvm; do
    MODULE_VERSION=$(modinfo -F version "$module" 2>/dev/null || true)
    MODULE_LICENSE=$(modinfo -F license "$module" 2>/dev/null || true)
    if [[ -z $MODULE_VERSION || $MODULE_LICENSE != "Dual MIT/GPL" ]]; then
        echo "Open NVIDIA module $module is not installed for this kernel." >&2
        exit 1
    fi
    if [[ $module == nvidia ]]; then
        DRIVER_VERSION=$MODULE_VERSION
    elif [[ $MODULE_VERSION != "$DRIVER_VERSION" ]]; then
        echo "NVIDIA module versions do not match." >&2
        exit 1
    fi
done
status driver "NVIDIA open driver $DRIVER_VERSION installed"

# Select the same PCI class used by the runtime-PM rule below. Reading sysfs
# avoids depending on pciutils and keeps discovery aligned with the policy.
GPU_PCI=
for device in /sys/bus/pci/devices/*; do
    [[ -r $device/vendor && -r $device/class ]] || continue
    if [[ $(<"$device/vendor") == 0x10de && $(<"$device/class") == 0x030200 ]]; then
        GPU_PCI=${device##*/}
        break
    fi
done
if [[ -z $GPU_PCI ]]; then
    echo "No NVIDIA 3D controller found." >&2
    exit 1
fi
status hardware "NVIDIA GPU at $GPU_PCI"

# ------------------------------------------------------------------------------
# Desktop policy: Intel renders; block automatic NVIDIA graphics discovery
# ------------------------------------------------------------------------------
# Chrome rendered through Intel but still auto-selected NVIDIA through Vulkan;
# that wake triggered the 2026-07-13 GC6-resume GSP crash. Chrome also loaded the
# NVIDIA EGL vendor while using Intel. Disable both manifests system-wide. This
# removes NVIDIA EGL/Vulkan graphics but leaves normal CUDA access unchanged.
#
# dpkg-divert makes the exclusions survive libnvidia-gl upgrades. The disabled
# filenames do not end in .json, so EGL and Vulkan loaders do not discover them.
# We previously tried __EGL_VENDOR_LIBRARY_FILENAMES instead. Do not restore it
# in /etc/environment: its host path is invalid inside confined snap namespaces.
divert_nvidia_probe() {
    local source=$1
    local target=$2
    local legacy_target=${3:-}
    local truename

    truename=$(dpkg-divert --truename "$source")
    if [[ -n $legacy_target && $truename == "$legacy_target" ]]; then
        if [[ -e $source || -e $target ]]; then
            echo "Cannot migrate diversion for $source: destination conflict." >&2
            exit 1
        fi
        dpkg-divert --local --remove --rename \
            --divert "$legacy_target" "$source"
        truename=$source
    fi

    if [[ $truename == "$source" ]]; then
        if [[ -e $target ]]; then
            echo "Cannot divert $source: $target already exists." >&2
            exit 1
        fi
        dpkg-divert --local --add --rename --divert "$target" "$source"
    elif [[ $truename != "$target" ]]; then
        echo "$source is diverted to unexpected target $truename." >&2
        exit 1
    fi

    if [[ -e $source ]]; then
        echo "$source remains discoverable after diversion." >&2
        exit 1
    fi
}

EGL_SOURCE=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
EGL_DISABLED=${EGL_SOURCE}.disabled
EGL_LEGACY=/usr/share/glvnd/egl_vendor.d/90_nvidia.json
divert_nvidia_probe "$EGL_SOURCE" "$EGL_DISABLED" "$EGL_LEGACY"
status desktop "NVIDIA excluded from automatic EGL discovery"

VULKAN_SOURCE=/usr/share/vulkan/icd.d/nvidia_icd.json
VULKAN_DISABLED=${VULKAN_SOURCE}.disabled
divert_nvidia_probe "$VULKAN_SOURCE" "$VULKAN_DISABLED"
status desktop "NVIDIA excluded from automatic Vulkan discovery"

# GDM's GNOME session scans GStreamer plugins before login. Both libgstnvcodec
# and libgsthip load libgstcuda and call NVIDIA's CUDA driver while registering.
# On 2026-07-14 each became the first NVIDIA client on consecutive boots and
# blocked in RmInitAdapter/kgspInitRm. Disable both plugins; Intel, software, and
# non-GStreamer CUDA paths stay available. These diversions survive upgrades of
# gstreamer1.0-plugins-bad.
for plugin in libgstnvcodec.so libgsthip.so; do
    source=/usr/lib/x86_64-linux-gnu/gstreamer-1.0/$plugin
    divert_nvidia_probe "$source" "${source}.disabled"
done
status desktop "NVIDIA excluded from automatic GStreamer codec/HIP probing"

# GLX/PRIME: select Mesa for login paths, including Chrome PWAs. We tried
# patching Chrome desktop files directly; package upgrades replaced the patches,
# and alternate PWA launchers bypassed them. These defaults control rendering;
# they do not stop Chrome from probing NVIDIA through another vendor API.
if ! grep -q '^# RTX laptop desktop policy$' /etc/environment 2>/dev/null; then
    cat >> /etc/environment << 'EOF'

# RTX laptop desktop policy
EOF
fi
for setting in '__NV_PRIME_RENDER_OFFLOAD=0' '__GLX_VENDOR_LIBRARY_NAME=mesa'; do
    key=${setting%%=*}
    if grep -q "^${key}=" /etc/environment 2>/dev/null; then
        sed -i "s|^${key}=.*|${setting}|" /etc/environment
    else
        echo "$setting" >> /etc/environment
    fi
done
status desktop "Mesa selected for GLX and PRIME"

# DRM: modeset=0 was insufficient. nvidia_drm still loaded, created
# /dev/dri/card0, and let GNOME hold the dGPU open. This laptop has no connector
# wired to NVIDIA, and CUDA does not need nvidia_drm, so block the module.
cat > /etc/modprobe.d/nvidia-kms.conf << 'EOF'
# No display connector uses NVIDIA. Block DRM, but leave vendor nodes available.
blacklist nvidia_drm
install nvidia_drm /bin/false
EOF

# Neutralize a file created by older revisions of this script. The same-basename
# /etc/modprobe.d/nvidia-kms.conf above shadows Ubuntu's packaged file.
LEGACY_KMS=/etc/modprobe.d/nvidia-graphics-drivers-kms.conf
if [[ -f "$LEGACY_KMS" ]]; then
    sed -i 's/^options nvidia-drm/# options nvidia-drm/' "$LEGACY_KMS"
fi
status desktop "nvidia_drm blocked; nvidia and nvidia_uvm remain unblocked"

# nvidia-settings opens /dev/nvidia* at login and prevents D3cold. Normal desktop
# rendering does not require it, so disable its autostart for the invoking user.
AUTOSTART_DIR="$REAL_HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/nvidia-settings-autostart.desktop"
runuser -u "$REAL_USER" -- mkdir -p "$AUTOSTART_DIR"
runuser -u "$REAL_USER" -- tee "$AUTOSTART_FILE" >/dev/null << 'EOF'
[Desktop Entry]
Type=Application
Hidden=true
EOF
status desktop "nvidia-settings autostart disabled for $REAL_USER"

# ------------------------------------------------------------------------------
# Runtime power policy
# ------------------------------------------------------------------------------
# NVIDIA's package supplies S0ix, video-memory preservation, /var/tmp storage,
# and nouveau/nova blacklists in /usr/lib/modprobe.d/nvidia-graphics-drivers.conf.
# Remove the obsolete local shadow so package updates remain authoritative.
rm -f /etc/modprobe.d/nvidia-graphics-drivers.conf
status power "packaged NVIDIA power-management policy retained"

# Allow ordinary users to collect NVIDIA profiling metrics. This is intentional
# for local CUDA development; remove the file to restore admin-only profiling.
cat > /etc/modprobe.d/nvidia-profiling.conf << 'EOF'
options nvidia NVreg_RestrictProfilingToAdminUsers=0
EOF
status driver "NVIDIA profiling allowed for ordinary users"

# Nonblocking open has caused nv_open_q to spin at high CPU on this driver. This
# option is temporary; remove it after NVIDIA fixes the open-path bug.
# https://github.com/NVIDIA/open-gpu-kernel-modules/discussions/615
cat > /etc/modprobe.d/nvidia-local.conf << 'EOF'
# Temporary nv_open_q spin workaround.
options nvidia NVreg_EnableNonblockingOpen=0
EOF
status power "nonblocking NVIDIA open disabled"

# NVIDIA packages select fine-grained runtime PM (0x02) in
# /usr/lib/modprobe.d/nvidia-runtimepm.conf. Fine mode is the desired policy: an
# idle GPU can enter D3cold even while a long-lived CUDA client remains open.
#
# Observed with 0x02: driver 610.43.02 eventually produced Xid 120/154/79 when
# its GSP failed a GC6->D0 resume. UNLOADING_GUEST_DRIVER appeared in the crash
# RPC history immediately before the GSP panic.
#
# Rejected trial: coarse mode (0x01) loaded on 2026-07-13. On its first boot,
# the first NVIDIA client deadlocked in RmInitAdapter/kgspInitRm. The leaked RM
# write lock then blocked GStreamer, Chrome, CUDA clients, and nvidia-smi in
# uninterruptible sleep. Coarse mode therefore is not a viable mitigation.
#
# Restore the pre-experiment fine policy (0x02). A proposed 0x00 diagnostic was
# not boot-tested: it would discard D3cold without fixing the underlying driver.
# Shadow the packaged file explicitly so setup.sh records the active now-state.
cat > /etc/modprobe.d/nvidia-runtimepm.conf << 'EOF'
# Fine runtime PM preserves D3cold. Do not retry coarse mode (0x01): it wedged.
options nvidia NVreg_DynamicPowerManagement=0x02
EOF
status power "fine runtime PM enabled (0x02) for D3cold"

# Keep PCI runtime PM enabled for D3cold. The rule reapplies power/control=auto
# whenever the NVIDIA function is added or rebound; TLP must not override it.
cat > /etc/udev/rules.d/80-nvidia-pm.rules << 'EOF'
# NVIDIA vendor 10de, class 030200 (3D controller).
ACTION=="add|change|bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", ATTR{power/control}="auto"
EOF
status power "PCI runtime PM allowed for the NVIDIA GPU"

if [[ -f /etc/tlp.conf ]]; then
    sed -i -E '/^[[:space:]#]*RUNTIME_PM_ON_AC=/d' /etc/tlp.conf
    echo 'RUNTIME_PM_ON_AC="auto"' >> /etc/tlp.conf
    status power "TLP permits runtime PM on AC"
else
    status power "TLP not installed; no TLP override needed"
fi

# ------------------------------------------------------------------------------
# Services and sleep hooks
# ------------------------------------------------------------------------------
# Older revisions added two custom services:
#   - nvidia-wake forced power/control=on before sleep and shutdown.
#   - nvidia-power-control restored auto at boot and after resume.
# They added transitions through the same failing firmware path. The udev rule
# already establishes the desired runtime-PM default, so remove both services.
disable_unit_if_present nvidia-wake.service
disable_unit_if_present nvidia-power-control.service
rm -f /etc/systemd/system/nvidia-wake.service
rm -f /etc/systemd/system/nvidia-power-control.service
rm -f /etc/systemd/system/nvidia-resume.service.d/restore-pm.conf
rmdir /etc/systemd/system/nvidia-resume.service.d 2>/dev/null || true
systemctl daemon-reload
status services "obsolete custom wake/runtime-PM services removed"

# Persistence keeps the NVIDIA driver initialized between clients and prevents
# D3cold. We prefer a cold-start delay on the first CUDA call over constant draw.
disable_unit_if_present nvidia-persistenced.service
status services "nvidia-persistenced disabled"

# Dynamic Boost requires the SBIOS NVPCF interface. This LG firmware does not
# expose it and asks the daemon to disable Dynamic Boost. Leaving powerd active
# only holds the GPU open and repeats PRH thermal-limit errors. Masking, rather
# than disabling, survives NVIDIA package presets.
#
# Preferred post-fix state: unmask powerd if a BIOS update exposes NVPCF; that
# would restore dynamic CPU/GPU power-budget sharing while the GPU is active.
systemctl mask --now nvidia-powerd
status services "nvidia-powerd masked until SBIOS provides NVPCF"

# NVIDIA's official sleep services touched the same ACPI path that logged
# D-notifier failures on this laptop. The dGPU drives no display and its modules
# are excluded from the initramfs below, so disable the services for now.
#
# Preferred post-fix state: re-enable these services after NVIDIA/LG fixes the
# suspend path, then retest s2idle and hibernate before keeping them enabled.
for unit in nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service; do
    disable_unit_if_present "$unit"
done
status services "NVIDIA suspend/hibernate/resume services disabled"

# ------------------------------------------------------------------------------
# Initramfs policy
# ------------------------------------------------------------------------------
# Loading NVIDIA before hibernate restore made the kernel freeze a newly loaded,
# incompletely initialized driver and fail with nv_pmops_freeze -5. Exclude the
# NVIDIA modules so they load after restore. Add i915 early so Intel can display
# the LUKS prompt.
#
# Preferred post-fix state: remove the NVIDIA exclusion once hibernate restore
# works with the packaged initramfs policy. Early i915 remains useful.
#
# Detect the installed implementation by package ownership, not command names.
# Ubuntu's dracut package provides an update-initramfs compatibility wrapper, so
# the presence of /usr/sbin/update-initramfs does not imply initramfs-tools.
if [[ $(dpkg-query -W -f='${db:Status-Abbrev}' dracut-core 2>/dev/null || true) == ii* ]]; then
    INITRAMFS_BACKEND=dracut
elif [[ $(dpkg-query -W -f='${db:Status-Abbrev}' initramfs-tools 2>/dev/null || true) == ii* ]]; then
    INITRAMFS_BACKEND=initramfs-tools
else
    echo "Neither dracut-core nor initramfs-tools is installed." >&2
    exit 1
fi
status initramfs "detected $INITRAMFS_BACKEND"

if [[ $INITRAMFS_BACKEND == dracut ]]; then
    mkdir -p /etc/dracut.conf.d
    echo 'omit_drivers+=" nvidia nvidia-drm nvidia-modeset nvidia-uvm "' \
        > /etc/dracut.conf.d/nvidia-exclude.conf
    echo 'add_drivers+=" i915 "' > /etc/dracut.conf.d/i915.conf
    status initramfs "configured dracut: exclude NVIDIA, add i915"
else
    mkdir -p /etc/initramfs-tools/hooks
    rm -f /etc/initramfs-tools/hooks/exclude-nvidia
    cat > /etc/initramfs-tools/hooks/zz-exclude-nvidia << 'HOOK'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0;; esac

# NVIDIA's package hook queues these for mkinitramfs's final module-copy pass.
# Remove both queued names and anything an earlier pass already copied.
if [ -n "${__MODULES_TO_ADD:-}" ] && [ -f "$__MODULES_TO_ADD" ]; then
    sed -i '\#\(^\|/\)nvidia[^/]*$#d' "$__MODULES_TO_ADD"
fi
if [ -n "${DESTDIR:-}" ]; then
    rm -f "${DESTDIR}"/lib/modules/*/kernel/drivers/video/nvidia* 2>/dev/null || true
    rm -f "${DESTDIR}"/lib/modules/*/updates/dkms/nvidia* 2>/dev/null || true
    rm -f "${DESTDIR}"/lib/modules/*/kernel/drivers/gpu/nvidia* 2>/dev/null || true
fi
HOOK
    chmod +x /etc/initramfs-tools/hooks/zz-exclude-nvidia
    grep -qxF i915 /etc/initramfs-tools/modules 2>/dev/null || \
        echo i915 >> /etc/initramfs-tools/modules
    status initramfs "configured initramfs-tools: exclude NVIDIA, add i915"
fi

status initramfs "rebuilding with $INITRAMFS_BACKEND"
# On dracut-based Ubuntu, update-initramfs is a dracut-owned compatibility
# wrapper. Rebuild every existing image so fallback kernels use the same policy.
update-initramfs -u -k all

# ------------------------------------------------------------------------------
# Post-reboot checks
# ------------------------------------------------------------------------------
cat << EOF

Setup complete. Reboot before evaluating the policy.

After reboot, verify:
  grep DynamicPowerManagement /proc/driver/nvidia/params
      expected: DynamicPowerManagement: 2

  lsmod | grep '^nvidia_drm'
      expected: no output

  cat /sys/bus/pci/devices/${GPU_PCI}/power/control
      expected: auto

  cat /sys/bus/pci/devices/${GPU_PCI}/power/runtime_status
      expected when no NVIDIA client is open: suspended

  systemctl is-enabled nvidia-powerd nvidia-persistenced \
      nvidia-suspend nvidia-hibernate nvidia-resume
      expected: masked, disabled, disabled, disabled, disabled

Future rollback after driver/firmware fixes:
  sudo dpkg-divert --local --remove --rename \
      --divert /usr/share/glvnd/egl_vendor.d/10_nvidia.json.disabled \
      /usr/share/glvnd/egl_vendor.d/10_nvidia.json
      restores NVIDIA EGL discovery
  sudo dpkg-divert --local --remove --rename \
      --divert /usr/share/vulkan/icd.d/nvidia_icd.json.disabled \
      /usr/share/vulkan/icd.d/nvidia_icd.json
      restores NVIDIA Vulkan discovery
  sudo dpkg-divert --local --remove --rename \
      --divert /usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstnvcodec.so.disabled \
      /usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstnvcodec.so
  sudo dpkg-divert --local --remove --rename \
      --divert /usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgsthip.so.disabled \
      /usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgsthip.so
      restores NVIDIA/HIP acceleration inside GStreamer
  sudo rm /etc/modprobe.d/nvidia-runtimepm.conf
      delegates fine-grained runtime PM (0x02) to the packaged configuration
  sudo rm /etc/modprobe.d/nvidia-local.conf
      restores the packaged nonblocking-open behavior
  sudo rm /etc/dracut.conf.d/nvidia-exclude.conf
      or: sudo rm /etc/initramfs-tools/hooks/zz-exclude-nvidia
  sudo update-initramfs -u -k all
      rebuilds every existing image after removing the exclusion
  sudo systemctl unmask nvidia-powerd
  sudo systemctl enable --now nvidia-powerd
      only after SBIOS exposes NVPCF
  sudo systemctl enable nvidia-suspend nvidia-hibernate nvidia-resume
      only after suspend and hibernate pass repeated testing
EOF
