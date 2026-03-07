#!/bin/bash
# =============================================================================
# generate_and_push.sh
# Daily HPC snapshot: creates dated subdir with system files, pushes to GitHub
#
# Cron example (23:00 daily):
#   0 23 * * * /nfs/shared/projects/hpc-cluster-mod/scripts/generate_and_push.sh >> /nfs/shared/projects/hpc-cluster-mod/auto_upload.log 2>&1
# =============================================================================

set -euo pipefail

# --- Config ---
REPO_DIR="/nfs/shared/projects/hpc-cluster-mod"
DATE=$(date +%Y-%m-%d)
TIME=$(date +%H:%M:%S)
SUBDIR="${REPO_DIR}/${DATE}"
LOG_FILE="${REPO_DIR}/auto_upload.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }

# --- Sanity check ---
if [[ ! -d "${REPO_DIR}/.git" ]]; then
    log "ERROR: ${REPO_DIR} is not a git repository. Run 'git init' or clone first."
    exit 1
fi

cd "${REPO_DIR}"

# Pull latest to avoid push conflicts
log "Pulling latest from origin..."
git pull --rebase origin main >> "${LOG_FILE}" 2>&1 || {
    log "WARNING: git pull failed (maybe repo is empty or offline). Continuing..."
}

# --- Create today's subdir (idempotent: safe to re-run same day) ---
mkdir -p "${SUBDIR}"
log "Working in subdir: ${SUBDIR}"

# --- File 1: system_info.txt ---
cat > "${SUBDIR}/system_info.txt" << EOF
=== HPC Node Snapshot ===
Date     : ${DATE}
Time     : ${TIME}
Hostname : $(hostname -f)
Kernel   : $(uname -r)
Uptime   : $(uptime -p)
Load Avg : $(cat /proc/loadavg)

--- CPU ---
$(lscpu | grep -E "^(Model name|CPU\(s\)|Thread\(s\)|Core\(s\)|Socket|CPU MHz)" | sed 's/^/  /')

--- Memory ---
$(free -h | sed 's/^/  /')

--- Disk ---
$(df -h --output=source,size,used,avail,pcent,target -x tmpfs -x devtmpfs | sed 's/^/  /')
EOF

# --- File 2: gpu_status.txt ---
{
    echo "=== GPU Status ==="
    echo "Date : ${DATE}  Time : ${TIME}"
    echo "Host : $(hostname -f)"
    echo ""
    if command -v nvidia-smi &>/dev/null; then
        echo "--- Summary ---"
        nvidia-smi --query-gpu=index,name,memory.total,memory.used,memory.free,utilization.gpu,temperature.gpu \
            --format=csv
        echo ""
        echo "--- Full nvidia-smi ---"
        nvidia-smi
    else
        echo "nvidia-smi not available on this host."
    fi
} > "${SUBDIR}/gpu_status.txt"

# --- File 3: top_processes.txt ---
{
    echo "=== Top Process Snapshot ==="
    echo "Date : ${DATE}  Time : ${TIME}"
    echo "Host : $(hostname -f)"
    echo ""
    echo "--- Top 15 by CPU ---"
    ps aux --sort=-%cpu | head -16
    echo ""
    echo "--- Top 15 by Memory ---"
    ps aux --sort=-%mem | head -16
} > "${SUBDIR}/top_processes.txt"

# --- File 4: network_info.txt ---
{
    echo "=== Network Snapshot ==="
    echo "Date : ${DATE}  Time : ${TIME}"
    echo "Host : $(hostname -f)"
    echo ""
    echo "--- IP Addresses ---"
    ip -br addr show | sed 's/^/  /'
    echo ""
    echo "--- Routes ---"
    ip route show | sed 's/^/  /'
    echo ""
    echo "--- Listening Ports ---"
    ss -tlnp | sed 's/^/  /'
} > "${SUBDIR}/network_info.txt"

# --- File 5: daily_summary.json (machine-readable) ---
LOAD1=$(awk '{print $1}' /proc/loadavg)
MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
MEM_USED=$(free -m  | awk '/^Mem:/{print $3}')
MEM_FREE=$(free -m  | awk '/^Mem:/{print $4}')
DISK_ROOT=$(df / | awk 'NR==2{print $5}' | tr -d '%')
GPU_COUNT=0
command -v nvidia-smi &>/dev/null && GPU_COUNT=$(nvidia-smi --list-gpus 2>/dev/null | wc -l) || true

cat > "${SUBDIR}/daily_summary.json" << EOF
{
  "date":               "${DATE}",
  "time":               "${TIME}",
  "hostname":           "$(hostname -f)",
  "kernel":             "$(uname -r)",
  "uptime":             "$(uptime -p)",
  "load_avg_1m":         ${LOAD1},
  "memory_total_mb":     ${MEM_TOTAL},
  "memory_used_mb":      ${MEM_USED},
  "memory_free_mb":      ${MEM_FREE},
  "root_disk_used_pct":  ${DISK_ROOT},
  "gpu_count":           ${GPU_COUNT}
}
EOF

log "Generated files:"
ls -lh "${SUBDIR}" | tee -a "${LOG_FILE}"

# --- Git: commit and push ---
git add "${SUBDIR}/"

if git diff --cached --quiet; then
    log "Nothing new to commit (files unchanged)."
    exit 0
fi

git commit -m "auto: HPC snapshot ${DATE} ${TIME} [$(hostname -s)]"
log "Committed. Pushing to GitHub..."

git push origin main >> "${LOG_FILE}" 2>&1
log "Push successful."
