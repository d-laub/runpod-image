#!/usr/bin/env bash
# Installed at /post_start.sh; RunPod's start.sh runs it after setup_ssh.
#
# Two problems this fixes, both stemming from HOME=/workspace (which we keep,
# so runtime caches/installs persist on the volume across pause/resume):
#
#   1. RunPod's setup_ssh does `echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys`,
#      writing the entire variable as ONE line. When the team PUBLIC_KEY
#      concatenates several keys with spaces, sshd honors only the first key
#      (keytype base64 comment — the comment runs to end-of-line, swallowing
#      every trailing key). Everyone but the first key hits a password prompt.
#
#   2. ~/.ssh resolves to /workspace/.ssh, and /workspace is a RunPod network
#      volume that is permanently mode 777 and ignores chmod. With
#      StrictModes yes, sshd refuses to read an authorized_keys under any
#      world-writable path — so pubkey auth is skipped entirely.
#
# So we DON'T put authorized_keys on the volume. We write the keys, one per
# line, to a root-owned path on the container filesystem (AuthorizedKeysFile is
# pinned there in the Dockerfile). chmod is honored there, StrictModes stays on.
# sshd re-reads the file per connection, so this also fixes a live pod.
#
# AUTH_KEYS is overridable for tests; default matches the Dockerfile pin.
set -euo pipefail

AUTH_KEYS="${AUTH_KEYS:-/etc/ssh/keys/authorized_keys}"

# Nothing to do if RunPod injected no key.
[ -n "${PUBLIC_KEY:-}" ] || exit 0

dir="$(dirname "$AUTH_KEYS")"
mkdir -p "$dir"

# Split on key-type tokens: start a new line each time a token looks like an
# SSH public-key type. Comments (which may contain spaces) stay with their key.
# `awk NF` drops blanks; `sort -u` dedupes RunPod's repeated appends. Overwrite
# (not append) so restart/resume stays clean.
printf '%s\n' "$PUBLIC_KEY" | awk '
{
    out = ""
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)$/) {
            if (out != "") print out
            out = $i
        } else {
            out = (out == "") ? $i : out " " $i
        }
    }
    if (out != "") print out
}' | awk 'NF' | sort -u > "$AUTH_KEYS"

chmod 755 "$dir"
chmod 600 "$AUTH_KEYS"
