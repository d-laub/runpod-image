# gvf-germ-som RunPod image

Docker images for RunPod pods that boot directly into a working
`gvf-germ-som` development environment. Two variants from one Dockerfile:

| Variant | Base                                       | Tag                     |
|---------|--------------------------------------------|-------------------------|
| GPU     | `runpod/base:1.0.3-cuda1281-ubuntu2404`    | `latest` / `gpu`        |
| CPU     | `runpod/base:1.0.3-ubuntu2404`             | `cpu`                   |

## What's inside

- **Shell:** oh-my-bash with agnoster-multiline theme, pixi global tools
  (rg, bat, fd, zoxide, dvc, rclone, awscli, uv, wandb, …), Rust toolchain,
  Claude Code + RTK + tilth + superpowers plugin, marimo skills.
- **HOME = `/workspace`:** all dotfiles, caches, and `pixi global install`
  results persist across pod pause/resume via the RunPod network volume.
  Seeded on first login from `/root` template via `/etc/profile.d/`.
- **First-shell bootstrap:** clones `standardmodelbio/gvf-germ-som`,
  installs the matching pixi env (CUDA-detected), `dvc pull` for hg38 +
  `.gvl` data, rclone copy `mmrf.svar` from R2.

## Required RunPod template secrets

| Secret              | Required | Purpose                                        |
|---------------------|----------|------------------------------------------------|
| `GH_TOKEN`          | yes      | Clone private `standardmodelbio/gvf-germ-som`  |
| `R2_SCRATCH_ACCESS` | yes      | R2 access key (rclone / aws / dvc)             |
| `R2_SCRATCH_SECRET` | yes      | R2 secret key                                  |
| `R2_ENDPOINT`       | yes      | R2 endpoint URL                                |
| `WANDB_API_KEY`     | yes*     | wandb run tracking (*optional on CPU dev pods) |
| `GIT_USER_NAME`     | optional | git identity name (gh fallback)                |
| `GIT_USER_EMAIL`    | optional | git identity email (gh fallback)               |

Optional tunables: `R2_REMOTE` (default `r2-scratch:smb-data-prod-scratch`),
`VM_REPO_DIR` (default `/workspace/gvf-germ-som`), `GVF_SKIP_BOOTSTRAP=1`.

## Build locally

```bash
# GPU
docker build -t ghcr.io/standardmodelbio/gvf-germ-som-runpod-image:gpu .

# CPU
docker build \
  --build-arg BASE_IMAGE=runpod/base:1.0.3-ubuntu2404 \
  -t ghcr.io/standardmodelbio/gvf-germ-som-runpod-image:cpu .
```

## CI

Push to `main` builds both variants and pushes to GHCR (see
`.github/workflows/docker-image.yml`).
