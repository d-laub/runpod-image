# Appended to the generic base image's /root/.bashrc at build time. Adds ONLY
# the gvf-germ-som first-shell bootstrap trigger; runs on every interactive
# shell. The secret/git/rclone/aws/wandb wiring is provided by the generic base.

# First-shell project bootstrap (heavy: clones repo, pixi install, dvc pull).
# Sentinel lives on /root (ephemeral): code is re-cloned on every fresh
# container, so the bootstrap must re-run each boot. It's idempotent and cheap
# on resume — git pull, dvc checkout from the persisted /workspace cache, and
# rclone skips data already on the volume.
if [[ ! -f /root/.gvf-bootstrapped && -z "${GVF_SKIP_BOOTSTRAP:-}" ]]; then
    if [[ -x /usr/local/bin/bootstrap-gvf.sh ]]; then
        # PIPESTATUS preserves bootstrap exit code through `tee`; without it,
        # tee's success would mask a bootstrap failure and the sentinel would
        # be touched even when the bootstrap broke.
        /usr/local/bin/bootstrap-gvf.sh 2>&1 | tee -a /root/.gvf-bootstrap.log
        if (( ${PIPESTATUS[0]} == 0 )); then
            touch /root/.gvf-bootstrapped
        fi
    fi
fi
