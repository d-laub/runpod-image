# gvf-germ-som RunPod image — the project bootstrap layered onto the generic
# base image. Everything generic (dlaub-togo shell, pixi globals, Claude
# tooling, RunPod secret wiring, ephemeral /root HOME, sshd defaults,
# /root/.claude/CLAUDE.md) is INHERITED from the base — not duplicated here.
#
# BASE_IMAGE selects the generic variant: GPU (default) or CPU. CI pins it to
# the matching per-commit generic tag; locally it defaults to the published
# :gpu image (override with --build-arg BASE_IMAGE=...:cpu for the CPU build).
ARG BASE_IMAGE=ghcr.io/d-laub/runpod-image:gpu
FROM ${BASE_IMAGE}

# First-shell bootstrap: clone the repo to /root and persist heavy data on the
# /workspace volume (DVC cache + mmrf.svar). Invoked from .bashrc on first shell.
COPY bootstrap-gvf.sh /usr/local/bin/bootstrap-gvf.sh
RUN chmod 0755 /usr/local/bin/bootstrap-gvf.sh

# Append ONLY the bootstrap trigger to the .bashrc the generic base already
# built — its secret/git/rclone/aws/wandb glue is inherited, not duplicated.
COPY extend-bashrc.sh /tmp/extend-bashrc.sh
RUN cat /tmp/extend-bashrc.sh >> /root/.bashrc && rm /tmp/extend-bashrc.sh
