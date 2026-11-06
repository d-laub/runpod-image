#!/usr/bin/env bats

# Runs the guard against a fake filesystem (_POD_GUARD_STAT), a fake cgroup
# (_POD_GUARD_CGROUP) and a fixed PID list (_POD_GUARD_PIDS), so it can only
# ever pause the test's own victims. Linux only: the guard reads /proc.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pod-guard.sh"

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
