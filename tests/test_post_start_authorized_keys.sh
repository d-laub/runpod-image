#!/usr/bin/env bash
# Regression test for the "SSH asks for password" bug.
#
# RunPod's setup_ssh writes the whole $PUBLIC_KEY as a single line into
# authorized_keys. When the team PUBLIC_KEY concatenates several keys with
# spaces, sshd parses only the FIRST key (the rest are absorbed into the
# comment field), so only the first key authenticates and everyone else hits
# a password prompt. post-start.sh must rewrite authorized_keys with one key
# per line so every team key works.
#
# Runs the SAME post-start.sh shipped in the images (both copies are identical,
# so testing one covers both). No Docker required.

set -euo pipefail

POST_START="${1:-$(cd "$(dirname "$0")/.." && pwd)/generic/post-start.sh}"

[ -x "$POST_START" ] || { echo "FAIL: $POST_START not found / not executable"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Build a realistic multi-key PUBLIC_KEY: three real keys joined with spaces,
# each with a name/comment, exactly as RunPod hands it to the container.
ssh-keygen -t ed25519 -N '' -C 'alice@host'  -f "$tmp/k1" -q
ssh-keygen -t rsa -b 2048 -N '' -C 'bob@host' -f "$tmp/k2" -q
ssh-keygen -t ed25519 -N '' -C 'carol@host'  -f "$tmp/k3" -q
PUBLIC_KEY="$(cat "$tmp/k1.pub") $(cat "$tmp/k2.pub") $(cat "$tmp/k3.pub")"

# Sanity: this is the bug condition — all three keys on a single line.
[ "$(printf '%s\n' "$PUBLIC_KEY" | wc -l)" -eq 1 ] || { echo "FAIL: test setup not single-line"; exit 1; }

AUTH="$tmp/authorized_keys"
PUBLIC_KEY="$PUBLIC_KEY" AUTH_KEYS="$AUTH" bash "$POST_START"

# 1) authorized_keys must exist and have exactly three lines (one key each).
[ -f "$AUTH" ] || { echo "FAIL: authorized_keys not written"; exit 1; }
lines="$(grep -c . "$AUTH" || true)"
[ "$lines" -eq 3 ] || { echo "FAIL: expected 3 key lines, got $lines"; cat "$AUTH"; exit 1; }

# 2) sshd must accept every key — ssh-keygen -l lists one fingerprint per
#    parseable key. All three must be parseable (the bug yields only 1).
fp_count="$(ssh-keygen -l -f "$AUTH" | grep -c . || true)"
[ "$fp_count" -eq 3 ] || { echo "FAIL: only $fp_count of 3 keys parse as valid"; ssh-keygen -l -f "$AUTH"; exit 1; }

# 3) Each individual public key must appear verbatim on its own line.
for k in k1 k2 k3; do
    grep -qF "$(cat "$tmp/$k.pub")" "$AUTH" || { echo "FAIL: $k missing from authorized_keys"; exit 1; }
done

# 4) Permissions: file 600 (sshd StrictModes — dir is created 755 by the script).
mode="$(stat -f '%Lp' "$AUTH" 2>/dev/null || stat -c '%a' "$AUTH")"
[ "$mode" = "600" ] || { echo "FAIL: authorized_keys mode $mode, expected 600"; exit 1; }

# 5) Dedup: RunPod's setup_ssh APPENDS the whole blob on every restart, so the
#    same keys arrive repeatedly. The script must collapse duplicates.
PUBLIC_KEY="$PUBLIC_KEY $PUBLIC_KEY" AUTH_KEYS="$AUTH" bash "$POST_START"
dlines="$(grep -c . "$AUTH" || true)"
[ "$dlines" -eq 3 ] || { echo "FAIL: duplicate keys not deduped, got $dlines lines"; cat "$AUTH"; exit 1; }

echo "PASS: 3 keys normalized one-per-line, valid, mode 600, and deduped"
