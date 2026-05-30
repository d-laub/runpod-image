#!/usr/bin/env bash
# Installed at /post_start.sh; RunPod's start.sh runs it after setup_ssh.
#
# RunPod's setup_ssh does `echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys`,
# writing the entire variable as ONE line. When the team PUBLIC_KEY concatenates
# several keys with spaces, sshd honors only the first key (keytype base64
# comment — the comment runs to end-of-line, swallowing every trailing key), so
# everyone but the first key hits a password prompt. We rewrite the keys one per
# line, deduped, into the AuthorizedKeysFile the Dockerfile pins.
#
# That pin is a fixed root-owned path on the container filesystem, deliberately
# NOT $HOME/.ssh: it stays correct regardless of HOME, and avoids ever landing
# on a RunPod network volume (mode 777, ignores chmod) which StrictModes would
# reject. chmod is honored here, StrictModes stays on. sshd re-reads the file
# per connection, so this also fixes a live pod.
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
