#!/usr/bin/env bash
# pod-guard: pause work before the pod gets killed, instead of losing /root.
#
# The dev pod is a bare Pod with restartPolicy Never, so anything that kills
# the container loses /root. Two things do, and neither can be prevented by a
# Kubernetes limit, because the limits are what kill it:
#
#   Disk.   / (the container layer: /root, /tmp, ...) has no quota and shares
#           the node's local disk. Below 5% free (nodefs.available), the kubelet
#           evicts the pod; an ephemeral-storage limit evicts too.
#   Memory. At memory.max the kernel OOM-kills, and Kubernetes sets
#           memory.oom.group=1, so it kills every process in the container,
#           PID 1 included.
#
# So at startup this sets memory.oom.group=0 (an OOM kills one process, not the
# pod) and memory.high a little below memory.max (the kernel throttles
# allocations there instead of killing). Then it polls each resource and, when
# one falls below its pause threshold, SIGSTOPs the running work and warns every
# terminal; once every resource that tripped is back at its resume threshold it
# SIGCONTs exactly what it stopped. Nothing is killed. /workspace is watched
# too: filling it doesn't kill the pod, but it crashes the jobs writing to it.
#
# Agents and people are told through two channels. The status file
# (POD_GUARD_STATUS, /run/pod-guard/status) holds the current pause or the
# last resume; at startup the guard installs claude-hook.sh (next to this
# script) into the Claude Code user settings, which feeds it into every
# session on the pod and wakes agents whose commands the pause froze. Terminals sitting at a shell prompt also get a message; full-screen
# apps (Claude Code's TUI, vim) are skipped so they aren't drawn over.
#
# Spared, so you can still log in and clean up: PID 1, sshd, shells,
# tmux/screen, editor remote servers, pagers/editors/monitors, and Claude Code.
# Commands started after the pause (rm, dvc gc, kill) run normally; only if a
# resource keeps falling by another STEP_PCT does the guard pause again, which
# catches new writers (e.g. a shell loop launching more jobs).
#
# Thresholds are whole percent free (headroom). Margins were sized from rates
# measured on an rtxp6000-8x node, polled every 0.5 s:
#   POD_GUARD_DISKS ("/:8:15 /workspace:5:8")  path:pause:resume, per disk.
#       /: the kubelet evicts at 5%; the 3% gap is ~210 GiB of the 7 TiB local
#       disk, ~50 s at the measured 4.2 GiB/s. Resuming needs ~500 GiB freed so
#       a resumed job doesn't re-pause at once.
#       /workspace: 5% of the 1 TiB PVC is ~50 GiB, ~11 s at 4.6 GiB/s.
#   POD_GUARD_MEM ("7:12")  pause:resume for memory, as headroom below
#       memory.max of the non-reclaimable part (memory.current minus page cache
#       and reclaimable slab). 7% of 900 GiB is ~63 GiB, ~2.3 s at the measured
#       27 GiB/s allocation rate across 16 processes.
#   POD_GUARD_MEM_HIGH_PCT (2)  memory.high sits this far below memory.max, as
#       a backstop if a burst outruns the poll.
#   POD_GUARD_STEP_PCT (1)  pause again after this much further loss.
#   POD_GUARD_INTERVAL (0.5)  seconds between checks.
#
# Test hooks: _POD_GUARD_CLAUDE_SETTINGS (Claude Code settings file),
# _POD_GUARD_STAT (file holding `stat -f -c '%a %b %d %c'` output,
# used for every disk), _POD_GUARD_CGROUP (cgroup directory, default
# /sys/fs/cgroup) and _POD_GUARD_PIDS (file listing the only PIDs that may be
# paused, so tests can't freeze the host).

set -uo pipefail

step_pct=${POD_GUARD_STEP_PCT:-1}
interval=${POD_GUARD_INTERVAL:-0.5}
high_pct=${POD_GUARD_MEM_HIGH_PCT:-2}
cgroup=${_POD_GUARD_CGROUP:-/sys/fs/cgroup}
status=${POD_GUARD_STATUS:-/run/pod-guard/status}
nag_every=300     # seconds between terminal reminders while paused
refresh_every=10  # seconds between status file refreshes while paused
resumed_ttl=600   # seconds a "resumed" status stays up for agents to see
claude_settings=${_POD_GUARD_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}
hook="$(cd "${BASH_SOURCE[0]%/*}" && pwd)/claude-hook.sh"

spared_comm='^(bash|sh|dash|zsh|fish|sshd|sshd-session|tmux.*|screen|SCREEN|sleep|claude|less|vim|nvim|top|htop|btop|nvtop|watch)$'
spared_exe='/\.(vscode-server|cursor-server|zed_server)/|zed-remote-server'

log() { printf 'pod-guard: %s\n' "$*"; }

# Resources, as parallel arrays: "disk" with a path, or "mem".
names=() kinds=() paths=() pause_bp=() resume_bp=()
add() { names+=("$1") kinds+=("$2") paths+=("$3") pause_bp+=($(($4 * 100))) resume_bp+=($(($5 * 100))); }
for spec in ${POD_GUARD_DISKS-/:8:15 /workspace:5:8}; do
    IFS=: read -r p lo hi <<<"$spec"
    if [[ -n ${_POD_GUARD_STAT:-} || -d $p ]]; then add "disk $p" disk "$p" "$lo" "$hi"; fi
done
mem_max=$(cat "$cgroup/memory.max" 2>/dev/null) || mem_max=max
if [[ -n ${POD_GUARD_MEM-7:12} && $mem_max != max ]]; then
    IFS=: read -r lo hi <<<"${POD_GUARD_MEM-7:12}"
    add memory mem "" "$lo" "$hi"
fi

# Headroom of resource $1 in basis points: for a disk, the minimum of free-space
# and free-inode fractions; for memory, what's left below memory.max after
# subtracting what reclaim can't free.
headroom_bp() {
    local avail total ifree itotal b i key val cur file=0 shmem=0 slab=0
    if [[ ${kinds[$1]} == disk ]]; then
        if [[ -n ${_POD_GUARD_STAT:-} ]]; then
            read -r avail total ifree itotal <"$_POD_GUARD_STAT"
        else
            read -r avail total ifree itotal < <(stat -f -c '%a %b %d %c' "${paths[$1]}")
        fi
        b=$((avail * 10000 / total))
        # Some filesystems report no inode limit (total 0).
        i=$((itotal > 0 ? ifree * 10000 / itotal : 10000))
        echo $((b < i ? b : i))
    else
        read -r cur <"$cgroup/memory.current"
        while read -r key val; do
            case $key in
                file) file=$val ;;
                shmem) shmem=$val ;;
                slab_reclaimable) slab=$val ;;
            esac
        done <"$cgroup/memory.stat"
        # memory.stat counts tmpfs/shm under file, but it can't be reclaimed.
        echo $(((mem_max - (cur - (file - shmem) - slab)) * 10000 / mem_max))
    fi
}

setup_memcg() {
    [[ $mem_max == max ]] && return
    local high=$((mem_max - mem_max * high_pct / 100))
    if echo 0 >"$cgroup/memory.oom.group" && echo "$high" >"$cgroup/memory.high"; then
        log "memory: oom.group=0 (OOM kills one process, not the pod), memory.high=$((high >> 30)) GiB of $((mem_max >> 30)) GiB"
    else
        log "memory: cgroup is read-only; an OOM will still kill the whole pod"
    fi
}

# Merged into the user settings, which reload live in running sessions.
# (A managed-settings drop-in would be cleaner, but accounts with remote
# managed settings skip local managed files.) Re-running replaces our entries,
# leaving the rest of the file alone.
install_claude_hooks() {
    [[ -f $hook ]] || return
    python3 - "$claude_settings" "bash $hook" <<'EOF' || return
import json, os, sys
path, h = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        settings = json.load(f)
except FileNotFoundError:
    settings = {}
cmd = lambda event, **kw: {"hooks": [{"type": "command", "command": f"{h} {event}", **kw}]}
ours = {
    "SessionStart": cmd("SessionStart"),
    "UserPromptSubmit": cmd("UserPromptSubmit"),
    "PostToolUse": cmd("PostToolUse"),
    "PostToolUseFailure": cmd("PostToolUseFailure"),
    "PreToolUse": {"matcher": "Bash", **cmd("watch", **{"async": True, "asyncRewake": True})},
}
hooks = settings.setdefault("hooks", {})
for event, entry in ours.items():
    kept = [e for e in hooks.get(event, []) if not any("claude-hook.sh" in x.get("command", "") for x in e.get("hooks", []))]
    hooks[event] = kept + [entry]
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path + ".pod-guard.tmp", "w") as f:
    json.dump(settings, f, indent=2)
os.replace(path + ".pod-guard.tmp", path)
EOF
    log "Claude Code hooks installed in $claude_settings"
}

declare -A stopped=() # pid -> start time, so a recycled PID is never resumed

starttime() {
    local stat f
    { stat=$(<"/proc/$1/stat"); } 2>/dev/null || return 1
    # Fields after the parenthesised comm, which may itself contain spaces.
    read -ra f <<<"${stat##*) }"
    echo "${f[19]}"
}

candidates() {
    if [[ -n ${_POD_GUARD_PIDS:-} ]]; then
        cat "$_POD_GUARD_PIDS"
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

# The three paused processes holding the most memory, as "PID (comm, N GiB)".
biggest_paused() {
    local pid rss comm
    for pid in "${!stopped[@]}"; do
        rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null) || continue
        { comm=$(<"/proc/$pid/comm"); } 2>/dev/null || continue
        echo "${rss:-0} $pid $comm"
    done | sort -rn | head -3 | awk '{printf "%s%s (%s, %d GiB)", sep, $2, $3, $1 / 1048576; sep = ", "}'
}

# Terminals whose foreground process is a shell, i.e. sitting at a prompt.
shell_ttys() {
    local d stat f tty
    for d in /proc/[0-9]*; do
        { stat=$(<"$d/stat"); } 2>/dev/null || continue
        # tty_nr and tpgid: the foreground group leader of a terminal.
        read -ra f <<<"${stat##*) }"
        ((f[4] != 0 && f[5] == ${d#/proc/})) || continue
        [[ ${stat#*(} =~ ^(bash|zsh|sh|dash|fish)\) ]] || continue
        tty=$(readlink "$d/fd/0" 2>/dev/null) && [[ $tty == /dev/pts/* ]] && echo "$tty"
    done | sort -u
}

# Message every terminal at a prompt; a stuck tty must not block the guard.
broadcast() {
    local tty
    log "$1"
    for tty in $(shell_ttys); do
        # shellcheck disable=SC2016  # expanded by the inner bash
        timeout 1 bash -c 'printf "\r\n\a*** pod-guard: %s ***\r\n" "$1" >"$2"' _ "$1" "$tty" 2>/dev/null
    done
}

pct() { printf '%d.%02d%%' $(($1 / 100)) $(($1 % 100)); }

# What to do about each tripped resource.
advice() {
    local i msg=""
    for i in "${!tripped[@]}"; do
        if [[ ${kinds[$i]} == disk ]]; then
            msg+=" ${names[$i]} is at $(pct "${hr[$i]}") free: delete files there until $((resume_bp[i] / 100))% free (du -xh -d2 ${paths[$i]} | sort -h | tail)."
        else
            msg+=" Memory headroom is $(pct "${hr[$i]}"): kill a paused job to free memory until $((resume_bp[i] / 100))% (biggest: $(biggest_paused))."
        fi
    done
    echo "$msg"
}

# Status file: first line is "<state> <epoch>" (one key per event, so the hook
# shows each event once per session), the rest is the message for agents.
write_status() {
    mkdir -p "${status%/*}" && printf '%s %s\n%s\n' "$1" "$2" "$3" >"$status.tmp" && mv "$status.tmp" "$status"
}

paused_status() {
    write_status paused "$paused_at" "pod-guard (automated pod monitor): at $(date -ud "@$paused_at" +%H:%M) UTC it PAUSED ${#stopped[@]} process(es) with SIGSTOP (not killed) so the pod isn't killed.$(advice) Processes started before the pause are frozen, possibly including commands you launched, which would then hang until they time out. Tell the user about this now. Don't start disk- or memory-heavy work; help free space if the user asks. Paused jobs resume automatically once resources recover."
}

on_exit() {
    ((paused)) && write_status resumed "$(date +%s)" "pod-guard: the guard stopped, so the pause from $(date -ud "@$paused_at" +%H:%M) UTC is over and paused jobs were resumed."
    resume_work
}

trap on_exit EXIT
trap exit INT TERM

setup_memcg
install_claude_hooks
for i in "${!names[@]}"; do
    log "watching ${names[$i]}: pause below $((pause_bp[i] / 100))% free, resume at $((resume_bp[i] / 100))%"
done

declare -A tripped=() low=()
hr=()
paused=0 paused_at=0 nagged=0 refreshed=0 step_bp=$((step_pct * 100))
while :; do
    pause=0
    for i in "${!names[@]}"; do
        hr[i]=$(headroom_bp "$i")
        if [[ -z ${tripped[$i]:-} ]]; then
            ((hr[i] < pause_bp[i])) && tripped[$i]=1 low[$i]=${hr[i]} pause=1
        elif ((hr[i] < low[$i] - step_bp)); then
            low[$i]=${hr[i]} pause=1
        fi
    done
    if ((pause)); then
        pause_work
        ((paused)) || paused_at=$(date +%s)
        paused=1 nagged=$((SECONDS - nag_every)) refreshed=$((SECONDS - refresh_every))
    elif ((paused)); then
        ok=1
        for i in "${!tripped[@]}"; do ((hr[i] >= resume_bp[i])) || ok=0; done
        if ((ok)); then
            resume_work
            paused=0 tripped=() low=()
            write_status resumed "$(date +%s)" "pod-guard: resources recovered and the jobs paused at $(date -ud "@$paused_at" +%H:%M) UTC were resumed at $(date -u +%H:%M) UTC. Commands that hung or timed out during the pause may need re-running."
            broadcast "resources recovered, paused jobs resumed"
        fi
    elif [[ -f $status ]] && (($(date +%s) - $(stat -c %Y "$status") >= resumed_ttl)); then
        rm -f "$status"
    fi
    if ((paused && SECONDS - refreshed >= refresh_every)); then
        paused_status
        refreshed=$SECONDS
    fi
    if ((paused && SECONDS - nagged >= nag_every)); then
        broadcast "${#stopped[@]} job(s) PAUSED (SIGSTOP, not killed) to keep the pod alive.$(advice)"
        nagged=$SECONDS
    fi
    sleep "$interval"
done
