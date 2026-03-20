#!/usr/bin/env bash
# Mirrors https://github.com/d-laub/dlaub-togo/blob/main/setup_bash.sh for image build.

set -euo pipefail

# Pixi install.sh only updates bashrc when SHELL is bash (often /bin/sh in Docker builds).
export SHELL=/bin/bash

bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" "" --unattended

curl -fsSL https://raw.githubusercontent.com/d-laub/dlaub-togo/main/aliases.sh >> "${HOME}/.bash_aliases"

git clone --depth 1 --branch main https://github.com/d-laub/dlaub-togo.git /tmp/dlaub-togo-tmp
mkdir -p "${HOME}/.oh-my-bash/themes"
cp -r /tmp/dlaub-togo-tmp/agnoster-multiline "${HOME}/.oh-my-bash/themes/"
rm -rf /tmp/dlaub-togo-tmp

curl -fsSL https://pixi.sh/install.sh | sh
export PATH="${HOME}/.pixi/bin:${PATH}"
pixi g i ripgrep bat glow-md sd zoxide rnr fd-find exa prek git gh

echo 'eval "$(zoxide init bash)"' >> "${HOME}/.bashrc"
sd '^OSH_THEME=.*$' 'OSH_THEME="agnoster-multiline"' "${HOME}/.bashrc"
