# Auto-rebuild images when upstream `dlaub-togo` changes

**Date:** 2026-09-08
**Status:** Approved

## Problem

The generic image installs the shell environment by cloning
`d-laub/dlaub-togo@main` at build time (`generic/setup_bash.sh`). Upstream
changes therefore never reach the published images:

1. **No trigger.** The workflow fires on push/PR to this repo only. A commit in
   `dlaub-togo` changes nothing here, so no build runs.
2. **No cache invalidation.** Even a manual `workflow_dispatch` would not help.
   The install is one `RUN bash /tmp/setup_bash.sh` layer whose cache key is the
   command string plus the copied file — both unchanged. `cache-from:
   type=gha` returns the *stale* layer, still containing the old clone.

Fixing only (1) produces green builds that ship old content, which is worse than
no automation. Both halves must be fixed together.

## Goal

A push to `dlaub-togo` results in republished `:latest` / `:gpu` / `:cpu` (and
the flavor tags) containing that commit, without manual intervention, and
without pointless rebuilds when nothing upstream changed.

## Solution overview

### 1. Pin the upstream commit (cache correctness + reproducibility)

`generic/setup_bash.sh` reads `DLAUB_TOGO_REF` (default `main`) and clones that
exact ref. `generic/Dockerfile` declares `ARG DLAUB_TOGO_REF=main` and passes it
into the install `RUN` as an environment variable, so the ARG value participates
in that layer's cache key.

CI resolves the ref to an immutable commit SHA with `git ls-remote` and passes
it as `--build-arg DLAUB_TOGO_REF=<sha>`:

- upstream changed → new ARG value → new cache key → genuine rebuild;
- upstream unchanged → identical ARG → cache hit → near-free build.

A fixed SHA also makes any given build reproducible, which the floating `main`
clone never was.

`git clone --depth 1 --branch <x>` accepts branches and tags but not arbitrary
SHAs, so the clone becomes `init` + `fetch --depth 1 origin <ref>` +
`checkout FETCH_HEAD`, which accepts both a SHA and a branch name (the local
default stays `main`).

### 2. Triggers

`.github/workflows/docker-image.yml` gains two entry points:

- `schedule` — daily. Self-contained: needs no cross-repo credentials, so it
  works from the moment this lands.
- `repository_dispatch` (type `dlaub-togo-updated`) — the instant path, fired by
  a workflow in `dlaub-togo`.

### 3. `resolve` job

A new lightweight job runs first and outputs:

- `togo_sha` — full upstream SHA, passed as the build-arg;
- `build_id` — `<this-repo-sha7>-t<togo-sha7>`, the content-addressed tag
  suffix;
- `changed` — `false` only when the event is `schedule` *and* both
  `:gpu-<build_id>` and `:cpu-<build_id>` already exist in GHCR.

`generic` is gated on `changed == 'true'`; `flavors` skips automatically because
a skipped `needs` job skips its dependents. The daily cron is therefore a true
no-op — two registry HEAD requests — when nothing moved upstream.

Non-schedule events (push, PR, `workflow_dispatch`, `repository_dispatch`)
always build, preserving today's behavior.

### 4. Tag scheme

The per-commit tag changes from `gpu-<sha>` to `gpu-<sha>-t<togo7>`, and
likewise for `cpu-` and the flavor tags.

This is required, not cosmetic. Once upstream can trigger a rebuild, the same
repo SHA can produce different image content; keeping `gpu-<sha>` would silently
mutate a tag the README documents as immutable — a pinning footgun. Addressing
the tag by *both* inputs restores the guarantee: one tag, one content, forever.

Mutable aliases (`latest`, `gpu`, `cpu`, branch tags, and the bare flavor tags)
are unchanged and continue to move. `flavors` pins the new per-commit generic
tag exactly as it pinned the old one. Previously published `gpu-<sha>` tags stay
in the registry; they simply stop being produced.

### 5. Notifier in `dlaub-togo`

`.github/workflows/notify-runpod-image.yml` in `dlaub-togo` posts a
`repository_dispatch` on push to `main`. `GITHUB_TOKEN` cannot dispatch
cross-repo, so it needs a PAT with `repo` scope on `runpod-image`, stored as the
`RUNPOD_IMAGE_DISPATCH_TOKEN` secret.

The `secrets` context is unavailable in `if:` conditions, so the token is bound
to an env var and the dispatch step is guarded on `env.TOKEN != ''`. Until the
secret exists the job succeeds as a no-op with an explanatory log line — no red
X on every upstream push. This makes the instant path strictly opt-in while the
cron keeps working.

Delivered as a PR against `dlaub-togo`, not a direct push to its `main`.

## Error handling

- `git ls-remote` returning an empty SHA fails the `resolve` job loudly rather
  than building against an unpinned ref.
- The GHCR existence probe treats any non-success as "not present" and builds;
  a false negative costs one cheap cached build, a false positive would skip a
  needed rebuild.
- `setup_bash.sh` keeps `set -euo pipefail` and its existing fail-loud assertion
  on upstream shape (the git-identity strip). If a future upstream commit
  changes that shape, the build fails visibly instead of shipping the wrong git
  identity — which is exactly the behavior wanted now that upstream changes
  build automatically.

## Testing

- `actionlint` over the workflows (syntax, expression, context validity).
- `shellcheck` over `generic/setup_bash.sh`.
- A bats test covering ref resolution in `setup_bash.sh` is not worthwhile: the
  script's body is a network clone plus a full toolchain install, untestable
  without a refactor that serves nothing else. The ARG→env→clone path is
  verified by the first real CI build.
- End-to-end: after merge, confirm a `workflow_dispatch` run publishes a
  `gpu-<sha>-t<togo7>` tag, and that a second run with unchanged upstream is a
  cache hit.

## Out of scope

- Running the existing `generic/test/cgroup_threads.bats` suite in CI (no job
  runs it today). Tracked separately as a GitHub issue.
- Pinning any other floating upstream input (apt, pixi globals, rustup).
