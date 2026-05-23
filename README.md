# RunPod images (d-laub)

One repo, multiple **flavors** of RunPod docker images. Each flavor lives in
its own subdirectory with its own `Dockerfile` + supporting scripts. CI matrix
builds GPU and CPU variants of every flavor and pushes them to
`ghcr.io/d-laub/runpod-image:*`.

## Flavors

### [`generic/`](generic) — project-agnostic dev pod

Default image. `:latest` (default-branch alias) / `:gpu` / `:cpu`.

dlaub-togo shell + pixi globals + Claude tooling + `HOME=/workspace` + RunPod
secret wiring (rclone / aws / wandb / git identity). Does **not** clone any
repo or fetch any data — bring your own. See
[`generic/README.md`](generic/README.md) for template secrets.

### [`gvf-germ-som/`](gvf-germ-som) — gvf-germ-som development pods

`:gvf-germ-som-gpu` / `:gvf-germ-som-cpu`.

Same generic base, plus an idempotent first-shell bootstrap that clones
[standardmodelbio/gvf-germ-som](https://github.com/standardmodelbio/gvf-germ-som),
runs `pixi install` for the matching CUDA env, `dvc pull` for hg38 + .gvl
data, and rclones the cross-project `mmrf.svar` as a sibling of the `.gvl`
directories. See [`gvf-germ-som/README.md`](gvf-germ-som/README.md).

## Tag matrix

| Flavor          | Variant | Tags                                             |
|-----------------|---------|--------------------------------------------------|
| generic         | GPU     | `latest` (default branch), `gpu`, `gpu-<sha>`    |
| generic         | CPU     | `cpu`, `cpu-<sha>`                               |
| gvf-germ-som    | GPU     | `gvf-germ-som-gpu`, `gvf-germ-som-gpu-<sha>`     |
| gvf-germ-som    | CPU     | `gvf-germ-som-cpu`, `gvf-germ-som-cpu-<sha>`     |

## Build locally

Each flavor has its own build context — the subdirectory IS the docker context:

```bash
# generic GPU
docker build generic/ -t ghcr.io/d-laub/runpod-image:gpu

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

## Adding a new flavor

1. Create `<flavor>/` with its `Dockerfile` and any supporting scripts. Either
   write a self-contained Dockerfile, or `FROM ghcr.io/d-laub/runpod-image:gpu`
   to inherit the generic base.
2. Add two matrix entries (gpu + cpu) to `.github/workflows/docker-image.yml`
   following the pattern of `gvf-germ-som`.
3. Pick tag names that don't collide with `:gpu` / `:cpu` (those belong to
   `generic`). Prefix with the flavor name, e.g. `:my-project-gpu`.
