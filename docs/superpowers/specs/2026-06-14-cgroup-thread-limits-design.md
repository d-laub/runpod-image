# cgroup-aware thread limiting for the generic RunPod image

**Date:** 2026-06-14  
**Status:** Approved

## Problem

RunPod containers share the host kernel, so `/proc/cpuinfo` and `nproc` report the
host machine's total CPU count rather than the container's CFS quota. Libraries that
auto-detect parallelism (NumPy/BLAS, OpenMP, Rayon, PyTorch, TensorFlow, Julia, etc.)
spawn one thread per visible CPU. When the container is allocated 8 vCPUs but sees 128,
the kernel throttles heavily and performance collapses.

RunPod does not configure this correctly and does not support `lxcfs`.

## Goal

Every process spawned from a covered shell sees the correct CPU count automatically,
without per-script changes. Both Python and non-Python workloads (Rust/Rayon, C++/OpenMP,
Julia) must be covered.

## Solution overview

A canonical shell script (`cgroup-threads.sh`) detects the CFS CPU quota and applies
two complementary limits:

1. **Affinity mask** — `taskset` shrinks the shell's CPU affinity to N cores. All child
   processes inherit it. Fixes anything that calls `sched_getaffinity` to discover
   parallelism: glibc `nproc`, Python `os.sched_getaffinity(0)`, OpenMP on Linux, and
   the `num_cpus` Rust crate (used by Rayon).

2. **Env vars** — belt-and-suspenders for libraries that read env vars before querying
   the kernel: OpenMP, BLAS variants, Rayon, NumExpr, Numba, PyTorch, TensorFlow, Julia.

The script is sourced from two entry points so it covers all common RunPod shell paths.
A guard variable (`_CGROUP_THREADS_APPLIED`) makes double-sourcing a no-op.

## Files changed

### New: `generic/cgroup-threads.sh`

Canonical implementation, installed to `/etc/profile.d/cgroup-threads.sh` in the image.

```
_cgroup_cpu_limit() -> int   # detection function, prints the limit
main block:
  - return early if _CGROUP_THREADS_APPLIED is set
  - call _cgroup_cpu_limit, floor at 1
  - if taskset available: taskset -cp 0-$((N-1)) $$
  - export OMP_NUM_THREADS, OPENBLAS_NUM_THREADS, MKL_NUM_THREADS,
           VECLIB_MAXIMUM_THREADS, BLIS_NUM_THREADS, NUMEXPR_NUM_THREADS,
           NUMBA_NUM_THREADS, RAYON_NUM_THREADS, PYTORCH_OPENMP_THREADS,
           TF_NUM_INTEROP_THREADS, TF_NUM_INTRAOP_THREADS, JULIA_NUM_THREADS
  - export _CGROUP_THREADS_APPLIED=1
```

Detection order:
1. cgroup v2: `/sys/fs/cgroup/cpu.max` — read quota and period; skip if quota is `max`
2. cgroup v1: `/sys/fs/cgroup/cpu/cpu.cfs_quota_us` and `cpu.cfs_period_us`; skip if quota is `-1`
3. Fallback: `nproc` (no CFS limit configured)

### Modified: `generic/Dockerfile`

Add before the `extend-bashrc.sh` step:

```dockerfile
COPY cgroup-threads.sh /etc/profile.d/cgroup-threads.sh
```

This covers login shells and job runners using `bash -l` / `bash --login`.

### Modified: `generic/extend-bashrc.sh`

Append one line:

```bash
source /etc/profile.d/cgroup-threads.sh
```

This covers interactive non-login shells (the typical SSH terminal session), where
`/etc/profile.d/` is not re-sourced. The guard makes it safe.

## Coverage matrix

| Entry point | Mechanism |
|---|---|
| SSH interactive session | `.bashrc` → `source /etc/profile.d/cgroup-threads.sh` |
| Login shell (`bash -l`, `bash --login`) | `/etc/profile.d/cgroup-threads.sh` |
| RunPod job runner (login shell) | `/etc/profile.d/cgroup-threads.sh` |
| Subshells of any covered shell | Inherits affinity mask + exported env vars |
| Bare `bash script.sh` (non-login, non-interactive) | Not covered — requires project-specific ENTRYPOINT |

The last gap is intentional and out of scope for the generic image.

## Error handling

- `taskset` absence: the affinity block is wrapped in `command -v taskset` guard; env
  vars still apply.
- No cgroup files: fallback to `nproc` (honest — no limit configured).
- Quota of `max` / `-1`: treated as no limit, falls through to next detection level or
  `nproc`.
- Result floored at 1 to prevent `taskset -cp 0--1 $$`.
