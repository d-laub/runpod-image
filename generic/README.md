# generic — project-agnostic RunPod dev image

The base `d-laub/runpod-image:latest` / `:gpu` / `:cpu`. Includes:

- dlaub-togo bash setup (oh-my-bash + agnoster-multiline theme + zellij config)
- pixi global tools (rg, bat, fd, zoxide, dvc, dvc-s3, rclone, awscli, uv, wandb, …)
- Rust toolchain (`cargo`, `cargo-binstall`, `cargo-update`)
- Claude Code + RTK + superpowers plugin + tilth + marimo + RunPod / SeqPro / genoray / GenVarLoader skills
- `HOME=/root` on the container filesystem — **ephemeral**, wiped on pod stop/redeploy. No network-volume persistence: code is git-tracked and pushed to GitHub, caches are baked into the image, and only large data (project images) lives on a volume via an explicit symlink. See `/root/.claude/CLAUDE.md` (shipped in the image) for the pattern.
- SSH pubkey auth fixed up by `post-start.sh` (normalizes RunPod's single-line `$PUBLIC_KEY` into one key per line at a `StrictModes`-safe path)
- Runtime config of rclone / aws (both `r2-scratch` and default profiles) / wandb / git identity from RunPod template secrets (re-wired into `/root` on every boot)

What it does **not** do: clone any project repo, pull any data. Bring your own. If you want a project-specific bootstrap (clone repo, `pixi install`, `dvc pull`, rclone-data-down), use one of the project-specific flavors (e.g. `gvf-germ-som-{gpu,cpu}`) or fork this one.

## RunPod template secrets

All optional — the image runs fine without any of them, just with the corresponding feature inert.

| Secret              | Purpose                                                    |
|---------------------|------------------------------------------------------------|
| `GITHUB_TOKEN`          | `gh auth setup-git` for private repo access over HTTPS     |
| `R2_SCRATCH_ACCESS` | R2 access key — used by rclone / aws CLI / dvc-s3          |
| `R2_SCRATCH_SECRET` | R2 secret key                                              |
| `R2_ENDPOINT`       | R2 endpoint URL (e.g. `https://<account>.r2.cloudflarestorage.com`) |
| `WANDB_API_KEY`     | `wandb login` for run tracking                             |
| `GIT_USER_NAME`     | `git config --global user.name`; falls back to `gh api user .name` |
| `GIT_USER_EMAIL`    | `git config --global user.email`; falls back to `gh api user .email` |

## Build locally

```bash
# GPU
docker build generic/ -t ghcr.io/d-laub/runpod-image:gpu

# CPU
docker build \
  --build-arg BASE_IMAGE=runpod/base:1.0.3-ubuntu2404 \
  -t ghcr.io/d-laub/runpod-image:cpu \
  generic/
```

## Use on RunPod

Reference the image in a RunPod template:

- `ghcr.io/d-laub/runpod-image:latest` (= `:gpu` on the default branch)
- `ghcr.io/d-laub/runpod-image:gpu`
- `ghcr.io/d-laub/runpod-image:cpu`

No network volume is needed — `HOME=/root` is ephemeral by design. Push code to
GitHub before stopping a pod; nothing on disk survives a stop/redeploy.
