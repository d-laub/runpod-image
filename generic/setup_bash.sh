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

# Upstream commit to install. CI pins this to a resolved SHA so this layer's
# Docker cache key tracks upstream: changed -> real rebuild, unchanged -> cache
# hit. Local builds default to the branch tip.
dlaub_togo_ref="${DLAUB_TOGO_REF:-main}"

dlaub_togo_dir=$(mktemp -d)
trap 'rm -rf "${dlaub_togo_dir}"' EXIT

# `clone --branch` rejects a raw SHA; fetch-by-ref takes either a SHA or a
# branch name and stays a shallow single-commit fetch both ways.
git -C "${dlaub_togo_dir}" init -q -b main
git -C "${dlaub_togo_dir}" fetch -q --depth 1 \
    https://github.com/d-laub/dlaub-togo.git "${dlaub_togo_ref}"
git -C "${dlaub_togo_dir}" checkout -q FETCH_HEAD
cd "${dlaub_togo_dir}"
echo "dlaub-togo: installing ${dlaub_togo_ref} -> $(git rev-parse HEAD)"

# RunPod overlay: strip the two hardcoded `git config --global user.{email,name}`
# lines. Identity is set at pod-start from RunPod template secrets. Fail loudly
# if the lines aren't where we expect — silent no-op would ship the wrong identity.
python3 - <<'PY'
import pathlib, re
p = pathlib.Path("setup_bash.sh")
s = p.read_text()
new, n = re.subn(r'^git config --global user\.(email|name) .*\n', '', s, flags=re.M)
assert n == 2, f"expected 2 git-identity lines to strip, found {n} — upstream dlaub-togo changed shape"

# Skills from private repos can't be cloned here (no credentials) and must not
# be baked into the public image. Defer them to pod start, where
# extend-bashrc.sh installs them with the GITHUB_TOKEN RunPod secret.
import os, subprocess
def is_public(repo: str) -> bool:
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    r = subprocess.run(["git", "ls-remote", f"https://github.com/{repo}.git", "HEAD"],
                       env=env, capture_output=True)
    return r.returncode == 0
skill_line = re.compile(r'^npx -y skills add ([\w.-]+/[\w.-]+)\s.*$', flags=re.M)
deferred = [m.group(0) for m in skill_line.finditer(new) if not is_public(m.group(1))]
for line in deferred:
    new = new.replace(line + "\n", "")
    print(f"dlaub-togo: deferring private skill to pod start: {line}")
out = pathlib.Path.home() / ".local/share/runpod-image/deferred-skills.sh"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text("set -uo pipefail\n" + "".join(f"{l}\n" for l in deferred))
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
