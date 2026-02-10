#!/bin/bash
# reset-gpu.sh — Unload and reload NVIDIA kernel modules to reset the GPU.
#
# Standard procedure (what everyone does) [1][2]:
#   1. Stop nvidia services (persistenced, fabricmanager)
#   2. Kill GPU compute processes
#   3. Disable persistence mode (nvidia-smi -pm 0)
#   4. Unload modules (modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia)
#   5. Reload modules (modprobe nvidia nvidia_modeset nvidia_drm nvidia_uvm)
#   6. [1] also does nvidia-smi -r (GPU reset), but that only works on
#      datacenter GPUs (Tesla, A100, etc.), not consumer cards.
#
# The hard part — nvidia_drm refcount:
#   modprobe -r fails if anything holds a reference to nvidia_drm. On headless
#   systems, killing compute processes and /dev/nvidia* users is sufficient.
#   On desktops, the display server must be stopped [3]. There is no way
#   around this — even on hybrid GPU (Intel+NVIDIA) where the compositor
#   renders on Intel, it still opens the NVIDIA DRM node and holds the ref.
#   [3] demonstrates this with dual-NVIDIA; the same applies to Intel+NVIDIA.
#
# What we do differently:
#   - Detect compositor on NVIDIA DRM nodes via fuser (not just nvidia-smi
#     compute apps). This catches hybrid GPU setups where the compositor holds
#     a DRM fd but doesn't appear in nvidia-smi's compute process list.
#   - Re-exec under systemd-run before stopping the display manager, so the
#     script survives its own session teardown [4]. The cleanup trap restarts
#     the DM on exit.
#   - Skip nvidia-smi -r since it only works on datacenter GPUs.
#
# Simplest possible version (what we'd do without corner case handling):
#
#   nvidia-smi -pm 0
#   fuser -k /dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-uvm
#   systemctl stop gdm3  # if running
#   modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia
#   modprobe nvidia nvidia_modeset nvidia_drm nvidia_uvm
#   systemctl start gdm3
#
# What this script adds beyond that:
#   - Detect whether a DM stop is actually needed (headless needs none)
#   - Re-exec under systemd-run so the script survives its own session teardown
#   - Stop/restart nvidia services (persistenced, fabricmanager, dcgm)
#   - Kill compute processes individually rather than blindly
#   - Partial unload recovery (re-loads modules if unload fails halfway)
#   - Skip DM restart if driver reload failed (avoids login loop)
#
# [1] https://docs.northerndata.eu/docs/how-to-reset-gpus-on-a-running-instance
# [2] https://forums.developer.nvidia.com/t/reset-driver-without-rebooting-on-linux/40625
# [3] https://forums.developer.nvidia.com/t/reset-dedicated-gpu-after-it-gets-stuck/208589
#     (dual-NVIDIA; display server held ref to CUDA GPU despite not rendering on it)
# [4] systemd-run(1) — run as a transient service to outlive the calling session
set -e

# Re-exec with sudo if not root
if [ "$EUID" -ne 0 ]; then
    echo "Re-executing with sudo..."
    exec sudo "$0" "$@"
fi

TS="${TS:-$(date +%s)}"
LOG="/tmp/gpu-reset-${TS}.log"

exec > >(tee -a "$LOG") 2>&1
echo "Logging to $LOG"

STOPPED_SERVICES=()

stop_service() {
    systemctl is-active --quiet "$1" || return 0
    echo "Stopping $1"
    systemctl stop "$1"
    STOPPED_SERVICES+=("$1")
}

cleanup() {
    # Don't restart DM if driver isn't loaded — avoids login loop
    if [ -n "$DM" ] && ! (lsmod | grep -q "^nvidia "); then
        echo "WARNING: NVIDIA driver not loaded, skipping DM restart to avoid login loop"
        echo "Run 'modprobe nvidia && systemctl start $DM' manually after fixing."
        # Still restart non-DM services
        for ((i=${#STOPPED_SERVICES[@]}-1; i>=0; i--)); do
            svc="${STOPPED_SERVICES[i]}"
            [ "$svc" = "$DM" ] && continue
            echo "Starting $svc"
            systemctl start "$svc" || echo "WARNING: Failed to start $svc"
        done
        return
    fi
    # Reverse order to respect dependencies
    for ((i=${#STOPPED_SERVICES[@]}-1; i>=0; i--)); do
        svc="${STOPPED_SERVICES[i]}"
        echo "Starting $svc"
        systemctl start "$svc" || echo "WARNING: Failed to start $svc"
    done
}
trap cleanup EXIT

# Detect if DM stop will be needed (before stopping any services)
if [ -z "$DM" ]; then
    if PIDS=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null); then
        echo "Checking GPU processes"
        for pid in $PIDS; do
            PROC=$(ps -p "$pid" -o comm= 2>/dev/null || echo "")
            if [[ "$PROC" =~ ^(Xorg|X|gnome-shell|kwin|mutter|composit|weston|sway|hyprland|picom).*$ ]]; then
                echo "Display server PID $pid ($PROC) using GPU"
                DM=$(systemctl list-units --type=service --state=running |
                    grep -oP '(gdm3?|lightdm|sddm|xdm)\.service' |
                    head -1 || echo "")
                break
            fi
        done
    else
        echo "nvidia-smi failed - assuming DM not using GPU"
    fi

    # Also check DRM holders of NVIDIA cards (compositor on hybrid GPU)
    if [ -z "$DM" ]; then
        for card in /sys/class/drm/card[0-9]*; do
            # Skip connector entries like card0-DP-1
            [[ "$(basename "$card")" =~ ^card[0-9]+$ ]] || continue
            driver=$(readlink "$card/device/driver" 2>/dev/null | xargs basename 2>/dev/null)
            [ "$driver" = "nvidia" ] || continue
            carddev="/dev/dri/$(basename "$card")"
            for pid in $(fuser "$carddev" 2>/dev/null | grep -oE '[0-9]+'); do
                PROC=$(ps -p "$pid" -o comm= 2>/dev/null || echo "")
                if [[ "$PROC" =~ ^(Xorg|X|gnome-shell|kwin|mutter|composit|weston|sway|hyprland|picom).*$ ]]; then
                    echo "Display server PID $pid ($PROC) holding GPU DRM: $carddev"
                    DM=$(systemctl list-units --type=service --state=running |
                        grep -oP '(gdm3?|lightdm|sddm|xdm)\.service' |
                        head -1 || echo "")
                    break 2
                fi
            done
        done
    fi
fi

# Re-exec via systemd if we'll stop DM (to survive session termination)
if [ -n "$DM" ] && [ -z "$INVOCATION_ID" ]; then
    SCRIPT=$(readlink -f "$0")
    exec systemd-run --no-ask-password --unit="gpu-reset-${TS}" --service-type=oneshot \
        --setenv=SUDO_USER="$SUDO_USER" \
        --setenv=TS="$TS" \
        --setenv=DM="$DM" \
        "$SCRIPT" "$@"
fi

# Now safe to stop services - we're either in systemd or don't need DM stop
stop_service nvidia-persistenced
stop_service nvidia-fabricmanager
stop_service dcgm

# Kill compute processes
if PIDS=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null); then
    for pid in $PIDS; do
        PROC=$(ps -p "$pid" -o comm= 2>/dev/null || echo "")
        if [[ ! "$PROC" =~ ^(Xorg|X|gnome-shell|kwin|mutter|composit|weston|sway|hyprland|picom).*$ ]]; then
            echo "Killing compute process PID $pid ($PROC)"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
fi

# Disable persistence mode so driver can unload
nvidia-smi -pm 0 2>/dev/null || true

# Kill any remaining GPU processes
pkill -9 -f "watch.*nvidia-smi" 2>/dev/null || true
fuser -k /dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools 2>/dev/null || true

if [ -n "$DM" ]; then
    stop_service "$DM"
    sleep 2
fi

echo "Unloading NVIDIA drivers"
sleep 1
# Unload each module individually so a partial failure doesn't leave a broken stack
NVIDIA_MODULES=(nvidia_uvm nvidia_drm nvidia_modeset nvidia)
UNLOADED_MODULES=()
unload_failed=false
for mod in "${NVIDIA_MODULES[@]}"; do
    if lsmod | grep -q "^${mod} "; then
        if ! modprobe -r "$mod" 2>/dev/null; then
            echo "WARNING: Failed to unload $mod, retrying..."
            sleep 2
            if ! modprobe -r "$mod"; then
                echo "FATAL: Cannot unload $mod"
                unload_failed=true
                break
            fi
        fi
        UNLOADED_MODULES+=("$mod")
    fi
done

# If partial unload, reload what we removed to restore a consistent state
if $unload_failed; then
    echo "Restoring partially unloaded modules..."
    for ((i=${#UNLOADED_MODULES[@]}-1; i>=0; i--)); do
        modprobe "${UNLOADED_MODULES[i]}" 2>/dev/null || true
    done
    echo "FATAL: GPU reset failed — could not unload all modules"
    exit 1
fi

echo "Reloading NVIDIA drivers"
modprobe nvidia
modprobe nvidia_modeset
modprobe nvidia_drm
modprobe nvidia_uvm

if false; then
    TEST_GPU="${1:-0}"
    echo "Testing GPU $TEST_GPU with PyTorch"
    sudo -u "$SUDO_USER" /home/"$SUDO_USER"/.local/bin/uv \
        --quiet --project /home/"$SUDO_USER"/research run --no-sync \
        python3 <<PYEOF
import torch
torch.cuda.set_device($TEST_GPU)
x = torch.rand([1000, 1000], device='cuda')
print('GPU works!')
PYEOF
fi

echo "GPU Status"
nvidia-smi \
    --query-gpu=index,power.draw,utilization.gpu,fan.speed,pstate \
    --format=csv

# Services restarted by EXIT trap
