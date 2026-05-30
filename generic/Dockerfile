# Project-agnostic RunPod dev image: dlaub-togo shell + pixi globals +
# Claude tooling + RunPod secret wiring. Does NOT clone any repo or fetch any
# data — bring your own.
#
# HOME stays /root (the container filesystem) — ephemeral and wiped on pod
# stop/redeploy. Nothing is persisted on a network volume: code is git-tracked
# and pulled from GitHub, caches are baked into the image, and only large data
# (if a project needs it) belongs on an attached volume via an explicit
# symlink. /root/.claude/CLAUDE.md documents this pattern for pod work.
#
# Build args:
#   BASE_IMAGE — runpod/base GPU (default) or CPU.

ARG BASE_IMAGE=runpod/base:1.0.3-cuda1281-ubuntu2404
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        rsync \
    && rm -rf /var/lib/apt/lists/*

# Build-time: install dlaub-togo shell + pixi globals + Claude tooling into
# /root. setup_bash.sh is a thin wrapper that clones upstream dlaub-togo and
# runs its setup_bash.sh after a minimal overlay.
COPY setup_bash.sh /tmp/setup_bash.sh
RUN bash /tmp/setup_bash.sh \
    && rm /tmp/setup_bash.sh

# Append runtime secret/git glue to /root/.bashrc.
COPY extend-bashrc.sh /tmp/extend-bashrc.sh
RUN cat /tmp/extend-bashrc.sh >> /root/.bashrc && rm /tmp/extend-bashrc.sh

# Global Claude instructions describing the ephemeral-/root, git-for-code,
# volume-only-for-data filesystem pattern, so pod work follows it.
COPY CLAUDE.md /root/.claude/CLAUDE.md

# SSH pubkey auth needs no special handling: HOME is the default /root, so
# RunPod's setup_ssh writes $PUBLIC_KEY (one key per line) to /root/.ssh/
# authorized_keys on the container fs, where perms satisfy sshd's StrictModes.

ENV PATH=/root/.pixi/bin:/root/.cargo/bin:${PATH}

WORKDIR /root
