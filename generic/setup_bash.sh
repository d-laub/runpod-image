#!/usr/bin/env bash
# Build-time shell + tooling setup for the RunPod image.
#
# Thin wrapper around https://github.com/d-laub/dlaub-togo/blob/main/setup_bash.sh —
# clones upstream, strips the hardcoded git identity (set at runtime from
# RunPod secrets in extend-bashrc.sh), and runs it from within the cloned dir.
#
# Runs with HOME=/root, which is also the runtime HOME — the install lands in
# the same place it's used. /root is ephemeral (no network-volume persistence).

set -euo pipefail

dlaub_togo_dir=$(mktemp -d)
trap 'rm -rf "${dlaub_togo_dir}"' EXIT

git clone --depth 1 --branch main https://github.com/d-laub/dlaub-togo.git "${dlaub_togo_dir}"
cd "${dlaub_togo_dir}"

# RunPod overlay: strip the two hardcoded `git config --global user.{email,name}`
# lines. Identity is set at pod-start from RunPod template secrets. Fail loudly
# if the lines aren't where we expect — silent no-op would ship the wrong identity.
python3 - <<'PY'
import pathlib, re
p = pathlib.Path("setup_bash.sh")
s = p.read_text()
new, n = re.subn(r'^git config --global user\.(email|name) .*\n', '', s, flags=re.M)
assert n == 2, f"expected 2 git-identity lines to strip, found {n} — upstream dlaub-togo changed shape"
p.write_text(new)
PY

bash setup_bash.sh

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
