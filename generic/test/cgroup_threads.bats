#!/usr/bin/env bats

# All tests source the script in a clean subshell with:
#   - fake cgroup files written to a tmpdir
#   - cgroup path overrides passed via env vars (_CGROUP_V2_CPU_MAX etc.)
#   - a no-op taskset binary injected at the front of PATH

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/cgroup-threads.sh"

setup() {
    TMPD="$(mktemp -d)"
    mkdir -p "$TMPD/bin" "$TMPD/v2" "$TMPD/v1/cpu"
    # No-op taskset so the script doesn't try to set affinity on the test PID
    printf '#!/bin/sh\nexit 0\n' > "$TMPD/bin/taskset"
    chmod +x "$TMPD/bin/taskset"
    export _SAVED_PATH="$PATH"
    export PATH="$TMPD/bin:$PATH"
}

teardown() {
    rm -rf "$TMPD"
    export PATH="$_SAVED_PATH"
    unset _SAVED_PATH
}

# Source the script in a clean subshell and print OMP_NUM_THREADS.
# Usage: _run v2_cpu_max_file v1_quota_file v1_period_file
_run() {
    env -i \
        PATH="$PATH" \
        HOME="$HOME" \
        _CGROUP_V2_CPU_MAX="$1" \
        _CGROUP_V1_QUOTA="$2" \
        _CGROUP_V1_PERIOD="$3" \
        bash --norc --noprofile -c "source '$SCRIPT'; printf '%s' \"\$OMP_NUM_THREADS\""
}

@test "cgroup v2: quota/period yields correct thread count" {
    echo "400000 100000" > "$TMPD/v2/cpu.max"
    result=$(_run "$TMPD/v2/cpu.max" /nonexistent /nonexistent)
    [ "$result" = "4" ]
}

@test "cgroup v2: quota=max falls through to v1" {
    echo "max 100000" > "$TMPD/v2/cpu.max"
    echo "800000" > "$TMPD/v1/cpu/quota"
    echo "100000" > "$TMPD/v1/cpu/period"
    result=$(_run "$TMPD/v2/cpu.max" "$TMPD/v1/cpu/quota" "$TMPD/v1/cpu/period")
    [ "$result" = "8" ]
}

@test "cgroup v1: positive quota yields correct thread count" {
    echo "200000" > "$TMPD/v1/cpu/quota"
    echo "100000" > "$TMPD/v1/cpu/period"
    result=$(_run /nonexistent "$TMPD/v1/cpu/quota" "$TMPD/v1/cpu/period")
    [ "$result" = "2" ]
}

@test "cgroup v1: quota=-1 falls through to nproc" {
    echo "-1" > "$TMPD/v1/cpu/quota"
    echo "100000" > "$TMPD/v1/cpu/period"
    expected="$(nproc)"
    result=$(_run /nonexistent "$TMPD/v1/cpu/quota" "$TMPD/v1/cpu/period")
    [ "$result" = "$expected" ]
}

@test "no cgroup files: nproc fallback" {
    expected="$(nproc)"
    result=$(_run /nonexistent /nonexistent /nonexistent)
    [ "$result" = "$expected" ]
}

@test "result floored at 1 when detection returns 0" {
    # quota < period → integer division gives 0
    echo "50000 100000" > "$TMPD/v2/cpu.max"
    result=$(_run "$TMPD/v2/cpu.max" /nonexistent /nonexistent)
    [ "$result" = "1" ]
}

@test "guard: double-source leaves env vars unchanged" {
    echo "400000 100000" > "$TMPD/v2/cpu.max"
    result=$(
        env -i \
            PATH="$PATH" \
            HOME="$HOME" \
            _CGROUP_V2_CPU_MAX="$TMPD/v2/cpu.max" \
            _CGROUP_V1_QUOTA=/nonexistent \
            _CGROUP_V1_PERIOD=/nonexistent \
            bash --norc --noprofile -c "
                source '$SCRIPT'
                OMP_NUM_THREADS=999
                source '$SCRIPT'
                printf '%s' \"\$OMP_NUM_THREADS\"
            "
    )
    [ "$result" = "999" ]
}

@test "cgroup v1: missing period file falls through to nproc" {
    echo "200000" > "$TMPD/v1/cpu/quota"
    # period file deliberately absent
    expected="$(nproc)"
    result=$(_run /nonexistent "$TMPD/v1/cpu/quota" /nonexistent)
    [ "$result" = "$expected" ]
}

@test "all 12 thread-count env vars are exported and equal" {
    echo "400000 100000" > "$TMPD/v2/cpu.max"
    result=$(
        env -i \
            PATH="$PATH" \
            HOME="$HOME" \
            _CGROUP_V2_CPU_MAX="$TMPD/v2/cpu.max" \
            _CGROUP_V1_QUOTA=/nonexistent \
            _CGROUP_V1_PERIOD=/nonexistent \
            bash --norc --noprofile -c "
                source '$SCRIPT'
                echo \"\$OMP_NUM_THREADS \$OPENBLAS_NUM_THREADS \$MKL_NUM_THREADS \
\$VECLIB_MAXIMUM_THREADS \$BLIS_NUM_THREADS \$NUMEXPR_NUM_THREADS \
\$NUMBA_NUM_THREADS \$RAYON_NUM_THREADS \$PYTORCH_OPENMP_THREADS \
\$TF_NUM_INTEROP_THREADS \$TF_NUM_INTRAOP_THREADS \$JULIA_NUM_THREADS\"
            "
    )
    [ "$result" = "4 4 4 4 4 4 4 4 4 4 4 4" ]
}
