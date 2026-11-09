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
CoreWeave PVC). It is **small relative to the node's local disk** — typically
1 TiB against the ~7 TiB on `/` — it is **shared by every session on the pod**,
and a full volume breaks all of them. The generic image itself does **not** use
`/workspace` — don't write there unless the project image or pod spec set it up.

**What belongs on the volume:** bytes that have no other copy and are expensive
to reproduce — checkpoints you are still writing, a dataset with no remote
mirror, a licensed download you can't re-fetch.

**What does not:**

- **A DVC cache.** The DVC remote (R2) is the durable copy, so the cache is
  reconstructible by definition. Keep it on the ephemeral local disk —
  `dvc cache dir --local /root/dvc-cache` — and re-fetch after a restart. A cache
  on the volume buys nothing and is the easiest way to fill it.
- **Project checkouts, git worktrees, or `.pixi` environments.** Code belongs on
  `/root`, from git; an env belongs wherever `pixi install` puts it. A worktree on
  the volume carries its own materialized DVC outputs *and* its own env, so the
  heavy bytes multiply per worktree. (A 1 TiB volume reached 94% full this way:
  four abandoned worktrees of one stale checkout held 394 GiB between them, all
  of it re-derivable from R2.)
- **Scratch.** The volume is not overflow space for intermediates.

When a project does use it, the pattern is: real data lives under
`/workspace/<project>/…` and is **symlinked into the working tree** (e.g.
`/root/<project>/data` → `/workspace/<project>/data`). Code stays on `/root`
(git); only the unreproducible heavy bytes live on the volume.

**Check `df -h /workspace` before writing anything big**, and leave headroom:
pod-guard SIGSTOPs every running job when the volume drops below 5% free.

## Practical rules

- Treat the pod as disposable. Reproduce state from git + the image, not from
  whatever happens to be on disk.
- Before stopping a pod: `git status` / `git push` anything you care about.
- Don't put credentials or generated config anywhere expecting it to persist —
  RunPod template secrets (or the CoreWeave `runpod-image-secrets` Secret) are
  re-injected and re-wired into `/root` on every boot.
- **Cleaning up a worktree or a data dir on the volume: remove the symlinks
  first, then the directory.** A recursive delete that follows a symlink destroys
  whatever it points at — the shared data or the shared env, not just the link.
