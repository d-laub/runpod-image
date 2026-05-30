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
