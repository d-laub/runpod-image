#!/usr/bin/env bash
# First-shell bootstrap for gvf-germ-som on a RunPod pod.
# Idempotent — re-runs cleanly after rm /root/.gvf-bootstrapped.
#
# Persistence model: code is EPHEMERAL on /root (re-cloned from GitHub each
# boot); only large data persists on the /workspace network volume. We do NOT
# symlink the repo's data/ dir wholesale — it holds git-tracked *.dvc files, so
# replacing it with a symlink would make git see them as deleted. Instead the
# DVC cache lives on the volume (DATA_VOL/dvc-cache) with cache.type=symlink, so
# `dvc checkout` materializes data/ as symlinks into the persisted cache: the
# heavy bytes live once on /workspace, the tracked .dvc files stay put. The
# non-DVC mmrf.svar is rclone'd onto the volume and symlinked into data/gvl.
#
# Steps: fetch repo, install the matching pixi env (CUDA-detected on GPU image;
# cpu on CPU image), pull hg38 + .gvl data via DVC, place mmrf.svar, and
# defensively migrate any legacy .gvl link.svar symlinks to the v0.25 svar_link.

set -euo pipefail

R2_REMOTE="${R2_REMOTE:-r2-scratch:smb-data-prod-scratch}"
VM_REPO_DIR="${VM_REPO_DIR:-/root/gvf-germ-som}"
DATA_VOL="${DATA_VOL:-/workspace/gvf-germ-som}"   # persistent volume root
DVC_CACHE="${DATA_VOL}/dvc-cache"
GITHUB_REPO='d-laub/gvf-germ-som'

log() { printf '[bootstrap-gvf] %s\n' "$*" >&2; }

# 1) Repo (on ephemeral /root — clone fresh, or fast-forward if still present)
if [[ -d ${VM_REPO_DIR}/.git ]]; then
    log "Repo present; fast-forwarding"
    git -C "${VM_REPO_DIR}" pull --ff-only
else
    log "Cloning ${GITHUB_REPO} -> ${VM_REPO_DIR}"
    mkdir -p "$(dirname "${VM_REPO_DIR}")"
    gh repo clone "${GITHUB_REPO}" "${VM_REPO_DIR}"
fi
cd "${VM_REPO_DIR}"
log "Initializing submodules"
git submodule update --init --recursive

# 1b) Point DVC's cache at the volume so pulled data persists across pods.
# --local writes .dvc/config.local (gitignored) → repo stays clean. symlink
# cache type keeps the bytes only in the volume cache; data/ files become
# symlinks into it. Re-applied every boot since the repo is re-cloned.
log "Pointing DVC cache at ${DVC_CACHE} (symlink checkout)"
mkdir -p "${DVC_CACHE}"
dvc cache dir --local "${DVC_CACHE}"
dvc config --local cache.type "symlink,reflink,copy"
dvc config --local cache.shared group

# 2) Detect CUDA → pick PIXI_ENV
detect_pixi_env() {
    # CPU image: nvidia-smi absent
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo "cpu"
        return 0
    fi
    local cuda
    cuda="$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n1)"
    case "${cuda}" in
        12.6) echo "cu126" ;;
        12.8) echo "cu128" ;;
        13.0) echo "cu130" ;;
        *)
            log "Unsupported CUDA: ${cuda:-<unknown>}; need 12.6, 12.8, or 13.0"
            return 1
            ;;
    esac
}
PIXI_ENV="$(detect_pixi_env)" || exit 1
log "Selected pixi env: ${PIXI_ENV}"

# 3) Pixi install
pixi install -e "${PIXI_ENV}"

# 4) GPU: torch CUDA sanity check
if [[ ${PIXI_ENV} != cpu ]]; then
    pixi run -e "${PIXI_ENV}" -- python - <<'PY'
import sys
import torch
if not torch.cuda.is_available():
    sys.exit("torch.cuda.is_available() is False")
print(f"torch CUDA OK: device 0 = {torch.cuda.get_device_name(0)!r}, torch CUDA = {torch.version.cuda}")
PY
fi

# 5) DVC pull (hg38 + data/gvl/*.gvl)
log "dvc pull (hg38 + data/gvl)"
dvc pull

# 6) mmrf.svar — cross-project, not DVC-tracked, gitignored. Lives on the
# volume and is symlinked into data/gvl so it persists without re-downloading.
log "Pulling mmrf.svar from ${R2_REMOTE}/data/mmrf.svar"
mmrf_vol="${DATA_VOL}/data/gvl/mmrf.svar"
mkdir -p "${mmrf_vol}" data/gvl
rclone copy "${R2_REMOTE}/data/mmrf.svar" "${mmrf_vol}" --transfers 16
[[ -f ${mmrf_vol}/variant_idxs.npy ]] || {
    log "ERROR: mmrf.svar pull incomplete — variant_idxs.npy missing"
    exit 1
}
# Link it in (replace any stale non-symlink left from an older layout).
[[ -e data/gvl/mmrf.svar && ! -L data/gvl/mmrf.svar ]] && rm -rf data/gvl/mmrf.svar
ln -sfn "${mmrf_vol}" data/gvl/mmrf.svar

# 7) Defensive: migrate any pre-v0.25 .gvl that slipped through
if [[ -f scripts/oneshot/migrate_gvl_links.py ]]; then
    shopt -s nullglob
    gvl_dirs=(data/gvl/*.gvl)
    shopt -u nullglob
    if (( ${#gvl_dirs[@]} > 0 )); then
        log "Defensive svar_link migration on ${#gvl_dirs[@]} .gvl dirs"
        pixi run -e "${PIXI_ENV}" -- python scripts/oneshot/migrate_gvl_links.py "${gvl_dirs[@]}" || true
    fi
fi

log "Bootstrap complete."
