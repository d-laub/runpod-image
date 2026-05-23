# Load RunPod environment variables if not already set (normally appended at end of ~/.bashrc)
if [[ -f /etc/rp_environment ]]; then
    source /etc/rp_environment
fi

# Configure git to use GitHub CLI for HTTPS (private repos)
gh auth setup-git

# Configure rclone r2-scratch remote from env vars
if [[ -n ${R2_SCRATCH_ACCESS:-} ]] && [[ -n ${R2_SCRATCH_SECRET:-} ]] && [[ -n ${R2_ENDPOINT:-} ]] && [[ ! -f ~/.config/rclone/rclone.conf ]]; then
    rclone config create r2-scratch s3 \
        provider=Cloudflare \
        access_key_id="$R2_SCRATCH_ACCESS" \
        secret_access_key="$R2_SCRATCH_SECRET" \
        endpoint="$R2_ENDPOINT" \
        acl=private
fi

# Configure AWS CLI profile for r2-scratch
if [[ -n ${R2_SCRATCH_ACCESS:-} ]] && [[ -n ${R2_SCRATCH_SECRET:-} ]] && [[ ! -f ~/.aws/credentials ]]; then
    aws configure set aws_access_key_id "$R2_SCRATCH_ACCESS" --profile r2-scratch
    aws configure set aws_secret_access_key "$R2_SCRATCH_SECRET" --profile r2-scratch
    aws configure set region auto --profile r2-scratch
fi

# Configure Weights & Biases API key from env var
if [[ -n ${WANDB_API_KEY:-} ]] && [[ ! -f ~/.netrc ]]; then
    wandb login --relogin "$WANDB_API_KEY"
fi
