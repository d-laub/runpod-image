#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # each @test runs in its own subshell by design

bats_require_minimum_version 1.5.0

# Runs the guard against a fake filesystem (_POD_GUARD_STAT), a fake cgroup
# (_POD_GUARD_CGROUP) and a fixed PID list (_POD_GUARD_PIDS), so it can only
# ever pause the test's own victims. Linux only: the guard reads /proc.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pod-guard.sh"
HOOK="${SCRIPT%/*}/claude-hook.sh"

setup() {
    TMPD="$(mktemp -d)"
    # Victims are bash scripts blocking on a FIFO read, so their comm is the
    # script name and they need no external binary (copying `sleep` breaks on
    # multicall coreutils, which dispatch on the program name).
    mkfifo "$TMPD/fifo"
    make_sleeper "$TMPD/victim"
    : >"$TMPD/pids"
    set_free 50
    CG="$TMPD/cgroup"
    mkdir "$CG"
    echo 10000 >"$CG/memory.max"
    echo max >"$CG/memory.high"
    echo 1 >"$CG/memory.oom.group"
    set_mem 50
}

teardown() {
    [[ -n ${GUARD:-} ]] && kill "$GUARD" 2>/dev/null && wait "$GUARD" 2>/dev/null
    pkill -CONT -f "$TMPD/victim" 2>/dev/null
    pkill -f "$TMPD/victim" 2>/dev/null
    rm -rf "$TMPD"
}

make_sleeper() {
    printf '#!/bin/bash\nread -rt 1000 <>"%s"\n' "$TMPD/fifo" >"$1"
    chmod +x "$1"
}

# Free space as a whole percent of 10000 blocks; inodes plentiful.
set_free() { echo "$(($1 * 100)) 10000 1000 1000" >"$TMPD/stat"; }

# Memory: $1 = % of memory.max in use, $2 = of which page cache, $3 = shmem.
set_mem() {
    echo $(($1 * 100)) >"$CG/memory.current"
    printf 'anon 0\nfile %d\nshmem %d\nslab_reclaimable 0\n' \
        $((${2:-0} * 100)) $((${3:-0} * 100)) >"$CG/memory.stat"
}

spawn_victim() {
    "$TMPD/victim" 1000 >/dev/null 2>&1 3>&- &
    echo $! >>"$TMPD/pids"
    echo $!
}

start_guard() {
    _POD_GUARD_STAT="$TMPD/stat" _POD_GUARD_PIDS="$TMPD/pids" \
        _POD_GUARD_CGROUP="$CG" POD_GUARD_DISKS="/:8:15" \
        POD_GUARD_STATUS="$TMPD/run/status" _POD_GUARD_CLAUDE_SETTINGS="$TMPD/claude/settings.json" \
        POD_GUARD_INTERVAL=0.1 bash "$SCRIPT" >"$TMPD/log" 2>&1 3>&- &
    GUARD=$!
    sleep 0.3
}

state() { awk '{print $3}' "/proc/$1/stat"; }

# Poll for a process state instead of sleeping a fixed time.
wait_state() {
    for _ in $(seq 50); do
        [[ $(state "$1") == "$2" ]] && return 0
        sleep 0.1
    done
    echo "pid $1 state $(state "$1"), wanted $2" >&2
    cat "$TMPD/log" >&2
    return 1
}

@test "plenty of free space: nothing paused" {
    v=$(spawn_victim)
    start_guard
    sleep 0.5
    [ "$(state "$v")" = S ]
}

@test "below pause threshold: victim paused" {
    v=$(spawn_victim)
    start_guard
    set_free 7
    wait_state "$v" T
}

@test "low inodes alone also pause" {
    v=$(spawn_victim)
    start_guard
    echo "5000 10000 50 1000" >"$TMPD/stat"
    wait_state "$v" T
}

@test "between pause and resume: stays paused; at resume: continues" {
    v=$(spawn_victim)
    start_guard
    set_free 7
    wait_state "$v" T
    set_free 12
    sleep 0.5
    [ "$(state "$v")" = T ]
    set_free 15
    wait_state "$v" S
}

@test "process started after the pause runs, until space keeps falling" {
    v=$(spawn_victim)
    start_guard
    set_free 7
    wait_state "$v" T
    late=$(spawn_victim)
    sleep 0.5
    [ "$(state "$late")" = S ]
    set_free 5
    wait_state "$late" T
}

@test "spared comm (bash) is never paused" {
    mkdir "$TMPD/spared"
    make_sleeper "$TMPD/spared/bash"
    "$TMPD/spared/bash" 1000 >/dev/null 2>&1 3>&- &
    sh_pid=$!
    echo "$sh_pid" >>"$TMPD/pids"
    start_guard
    set_free 1
    sleep 0.5
    st=$(state "$sh_pid")
    kill "$sh_pid"
    [ "$st" = S ]
}

@test "guard exit resumes what it paused" {
    v=$(spawn_victim)
    start_guard
    set_free 7
    wait_state "$v" T
    kill "$GUARD"
    wait "$GUARD" 2>/dev/null || true
    GUARD=
    wait_state "$v" S
}

@test "startup: OOM kills one process, memory.high just below memory.max" {
    start_guard
    [ "$(cat "$CG/memory.oom.group")" = 0 ]
    [ "$(cat "$CG/memory.high")" = 9800 ]
}

@test "memory headroom below pause threshold: victim paused" {
    v=$(spawn_victim)
    start_guard
    set_mem 94
    wait_state "$v" T
    grep -q "kill a paused job" "$TMPD/log"
}

@test "page cache doesn't count against memory headroom; shmem does" {
    v=$(spawn_victim)
    start_guard
    set_mem 99 60
    sleep 0.5
    [ "$(state "$v")" = S ]
    set_mem 99 60 58
    wait_state "$v" T
}

@test "resume waits only on the resource that tripped" {
    v=$(spawn_victim)
    set_free 10 # between disk pause (8) and resume (15): never tripped
    start_guard
    set_mem 95
    wait_state "$v" T
    set_mem 87
    wait_state "$v" S
}

@test "no memory limit: memory not watched, cgroup untouched" {
    echo max >"$CG/memory.max"
    start_guard
    [ "$(cat "$CG/memory.oom.group")" = 1 ]
    run ! grep -q "watching memory" "$TMPD/log"
}

# Run the hook for event $1 in session $2.
hook() {
    echo "{\"session_id\": \"$2\", \"hook_event_name\": \"$1\"}" |
        POD_GUARD_STATUS="$TMPD/run/status" bash "$HOOK" "$1"
}

wait_status() {
    for _ in $(seq 50); do
        [[ $(head -n1 "$TMPD/run/status" 2>/dev/null) == "$1 "* ]] && return 0
        sleep 0.1
    done
    cat "$TMPD/log" >&2
    return 1
}

@test "status file: written on pause, says resumed after recovery" {
    v=$(spawn_victim)
    start_guard
    [ ! -e "$TMPD/run/status" ]
    set_free 7
    wait_status paused
    grep -q "PAUSED 1 process" "$TMPD/run/status"
    grep -q "disk / is at 7.00% free" "$TMPD/run/status"
    set_free 50
    wait_status resumed
}

@test "status file: guard exit while paused says resumed" {
    v=$(spawn_victim)
    start_guard
    set_free 7
    wait_status paused
    kill "$GUARD"
    wait "$GUARD" 2>/dev/null || true
    GUARD=
    grep -q "^resumed " "$TMPD/run/status"
}

@test "hook: silent without a status file" {
    run hook PostToolUse s1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook: shows each event once per session; failed tools always, via stderr" {
    mkdir -p "$TMPD/run"
    printf 'paused 100\nthe "message"\n' >"$TMPD/run/status"
    run hook PostToolUse s1
    [ "$(python3 -c 'import json,sys; o=json.loads(sys.argv[1])["hookSpecificOutput"]; print(o["hookEventName"], o["additionalContext"])' "$output")" = 'PostToolUse the "message"' ]
    run hook UserPromptSubmit s1
    [ -z "$output" ]
    run -2 --separate-stderr hook PostToolUseFailure s1
    [ "$stderr" = 'the "message"' ]
    run hook PostToolUse s2
    [ -n "$output" ]
    printf 'resumed 200\nover\n' >"$TMPD/run/status"
    run hook PostToolUse s1
    [[ $output == *over* ]]
}

@test "hook: subagents sharing a session each see the event once" {
    mkdir -p "$TMPD/run"
    printf 'paused 150\nshared\n' >"$TMPD/run/status"
    agent() {
        echo "{\"session_id\": \"s3\", \"agent_id\": \"$1\", \"hook_event_name\": \"PostToolUse\"}" |
            POD_GUARD_STATUS="$TMPD/run/status" bash "$HOOK" PostToolUse
    }
    run hook PostToolUse s3 # main thread claims it
    [ -n "$output" ]
    run agent a1
    [[ $output == *shared* ]]
    run agent a2
    [[ $output == *shared* ]]
    run agent a1
    [ -z "$output" ]
    run hook PostToolUse s3
    [ -z "$output" ]
}

@test "hook watch: one watcher per agent, each woken by a pause" {
    mkdir -p "$TMPD/run"
    for a in x1 x2; do
        echo "{\"session_id\": \"s4\", \"agent_id\": \"$a\"}" | POD_GUARD_STATUS="$TMPD/run/status" \
            POD_GUARD_WATCH_POLL=0.1 bash "$HOOK" watch >/dev/null 2>"$TMPD/woke_$a" 3>&- &
    done
    sleep 0.3
    printf 'paused 400\nboth\n' >"$TMPD/run/status"
    wait
    [ "$(cat "$TMPD/woke_x1")" = both ]
    [ "$(cat "$TMPD/woke_x2")" = both ]
}

@test "hook watch: wakes the session (exit 2) when a pause starts, once" {
    mkdir -p "$TMPD/run"
    echo '{"session_id": "w1"}' | POD_GUARD_STATUS="$TMPD/run/status" POD_GUARD_WATCH_POLL=0.1 \
        bash "$HOOK" watch >/dev/null 2>"$TMPD/woke" 3>&- &
    w=$!
    sleep 0.3
    kill -0 "$w" # still waiting
    printf 'paused 300\nfrozen\n' >"$TMPD/run/status"
    rc=0
    wait "$w" || rc=$?
    [ "$rc" -eq 2 ]
    [ "$(cat "$TMPD/woke")" = frozen ]
    run hook PostToolUse w1 # already shown by the watcher
    [ -z "$output" ]
}

@test "hook watch: one watcher per session" {
    mkdir -p "$TMPD/run"
    echo '{"session_id": "w2"}' | POD_GUARD_STATUS="$TMPD/run/status" \
        bash "$HOOK" watch >/dev/null 2>&1 3>&- &
    w=$!
    sleep 0.3
    run hook watch w2
    [ "$status" -eq 0 ]
    kill "$w"
}

@test "startup merges the Claude Code hooks into settings, idempotently" {
    mkdir -p "$TMPD/claude"
    echo '{"theme": "dark", "hooks": {"PostToolUse": [{"hooks": [{"type": "command", "command": "mine"}]}]}}' >"$TMPD/claude/settings.json"
    start_guard
    kill "$GUARD"
    wait "$GUARD" 2>/dev/null || true
    start_guard
    python3 - "$TMPD/claude/settings.json" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["theme"] == "dark"
post = [h["command"] for e in s["hooks"]["PostToolUse"] for h in e["hooks"]]
assert post[0] == "mine" and len(post) == 2 and post[1].endswith("claude-hook.sh PostToolUse"), post
assert s["hooks"]["PreToolUse"][0]["hooks"][0]["asyncRewake"] is True
EOF
}
