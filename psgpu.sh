#!/bin/bash
# List processes holding the NVIDIA device, then per-process GPU usage.
#
# Two sections, in this order deliberately:
#   1. HOLDERS  - scans /proc/*/fd for /dev/nvidia*. Pure sysfs/procfs, never
#                 touches the driver, so it works even when the GPU is wedged
#                 and it also catches clients that opened the device but have
#                 not created a CUDA context yet (invisible to NVML).
#   2. COMPUTE  - nvidia-smi query. Reports real GPU memory and utilization,
#                 which the kernel does not expose anywhere else, but it wakes
#                 the GPU from D3cold and can hang on a wedged driver. Printed
#                 second so the safe output is already on screen if it stalls.
#
# Empty sections print nothing: an idle GPU is a single line.
#
# Run under sudo to see holders owned by other users.

set -uo pipefail

# Every GPU bound to the nvidia driver, not just the first. Runtime PM state is
# per-device: one card can be in D3cold while another is computing.
mapfile -t GPU_PCI < <(
    for dev in /sys/bus/pci/drivers/nvidia/0000:*; do
        [[ -e $dev/power/runtime_status ]] && basename "$dev"
    done
)

read_attr() {
    cat "/sys/bus/pci/devices/$1/$2" 2>/dev/null || echo '?'
}

# Aggregate across cards: any device in error blocks nvidia-smi, and any device
# with a nonzero refcount means the driver is already awake, so querying it is
# free.
any_error=0
total_usage=0
power_lines=""
for pci in "${GPU_PCI[@]}"; do
    rs=$(read_attr "$pci" power/runtime_status)
    ps=$(read_attr "$pci" power_state)
    ru=$(read_attr "$pci" power/runtime_usage)
    [[ $rs == error ]] && any_error=1
    [[ $ru =~ ^[0-9]+$ ]] && ((total_usage += ru))
    power_lines+="$pci|$rs|$ps|$ru"$'\n'
done

# ------------------------------------------------------------------------------
# 1. Device holders (safe)
# ------------------------------------------------------------------------------
# One row per pid: a client typically opens several nodes (nvidiactl, nvidia0,
# nvidia-uvm), and listing each fd separately would triple every entry.
# find matches the symlink target itself, so the whole scan is one syscall pass.
# A shell loop calling readlink per fd does the same job ~300x slower (8.3s vs
# 0.03s here) because it forks for every descriptor on the system.
holders=$(
    find /proc/[0-9]*/fd -maxdepth 1 -lname '/dev/nvidia*' -printf '%h %f %l\n' \
        2>/dev/null |
        awk '{split($1, p, "/"); split($3, n, "/"); print p[3], n[3]}' |
        sort -u -k1,1n -k2,2 |
        awk '{a[$1] = ($1 in a ? a[$1] "," $2 : $2)} END {for (p in a) print p, a[p]}' |
        sort -n
)

holder_rows=""
while read -r pid nodes; do
    [[ -z $pid ]] && continue
    read -r user elapsed rss full_cmd < <(
        ps -p "$pid" -o user=,etimes=,rss=,args= 2>/dev/null)
    # The process exited between the fd scan and here.
    [[ -z $user ]] && continue
    etime=$(printf '%dh%02dm' $((elapsed / 3600)) $(((elapsed % 3600) / 60)))
    # RSS is host memory, not VRAM; the kernel exposes no per-process VRAM.
    holder_rows+=$(printf '%-8s %-10s %-8s %-9s %-26s %s' \
        "$pid" "$user" "$etime" "$((rss / 1024))MiB" "$nodes" "$full_cmd")$'\n'
done <<< "$holders"

while IFS='|' read -r pci rs ps ru; do
    [[ -z $pci ]] && continue
    if [[ $ru == 0 || $ru == '?' ]]; then
        printf 'GPU %s: %s (%s), no clients\n' "$pci" "$rs" "$ps"
    else
        printf 'GPU %s: %s (%s), runtime_usage=%s\n' "$pci" "$rs" "$ps" "$ru"
    fi
done <<< "$power_lines"

if [[ -n $holder_rows ]]; then
    scope='all users'
    [[ $EUID -ne 0 ]] && scope="$(id -un) only; /proc/<pid>/fd is unreadable for other users -- run under sudo for all"
    printf '\nHOLDERS (open /dev/nvidia* fds; %s)\n' "$scope"
    printf '%-8s %-10s %-8s %-9s %-26s %s\n' \
        PID USER TIME RSS NODES COMMAND
    printf '%s' "$holder_rows"
fi

# ------------------------------------------------------------------------------
# 2. Compute apps (wakes the GPU; may hang if the driver is wedged)
# ------------------------------------------------------------------------------
if (( any_error )); then
    printf '\nruntime_status=error: skipping nvidia-smi, it would hang.\n'
    exit 0
fi

# Skipping the query keeps an idle GPU in D3cold: the two nvidia-smi calls below
# cost ~4s and a wake for no information. Empty holder_rows is NOT sufficient
# evidence of idle -- the fd scan cannot read /proc/<pid>/fd of other users'
# processes without sudo, so another user's compute job is invisible to it.
# runtime_usage is the kernel's own reference count and sees every client.
if [[ -z $holder_rows ]] && (( total_usage == 0 )); then
    exit 0
fi

declare -A gpu_index gpu_util gpu_mem_used
while IFS=', ' read -r idx uuid util mem_used _; do
    gpu_index[$uuid]=$idx
    gpu_util[$uuid]=$util
    gpu_mem_used[$uuid]=$mem_used
done < <(nvidia-smi --query-gpu=index,uuid,utilization.gpu,memory.used,memory.total \
    --format=csv,noheader,nounits 2>/dev/null)

gpu_rows=""
for uuid in "${!gpu_index[@]}"; do
    gpu_rows+=$(printf '%-4s %-6s %s' \
        "${gpu_index[$uuid]}" "${gpu_util[$uuid]}%" "${gpu_mem_used[$uuid]}MiB")$'\n'
done
gpu_rows=$(sort -n <<< "${gpu_rows%$'\n'}")

# MEM here is this process's own VRAM, distinct from the per-GPU total above.
# There is no per-process utilization: NVML only exposes it with accounting mode
# enabled, which requires root and is off by default (accounting.mode=Disabled).
compute_rows=""
while IFS=', ' read -r pid proc uuid mem_used; do
    [[ -z $pid ]] && continue
    idx=${gpu_index[$uuid]:-'?'}
    read -r elapsed full_cmd < <(ps -p "$pid" -o etimes=,args= 2>/dev/null)
    if [[ -n $elapsed ]]; then
        etime=$(printf '%dh%02dm' $((elapsed / 3600)) $(((elapsed % 3600) / 60)))
    else
        etime='?'
        full_cmd=$(basename "$proc")
    fi
    compute_rows+=$(printf '%-4s %-8s %-9s %-8s %s' \
        "$idx" "$pid" "${mem_used}MiB" "$etime" "$full_cmd")$'\n'
done < <(nvidia-smi --query-compute-apps=pid,process_name,gpu_uuid,used_memory \
    --format=csv,noheader,nounits 2>/dev/null)

if [[ -n $gpu_rows ]]; then
    printf '\n%-4s %-6s %s\n' GPU UTIL MEM
    printf '%s\n' "$gpu_rows"
fi

if [[ -n $compute_rows ]]; then
    printf '\nCOMPUTE (NVML; all users)\n'
    printf '%-4s %-8s %-9s %-8s %s\n' GPU PID MEM TIME COMMAND
    printf '%s' "$compute_rows"
fi
