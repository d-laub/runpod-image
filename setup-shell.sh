#!/usr/bin/env bash
set -euo pipefail

# Pixi install.sh and several tools expect bash.
export SHELL=/bin/bash

dlaub_togo_dir=$(mktemp -d)
trap 'rm -rf "${dlaub_togo_dir}"' EXIT

git clone --depth 1 --branch main https://github.com/d-laub/dlaub-togo.git "${dlaub_togo_dir}"

cd "${dlaub_togo_dir}"

bash setup_bash.sh

cd /
