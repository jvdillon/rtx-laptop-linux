#!/bin/bash
# List GPU processes with GPU index, utilization, and memory info

# Build associative arrays from GPU info
declare -A gpu_index gpu_util gpu_mem_used
while IFS=', ' read -r idx uuid util mem_used _; do
    gpu_index[$uuid]=$idx
    gpu_util[$uuid]=$util
    gpu_mem_used[$uuid]=$mem_used
done < <(nvidia-smi --query-gpu=index,uuid,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits)

# Print header
printf "%-4s %-10s %-6s %-10s %-10s %s\n" "GPU" "PID" "UTIL" "MEM" "TIME" "COMMAND"
# printf "%-4s %-10s %-8s %-18s %s\n" "---" "---" "----" "---" "-------"

# Process each running compute app
while IFS=', ' read -r pid proc uuid _; do
    [ -z "$pid" ] && continue
    idx=${gpu_index[$uuid]:-"?"}
    util=${gpu_util[$uuid]:-"?"}
    mem_used=${gpu_mem_used[$uuid]:-"?"}
    read -r elapsed full_cmd < <(ps -p "$pid" -o etimes=,args= 2>/dev/null)
    [ -z "$full_cmd" ] && full_cmd=$(basename "$proc")
    if [ -n "$elapsed" ]; then
        hours=$((elapsed / 3600))
        mins=$(((elapsed % 3600) / 60))
        etime=$(printf "%dh%02dm" "$hours" "$mins")
    else
        etime="?"
    fi
    printf "%-4s %-10s %-6s %-10s %-10s %s\n" \
        "$idx" "$pid" "${util}%" "${mem_used}MiB" "$etime" "$full_cmd"
done < <(nvidia-smi --query-compute-apps=pid,process_name,gpu_uuid,used_memory --format=csv,noheader,nounits)
