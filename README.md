# RunPod images (d-laub)

One repo, multiple **flavors** of RunPod docker images. Each flavor lives in its
own subdirectory with its own `Dockerfile` + supporting scripts. CI matrix
builds GPU and CPU variants of every flavor and pushes them to
`ghcr.io/d-laub/runpod-image:*`.

## Flavors

### `dlaub-togo/` — generic shell + pixi base

[`dlaub-togo/Dockerfile`](dlaub-togo/Dockerfile). Interactive bash setup from
[d-laub/dlaub-togo](https://github.com/d-laub/dlaub-togo): Oh My Bash with
agnoster-multiline theme, pixi global tools, aliases, zoxide.

| Variant | Base image                                | Tag(s)                           |
|---------|-------------------------------------------|----------------------------------|
| GPU     | `runpod/base:1.0.3-cuda1281-ubuntu2404`   | `latest` (default branch), `gpu` |
| CPU     | `runpod/base:1.0.3-ubuntu2404`            | `cpu`                            |

### `gvf-germ-som/` — gvf-germ-som development pods

[`gvf-germ-som/Dockerfile`](gvf-germ-som/Dockerfile). Project-specific bootstrap
on top of the generic base: `usermod` via direct `/etc/passwd` edit, first-login
seed of `/root` → `/workspace`, and an idempotent `bootstrap-gvf.sh` that clones
[standardmodelbio/gvf-germ-som](https://github.com/standardmodelbio/gvf-germ-som),
runs `pixi install`, `dvc pull`, and rclones `mmrf.svar`. See
[`gvf-germ-som/README.md`](gvf-germ-som/README.md) for required RunPod template
secrets.

| Variant | Base image                                | Tag(s)                           |
|---------|-------------------------------------------|----------------------------------|
| GPU     | `runpod/base:1.0.3-cuda1281-ubuntu2404`   | `gvf-germ-som-gpu`               |
| CPU     | `runpod/base:1.0.3-ubuntu2404`            | `gvf-germ-som-cpu`               |

Per-flavor commit SHAs are also tagged (`gpu-<sha>`, `cpu-<sha>`,
`gvf-germ-som-gpu-<sha>`, `gvf-germ-som-cpu-<sha>`) for reproducible pin-back.

## Build locally

Each flavor has its own build context — the subdirectory is the docker context:

```bash
# dlaub-togo GPU
docker build dlaub-togo/ -t ghcr.io/d-laub/runpod-image:gpu

# gvf-germ-som CPU
docker build \
  --build-arg BASE_IMAGE=runpod/base:1.0.3-ubuntu2404 \
  -t ghcr.io/d-laub/runpod-image:gvf-germ-som-cpu \
  gvf-germ-som/
```

## CI

Pushes to `main` / `master` trigger
[`.github/workflows/docker-image.yml`](.github/workflows/docker-image.yml).
Matrix: 4 jobs (2 flavors × 2 variants). PRs build but don't push. GHA cache is
scoped per `(flavor, variant)`.

## Use on RunPod

Pick a tag and reference it in a RunPod template. Mount the volume at
`/workspace` (the gvf-germ-som flavor depends on this).
