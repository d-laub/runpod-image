# Working on this pod (RunPod or CoreWeave)

This pod runs from a prebuilt Docker image (`ghcr.io/d-laub/runpod-image`).
Understand the filesystem model before you store anything.

## Filesystem & persistence

- **`HOME` is `/root`, on the container filesystem. It is EPHEMERAL.** Everything
  under `/root` — your shell history, installed packages, `pixi`/`cargo`/`rattler`
  caches, Claude config, scratch files — is **wiped when the pod is stopped,
  restarted, or the image is redeployed.** Do not assume anything here survives.
- **There is no implicit persistence.** Earlier images made `/root` live on a
  network volume; that is gone. Nothing you create is automatically saved.
- **Persist code by committing and pushing to GitHub.** That is the only durable
  store for source. Clone fresh each session; commit early and often. If a pod is
  about to be torn down, push first or the work is lost.
- **Caches are baked into the image** under `/root` (pixi globals at
  `/root/.pixi`, rattler cache, cargo). They are rebuildable — never try to
  persist or back them up.

## Large data (only when a volume is attached)

Some pods attach a **volume at `/workspace`** (a RunPod network volume, or a
CoreWeave PVC) purely for large, expensive-to-refetch data (datasets, model
weights, DVC artifacts). The generic image itself does **not** use `/workspace`
— don't write there unless the project image or pod spec set it up.

When a project does use it, the pattern is: real data lives under
`/workspace/<project>/…` and is **symlinked into the working tree** (e.g.
`/root/<project>/data` → `/workspace/<project>/data`, or the DVC cache onto the
volume). Code stays on `/root` (git), only the heavy bytes live on the volume.

## Practical rules

- Treat the pod as disposable. Reproduce state from git + the image, not from
  whatever happens to be on disk.
- Before stopping a pod: `git status` / `git push` anything you care about.
- Don't put credentials or generated config anywhere expecting it to persist —
  RunPod template secrets (or the CoreWeave `runpod-image-secrets` Secret) are
  re-injected and re-wired into `/root` on every boot.
