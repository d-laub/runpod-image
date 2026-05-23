# /etc/profile.d/00-seed-home.sh
# Seed /workspace from the /root template on first login. Runs before
# ~/.bashrc is read by any login shell (sshd default, RunPod web terminal).
# Idempotent: a sentinel file at /workspace/.home-seeded blocks re-runs.
# `rsync --ignore-existing` preserves user edits across pause/resume.

if [ ! -f /workspace/.home-seeded ]; then
    if command -v rsync >/dev/null 2>&1; then
        # rsync silences errors — /root/ and /workspace/ are container-managed and assumed reliable
        rsync -a --ignore-existing /root/ /workspace/ 2>/dev/null || true
    fi
    touch /workspace/.home-seeded
fi
