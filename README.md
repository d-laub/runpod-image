# RunPod images (d-laub)

One repo, multiple **flavors** of RunPod docker images. Each flavor lives in
its own subdirectory with its own `Dockerfile` + supporting scripts. CI matrix
builds GPU and CPU variants of every flavor and pushes them to
`ghcr.io/d-laub/runpod-image:*`.

## Flavors

### [`generic/`](generic) — project-agnostic dev pod

Default image. `:latest` (default-branch alias) / `:gpu` / `:cpu`.

dlaub-togo shell + pixi globals + Claude tooling + RunPod secret wiring
(rclone / aws / wandb / git identity). Ephemeral `HOME=/root` — code lives in
GitHub, not on a volume. Does **not** clone any repo or fetch any data — bring
your own. See [`generic/README.md`](generic/README.md) for template secrets.

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
[`.github/workflows/docker-image.yml`](.github/workflows/docker-image.yml), in
two stages:

1. **`generic`** — builds the base GPU/CPU images and pushes `:latest` / `:gpu`
   / `:cpu` plus an immutable per-commit `:{gpu,cpu}-<sha>` tag.
2. **`flavors`** (`needs: generic`) — each flavor is built `FROM` the matching
   per-commit generic tag, so flavors never re-implement the base.

PRs build but don't push; on a PR the flavors build `FROM` the last `main`
generic image (since this commit's generic isn't pushed). GHA cache is scoped
per `(flavor, variant)`.

## Adding a new flavor (DRY)

Flavors layer on top of generic — don't duplicate the base.

1. Create `<flavor>/` with a `Dockerfile` that starts
   `ARG BASE_IMAGE=ghcr.io/d-laub/runpod-image:gpu` / `FROM ${BASE_IMAGE}`, plus
   only the project-specific layers (see `gvf-germ-som/` as the template).
2. Add two entries (gpu + cpu) to the **`flavors`** matrix in
   `.github/workflows/docker-image.yml`, following `gvf-germ-som` — set
   `from_tag: gpu` / `cpu` so it pins to the right generic variant.
3. Pick tag names that don't collide with `:gpu` / `:cpu` (those belong to
   `generic`). Prefix with the flavor name, e.g. `:my-project-gpu`.
