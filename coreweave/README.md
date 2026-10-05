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

3. Create the volume:

   ```bash
   kubectl apply -f coreweave/workspace-pvc.yaml
   ```

## Daily use

```bash
kubectl apply -f coreweave/dev-pod.yaml
kubectl wait --for=condition=Ready pod/dev --timeout=15m   # first pull is slow
kubectl exec -it dev -- bash
```

New nodes run CoreWeave's HPC verification burn-in first, holding all 8 GPUs,
so the pod stays Pending until it ends (`kubectl get pods -n
cw-hpc-verification` is empty). `ACTIVE false` in `cwic node get` only means
the node is idle (no workloads), not that it is unready.

When done: `kubectl delete pod dev`. `/workspace` persists; `/root` does not,
so push your code first. The reserved node bills whether or not the pod runs.

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
