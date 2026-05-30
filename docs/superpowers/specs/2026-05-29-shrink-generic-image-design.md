# Design: shrink the generic RunPod image via in-layer cleanup

Date: 2026-05-29

## Problem

The generic image's `/root` is ~4.1 GB (measured live on a pod), dominated by
**download caches that are not needed at runtime**:

| Path                  | Size    | Needed at runtime? |
|-----------------------|---------|--------------------|
| `~/.cache/rattler`    | ~1.9 GB | No — pixi package download cache |
| `~/.pixi`             | 541 MB  | Yes — the global tool envs |
| `~/.cargo` (+`.rustup`) | ~88 MB + toolchain | bins yes; registry/docs no |
| oh-my-bash / claude / skills / npx | smaller | yes (config), caches no |

Everything is installed in a **single `RUN bash /tmp/setup_bash.sh` layer**
(the wrapper `generic/setup_bash.sh`, which clones upstream `d-laub/dlaub-togo`
and runs its installer). Because the caches live in that layer, they ship in
the image even though they're regenerable. Result: slow RunPod pulls/loads and
slow CI pushes.

## Goal

Smaller image first (faster RunPod load + faster CI push), without lengthening
build time or breaking installed tools. Decisions taken during brainstorming:

- Optimize **size first** (also helps build/push); build *time* stays ~flat.
- **Strip all package-download caches** (rattler/uv/pip/cargo-registry/npm).
  Runtime `pixi global install` / `cargo install` / gvf `pixi install` re-fetch
  on demand — acceptable (pods are ephemeral; HOME=/root wouldn't persist a
  baked cache across restarts anyway).
- **Single-stage, in-layer cleanup** — no multi-stage. The install is already
  one layer, so cleaning inside it captures ~all the win; pixi/cargo/git are
  runtime tools we keep, so a builder/runtime split gains little.
- **Rust: default minus `rust-docs`** — keep clippy/rustfmt, drop the offline
  doc set (the large part). Re-addable at runtime via `rustup component add`.

## Approach

Single change surface: **`generic/setup_bash.sh`** (the wrapper). gvf-germ-som
inherits the win automatically (it is `FROM` the generic image). No Dockerfile
restructuring.

The wrapper currently: clones upstream, patches out the hardcoded git-identity
lines (fail-loudly if not found), then `bash setup_bash.sh`. Add, in the same
process (hence same image layer):

### 1. Trim Rust after install

After upstream runs, with cargo/rustup on PATH:

```bash
rustup component remove rust-docs 2>/dev/null || true
```

Keeps clippy/rustfmt; removes the offline docs. (No upstream-line patch needed
— this is a post-step, so the fail-loudly discipline applies only to edits of
the cloned script, which we are not changing for Rust.)

### 2. Strip caches (direct `rm -rf`, robust, no PATH dependence)

```bash
rm -rf \
  "$HOME/.cache/rattler" \
  "$HOME/.cache/uv" \
  "$HOME/.cache/pip" \
  "$HOME/.npm" "$HOME/.cache/npm" \
  "$HOME/.cargo/registry" "$HOME/.cargo/git" \
  "$HOME/.rustup/downloads" "$HOME/.rustup/tmp"
find "$HOME/.pixi" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
# catch-all: ~/.cache holds only regenerable caches (Claude config is ~/.claude)
rm -rf "$HOME/.cache"/* 2>/dev/null || true
```

Each removal is guarded so the wrapper's `set -euo pipefail` cannot abort on an
already-absent path.

## What does NOT change

- Tool set and versions (pixi globals, cargo bins, claude plugins/skills) —
  unchanged; only their download caches and rust offline docs are removed.
- Dockerfiles (no new layers, no multi-stage), CI workflow, SSH/HOME model.
- gvf-germ-som files — it just gets a smaller base.

## Verification

Docker Desktop is installed but its daemon must be started (`open -a Docker`).
At implementation time:

1. **Size delta (authoritative):** build the **CPU** variant before and after
   the change (lighter than GPU; cleanup is variant-independent) and compare
   `docker image inspect -f '{{.Size}}'`. Expect the rattler cache (~1.9 GB) +
   rust-docs + cargo registry + npm caches to drop out (~2 GB+ uncompressed).
2. **Tool smoke (catches over-deletion):** `docker run --rm <img> bash -lc
   'pixi --version && cargo --version && rg --version && dvc --version && gh
   --version && claude --version'` — all must succeed.
3. Report the **published GHCR size** before/after once CI builds on main.

No permanent CI smoke step (keeps CI lean); the local smoke covers this change.

## Risks

Low. Runtime re-download on first install (accepted). Someone wanting rust-docs
runs one `rustup component add`. The `~/.cache/*` catch-all only clears
regenerable caches; Claude/plugin config lives under `~/.claude`, untouched.

## Expected outcome

~2 GB+ smaller generic image → faster RunPod pull/load and faster CI push;
build time ~unchanged; GHA layer caching preserved (still one install layer).
gvf-germ-som shrinks by the same base delta.
