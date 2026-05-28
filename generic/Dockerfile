# Project-agnostic RunPod dev image: dlaub-togo shell + pixi globals +
# Claude tooling + /workspace HOME + first-login seed + RunPod secret
# wiring. Does NOT clone any repo or fetch any data — bring your own.
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

# Build-time: install dlaub-togo shell + pixi globals + Claude tooling into /root
# as the "seed template" for /workspace. setup_bash.sh is a thin wrapper that
# clones upstream dlaub-togo and runs its setup_bash.sh after a minimal overlay.
COPY setup_bash.sh /tmp/setup_bash.sh
RUN bash /tmp/setup_bash.sh \
    && rm /tmp/setup_bash.sh

# Append runtime secret/git glue to /root/.bashrc (the seed template).
COPY extend-bashrc.sh /tmp/extend-bashrc.sh
RUN cat /tmp/extend-bashrc.sh >> /root/.bashrc && rm /tmp/extend-bashrc.sh

# Seed-on-first-login script.
COPY seed-home.sh /etc/profile.d/00-seed-home.sh

# Make /workspace root's HOME. Direct /etc/passwd edit avoids `usermod -d`,
# which exits 8 ("user logged in") under the runpod/base PAM/utmp state in
# docker build.
RUN sed -i 's|^\(root:[^:]*:0:0:[^:]*:\)/root:|\1/workspace:|' /etc/passwd
ENV HOME=/workspace

# RunPod's pod startup writes the team SSH pubkey to $HOME/.ssh/authorized_keys
# (HOME-aware via /etc/passwd) — that resolves to /workspace/.ssh/authorized_keys.
# Pin sshd's AuthorizedKeysFile to that absolute path so TCP SSH works
# regardless of how login shells later reinterpret HOME.
RUN sed -i '/^#\?AuthorizedKeysFile/d' /etc/ssh/sshd_config \
    && echo 'AuthorizedKeysFile /workspace/.ssh/authorized_keys' >> /etc/ssh/sshd_config
ENV PATH=/workspace/.pixi/bin:/root/.pixi/bin:/root/.cargo/bin:${PATH}

WORKDIR /workspace
