#!/usr/bin/env bash
# disk-guard: pause work before the kubelet evicts the pod for a full node disk.
#
# Everything outside /workspace (/root, /tmp, ...) is the container's writable
# layer on the node's local disk, with no quota. When that disk's free space or
# free inodes drop below the kubelet's hard eviction threshold (nodefs 5% on
# CKS), the kubelet kills the whole pod and /root is lost. An ephemeral-storage
# limit or an emptyDir sizeLimit would not help: the kubelet enforces both by
# evicting too.
#
# So this polls the filesystem and, when free space or inodes fall below
# PAUSE_PCT, SIGSTOPs the running work and warns every terminal. Once both are
# back at RESUME_PCT it SIGCONTs exactly what it stopped. Nothing is killed.
#
# Spared, so you can still log in and clean up: PID 1, sshd, shells,
# tmux/screen, editor remote servers, pagers/editors/monitors, and Claude Code.
# Commands started after the pause (rm, dvc gc, a cleanup script) run normally;
# only if free space keeps falling by another STEP_PCT does the guard pause
# again, which catches new writers (e.g. a shell loop launching more jobs).
#
# Thresholds, in whole percent of the filesystem:
#   DISK_GUARD_PAUSE_PCT  (8)   pause below this. The kubelet evicts at 5%; on
#                               the 7 TiB rtxp6000-8x local disk the 3% gap is
#                               ~210 GiB, many polls' worth of NVMe writes.
#   DISK_GUARD_RESUME_PCT (15)  resume at or above this, so cleanup must free
#                               ~500 GiB and a resumed job doesn't re-pause at once.
#   DISK_GUARD_STEP_PCT   (1)   pause again after this much further loss.
#   DISK_GUARD_INTERVAL   (2)   seconds between checks.
#   DISK_GUARD_PATH       (/)   filesystem to watch.
#
# Test hooks: _DISK_GUARD_STAT (file holding `stat -f -c '%a %b %d %c'` output
# to use instead of the real filesystem) and _DISK_GUARD_PIDS (file listing the
# only PIDs that may be paused, so tests can't freeze the host).

set -uo pipefail

pause_pct=${DISK_GUARD_PAUSE_PCT:-8}
resume_pct=${DISK_GUARD_RESUME_PCT:-15}
step_pct=${DISK_GUARD_STEP_PCT:-1}
interval=${DISK_GUARD_INTERVAL:-2}
path=${DISK_GUARD_PATH:-/}
nag_every=300

spared_comm='^(bash|sh|dash|zsh|fish|sshd|sshd-session|tmux.*|screen|SCREEN|sleep|claude|less|vim|nvim|top|htop|btop|nvtop|watch)$'
spared_exe='/\.(vscode-server|cursor-server|zed_server)/|zed-remote-server'

declare -A stopped=()  # pid -> start time, so a recycled PID is never resumed

log() { printf 'disk-guard: %s\n' "$*"; }

# Minimum of free-space and free-inode fractions, in basis points.
free_bp() {
    local avail total ifree itotal b i
    if [[ -n ${_DISK_GUARD_STAT:-} ]]; then
        read -r avail total ifree itotal <"$_DISK_GUARD_STAT"
    else
        read -r avail total ifree itotal < <(stat -f -c '%a %b %d %c' "$path")
    fi
    b=$((avail * 10000 / total))
    # Some filesystems report no inode limit (total 0).
    i=$((itotal > 0 ? ifree * 10000 / itotal : 10000))
    echo $((b < i ? b : i))
}

starttime() {
    local stat f
    { stat=$(<"/proc/$1/stat"); } 2>/dev/null || return 1
    # Fields after the parenthesised comm, which may itself contain spaces.
    read -ra f <<<"${stat##*) }"
    echo "${f[19]}"
}

candidates() {
    if [[ -n ${_DISK_GUARD_PIDS:-} ]]; then
        cat "$_DISK_GUARD_PIDS"
    else
        local d
        for d in /proc/[0-9]*; do echo "${d#/proc/}"; done
    fi
}

spared() {
    local pid=$1 comm exe
    ((pid == 1 || pid == $$ || pid == PPID)) && return 0
    { comm=$(<"/proc/$pid/comm"); } 2>/dev/null || return 0
    [[ $comm =~ $spared_comm ]] && return 0
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
    [[ -n $exe && $exe =~ $spared_exe ]]
}

pause_work() {
    local pid st n=0
    while read -r pid; do
        [[ -n ${stopped[$pid]:-} ]] && continue
        spared "$pid" && continue
        st=$(starttime "$pid") || continue
        kill -STOP "$pid" 2>/dev/null && stopped[$pid]=$st && ((n++))
    done < <(candidates)
    log "paused $n process(es), ${#stopped[@]} paused in total"
}

resume_work() {
    local pid
    for pid in "${!stopped[@]}"; do
        [[ $(starttime "$pid") == "${stopped[$pid]}" ]] && kill -CONT "$pid" 2>/dev/null
    done
    log "resumed ${#stopped[@]} process(es)"
    stopped=()
}

# Message every terminal; a stuck tty must not block the guard.
broadcast() {
    local tty
    log "$1"
    for tty in /dev/pts/[0-9]*; do
        # shellcheck disable=SC2016  # expanded by the inner bash
        timeout 1 bash -c 'printf "\r\n\a*** %s ***\r\n" "$1" >"$2"' _ "$1" "$tty" 2>/dev/null
    done
}

pct() { printf '%d.%02d%%' $(($1 / 100)) $(($1 % 100)); }

trap resume_work EXIT
trap exit INT TERM

pause_bp=$((pause_pct * 100)) resume_bp=$((resume_pct * 100)) step_bp=$((step_pct * 100))
paused=0 low=0 nagged=0
log "watching $path: pause below ${pause_pct}% free, resume at ${resume_pct}%"
while :; do
    bp=$(free_bp)
    if ((!paused && bp < pause_bp)) || ((paused && bp < low - step_bp)); then
        pause_work
        paused=1 low=$bp nagged=$((SECONDS - nag_every))
    elif ((paused && bp >= resume_bp)); then
        resume_work
        paused=0
        broadcast "disk-guard: node disk back to $(pct "$bp") free, paused jobs resumed"
    fi
    if ((paused && SECONDS - nagged >= nag_every)); then
        broadcast "disk-guard: node disk at $(pct "$bp") free (pod is evicted at 5%). ${#stopped[@]} jobs are PAUSED (SIGSTOP, not killed). Delete files outside /workspace until free reaches ${resume_pct}%; find them with: du -xh -d2 / | sort -h | tail"
        nagged=$SECONDS
    fi
    sleep "$interval"
done
