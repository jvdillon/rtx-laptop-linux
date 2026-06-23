#!/bin/bash
# workaround-610-prh-nvpcf.sh — Silence NVIDIA PRH/NVPCF thermal spam by
# disabling nvidia-powerd (Dynamic Boost), which this laptop's SBIOS refuses.
#
# Problem:
#   On nvidia-open 610.43.02 (kernel 7.0), the journal fills with, every ~22s:
#     NVRM: GPU0 ... PlatformRequestHandler failed to get target temp from SBIOS
#         @ platform_request_handler_ctrl.c:2174
#     NVRM: GPU0 ... failed to get platform power mode from SBIOS
#         @ platform_request_handler_ctrl.c:2117
#     NVRM: GPU0 nvAssertFailedNoLog: Assertion failed:
#         PRH failed to update thermal limit! @ platform_request_handler.c:855
#   nvidia-smi reports `power.limit [N/A]` — the driver cannot read or set the
#   GPU power rail. nvidia-powerd's own log shows the decisive line:
#     nvidia-powerd: ERROR! Client (presumably SBIOS) has requested to disable
#                    Dynamic Boost DC controller
#
# Affected system:
#   LG gram 16Z90TR (RTX 5050 Mobile / Blackwell, GB207M)
#   BIOS: A3ZJ3390 (07/16/2025)
#   nvidia-open 610.43.02, kernel 7.0.0-22-generic
#
# Root cause:
#   nvidia-powerd is the Dynamic Boost daemon: while the GPU is ACTIVE it shifts
#   the shared CPU/GPU power budget in real time. It depends on the SBIOS exposing
#   the GPU power rail via the NVPCF ACPI interface. This laptop's SBIOS does not
#   expose NVPCF and actively requests Dynamic Boost be disabled. The daemon keeps
#   the device open and the driver keeps polling the dead thermal interface, which
#   is what logs the PRH assertions. This is an SBIOS gap, NOT a driver-flag gap:
#   the installed 610 module exposes no PlatformRequestHandler toggle
#   (`modinfo nvidia | grep -i platform` shows only DynamicPowerManagement and
#   RegisterPlatformDeviceDriver — neither disables PRH).
#
#   This is the benign remnant of the 595-era Xid 120 GSP panic (see
#   workaround-595-gsp-crash.sh): the PRH messages were a *symptom* listed there,
#   but 610 fixed the GSP crash itself. Current boots show zero Xid / zero GSP
#   CrashCat — only the cosmetic PRH spam survives.
#
# Why disabling nvidia-powerd is safe (all verified by measurement, not memory):
#   - D3cold / idle battery savings are driven by the kernel PCI runtime-PM core
#     (power/control=auto + NVreg_DynamicPowerManagement=2 from setup.sh), a
#     DIFFERENT subsystem from Dynamic Boost. Measured: 93% runtime-suspended
#     residency and ~11W idle rail draw WHILE powerd was already failing. Disabling
#     powerd removes one /dev/nvidia0 handle, which can only help D3cold.
#   - Suspend/resume is driven by nvidia-suspend/resume/hibernate +
#     NVreg_PreserveVideoMemoryAllocations — no dependency on powerd. Nothing in
#     systemd Requires/Wants/After nvidia-powerd except the boot target's preset.
#   - The only feature lost is Dynamic Boost, which (a) the SBIOS already refused,
#     and (b) is irrelevant to sustained ML compute, where the GPU wants its full
#     budget and there is no idle CPU budget to donate.
#
# Certainty:
#   The PRH spam is benign and the disable is safe — high confidence, measured.
#   The TRUE fix for Dynamic Boost is an LG BIOS update for the 16Z90TR that
#   exposes NVPCF. Until then the feature cannot work regardless of driver flags.
#   Do NOT downgrade to 590: 610 already eliminated the Xid 120 GSP panic that
#   plagued 595; 590 is strictly a regression here.
#
# References:
#   - Dynamic Boost depends on SBIOS-exposed NVPCF (Dell G15, NVPCF not exposed):
#     https://www.dell.com/community/en/conversations/linux-general/g15-5520-and-other-laptops-missing-acpi-support-for-advanced-optimus-on-linux-nvpcf-not-exposed/67f8ea6c0141bf65d7cc7fbb
#   - nvidia-powerd is the Dynamic Boost / power-balancing daemon; safe to disable
#     when the BIOS does not expose the rail:
#     https://discourse.ubuntu.com/t/questions-about-nvidia-powerd/63547
#   - "Client (presumably SBIOS) has requested to disable Dynamic Boost DC":
#     https://github.com/NVIDIA/open-gpu-kernel-modules/issues/966
#   - PlatformRequestHandler assertion is triggered by powerd/SBIOS, not hardware:
#     https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1059
#
# Run with: sudo ./workaround-610-prh-nvpcf.sh
# No reboot required. Idempotent.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo ./workaround-610-prh-nvpcf.sh)"
    exit 1
fi

GPU_PCI=$(lspci -D | grep -iE '(3d|vga)[^:]*controller.*nvidia|nvidia.*(3d|vga)' | head -1 | awk '{print $1}')
if [[ -z "${GPU_PCI}" ]]; then
    echo "Error: no NVIDIA GPU found"
    exit 1
fi
echo "NVIDIA GPU: ${GPU_PCI}"

if ! systemctl list-unit-files nvidia-powerd.service &>/dev/null; then
    echo "nvidia-powerd.service not present; nothing to do."
    exit 0
fi

prh_before=$(journalctl -k -b --no-pager 2>/dev/null | grep -c 'PRH failed' || true)
echo "PRH assertions this boot before change: ${prh_before}"

if systemctl is-enabled nvidia-powerd.service &>/dev/null || systemctl is-active nvidia-powerd.service &>/dev/null; then
    echo "Disabling and stopping nvidia-powerd (Dynamic Boost daemon)..."
    systemctl disable --now nvidia-powerd.service
else
    echo "nvidia-powerd already disabled and stopped (skipped)."
fi

echo ""
echo "=========================================="
echo "Done. nvidia-powerd is disabled. No reboot needed."
echo ""
echo "Verify (give the GPU a few seconds to re-suspend):"
echo "  systemctl is-active nvidia-powerd          # -> inactive"
echo "  cat /sys/bus/pci/devices/${GPU_PCI}/power/runtime_status   # -> suspended"
echo "  journalctl -k -f | grep PRH                # -> silent (no new lines)"
echo "  awk '{print \$1/1000000\" W\"}' /sys/class/power_supply/BAT*/power_now  # ~11W idle"
echo ""
echo "Real fix for Dynamic Boost: an LG BIOS update exposing NVPCF for the 16Z90TR."
echo "To undo: sudo systemctl enable --now nvidia-powerd"
echo "=========================================="
