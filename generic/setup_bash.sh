#!/usr/bin/env bash
# Build-time shell + tooling setup for the gvf-germ-som RunPod image.
#
# Forked from https://github.com/d-laub/dlaub-togo/blob/main/setup_bash.sh
# with these RunPod-specific changes:
#   - No hardcoded git user identity (set at runtime from RunPod secrets in
#     extend-bashrc.sh; falls back to gh-resolved identity).
#   - Generic dlaub-togo assets (agnoster-multiline theme, aliases.sh,
#     zellij_config.kdl) are pulled from d-laub/dlaub-togo at build time.
#   - rustup runs with `-y` for unattended non-TTY install.
#
# Runs with HOME=/root (the seed template). The Dockerfile follows up with
# `usermod -d /workspace root` + `ENV HOME=/workspace`, and a
# /etc/profile.d/00-seed-home.sh rsyncs /root/ → /workspace/ on first boot.

set -euo pipefail

dlaub_togo_dir=$(mktemp -d)
trap 'rm -rf "${dlaub_togo_dir}"' EXIT

# Generic shell theme / aliases / zellij config live in dlaub-togo
git clone --depth 1 --branch main https://github.com/d-laub/dlaub-togo.git "${dlaub_togo_dir}"

# oh-my-bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" "" --unattended

export PATH="${HOME}/.local/bin:${PATH}"

# pixi + global tools (dvc-s3 needed for DVC against R2's s3:// remote)
curl -fsSL https://pixi.sh/install.sh | sh
export PATH="${HOME}/.pixi/bin:${PATH}"
pixi g i ripgrep bat glow-md sd zoxide rnr fd-find exa prek git gh less zellij dvc rclone awscli uv wandb dust nodejs commitizen
pixi g a -e dvc dvc-s3

# rust toolchain (-y for non-interactive build)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
export PATH="${HOME}/.cargo/bin:${PATH}"
curl -L --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash
# cargo-update is a "keep pixi globals fresh on demand" tool — non-fatal if
# the binstall GH-API call rate-limits and the source-build fallback hits
# missing system deps (openssl-sys). User can `cargo binstall cargo-update`
# manually on a working pod later.
cargo binstall -y cargo-update || echo "WARN: cargo-update install skipped (binstall fetch failed)"

# Generic git defaults only — identity is set at runtime from RunPod secrets.
git config --global pull.rebase true

# LLM tooling
## Claude Code + RTK (token-saving proxy)
curl -fsSL https://claude.ai/install.sh | bash
curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
rtk init --global

## Anthropic plugin marketplace + superpowers
claude plugin marketplace add anthropics/claude-plugins-official
claude plugin install superpowers@claude-plugins-official

## tilth (code-intel MCP server)
cargo binstall -y tilth
tilth install claude-code --edit

## marimo skills
npx -y skills add marimo-team/marimo-pair --agent claude-code --global -y
npx -y skills add marimo-team/skills --skill marimo-notebook --agent claude-code --global -y

## RunPod skill
npx -y skills add runpod/skills --agent claude-code --global -y

## Project-relevant skills
npx -y skills add ML4GLand/SeqPro --skill seqpro --agent claude-code --global -y
npx -y skills add d-laub/genoray --agent claude-code --global -y
npx -y skills add mcvickerlab/GenVarLoader --agent claude-code --global -y

# Aliases (from dlaub-togo)
cat "${dlaub_togo_dir}/aliases.sh" >> "${HOME}/.bash_aliases"

# Theme (from dlaub-togo)
mkdir -p "${HOME}/.oh-my-bash/themes"
cp -r "${dlaub_togo_dir}/agnoster-multiline" "${HOME}/.oh-my-bash/themes/"
sd '^OSH_THEME=.*$' 'OSH_THEME="agnoster-multiline"' "${HOME}/.bashrc"

# bashrc tail
printf '%s\n' 'export PATH="${HOME}/.local/bin:${PATH}"' >> "${HOME}/.bashrc"
printf '%s\n' 'eval "$(zoxide init bash)"' >> "${HOME}/.bashrc"
printf '%s\n' 'eval "$(dvc completion -s bash)"' >> "${HOME}/.bashrc"

# zellij config (from dlaub-togo)
mkdir -p "${HOME}/.config/zellij"
cp "${dlaub_togo_dir}/zellij_config.kdl" "${HOME}/.config/zellij/config.kdl"

echo 'Finished setting up shell environment for gvf-germ-som RunPod image.'
