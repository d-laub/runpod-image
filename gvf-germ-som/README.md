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
- **HOME = `/root` (ephemeral).** Code and shell state are not persisted; the
  repo is re-cloned from GitHub on each boot. Only large **data** persists, on
  the RunPod network volume at `/workspace/gvf-germ-som` (the DVC cache + the
  rclone'd `mmrf.svar`), symlinked into the working tree. See the shipped
  `/root/.claude/CLAUDE.md`.
- **First-shell bootstrap:** clones `d-laub/gvf-germ-som` to
  `/root/gvf-germ-som`, installs the matching pixi env (CUDA-detected), points
  the DVC cache at the volume and `dvc pull`s hg38 + `.gvl` data (symlink
  checkout), and rclones `mmrf.svar` from R2 onto the volume.

## Required RunPod template secrets

| Secret              | Required | Purpose                                        |
|---------------------|----------|------------------------------------------------|
| `GITHUB_TOKEN`          | yes      | Clone private `standardmodelbio/gvf-germ-som`  |
| `R2_SCRATCH_ACCESS` | yes      | R2 access key (rclone / aws / dvc)             |
| `R2_SCRATCH_SECRET` | yes      | R2 secret key                                  |
| `R2_ENDPOINT`       | yes      | R2 endpoint URL                                |
| `WANDB_API_KEY`     | yes*     | wandb run tracking (*optional on CPU dev pods) |
| `GIT_USER_NAME`     | optional | git identity name (gh fallback)                |
| `GIT_USER_EMAIL`    | optional | git identity email (gh fallback)               |

Optional tunables: `R2_REMOTE` (default `r2-scratch:smb-data-prod-scratch`),
`VM_REPO_DIR` (default `/root/gvf-germ-som`), `DATA_VOL` (volume root, default
`/workspace/gvf-germ-som`), `GVF_SKIP_BOOTSTRAP=1`.

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
