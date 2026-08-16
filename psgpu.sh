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

# tput falls back to the terminfo width (80) when stdout is a pipe, which is the
# right answer there anyway.
TERM_WIDTH=$(tput cols 2>/dev/null) || TERM_WIDTH=100
(( TERM_WIDTH < 60 )) && TERM_WIDTH=60

# Where COMMAND starts in each table: the sum of the preceding printf widths
# plus their separating spaces. Kept next to the format strings they mirror.
HOLDER_CMD_COL=66   # 8 +1+ 10 +1+ 8 +1+ 9 +1+ 26 +1
COMPUTE_CMD_COL=44  # 4 +1+ 8 +1+ 10 +1+ 9 +1+ 8 +1

# Emit "<prefix><command>" with the command greedy-wrapped inside its own column:
# continuation lines are indented to $col so the table keeps its shape. The
# prefix is measured rather than assumed to equal $col, since an over-long
# earlier field (NODES, say) pushes the first line right.
wrap_row() {
    local prefix=$1 col=$2 text=$3
    local pad
    printf -v pad '%*s' "$col" ''
    # Never let a wide prefix drive the text column to zero: the hard-break loop
    # below would spin forever on a zero-width slice.
    local textw=$((TERM_WIDTH - col))
    (( textw < 20 )) && textw=20
    local avail=$((TERM_WIDTH - ${#prefix})) line='' out='' word
    (( avail < 20 )) && avail=20
    local -a words
    read -ra words <<< "$text"
    for word in "${words[@]}"; do
        # A single token wider than the column (long paths) is hard-broken.
        while (( ${#word} > avail )); do
            if [[ -n $line ]]; then
                out+="$prefix$line"$'\n'
            else
                out+="$prefix${word:0:avail}"$'\n'
                word=${word:avail}
            fi
            line=''
            prefix=$pad
            avail=$textw
        done
        if [[ -z $line ]]; then
            line=$word
        elif (( ${#line} + 1 + ${#word} <= avail )); then
            line+=" $word"
        else
            out+="$prefix$line"$'\n'
            line=$word
            prefix=$pad
            avail=$textw
        fi
    done
    [[ -n $line ]] && out+="$prefix$line"$'\n'
    printf '%s' "$out"
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
    printf -v prefix '%-8s %-10s %-8s %-9s %-26s ' \
        "$pid" "$user" "$etime" "$((rss / 1024))MiB" "$nodes"
    holder_rows+=$(wrap_row "$prefix" "$HOLDER_CMD_COL" "$full_cmd")$'\n'
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

# Thermals come from NVML, not /sys: the proprietary driver registers no hwmon
# node (only nouveau does), so there is no sysfs source to read them from.
# Fields absent on a given board (temperature.memory outside datacenter parts,
# fan.speed on passively cooled ones) come back as [N/A] and print as '-'.
declare -A gpu_index gpu_util gpu_mem_used gpu_temp gpu_fan gpu_power
while IFS=', ' read -r idx uuid util mem_used _ temp fan power; do
    gpu_index[$uuid]=$idx
    gpu_util[$uuid]=$util
    gpu_mem_used[$uuid]=$mem_used
    gpu_temp[$uuid]=$temp
    gpu_fan[$uuid]=$fan
    gpu_power[$uuid]=$power
done < <(nvidia-smi \
    --query-gpu=index,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu,fan.speed,power.draw \
    --format=csv,noheader,nounits 2>/dev/null)

# nvidia-smi spells unsupported fields '[N/A]'; a bare unit suffix on that would
# read as a real measurement.
fmt_field() {
    [[ $1 == '[N/A]' || -z $1 ]] && { printf -- '-'; return; }
    printf '%s%s' "$1" "$2"
}

gpu_rows=""
for uuid in "${!gpu_index[@]}"; do
    gpu_rows+=$(printf '%-4s %-6s %-10s %-6s %-6s %s' \
        "${gpu_index[$uuid]}" \
        "$(fmt_field "${gpu_util[$uuid]}" '%')" \
        "$(fmt_field "${gpu_mem_used[$uuid]}" 'MiB')" \
        "$(fmt_field "${gpu_temp[$uuid]}" 'C')" \
        "$(fmt_field "${gpu_fan[$uuid]}" '%')" \
        "$(fmt_field "${gpu_power[$uuid]}" 'W')")$'\n'
done
gpu_rows=$(sort -n <<< "${gpu_rows%$'\n'}")

# MEM here is this process's own VRAM, distinct from the per-GPU total above.
# There is no per-process utilization: NVML only exposes it with accounting mode
# enabled, which requires root and is off by default (accounting.mode=Disabled).
compute_rows=""
while IFS=', ' read -r pid proc uuid mem_used; do
    [[ -z $pid ]] && continue
    idx=${gpu_index[$uuid]:-'?'}
    read -r user elapsed full_cmd < <(ps -p "$pid" -o user=,etimes=,args= 2>/dev/null)
    if [[ -n $elapsed ]]; then
        etime=$(printf '%dh%02dm' $((elapsed / 3600)) $(((elapsed % 3600) / 60)))
    else
        # NVML sees every user's compute apps, but the process may have exited
        # between the query and here.
        user='?'
        etime='?'
        full_cmd=$(basename "$proc")
    fi
    printf -v prefix '%-4s %-8s %-10s %-9s %-8s ' \
        "$idx" "$pid" "$user" "${mem_used}MiB" "$etime"
    compute_rows+=$(wrap_row "$prefix" "$COMPUTE_CMD_COL" "$full_cmd")$'\n'
done < <(nvidia-smi --query-compute-apps=pid,process_name,gpu_uuid,used_memory \
    --format=csv,noheader,nounits 2>/dev/null)

if [[ -n $gpu_rows ]]; then
    printf '\n%-4s %-6s %-10s %-6s %-6s %s\n' GPU UTIL MEM TEMP FAN POWER
    printf '%s\n' "$gpu_rows"
fi

if [[ -n $compute_rows ]]; then
    printf '\nCOMPUTE (NVML; all users)\n'
    printf '%-4s %-8s %-10s %-9s %-8s %s\n' GPU PID USER MEM TIME COMMAND
    printf '%s' "$compute_rows"
fi
