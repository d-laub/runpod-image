# RunPod image: dlaub-togo shell + pixi

Two flavors from the same [`Dockerfile`](Dockerfile), differing only in the RunPod base image:

| Variant | Base image | Typical use |
|--------|------------|-------------|
| **GPU** (default) | [`runpod/base:1.0.3-cuda1281-ubuntu2404`](https://hub.docker.com/r/runpod/base) | GPU pods |
| **CPU** | [`runpod/base:1.0.3-ubuntu2404`](https://hub.docker.com/r/runpod/base) | CPU / Linux VM development |

Both include the same interactive bash setup as [d-laub/dlaub-togo](https://github.com/d-laub/dlaub-togo):

- [Oh My Bash](https://github.com/ohmybash/oh-my-bash) (`--unattended` for image builds)
- Custom **agnoster-multiline** theme from dlaub-togo
- [Pixi](https://pixi.sh) global tools
- Aliases from `aliases.sh` and `eval "$(zoxide init bash)"` in `~/.bashrc`

`PATH` includes `/root/.pixi/bin` for non-login sessions.

## Build locally

**GPU** (default):

```bash
docker build -t your-registry/runpod-dlaub-togo:latest .
```

**CPU** (same layers, different base):

```bash
docker build \
  --build-arg BASE_IMAGE=runpod/base:1.0.3-ubuntu2404 \
  -t your-registry/runpod-dlaub-togo:cpu .
```

## CI (GitHub Actions)

On push to **`main`** or **`master`**, [`.github/workflows/docker-image.yml`](.github/workflows/docker-image.yml) builds **both** variants and pushes to **GHCR**:

- **GPU:** `latest` and `gpu` on the default branch, plus branch name and `gpu-<sha>`
- **CPU:** `cpu`, plus branch name and `cpu-<sha>`

Pull requests run both builds without pushing.

The workflow uses the default `GITHUB_TOKEN` with `packages: write`. The first time, open the package under **GitHub → Packages → container → Package settings** and set **Change visibility** to **Public** if you want anonymous pulls.

## Use on RunPod

Push the image, then create a template/pod that references it. Mount volumes at `/workspace` if you use the default workdir.
