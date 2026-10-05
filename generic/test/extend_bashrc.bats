#!/usr/bin/env bats

# extend-bashrc.sh is appended to /root/.bashrc AFTER the dlaub-togo PATH setup.
# /etc/rp_environment (written by the base image's /start.sh) is a dump of the
# container env, PATH included, so sourcing it must not clobber that setup.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/extend-bashrc.sh"

setup() {
    TMPD="$(mktemp -d)"
    cat > "$TMPD/rp_environment" <<'EOF'
export PATH="/usr/bin:/bin"
export WANDB_PROJECT="from-secret"
EOF
}

teardown() {
    rm -rf "$TMPD"
}

# Source the script in a clean shell whose PATH was already extended the way
# .bashrc extends it, then print the requested variable.
_run() {
    env -i \
        PATH="/root/.local/bin:/usr/bin:/bin" \
        HOME="$TMPD" \
        _RP_ENVIRONMENT="$TMPD/rp_environment" \
        _CGROUP_THREADS_APPLIED=1 \
        bash --norc --noprofile -c "source '$SCRIPT' 2>/dev/null; printf '%s' \"\$$1\""
}

@test "rp_environment does not clobber PATH set earlier in .bashrc" {
    result=$(_run PATH)
    [ "$result" = "/root/.local/bin:/usr/bin:/bin" ]
}

@test "rp_environment still exports secret env vars" {
    result=$(_run WANDB_PROJECT)
    [ "$result" = "from-secret" ]
}
