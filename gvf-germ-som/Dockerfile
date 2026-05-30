# gvf-germ-som RunPod image — GPU (default) or CPU via BASE_IMAGE build-arg.
# See README.md for usage and the design spec for architecture.
#
# HOME stays /root (ephemeral container fs). Code is cloned fresh from GitHub on
# each boot by bootstrap-gvf.sh; only large data persists, on the network volume
# at /workspace (DVC cache + the rclone'd mmrf.svar), linked into the working
# tree. See /root/.claude/CLAUDE.md and bootstrap-gvf.sh.
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

# Build-time: install dlaub-togo shell + pixi globals + Claude tooling into /root.
COPY setup_bash.sh /tmp/setup_bash.sh
RUN bash /tmp/setup_bash.sh \
    && rm /tmp/setup_bash.sh

# Append the runtime secret/git/bootstrap glue to /root/.bashrc.
COPY extend-bashrc.sh /tmp/extend-bashrc.sh
RUN cat /tmp/extend-bashrc.sh >> /root/.bashrc && rm /tmp/extend-bashrc.sh

# Global Claude instructions describing the ephemeral-/root, git-for-code,
# volume-only-for-data filesystem pattern, so pod work follows it.
COPY CLAUDE.md /root/.claude/CLAUDE.md

# Project bootstrap script (invoked from extend-bashrc.sh on first shell):
# clones the repo to /root, persists heavy data on the /workspace volume.
COPY bootstrap-gvf.sh /usr/local/bin/bootstrap-gvf.sh
RUN chmod 0755 /usr/local/bin/bootstrap-gvf.sh

ENV PATH=/root/.pixi/bin:/root/.cargo/bin:${PATH}

# SSH pubkey auth. RunPod's setup_ssh does `echo "$PUBLIC_KEY" >> ~/.ssh/...`,
# writing every team key onto ONE line — sshd then honors only the first key
# (the rest fall into the comment field) and everyone else hits a password
# prompt. post-start.sh re-splits them one per line. We pin AuthorizedKeysFile
# to a fixed root-owned path (independent of HOME and of any network volume,
# whose 777/chmod-ignoring perms would trip StrictModes). See post-start.sh.
RUN mkdir -p /etc/ssh/keys \
    && chmod 0755 /etc/ssh/keys \
    && sed -i '/^#\?AuthorizedKeysFile/d;/^#\?StrictModes/d' /etc/ssh/sshd_config \
    && printf 'AuthorizedKeysFile /etc/ssh/keys/authorized_keys\nStrictModes yes\n' >> /etc/ssh/sshd_config

# Runs (as /post_start.sh) after RunPod's setup_ssh; rewrites the pinned
# authorized_keys with one valid key per line. sshd re-reads it per connection.
COPY post-start.sh /post_start.sh
RUN chmod 0755 /post_start.sh

WORKDIR /root
