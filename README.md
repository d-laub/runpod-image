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

| Flavor          | Variant | Moving tags                      | Immutable tag                     |
|-----------------|---------|----------------------------------|-----------------------------------|
| generic         | GPU     | `latest` (default branch), `gpu` | `gpu-<build_id>`                  |
| generic         | CPU     | `cpu`                            | `cpu-<build_id>`                  |
| gvf-germ-som    | GPU     | `gvf-germ-som-gpu`               | `gvf-germ-som-gpu-<build_id>`     |
| gvf-germ-som    | CPU     | `gvf-germ-som-cpu`               | `gvf-germ-som-cpu-<build_id>`     |

`build_id` is `<repo-sha7>-t<dlaub-togo-sha7>` — it names **both** inputs that
determine image content. That is what keeps the tag immutable: because upstream
`dlaub-togo` can trigger a rebuild of an unchanged repo commit (see
[CI](#ci)), a tag keyed on the repo SHA alone would silently change content
under anyone who pinned it.

Branch pushes also publish `<branch>-gpu` / `<branch>-cpu`.

## Build locally

Each flavor has its own build context — the subdirectory IS the docker context:

```bash
# generic GPU
docker build generic/ -t ghcr.io/d-laub/runpod-image:gpu

# generic GPU, pinned to a specific upstream shell-env commit
docker build \
  --build-arg DLAUB_TOGO_REF=<dlaub-togo-sha> \
  -t ghcr.io/d-laub/runpod-image:gpu \
  generic/

# gvf-germ-som CPU
docker build \
  --build-arg BASE_IMAGE=runpod/base:1.0.3-ubuntu2404 \
  -t ghcr.io/d-laub/runpod-image:gvf-germ-som-cpu \
  gvf-germ-som/
```

`DLAUB_TOGO_REF` defaults to `main` locally; CI always pins a resolved SHA.

## CI

[`.github/workflows/docker-image.yml`](.github/workflows/docker-image.yml) runs
in three stages:

1. **`resolve`** — resolves `d-laub/dlaub-togo@main` to a commit SHA and derives
   `build_id`. On a *scheduled* run it also probes GHCR for
   `:{gpu,cpu}-<build_id>`; if both already exist, nothing upstream moved and
   every later stage is skipped.
2. **`generic`** — builds the base GPU/CPU images and pushes `:latest` / `:gpu`
   / `:cpu` plus the immutable `:{gpu,cpu}-<build_id>` tag. The resolved
   upstream SHA is passed as the `DLAUB_TOGO_REF` build-arg.
3. **`flavors`** (`needs: generic`) — each flavor is built `FROM` the matching
   per-build generic tag, so flavors never re-implement the base.

PRs build but don't push; on a PR the flavors build `FROM` the last `main`
generic image (since this commit's generic isn't pushed). GHA cache is scoped
per `(flavor, variant)`.

### Rebuilding when the shell environment changes

The generic image installs [`d-laub/dlaub-togo`](https://github.com/d-laub/dlaub-togo)
at build time, so upstream commits must reach the published images. Two triggers
cover this:

- **Daily `schedule`** — always active, no credentials needed. Cheap: when
  upstream is unchanged the `resolve` probe short-circuits the whole run.
- **`repository_dispatch` (`dlaub-togo-updated`)** — the instant path, fired by
  `.github/workflows/notify-runpod-image.yml` in `dlaub-togo`. That workflow
  no-ops until the `RUNPOD_IMAGE_DISPATCH_TOKEN` secret (a PAT with `repo`
  scope on this repo) is set in `dlaub-togo`; `GITHUB_TOKEN` cannot dispatch
  across repos.

Triggering alone is not enough — the install is a single `RUN` layer, so without
`DLAUB_TOGO_REF` in the cache key a "rebuild" would restore the stale layer and
republish the old shell environment. Pinning the SHA is what makes the rebuild
real.

## Adding a new flavor (DRY)

Flavors layer on top of generic — don't duplicate the base.

1. Create `<flavor>/` with a `Dockerfile` that starts
   `ARG BASE_IMAGE=ghcr.io/d-laub/runpod-image:gpu` / `FROM ${BASE_IMAGE}`, plus
   only the project-specific layers (see `gvf-germ-som/` as the template).
2. Add the directory name to the `flavor` list in the **`flavors`** matrix in
   `.github/workflows/docker-image.yml`. The directory name is both the build
   context and the tag prefix, and both variants are generated for you.
3. Pick a directory name that doesn't collide with `:gpu` / `:cpu` (those belong
   to `generic`), e.g. `my-project/` → `:my-project-gpu`.
