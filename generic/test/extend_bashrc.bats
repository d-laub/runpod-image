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

# dlaub-togo's .bashrc sets `alias mkdir='mkdir -pv'` and `noclobber`, and
# aliases expand inside .bashrc. `mkdir -p` never fails, which used to defeat
# the once-per-boot lock: every shell re-ran the install (blocked only by
# noclobber refusing to overwrite the log, with an error on every shell).
@test "deferred skills run once per boot under dlaub-togo's mkdir alias and noclobber" {
    mkdir -p "$TMPD/.local/share/runpod-image"
    echo "echo ran >> '$TMPD/runs'" > "$TMPD/.local/share/runpod-image/deferred-skills.sh"
    for _ in 1 2 3; do
        env -i PATH=/usr/bin:/bin HOME="$TMPD" GITHUB_TOKEN=x \
            _RP_ENVIRONMENT=/nonexistent _CGROUP_THREADS_APPLIED=1 \
            bash --norc --noprofile -c "
                shopt -s expand_aliases; alias mkdir='mkdir -pv'; set -o noclobber
                source '$SCRIPT'" 2>> "$TMPD/stderr" || true
    done
    sleep 1   # the install runs in the background
    [ "$(wc -l < "$TMPD/runs")" -eq 1 ]
    ! grep -q 'cannot overwrite' "$TMPD/stderr"
}
