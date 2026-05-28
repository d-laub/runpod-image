# gvf-germ-som RunPod image — GPU (default) or CPU via BASE_IMAGE build-arg.
# See README.md for usage and the design spec for architecture.
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
# as the "seed template" for /workspace.
COPY setup_bash.sh /tmp/setup_bash.sh
RUN bash /tmp/setup_bash.sh \
    && rm /tmp/setup_bash.sh

# Append the runtime secret/git/bootstrap glue to /root/.bashrc (the template)
COPY extend-bashrc.sh /tmp/extend-bashrc.sh
RUN cat /tmp/extend-bashrc.sh >> /root/.bashrc && rm /tmp/extend-bashrc.sh

# Seed-on-first-login script
COPY seed-home.sh /etc/profile.d/00-seed-home.sh
# seed-home.sh (Task 7) will be committed at 0644 by default

# Project bootstrap script (invoked from extend-bashrc.sh on first shell)
COPY bootstrap-gvf.sh /usr/local/bin/bootstrap-gvf.sh
# bootstrap-gvf.sh (Task 9) will be committed at 0755

# Make /workspace root's HOME; keep /root as the seed template.
# `usermod -d` errors with exit code 8 ("user currently logged in") in some
# docker build contexts (PAM/utmp leakage from the base image). Edit
# /etc/passwd directly to bypass the safety check — same result.
RUN sed -i 's|^\(root:[^:]*:0:0:[^:]*:\)/root:|\1/workspace:|' /etc/passwd
ENV HOME=/workspace
ENV PATH=/workspace/.pixi/bin:/root/.pixi/bin:/root/.cargo/bin:${PATH}

# RunPod's pod startup writes the team SSH pubkey to /root/.ssh/authorized_keys,
# but with HOME=/workspace sshd would otherwise look at /workspace/.ssh/. Pin
# the path so TCP SSH auth works regardless of HOME.
RUN sed -i '/^#\?AuthorizedKeysFile/d' /etc/ssh/sshd_config \
    && echo 'AuthorizedKeysFile /root/.ssh/authorized_keys' >> /etc/ssh/sshd_config

WORKDIR /workspace
