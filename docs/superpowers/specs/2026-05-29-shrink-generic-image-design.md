# Design: shrink the generic RunPod image via in-layer cleanup

Date: 2026-05-29

## Problem

The generic image ships non-runtime bulk. Measured against the published CPU
image (`du -s` is hardlink-aware, so its numbers reflect real unique bytes):

| Path                  | `du` alone | Reality |
|-----------------------|-----------|---------|
| `~/.pixi` (tool envs) | 1.9 GB    | keep — runtime |
| `~/.cache/rattler`    | 1.8 GB    | **mostly hardlinked into `~/.pixi`** — removing frees only ~0.4 GB |
| `~/.rustup`           | 1.4 GB    | of which `share/doc` = **801 MB** (offline HTML docs, removable) |
| `~/.cargo`            | 88 MB     | bins keep; registry/git caches removable |
| `~/.local`, oh-my-bash, claude/skills | smaller | config keeps; caches removable |

`du -s /root` = 4.1 GB (hardlink-aware). Key correction from an earlier
estimate: pixi **hardlinks** the rattler cache into the envs, so deleting the
cache reclaims ~0.4 GB, not 1.8 GB. The clean win is rust-docs (~0.8 GB).
Verified real saving from the full cleanup: **/root 4.1 GB → 2.8 GB (~1.3 GB)**.

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

### 1. Trim Rust offline docs (direct `rm`)

```bash
rm -rf "$HOME"/.rustup/toolchains/*/share/doc 2>/dev/null || true
```

NOT `rustup component remove rust-docs`: rustup's rename-into-`tmp` removal
fails with "Invalid cross-device link (os error 18)" on overlay filesystems
(verified). Direct `rm` reclaims the ~800 MB and leaves rustc/cargo/clippy/
rustfmt intact; re-fetch docs at runtime with `rustup component add rust-docs`.

### 2. Strip caches (direct `rm -rf`, robust, no PATH dependence)

```bash
rm -rf \
  "$HOME/.cache/rattler" \
  "$HOME/.cache/uv" \
  "$HOME/.cache/pip" \
  "$HOME/.npm" "$HOME/.cache/npm" \
  "$HOME/.cargo/registry" "$HOME/.cargo/git" \
  "$HOME/.rustup/downloads" "$HOME/.rustup/tmp" 2>/dev/null || true
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

This dev machine is arm64; the images are `linux/amd64`, so a local build runs
under slow/flaky qemu emulation. Instead:

1. **In-container simulation (authoritative for freed bytes + safety):** pull
   the published CPU image (`--platform linux/amd64`), run the exact cleanup
   commands inside it, and compare `du -sh /root` before/after (`du -s` is
   hardlink-aware). Verified: 4.1 GB → 2.8 GB (~1.3 GB). In the same container,
   confirm `pixi/cargo/rustc/rg/dvc/gh/claude` still launch (catches
   over-deletion). Done — all pass.
2. **CI builds natively** (amd64 runners) on push; then report the published
   GHCR image size before vs. after.

No permanent CI smoke step (keeps CI lean); the in-container smoke covers it.

## Risks

Low. Runtime re-download on first install (accepted). Someone wanting rust-docs
runs one `rustup component add`. The `~/.cache/*` catch-all only clears
regenerable caches; Claude/plugin config lives under `~/.claude`, untouched.

## Expected outcome

~1.3 GB smaller generic image (≈800 MB rust-docs + ≈400 MB cache-unique +
misc), roughly halving `/root` → faster RunPod pull/load and faster CI push;
build time ~unchanged; GHA layer caching preserved (still one install layer).
gvf-germ-som shrinks by the same base delta.
