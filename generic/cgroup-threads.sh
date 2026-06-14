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

[ -n "$BASH_VERSION" ] || return 0

[[ -n ${_CGROUP_THREADS_APPLIED:-} ]] && return 0

_cgroup_cpu_limit() {
    local v2="${_CGROUP_V2_CPU_MAX:-/sys/fs/cgroup/cpu.max}"
    local v1q="${_CGROUP_V1_QUOTA:-/sys/fs/cgroup/cpu/cpu.cfs_quota_us}"
    local v1p="${_CGROUP_V1_PERIOD:-/sys/fs/cgroup/cpu/cpu.cfs_period_us}"
    local quota period

    if [[ -f $v2 ]]; then
        read -r quota period < "$v2"
        if [[ $quota != max ]]; then
            echo $(( (quota + period - 1) / period ))
            return
        fi
    fi

    if [[ -f $v1q && -f $v1p ]]; then
        quota=$(< "$v1q")
        period=$(< "$v1p")
        if (( quota > 0 )); then
            echo $(( (quota + period - 1) / period ))
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
