# RTX Laptop Linux Power Management

Get proper battery life on Linux laptops with NVIDIA RTX GPUs.

**TL;DR:** By default, NVIDIA GPUs stay awake and drain ~6W constantly. This
guide enables D3cold power states so the GPU sleeps when idle, **doubling
battery life** on hybrid graphics laptops (tested: 20W → 10W idle).

## The Problem

Linux hybrid graphics laptops with NVIDIA RTX GPUs have terrible battery life
out of the box. The GPU never enters deep sleep (D3cold) because:

1. **GNOME Shell uses NVIDIA for EGL rendering** - libglvnd loads
   `10_nvidia.json` before `50_mesa.json`, so the desktop compositor keeps the
   GPU awake permanently.

2. **The NVIDIA driver has bugs** - Sleep/shutdown hangs, CPU spin bugs, and
   missing power management features require workarounds.

3. **System services keep the GPU awake** - `nvidia-persistenced`,
   `nvidia-settings`, and even Chrome probe the GPU at startup.

4. **TLP fights against you** - Default `RUNTIME_PM_ON_AC=on` forces all
   devices to stay awake on AC power.

## Quick Start

```bash
git clone https://github.com/jvdillon/rtx-laptop-linux.git
cd rtx-laptop-linux
sudo ./setup.sh
# Reboot required
```

The script will:
1. Install NVIDIA drivers (or prompt to reinstall if present)
2. Apply all power management fixes
3. Configure systemd services for proper sleep/wake handling

## What the Setup Does

### 1. Demote NVIDIA EGL Priority

libglvnd loads EGL vendors by filename order. Renaming `10_nvidia.json` to
`90_nvidia.json` ensures Mesa (Intel/AMD integrated) loads first.

```bash
sudo mv /usr/share/glvnd/egl_vendor.d/{10,90}_nvidia.json
```

### 2. Force Mesa EGL System-Wide

Even with the priority fix, some apps probe NVIDIA. This environment variable
forces Mesa for all desktop rendering:

```bash
# /etc/environment
__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
```

### 3. Disable NVIDIA DRM Modesetting

With `modeset=1`, nvidia_drm takes over the display, preventing Intel from
driving the panel. This also causes Plymouth hangs during boot.

```bash
sudo sed -i 's/modeset=1/modeset=0/' /etc/modprobe.d/nvidia-graphics-drivers-kms.conf
```

### 4. Fix nv_open_q CPU Spin Bug

Driver bug: the `nv_open_q` kernel thread spins at 20-70% CPU when nonblocking
open is enabled (default).

```bash
# /etc/modprobe.d/nvidia-graphics-drivers.conf
options nvidia NVreg_EnableNonblockingOpen=0
```

Reference: https://github.com/NVIDIA/open-gpu-kernel-modules/discussions/615

### 5. Enable Runtime PM via udev

The GPU needs `power/control=auto` to enter D3cold. This udev rule sets it for
all NVIDIA 3D controllers:

```bash
# /etc/udev/rules.d/80-nvidia-pm.rules
ACTION=="add|change|bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", ATTR{power/control}="auto"
```

### 6. Wake GPU Before Shutdown/Sleep

Driver bug: when the GPU is in D3cold, the driver can't cleanly unload or
prepare for system sleep. This causes hangs after "Reached target Reboot" or
sleep failures with error -5.

A systemd service wakes the GPU before any shutdown/sleep target:

```ini
# /etc/systemd/system/nvidia-wake.service
[Unit]
Description=Wake NVIDIA GPU before shutdown/sleep to prevent hangs
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target suspend.target hibernate.target hybrid-sleep.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo on > /sys/bus/pci/devices/0000:01:00.0/power/control; sleep 1'

[Install]
WantedBy=halt.target reboot.target shutdown.target suspend.target hibernate.target hybrid-sleep.target
```

### 7. Fix Hibernate Resume

Driver bug: when nvidia modules are in initramfs, they load BEFORE hibernate
resume. The kernel then tries to freeze a freshly-loaded driver that was never
properly initialized, causing `pci_pm_freeze(): nv_pmops_freeze returns -5`.

Fix: exclude nvidia from initramfs so modules load AFTER hibernate resume.

**Ubuntu 25.04+ (dracut):**
```bash
# /etc/dracut.conf.d/nvidia-exclude.conf
omit_drivers+=" nvidia nvidia-drm nvidia-modeset nvidia-uvm "
```

**Ubuntu 24.04 LTS (initramfs-tools):**
```bash
# /etc/initramfs-tools/hooks/exclude-nvidia
# Hook script that removes nvidia modules from initramfs
```

Also adds early i915 KMS for external display during LUKS decrypt.

References:
- https://bbs.archlinux.org/viewtopic.php?id=285508
- https://forums.developer.nvidia.com/t/preservevideomemoryallocations-systemd-services-causes-resume-from-hibernate-to-fail/233643

### 8. Restore Runtime PM After Boot/Resume

The nvidia driver sets `power/control=on` when it initializes, and our wake
service sets it before sleep. Both prevent D3cold after boot/resume.

Two systemd units restore `power/control=auto`:

```ini
# /etc/systemd/system/nvidia-power-control.service (after boot)
[Unit]
Description=Enable NVIDIA GPU runtime power management
After=multi-user.target tlp.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo auto > /sys/bus/pci/devices/0000:01:00.0/power/control'

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/nvidia-resume.service.d/restore-pm.conf (after resume)
[Service]
ExecStartPost=/bin/bash -c 'echo auto > /sys/bus/pci/devices/0000:01:00.0/power/control'
```

### 9. Disable nvidia-persistenced

This service keeps the driver loaded even when the GPU is unused, preventing
D3cold. Disabling it enables on-demand loading.

Trade-off: first CUDA call has ~1s latency while the driver loads.

```bash
sudo systemctl disable nvidia-persistenced
```

### 10. Disable nvidia-settings Autostart

`nvidia-settings` spawns at login and keeps `/dev/nvidia*` open, preventing
D3cold.

```bash
# ~/.config/autostart/nvidia-settings-autostart.desktop
[Desktop Entry]
Type=Application
Hidden=true
```

### 11. Prevent Chrome from Waking GPU

Chrome probes `/dev/nvidiactl` at startup even when not using GPU acceleration.
Force it to use Mesa:

```bash
sudo sed -i 's|^Exec=/usr/bin/google-chrome-stable|Exec=env __NV_PRIME_RENDER_OFFLOAD=0 __GLX_VENDOR_LIBRARY_NAME=mesa /usr/bin/google-chrome-stable|' \
    /usr/share/applications/google-chrome.desktop
```

### 12. Configure TLP (if installed)

TLP defaults to `RUNTIME_PM_ON_AC=on` which forces all devices awake on AC
power:

```bash
sudo sed -i '/^#*RUNTIME_PM_ON_AC/d; $ a RUNTIME_PM_ON_AC="auto"' /etc/tlp.conf
```

## Verification

After rebooting, verify the GPU enters D3cold when idle:

```bash
# Should show "suspended" when GPU is idle
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status

# nv_open_q should be ~0% CPU (or not running)
ps aux | grep '\[nv_open_q\]'

# Power draw should be 8-12W idle (without heavy apps)
cat /sys/class/power_supply/BAT*/power_now | awk '{print $1/1000000 " W"}'
```

To wake the GPU for CUDA work:
```bash
nvidia-smi  # GPU wakes on-demand
```

## Troubleshooting

### GPU won't enter suspended state

Check what's keeping it awake:
```bash
# List processes using nvidia devices
sudo fuser -v /dev/nvidia*

# Check if any GL apps are running
lsof /dev/dri/card*
```

Common culprits: Discord, Slack, VS Code (Electron apps), OBS.

### System hangs on shutdown/reboot

The wake service may not be running:
```bash
sudo systemctl status nvidia-wake.service
sudo systemctl enable nvidia-wake.service
```

### Hibernate resume fails

Check if nvidia modules are in initramfs:
```bash
lsinitramfs /boot/initrd.img-$(uname -r) | grep nvidia
```

If they appear, the dracut config didn't take effect:
```bash
sudo update-initramfs -u
```

### Screen corruption after resume

Try adding to kernel command line:
```
nvidia.NVreg_PreserveVideoMemoryAllocations=1
```

### Hybrid-sleep doesn't work

Known NVIDIA driver bug (`nv_restore_user_channels` fails). Use suspend or
hibernate instead - hybrid-sleep is fundamentally broken with these drivers.

## Finding Your GPU PCI Address

The scripts assume `0000:01:00.0`. Find yours with:

```bash
lspci | grep -i nvidia
# Example output: 01:00.0 3D controller: NVIDIA Corporation...
```

If different, update the PCI address in:
- `/etc/systemd/system/nvidia-wake.service`
- `/etc/systemd/system/nvidia-power-control.service`
- `/etc/systemd/system/nvidia-resume.service.d/restore-pm.conf`

## Driver Installation (Ubuntu)

For reference, here's how to install the NVIDIA driver and CUDA toolkit on
Ubuntu 24.04+:

```bash
# Remove any existing nvidia packages
sudo apt purge -y '^nvidia-.*' '^libnvidia-.*' '^cuda-.*' '^libcuda-.*'
sudo apt autoremove -y

# Add NVIDIA CUDA repository
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update

# Install open driver + CUDA toolkit
sudo apt install -y nvidia-open cuda-toolkit

# Add CUDA to PATH (~/.bashrc)
export PATH="/usr/local/cuda/bin${PATH:+:${PATH}}"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
```

## Enabling Profiling

To use `nsys` and other NVIDIA profiling tools without root:

```bash
# Allow profiling for all users
echo "options nvidia NVreg_RestrictProfilingToAdminUsers=0" | \
    sudo tee /etc/modprobe.d/nvidia-profiling.conf
sudo update-initramfs -u

# Set perf_event_paranoid
echo "kernel.perf_event_paranoid=2" | sudo tee /etc/sysctl.d/99-perf.conf
sudo sysctl -p /etc/sysctl.d/99-perf.conf
```

## References

- [NVIDIA Dynamic Power Management](https://download.nvidia.com/XFree86/Linux-x86_64/560.35.03/README/dynamicpowermanagement.html)
- [Arch Wiki: NVIDIA Tips](https://wiki.archlinux.org/title/NVIDIA/Tips_and_tricks#Preserve_video_memory_after_suspend)
- [Kernel PCI Power Management](https://www.kernel.org/doc/Documentation/power/pci.txt)
- [nv_open_q CPU spin bug](https://github.com/NVIDIA/open-gpu-kernel-modules/discussions/615)

## Tested On

- LG Gram Pro 16" 2025 (RTX 5050 Mobile) - Ubuntu 25.10, 25.04
- Ubuntu 24.04 LTS supported (uses initramfs-tools instead of dracut)
- Should work on any hybrid graphics laptop with RTX 20-series or newer

## License

Apache 2.0
