# /etc/profile.d/00-seed-home.sh
# Seed /workspace from the /root template on first login. Runs before
# ~/.bashrc is read by any login shell (sshd default, RunPod web terminal).
# Idempotent: a sentinel file at /workspace/.home-seeded blocks re-runs.
# `rsync --ignore-existing` preserves user edits across pause/resume.

if [ ! -f /workspace/.home-seeded ]; then
    # RunPod's pod-startup writes a stub /workspace/.bashrc containing just
    # `source /etc/rp_environment` BEFORE this script runs. Without removing
    # it, rsync's --ignore-existing keeps the stub and our oh-my-bash setup
    # never lands. Detect (< 5 lines AND mentions rp_environment) and remove.
    if [ -f /workspace/.bashrc ] \
        && [ "$(wc -l < /workspace/.bashrc 2>/dev/null || echo 99)" -lt 5 ] \
        && grep -q 'rp_environment' /workspace/.bashrc 2>/dev/null; then
        rm -f /workspace/.bashrc
    fi
    if command -v rsync >/dev/null 2>&1; then
        # rsync silences errors — /root/ and /workspace/ are container-managed and assumed reliable
        rsync -a --ignore-existing /root/ /workspace/ 2>/dev/null || true
    fi
    touch /workspace/.home-seeded
fi
