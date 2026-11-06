# coreweave — run the images on CoreWeave (CKS)

Kubernetes manifests for running `ghcr.io/d-laub/runpod-image:gpu` on a
CoreWeave node. No separate image: the RunPod base's `/start.sh` is
platform-neutral, so the same image behaves the same on both platforms.

| RunPod                      | CoreWeave                                       |
|-----------------------------|-------------------------------------------------|
| Template secrets            | Secret `runpod-image-secrets` (`envFrom`)       |
| Network volume `/workspace` | PVC `workspace` (`shared-vast`) at `/workspace` |
| Web terminal / SSH          | `kubectl exec`, or SSH over `kubectl port-forward` |
| Ephemeral `/root`           | Ephemeral `/root` (unchanged)                   |

## One-time setup

1. Generate a kubeconfig for the cluster. `cwic cluster auth` prompts
   interactively, so run it in a real terminal:

   ```bash
   cwic cluster auth <cluster>
   ```

   If `kubectl` then reports "no configuration has been provided", the
   generated config has an empty `current-context`. Set it:

   ```bash
   kubectl config use-context "$(kubectl config get-contexts -o name | head -n1)"
   ```

2. Create the Secret from a local env file (never commit it). Keys are the
   same as the RunPod template secrets in [`../generic/README.md`](../generic/README.md),
   plus optional `PUBLIC_KEY` for SSH. All keys are optional.

   ```bash
   kubectl create secret generic runpod-image-secrets --from-env-file=.env.coreweave
   ```

   To change it later, delete and recreate it, then recreate the pod.

## Daily use

```bash
kubectl apply -k coreweave/   # PVC, disk-guard ConfigMap, pod
kubectl wait --for=condition=Ready pod/dev --timeout=15m   # first pull is slow
kubectl exec -it dev -- bash
```

New nodes run CoreWeave's HPC verification burn-in first, holding all 8 GPUs,
so the pod stays Pending until it ends (`kubectl get pods -n
cw-hpc-verification` is empty). `ACTIVE false` in `cwic node get` only means
the node is idle (no workloads), not that it is unready.

When done: `kubectl delete pod dev`. `/workspace` persists; `/root` does not,
so push your code first. The reserved node bills whether or not the pod runs.

## Disk guard

`/root`, `/tmp` and everything else outside `/workspace` live on the node's
local disk (~7 TiB) with no quota. If that disk drops below 5% free, the
kubelet evicts the pod and `/root` is gone. An `ephemeral-storage` limit
wouldn't help, because the kubelet enforces it by evicting too.

[`disk-guard.sh`](disk-guard.sh) runs inside the pod and checks free space every
2 s. Below 8% free it SIGSTOPs running jobs (it does not kill them) and
prints a warning to every terminal. Shells, sshd, tmux, editor servers and
Claude Code keep running, and so do commands you start after the pause, so you
can clean up. When free space is back at 15%, the jobs continue. If free space
keeps falling while paused, the guard pauses again, catching any new writers.

- See what it did: `kubectl logs dev | grep disk-guard`
- Find what's big: `du -xh -d2 / | sort -h | tail`
- Distributed jobs: NCCL collectives can time out when they resume after a
  long pause.

## SSH (VS Code / Zed Remote-SSH)

Needs `PUBLIC_KEY` in the Secret; `/start.sh` then starts `sshd`.

```bash
kubectl port-forward pod/dev 2222:22
ssh -p 2222 root@localhost
```

`~/.ssh/config` entry for editors:

```
Host coreweave-dev
    HostName localhost
    Port 2222
    User root
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

Host-key checking is off because every new pod generates fresh host keys
behind the same `localhost:2222`.
