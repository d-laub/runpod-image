# cgroup-aware Thread Limiting — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add automatic CPU-limit detection to the generic RunPod image so every covered shell enforces the container's CFS quota as both an OS affinity mask and thread-count env vars, without any per-script changes.

**Architecture:** A single canonical script `generic/cgroup-threads.sh` is installed to `/etc/profile.d/cgroup-threads.sh` in the image. It detects the CFS quota (cgroup v2 → v1 → `nproc` fallback), sets the CPU affinity mask via `taskset`, and exports 12 thread-count env vars. A guard variable makes it idempotent. It is sourced from `/etc/profile.d/` (login shells / job runners) and also explicitly from `.bashrc` (interactive non-login shells).

**Tech Stack:** bash, `taskset` (util-linux — present in the Ubuntu 24.04 base), bats-core (tests)

**Prerequisite:** `brew install bats-core` (once, on dev machine — not in the image)

---

### Task 1: Implement `generic/cgroup-threads.sh` with tests

**Files:**
- Create: `generic/cgroup-threads.sh`
- Create: `generic/test/cgroup_threads.bats`

- [ ] **Step 1: Create the bats test file**

Create `generic/test/cgroup_threads.bats`:

```bash
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
```

- [ ] **Step 2: Run tests — confirm all fail**

```bash
bats generic/test/cgroup_threads.bats
```

Expected: all 8 tests fail with "No such file or directory" (script doesn't exist yet).

- [ ] **Step 3: Write `generic/cgroup-threads.sh`**

```bash
# Detects the container's CFS CPU quota and enforces it via:
#   1. CPU affinity mask (taskset) — fixes sched_getaffinity-based discovery
#      (glibc nproc, Python os.sched_getaffinity, OpenMP, Rust num_cpus/Rayon)
#   2. Thread-count env vars — belt-and-suspenders for libs that read env vars
#      before querying the kernel (BLAS, Numba, Julia, TF, etc.)
#
# Installed to /etc/profile.d/ (login shells) and sourced from .bashrc
# (interactive non-login shells). Guard makes double-sourcing a no-op.
#
# Override cgroup paths for testing:
#   _CGROUP_V2_CPU_MAX, _CGROUP_V1_QUOTA, _CGROUP_V1_PERIOD

[[ -n ${_CGROUP_THREADS_APPLIED:-} ]] && return 0

_cgroup_cpu_limit() {
    local v2="${_CGROUP_V2_CPU_MAX:-/sys/fs/cgroup/cpu.max}"
    local v1q="${_CGROUP_V1_QUOTA:-/sys/fs/cgroup/cpu/cpu.cfs_quota_us}"
    local v1p="${_CGROUP_V1_PERIOD:-/sys/fs/cgroup/cpu/cpu.cfs_period_us}"
    local quota period

    if [[ -f $v2 ]]; then
        read -r quota period < "$v2"
        if [[ $quota != max ]]; then
            echo $(( quota / period ))
            return
        fi
    fi

    if [[ -f $v1q ]]; then
        quota=$(< "$v1q")
        period=$(< "$v1p")
        if (( quota > 0 )); then
            echo $(( quota / period ))
            return
        fi
    fi

    nproc
}

_N=$(_cgroup_cpu_limit)
(( _N < 1 )) && _N=1

if command -v taskset >/dev/null 2>&1; then
    taskset -cp "0-$(( _N - 1 ))" "$$" >/dev/null 2>&1 || true
fi

export OMP_NUM_THREADS=$_N
export OPENBLAS_NUM_THREADS=$_N
export MKL_NUM_THREADS=$_N
export VECLIB_MAXIMUM_THREADS=$_N
export BLIS_NUM_THREADS=$_N
export NUMEXPR_NUM_THREADS=$_N
export NUMBA_NUM_THREADS=$_N
export RAYON_NUM_THREADS=$_N
export PYTORCH_OPENMP_THREADS=$_N
export TF_NUM_INTEROP_THREADS=$_N
export TF_NUM_INTRAOP_THREADS=$_N
export JULIA_NUM_THREADS=$_N
export _CGROUP_THREADS_APPLIED=1

unset _N
unset -f _cgroup_cpu_limit
```

- [ ] **Step 4: Run tests — confirm all pass**

```bash
bats generic/test/cgroup_threads.bats
```

Expected:
```
 ✓ cgroup v2: quota/period yields correct thread count
 ✓ cgroup v2: quota=max falls through to v1
 ✓ cgroup v1: positive quota yields correct thread count
 ✓ cgroup v1: quota=-1 falls through to nproc
 ✓ no cgroup files: nproc fallback
 ✓ result floored at 1 when detection returns 0
 ✓ guard: double-source leaves env vars unchanged
 ✓ all 12 thread-count env vars are exported and equal

8 tests, 0 failures
```

- [ ] **Step 5: Commit**

```bash
git add generic/cgroup-threads.sh generic/test/cgroup_threads.bats
git commit -m "feat(image): cgroup-aware thread limiting via affinity mask + env vars"
```

---

### Task 2: Wire up Dockerfile and extend-bashrc.sh

**Files:**
- Modify: `generic/Dockerfile` (insert COPY before the extend-bashrc block)
- Modify: `generic/extend-bashrc.sh` (append source line)

- [ ] **Step 1: Add COPY to Dockerfile**

In `generic/Dockerfile`, insert after the `setup_bash.sh` RUN block and before the `extend-bashrc.sh` block. The diff:

```dockerfile
 COPY setup_bash.sh /tmp/setup_bash.sh
 RUN bash /tmp/setup_bash.sh \
     && rm /tmp/setup_bash.sh

+# Sets CPU affinity + thread-count env vars from CFS quota on every login shell
+# and job runner entry point that uses bash -l / bash --login.
+COPY cgroup-threads.sh /etc/profile.d/cgroup-threads.sh
+
 # Append runtime secret/git glue to /root/.bashrc.
 COPY extend-bashrc.sh /tmp/extend-bashrc.sh
 RUN cat /tmp/extend-bashrc.sh >> /root/.bashrc && rm /tmp/extend-bashrc.sh
```

- [ ] **Step 2: Append source line to extend-bashrc.sh**

Append to the end of `generic/extend-bashrc.sh`:

```bash

# Enforce cgroup CPU quota via affinity mask + thread-count env vars.
# Covers interactive non-login shells; login shells get it via /etc/profile.d/.
# shellcheck source=/etc/profile.d/cgroup-threads.sh
source /etc/profile.d/cgroup-threads.sh
```

- [ ] **Step 3: Commit**

```bash
git add generic/Dockerfile generic/extend-bashrc.sh
git commit -m "feat(image): wire cgroup-threads.sh into Dockerfile and .bashrc"
```
