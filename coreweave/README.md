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
kubectl apply -k coreweave/   # PVC, pod-guard ConfigMap, pod
kubectl wait --for=condition=Ready pod/dev --timeout=15m   # first pull is slow
kubectl exec -it dev -- bash
```

New nodes run CoreWeave's HPC verification burn-in first, holding all 8 GPUs,
so the pod stays Pending until it ends (`kubectl get pods -n
cw-hpc-verification` is empty). `ACTIVE false` in `cwic node get` only means
the node is idle (no workloads), not that it is unready.

When done: `kubectl delete pod dev`. `/workspace` persists; `/root` does not,
so push your code first. The reserved node bills whether or not the pod runs.

## Pod guard

The pod is a bare Pod with `restartPolicy: Never`, so anything that kills the
container loses `/root`. Two things can, and Kubernetes limits can't stop them,
because the limits are what do the killing:

- **Disk.** `/root`, `/tmp` and everything else outside `/workspace` live on
  the node's local disk (~7 TiB) with no quota. Below 5% free, the kubelet
  evicts the pod. An `ephemeral-storage` limit would evict it too.
- **Memory.** At the 900Gi limit, the kernel OOM-kills. Kubernetes sets
  `memory.oom.group=1`, so every process dies, PID 1 included.

[`pod-guard.sh`](pod-guard.sh) runs inside the pod and handles both:

- At startup it sets `memory.oom.group=0`, so an OOM kills one process
  instead of the whole pod. It also sets `memory.high` 2% below the limit,
  where the kernel slows allocations down instead of killing anything.
- Every 0.5 s it checks free space on `/` (pauses below 8%, resumes at 15%),
  free space on `/workspace` (5% / 8%), and memory headroom (7% / 12%).
  Memory headroom excludes page cache, because the kernel can free that.
- When a check trips, it SIGSTOPs running jobs (it doesn't kill them) and warns
  every terminal. Shells, sshd, tmux, editor servers and Claude Code keep
  running, and so do commands you start after the pause, so you can clean
  up: delete files, or for memory, kill one of the paused jobs the warning
  names. Once the tripped resource recovers, the jobs continue. If it keeps
  falling while paused, the guard pauses again, catching any new jobs.

`/dev/shm` is sized to the memory limit. It counts against memory, and it
fills at 25 GiB/s, faster than any polling could catch a smaller tmpfs.

- See what it did: `kubectl logs dev | grep pod-guard`
- Distributed jobs: NCCL collectives can time out when they resume after a
  long pause.
- Not covered: CoreWeave draining or rebooting the node (maintenance, GPU
  faults). Push code and keep checkpoints on `/workspace`.

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
