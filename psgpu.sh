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

GPU_PCI=0000:01:00.0
SYSFS=/sys/bus/pci/devices/${GPU_PCI}

read_attr() {
    cat "${SYSFS}/$1" 2>/dev/null || echo '?'
}

runtime_status=$(read_attr power/runtime_status)
power_state=$(read_attr power_state)
runtime_usage=$(read_attr power/runtime_usage)

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

if [[ -n $holder_rows ]]; then
    printf 'GPU %s: %s (%s), runtime_usage=%s\n\n' \
        "$GPU_PCI" "$runtime_status" "$power_state" "$runtime_usage"
    printf '%-8s %-10s %-8s %-9s %-26s %s\n' \
        PID USER TIME RSS NODES COMMAND
    printf '%s' "$holder_rows"
elif [[ $runtime_usage == 0 || $runtime_usage == '?' ]]; then
    printf 'GPU %s: %s (%s), no clients\n' "$GPU_PCI" "$runtime_status" "$power_state"
else
    # No userspace holder yet runtime PM is pinned: a kernel-side reference.
    printf 'GPU %s: %s (%s), no client fds but runtime_usage=%s\n' \
        "$GPU_PCI" "$runtime_status" "$power_state" "$runtime_usage"
fi

# ------------------------------------------------------------------------------
# 2. Compute apps (wakes the GPU; may hang if the driver is wedged)
# ------------------------------------------------------------------------------
if [[ $runtime_status == error ]]; then
    printf '\nrutime_status=error: skipping nvidia-smi, it would hang.\n'
    exit 0
fi

declare -A gpu_index gpu_util gpu_mem_used
while IFS=', ' read -r idx uuid util mem_used _; do
    gpu_index[$uuid]=$idx
    gpu_util[$uuid]=$util
    gpu_mem_used[$uuid]=$mem_used
done < <(nvidia-smi --query-gpu=index,uuid,utilization.gpu,memory.used,memory.total \
    --format=csv,noheader,nounits 2>/dev/null)

compute_rows=""
while IFS=', ' read -r pid proc uuid _; do
    [[ -z $pid ]] && continue
    idx=${gpu_index[$uuid]:-'?'}
    util=${gpu_util[$uuid]:-'?'}
    mem_used=${gpu_mem_used[$uuid]:-'?'}
    read -r elapsed full_cmd < <(ps -p "$pid" -o etimes=,args= 2>/dev/null)
    if [[ -n $elapsed ]]; then
        etime=$(printf '%dh%02dm' $((elapsed / 3600)) $(((elapsed % 3600) / 60)))
    else
        etime='?'
        full_cmd=$(basename "$proc")
    fi
    compute_rows+=$(printf '%-4s %-8s %-6s %-9s %-8s %s' \
        "$idx" "$pid" "${util}%" "${mem_used}MiB" "$etime" "$full_cmd")$'\n'
done < <(nvidia-smi --query-compute-apps=pid,process_name,gpu_uuid,used_memory \
    --format=csv,noheader,nounits 2>/dev/null)

if [[ -n $compute_rows ]]; then
    printf '\n%-4s %-8s %-6s %-9s %-8s %s\n' GPU PID UTIL MEM TIME COMMAND
    printf '%s' "$compute_rows"
fi
