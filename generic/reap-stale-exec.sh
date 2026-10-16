#!/usr/bin/env bash
# Kill shells left behind by `kubectl exec -- bash` sessions whose client
# disconnected (laptop sleep, network drop). Kubelet never closes the exec pty,
# so the shell and any `zellij attach` client inside it live forever, piling up
# as stale clients on the zellij session. Run from .bashrc on each new exec
# login: only one terminal is ever live, so every OTHER exec shell is stale.
#
# Usage: reap-stale-exec.sh [--dry-run] CURRENT_SHELL_PID
#
# An exec shell is a bare interactive `bash` whose parent is PID 0 (outside the
# container's pid namespace). Of those, besides the current one:
#   - no children          → SIGHUP the shell
#   - only zellij clients  → SIGKILL the clients (they ignore HUP/TERM on a dead
#                            pty), then SIGHUP the shell
#   - anything else        → leave it; a foreground job may still be wanted
# The zellij server and its panes are never touched.
# _REAP_PS overrides the process-table command for testing.

set -u

dry_run=0
if [[ ${1:-} == --dry-run ]]; then
    dry_run=1
    shift
fi
self=${1:?usage: reap-stale-exec.sh [--dry-run] CURRENT_SHELL_PID}

_kill() {
    if ((dry_run)); then
        echo "kill -$1 $2"
    else
        kill "-$1" "$2" 2>/dev/null
    fi
}

declare -A ppid_of args_of
while read -r pid ppid args; do
    ppid_of[$pid]=$ppid
    args_of[$pid]=$args
done < <(${_REAP_PS:-ps -eo pid=,ppid=,args=})

reaped=0
for shell in "${!ppid_of[@]}"; do
    [[ ${ppid_of[$shell]} == 0 && $shell != "$self" ]] || continue
    [[ ${args_of[$shell]} =~ ^(-|/bin/|/usr/bin/)?bash$ ]] || continue

    clients=()
    other=0
    for child in "${!ppid_of[@]}"; do
        [[ ${ppid_of[$child]} == "$shell" ]] || continue
        if [[ ${args_of[$child]} =~ (^|/)zellij\ (a|attach)( |$) ]]; then
            clients+=("$child")
        else
            other=1
        fi
    done

    if ((other)); then
        echo "reap-stale-exec: skipping exec shell $shell (running a non-zellij job)" >&2
        continue
    fi
    for client in "${clients[@]}"; do
        _kill KILL "$client"
    done
    _kill HUP "$shell"
    ((reaped++))
done

if ((reaped)); then
    echo "reaped $reaped stale exec shell(s)"
fi
exit 0
