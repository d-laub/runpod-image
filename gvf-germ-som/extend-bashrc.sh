# Appended to /root/.bashrc at build time; seeded to /workspace/.bashrc on
# first login by /etc/profile.d/00-seed-home.sh. Runs on every shell.

# Load RunPod-injected env vars (rp_environment exports the template secrets)
if [[ -f /etc/rp_environment ]]; then
    source /etc/rp_environment
fi

# Configure git over HTTPS using gh-resolved GH_TOKEN
if command -v gh >/dev/null 2>&1 && [[ -n ${GH_TOKEN:-} ]]; then
    gh auth setup-git 2>/dev/null || true
fi

# Runtime git identity: prefer GIT_USER_* secrets, fall back to gh-resolved
_set_git_identity() {
    local name="${GIT_USER_NAME:-}"
    local email="${GIT_USER_EMAIL:-}"
    if [[ -z $name || -z $email ]] && command -v gh >/dev/null 2>&1 && [[ -n ${GH_TOKEN:-} ]]; then
        name="${name:-$(gh api user --jq .name 2>/dev/null || true)}"
        email="${email:-$(gh api user --jq .email 2>/dev/null || true)}"
    fi
    [[ -n $name ]]  && git config --global user.name  "$name"
    [[ -n $email ]] && git config --global user.email "$email"
}
_set_git_identity

# Configure rclone r2-scratch remote (idempotent — skip if config already exists)
if [[ -n ${R2_SCRATCH_ACCESS:-} && -n ${R2_SCRATCH_SECRET:-} && -n ${R2_ENDPOINT:-} && ! -f ${HOME}/.config/rclone/rclone.conf ]]; then
    rclone config create r2-scratch s3 \
        provider=Cloudflare \
        access_key_id="$R2_SCRATCH_ACCESS" \
        secret_access_key="$R2_SCRATCH_SECRET" \
        endpoint="$R2_ENDPOINT" \
        acl=private >/dev/null
fi

# Configure AWS profiles: r2-scratch (named) + default (for DVC s3:// remote)
if [[ -n ${R2_SCRATCH_ACCESS:-} && -n ${R2_SCRATCH_SECRET:-} && ! -f ${HOME}/.aws/credentials ]]; then
    aws configure set aws_access_key_id     "$R2_SCRATCH_ACCESS" --profile r2-scratch
    aws configure set aws_secret_access_key "$R2_SCRATCH_SECRET" --profile r2-scratch
    aws configure set region auto                                 --profile r2-scratch
    # default profile so DVC (which reads default) works without project config changes
    aws configure set aws_access_key_id     "$R2_SCRATCH_ACCESS"
    aws configure set aws_secret_access_key "$R2_SCRATCH_SECRET"
    aws configure set region auto
fi

# wandb (creates ~/.netrc on first login)
if [[ -n ${WANDB_API_KEY:-} && ! -f ${HOME}/.netrc ]] && command -v wandb >/dev/null 2>&1; then
    wandb login --relogin "$WANDB_API_KEY" >/dev/null 2>&1 || true
fi

# First-shell project bootstrap (heavy: clones repo, pixi install, dvc pull)
if [[ ! -f /workspace/.gvf-bootstrapped && -z "${GVF_SKIP_BOOTSTRAP:-}" ]]; then
    if [[ -x /usr/local/bin/bootstrap-gvf.sh ]]; then
        /usr/local/bin/bootstrap-gvf.sh 2>&1 | tee -a /workspace/.gvf-bootstrap.log \
            && touch /workspace/.gvf-bootstrapped
    fi
fi
