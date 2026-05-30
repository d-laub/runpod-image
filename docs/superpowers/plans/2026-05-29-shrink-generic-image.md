# Shrink Generic Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strip ~2 GB of non-runtime download caches (and rust offline docs) from the generic RunPod image, in the same build layer, so pods pull/load faster and CI pushes faster.

**Architecture:** All install happens in one `RUN bash /tmp/setup_bash.sh` layer via the wrapper `generic/setup_bash.sh` (clones upstream `d-laub/dlaub-togo`, runs its installer). Append cache cleanup + `rust-docs` removal to that wrapper so the bulk never enters the layer. gvf-germ-som inherits the win (it is `FROM` the generic image). No multi-stage, no Dockerfile/CI changes.

**Tech Stack:** Docker (buildx), bash, pixi, rustup, GitHub Actions, GHCR.

Spec: `docs/superpowers/specs/2026-05-29-shrink-generic-image-design.md`

---

### Task 1: Establish the baseline image size

Measure the current published CPU image (no cleanup yet) as the before-number. CPU variant is used throughout (lighter base; cleanup is variant-independent).

**Files:** none (measurement only)

- [ ] **Step 1: Confirm the Docker daemon is up**

Run: `docker info --format '{{.ServerVersion}}'`
Expected: a version string (e.g. `27.x`). If it errors with a socket message, run `open -a Docker`, wait ~60s, retry.

- [ ] **Step 2: Log in to GHCR (to pull the private base/published image)**

Run:
```bash
gh auth token | docker login ghcr.io -u "$(gh api user --jq .login)" --password-stdin
```
Expected: `Login Succeeded`.

- [ ] **Step 3: Pull the current published generic CPU image and record its size**

Run:
```bash
docker pull ghcr.io/d-laub/runpod-image:cpu
docker image inspect ghcr.io/d-laub/runpod-image:cpu -f '{{.Size}}' | tee /tmp/size_baseline.txt
```
Expected: pull succeeds; a byte count is printed and saved (expect multiple GB, e.g. > 3000000000).

---

### Task 2: Add cleanup to the build wrapper

**Files:**
- Modify: `generic/setup_bash.sh` (append after the existing `bash setup_bash.sh` line)

- [ ] **Step 1: Append the rust-docs removal and cache cleanup to the wrapper**

Open `generic/setup_bash.sh`. It currently ends with:
```bash
bash setup_bash.sh
```
Append immediately after that line:
```bash

# --- Image-size cleanup (runs in the same Docker layer as the install above) ---
# Drops ~1.3 GB of non-runtime bulk so it never ships in the image. Verified
# against the published CPU image: /root 4.1G -> 2.8G, all tools still launch.
# Each removal is guarded so this script's `set -euo pipefail` can't abort on an
# already-absent path.

# Rust offline HTML docs (~800 MB). Removed by direct rm, NOT
# `rustup component remove rust-docs`: rustup's rename-into-tmp removal fails
# with "Invalid cross-device link" on overlay filesystems. rustc/cargo/clippy/
# rustfmt are untouched; re-fetch docs at runtime with `rustup component add`.
rm -rf "${HOME}"/.rustup/toolchains/*/share/doc 2>/dev/null || true

# Package-download caches. The pixi tool envs are self-contained once built
# (rattler hardlinks shared files into ~/.pixi, which we keep), so dropping the
# caches mostly reclaims cache-unique bytes; runtime installs re-fetch on demand.
rm -rf \
    "${HOME}/.cache/rattler" \
    "${HOME}/.cache/uv" \
    "${HOME}/.cache/pip" \
    "${HOME}/.npm" "${HOME}/.cache/npm" \
    "${HOME}/.cargo/registry" "${HOME}/.cargo/git" \
    "${HOME}/.rustup/downloads" "${HOME}/.rustup/tmp" 2>/dev/null || true

# Compiled Python bytecode in the pixi tool envs.
find "${HOME}/.pixi" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

# Catch-all: ~/.cache holds only regenerable caches (Claude config is ~/.claude).
rm -rf "${HOME}/.cache"/* 2>/dev/null || true
```

- [ ] **Step 2: Syntax-check the wrapper**

Run: `bash -n generic/setup_bash.sh`
Expected: no output, exit 0.

---

### Task 3: Verify freed bytes + tool safety via in-container simulation

This machine is arm64; the images are `linux/amd64`, so a local build runs
under slow/flaky qemu. Instead, run the exact cleanup commands inside the
already-pulled baseline container and measure the real (hardlink-aware) delta.

**Files:** none (measurement)

- [ ] **Step 1: Simulate cleanup, measure `du -s /root` delta, smoke tools**

Run:
```bash
docker run --rm --platform linux/amd64 ghcr.io/d-laub/runpod-image:cpu bash -lc '
set -e
export PATH=$HOME/.local/bin:$HOME/.pixi/bin:$HOME/.cargo/bin:$PATH
echo "== BEFORE =="; du -sh /root
rm -rf "$HOME"/.rustup/toolchains/*/share/doc 2>/dev/null || true
rm -rf \
  "$HOME/.cache/rattler" "$HOME/.cache/uv" "$HOME/.cache/pip" \
  "$HOME/.npm" "$HOME/.cache/npm" \
  "$HOME/.cargo/registry" "$HOME/.cargo/git" \
  "$HOME/.rustup/downloads" "$HOME/.rustup/tmp" 2>/dev/null || true
find "$HOME/.pixi" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
rm -rf "$HOME/.cache"/* 2>/dev/null || true
echo "== AFTER =="; du -sh /root
echo "== SMOKE =="
pixi --version && cargo --version && rustc --version && rg --version | head -1 \
  && dvc --version && gh --version | head -1 && claude --version && echo SMOKE_OK
'
```
Expected: BEFORE ≈ 4.1G, AFTER ≈ 2.8G (≈1.3 GB freed; `du -s` is hardlink-aware
so this is real unique bytes), and final line `SMOKE_OK`. A "command not found"
means a cleanup removed too much — narrow the offending `rm`.

---

### Task 5: Commit and push (triggers CI rebuild of all variants)

**Files:**
- Modify: `generic/setup_bash.sh` (already changed)

- [ ] **Step 1: Commit the wrapper change**

Run:
```bash
git add generic/setup_bash.sh
git commit -m "perf(image): strip download caches + rust-docs in-layer

Removes ~2GB of non-runtime bulk (rattler/uv/pip/cargo-registry/npm caches and
rust offline docs) inside the install layer so it never ships in the image.
gvf-germ-som inherits the smaller base. Verified locally: CPU image dropped
~<N> GB; pixi/cargo/rg/dvc/gh/claude still launch.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
(Replace `<N>` with the measured saving from Task 3 Step 2.)

- [ ] **Step 2: Push to main**

Run: `git push origin main`
Expected: push succeeds; the `generic` → `flavors` workflow starts.

- [ ] **Step 3: Watch CI to completion**

Run:
```bash
RID=$(gh run list --workflow=docker-image.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RID" --exit-status
```
Expected: exit 0; all `generic` and `flavors` jobs succeed.

---

### Task 6: Report the published size delta

**Files:** none

- [ ] **Step 1: Pull the new published CPU image and report before/after**

Run:
```bash
docker pull ghcr.io/d-laub/runpod-image:cpu
NEW=$(docker image inspect ghcr.io/d-laub/runpod-image:cpu -f '{{.Size}}')
python3 - "$NEW" <<'PY'
import sys
base = int(open('/tmp/size_baseline.txt').read().strip())
new = int(sys.argv[1])
print(f"published CPU image: {base/1e9:.2f} GB -> {new/1e9:.2f} GB (saved {(base-new)/1e9:.2f} GB)")
PY
```
Expected: a clear before→after line. Report it to the user. (GPU image drops by the same cache delta.)

---

## Notes for the implementer

- This plan only touches `generic/setup_bash.sh`. Do not modify Dockerfiles, the CI workflow, or any gvf-germ-som file — they inherit the change.
- Builds are heavy (full networked install). Use the CPU variant for local iteration; the GPU image gets the same cleanup via the same wrapper.
- If `docker build` can't reach the daemon, the daemon isn't up — `open -a Docker`, wait, retry.
