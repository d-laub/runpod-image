#!/usr/bin/env bash
# First-shell bootstrap for gvf-germ-som on a RunPod pod.
# Idempotent — re-runs cleanly after rm /workspace/.gvf-bootstrapped.
#
# Fetches the project repo, installs the matching pixi env (CUDA-detected on
# GPU image; cpu on CPU image), pulls hg38 + .gvl data via DVC, rclones the
# cross-project mmrf.svar to data/gvl/mmrf.svar, and defensively migrates
# any legacy .gvl link.svar symlinks to the v0.25 metadata.json svar_link.

set -euo pipefail

R2_REMOTE="${R2_REMOTE:-r2-scratch:smb-data-prod-scratch}"
VM_REPO_DIR="${VM_REPO_DIR:-/workspace/gvf-germ-som}"
GITHUB_REPO='d-laub/gvf-germ-som'

log() { printf '[bootstrap-gvf] %s\n' "$*" >&2; }

# 1) Repo
if [[ -d ${VM_REPO_DIR}/.git ]]; then
    log "Repo present; fast-forwarding"
    git -C "${VM_REPO_DIR}" pull --ff-only
else
    log "Cloning ${GITHUB_REPO} -> ${VM_REPO_DIR}"
    mkdir -p "$(dirname "${VM_REPO_DIR}")"
    gh repo clone "${GITHUB_REPO}" "${VM_REPO_DIR}"
fi
cd "${VM_REPO_DIR}"

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

# 6) mmrf.svar — cross-project, not DVC-tracked
log "Pulling mmrf.svar from ${R2_REMOTE}/data/mmrf.svar"
mkdir -p data/gvl
rclone copy "${R2_REMOTE}/data/mmrf.svar" data/gvl/mmrf.svar --transfers 16
[[ -f data/gvl/mmrf.svar/variant_idxs.npy ]] || {
    log "ERROR: mmrf.svar pull incomplete — variant_idxs.npy missing"
    exit 1
}

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
