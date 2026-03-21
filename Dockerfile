# RunPod base + bash (oh-my-bash, agnoster-multiline) and pixi global tools
# per https://github.com/d-laub/dlaub-togo
#
# Build args:
#   BASE_IMAGE — default GPU; use runpod/base:1.0.3-ubuntu2404 for CPU/Linux VM dev.

ARG BASE_IMAGE=runpod/base:1.0.3-cuda1300-ubuntu2404
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
    && rm -rf /var/lib/apt/lists/*

COPY setup-shell.sh /tmp/setup-shell.sh
RUN chmod +x /tmp/setup-shell.sh \
    && bash /tmp/setup-shell.sh \
    && rm /tmp/setup-shell.sh

ENV PATH="/root/.pixi/bin:${PATH}"

WORKDIR /workspace
