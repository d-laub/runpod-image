# RunPod GPU base + bash (oh-my-bash, agnoster-multiline) and pixi global tools
# per https://github.com/d-laub/dlaub-togo
FROM runpod/base:1.0.3-cuda1300-ubuntu2404

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
